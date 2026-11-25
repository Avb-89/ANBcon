//
//  NotesSearch.swift
//  anbcon
//
//  Created by SITIS on 11/25/26.
//

import CryptoKit
import Foundation

enum NotesSearch {
    enum Field {
        case title
        case body
    }

    struct Request {
        let groups: [[String]]
        let field: Field
        let exact: Bool
        let window: Int
        let hitOffset: Int
    }

    struct Hit {
        let reference: String
        let chapter: String?
        let blockNumber: Int?
        let excerpt: String
        let terms: [String]
    }

    struct ChapterMatches {
        let title: String
        let count: Int
    }

    struct Match {
        let note: NotesClient.Note
        let count: Int
        let chapters: [ChapterMatches]
        let hit: Hit?
    }

    struct Failure {
        let note: NotesClient.Note
        let reason: String
    }

    struct Report {
        let checked: Int
        let total: Int
        let failures: [Failure]
        let matches: [Match]
    }

    struct Context {
        let title: String
        let chapter: String?
        let firstBlockNumber: Int?
        let lines: [String]
    }

    enum SearchError: LocalizedError {
        case invalidWindow
        case invalidReference
        case noteChanged
        case invalidRadius
        case invalidHitOffset

        var errorDescription: String? {
            switch self {
            case .invalidWindow: "Use --near with 1–8 text blocks, and only for body search."
            case .invalidReference: "Invalid context reference. Copy the full reference from search output."
            case .noteChanged: "The note changed since the search. Search again for a new reference."
            case .invalidRadius: "--radius requires a number from 0 to 8."
            case .invalidHitOffset: "--hit-offset requires zero or a positive number."
            }
        }
    }

    private struct Anchor: Codable {
        let noteID: String
        let revision: String
        let section: Int?
        let firstBlock: Int?
        let lastBlock: Int?

        func reference() throws -> String {
            try JSONEncoder().encode(self).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func decode(_ reference: String) throws -> Anchor {
            guard (1...2048).contains(reference.utf8.count) else { throw SearchError.invalidReference }
            var encoded = reference.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded),
                  let anchor = try? JSONDecoder().decode(Self.self, from: data),
                  !anchor.noteID.isEmpty,
                  Data(base64Encoded: anchor.revision)?.count == 32 else { throw SearchError.invalidReference }
            switch (anchor.section, anchor.firstBlock, anchor.lastBlock) {
            case (nil, nil, nil): break
            case let (section?, first?, last?) where section >= 0 && first >= 0 && last >= first: break
            default: throw SearchError.invalidReference
            }
            return anchor
        }
    }

    private struct TextBlock {
        let index: Int
        let text: String
        let evidence: [BookSearch.LiteralGroups.Evidence]
    }

    static func search(
        _ notes: [NotesClient.Note], request: Request, readBody: (String) throws -> String
    ) throws -> Report {
        guard (1...8).contains(request.window), request.field == .body || request.window == 1 else {
            throw SearchError.invalidWindow
        }
        guard request.hitOffset >= 0 else { throw SearchError.invalidHitOffset }
        let query = try BookSearch.LiteralGroups(request.groups, exact: request.exact)
        let notes = NotesClient.uniqueNotes(notes)
        var matches: [Match] = []
        var failures: [Failure] = []
        for note in notes {
            do {
                switch request.field {
                case .title:
                    let evidence = query.evidence(in: note.title)
                    guard evidence.count == query.count, let first = evidence.first else { continue }
                    let anchor = Anchor(
                        noteID: note.id, revision: digest(Data(note.title.utf8)),
                        section: nil, firstBlock: nil, lastBlock: nil
                    )
                    let hit = request.hitOffset == 0 ? Hit(
                        reference: try anchor.reference(), chapter: nil, blockNumber: nil,
                        excerpt: snippet(note.title, at: first.range.location, width: 220),
                        terms: evidence.map(\.text)
                    ) : nil
                    matches.append(Match(note: note, count: 1, chapters: [], hit: hit))
                case .body:
                    let document = NotesHTMLParser().parse(try readBody(note.id))
                    if let match = try bodyMatch(note, document: document, query: query, request: request) {
                        matches.append(match)
                    }
                }
            } catch {
                failures.append(Failure(note: note, reason: error.localizedDescription))
            }
        }
        matches.sort { first, second in
            if first.count != second.count { return first.count > second.count }
            let order = first.note.title.localizedStandardCompare(second.note.title)
            return order == .orderedSame ? first.note.id < second.note.id : order == .orderedAscending
        }
        return Report(checked: notes.count - failures.count, total: notes.count, failures: failures, matches: matches)
    }

