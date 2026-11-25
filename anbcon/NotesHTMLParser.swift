//
//  NotesHTMLParser.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import CryptoKit
import Foundation

struct NotesHTMLParser {
    func parse(_ html: String, extractingPNG number: Int? = nil, fingerprintingPNGs: Bool = false) -> BookDocument {
        withBytes(html) {
            parse($0, extractingPNG: number, fingerprintingPNGs: fingerprintingPNGs, indexingPNGs: false).document
        }
    }

    func visitExportBlocks(_ html: String, _ visit: (BookDocument.Block, Data?) throws -> Void) rethrows {
        try withBytes(html) { bytes in
            let source = parse(bytes, extractingPNG: nil, fingerprintingPNGs: false, indexingPNGs: true)
            let scanner = Scanner(bytes: bytes)
            for section in source.document.sections {
                for block in section.blocks {
                    var png: Data?
                    if case .figure(let number) = block, let range = source.payloads[number - 1] {
                        png = scanner.decodePNG(in: range)
                    }
                    try visit(block, png)
                }
            }
        }
    }

    private func withBytes<T>(_ html: String, _ work: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        if let result = try html.utf8.withContiguousStorageIfAvailable(work) { return result }
        return try Array(html.utf8).withUnsafeBufferPointer(work)
    }

    private func parse(
        _ bytes: UnsafeBufferPointer<UInt8>, extractingPNG number: Int?, fingerprintingPNGs: Bool, indexingPNGs: Bool
    ) -> (document: BookDocument, payloads: [Range<Int>?]) {
        var scanner = Scanner(bytes: bytes)
        var document = Builder()
        var ignoredElement: String?
        var payloads: [Range<Int>?] = []

        while !scanner.isAtEnd {
            if let tag = scanner.readTag() {
                if let skipped = ignoredElement {
                    if tag.isClosing && tag.name == skipped {
                        ignoredElement = nil
                    }
                    continue
                }

                switch tag.name {
                case "head", "script", "style":
                    if !tag.isClosing { ignoredElement = tag.name }
                case "div", "p", "blockquote", "section", "ul", "ol", "tr":
                    document.flushText()
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    document.flushText()
                    document.isHeading = !tag.isClosing
                case "li":
                    document.flushText()
                    document.startsListItem = !tag.isClosing
                case "br":
                    if !tag.isClosing { document.lineBreak() }
                case "td", "th":
                    if tag.isClosing && !document.pendingText.isEmpty { document.pendingText.append(" ") }
                case "img":
                    if !tag.isClosing {
                        let figureNumber = document.figures.count + 1
                        let extract = figureNumber == number
                        let payload = extract || fingerprintingPNGs || indexingPNGs ? scanner.pngPayload(in: tag) : nil
                        if indexingPNGs { payloads.append(payload) }
                        let png = extract || fingerprintingPNGs ? payload.flatMap { scanner.decodePNG(in: $0) } : nil
                        let fingerprint = fingerprintingPNGs ? png.map { Data(SHA256.hash(data: $0)).base64EncodedString() } : nil
                        document.addFigure(png: extract ? png : nil, fingerprint: fingerprint)
                    }
                default:
                    break
                }
            } else {
                let text = scanner.readText()
                if ignoredElement == nil { document.appendText(text) }
            }
        }
        return (document.finish(), payloads)
    }

    private struct Tag {
        let name: String
        let isClosing: Bool
        let attributes: Range<Int>
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

        var isAtEnd: Bool { position >= bytes.count }

        mutating func readText() -> String {
            let start = position
            position += 1
            while !isAtEnd && bytes[position] != 60 { position += 1 }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        mutating func readTag() -> Tag? {
            guard !isAtEnd, bytes[position] == 60, position + 1 < bytes.count else { return nil }
            let initial = bytes[position + 1]
            if initial == 33 || initial == 63 {
                return readDeclaration()
            }

            let isClosing = initial == 47
            let nameStart = position + (isClosing ? 2 : 1)
            guard nameStart < bytes.count, Self.isLetter(bytes[nameStart]) else { return nil }
            var cursor = nameStart
            while cursor < bytes.count && Self.isNameByte(bytes[cursor]) { cursor += 1 }
            let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
            let attributesStart = cursor
            var quote: UInt8 = 0

            while cursor < bytes.count {
                let byte = bytes[cursor]
                if quote != 0 {
                    if byte == quote { quote = 0 }
                } else if byte == 34 || byte == 39 {
                    quote = byte
                } else if byte == 62 {
                    position = cursor + 1
                    return Tag(name: name, isClosing: isClosing, attributes: attributesStart..<cursor)
                } else if byte == 60 {
                    return nil
                }
                cursor += 1
            }
            return nil
        }

        private mutating func readDeclaration() -> Tag? {
            let start = position
            var cursor = start + 2
            let isComment = cursor + 1 < bytes.count && bytes[start + 1] == 33
                && bytes[cursor] == 45 && bytes[cursor + 1] == 45
            if isComment { cursor += 2 }
            while cursor < bytes.count {
                if bytes[cursor] == 62,
                   !isComment || (cursor >= start + 6 && bytes[cursor - 1] == 45 && bytes[cursor - 2] == 45) {
                    position = cursor + 1
                    return Tag(name: "", isClosing: false, attributes: cursor..<cursor)
                }
                cursor += 1
            }
            return nil
        }

        func pngPayload(in tag: Tag) -> Range<Int>? {
            let prefix = "data:image/png;base64,"
            guard let range = attribute("src", in: tag), range.count > prefix.utf8.count else {
                return nil
            }
            let payloadStart = range.lowerBound + prefix.utf8.count
            let header = String(decoding: bytes[range.lowerBound..<payloadStart], as: UTF8.self)
            guard header.lowercased() == prefix else { return nil }
            return payloadStart..<range.upperBound
        }

        func decodePNG(in range: Range<Int>) -> Data? {
            let payload = String(decoding: bytes[range], as: UTF8.self)
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10] as [UInt8]) else { return nil }
            return data
        }

