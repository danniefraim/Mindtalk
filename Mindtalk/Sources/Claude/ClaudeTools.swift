import Foundation

// MARK: - What the assistant may read, tool by tool
//
// Seven tools, all reading: folders, meetings, one meeting's notes, one meeting's
// text, search, tasks and thoughts. The helper exposes them to the assistant (Claude,
// ChatGPT or any other MCP app; Helper/); the app answers them here, on the main
// thread, from the same stores as its own pages (MeetingStore, MeetingFolders,
// Thoughts) and with the same search engine (MeetingSearch). Nothing is written.
// Audio and voiceprints are never given out.
//
// Every request is checked against ClaudeSharing first: off, the level, and the
// folders kept away, which are never listed and never named: an id from one is
// "No such meeting". Every answer is noted in the log the settings card shows.
//
// Text the assistant reads (descriptions, errors, notes) is English and plain. Only
// the log's scope is shown to you, so only it goes through the catalog.

@MainActor
enum ClaudeTools {
    struct Failure: Error { let message: String }

    static let offMessage = "Sharing is switched off in Mindtalk. Turn it on in Mindtalk under Settings → Integrations → MCP."
    static let moreNote = "More available: narrow with from/to, folder_id or query, or follow nextCursor."
    private static let meetingsLevelMessage =
        "Meetings are not shared: the level in Mindtalk under Settings → Integrations → MCP is \"Only thoughts\". Thoughts can be read with mindtalk_list_thoughts and mindtalk_search."
    private static let transcriptsLevelMessage =
        "Transcripts are not shared: the level in Mindtalk under Settings → Integrations → MCP is \"Thoughts and summaries\". Use mindtalk_get_meeting for the summary, decisions and tasks, or mindtalk_search."

    /// About 6 000 tokens for a list, 25 000 characters for a page of text.
    static let listBudget = 24_000
    static let transcriptPage = 25_000
    static let meetingBudget = 30_000

    static func handle(tool: String, args raw: [String: Any]) async throws -> [String: Any] {
        let sharing = ClaudeSharing.shared
        guard sharing.enabled else { throw Failure(message: offMessage) }
        // Just started (the helper opens the app when it isn't running): the meetings
        // are still being read from disk. Answered from an empty list, "no meetings"
        // would be a lie, so every tool waits for them. Folders and thoughts are read
        // the moment they are first asked for, on this thread.
        await MeetingStore.shared.ready()
        let args = Args(raw)
        let result: [String: Any]
        let scope: String
        let items: Int
        switch tool {
        case "mindtalk_list_folders":
            try requireMeetings()
            (result, scope, items) = listFolders()
        case "mindtalk_list_meetings":
            try requireMeetings()
            (result, scope, items) = try listMeetings(args)
        case "mindtalk_get_meeting":
            try requireMeetings()
            (result, scope, items) = try getMeeting(args)
        case "mindtalk_get_transcript":
            try requireMeetings()
            guard sharing.level.includesTranscripts else { throw Failure(message: transcriptsLevelMessage) }
            (result, scope, items) = try getTranscript(args)
        case "mindtalk_search":
            (result, scope, items) = try search(args)
        case "mindtalk_list_tasks":
            try requireMeetings()
            (result, scope, items) = try listTasks(args)
        case "mindtalk_list_thoughts":
            (result, scope, items) = try listThoughts(args)
        default:
            throw Failure(message: "Unknown tool \"\(tool)\".")
        }
        sharing.record(tool: tool, scope: scope, items: items, characters: size(of: result))
        return result
    }

    private static func requireMeetings() throws {
        guard ClaudeSharing.shared.level.includesMeetings else { throw Failure(message: meetingsLevelMessage) }
    }

    // MARK: Arguments

    @MainActor struct Args {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }

