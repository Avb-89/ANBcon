import Darwin
import Foundation

func noteLabel(_ note: NotesClient.Note) -> String {
    let title = singleLine(note.title)
    let folder = singleLine(note.folder)
    return "\(title.isEmpty ? "(untitled)" : title) — \(folder.isEmpty ? "(unknown folder)" : folder)"
}

func selectNote(from notes: [NotesClient.Note], using client: NotesClient) -> NotesClient.Note? {
    guard !notes.isEmpty else {
        diagnostic("Apple Notes returned no notes.")
        return nil
    }

    diagnostic("Choose a note:")
    let labels = notes.map(noteLabel)
    let groups = Dictionary(grouping: labels, by: { $0 })
    for (index, label) in labels.enumerated() {
        let note = notes[index]
        if let group = groups[label], group.count > 1 {
            let metadata = (try? client.disambiguation(noteID: note.id)) ?? []
            let details = metadata.map(singleLine).filter { !$0.isEmpty } + [singleLine(note.id)]
            diagnostic("\(index + 1)) \(label) — \(details.joined(separator: " · "))")
        } else {
            diagnostic("\(index + 1)) \(label)")
        }
    }

    while true {
        diagnostic("Note number (0 to cancel): ", terminator: "")
        guard let input = readLine() else { return nil }
        let answer = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer == "0" { return nil }
        if let number = Int(answer), (1...notes.count).contains(number) {
            return notes[number - 1]
        }
        diagnostic("Enter a number from 1 to \(notes.count).")
    }
}

func singleLine(_ value: String) -> String {
    value.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
}

func diagnostic(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

func selectNote(matching title: String, from notes: [NotesClient.Note], using client: NotesClient) -> NotesClient.Note? {
    let matches = notes.filter { $0.title.range(of: title, options: [.caseInsensitive, .literal]) != nil }
    let exact = matches.filter { $0.title.compare(title, options: [.caseInsensitive, .literal]) == .orderedSame }
    let choices = exact.isEmpty ? matches : exact
    if choices.count == 1 { return choices[0] }
    guard !choices.isEmpty else {
        diagnostic("No note titles match: \(singleLine(title)).")
        return nil
    }
    let limit = 12
    if choices.count > limit {
        diagnostic("Showing \(limit) of \(choices.count) matching titles. Refine the title for more specific results.")
    }
    return selectNote(from: Array(choices.prefix(limit)), using: client)
}

func openFigureInPreview(_ file: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", "com.apple.Preview", file.path]
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            diagnostic("The PNG was saved, but Preview could not open it.")
        }
    } catch {
        diagnostic("The PNG was saved, but Preview could not open it: \(error.localizedDescription)")
    }
}

func showNote(_ body: String, action: CLIArguments.Action, workspace: URL? = nil) throws {
    let parser = NotesHTMLParser()
    switch action {
    case .setup:
        print("Read \(body.utf8.count) bytes of Notes HTML.")
    case .read(let chapter):
        let document = parser.parse(body)
        let sections = try BookSearch.selectSections(from: document, chapter: chapter)
        print(sections.flatMap(\.blocks).map(\.plainText).joined(separator: "\n"))
    case .wordCount(let chapter):
        print(try BookSearch.countWords(in: parser.parse(body), chapter: chapter))
    case .stats:
        let document = parser.parse(body)
        let stats = document.statistics(wordCount: try BookSearch.countWords(in: document, chapter: nil))
        print("Words: \(stats.words)")
        print("Chapters: \(stats.chaptersWithText + stats.chaptersWithoutText)")
        print("Chapters with text: \(stats.chaptersWithText)")
        print("Chapters without text: \(stats.chaptersWithoutText)")
        print("Figures: \(stats.figures)")
    case .search(let request):
        let result = try BookSearch.search(parser.parse(body), request: request)
        if request.countOnly {
            print(result.occurrences)
            return
        }
        for hit in result.hits {
            let location = hit.chapter.map { "\(singleLine($0)) · #\(hit.blockNumber)" }
                ?? "#\(hit.blockNumber)"
            print("[\(location)] \(hit.excerpt)")
        }
        if result.occurrences == 0 {
            diagnostic("No matches.")
        } else if result.hits.isEmpty {
            diagnostic("No matching sentences after offset \(request.offset).")
        }
        if let next = result.nextOffset {
            diagnostic("Showing sentences \(request.offset + 1)–\(next) of \(result.matchingSentences). Continue with --offset \(next).")
        }
    case .image(let number):
        guard let workspace else { throw BookDocument.FigureError.workspaceRequired }
        let document = parser.parse(body, extractingPNG: number)
        let png = try document.png(for: number)
        let file = try BookDocument.savePNG(png, number: number, in: workspace)
        print(file.path)
        openFigureInPreview(file)
    }
}

