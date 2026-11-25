//
//  SnapshotStore.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

struct BookSnapshot: Codable {
    struct Figure: Codable {
        let number: Int
        let fingerprint: String?
    }

    let version: Int
    let noteID: String
    let capturedAt: Date
    let sections: [BookDocument.Section]
    let figures: [Figure]

    init(noteID: String, document: BookDocument) {
        version = 1
        self.noteID = noteID
        capturedAt = Date()
        sections = document.sections
        figures = document.figures.map { Figure(number: $0.number, fingerprint: $0.fingerprint) }
    }
}

struct SnapshotStore {
    enum Slot: String {
        case current
        case reviewed

        var filename: String { "\(rawValue).snapshot.json" }
    }

    enum StoreError: LocalizedError {
        case missing(Slot)
        case invalid(String)
        case noteMismatch(String)
        case workspaceNotConfigured

        var errorDescription: String? {
            switch self {
            case .missing(.current): "No current snapshot. Run --snapshot or --diff first."
            case .missing(.reviewed): "No reviewed snapshot. Run --snapshot, then --mark-reviewed after checking that version."
            case .invalid(let path): "Invalid or unsupported snapshot: \(path)."
            case .noteMismatch(let path): "Snapshot belongs to a different note: \(path)."
            case .workspaceNotConfigured: "Set up the workspace with -w before using snapshots."
            }
        }
    }

    let workspace: URL
    let noteID: String

    func load(_ slot: Slot) throws -> BookSnapshot {
        guard let snapshot = try read(slot) else { throw StoreError.missing(slot) }
        return snapshot
    }

    func saveCurrent(_ document: BookDocument) throws -> BookSnapshot {
        _ = try read(.current)
        let snapshot = BookSnapshot(noteID: noteID, document: document)
        try save(snapshot, to: .current)
        return snapshot
    }

    func markReviewed() throws -> BookSnapshot {
        let snapshot = try load(.current)
        _ = try read(.reviewed)
        try save(snapshot, to: .reviewed)
        return snapshot
    }

    private func read(_ slot: Slot) throws -> BookSnapshot? {
        let file = workspace.appendingPathComponent(slot.filename)
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw StoreError.invalid(file.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(BookSnapshot.self, from: data),
              snapshot.version == 1 else { throw StoreError.invalid(file.path) }
        guard snapshot.noteID == noteID else { throw StoreError.noteMismatch(file.path) }
        let numbers = snapshot.sections.flatMap(\.blocks).compactMap { block -> Int? in
            if case .figure(let number) = block { return number }
            return nil
        }
        guard numbers == snapshot.figures.map(\.number),
              numbers.enumerated().allSatisfy({ $0.element == $0.offset + 1 }),
              snapshot.figures.allSatisfy({ figure in
                  guard let fingerprint = figure.fingerprint else { return true }
                  return Data(base64Encoded: fingerprint)?.count == 32
              }) else { throw StoreError.invalid(file.path) }
        return snapshot
    }

    private func save(_ snapshot: BookSnapshot, to slot: Slot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try data.write(to: workspace.appendingPathComponent(slot.filename), options: .atomic)
    }
}
