//
//  MCPTools.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import CoreFoundation
import CryptoKit
import Foundation

final class MCPTools {
    private typealias Object = [String: Any]
    private typealias Fields = [String: [String: Any]]

    private struct Tool {
        let name: String
        let description: String
        let fields: Fields
        let required: [String]
        let writes: Bool

        var payload: Object {
            [
                "name": name, "description": description,
                "inputSchema": ["type": "object", "properties": fields, "required": required, "additionalProperties": false],
                "annotations": ["readOnlyHint": !writes, "destructiveHint": false, "openWorldHint": false]
            ]
        }
    }

    private enum ToolError: LocalizedError {
        case argument(String)
        case conflict(String)
        case changed
        case oversizedImage

        var errorDescription: String? {
            switch self {
            case .argument(let field): "Missing or invalid argument: \(field)."
            case .conflict(let message): message
            case .changed: "The source changed. Start again at offset 0."
            case .oversizedImage: "The PNG exceeds the inline size limit. For a project, retry with save=true and inline=false."
            }
        }
    }

    private static func string(_ description: String, _ values: [String]? = nil) -> Object {
        var result: Object = ["type": "string", "description": description, "minLength": 1, "maxLength": 4000]
        if let values { result["enum"] = values }
        return result
    }

    private static func number(_ description: String, _ min: Int, _ max: Int) -> Object {
        ["type": "integer", "description": description, "minimum": min, "maximum": max]
    }

    private static func bool(_ description: String) -> Object { ["type": "boolean", "description": description] }

    private static let definitions: [Tool] = {
        let project = string("Explicit project ID or unique name. Otherwise use this chat's selected project.")
        let note = string("Exact note_id from search results. For one-off reads, takes the place of project.")
        let source = ["project": project, "note_id": note]
        let offset = number("Start at this offset (0-based). Use next_offset from the previous result.", 0, Int.max)
        let limit = number("Maximum items to return.", 1, 20)
        let chars = number("Maximum characters in this page (default 2500).", 1, 8000)
        let revision = string("Revision from the previous page; required when offset is positive.")
        let page = ["offset": offset, "chars": chars, "revision": revision]
        func build(_ name: String, _ description: String, _ fields: Fields, required: [String] = [], writes: Bool = false) -> Tool {
            Tool(name: name, description: description, fields: fields, required: required, writes: writes)
        }
        return [
            build("projects", "Find configured workspaces in ~/.Book and ~/.WorkProject. Select only for an explicit work-on request; selection is per chat and does not load the note.", [
                "query": string("A distinctive part of a note title, workspace folder name, or exact project ID."),
                "select": bool("Select a unique match for this chat."),
                "offset": offset, "limit": limit
            ], writes: true),
            build("bind_project", "Explicitly link a Notes result to a new or empty project folder and select it for this chat. Never use for one-off lookup; never rebind a different note.", [
                "note_id": note, "kind": string("Project root.", ["book", "work"]),
                "folder": string("One ASCII folder name (letters, digits, underscores or hyphens), no path.")
            ], required: ["note_id", "kind", "folder"], writes: true),
            build("search_notes", "Find literal matches without dumping notes. Scans the full chosen scope regardless of paging. Return summaries with counts, evidence, context references and coverage. No project is created or switched.", source.merging([
                "scope": string("Default: project if selected, otherwise notes. Use notes or other_notes in a project chat only when explicitly requested.", ["project", "notes", "other_notes"]),
                "field": string("Search titles without accessing bodies, or search parsed body text (default).", ["title", "body"]),
                "groups": ["type": "array", "minItems": 1, "maxItems": 8, "items": string("Literal alternatives separated by |. All groups are required.")],
                "near": number("Required groups may span this many consecutive text blocks in one section (default 1).", 1, 8),
                "exact": bool("Require whole-word/phrase boundaries."),
                "hit_offset": number("Pick a later excerpt within each matching note, starting at 0.", 0, Int.max),
                "limit": limit, "offset": offset
            ]) { _, new in new }, required: ["groups"]),
            build("read_context", "Read original blocks around a search reference. For a title hit, reads opening blocks. Page long results by character offset.", page.merging([
                "reference": string("Exact reference from search_notes."),
                "radius": number("Blocks on each side (default 2).", 0, 8)
            ]) { _, new in new }, required: ["reference"]),
            build("read_note", "Read a chapter or page of original text when short evidence is insufficient. Text is paged and images are not included.", source.merging(page.merging([
                "chapter": string("Chapter number or full heading. Omit to page the entire note.")
            ]) { _, new in new }) { _, new in new }),
            build("stats", "Count words, chapters with and without text, and figures in a note or chapter. Does not return book text.", source.merging([
                "chapter": string("Optional chapter number or heading.")
            ]) { _, new in new }),
            build("count_matches", "Count literal occurrences of a single term in one note or chapter. Returns a number, not sentences or excerpts.", source.merging([
                "query": string("Literal text to count."),
                "chapter": string("Optional chapter number or heading."),
                "exact": bool("Require whole-word/phrase boundaries.")
            ]) { _, new in new }, required: ["query"]),
            build("figure", "Extract one PNG. Return it as an image, save it in the project, or both. No GUI launched.", source.merging([
                "number": number("Figure number starting at 1.", 1, Int.max),
                "save": bool("Save to the workspace's images folder."),
                "inline": bool("Return PNG as MCP image (default true).")
            ]) { _, new in new }, required: ["number"], writes: true),
            build("review", "Capture, compare, or mark the saved snapshot reviewed. Diff refreshes the current snapshot, not the reviewed baseline. Mark reviewed only on the user's instruction.", page.merging([
                "project": project,
                "action": string("Snapshot operation.", ["capture", "diff", "mark_reviewed"])
            ]) { _, new in new }, required: ["action"], writes: true),
            build("export_html", "Write standalone HTML and return its path. Updates a previous export of the same note in place, without numbered copies. Other existing files are not replaced.", source.merging([
                "destination": string("Workspace (default for a project) or Desktop. Required for a one-off note.", ["workspace", "desktop"])
            ]) { _, new in new }, writes: true)
        ]
    }()