func runSnapshotAction(_ action: CLIArguments.SnapshotAction, in workspace: URL) throws {
    guard let config = try WorkspaceConfig.load(from: workspace) else {
        throw SnapshotStore.StoreError.workspaceNotConfigured
    }
    let store = SnapshotStore(workspace: workspace, noteID: config.noteID)
    if action == .markReviewed {
        let snapshot = try store.markReviewed()
        print("Marked reviewed: \(ISO8601DateFormatter().string(from: snapshot.capturedAt))")
        return
    }
    let reviewed = action == .diff ? try store.load(.reviewed) : nil
    let body = try NotesClient().readBody(noteID: config.noteID)
    let document = NotesHTMLParser().parse(body, fingerprintingPNGs: true)
    let current = try store.saveCurrent(document)
    if let reviewed {
        print(BookDiff.render(BookDiff.compare(reviewed: reviewed, current: current)))
    } else {
        print("Current snapshot saved: \(workspace.appendingPathComponent(SnapshotStore.Slot.current.filename).path)")
    }
}

func runHTMLExport(from source: CLIArguments.Source, in directory: URL) throws {
    let notes = NotesClient()
    let noteID: String
    switch source {
    case .workspace(let workspace):
        guard let config = try WorkspaceConfig.load(from: workspace) else {
            throw HTMLExporter.ExportError.missingWorkspace
        }
        noteID = config.noteID
    case .noteTitle(let requestedTitle):
        guard let selection = try selectNote(matching: requestedTitle, from: notes.listNotes(), using: notes) else {
            return
        }
        noteID = selection.id
    }
    let note = try notes.readForExport(noteID: noteID)
    let file = try HTMLExporter.destination(for: note.title, in: directory)
    var existing: HTMLExporter.ExistingFilePolicy = .refuse
    if FileManager.default.fileExists(atPath: file.path) {
        guard isatty(STDIN_FILENO) == 1 else { throw HTMLExporter.ExportError.fileExists(file.path) }
        diagnostic("Overwrite \(file.lastPathComponent)? [y/N] ", terminator: "")
        guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" else {
            diagnostic("Export cancelled.")
            return
        }
        existing = .replace
    }
    let result = try HTMLExporter.export(note.body, title: note.title, to: file, existing: existing, noteID: noteID)
    if !result.unavailableFigures.isEmpty {
        let labels = result.unavailableFigures.map(BookDocument.figureLabel).joined(separator: ", ")
        diagnostic("No readable embedded PNG for figure(s) \(labels). Placeholders were exported.")
    }
    print(result.file.path)
}

func runNotesSearch(
    source: CLIArguments.Source?, request: NotesSearch.Request, limit: Int, offset: Int
) throws {
    let notes = NotesClient()
    let candidates: [NotesClient.Note]
    switch source {
    case .workspace(let workspace):
        guard let config = try WorkspaceConfig.load(from: workspace) else {
            throw SnapshotStore.StoreError.workspaceNotConfigured
        }
        let title = try notes.readTitle(noteID: config.noteID)
        candidates = [NotesClient.Note(id: config.noteID, title: title, folder: "")]
    case .noteTitle(let title):
        guard let selected = try selectNote(matching: title, from: notes.listNotes(), using: notes) else { return }
        candidates = [selected]
    case nil:
        candidates = try notes.listNotes()
    }

    let report = try NotesSearch.search(candidates, request: request, readBody: notes.readBody(noteID:))
    let field = request.field == .title ? "Titles" : "Note bodies"
    print("\(field) checked: \(report.checked)/\(report.total). Matched notes: \(report.matches.count).")
    if !report.failures.isEmpty {
        diagnostic("Search incomplete: \(report.failures.count) note(s) could not be checked.")
        for failure in report.failures.prefix(5) {
            diagnostic("  \(singleLine(failure.note.title)) [\(singleLine(failure.note.id))]: \(singleLine(failure.reason))")
        }
    }
    let page = report.matches.dropFirst(offset).prefix(limit)
    if page.isEmpty && !report.matches.isEmpty { diagnostic("No matched notes after offset \(offset).") }
    for match in page {
        let title = singleLine(match.note.title)
        let folder = singleLine(match.note.folder)
        print("\n\(folder.isEmpty ? title : "\(title) — \(folder)")")
        print("  ID: \(singleLine(match.note.id))")
        print("  Matching \(request.field == .title ? "titles" : "passages"): \(match.count)")
        if source != nil, !match.chapters.isEmpty {
            let counts = match.chapters.map { "\(singleLine($0.title)): \($0.count)" }
            print("  Chapters: \(counts.joined(separator: "; "))")
        }
        guard let hit = match.hit else {
            print("  No passage at hit offset \(request.hitOffset).")
            continue
        }
        if let block = hit.blockNumber {
            print("  Location: \(BookDiff.locationLabel(.init(chapter: hit.chapter, blockNumber: block)))")
        }
        print("  Matched: \(hit.terms.map(singleLine).joined(separator: ", "))")
        print("  Excerpt: \(singleLine(hit.excerpt))")
        print("  Context: anbcon --context \(hit.reference)")
        if request.hitOffset < match.count - 1 {
            print("  Next passage: --hit-offset \(request.hitOffset + 1)")
        }
    }
    if !page.isEmpty && offset + page.count < report.matches.count {
        diagnostic("More matched notes: continue with --offset \(offset + page.count).")
    }
}

