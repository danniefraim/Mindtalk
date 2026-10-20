import Foundation
import MCP

// MARK: - mindtalk on the command line
//
// The same helper, the same socket, the same rules as MCP: `mindtalk meetings`,
// `mindtalk search offerten`, `mindtalk tasks --done` ask the running app exactly as
// an MCP client would, and the app answers while MCP is on and writes every call to
// its log. Nothing is read from disk here.
//
// Plain text by default (one meeting per line, the summary as paragraphs, tasks as
// "[ ] text (owner) · meeting · time"); `--json` prints the tool's answer as it is,
// for scripts and agents. Folders can be named: the name is looked up through
// mindtalk_list_folders. Exit codes: 0; 1 an error from the app (the message on
// stderr); 2 usage; 3 MCP off or the app unreachable (the app's own message).
//
// Help is in English, like the tools: the terminal is where agents and scripts live.
// The values (titles, what was said) come back as they are.

enum Commands {
    static let names = ["folders", "meetings", "meeting", "search", "thoughts", "tasks"]

    // MARK: Run

    static func run(_ arguments: [String]) async -> Int32 {
        guard let name = arguments.first else { return usage(nil) }
        var args = Array(arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") { return usage(name) }
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        do {
            let text: String
            switch name {
            case "folders": text = try await folders(args, json: json)
            case "meetings": text = try await meetings(args, json: json)
            case "meeting": text = try await meeting(args, json: json)
            case "search": text = try await search(args, json: json)
            case "thoughts": text = try await thoughts(args, json: json)
            case "tasks": text = try await tasks(args, json: json)
            default: return usage(nil)
            }
            print(text)
            return 0
        } catch let problem as Usage {
            FileHandle.standardError.write(Data("mindtalk: \(problem.message)\n".utf8))
            return 2
        } catch let failure as BridgeClient.Failure {
            FileHandle.standardError.write(Data("mindtalk: \(failure.message)\n".utf8))
            return failure.message == BridgeClient.off || failure.message == BridgeClient.notRunning ? 3 : 1
        } catch {
            FileHandle.standardError.write(Data("mindtalk: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct Usage: Error { let message: String }

    // MARK: Help

    static let intro = """
        Your meetings and thoughts from Mindtalk, on the command line. Same rules as MCP: \
        Mindtalk must be running with MCP switched on (Settings → Integrations → AI apps), and every \
        call shows in Mindtalk's log.
        """

    private static let help: [String: String] = [
        "folders": """
            mindtalk folders [--json]
              The folders, with how many meetings each holds, and how many
              meetings have no folder. Use a folder's name or id with --folder elsewhere.
            """,
        "meetings": """
            mindtalk meetings [--folder <name|id>] [--from DATE] [--to DATE] [--query WORDS] [--limit N] [--json]
              Meetings, newest first: date, length, title, folder and id.
              --from, --to   ISO 8601 dates (2026-10-01) or moments (2026-10-01T09:00:00+02:00).
              --query        Words that must all occur in the meeting.
              --limit        At most this many (1 to 50; default 20).
            """,
        "meeting": """
            mindtalk meeting <id> [--summary | --tasks | --notes | --text] [--json]
              One meeting. Without a part: the summary, decisions, tasks, notes and marks.
              --summary   Only the summary and the decisions.
              --tasks     Only the tasks.
              --notes     Only your notes and the moments you marked.
              --text      What was said, as "[mm:ss] Speaker: text".
            """,
        "search": """
            mindtalk search <words> [--folder <name|id>] [--meeting <id>] [--from DATE] [--to DATE] [--limit N] [--json]
              Where the words occur: thoughts, summaries, decisions, tasks, notes, marks and what
              was said. Every word must occur in the same meeting or thought.
              --limit     At most this many hits (1 to 50; default 20).
            """,
        "thoughts": """
            mindtalk thoughts [--today] [--from DATE] [--to DATE] [--query WORDS] [--limit N] [--json]
              Your thoughts, newest first. [x] marks one done; "pinned" one you pinned.
              --today     Only today's.
              --limit     At most this many (1 to 200; default 50).
            """,
        "tasks": """
            mindtalk tasks [--open | --done | --all] [--folder <name|id>] [--from DATE] [--to DATE] [--owner NAME] [--limit N] [--json]
              Tasks from the meetings' summaries and the moments marked as tasks, as
              "[ ] text (owner) · meeting · time". Open ones by default.
              --limit     At most this many (1 to 200; default 50).
            """,
    ]

    /// The one-line help for `mindtalk --help`.
    static var summary: String {
        """
        mindtalk \(HelperInfo.version)
        \(intro)

          mindtalk folders                   the folders
          mindtalk meetings [options]        meetings, newest first
          mindtalk meeting <id> [part]       one meeting: summary, tasks, notes or text
          mindtalk search <words> [options]  where words occur, with the moment
          mindtalk thoughts [options]        your thoughts, newest first
          mindtalk tasks [options]           tasks from the meetings
          mindtalk mcp                       start the MCP server (stdio) for Claude, ChatGPT and other MCP apps
          mindtalk --version                 print the version

        --json prints the tool's answer as JSON, for scripts and agents.
        mindtalk <command> --help shows that command's options.
        """
    }

    /// A command's help (exit 0), or the summary when the command isn't one (exit 2).
    static func usage(_ name: String?) -> Int32 {
        if let name, let text = help[name] {
            print(text)
            return 0
        }
        print(summary)
        return 2
    }

    // MARK: The commands

    private static func folders(_ args: [String], json: Bool) async throws -> String {
        let opts = try Options(args, flags: [], valued: [])
        guard opts.words.isEmpty else { throw Usage(message: "folders takes no words. See mindtalk folders --help.") }
        let (value, object) = try await call("mindtalk_list_folders", [:])
        if json { return BridgeClient.json(value) }
        var lines: [String] = []
        for folder in rows(object, "folders") {
            let n = int(folder["meeting_count"])
            lines.append("\(str(folder["name"]))  (\(n) \(n == 1 ? "meeting" : "meetings"))  \(str(folder["id"]))")
        }
        if lines.isEmpty { lines.append("No folders.") }
        lines.append("Meetings without folder: \(int(object["meetings_without_folder"]))")
        return lines.joined(separator: "\n")
    }

    private static func meetings(_ args: [String], json: Bool) async throws -> String {
        let opts = try Options(args, flags: [], valued: ["--folder", "--from", "--to", "--query", "--limit"])
        guard opts.words.isEmpty else { throw Usage(message: "Unexpected \"\(opts.words[0])\". Use --query for words. See mindtalk meetings --help.") }
        var a: [String: Value] = [:]
        if let folder = opts["--folder"] { a["folder_id"] = .string(try await folderID(folder)) }
        if let from = opts["--from"] { a["from"] = .string(from) }
        if let to = opts["--to"] { a["to"] = .string(to) }
        if let q = opts["--query"] { a["query"] = .string(q) }
        if let limit = opts["--limit"] { a["limit"] = .int(try number(limit, "--limit")) }
        let (value, object) = try await call("mindtalk_list_meetings", a)
        if json { return BridgeClient.json(value) }
        var lines = rows(object, "meetings").map(meetingLine)
        if lines.isEmpty { lines.append("No meetings.") }
        if object["nextCursor"] != nil {
            lines.append("More than shown (\(int(object["total"])) in all): raise --limit or narrow with --folder, --from, --to or --query.")
        }
        return lines.joined(separator: "\n")
    }

    private static func meeting(_ args: [String], json: Bool) async throws -> String {
        let opts = try Options(args, flags: ["--summary", "--tasks", "--notes", "--text"], valued: [])
        guard opts.words.count == 1 else { throw Usage(message: "Give one meeting id (from mindtalk meetings). See mindtalk meeting --help.") }
        let id = opts.words[0]
        let parts = ["--summary", "--tasks", "--notes", "--text"].filter { opts.has($0) }
        guard parts.count <= 1 else { throw Usage(message: "Choose one of --summary, --tasks, --notes and --text.") }
        if parts.first == "--text" {
            // Every page, so the whole text comes out at once.
            var segments: [String] = []
            var cursor: String?
            var first: (Value, [String: Any])?
            repeat {
                var a: [String: Value] = ["meeting_id": .string(id)]
                if let cursor { a["cursor"] = .string(cursor) }
                let page = try await call("mindtalk_get_transcript", a)
                if first == nil { first = page }
                segments += (page.1["segments"] as? [String]) ?? []
                cursor = page.1["nextCursor"] as? String
            } while cursor != nil
            guard let first else { return "" }
            if json {
                var whole = first.1
                whole["segments"] = segments
                whole["nextCursor"] = nil
                whole["note"] = nil
                return jsonText(whole)
            }
            let meeting = first.1["meeting"] as? [String: Any] ?? [:]
            let head = "\(str(meeting["title"]))  \(when(str(meeting["date"])))  \(duration(int(first.1["total_seconds"])))"
            return ([head, ""] + (segments.isEmpty ? ["(nothing said)"] : segments)).joined(separator: "\n")
        }
        var a: [String: Value] = ["meeting_id": .string(id), "response_format": .string("detailed")]
        switch parts.first {
        case "--summary": a["include"] = .array([.string("summary"), .string("decisions")])
        case "--tasks": a["include"] = .array([.string("tasks")])
        case "--notes": a["include"] = .array([.string("notes"), .string("marks")])
        default: break
        }
        let (value, object) = try await call("mindtalk_get_meeting", a)
        if json { return BridgeClient.json(value) }
        var out: [String] = []
        var head = "\(str(object["title"]))  \(when(str(object["start"])))  \(duration(int(object["duration_seconds"])))"
        if let folder = object["folder"] as? [String: Any] { head += "  [\(str(folder["name"]))]" }
        out.append(head)
        let speakers = object["speakers"] as? [String] ?? []
        if !speakers.isEmpty { out.append("Speakers: " + speakers.joined(separator: ", ")) }
        out.append("Link: \(str(object["link"]))")
        if let summary = object["summary"] as? [String: Any] {
            out.append("")
            out.append("Summary")
            let overview = str(summary["overview"])
            out.append(overview.isEmpty ? "(none)" : overview)
            let points = (summary["points"] as? [[String: Any]] ?? []).map { "  · \(str($0["text"]))\(at($0))" }
            if !points.isEmpty { out.append(""); out += points }
        } else if parts.isEmpty || parts.first == "--summary" {
            out.append("")
            out.append("Summary: none yet.")
        }
        func section(_ title: String, _ key: String, _ line: ([String: Any]) -> String) {
            guard let list = object[key] as? [[String: Any]] else { return }
            out.append("")
            out.append(title)
            out += list.isEmpty ? ["  (none)"] : list.map { "  " + line($0) }
        }
        section("Decisions", "decisions") { "· \(str($0["text"]))\(at($0))" }
        section("Tasks", "tasks") { "\(box($0["done"])) \(str($0["text"]))\(owner($0))\(at($0))" }
        section("Notes", "notes") { "· \(str($0["text"]))\(at($0))" }
        section("Marks", "marks") { "· \(str($0["kind"])): \(str($0["text"]))\(at($0))" }
        if let note = object["note"] as? String { out.append(""); out.append(note) }
        return out.joined(separator: "\n")
    }

    private static func search(_ args: [String], json: Bool) async throws -> String {
        let opts = try Options(args, flags: [], valued: ["--folder", "--meeting", "--from", "--to", "--limit"])
        guard !opts.words.isEmpty else { throw Usage(message: "Give one or more words to search for. See mindtalk search --help.") }
        var a: [String: Value] = ["query": .string(opts.words.joined(separator: " "))]
        if let folder = opts["--folder"] { a["folder_id"] = .string(try await folderID(folder)) }
        if let meeting = opts["--meeting"] { a["meeting_id"] = .string(meeting) }
        if let from = opts["--from"] { a["from"] = .string(from) }
        if let to = opts["--to"] { a["to"] = .string(to) }
        if let limit = opts["--limit"] { a["limit"] = .int(try number(limit, "--limit")) }
        let (value, object) = try await call("mindtalk_search", a)
        if json { return BridgeClient.json(value) }
        var lines: [String] = []
        for hit in rows(object, "hits") {
            var place: [String] = []
            if let meeting = hit["meeting"] as? [String: Any] {
                place.append(str(meeting["title"]))
                if let t = hit["t_seconds"] as? Int { place.append(clock(t)) }
                if let speaker = hit["speaker"] as? String, !speaker.isEmpty { place.append(speaker) }
            } else {
                place.append(day(str(hit["date"])))
            }
            var kind = str(hit["kind"])
            if let part = hit["part"] as? String, !part.isEmpty { kind += "/" + part }
            lines.append("\(kind)  \(place.joined(separator: " · "))\n  \(str(hit["text"]).replacingOccurrences(of: "\n", with: " "))\n  \(str(hit["link"]))")
        }
        if lines.isEmpty { lines.append("No hits.") }
        if object["note"] != nil {
            lines.append("More hits than shown (\(int(object["total"])) in all): raise --limit or narrow with --folder, --meeting, --from, --to or more specific words.")
        }
        return lines.joined(separator: "\n")
    }

    private static func thoughts(_ args: [String], json: Bool) async throws -> String {
        let opts = try Options(args, flags: ["--today"], valued: ["--from", "--to", "--query", "--limit"])
        guard opts.words.isEmpty else { throw Usage(message: "Unexpected \"\(opts.words[0])\". Use --query for words. See mindtalk thoughts --help.") }
        var a: [String: Value] = [:]
        if opts.has("--today") {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            a["from"] = .string(f.string(from: Date()))
        }
        if let from = opts["--from"] { a["from"] = .string(from) }
        if let to = opts["--to"] { a["to"] = .string(to) }
        if let q = opts["--query"] { a["query"] = .string(q) }
        if let limit = opts["--limit"] { a["limit"] = .int(try number(limit, "--limit")) }
        let (value, object) = try await call("mindtalk_list_thoughts", a)
        if json { return BridgeClient.json(value) }
        var lines = rows(object, "thoughts").map { t -> String in
            var line = "\(box(t["done"])) \(when(str(t["date"])))  \(str(t["text"]).replacingOccurrences(of: "\n", with: " "))"
            if t["pinned"] as? Bool == true { line += "  · pinned" }
            return line + "  \(str(t["id"]))"
        }
        if lines.isEmpty { lines.append("No thoughts.") }
        if object["nextCursor"] != nil { lines.append("More than shown (\(int(object["total"])) in all): raise --limit or narrow with --from, --to or --query.") }
        return lines.joined(separator: "\n")
    }

    private static func tasks(_ args: [String], json: Bool) async throws -> String {
        let opts = try Options(args, flags: ["--open", "--done", "--all"], valued: ["--folder", "--from", "--to", "--owner", "--limit"])
        guard opts.words.isEmpty else { throw Usage(message: "Unexpected \"\(opts.words[0])\". See mindtalk tasks --help.") }
        let states = ["--open", "--done", "--all"].filter { opts.has($0) }
        guard states.count <= 1 else { throw Usage(message: "Choose one of --open, --done and --all.") }
        var a: [String: Value] = [:]
        if let state = states.first { a["status"] = .string(String(state.dropFirst(2))) }
        if let folder = opts["--folder"] { a["folder_id"] = .string(try await folderID(folder)) }
        if let from = opts["--from"] { a["from"] = .string(from) }
        if let to = opts["--to"] { a["to"] = .string(to) }
        if let owner = opts["--owner"] { a["owner"] = .string(owner) }
        if let limit = opts["--limit"] { a["limit"] = .int(try number(limit, "--limit")) }
        let (value, object) = try await call("mindtalk_list_tasks", a)
        if json { return BridgeClient.json(value) }
        var lines = rows(object, "tasks").map { t -> String in
            var line = "\(box(t["done"])) \(str(t["task"]))\(owner(t))"
            if let meeting = t["meeting"] as? [String: Any] {
                line += " · \(str(meeting["title"])) \(day(str(meeting["date"])))"
                if let s = t["t_seconds"] as? Int { line += " · \(clock(s))" }
            }
            return line
        }
        if lines.isEmpty { lines.append(states.first == "--done" ? "No tasks done." : "No tasks.") }
        if object["nextCursor"] != nil { lines.append("More than shown (\(int(object["total"])) in all): raise --limit or narrow with --folder, --from, --to or --owner.") }
        return lines.joined(separator: "\n")
    }

    // MARK: The app

    /// One tool call, the answer both as the SDK's Value (for --json) and as a dictionary.
    private static func call(_ tool: String, _ args: [String: Value]) async throws -> (Value, [String: Any]) {
        switch await BridgeClient.call(tool: tool, arguments: args) {
        case .success(let value):
            let object = (try? JSONSerialization.jsonObject(with: Data(BridgeClient.json(value).utf8))) as? [String: Any] ?? [:]
            return (value, object)
        case .failure(let failure):
            throw failure
        }
    }

    /// A folder by name (case does not matter) or id, through the app's list.
    private static func folderID(_ nameOrID: String) async throws -> String {
        let (_, object) = try await call("mindtalk_list_folders", [:])
        let folders = rows(object, "folders")
        if let byID = folders.first(where: { str($0["id"]) == nameOrID }) { return str(byID["id"]) }
        if let byName = folders.first(where: { str($0["name"]).compare(nameOrID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return str(byName["id"])
        }
        let names = folders.map { str($0["name"]) }
        throw BridgeClient.Failure(message: "No folder named \"\(nameOrID)\"." + (names.isEmpty ? "" : " Folders: " + names.joined(separator: ", ") + "."))
    }

    // MARK: Arguments

    /// `--flag`, `--option value`, and the words that are neither.
    struct Options {
        private(set) var words: [String] = []
        private var flags: Set<String> = []
        private var values: [String: String] = [:]

        init(_ args: [String], flags known: [String], valued: [String]) throws {
            var i = 0
            while i < args.count {
                let arg = args[i]
                if known.contains(arg) {
                    flags.insert(arg)
                } else if valued.contains(arg) {
                    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw Usage(message: "\(arg) needs a value.") }
                    // --query takes every following word up to the next option.
                    if arg == "--query" {
                        var taken: [String] = []
                        while i + 1 < args.count, !args[i + 1].hasPrefix("--") { taken.append(args[i + 1]); i += 1 }
                        values[arg] = taken.joined(separator: " ")
                    } else {
                        values[arg] = args[i + 1]
                        i += 1
                    }
                } else if arg.hasPrefix("--") {
                    throw Usage(message: "Unknown option \(arg). See --help.")
                } else {
                    words.append(arg)
                }
                i += 1
            }
        }

        func has(_ flag: String) -> Bool { flags.contains(flag) }
        subscript(_ option: String) -> String? { values[option] }
    }

    private static func number(_ text: String, _ option: String) throws -> Int {
        guard let n = Int(text), n > 0 else { throw Usage(message: "\(option) needs a whole number above 0.") }
        return n
    }

    // MARK: Words

    private static func rows(_ object: [String: Any], _ key: String) -> [[String: Any]] { object[key] as? [[String: Any]] ?? [] }
    private static func str(_ any: Any?) -> String { any as? String ?? "" }
    private static func int(_ any: Any?) -> Int { any as? Int ?? 0 }
    private static func box(_ done: Any?) -> String { done as? Bool == true ? "[x]" : "[ ]" }
    private static func owner(_ item: [String: Any]) -> String {
        guard let who = item["owner"] as? String, !who.isEmpty else { return "" }
        return " (\(who))"
    }
    private static func at(_ item: [String: Any]) -> String {
        guard let t = item["t_seconds"] as? Int else { return "" }
        return " · \(clock(t))"
    }

    private static func meetingLine(_ m: [String: Any]) -> String {
        var line = "\(when(str(m["start"])))  \(duration(int(m["duration_seconds"])))  \(str(m["title"]))"
        if let folder = m["folder"] as? [String: Any] { line += "  [\(str(folder["name"]))]" }
        return line + "  \(str(m["id"]))"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ text: String) -> Date? { iso.date(from: text) ?? isoWithFraction.date(from: text) }

    /// "2026-10-14 10:00" in the user's time zone; the text as it was when it isn't a date.
    static func when(_ text: String) -> String {
        guard let d = date(text) else { return text }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func day(_ text: String) -> String {
        guard let d = date(text) else { return text }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "1 h 5 min", "45 min", "30 s".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "12:04", "1:02:04".
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