        private func attribute(_ key: String, in tag: Tag) -> Range<Int>? {
            var cursor = tag.attributes.lowerBound
            let end = tag.attributes.upperBound

            while cursor < end {
                while cursor < end && Self.isSpace(bytes[cursor]) { cursor += 1 }
                let start = cursor
                while cursor < end && Self.isNameByte(bytes[cursor]) { cursor += 1 }
                if start == cursor {
                    cursor += 1
                    continue
                }
                let name = String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()
                while cursor < end && Self.isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < end, bytes[cursor] == 61 else { continue }
                cursor += 1
                while cursor < end && Self.isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < end else { return nil }

                let quote = bytes[cursor]
                if quote == 34 || quote == 39 {
                    cursor += 1
                    let value = cursor
                    while cursor < end && bytes[cursor] != quote { cursor += 1 }
                    if name == key { return value..<cursor }
                    if cursor < end { cursor += 1 }
                } else {
                    let value = cursor
                    while cursor < end && !Self.isSpace(bytes[cursor]) { cursor += 1 }
                    if name == key { return value..<cursor }
                }
            }
            return nil
        }

        private static func isLetter(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte)
        }

        private static func isNameByte(_ byte: UInt8) -> Bool {
            isLetter(byte) || (48...57).contains(byte) || byte == 45 || byte == 58 || byte == 95
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 32 || (9...13).contains(byte)
        }
    }

    private struct Builder {
        private static let chapterPattern = #"^глава\s*[0-9]+(?:\s*[.:—–-].*)?$"#
        private static let richLineBreaks = CharacterSet(charactersIn: "\u{2028}\u{2029}")
        private var sections: [BookDocument.Section] = []
        private var chapterHeading: String?
        private var blocks: [BookDocument.Block] = []
        private(set) var figures: [BookDocument.Figure] = []
        var pendingText = ""
        var isHeading = false
        var startsListItem = false

        mutating func appendText(_ raw: String) {
            let text = NotesHTMLParser.decodeEntities(raw)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")

            for (index, part) in text.components(separatedBy: Self.richLineBreaks).enumerated() {
                if index > 0 { lineBreak() }
                pendingText.append(part)
            }
        }

        @discardableResult
        mutating func flushText() -> Bool {
            let text = pendingText.trimmingCharacters(in: .whitespaces)
            pendingText.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return false }

            if text.range(of: Self.chapterPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                finishSection()
                chapterHeading = text
                blocks.append(.heading(text))
            } else if isHeading {
                blocks.append(.heading(text))
            } else {
                blocks.append(.text(startsListItem ? "- \(text)" : text))
            }
            startsListItem = false
            return true
        }

        mutating func lineBreak() {
            if !flushText() { blocks.append(.blank) }
        }

        mutating func addFigure(png: Data?, fingerprint: String?) {
            flushText()
            let number = figures.count + 1
            figures.append(.init(number: number, png: png, fingerprint: fingerprint))
            blocks.append(.figure(number))
        }

        private mutating func finishSection() {
            guard !blocks.isEmpty else { return }
            sections.append(.init(chapterHeading: chapterHeading, blocks: blocks))
            blocks = []
        }

        mutating func finish() -> BookDocument {
            flushText()
            finishSection()
            return BookDocument(sections: sections, figures: figures)
        }
    }

    private static let entityPattern = try? NSRegularExpression(
        pattern: #"&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]*);"#
    )

    private static let namedEntities = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "bull": "•"
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"), let entityPattern else { return text }
        let source = text as NSString
        let matches = entityPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let name = source.substring(with: match.range(at: 1))
            if let decoded = namedEntities[name] ?? numericEntity(name) {
                result.replaceCharacters(in: match.range, with: decoded)
            }
        }
        return result as String
    }

    private static func numericEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return nil }
        let value = name.dropFirst()
        let isHex = value.hasPrefix("x") || value.hasPrefix("X")
        guard let number = UInt32(isHex ? value.dropFirst() : value, radix: isHex ? 16 : 10),
              let scalar = Unicode.Scalar(number) else { return nil }
        return String(scalar)
    }
}
