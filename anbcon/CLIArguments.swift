//
//  CLIArguments.swift
//  anbcon
//
//  Created by SITIS on 11/24/26.
//

import Foundation

struct CLIArguments {
    enum Action {
        case setup
        case read(chapter: String?)
        case image(Int)
        case search(BookSearch.Request)
        case wordCount(chapter: String?)
        case stats
    }

    enum Source {
        case workspace(URL)
        case noteTitle(String)
    }

    enum Invocation {
        case help
        case mcp
        case run(source: Source, action: Action)
        case snapshots(workspace: URL, action: SnapshotAction)
        case exportHTML(source: Source, directory: URL)
        case searchNotes(source: Source?, request: NotesSearch.Request, limit: Int, offset: Int)
        case notesContext(reference: String, radius: Int)
    }

    enum SnapshotAction: String {
        case capture = "--snapshot"
        case diff = "--diff"
        case markReviewed = "--mark-reviewed"
    }

    enum ArgumentError: LocalizedError {
        case unknown(String)
        case missingSource
        case conflictingSources
        case missingValue(String)
        case duplicate(String)
        case invalidImageNumber
        case conflictingActions
        case searchRequiresRead
        case missingSearchQuery
        case invalidLimit
        case invalidOffset
        case countDoesNotPage
        case noteRequiresRead
        case snapshotsRequireWorkspace
        case chapterRequiresRead
        case exportRequiresDirectory
        case wordCountRequiresRead
        case wordCountWithSearch
        case notesSearchOptionWithoutSearch
        case radiusWithoutContext
        case invalidNear
        case invalidRadius
        case invalidHitOffset

        var errorDescription: String? {
            switch self {
            case .unknown(let argument): "Unknown argument: \(argument)."
            case .missingSource: "Specify a workspace with -w or a note title with --note."
            case .conflictingSources: "Use -w or --note, not both."
            case .missingValue(let option): "\(option) requires a value."
            case .duplicate(let option): "Specify \(option) only once."
            case .invalidImageNumber: "--image requires a positive figure number."
            case .conflictingActions: "Choose one action. See --help for supported combinations."
            case .searchRequiresRead: "Use -r with -s or -sc."
            case .missingSearchQuery: "Use -s or -sc with a search query."
            case .invalidLimit: "--limit requires a positive number."
            case .invalidOffset: "--offset requires zero or a positive number."
            case .countDoesNotPage: "--limit and --offset do not apply to --count."
            case .noteRequiresRead: "Use --note with -r, --stats, --search-notes, or --export-html."
            case .snapshotsRequireWorkspace: "Snapshot actions require a workspace (-w)."
            case .chapterRequiresRead: "Use -r with -g or --chapter."
            case .exportRequiresDirectory: "Exporting with --note requires a directory after --export-html."
            case .wordCountRequiresRead: "Use -r with --word-count."
            case .wordCountWithSearch: "--word-count counts all words and cannot be combined with search options."
            case .notesSearchOptionWithoutSearch: "Use --and, --titles, --near, and --hit-offset only with --search-notes."
            case .radiusWithoutContext: "Use --radius only with --context."
            case .invalidNear: "--near requires a number from 1 to 8."
            case .invalidRadius: "--radius requires a number from 0 to 8."
            case .invalidHitOffset: "--hit-offset requires zero or a positive number."
            }
        }
    }

    static let version = "1.0.0"