        func string(_ key: String) -> String? {
            guard let s = raw[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func int(_ key: String) -> Int? {
            if let n = raw[key] as? Int { return n }
            if let d = raw[key] as? Double { return Int(d) }
            if let s = raw[key] as? String { return Int(s) }
            return nil
        }
        func double(_ key: String) -> Double? {
            if let d = raw[key] as? Double { return d }
            if let n = raw[key] as? Int { return Double(n) }
            if let s = raw[key] as? String { return Double(s) }
            return nil
        }
        func strings(_ key: String) -> [String]? {
            if let list = raw[key] as? [String] { return list.map { $0.lowercased() } }
            if let one = raw[key] as? String { return [one.lowercased()] }
            return nil
        }
        /// 1...max, or the default.
        func limit(_ key: String = "limit", default fallback: Int, max top: Int) -> Int {
            guard let n = int(key) else { return fallback }
            return min(max(n, 1), top)
        }
        func uuid(_ key: String) -> UUID? { string(key).flatMap(UUID.init) }
        /// An offset from an opaque cursor.
        func offset() throws -> Int {
            guard let c = string("cursor") else { return 0 }
            guard let data = Data(base64Encoded: c), let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("o="), let n = Int(text.dropFirst(2)), n >= 0
            else { throw Failure(message: "Invalid cursor. Use the nextCursor from the previous answer.") }
            return n
        }
        /// "2026-10-19" or "2026-10-19T14:00:00+02:00". `to` as a bare date reaches its end.
        func date(_ key: String, end: Bool = false) throws -> Date? {
            guard let s = string(key) else { return nil }
            if let d = ClaudeTools.fullDate.date(from: s) ?? ClaudeTools.fractionalDate.date(from: s) { return d }
            if let d = ClaudeTools.dayOnly.date(from: s) {
                let day = Calendar.current.startOfDay(for: d)
                return end ? Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day : day
            }
            throw Failure(message: "Invalid \(key) \"\(s)\": use ISO 8601, for example 2026-10-19 or 2026-10-19T14:00:00+02:00.")
        }
    }

    static func cursor(offset: Int) -> String { Data("o=\(offset)".utf8).base64EncodedString() }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    private static let fullDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let fractionalDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .current; return f
    }()

    // MARK: What may be seen

    /// The meetings the assistant may read: not in a folder kept away. Newest first.
    private static func visibleMeetings() -> [MeetingRecord] {
        let sharing = ClaudeSharing.shared
        return MeetingStore.shared.meetings.filter { sharing.allows(folder: $0.folder) }
    }
    private static func visibleFolders() -> [MeetingFolder] {
        let sharing = ClaudeSharing.shared
        return MeetingFolders.shared.folders.filter { sharing.allows(folder: $0.id) }
    }
    /// Thoughts as the page shows them: written down, not removed. Newest first.
    private static func liveThoughts() -> [Thought] {
        Thoughts.shared.all.filter { $0.deleted == nil && $0.writing == nil && !$0.text.isEmpty }
            .sorted { $0.date > $1.date }
    }

    private struct Scope {
        var meetings: [MeetingRecord]
        /// What the log says: a title, a folder's name, "Alla möten".
        var label: String
        var meeting: MeetingRecord?
        var folder: MeetingFolder?
    }

    /// `meeting_id`: one meeting. `folder_id`: a folder. Neither: everything shared.
    /// `from`/`to` narrow by the meeting's start. Ids kept away are unknown ids.
    private static func scope(_ args: Args, meeting allowMeeting: Bool = true, folder allowFolder: Bool = true) throws -> Scope {
        var out: Scope
        if allowMeeting, args.string("meeting_id") != nil {
            let m = try meeting(args)
            out = Scope(meetings: [m], label: title(of: m), meeting: m)
        } else if allowFolder, args.string("folder_id") != nil {
            guard let id = args.uuid("folder_id"), let folder = visibleFolders().first(where: { $0.id == id }) else {
                throw Failure(message: "No such folder.")
            }
            out = Scope(meetings: visibleMeetings().filter { $0.folder == id }, label: folder.name, folder: folder)
        } else {
            out = Scope(meetings: visibleMeetings(), label: String(localized: "Alla möten"))
        }
        if let from = try args.date("from") { out.meetings.removeAll { $0.date < from } }
        if let to = try args.date("to", end: true) { out.meetings.removeAll { $0.date > to } }
        return out
    }

    private static func meeting(_ args: Args) throws -> MeetingRecord {
        guard let id = args.uuid("meeting_id"), let m = visibleMeetings().first(where: { $0.id == id }) else {
            throw Failure(message: "No such meeting.")
        }
        return m
    }

    // MARK: Pieces of an answer

