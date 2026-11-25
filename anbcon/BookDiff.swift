//
//  BookDiff.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

enum BookDiff {
    struct Location {
        let chapter: String?
        let blockNumber: Int
    }

    struct Line {
        let block: BookDocument.Block
        let location: Location
    }

    struct Edit {
        enum Kind: String {
            case context = " "
            case removed = "-"
            case added = "+"
        }

        let kind: Kind
        let line: Line
        let oldIndex: Int
        let newIndex: Int
    }

    struct FigurePosition {
        let number: Int
        let location: Location
        let textOffset: Int
        let before: String?
        let after: String?
        let fingerprint: String?
    }

    enum FigureChange {
        case moved(FigurePosition, FigurePosition)
        case replaced(FigurePosition, FigurePosition)
        case removed(FigurePosition)
        case added(FigurePosition)
        case unverified(old: [FigurePosition], new: [FigurePosition])
    }

    struct Result {
        let text: [[Edit]]
        let figures: [FigureChange]
    }

    static func locationLabel(_ location: Location) -> String {
        let block = "#\(location.blockNumber)"
        return location.chapter.map { "\(oneLine($0)) · \(block)" } ?? block
    }

    static func render(_ result: Result) -> String {
        if result.text.isEmpty && result.figures.isEmpty { return "No changes." }
        var lines: [String] = []
        for hunk in result.text {
            guard let change = hunk.first(where: { $0.kind != .context }) else { continue }
            let side = change.kind == .removed ? "reviewed" : "current"
            lines.append("@@ \(side): \(locationLabel(change.line.location)) @@")
            lines += hunk.map { "\($0.kind.rawValue) \($0.line.block.plainText)" }
        }
        for change in result.figures {
            switch change {
            case .moved(let old, let new):
                lines.append("Figure moved (same PNG):\n  \(positionLabel(old))\n  → \(positionLabel(new))")
            case .replaced(let old, let new):
                lines.append("Figure replaced (same text anchors):\n  \(positionLabel(old))\n  → \(positionLabel(new))")
            case .removed(let old):
                lines.append("Figure removed: \(positionLabel(old))")
            case .added(let new):
                lines.append("Figure added: \(positionLabel(new))")
            case .unverified(let old, let new):
                lines.append("Cannot compare figures without a readable embedded PNG:")
                lines += old.map { "  reviewed: \(positionLabel($0))" }
                lines += new.map { "  current: \(positionLabel($0))" }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func positionLabel(_ position: FigurePosition) -> String {
        let label = "[Рисунок \(BookDocument.figureLabel(position.number))] [\(locationLabel(position.location))]"
        var context: [String] = []
        if let before = position.before {
            let line = oneLine(before)
            context.append("after «\((line.count > 90 ? "…" : "") + String(line.suffix(90)))»")
        }
        if let after = position.after {
            let line = oneLine(after)
            context.append("before «\(String(line.prefix(90)) + (line.count > 90 ? "…" : ""))»")
        }
        return context.isEmpty ? label : "\(label) \(context.joined(separator: ", "))"
    }

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
    }

    private struct Layout {
        let lines: [Line]
        let figures: [FigurePosition]

        init(_ snapshot: BookSnapshot) {
            var lines: [Line] = []
            var positions: [(number: Int, location: Location, offset: Int)] = []
            for section in snapshot.sections {
                for (index, block) in section.blocks.enumerated() {
                    let location = Location(chapter: section.chapterHeading, blockNumber: index + 1)
                    if case .figure(let number) = block {
                        positions.append((number, location, lines.count))
                    } else {
                        lines.append(Line(block: block, location: location))
                    }
                }
            }
            self.lines = lines
            figures = positions.map { position in
                let offset = position.offset
                let before = lines[..<offset].last { $0.block != .blank }
                let after = lines[offset...].first { $0.block != .blank }
                let figure = snapshot.figures.first { $0.number == position.number }
                return FigurePosition(
                    number: position.number, location: position.location, textOffset: offset,
                    before: before?.block.plainText, after: after?.block.plainText, fingerprint: figure?.fingerprint
                )
            }
        }
    }

    static func compare(reviewed: BookSnapshot, current: BookSnapshot, context: Int = 2) -> Result {
        let old = Layout(reviewed)
        let new = Layout(current)
        let edits = align(old.lines, new.lines)
        let anchors = figureAnchors(edits)
        let oldGaps = textGaps(count: old.lines.count, anchors: anchors.old)
        let newGaps = textGaps(count: new.lines.count, anchors: anchors.new)
        return Result(
            text: hunks(edits, context: max(0, context)),
            figures: compareFigures(
                old.figures, new.figures,
                oldGaps: old.figures.map { oldGaps[$0.textOffset] },
                newGaps: new.figures.map { newGaps[$0.textOffset] }
            )
        )
    }

    private static func align(_ old: [Line], _ new: [Line]) -> [Edit] {
        let difference = new.map(\.block).difference(from: old.map(\.block))
        var removed: Set<Int> = []
        var added: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var edits: [Edit] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) {
                edits.append(Edit(kind: .removed, line: old[i], oldIndex: i, newIndex: j))
                i += 1
            } else if added.contains(j) {
                edits.append(Edit(kind: .added, line: new[j], oldIndex: i, newIndex: j))
                j += 1
            } else {
                edits.append(Edit(kind: .context, line: new[j], oldIndex: i, newIndex: j))
                i += 1
                j += 1
            }
        }
        return edits
    }