    static let usage = """
    anbcon \(version) — read, search, and export Apple Notes

    Start here
      Link an empty folder to one note. Pick the note from the menu:
        anbcon -w <path>
      Replace <path> with your folder; do not type the angle brackets.
      Quote paths, note titles, or queries that contain spaces.

    Read a book
      Read the whole note:
        anbcon -w <path> -r
      Read only chapter 4:
        anbcon -w <path> -r -g 4

    Count all words (no search query)
      Count the whole note:
        anbcon -w <path> -r --word-count
      Count only chapter 4:
        anbcon -w <path> -r -g 4 --word-count
      Headings count; standalone numbers and figure markers do not.
      Show word, chapter, and figure totals together:
        anbcon -w <path> --stats

    Find or count a search term
      Show every sentence that contains the search text:
        anbcon -w <path> -r -s 'text'
      Show the first five matches in chapter 4:
        anbcon -w <path> -r -g 4 -s 'text' --limit 5
      Show the next five from that chapter:
        anbcon -w <path> -r -g 4 -s 'text' --limit 5 --offset 5
      Count occurrences of the search text, even inside longer words:
        anbcon -w <path> -r -s 'text' -c
      Count only whole-word matches:
        anbcon -w <path> -r -sc 'text'
      To show whole-word matches instead of counting them, use -s with --exact.

    Find information across Notes (no workspace required)
      Find notes by title, accepting either word:
        anbcon --search-notes 'text|alternative' --titles
      Find matching passages in the text of all available notes:
        anbcon --search-notes 'text'
      Require both groups within two consecutive text blocks:
        anbcon --search-notes 'text|alternative' --and 'other' --near 2
      Search just one linked note:
        anbcon -w <path> --search-notes 'text'
      Open a hit and two surrounding blocks on each side:
        anbcon --context <reference> --radius 2
      Default: one excerpt per note, two context blocks per side.
      --limit and --offset page notes; they never shorten the scan.
      --hit-offset 1 shows the second matching passage in each note.

    Save an image or export HTML
      Save figure 3 in the workspace's images folder and open it in Preview:
        anbcon -w <path> --image 3
      Save a standalone HTML file in the workspace:
        anbcon -w <path> --export-html
      Save that HTML in another directory:
        anbcon -w <path> --export-html <directory>
      The HTML filename comes from the note title.

    Review changes
      1. Save the version you have already reviewed:
         anbcon -w <path> --snapshot
         anbcon -w <path> --mark-reviewed
      2. Edit in Notes, then see what changed:
         anbcon -w <path> --diff
      3. Once you have reviewed the changes, accept that snapshot:
         anbcon -w <path> --mark-reviewed
      Reading does not change the review baseline. Marking a snapshot reviewed
      uses the saved version without rereading Notes.

    Work with a note once (no workspace)
      Read by title:
        anbcon --note 'title' -r
      Search by title and query:
        anbcon --note 'title' -r -s 'text'
      Export by title (the destination folder is required):
        anbcon --note 'title' --export-html <directory>

    Long flag names: --workspace, --read, --chapter, --search, --count.
    Start the local MCP server on stdio: anbcon --mcp.
    Show this help: anbcon -h or anbcon --help.
    """

    static func parse(_ arguments: [String]) throws -> Invocation {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            return .help
        }
        if arguments == ["--mcp"] { return .mcp }

        var source: Source?
        var read = false
        var image: Int?
        var snapshotAction: SnapshotAction?
        var exportHTML = false
        var exportDirectory: URL?
        var query: String?
        var chapter: String?
        var exact = false
        var countOnly = false
        var wordCount = false
        var stats = false
        var libraryQuery: String?
        var requiredGroups: [String] = []
        var titlesOnly = false
        var window: Int?
        var hitOffset: Int?
        var contextReference: String?
        var radius: Int?
        var limit: Int?
        var offset: Int?
        var index = 0