    static func link(meeting id: UUID, at seconds: Double? = nil) -> String {
        "mindtalk://meeting/\(id.uuidString)" + (seconds.map { "?t=\(Int($0.rounded(.down)))" } ?? "")
    }
    static func link(thought id: UUID) -> String { "mindtalk://thought/\(id.uuidString)" }

    private static func title(of m: MeetingRecord) -> String {
        m.title.isEmpty ? MeetingRecord.defaultTitle(for: m.date) : m.title
    }
    private static func seconds(_ m: MeetingRecord) -> Double { m.duration > 0 ? m.duration : (m.words.last?.end ?? 0) }

    private static func stamp(_ t: Double) -> String { MeetingView.duration(t) }

    /// The meeting named in a hit or a task.
    private static func brief(_ m: MeetingRecord) -> [String: Any] {
        ["id": m.id.uuidString, "title": title(of: m), "date": iso.string(from: m.date)]
    }

    /// One row of a meeting list.
    private static func item(_ m: MeetingRecord) -> [String: Any] {
        var d: [String: Any] = [
            "id": m.id.uuidString,
            "title": title(of: m),
            "start": iso.string(from: m.date),
            "duration_seconds": Int(seconds(m).rounded()),
            "speakers": m.speakers.map { m.name(of: $0) },
            "has_summary": m.summary != nil,
            "has_transcript": !m.words.isEmpty,
            "link": link(meeting: m.id),
        ]
        if let f = MeetingFolders.shared.folder(of: m) { d["folder"] = ["id": f.id.uuidString, "name": f.name] }
        if let g = gist(m) { d["gist"] = g }
        return d
    }

    /// One line about the meeting: the first sentence of the summary's overview.
    private static func gist(_ m: MeetingRecord) -> String? {
        guard let overview = m.summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty else { return nil }
        var first = overview
        overview.enumerateSubstrings(in: overview.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { first = s; stop = true }
        }
        return clip(first, limit: 200)
    }

