//
//  BookDocument.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

struct BookDocument {
    struct Statistics {
        let words: Int
        let chaptersWithText: Int
        let chaptersWithoutText: Int
        let figures: Int
    }

    struct Section: Codable {
        let chapterHeading: String?
        let blocks: [Block]
    }

    enum Block: Codable, Equatable {
        case heading(String)
        case text(String)
        case figure(Int)
        case blank

        var plainText: String {
            switch self {
            case .heading(let title), .text(let title): title
            case .figure(let number): "[Рисунок \(BookDocument.figureLabel(number))]"
            case .blank: ""
            }
        }
    }

    struct Figure {
        let number: Int
        let png: Data?
        var fingerprint: String? = nil
    }

    enum FigureError: LocalizedError {
        case workspaceRequired
        case notFound(Int, Int)
        case noPNG(Int)
        case unsafeDirectory

        var errorDescription: String? {
            switch self {
            case .workspaceRequired: "Saving an image requires a workspace."
            case .notFound(let number, let count): "Figure \(number) was not found. The note has \(count) figures."
            case .noPNG(let number): "Figure \(number) has no readable embedded PNG."
            case .unsafeDirectory: "The images directory must not be a symlink."
            }
        }
    }

    let sections: [Section]
    let figures: [Figure]

    var plainText: String {
        sections.flatMap(\.blocks).map(\.plainText).joined(separator: "\n")
    }

    func statistics(wordCount: Int) -> Statistics {
        let chapters = sections.filter { $0.chapterHeading != nil }
        let withText = chapters.filter { section in
            section.blocks.contains { block in
                if case .text = block { return true }
                return false
            }
        }.count
        return Statistics(
            words: wordCount,
            chaptersWithText: withText,
            chaptersWithoutText: chapters.count - withText,
            figures: figures.count
        )
    }

    func png(for number: Int) throws -> Data {
        guard let figure = figures.first(where: { $0.number == number }) else {
            throw FigureError.notFound(number, figures.count)
        }
        guard let png = figure.png else { throw FigureError.noPNG(number) }
        return png
    }

    static func savePNG(_ png: Data, number: Int, in workspace: URL) throws -> URL {
        let directory = workspace.appendingPathComponent("images", isDirectory: true)
        let manager = FileManager.default
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw FigureError.unsafeDirectory
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "figure-\(figureLabel(number))"
        var file = directory.appendingPathComponent("\(base).png")
        var suffix = 2
        while manager.fileExists(atPath: file.path) {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
               (try? Data(contentsOf: file)) == png { return file }
            file = directory.appendingPathComponent("\(base)-\(suffix).png")
            suffix += 1
        }
        try png.write(to: file, options: .withoutOverwriting)
        return file
    }

    static func figureLabel(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }
}