    static var catalog: [[String: Any]] { definitions.map(\.payload) }
    static var names: Set<String> { Set(definitions.map(\.name)) }

    private let registry: ProjectRegistry
    private let notes = NotesClient()

    init(registry: ProjectRegistry = ProjectRegistry()) { self.registry = registry }

    func call(_ name: String, _ values: [String: Any], session: String?) throws -> [String: Any] {
        let a = try Arguments(name, values)
        switch name {
        case "projects": return try reply(projects(a, session))
        case "bind_project":
            let id = a.text("note_id")!
            let title = try notes.readTitle(noteID: id)
            let kind = ProjectRegistry.Kind(rawValue: a.text("kind")!)!
            let project = try registry.bind(
                note: .init(id: id, title: title, folder: ""), kind: kind, folder: a.text("folder")!
            )
            registry.select(project, for: session)
            return try reply(["binding": project.payload, "selected_for_chat": session != nil])
        case "search_notes": return try reply(search(a, session))
        case "read_context":
            let context = try NotesSearch.readContext(a.text("reference")!, radius: a.int("radius", 2), readNote: notes.readForExport(noteID:))
            var metadata: Object = ["title": clip(context.title)]
            if let chapter = context.chapter { metadata["chapter"] = clip(chapter) }
            if let first = context.firstBlockNumber { metadata["first_block"] = first }
            return try reply(textPage(context.lines.joined(separator: "\n"), arguments: a, metadata: metadata))
        case "read_note":
            let source = try target(a, session)
            let note = try notes.readForExport(noteID: source.id)
            let book = NotesHTMLParser().parse(note.body)
            let sections = try BookSearch.selectSections(from: book, chapter: a.text("chapter"))
            let text = sections.flatMap(\.blocks).map(\.plainText).joined(separator: "\n")
            return try reply(textPage(text, arguments: a, metadata: ["title": clip(note.title), "note_id": source.id]))
        case "stats":
            let source = try target(a, session)
            let book = NotesHTMLParser().parse(try notes.readBody(noteID: source.id))
            let chapter = a.text("chapter")
            let words = try BookSearch.countWords(in: book, chapter: chapter)
            if let chapter {
                let sections = try BookSearch.selectSections(from: book, chapter: chapter)
                let figures = sections.flatMap(\.blocks).reduce(0) { count, block in
                    if case .figure = block { return count + 1 }
                    return count
                }
                return try reply(["words": words, "figures": figures, "chapter": chapter])
            }
            let stats = book.statistics(wordCount: words)
            return try reply([
                "words": stats.words, "chapters": stats.chaptersWithText + stats.chaptersWithoutText,
                "chapters_with_text": stats.chaptersWithText, "chapters_without_text": stats.chaptersWithoutText,
                "figures": stats.figures
            ])
        case "count_matches":
            let source = try target(a, session)
            let book = NotesHTMLParser().parse(try notes.readBody(noteID: source.id))
            let result = try BookSearch.search(book, request: .init(
                query: a.text("query")!, chapter: a.text("chapter"), exact: a.flag("exact"),
                countOnly: true, limit: nil, offset: 0
            ))
            return try reply(["occurrences": result.occurrences])
        case "figure": return try image(a, session)
        case "review": return try reply(review(a, session))
        case "export_html": return try reply(export(a, session))
        default: throw ToolError.argument("tool")
        }
    }