    private static func hunks(_ edits: [Edit], context: Int) -> [[Edit]] {
        var ranges: [Range<Int>] = []
        for index in edits.indices where edits[index].kind != .context {
            let start = index - min(index, context)
            let end = index + 1 + min(edits.count - index - 1, context)
            if let last = ranges.last, start <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<end
            } else {
                ranges.append(start..<end)
            }
        }
        return ranges.map { Array(edits[$0]) }
    }

    private static func figureAnchors(_ edits: [Edit]) -> (old: Set<Int>, new: Set<Int>) {
        var old: Set<Int> = []
        var new: Set<Int> = []
        var removed: [Int] = []
        var added: [Int] = []
        func finishRun() {
            if removed.count == 1, added.count == 1 {
                old.insert(removed[0])
                new.insert(added[0])
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for edit in edits {
            switch edit.kind {
            case .context:
                finishRun()
                if edit.line.block != .blank {
                    old.insert(edit.oldIndex)
                    new.insert(edit.newIndex)
                }
            case .removed:
                if edit.line.block != .blank { removed.append(edit.oldIndex) }
            case .added:
                if edit.line.block != .blank { added.append(edit.newIndex) }
            }
        }
        finishRun()
        return (old, new)
    }

    private static func textGaps(count: Int, anchors: Set<Int>) -> [Int] {
        var gap = 0
        return (0...count).map { offset in
            if offset > 0 && anchors.contains(offset - 1) { gap += 1 }
            return gap
        }
    }

    private static func compareFigures(
        _ old: [FigurePosition], _ new: [FigurePosition], oldGaps: [Int], newGaps: [Int]
    ) -> [FigureChange] {
        var pairs: [Int: Int] = [:]
        var used: Set<Int> = []
        for requireSameGap in [true, false] {
            for i in old.indices where pairs[i] == nil {
                guard let fingerprint = old[i].fingerprint,
                      let j = new.indices.first(where: {
                          !used.contains($0) && new[$0].fingerprint == fingerprint
                              && (!requireSameGap || oldGaps[i] == newGaps[$0])
                      }) else { continue }
                pairs[i] = j
                used.insert(j)
            }
        }

        var changes: [FigureChange] = []
        for i in old.indices {
            guard let j = pairs[i] else { continue }
            let sameGap = oldGaps[i] == newGaps[j]
            let reordered = sameGap && pairs.contains { other in
                oldGaps[other.key] == oldGaps[i] && newGaps[other.value] == newGaps[j]
                    && ((other.key < i && other.value > j) || (other.key > i && other.value < j))
            }
            if !sameGap || reordered { changes.append(.moved(old[i], new[j])) }
        }

        let unknownOld = old.indices.filter { old[$0].fingerprint == nil }
        let unknownNew = new.indices.filter { new[$0].fingerprint == nil }
        let unknownGaps = Set(unknownOld.map { oldGaps[$0] } + unknownNew.map { newGaps[$0] })
        let unmatchedOld = old.indices.filter { pairs[$0] == nil && old[$0].fingerprint != nil }
        let unmatchedNew = new.indices.filter { !used.contains($0) && new[$0].fingerprint != nil }
        let oldByGap = Dictionary(grouping: unmatchedOld) { oldGaps[$0] }
        let newByGap = Dictionary(grouping: unmatchedNew) { newGaps[$0] }
        for i in unmatchedOld {
            let gap = oldGaps[i]
            if !unknownGaps.contains(gap), oldByGap[gap]?.count == 1,
               let candidates = newByGap[gap], candidates.count == 1, let j = candidates.first {
                changes.append(.replaced(old[i], new[j]))
                used.insert(j)
            } else {
                changes.append(.removed(old[i]))
            }
        }
        for j in unmatchedNew where !used.contains(j) { changes.append(.added(new[j])) }
        if !unknownOld.isEmpty || !unknownNew.isEmpty {
            changes.append(.unverified(old: unknownOld.map { old[$0] }, new: unknownNew.map { new[$0] }))
        }
        return changes
    }
}