    static func readContext(
        _ reference: String, radius: Int, readNote: (String) throws -> (title: String, body: String)
    ) throws -> Context {
        guard (0...8).contains(radius) else { throw SearchError.invalidRadius }
        let anchor = try Anchor.decode(reference)
        let note = try readNote(anchor.noteID)
        let document = NotesHTMLParser().parse(note.body)
        guard let sectionIndex = anchor.section, let firstBlock = anchor.firstBlock, let lastBlock = anchor.lastBlock else {
            guard digest(Data(note.title.utf8)) == anchor.revision else { throw SearchError.noteChanged }
            let lines = document.sections.lazy.flatMap(\.blocks).filter { $0 != .blank }
            return Context(title: note.title, chapter: nil, firstBlockNumber: nil,
                           lines: Array(lines.prefix(radius).map(\.plainText)))
        }
        guard try revision(of: document) == anchor.revision else { throw SearchError.noteChanged }
        guard document.sections.indices.contains(sectionIndex) else { throw SearchError.invalidReference }
        let section = document.sections[sectionIndex]
        guard section.blocks.indices.contains(firstBlock), section.blocks.indices.contains(lastBlock) else {
            throw SearchError.invalidReference
        }
        var start = firstBlock
        var end = lastBlock
        var before = radius
        var after = radius
        while start > 0 && before > 0 {
            start -= 1
            if section.blocks[start] != .blank { before -= 1 }
        }
        while end < section.blocks.count - 1 && after > 0 {
            end += 1
            if section.blocks[end] != .blank { after -= 1 }
        }
        return Context(
            title: note.title, chapter: section.chapterHeading, firstBlockNumber: start + 1,
            lines: section.blocks[start...end].map(\.plainText)
        )
    }

    private static func bodyMatch(
        _ note: NotesClient.Note, document: BookDocument, query: BookSearch.LiteralGroups, request: Request
    ) throws -> Match? {
        var count = 0
        var chapters: [ChapterMatches] = []
        var hit: Hit?
        for (sectionIndex, section) in document.sections.enumerated() {
            var window: [TextBlock] = []
            let before = count
            for (index, block) in section.blocks.enumerated() {
                let text: String
                switch block {
                case .text(let value), .heading(let value): text = value
                case .blank, .figure: continue
                }
                let evidence = query.evidence(in: text)
                window.append(TextBlock(index: index, text: text, evidence: evidence))
                if window.count > request.window { window.removeFirst() }
                guard !evidence.isEmpty else { continue }

                var terms: [Int: String] = [:]
                var first: Int?
                for position in window.indices.reversed() {
                    for item in window[position].evidence where terms[item.group] == nil {
                        terms[item.group] = item.text
                    }
                    if terms.count == query.count {
                        first = position
                        break
                    }
                }
                guard let first else { continue }
                if count == request.hitOffset {
                    let anchor = Anchor(
                        noteID: note.id, revision: try revision(of: document),
                        section: sectionIndex, firstBlock: window[first].index, lastBlock: index
                    )
                    let excerpts = window[first...].filter { !$0.evidence.isEmpty }.prefix(3)
                    let excerpt = excerpts.map { row in
                        snippet(row.text, at: row.evidence.first?.range.location ?? 0, width: excerpts.count == 1 ? 220 : 90)
                    }.joined(separator: " / ")
                    hit = Hit(
                        reference: try anchor.reference(), chapter: section.chapterHeading, blockNumber: window[first].index + 1,
                        excerpt: excerpt, terms: terms.keys.sorted().compactMap { terms[$0] }
                    )
                }
                count += 1
            }
            if let chapter = section.chapterHeading, count > before {
                chapters.append(ChapterMatches(title: chapter, count: count - before))
            }
        }
        guard count > 0 else { return nil }
        return Match(note: note, count: count, chapters: chapters, hit: hit)
    }

    static func revision(of document: BookDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(document.sections))
    }

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func snippet(_ text: String, at location: Int, width: Int) -> String {
        let length = text.count
        guard length > width else { return text }
        let anchor = String.Index(utf16Offset: location, in: text)
        let offset = min(max(0, text.distance(from: text.startIndex, to: anchor) - width / 3), length - width)
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: width)
        return (offset == 0 ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }
}