    private func project(_ a: Arguments, _ session: String?) throws -> ProjectRegistry.Project {
        try registry.resolve(a.text("project"), session: session, notes: notes.listNotes)
    }

    private func target(_ a: Arguments, _ session: String?) throws -> (id: String, workspace: URL?) {
        if let id = a.text("note_id") {
            guard a.text("project") == nil else { throw ToolError.conflict("Use note_id or project, not both.") }
            return (id, nil)
        }
        let selected = try project(a, session)
        return (selected.noteID, selected.workspace)
    }

    private func projects(_ a: Arguments, _ session: String?) throws -> Object {
        let found: [ProjectRegistry.Project]
        var status: Object = [:]
        do {
            found = try registry.list(notes: notes.listNotes())
        } catch {
            found = try registry.list(notes: [])
            status["notes_metadata_error"] = clip(error.localizedDescription)
        }
        let matches = a.text("query").map { registry.matches($0, in: found) } ?? found
        if a.flag("select"), a.text("query") == nil { throw ToolError.argument("query") }
        if a.flag("select") {
            status["selected_for_chat"] = false
            if matches.count == 1, let match = matches.first {
                registry.select(match, for: session)
                status["selected_for_chat"] = session != nil
            }
        }
        if let active = registry.active(for: session) { status["active"] = active.payload }
        status["matched"] = matches.count
        status["projects"] = page(matches, a, count: 8, result: &status).map(\.payload)
        return status
    }

