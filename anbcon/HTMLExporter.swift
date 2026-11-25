//
//  HTMLExporter.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import CryptoKit
import Darwin
import Foundation

enum HTMLExporter {
    struct Result {
        let file: URL
        let unavailableFigures: [Int]
    }

    enum ExistingFilePolicy {
        case refuse
        case replace
        case replaceOwned
    }

    enum ExportError: LocalizedError {
        case missingWorkspace
        case invalidDirectory(String)
        case fileExists(String)
        case unownedFile(String)

        var errorDescription: String? {
            switch self {
            case .missingWorkspace: "Set up the workspace with -w before exporting."
            case .invalidDirectory(let path): "Export destination is not an existing directory: \(path)."
            case .fileExists(let path): "Export already exists: \(path)."
            case .unownedFile(let path): "Will not replace an HTML file not marked as this note's export: \(path). Use interactive CLI to confirm replacement."
            }
        }
    }

    static func destination(for title: String, in directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ExportError.invalidDirectory(directory.path) }
        return directory.appendingPathComponent(filename(for: title), isDirectory: false)
    }

    static func filename(for title: String) -> String {
        var stem = ""
        var needsSeparator = false
        let locale = Locale(identifier: "en_US_POSIX")
        for character in title.precomposedStringWithCanonicalMapping.lowercased() {
            let word: String
            if let letters = russianLetters[character] {
                if letters.isEmpty { continue }
                word = letters
            } else {
                let folded = String(character).folding(options: .diacriticInsensitive, locale: locale)
                let bytes = folded.utf8.filter { (97...122).contains($0) || (48...57).contains($0) }
                word = String(decoding: bytes, as: UTF8.self)
            }
            if word.isEmpty {
                needsSeparator = !stem.isEmpty
            } else {
                if needsSeparator { stem.append("_") }
                stem += word
                needsSeparator = false
                if stem.count >= 240 { break }
            }
        }
        let filename = String(stem.prefix(240)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (filename.isEmpty ? "note" : filename) + ".html"
    }

    static func export(
        _ notesHTML: String, title: String?, to file: URL, existing: ExistingFilePolicy = .refuse, noteID: String? = nil
    ) throws -> Result {
        let manager = FileManager.default
        let marker = noteID.map {
            let hash = Data(SHA256.hash(data: Data($0.utf8))).base64EncodedString()
            return "<meta name=\"anbcon-source\" content=\"\(hash)\">"
        }
        func canReplace() throws -> Bool {
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink == true || manager.fileExists(atPath: file.path) else { return false }
            switch existing {
            case .refuse: throw ExportError.fileExists(file.path)
            case .replace: return true
            case .replaceOwned:
                guard let marker, values?.isRegularFile == true, values?.isSymbolicLink == false else {
                    throw ExportError.unownedFile(file.path)
                }
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                let header = try input.read(upToCount: 512) ?? Data()
                guard String(decoding: header, as: UTF8.self).contains("\n\(marker)\n") else {
                    throw ExportError.unownedFile(file.path)
                }
                return true
            }
        }
        _ = try canReplace()
        let directory = file.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".anbcon-\(UUID().uuidString).tmp")
        try Data().write(to: staging, options: .withoutOverwriting)
        defer { try? manager.removeItem(at: staging) }

        let handle = try FileHandle(forWritingTo: staging)
        var closed = false
        defer { if !closed { try? handle.close() } }

        func write(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }

        let documentTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Apple Notes"
        try write("""
        <!doctype html>
        <html lang="ru">
        <head>
        <meta charset="utf-8">
        \(marker ?? "")
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(documentTitle))</title>
        \(style)
        </head>
        <body>
        <main>

        """)
        var unavailable: [Int] = []
        var hasHeading = false
        try NotesHTMLParser().visitExportBlocks(notesHTML) { block, png in
            switch block {
            case .heading(let text):
                let tag = hasHeading ? "h2" : "h1"
                try write("<\(tag)>\(escape(text))</\(tag)>\n")
                hasHeading = true
            case .text(let text):
                try write("<p>\(escape(text))</p>\n")
            case .blank:
                try write("<div class=\"blank\" aria-hidden=\"true\"></div>\n")
            case .figure(let number):
                let label = BookDocument.figureLabel(number)
                try write("<figure id=\"figure-\(label)\">")
                if let png {
                    try write("<img alt=\"Рисунок \(label)\" src=\"data:image/png;base64,")
                    try handle.write(contentsOf: png.base64EncodedData())
                    try write("\">")
                } else {
                    unavailable.append(number)
                    try write("<figcaption>Рисунок \(label) недоступен</figcaption>")
                }
                try write("</figure>\n")
            }
        }
        try write("</main>\n</body>\n</html>\n")
        try handle.close()
        closed = true
        if try canReplace() {
            try staging.withUnsafeFileSystemRepresentation { source in
                try file.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { throw POSIXError(.EINVAL) }
                    guard Darwin.rename(source, destination) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
        } else {
            do {
                try manager.moveItem(at: staging, to: file)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw ExportError.fileExists(file.path)
            }
        }
        return Result(file: file, unavailableFigures: unavailable)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let russianLetters: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
        "ж": "zh", "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
    ]

    private static let style = """
    <style>
      :root { color-scheme: light; }
      body { color: #171717; background: #fff; font: 1.1rem/1.55 Georgia, "Times New Roman", serif; }
      main { max-width: 46rem; margin: 2rem auto; padding: 0 1rem; overflow-wrap: anywhere; }
      h1, h2 { line-height: 1.2; }
      p { margin: 0 0 .65em; white-space: pre-wrap; }
      figure { margin: 1.25em 0; }
      figure img { display: block; width: auto; height: auto; max-width: 100%; margin: 0 auto; }
      .blank { height: .65em; }
      @page { margin: 16mm; }
      @media print {
        body { margin: 0; color: #000; background: #fff; font-size: 11pt; }
        main { max-width: none; margin: 0; padding: 0; }
        h1, h2, .blank { break-after: avoid; page-break-after: avoid; }
        p { orphans: 3; widows: 3; }
        figure { break-inside: avoid; page-break-inside: avoid; }
        figure img { max-height: 210mm; object-fit: contain; }
      }
      @media print and (orientation: landscape) {
        figure img { max-height: 145mm; }
      }
    </style>
    """
}
