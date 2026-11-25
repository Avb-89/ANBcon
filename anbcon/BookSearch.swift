//
//  BookSearch.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation
import NaturalLanguage

enum BookSearch {
    struct Request {
        let query: String
        let chapter: String?
        let exact: Bool
        let countOnly: Bool
        let limit: Int?
        let offset: Int
        var excerptLimit: Int? = nil
    }

    struct Hit {
        let chapter: String?
        let blockNumber: Int
        let excerpt: String
    }

    struct Result {
        let occurrences: Int
        let matchingSentences: Int
        let hits: [Hit]
        let nextOffset: Int?
    }

    enum SearchError: LocalizedError {
        case emptyQuery
        case chapterNotFound(String)
        case invalidGroups

        var errorDescription: String? {
            switch self {
            case .emptyQuery: "Enter a non-empty search query."
            case .chapterNotFound(let chapter): "Chapter not found: \(chapter)."
            case .invalidGroups: "Use 1–8 groups with 1–12 non-empty alternatives each (up to 512 bytes per alternative)."
            }
        }
    }

    struct LiteralGroups {
        struct Evidence {
            let group: Int
            let text: String
            let range: NSRange
        }

        private let patterns: [NSRegularExpression]
        var count: Int { patterns.count }

        init(_ groups: [[String]], exact: Bool) throws {
            guard (1...8).contains(groups.count) else { throw SearchError.invalidGroups }
            patterns = try groups.map { group in
                let terms = group.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard (1...12).contains(terms.count),
                      terms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
                    throw SearchError.invalidGroups
                }
                let choices = terms.sorted { $0.count > $1.count }
                    .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                let pattern = "(?:\(choices))"
                let word = #"[\p{L}\p{M}\p{N}_]"#
                return try NSRegularExpression(
                    pattern: exact ? "(?<!\(word))\(pattern)(?!\(word))" : pattern, options: .caseInsensitive
                )
            }
        }

        func evidence(in text: String) -> [Evidence] {
            let string = text as NSString
            let bounds = NSRange(location: 0, length: string.length)
            return patterns.enumerated().compactMap { index, pattern in
                guard let match = pattern.firstMatch(in: text, range: bounds) else { return nil }
                return Evidence(group: index, text: string.substring(with: match.range), range: match.range)
            }
        }
    }

    private static let chapterNumber = try? NSRegularExpression(
        pattern: #"^(?:глава\s*)?([0-9]+)$"#,
        options: .caseInsensitive
    )

    private static let headingNumber = try? NSRegularExpression(
        pattern: #"^глава\s*([0-9]+)"#,
        options: .caseInsensitive
    )

    static func search(_ document: BookDocument, request: Request) throws -> Result {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SearchError.emptyQuery }

        let literal = NSRegularExpression.escapedPattern(for: query)
        let word = #"[\p{L}\p{M}\p{N}_]"#
        let pattern = request.exact ? "(?<!\(word))\(literal)(?!\(word))" : literal
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let sections = try selectSections(from: document, chapter: request.chapter)
        let tokenizer = request.countOnly ? nil : NLTokenizer(unit: .sentence)
        let limit = request.limit.map { max(1, $0) } ?? Int.max
        let offset = max(0, request.offset)
        var occurrences = 0
        var matchingSentences = 0
        var hits: [Hit] = []

        for section in sections {
            for (index, block) in section.blocks.enumerated() {
                let text: String
                switch block {
                case .text(let value), .heading(let value): text = value
                case .blank, .figure: continue
                }
                let bounds = NSRange(text.startIndex..<text.endIndex, in: text)
                guard let tokenizer else {
                    occurrences += regex.numberOfMatches(in: text, range: bounds)
                    continue
                }

                let matches = regex.matches(in: text, range: bounds)
                guard !matches.isEmpty else { continue }
                occurrences += matches.count
                tokenizer.string = text
                let wholeBlock = text.startIndex..<text.endIndex
                let sentences = tokenizer.tokens(for: wholeBlock)
                var sentenceIndex = 0
                var lastSentence: Range<String.Index>?

                for match in matches {
                    let anchor = Range(match.range, in: text)?.lowerBound
                        ?? String.Index(utf16Offset: match.range.location, in: text)
                    while sentenceIndex < sentences.count && sentences[sentenceIndex].upperBound <= anchor {
                        sentenceIndex += 1
                    }
                    let sentence: Range<String.Index>
                    if sentenceIndex < sentences.count, sentences[sentenceIndex].contains(anchor) {
                        sentence = sentences[sentenceIndex]
                    } else {
                        sentence = wholeBlock
                    }
                    guard sentence != lastSentence else { continue }
                    lastSentence = sentence
                    defer { matchingSentences += 1 }
                    guard matchingSentences >= offset, hits.count < limit else { continue }
                    hits.append(Hit(
                        chapter: section.chapterHeading,
                        blockNumber: index + 1,
                        excerpt: excerpt(in: text, span: sentence, anchor: anchor, limit: request.excerptLimit)
                    ))
                }
            }
        }

        let following = offset + hits.count
        return Result(
            occurrences: occurrences,
            matchingSentences: matchingSentences,
            hits: hits,
            nextOffset: following < matchingSentences ? following : nil
        )
    }

    static func countWords(in document: BookDocument, chapter: String?) throws -> Int {
        let sections = try selectSections(from: document, chapter: chapter)
        let part = #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*"#
        let words = try NSRegularExpression(pattern: #"\#(part)(?:['’‐‑-]\#(part))*"#)
        var count = 0
        for section in sections {
            for block in section.blocks {
                let text: String
                switch block {
                case .text(let value), .heading(let value): text = value
                case .blank, .figure: continue
                }
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                words.enumerateMatches(in: text, range: range) { match, _, _ in
                    guard let match, let token = Range(match.range, in: text),
                          text[token].unicodeScalars.contains(where: CharacterSet.letters.contains) else { return }
                    count += 1
                }
            }
        }
        return count
    }

    static func selectSections(from document: BookDocument, chapter: String?) throws -> [BookDocument.Section] {
        guard let chapter else { return document.sections }
        let name = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = Self.number(in: name, using: chapterNumber)
        let selected = document.sections.filter { section in
            guard let heading = section.chapterHeading else { return false }
            if let number { return Self.number(in: heading, using: headingNumber) == number }
            return heading.compare(name, options: .caseInsensitive) == .orderedSame
        }
        guard !selected.isEmpty else { throw SearchError.chapterNotFound(chapter) }
        return selected
    }

    private static func number(in text: String, using regex: NSRegularExpression?) -> Int? {
        guard let regex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let digits = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[digits])
    }

    private static func excerpt(in text: String, span: Range<String.Index>, anchor: String.Index, limit: Int?) -> String {
        guard let limit else { return text[span].trimmingCharacters(in: .whitespacesAndNewlines) }
        let width = max(1, limit)
        let count = text.distance(from: span.lowerBound, to: span.upperBound)
        let focus = text.distance(from: span.lowerBound, to: anchor)
        let startOffset = min(max(0, focus - width / 3), max(0, count - width))
        let start = text.index(span.lowerBound, offsetBy: startOffset)
        let end = text.index(start, offsetBy: min(width, count - startOffset))
        let value = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > span.lowerBound ? "…" : "") + value + (end < span.upperBound ? "…" : "")
    }
}