    private func search(_ a: Arguments, _ session: String?) throws -> Object {
        let id = a.text("note_id")
        let defaultScope = a.text("project") != nil || registry.active(for: session) != nil ? "project" : "notes"
        let scope = a.text("scope") ?? defaultScope
        let selected = scope == "project" || scope == "other_notes" ? try project(a, session) : nil
        if let id, let selected, scope == "project", id != selected.noteID {
            throw ToolError.conflict("This note is outside the selected project. Expand the scope only when the user asks.")
        }
        if a.text("project") != nil, scope == "notes" {
            throw ToolError.conflict("Use project scope with a project argument, or omit that argument for Notes-wide search.")
        }
        let candidates: [NotesClient.Note]
        if scope == "project", let selected {
            candidates = [.init(id: selected.noteID, title: try notes.readTitle(noteID: selected.noteID), folder: "")]
        } else if let id {
            if scope == "other_notes", id == selected?.noteID {
                throw ToolError.conflict("The selected project is excluded from other_notes.")
            }
            candidates = [.init(id: id, title: try notes.readTitle(noteID: id), folder: "")]
        } else {
            candidates = try notes.listNotes().filter { scope != "other_notes" || $0.id != selected?.noteID }
        }
        let field: NotesSearch.Field = a.text("field") == "title" ? .title : .body
        let request = NotesSearch.Request(
            groups: a.groups.map { $0.components(separatedBy: "|") }, field: field,
            exact: a.flag("exact"), window: a.int("near", 1), hitOffset: a.int("hit_offset", 0)
        )
        let report = try NotesSearch.search(candidates, request: request, readBody: notes.readBody(noteID:))
        var result: Object = [
            "scope": scope, "field": field == .title ? "title" : "body",
            "checked": report.checked, "total": report.total, "complete": report.failures.isEmpty,
            "matched_notes": report.matches.count, "unreadable": report.failures.count
        ]
        if !report.failures.isEmpty {
            result["failures"] = report.failures.prefix(3).map { ["id": $0.note.id, "error": clip($0.reason)] }
        }
        result["matches"] = page(report.matches, a, count: 5, result: &result).map { match -> Object in
            var item: Object = [
                "note_id": match.note.id, "title": clip(match.note.title), "folder": clip(match.note.folder),
                "matching_passages": match.count
            ]
            if let hit = match.hit {
                item["reference"] = hit.reference
                item["excerpt"] = hit.excerpt
                item["matched_terms"] = hit.terms.map { clip($0, length: 80) }
                if let chapter = hit.chapter { item["chapter"] = clip(chapter) }
                if let block = hit.blockNumber { item["block"] = block }
                if request.hitOffset < match.count - 1 { item["next_hit_offset"] = request.hitOffset + 1 }
            }
            if candidates.count == 1, !match.chapters.isEmpty {
                item["matched_chapters"] = match.chapters.count
                item["chapters"] = match.chapters.prefix(12).map { ["title": clip($0.title, length: 70), "matches": $0.count] }
            }
            return item
        }
        return result
    }

    private func image(_ a: Arguments, _ session: String?) throws -> Object {
        let number = a.int("number", 1)
        let source = try target(a, session)
        let inline = a.flag("inline", default: true)
        let save = a.flag("save")
        guard inline || save else { throw ToolError.conflict("Set inline=true or save=true.") }
        if save, source.workspace == nil { throw BookDocument.FigureError.workspaceRequired }
        let book = NotesHTMLParser().parse(try notes.readBody(noteID: source.id), extractingPNG: number)
        let png = try book.png(for: number)
        if inline, png.count > 8 * 1024 * 1024 { throw ToolError.oversizedImage }
        var info: Object = ["figure": number, "bytes": png.count]
        if save, let workspace = source.workspace {
            info["path"] = try BookDocument.savePNG(png, number: number, in: workspace).path
        }
        return try reply(info, png: inline ? png : nil)
    }

    private func review(_ a: Arguments, _ session: String?) throws -> Object {
        let selected = try project(a, session)
        let store = SnapshotStore(workspace: selected.workspace, noteID: selected.noteID)
        let action = a.text("action")!
        if action != "diff", a.has("offset") || a.has("chars") || a.has("revision") {
            throw ToolError.conflict("Paging options only apply to diff.")
        }
        if action == "mark_reviewed" {
            let reviewed = try store.markReviewed()
            return ["reviewed_at": ISO8601DateFormatter().string(from: reviewed.capturedAt)]
        }
        let reviewed = action == "diff" ? try store.load(.reviewed) : nil
        let continuing = a.text("revision") != nil
        if a.int("offset", 0) > 0, !continuing { throw ToolError.argument("revision") }
        let current: BookSnapshot
        if continuing {
            current = try store.load(.current)
        } else {
            let body = try notes.readBody(noteID: selected.noteID)
            current = try store.saveCurrent(NotesHTMLParser().parse(body, fingerprintingPNGs: true))
        }
        guard let reviewed else {
            return ["captured_at": ISO8601DateFormatter().string(from: current.capturedAt)]
        }
        let diff = BookDiff.compare(reviewed: reviewed, current: current)
        return try textPage(BookDiff.render(diff), arguments: a, metadata: [
            "text_hunks": diff.text.count, "figure_changes": diff.figures.count
        ])
    }