    /// At most `limit` characters, cut at a word.
    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var piece = String(text.prefix(limit))
        if let space = piece.lastIndex(of: " ") { piece = String(piece[..<space]) }
        return piece + "…"
    }

    /// About `limit` characters around the first of `words` found, cut at words.
    static func excerpt(_ text: String, around words: [String], limit: Int = 300) -> String {
        guard text.count > limit + 10 else { return text }
        guard let hit = words.compactMap({ text.range(of: $0, options: .caseInsensitive) }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return clip(text, limit: limit) }
        let from = text.index(hit.lowerBound, offsetBy: -(limit / 3), limitedBy: text.startIndex) ?? text.startIndex
        let to = text.index(from, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        var piece = String(text[from..<to])
        if from != text.startIndex, let space = piece.firstIndex(of: " ") { piece = "…" + piece[piece.index(after: space)...] }
        if to != text.endIndex, let space = piece.lastIndex(of: " ") { piece = String(piece[..<space]) + "…" }
        return piece
    }

    static func size(of object: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: object)).map(\.count) ?? 0
    }

    /// Drops rows from the end until the answer fits the budget. Returns how many stayed.
    private static func fit(_ rows: inout [[String: Any]], in result: [String: Any], key: String, budget: Int) -> Bool {
        var cut = false
        while rows.count > 1 {
            var probe = result
            probe[key] = rows
            if size(of: probe) <= budget { break }
            rows.removeLast(max(1, rows.count / 10))
            cut = true
        }
        return cut
    }

    /// The query as words, as the app's search splits them.
    private static func words(_ query: String?) -> [String] {
        (query ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }
    private static func has(_ text: String, _ word: String) -> Bool { text.range(of: word, options: .caseInsensitive) != nil }
    private static func hasAll(_ text: String, _ words: [String]) -> Bool { words.allSatisfy { has(text, $0) } }

    // MARK: mindtalk_list_folders

    private static func listFolders() -> ([String: Any], String, Int) {
        let meetings = visibleMeetings()
        let folders = visibleFolders().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rows: [[String: Any]] = folders.map { f in
            ["id": f.id.uuidString, "name": f.name, "meeting_count": meetings.filter { $0.folder == f.id }.count]
        }
        let result: [String: Any] = [
            "folders": rows,
            "meetings_without_folder": meetings.filter { $0.folder == nil || MeetingFolders.shared.folder($0.folder) == nil }.count,
        ]
        return (result, String(localized: "Alla möten"), rows.count)
    }

    // MARK: mindtalk_list_meetings

    private static func listMeetings(_ args: Args) throws -> ([String: Any], String, Int) {
        let scope = try scope(args, meeting: false)
        var meetings = scope.meetings
        if let query = args.string("query") {
            // The app's own search: every word somewhere in the meeting.
            meetings = MeetingSearch.find(query, in: meetings, limit: 1).map(\.record)
        }
        let limit = args.limit(default: 20, max: 50)
        let offset = try args.offset()
        let page = Array(meetings.dropFirst(offset).prefix(limit))
        var rows = page.map(item)
        var result: [String: Any] = ["total": meetings.count]
        let cut = fit(&rows, in: result, key: "meetings", budget: listBudget)
        result["meetings"] = rows
        if cut || offset + rows.count < meetings.count {
            result["nextCursor"] = cursor(offset: offset + rows.count)
            result["note"] = moreNote
        }
        return (result, scope.label, rows.count)
    }

    // MARK: mindtalk_get_meeting

    private static func getMeeting(_ args: Args) throws -> ([String: Any], String, Int) {
        let m = try meeting(args)
        let include = Set(args.strings("include") ?? ["summary", "decisions", "tasks", "notes", "marks"])
        let detailed = args.string("response_format")?.lowercased() == "detailed"
        var result = item(m)
        result["date"] = iso.string(from: m.date)
        func moment(_ at: Double?) -> [String: Any] {
            guard let at else { return [:] }
            var d: [String: Any] = ["t_seconds": Int(at.rounded()), "time": stamp(at)]
            if detailed { d["link"] = link(meeting: m.id, at: at) }
            return d
        }
        if let s = m.summary {
            if include.contains("summary") {
                var summary: [String: Any] = ["overview": s.overview, "written": iso.string(from: s.created)]
                if let w = s.writer { summary["written_by"] = w }
                if detailed, !s.points.isEmpty {
                    summary["points"] = s.points.map { ["text": $0.text].merging(moment($0.at)) { a, _ in a } }
                }
                if let from = s.notesFrom, from != m.notesFingerprint { summary["notes_changed_since"] = true }
                result["summary"] = summary
            }
            if include.contains("decisions") {
                result["decisions"] = s.decisions.map { ["text": $0.text].merging(moment($0.at)) { a, _ in a } }
            }
            if include.contains("tasks") {
                result["tasks"] = s.tasks.map { t -> [String: Any] in
                    var d: [String: Any] = ["text": t.text, "done": t.done == true]
                    if let o = t.owner, !o.isEmpty { d["owner"] = o }
                    return d.merging(moment(t.at)) { a, _ in a }
                }
            }
        } else if include.contains("summary") {
            result["summary"] = NSNull()
        }
        if include.contains("notes") {
            var notes = m.notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ["text": $0.text].merging(moment($0.at)) { a, _ in a } }
            if fit(&notes, in: result, key: "notes", budget: meetingBudget) { result["note"] = moreNote }
            result["notes"] = notes
        }
        if include.contains("marks") {
            result["marks"] = m.marks.sorted { $0.at < $1.at }.map { mark -> [String: Any] in
                var d: [String: Any] = ["kind": mark.kind.rawValue]
                if let t = mark.text, !t.isEmpty { d["text"] = t }
                return d.merging(moment(mark.at)) { a, _ in a }
            }
        }
        return (result, title(of: m), 1)
    }

    // MARK: mindtalk_get_transcript

    private struct Line { let at: Double; let speaker: String?; let text: String }

    private static func lines(of m: MeetingRecord) -> [Line] {
        MeetingText.turns(m.words, paragraphs: true).compactMap { turn in
            guard !turn.text.isEmpty else { return nil }
            let who = turn.speaker.flatMap { $0 >= 0 ? m.name(of: $0) : nil }
            return Line(at: turn.start, speaker: who, text: turn.text)
        }
    }
    private static func render(_ line: Line) -> String {
        "[\(stamp(line.at))] " + (line.speaker.map { "\($0): " } ?? "") + line.text
    }

    private static func getTranscript(_ args: Args) throws -> ([String: Any], String, Int) {
        let m = try meeting(args)
        var all = lines(of: m)
        if let from = args.double("start_sec") { all.removeAll { $0.at < from } }
        if let to = args.double("end_sec") { all.removeAll { $0.at > to } }
        if let who = args.string("speaker") {
            all.removeAll { !($0.speaker?.localizedCaseInsensitiveContains(who) ?? false) }
        }
        let rendered = all.map(render)
        let offset = try args.offset()
        var page: [String] = []
        var chars = 0
        var i = offset
        while i < rendered.count, page.isEmpty || chars + rendered[i].count <= transcriptPage {
            page.append(rendered[i])
            chars += rendered[i].count + 1
            i += 1
        }
        var result: [String: Any] = [
            "meeting": brief(m),
            "segments": page,
            "total_seconds": Int(seconds(m).rounded()),
            "total_chars": rendered.reduce(0) { $0 + $1.count + 1 },
            "total_segments": rendered.count,
            "link": link(meeting: m.id, at: all.dropFirst(offset).first?.at),
        ]
        if let first = all.dropFirst(offset).first { result["from_seconds"] = Int(first.at.rounded()) }
        if i > offset { result["to_seconds"] = Int(all[i - 1].at.rounded()) }
        if i < rendered.count {
            result["nextCursor"] = cursor(offset: i)
            result["note"] = moreNote
        }
        return (result, title(of: m), page.count)
    }

    // MARK: mindtalk_search

    private static func search(_ args: Args) throws -> ([String: Any], String, Int) {
        let words = words(args.string("query"))
        guard !words.isEmpty else { throw Failure(message: "query is required: one or more words to look for.") }
        let level = ClaudeSharing.shared.level
        let allowed = ["thoughts"] + (level.includesMeetings ? ["summaries"] : []) + (level.includesTranscripts ? ["transcripts"] : [])
        let kinds = args.strings("kinds") ?? allowed
        for kind in kinds {
            guard ["thoughts", "summaries", "transcripts"].contains(kind) else {
                throw Failure(message: "Unknown kind \"\(kind)\": use thoughts, summaries or transcripts.")
            }
            guard allowed.contains(kind) else {
                throw Failure(message: kind == "transcripts" ? transcriptsLevelMessage : meetingsLevelMessage)
            }
        }
        let limit = args.limit(default: 20, max: 50)
        let inMeetings = args.string("meeting_id") != nil || args.string("folder_id") != nil
        var hits: [[String: Any]] = []
        var label = String(localized: "Alla möten")

        // Thoughts: every word in the thought. Not when a meeting or a folder is asked about.
        if kinds.contains("thoughts"), !inMeetings {
            let from = try args.date("from"), to = try args.date("to", end: true)
            for t in liveThoughts() where hasAll(t.text, words) {
                if let from, t.date < from { continue }
                if let to, t.date > to { continue }
                hits.append(["kind": "thought", "id": t.id.uuidString, "text": excerpt(t.text, around: words),
                             "date": iso.string(from: t.date), "link": link(thought: t.id)])
            }
            if !kinds.contains("summaries"), !kinds.contains("transcripts") { label = String(localized: "Tankar") }
        }

        if kinds.contains("summaries") || kinds.contains("transcripts"), level.includesMeetings {
            let scope = try scope(args)
            label = scope.label
            for m in scope.meetings {
                struct Candidate { let rank: Int; let at: Double?; let hit: [String: Any] }
                var found: [Candidate] = []
                var everything: [String] = []
                func rank(_ text: String) -> Int { words.filter { has(text, $0) }.count }
                if kinds.contains("summaries") {
                    var parts: [(part: String, text: String, at: Double?)] = [("title", title(of: m), nil)]
                    parts += MeetingSearch.summaryLines(of: m).map { ($0.kind, $0.text, $0.at) }
                    parts += m.notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map { ("note", $0.text, $0.at) }
                    parts += m.marks.compactMap { mark in mark.text.map { ("mark", "\(mark.kind.rawValue): \($0)", mark.at) } }
                    everything += parts.map(\.text)
                    for p in parts {
                        let r = rank(p.text)
                        guard r > 0 else { continue }
                        var hit: [String: Any] = ["kind": "summary", "part": p.part, "text": excerpt(p.text, around: words),
                                                  "meeting": brief(m), "link": link(meeting: m.id, at: p.at)]
                        if let at = p.at { hit["t_seconds"] = Int(at.rounded()) }
                        found.append(Candidate(rank: r, at: p.at, hit: hit))
                    }
                }
                if kinds.contains("transcripts"), level.includesTranscripts {
                    let sentences = MeetingSearch.sentences(of: m)
                    everything += sentences.map(\.text)
                    for s in sentences {
                        let r = rank(s.text)
                        guard r > 0 else { continue }
                        var hit: [String: Any] = ["kind": "transcript", "text": excerpt(s.text, around: words), "meeting": brief(m),
                                                  "t_seconds": Int(s.start.rounded()), "link": link(meeting: m.id, at: s.start)]
                        if !s.speaker.isEmpty { hit["speaker"] = s.speaker }
                        found.append(Candidate(rank: r, at: s.start, hit: hit))
                    }
                }
                // As the app: every word somewhere in the meeting, then the lines with the most of them first.
                guard hasAll(everything.joined(separator: " "), words) else { continue }
                found.sort { a, b in a.rank != b.rank ? a.rank > b.rank : (a.at ?? -1) < (b.at ?? -1) }
                hits += found.map(\.hit)
            }
        }

        let total = hits.count
        var rows = Array(hits.prefix(limit))
        var result: [String: Any] = ["total": total]
        let cut = fit(&rows, in: result, key: "hits", budget: listBudget)
        result["hits"] = rows
        if cut || rows.count < total { result["note"] = moreNote }
        return (result, label, rows.count)
    }

    // MARK: mindtalk_list_tasks

    private static func listTasks(_ args: Args) throws -> ([String: Any], String, Int) {
        let scope = try scope(args, meeting: false)
        let status = args.string("status")?.lowercased() ?? "open"
        guard ["open", "done", "all"].contains(status) else { throw Failure(message: "status must be open, done or all.") }
        let owner = args.string("owner")
        var rows: [[String: Any]] = []
        for m in scope.meetings {
            var tasks: [(text: String, owner: String?, done: Bool, at: Double?)] = []
            if let s = m.summary {
                tasks = s.tasks.map { ($0.text, $0.owner, $0.done == true, $0.at) }
            } else {
                // No summary yet: the moments you marked as tasks.
                tasks = m.marks.filter { $0.kind == .task }.compactMap { mark in mark.text.map { ($0, nil, false, mark.at) } }
            }
            for t in tasks {
                if status == "open", t.done { continue }
                if status == "done", !t.done { continue }
                if let owner, !(t.owner?.localizedCaseInsensitiveContains(owner) ?? false) { continue }
                var d: [String: Any] = ["task": t.text, "done": t.done, "meeting": brief(m), "link": link(meeting: m.id, at: t.at)]
                if let o = t.owner, !o.isEmpty { d["owner"] = o }
                if let at = t.at { d["t_seconds"] = Int(at.rounded()) }
                rows.append(d)
            }
        }
        let total = rows.count
        var result: [String: Any] = ["total": total]
        let cut = fit(&rows, in: result, key: "tasks", budget: listBudget)
        result["tasks"] = rows
        if cut { result["note"] = moreNote }
        return (result, scope.label, rows.count)
    }

    // MARK: mindtalk_list_thoughts

    private static func listThoughts(_ args: Args) throws -> ([String: Any], String, Int) {
        var thoughts = liveThoughts()
        if let from = try args.date("from") { thoughts.removeAll { $0.date < from } }
        if let to = try args.date("to", end: true) { thoughts.removeAll { $0.date > to } }
        let words = words(args.string("query"))
        if !words.isEmpty { thoughts.removeAll { !hasAll($0.text, words) } }
        let limit = args.limit(default: 50, max: 200)
        let offset = try args.offset()
        var rows: [[String: Any]] = thoughts.dropFirst(offset).prefix(limit).map { t in
            ["id": t.id.uuidString, "text": t.text, "date": iso.string(from: t.date), "done": t.done, "pinned": t.pinned,
             "link": link(thought: t.id)]
        }
        var result: [String: Any] = ["total": thoughts.count]
        let cut = fit(&rows, in: result, key: "thoughts", budget: listBudget)
        result["thoughts"] = rows
        if cut || offset + rows.count < thoughts.count {
            result["nextCursor"] = cursor(offset: offset + rows.count)
            result["note"] = moreNote
        }
        return (result, String(localized: "Tankar"), rows.count)
    }
}