        func nextValue(for option: String) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("-"),
                  !arguments[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArgumentError.missingValue(option)
            }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-w", "--workspace":
                guard source == nil else { throw ArgumentError.conflictingSources }
                let path = NSString(string: try nextValue(for: argument)).expandingTildeInPath
                source = .workspace(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
            case "--note":
                guard source == nil else { throw ArgumentError.conflictingSources }
                source = .noteTitle(try nextValue(for: argument).trimmingCharacters(in: .whitespacesAndNewlines))
            case "-r", "--read":
                guard !read else { throw ArgumentError.duplicate("--read") }
                read = true
            case "--image":
                guard image == nil else { throw ArgumentError.duplicate("--image") }
                index += 1
                guard index < arguments.count, let number = Int(arguments[index]), number > 0 else {
                    throw ArgumentError.invalidImageNumber
                }
                image = number
            case "--export-html":
                guard !exportHTML else { throw ArgumentError.duplicate(argument) }
                exportHTML = true
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    let path = NSString(string: try nextValue(for: argument)).expandingTildeInPath
                    exportDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                }
            case "-s", "--search", "-sc":
                guard query == nil else { throw ArgumentError.duplicate("--search") }
                query = try nextValue(for: argument)
                if argument == "-sc" {
                    exact = true
                    countOnly = true
                }
            case "-g", "--chapter":
                guard chapter == nil else { throw ArgumentError.duplicate("--chapter") }
                chapter = try nextValue(for: argument)
            case "--exact":
                exact = true
            case "-c", "--count":
                countOnly = true
            case "--word-count":
                guard !wordCount else { throw ArgumentError.duplicate(argument) }
                wordCount = true
            case "--stats":
                guard !stats else { throw ArgumentError.duplicate(argument) }
                stats = true
            case "--search-notes":
                guard libraryQuery == nil else { throw ArgumentError.duplicate(argument) }
                libraryQuery = try nextValue(for: argument)
            case "--and":
                requiredGroups.append(try nextValue(for: argument))
            case "--titles":
                guard !titlesOnly else { throw ArgumentError.duplicate(argument) }
                titlesOnly = true
            case "--near":
                guard window == nil else { throw ArgumentError.duplicate(argument) }
                guard let value = Int(try nextValue(for: argument)), (1...8).contains(value) else {
                    throw ArgumentError.invalidNear
                }
                window = value
            case "--hit-offset":
                guard hitOffset == nil else { throw ArgumentError.duplicate(argument) }
                guard let value = Int(try nextValue(for: argument)), value >= 0 else {
                    throw ArgumentError.invalidHitOffset
                }
                hitOffset = value
            case "--context":
                guard contextReference == nil else { throw ArgumentError.duplicate(argument) }
                contextReference = try nextValue(for: argument)
            case "--radius":
                guard radius == nil else { throw ArgumentError.duplicate(argument) }
                guard let value = Int(try nextValue(for: argument)), (0...8).contains(value) else {
                    throw ArgumentError.invalidRadius
                }
                radius = value
            case "--limit":
                guard limit == nil else { throw ArgumentError.duplicate(argument) }
                guard let value = Int(try nextValue(for: argument)), value > 0 else {
                    throw ArgumentError.invalidLimit
                }
                limit = value
            case "--offset":
                guard offset == nil else { throw ArgumentError.duplicate(argument) }
                guard let value = Int(try nextValue(for: argument)), value >= 0 else {
                    throw ArgumentError.invalidOffset
                }
                offset = value
            default:
                guard let action = SnapshotAction(rawValue: argument) else { throw ArgumentError.unknown(argument) }
                guard snapshotAction != action else { throw ArgumentError.duplicate(argument) }
                guard snapshotAction == nil else { throw ArgumentError.conflictingActions }
                snapshotAction = action
            }
            index += 1
        }

        let otherAction = read || image != nil || query != nil || chapter != nil || countOnly || wordCount
            || snapshotAction != nil || exportHTML
        let libraryOptions = !requiredGroups.isEmpty || titlesOnly || window != nil || hitOffset != nil
        if let contextReference {
            guard source == nil, libraryQuery == nil, !libraryOptions, !stats, !otherAction, !exact,
                  limit == nil, offset == nil else { throw ArgumentError.conflictingActions }
            return .notesContext(reference: contextReference, radius: radius ?? 2)
        }
        if radius != nil { throw ArgumentError.radiusWithoutContext }
        if let libraryQuery {
            guard !stats, !otherAction else { throw ArgumentError.conflictingActions }
            if titlesOnly, window != nil { throw NotesSearch.SearchError.invalidWindow }
            let groups = ([libraryQuery] + requiredGroups).map { $0.components(separatedBy: "|") }
            let request = NotesSearch.Request(
                groups: groups, field: titlesOnly ? .title : .body, exact: exact,
                window: window ?? 1, hitOffset: hitOffset ?? 0
            )
            return .searchNotes(source: source, request: request, limit: limit ?? 10, offset: offset ?? 0)
        }
        if libraryOptions { throw ArgumentError.notesSearchOptionWithoutSearch }
        guard let source else { throw ArgumentError.missingSource }
        if stats {
            guard !otherAction, !exact, limit == nil, offset == nil else { throw ArgumentError.conflictingActions }
            return .run(source: source, action: .stats)
        }
        if exportHTML {
            guard snapshotAction == nil, !read, image == nil, query == nil, chapter == nil,
                  !exact, !countOnly, !wordCount, limit == nil, offset == nil else { throw ArgumentError.conflictingActions }
            if let exportDirectory { return .exportHTML(source: source, directory: exportDirectory) }
            guard case .workspace(let workspace) = source else { throw ArgumentError.exportRequiresDirectory }
            return .exportHTML(source: source, directory: workspace)
        }
        if let snapshotAction {
            guard case .workspace(let workspace) = source else { throw ArgumentError.snapshotsRequireWorkspace }
            guard !read, image == nil, query == nil, chapter == nil, !exact, !countOnly, !wordCount,
                  limit == nil, offset == nil else { throw ArgumentError.conflictingActions }
            return .snapshots(workspace: workspace, action: snapshotAction)
        }
        if image != nil && read { throw ArgumentError.conflictingActions }
        if wordCount {
            guard read else { throw ArgumentError.wordCountRequiresRead }
            guard query == nil, !exact, !countOnly, limit == nil, offset == nil else {
                throw ArgumentError.wordCountWithSearch
            }
            return .run(source: source, action: .wordCount(chapter: chapter))
        }
        if case .noteTitle = source, !read { throw ArgumentError.noteRequiresRead }
        if let query {
            guard read else { throw ArgumentError.searchRequiresRead }
            if countOnly, limit != nil || offset != nil { throw ArgumentError.countDoesNotPage }
            let request = BookSearch.Request(
                query: query,
                chapter: chapter,
                exact: exact,
                countOnly: countOnly,
                limit: limit,
                offset: offset ?? 0
            )
            return .run(source: source, action: .search(request))
        }
        if exact || countOnly || limit != nil || offset != nil {
            throw ArgumentError.missingSearchQuery
        }
        if chapter != nil && !read { throw ArgumentError.chapterRequiresRead }
        if let image { return .run(source: source, action: .image(image)) }
        return .run(source: source, action: read ? .read(chapter: chapter) : .setup)
    }
}