    private func export(_ a: Arguments, _ session: String?) throws -> Object {
        let source = try target(a, session)
        let directory: URL
        if a.text("destination") == "desktop" {
            directory = registry.desktop
        } else {
            guard let workspace = source.workspace else { throw ToolError.argument("destination") }
            directory = workspace
        }
        let note = try notes.readForExport(noteID: source.id)
        let file = try HTMLExporter.destination(for: note.title, in: directory)
        let result = try HTMLExporter.export(note.body, title: note.title, to: file, existing: .replaceOwned, noteID: source.id)
        return ["path": result.file.path, "unavailable_figures": result.unavailableFigures]
    }

    private func page<T>(_ items: [T], _ a: Arguments, count: Int, result: inout Object) -> ArraySlice<T> {
        let offset = min(a.int("offset", 0), items.count)
        let end = offset + min(a.int("limit", count), items.count - offset)
        if end < items.count { result["next_offset"] = end }
        return items[offset..<end]
    }

    private func textPage(_ text: String, arguments a: Arguments, metadata: Object) throws -> Object {
        let revision = Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
        let count = text.count
        let offset = min(a.int("offset", 0), count)
        if a.int("offset", 0) > 0, a.text("revision") == nil { throw ToolError.argument("revision") }
        if let expected = a.text("revision"), expected != revision { throw ToolError.changed }
        let start = text.index(text.startIndex, offsetBy: offset)
        let part = String(text[start...].prefix(a.int("chars", 2500)))
        var result = metadata
        result["text"] = part
        result["revision"] = revision
        result["total_chars"] = count
        let end = offset + part.count
        if end < count { result["next_offset"] = end }
        return result
    }

    private func clip(_ value: String, length: Int = 160) -> String {
        value.count <= length ? value : String(value.prefix(length)) + "…"
    }

    private func reply(_ payload: Object, png: Data? = nil) throws -> Object {
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        var content: [Object] = [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]]
        if let png { content.append(["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]) }
        return ["content": content]
    }

    private struct Arguments {
        let values: Object

        init(_ tool: String, _ values: Object) throws {
            guard let spec = MCPTools.definitions.first(where: { $0.name == tool }) else { throw ToolError.argument("tool") }
            for field in spec.required where values[field] == nil { throw ToolError.argument(field) }
            for (field, value) in values {
                guard let rule = spec.fields[field] else { throw ToolError.argument(field) }
                switch rule["type"] as? String {
                case "string":
                    guard let text = value as? String, Self.valid(text),
                          (rule["enum"] as? [String])?.contains(text) != false else { throw ToolError.argument(field) }
                case "array":
                    guard let strings = value as? [String], (1...8).contains(strings.count),
                          strings.allSatisfy(Self.valid) else { throw ToolError.argument(field) }
                case "integer":
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          let integer = Int(number.stringValue),
                          integer >= (rule["minimum"] as? Int ?? 0),
                          integer <= (rule["maximum"] as? Int ?? Int.max) else { throw ToolError.argument(field) }
                case "boolean":
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        throw ToolError.argument(field)
                    }
                default: throw ToolError.argument(field)
                }
            }
            self.values = values
        }

        func text(_ key: String) -> String? { values[key] as? String }
        func int(_ key: String, _ fallback: Int) -> Int {
            (values[key] as? NSNumber).flatMap { Int($0.stringValue) } ?? fallback
        }
        func flag(_ key: String, default fallback: Bool = false) -> Bool {
            (values[key] as? NSNumber)?.boolValue ?? fallback
        }
        func has(_ key: String) -> Bool { values[key] != nil }
        var groups: [String] { values["groups"] as? [String] ?? [] }

        private static func valid(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 4000 && !value.contains("\0")
        }
    }
}
