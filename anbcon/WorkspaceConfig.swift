//
//   WorkspaceConfig.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

struct WorkspaceConfig: Codable {
    let noteID: String

    enum ConfigError: LocalizedError {
        case notDirectory(String)
        case notEmpty(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .notDirectory(let path): "Workspace is not a directory: \(path)."
            case .notEmpty(let path): "Workspace is not empty and has no config.json: \(path). Use an empty directory."
            case .invalid(let path): "Invalid workspace configuration: \(path)."
            }
        }
    }

    static func load(from workspace: URL) throws -> WorkspaceConfig? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard isDirectory.boolValue else { throw ConfigError.notDirectory(workspace.path) }

        let entries = try fileManager.contentsOfDirectory(atPath: workspace.path)
        guard entries.contains("config.json") else {
            guard entries.allSatisfy({ $0 == ".DS_Store" }) else {
                throw ConfigError.notEmpty(workspace.path)
            }
            return nil
        }

        let file = workspace.appendingPathComponent("config.json")
        let data = try Data(contentsOf: file)
        guard let config = try? JSONDecoder().decode(WorkspaceConfig.self, from: data),
              !config.noteID.isEmpty else {
            throw ConfigError.invalid(file.path)
        }
        return config
    }

    func save(in workspace: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try data.write(to: workspace.appendingPathComponent("config.json"), options: .withoutOverwriting)
    }
}
