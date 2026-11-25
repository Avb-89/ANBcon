//
//  NotesClient.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

struct NotesClient {
    struct Note: Equatable {
        let id: String
        let title: String
        let folder: String
    }

    enum NotesError: LocalizedError {
        case invalidID
        case invalidResponse
        case automationDenied
        case noteNotFound(String)
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidID: "Invalid Apple Notes ID."
            case .invalidResponse: "Apple Notes returned an unexpected result."
            case .automationDenied: "Apple Notes access was denied. Check System Settings > Privacy & Security > Automation for the app that launched anbcon."
            case .noteNotFound: "The note could not be found in Apple Notes. Restore it if it is in Recently Deleted."
            case .scriptFailed(let message): "Apple Notes request failed: \(message)"
            }
        }
    }

    func listNotes() throws -> [Note] {
        let result = try execute("""
        with timeout of 120 seconds
            tell application id "com.apple.Notes"
                set noteRows to {}
                set noteRefs to (get notes)
                repeat with noteRef in noteRefs
                    set currentNote to contents of noteRef
                    set noteID to id of currentNote
                    set noteTitle to name of currentNote
                    set folderName to ""
                    try
                        set noteFolder to container of currentNote
                        set folderName to name of noteFolder
                    end try
                    set end of noteRows to {noteID, noteTitle, folderName}
                end repeat
                return noteRows
            end tell
        end timeout
        """)

        guard result.descriptorType == 0x6C697374 else { throw NotesError.invalidResponse }
        var notes: [Note] = []
        for offset in 0..<result.numberOfItems {
            guard let row = result.atIndex(offset + 1),
                  let id = row.atIndex(1)?.stringValue,
                  let title = row.atIndex(2)?.stringValue,
                  let folder = row.atIndex(3)?.stringValue else {
                throw NotesError.invalidResponse
            }
            notes.append(Note(id: id, title: title, folder: folder))
        }

        return Self.uniqueNotes(notes).sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            if order != .orderedSame { return order == .orderedAscending }
            let folderOrder = $0.folder.localizedStandardCompare($1.folder)
            if folderOrder != .orderedSame { return folderOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    static func uniqueNotes(_ notes: [Note]) -> [Note] {
        var seen: Set<String> = []
        return notes.filter { seen.insert($0.id).inserted }
    }

    func readBody(noteID: String) throws -> String {
        try validateID(noteID)
        let result = try execute("""
        with timeout of 120 seconds
            tell application id "com.apple.Notes"
                return body of note id "\(noteID)"
            end tell
        end timeout
        """, noteID: noteID)
        guard let body = result.stringValue else { throw NotesError.invalidResponse }
        return body
    }

    func readTitle(noteID: String) throws -> String {
        try validateID(noteID)
        let result = try execute("""
        with timeout of 120 seconds
            tell application id "com.apple.Notes"
                return name of note id "\(noteID)"
            end tell
        end timeout
        """, noteID: noteID)
        guard let title = result.stringValue else { throw NotesError.invalidResponse }
        return title
    }

    func readForExport(noteID: String) throws -> (title: String, body: String) {
        try validateID(noteID)
        let result = try execute("""
        with timeout of 120 seconds
            tell application id "com.apple.Notes"
                set currentNote to note id "\(noteID)"
                set noteTitle to name of currentNote
                set noteHTML to body of currentNote
                return {noteTitle, noteHTML}
            end tell
        end timeout
        """, noteID: noteID)
        guard result.descriptorType == 0x6C697374,
              let title = result.atIndex(1)?.stringValue,
              let body = result.atIndex(2)?.stringValue else { throw NotesError.invalidResponse }
        return (title, body)
    }

    func disambiguation(noteID: String) throws -> [String] {
        try validateID(noteID)
        let result = try execute("""
        with timeout of 5 seconds
            tell application id "com.apple.Notes"
                set currentNote to note id "\(noteID)"
                set accountName to ""
                set modifiedLabel to ""
                try
                    set noteContainer to container of currentNote
                    repeat 16 times
                        if class of noteContainer is account then
                            set accountName to name of noteContainer
                            exit repeat
                        else if class of noteContainer is folder then
                            set noteContainer to container of noteContainer
                        else
                            exit repeat
                        end if
                    end repeat
                end try
                try
                    set modifiedLabel to (modification date of currentNote) as text
                end try
                return {accountName, modifiedLabel}
            end tell
        end timeout
        """)
        return [result.atIndex(1)?.stringValue, result.atIndex(2)?.stringValue].compactMap { $0 }
    }

    private func validateID(_ noteID: String) throws {
        guard noteID.range(
            of: #"^x-coredata://[0-9A-Fa-f-]+/ICNote/p[0-9]+\z"#,
            options: .regularExpression
        ) != nil else {
            throw NotesError.invalidID
        }
    }

    static func scriptError(number: Int?, message: String, noteID: String? = nil) -> NotesError {
        if number == -1743 { return .automationDenied }
        if let noteID, number == -1728 { return .noteNotFound(noteID) }
        return .scriptFailed(number.map { "\(message) (\($0))" } ?? message)
    }

    private func execute(_ source: String, noteID: String? = nil) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw NotesError.scriptFailed("Could not create the AppleScript.")
        }
        var details: NSDictionary?
        let result = script.executeAndReturnError(&details)
        if let details {
            let number = (details["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            let message = details["NSAppleScriptErrorMessage"] as? String ?? "Unknown error."
            throw Self.scriptError(number: number, message: message, noteID: noteID)
        }
        return result
    }
}
