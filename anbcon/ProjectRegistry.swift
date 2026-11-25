//
//  ProjectRegistry.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

final class ProjectRegistry {
    enum Kind: String, CaseIterable {
        case book
        case work

        var folder: String { self == .book ? ".Book" : ".WorkProject" }
    }

    struct Project {
        let id: String
        let workspace: URL
        let noteID: String
        let title: String

        var payload: [String: Any] {
            ["project": id, "workspace": workspace.path, "note_id": noteID, "title": title]
        }
    }

    enum RegistryError: LocalizedError {
        case invalidFolder
        case notFound
        case noSelection
        case ambiguous
        case changedBinding
        case existingBinding

        var errorDescription: String? {
            switch self {
            case .invalidFolder: "Use a direct project folder name containing letters, digits, underscores, or hyphens. Symlinks are not allowed."
            case .notFound: "No matching project. Use projects to see the registered workspaces."
            case .noSelection: "No project is selected for this chat. Select one or pass an explicit project."
            case .ambiguous: "More than one project matches. Use its exact project ID."
            case .changedBinding: "The workspace binding changed. Select the project again."
            case .existingBinding: "This workspace is already linked to a different note."
            }
        }
    }

    private let home: URL
    private var selections: [String: Project] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    var desktop: URL { home.appendingPathComponent("Desktop", isDirectory: true) }

    func list(notes: [NotesClient.Note]) throws -> [Project] {
        var titles: [String: String] = [:]
        for note in notes { titles[note.id] = note.title }
        var projects: [Project] = []
        let manager = FileManager.default
        for kind in Kind.allCases {
            let root = home.appendingPathComponent(kind.folder, isDirectory: true)
            guard ordinaryDirectory(root) else { continue }
            let entries = try manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
            )
            for directory in entries where ordinaryDirectory(directory) {
                let file = directory.appendingPathComponent("config.json")
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink == false,
                      let config = try? WorkspaceConfig.load(from: directory) else { continue }
                projects.append(Project(
                    id: "\(kind.rawValue):\(directory.lastPathComponent)", workspace: directory,
                    noteID: config.noteID, title: titles[config.noteID] ?? directory.lastPathComponent
                ))
            }
        }
        return projects.sorted { $0.id < $1.id }
    }

    func matches(_ query: String, in projects: [Project]) -> [Project] {
        let exact = projects.filter {
            [$0.id, $0.title, $0.workspace.lastPathComponent].contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }
        if !exact.isEmpty { return exact }
        return projects.filter {
            [$0.id, $0.title].contains { $0.range(of: query, options: [.caseInsensitive, .literal]) != nil }
        }
    }

    func select(_ project: Project, for session: String?) {
        guard let session else { return }
        selections[session] = project
    }

    func active(for session: String?) -> Project? {
        guard let session else { return nil }
        return selections[session]
    }

    func resolve(_ query: String?, session: String?, notes: () throws -> [NotesClient.Note]) throws -> Project {
        if let query {
            let workspaceMatches = matches(query, in: try list(notes: []))
            let exactID = workspaceMatches.first { $0.id.caseInsensitiveCompare(query) == .orderedSame }
            if let exactID { return try validate(exactID) }
            let found = matches(query, in: try list(notes: notes()))
            guard !found.isEmpty else { throw RegistryError.notFound }
            guard found.count == 1 else { throw RegistryError.ambiguous }
            return try validate(found[0])
        }
        guard let project = active(for: session) else { throw RegistryError.noSelection }
        return try validate(project)
    }

    func bind(note: NotesClient.Note, kind: Kind, folder: String) throws -> Project {
        guard folder.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$"#, options: .regularExpression) != nil else {
            throw RegistryError.invalidFolder
        }
        let root = home.appendingPathComponent(kind.folder, isDirectory: true)
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try allowDirectory(root)
        try allowDirectory(directory)
        if let config = try WorkspaceConfig.load(from: directory) {
            guard config.noteID == note.id else { throw RegistryError.existingBinding }
        } else {
            try WorkspaceConfig(noteID: note.id).save(in: directory)
        }
        return Project(id: "\(kind.rawValue):\(folder)", workspace: directory, noteID: note.id, title: note.title)
    }

    private func validate(_ project: Project) throws -> Project {
        let file = project.workspace.appendingPathComponent("config.json")
        guard ordinaryDirectory(project.workspace),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let config = try WorkspaceConfig.load(from: project.workspace),
              config.noteID == project.noteID else { throw RegistryError.changedBinding }
        return project
    }

    private func ordinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink == false
            && url.resolvingSymlinksInPath().path == url.path
    }

    private func allowDirectory(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, url.resolvingSymlinksInPath().path == url.path,
              !FileManager.default.fileExists(atPath: url.path) || ordinaryDirectory(url) else {
            throw RegistryError.invalidFolder
        }
        let file = url.appendingPathComponent("config.json")
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw RegistryError.invalidFolder
        }
    }
}