func showSearchContext(reference: String, radius: Int) throws {
    let notes = NotesClient()
    let context = try NotesSearch.readContext(reference, radius: radius, readNote: notes.readForExport(noteID:))
    print(singleLine(context.title))
    if let chapter = context.chapter { print(singleLine(chapter)) }
    for (index, line) in context.lines.enumerated() {
        if let first = context.firstBlockNumber {
            print("[#\(first + index)] \(line)")
        } else {
            print(line)
        }
    }
}

func run(_ invocation: CLIArguments.Invocation) throws {
    switch invocation {
    case .help:
        print(CLIArguments.usage)
    case .mcp:
        try MCPServer().serve()
    case .snapshots(let workspace, let action):
        try runSnapshotAction(action, in: workspace)
    case .exportHTML(let source, let directory):
        try runHTMLExport(from: source, in: directory)
    case .searchNotes(let source, let request, let limit, let offset):
        try runNotesSearch(source: source, request: request, limit: limit, offset: offset)
    case .notesContext(let reference, let radius):
        try showSearchContext(reference: reference, radius: radius)
    case .run(.workspace(let workspace), let action):
        let notes = NotesClient()
        if let config = try WorkspaceConfig.load(from: workspace) {
            switch action {
            case .setup:
                print("Workspace configured: \(workspace.path)")
                print("Use -r to read the saved note.")
            case .read, .image, .search, .wordCount, .stats:
                let body = try notes.readBody(noteID: config.noteID)
                try showNote(body, action: action, workspace: workspace)
            }
            return
        }

        let choices = try notes.listNotes()
        guard let selection = selectNote(from: choices, using: notes) else { return }
        let body = try notes.readBody(noteID: selection.id)
        try WorkspaceConfig(noteID: selection.id).save(in: workspace)
        if case .setup = action {
            print("Saved workspace: \(workspace.path)")
        }
        try showNote(body, action: action, workspace: workspace)
    case .run(.noteTitle(let title), let action):
        let notes = NotesClient()
        guard let selection = try selectNote(matching: title, from: notes.listNotes(), using: notes) else { return }
        let body = try notes.readBody(noteID: selection.id)
        try showNote(body, action: action)
    }
}

func linkedWorkspace(in invocation: CLIArguments.Invocation) -> URL? {
    switch invocation {
    case .run(.workspace(let directory), _),
         .exportHTML(.workspace(let directory), _),
         .searchNotes(.workspace(let directory), _, _, _),
         .snapshots(let directory, _):
        return directory
    default:
        return nil
    }
}

func offerToTrashWorkspace(_ workspace: URL, linkedTo noteID: String) {
    guard isatty(STDIN_FILENO) == 1 else { return }
    let manager = FileManager.default

    func isLinkedWorkspace() -> Bool {
        let path = workspace.path.lowercased()
        guard workspace.resolvingSymlinksInPath().path == workspace.path else { return false }
        let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let current = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true).resolvingSymlinksInPath()
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let protected = [home.path, current.path].map { $0.lowercased() }
        guard !protected.contains(where: { $0 == path || $0.hasPrefix(prefix) }) else { return false }
        let commonFolders = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]
        guard !commonFolders.contains(where: { home.appendingPathComponent($0).path.lowercased() == path }) else {
            return false
        }
        let file = workspace.appendingPathComponent("config.json")
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink == false else { return false }
        return (try? WorkspaceConfig.load(from: workspace))?.noteID == noteID
    }

    guard isLinkedWorkspace() else { return }
    diagnostic("Move workspace \(singleLine(workspace.path)) and all its files to the Trash? [y/N] ", terminator: "")
    guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" else {
        diagnostic("Workspace kept.")
        return
    }
    guard isLinkedWorkspace() else {
        diagnostic("The workspace changed. Nothing was moved to the Trash.")
        return
    }
    do {
        try manager.trashItem(at: workspace, resultingItemURL: nil)
        diagnostic("Workspace moved to the Trash.")
    } catch {
        diagnostic("Could not move the workspace to the Trash: \(error.localizedDescription)")
    }
}

do {
    let invocation = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
    do {
        try run(invocation)
    } catch NotesClient.NotesError.noteNotFound(let noteID) {
        diagnostic("anbcon: \(NotesClient.NotesError.noteNotFound(noteID).localizedDescription)")
        if let workspace = linkedWorkspace(in: invocation) {
            offerToTrashWorkspace(workspace, linkedTo: noteID)
        }
        exit(1)
    }
} catch {
    diagnostic("anbcon: \(error.localizedDescription)")
    exit(error is CLIArguments.ArgumentError ? 2 : 1)
}
