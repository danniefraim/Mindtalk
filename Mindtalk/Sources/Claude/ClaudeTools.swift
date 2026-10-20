import Foundation

// MARK: - What the assistant may read, tool by tool
//
// Seven tools, all reading: folders, meetings, one meeting's notes, one meeting's
// text, search, tasks and thoughts. The helper exposes them to the assistant (Claude,
// ChatGPT or any other MCP app; Helper/); the app answers them here, on the main
// thread, from the same stores as its own pages (MeetingStore, MeetingFolders,
// Thoughts) and with the same search engine (MeetingSearch); the words of a query are
// looked for off it, in copies of the text. Nothing is written. Audio and voiceprints
// are never given out.
//
// Every request is checked against ClaudeSharing first: off answers nothing, on reads
// everything Mindtalk has. For every meeting ClaudeSharing.allows decides whether it is
// over and may be read: one being recorded or just ended is never listed and never
// named, an id from one is "No such meeting". Every answer is noted in the log the
// settings card shows.
//
// Text the assistant reads (descriptions, errors, notes) is English and plain. Only
// the log's scope is shown to you: a title or a folder's name as it is, and "all
// meetings", "thoughts" and the refusals as LogScope's marks, put into words when shown.

@MainActor
enum ClaudeTools {
    struct Failure: Error {
        let message: String
        /// Set when the owner's settings said no (off, an id that isn't there):
        /// noted in the log as a LogScope refusal, so the card shows what was asked for and refused.
        var refusal: String? = nil
    }

    static let offMessage = "MCP is switched off in Mindtalk, so nothing can be read. Ask the user to switch it on in Mindtalk under Settings → Integrations → AI apps (Inställningar → Integrationer → AI-program in Swedish)."
    /// A list or a search that didn't fit, or has another page.
    static let moreNote = "More hits than shown: narrow with meeting_id, folder_id, from/to or more specific words, or follow nextCursor where there is one."
    /// A meeting's notes that didn't fit.
    static let moreNotesNote = "Not all notes fit; use mindtalk_search with meeting_id to find a specific one."

    /// The most `limit` gives: meetings and search hits, tasks and thoughts (the
    /// schemas' `maximum` in Helper/ToolCatalog.swift). More is held here and said.
    static let maxLimit = 50
    static let maxLongLimit = 200

    /// About 6 000 tokens for a list, 25 000 characters for a page of text.
    static let listBudget = 24_000
    static let transcriptPage = 25_000
    static let meetingBudget = 30_000

    /// `client`: the program asking, as the bridge saw it ("Claude"), for the log.
    static func handle(tool: String, args raw: [String: Any], client: String? = nil) async throws -> [String: Any] {
        let sharing = ClaudeSharing.shared
        do {
            guard sharing.enabled else { throw refusedOff() }
            // Just started (the helper opens the app when it isn't running): the meetings
            // are still being read from disk. Answered from an empty list, "no meetings"
            // would be a lie, so every tool waits for them. Folders and thoughts are read
            // the moment they are first asked for, on this thread.
            await MeetingStore.shared.ready()
            // Switched off while waiting: nothing is answered.
            guard sharing.enabled else { throw refusedOff() }
            let args = Args(raw)
            let result: [String: Any]
            let scope: String
            let items: Int
            switch tool {
            case "mindtalk_list_folders":
                (result, scope, items) = listFolders()
            case "mindtalk_list_meetings":
                (result, scope, items) = try await listMeetings(args)
            case "mindtalk_get_meeting":
                (result, scope, items) = try getMeeting(args)
            case "mindtalk_get_transcript":
                (result, scope, items) = try getTranscript(args)
            case "mindtalk_search":
                (result, scope, items) = try await search(args)
            case "mindtalk_list_tasks":
                (result, scope, items) = try listTasks(args)
            case "mindtalk_list_thoughts":
                (result, scope, items) = try await listThoughts(args)
            default:
                throw Failure(message: "Unknown tool \"\(tool)\".")
            }
            // Switched off while the words were looked for: nothing is answered.
            guard sharing.enabled else { throw refusedOff() }
            sharing.record(tool: tool, scope: scope, items: items, characters: size(of: result), client: client)
            return result
        } catch let failure as Failure {
            // What was refused is noted too, never with an id: the owner sees that a
            // program asked while MCP was off, or for something that isn't there.
            if let refusal = failure.refusal {
                sharing.record(tool: tool, scope: refusal, items: 0, characters: 0, client: client, refused: true)
            }
            throw failure
        }
    }

    private static func refusedOff() -> Failure {
        Failure(message: offMessage, refusal: LogScope.off)
    }
    /// A whole number from a value read from disk, never a crash: NaN and infinity
    /// become 0, and anything beyond what a meeting could hold is held there.
    nonisolated static func clampedInt(_ d: Double, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int {
        guard d.isFinite else { return 0 }
        return Int(min(max(d.rounded(rule), -1e15), 1e15))
    }

    // MARK: Arguments

    @MainActor struct Args {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }

        /// Given at all: null counts as left out.
        private func given(_ key: String) -> Any? {
            guard let v = raw[key], !(v is NSNull) else { return nil }
            return v
        }
        /// A wrong kind of value is an error that says what was expected, never a guess.
        func string(_ key: String) throws -> String? {
            guard let v = given(key) else { return nil }
            guard let s = v as? String else { throw Failure(message: "\(key) must be a string.") }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        /// true and false come in as numbers (1 and 0): never taken for one.
        private func isBool(_ v: Any) -> Bool {
            guard let n = v as? NSNumber else { return false }
            return CFGetTypeID(n) == CFBooleanGetTypeID()
        }
        /// A whole number. Anything that isn't one (text, NaN, a number too large for
        /// a count, true) is an error, never a crash: Int(1e300) would trap.
        func int(_ key: String) throws -> Int? {
            guard let v = given(key) else { return nil }
            guard !isBool(v) else { throw Failure(message: "\(key) must be a whole number.") }
            if let n = v as? Int { return n }
            let d: Double?
            if let x = v as? Double { d = x } else if let s = v as? String { d = Double(s) } else { d = nil }
            guard let d, d.isFinite, abs(d) < 1e15, d == d.rounded() else {
                throw Failure(message: "\(key) must be a whole number.")
            }
            return Int(d)
        }
        func double(_ key: String) throws -> Double? {
            guard let v = given(key) else { return nil }
            guard !isBool(v) else { throw Failure(message: "\(key) must be a number.") }
            let d: Double?
            if let x = v as? Double { d = x } else if let n = v as? Int { d = Double(n) } else if let s = v as? String { d = Double(s) } else { d = nil }
            guard let d, d.isFinite else { throw Failure(message: "\(key) must be a number.") }
            return d
        }
        /// A list of words, lowercased; one word on its own is allowed.
        func strings(_ key: String) throws -> [String]? {
            guard let v = given(key) else { return nil }
            if let list = v as? [String] { return list.map { $0.lowercased() } }
            if let one = v as? String { return [one.lowercased()] }
            throw Failure(message: "\(key) must be a list of strings.")
        }
        /// 1...max, or the default. Above the max is held at the max (`cappedNote` says
        /// so in the answer); below 1, text or true is an error.
        func limit(_ key: String = "limit", default fallback: Int, max top: Int) throws -> Int {
            if try asked(key, above: top) { return top }
            guard let n = try int(key) else { return fallback }
            guard n >= 1 else { throw Failure(message: "\(key) must be a whole number from 1 to \(top).") }
            return n
        }
        /// A number above `top`, however large (1e300 too): held at the max, not refused.
        private func asked(_ key: String, above top: Int) throws -> Bool {
            guard let v = given(key), !isBool(v) else { return false }
            if let n = v as? Int { return n > top }
            let d: Double?
            if let x = v as? Double { d = x } else if let t = v as? String { d = Double(t) } else { d = nil }
            guard let d, d.isFinite, d > Double(top) else { return false }
            return d >= 1e15 || d == d.rounded()
        }
        /// What the answer says when `limit` was above the max: how many at most, and
        /// how to get the rest (`paged`: there is a nextCursor to follow).
        func cappedNote(_ key: String = "limit", max top: Int, paged: Bool) throws -> String? {
            guard try asked(key, above: top) else { return nil }
            return "\(key) is at most \(top), so at most \(top) are shown. "
                + (paged ? "Follow nextCursor, when there is one, for the next page."
                         : "For other hits, narrow with meeting_id, folder_id, from/to or more specific words.")
        }
        func uuid(_ key: String) throws -> UUID? { try string(key).flatMap(UUID.init) }
        /// An offset from an opaque cursor. `stamp`: what the pages are cut from (the
        /// transcript's filters and length): a cursor from another cut is refused, so
        /// a page never starts in the middle of a different list.
        func offset(stamp: String? = nil) throws -> Int {
            guard let c = try string("cursor") else { return 0 }
            guard let data = Data(base64Encoded: c), let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("o=") else { throw Failure(message: "Invalid cursor. Use the nextCursor from the previous answer.") }
            let fields = text.dropFirst(2).split(separator: ";", maxSplits: 1).map(String.init)
            guard let first = fields.first, let n = Int(first), n >= 0
            else { throw Failure(message: "Invalid cursor. Use the nextCursor from the previous answer.") }
            if let stamp, fields.count < 2 || fields[1] != stamp {
                throw Failure(message: "Invalid cursor, start again without a cursor.")
            }
            return n
        }
        /// "2026-10-19" or "2026-10-19T14:00:00+02:00". `to` as a bare date reaches its end.
        func date(_ key: String, end: Bool = false) throws -> Date? {
            guard let v = given(key) else { return nil }
            guard let s = v as? String else { throw Failure(message: "\(key) must be a string: ISO 8601, for example 2026-10-19.") }
            if let d = ClaudeTools.fullDate.date(from: s) ?? ClaudeTools.fractionalDate.date(from: s) { return d }
            if let d = ClaudeTools.dayOnly.date(from: s) {
                let day = Calendar.current.startOfDay(for: d)
                return end ? Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day : day
            }
            throw Failure(message: "Invalid \(key) \"\(s)\": use ISO 8601, for example 2026-10-19 or 2026-10-19T14:00:00+02:00.")
        }
    }

    static func cursor(offset: Int, stamp: String? = nil) -> String {
        Data(("o=\(offset)" + (stamp.map { ";" + $0 } ?? "")).utf8).base64EncodedString()
    }

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

    /// The meetings the assistant may read, newest first: those ClaudeSharing.allows.
    private static func visibleMeetings() -> [MeetingRecord] {
        let sharing = ClaudeSharing.shared
        let now = Date()
        return MeetingStore.shared.meetings.filter { sharing.allows($0, now: now) }
    }
    private static func visibleFolders() -> [MeetingFolder] { MeetingFolders.shared.folders }
    /// Thoughts as the page shows them: written down, not removed. Newest first.
    private static func liveThoughts() -> [Thought] {
        Thoughts.shared.all.filter { $0.deleted == nil && $0.writing == nil && !$0.text.isEmpty }
            .sorted { $0.date > $1.date }
    }

    private struct Scope {
        var meetings: [MeetingRecord]
        /// What the log says: a title, a folder's name, LogScope.all.
        var label: String
        var meeting: MeetingRecord?
        var folder: MeetingFolder?
    }

    /// `meeting_id`: one meeting. `folder_id`: a folder. Neither: everything shared.
    /// `from`/`to` narrow by the meeting's start. Ids of meetings not yet over are unknown ids.
    private static func scope(_ args: Args, meeting allowMeeting: Bool = true, folder allowFolder: Bool = true) throws -> Scope {
        var out: Scope
        if allowMeeting, try args.string("meeting_id") != nil {
            let m = try meeting(args)
            out = Scope(meetings: [m], label: title(of: m), meeting: m)
        } else if allowFolder, try args.string("folder_id") != nil {
            guard let id = try args.uuid("folder_id"), let folder = visibleFolders().first(where: { $0.id == id }) else {
                throw Failure(message: "No such folder. Use an id from mindtalk_list_folders.", refusal: LogScope.unknownFolder)
            }
            out = Scope(meetings: visibleMeetings().filter { $0.folder == id }, label: folder.name, folder: folder)
        } else {
            out = Scope(meetings: visibleMeetings(), label: LogScope.all)
        }
        if let from = try args.date("from") { out.meetings.removeAll { $0.date < from } }
        if let to = try args.date("to", end: true) { out.meetings.removeAll { $0.date > to } }
        return out
    }

    private static func meeting(_ args: Args) throws -> MeetingRecord {
        guard let id = try args.uuid("meeting_id"), let m = visibleMeetings().first(where: { $0.id == id }) else {
            throw Failure(message: "No such meeting. Use an id from mindtalk_list_meetings or mindtalk_search.", refusal: LogScope.unknownMeeting)
        }
        return m
    }

    // MARK: Pieces of an answer

    static func link(meeting id: UUID, at seconds: Double? = nil) -> String {
        "mindtalk://meeting/\(id.uuidString)" + (seconds.map { "?t=\(clampedInt($0, .down))" } ?? "")
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
            "duration_seconds": clampedInt(seconds(m)),
            "speakers": { let cast = m.cast; return m.speakers.map { cast.name(of: $0) } }(),
            "has_summary": m.summary != nil,
            "has_transcript": !m.words.isEmpty,
            "link": link(meeting: m.id),
        ]
        if let f = MeetingFolders.shared.folder(of: m) { d["folder"] = ["id": f.id.uuidString, "name": f.name] }
        // The gist is the summary's first sentence.
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

    /// The cap's note first, then the note already there (moreNote), as one line.
    private static func note(_ result: inout [String: Any], _ capped: String?) {
        guard let capped else { return }
        result["note"] = [capped, result["note"] as? String].compactMap { $0 }.joined(separator: " ")
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

    /// A query is asked of every meeting and every line: one of thousands of words is
    /// refused, not run.
    static let queryLimit = 500
    static let wordLimit = 32

    /// The query as words, as the app's search splits them, each once.
    private static func words(_ query: String?) throws -> [String] {
        let query = query ?? ""
        guard query.count <= queryLimit else {
            throw Failure(message: "query is too long: at most \(queryLimit) characters. Use a few specific words.")
        }
        var seen = Set<String>()
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard words.count <= wordLimit else {
            throw Failure(message: "query has too many words: at most \(wordLimit). Use a few specific words.")
        }
        return words
    }
    nonisolated private static func has(_ text: String, _ word: String) -> Bool { text.range(of: word, options: .caseInsensitive) != nil }
    nonisolated private static func hasAll(_ text: String, _ words: [String]) -> Bool { words.allSatisfy { has(text, $0) } }

    /// Which of `texts` hold every word, and how many of the words each holds: worked
    /// out off the main thread, in copies of the text, so the app goes on meanwhile.
    nonisolated private static func matches(_ texts: [String], _ words: [String]) async -> [Bool] {
        await Task.detached(priority: .userInitiated) { texts.map { hasAll($0, words) } }.value
    }
    nonisolated private static func ranks(_ texts: [String], _ words: [String]) async -> [Int] {
        await Task.detached(priority: .userInitiated) { texts.map { t in words.reduce(0) { has(t, $1) ? $0 + 1 : $0 } } }.value
    }

    /// The meeting parts a search can look in, as `kinds` names them.
    private enum Part: String, CaseIterable { case summaries, notes, transcripts }

    /// All of a meeting the assistant may match, as one string: the title always, and
    /// of the summary, the notes and marks, and what was said the `parts` given.
    private static func everything(of m: MeetingRecord, parts: Set<Part> = Set(Part.allCases)) -> String {
        var text = [title(of: m)]
        if parts.contains(.summaries) { text += MeetingSearch.summaryLines(of: m).map(\.text) }
        if parts.contains(.notes) { text += m.notes.map(\.text) + m.marks.compactMap(\.text) }
        if parts.contains(.transcripts) { text.append(MeetingSearch.said(of: m)) }
        return text.joined(separator: " ")
    }

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
        return (result, LogScope.all, rows.count)
    }

    // MARK: mindtalk_list_meetings

    private static func listMeetings(_ args: Args) async throws -> ([String: Any], String, Int) {
        let scope = try scope(args, meeting: false)
        var meetings = scope.meetings
        if let query = try args.string("query") {
            // As the app's own search: every word somewhere in the meeting.
            let words = try words(query)
            let keep = await matches(meetings.map { everything(of: $0) }, words)
            meetings = zip(meetings, keep).filter(\.1).map(\.0)
        }
        let limit = try args.limit(default: 20, max: maxLimit)
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
        note(&result, try args.cappedNote(max: maxLimit, paged: true))
        return (result, scope.label, rows.count)
    }

    // MARK: mindtalk_get_meeting

    private static func getMeeting(_ args: Args) throws -> ([String: Any], String, Int) {
        let m = try meeting(args)
        let every = ["summary", "decisions", "tasks", "notes", "marks"]
        let asked = try args.strings("include")
        for part in asked ?? [] where !every.contains(part) {
            throw Failure(message: "Unknown include \"\(part)\": use summary, decisions, tasks, notes or marks.")
        }
        let include = Set(asked ?? every)
        let format = try args.string("response_format")?.lowercased() ?? "concise"
        guard ["concise", "detailed"].contains(format) else { throw Failure(message: "response_format must be concise or detailed.") }
        let detailed = format == "detailed"
        var result = item(m)
        result["date"] = iso.string(from: m.date)
        func moment(_ at: Double?) -> [String: Any] {
            guard let at else { return [:] }
            var d: [String: Any] = ["t_seconds": clampedInt(at), "time": stamp(at)]
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
            if fit(&notes, in: result, key: "notes", budget: meetingBudget) { result["note"] = moreNotesNote }
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

    /// The meeting as turns, grouped anew: the live view keeps a prefix of the meeting
    /// it shows, and a whole transcript read here must not replace it.
    private static func lines(of m: MeetingRecord) -> [Line] {
        let cast = m.cast
        return MeetingText.turnsAllAnew(m.words, pending: []).compactMap { turn in
            guard !turn.text.isEmpty else { return nil }
            let who = turn.speaker.flatMap { $0 >= 0 ? cast.name(of: $0) : nil }
            return Line(at: turn.start, speaker: who, text: turn.text)
        }
    }
    private static func render(_ line: Line) -> String {
        "[\(stamp(line.at))] " + (line.speaker.map { "\($0): " } ?? "") + line.text
    }

    private static func getTranscript(_ args: Args) throws -> ([String: Any], String, Int) {
        let m = try meeting(args)
        var all = lines(of: m)
        let from = try args.double("start_sec"), to = try args.double("end_sec"), who = try args.string("speaker")
        if let from { all.removeAll { $0.at < from } }
        if let to { all.removeAll { $0.at > to } }
        if let who { all.removeAll { !($0.speaker?.localizedCaseInsensitiveContains(who) ?? false) } }
        let rendered = all.map(render)
        // The cut the pages are of: the filters and the meeting's length.
        let stamp = "\(m.words.count)-\(from.map { String($0) } ?? "")-\(to.map { String($0) } ?? "")-\(who?.lowercased() ?? "")"
        let offset = try args.offset(stamp: stamp)
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
            "total_seconds": clampedInt(seconds(m)),
            "total_chars": rendered.reduce(0) { $0 + $1.count + 1 },
            "total_segments": rendered.count,
            "link": link(meeting: m.id, at: all.dropFirst(offset).first?.at),
        ]
        if let first = all.dropFirst(offset).first { result["from_seconds"] = clampedInt(first.at, .down) }
        if i > offset { result["to_seconds"] = clampedInt(all[i - 1].at, .down) }
        if i < rendered.count {
            result["nextCursor"] = cursor(offset: i, stamp: stamp)
            result["note"] = moreNote
        }
        return (result, title(of: m), page.count)
    }

    // MARK: mindtalk_search

    /// A place a search found words: a thought, or a line of a meeting. Matched off
    /// the main thread; made into a hit, with its excerpt, only when it goes back.
    private struct Spot {
        let kind: String
        var part: String? = nil
        let text: String
        var at: Double? = nil
        var speaker: String? = nil
        /// The thought or the meeting it is in, by its place in the search's own list.
        let owner: Int
    }

    private static func search(_ args: Args) async throws -> ([String: Any], String, Int) {
        let words = try words(try args.string("query"))
        guard !words.isEmpty else { throw Failure(message: "query is required: one or more words to look for.") }
        // Everything by default; `kinds` narrows it, as the assistant chooses.
        let kinds = try args.strings("kinds") ?? ["thoughts"] + Part.allCases.map(\.rawValue)
        for kind in kinds where kind != "thoughts" && Part(rawValue: kind) == nil {
            throw Failure(message: "Unknown kind \"\(kind)\": use thoughts, summaries, notes or transcripts.")
        }
        // The meeting parts searched.
        let searched = Set(kinds.compactMap(Part.init(rawValue:)))
        let limit = try args.limit(default: 20, max: maxLimit)
        let inMeetings = try args.string("meeting_id") != nil || args.string("folder_id") != nil
        var spots: [Spot] = []
        var thoughts: [Thought] = []
        var meetings: [MeetingRecord] = []
        var label = LogScope.all

        // Thoughts: every word in the thought. Not when a meeting or a folder is asked about.
        if kinds.contains("thoughts"), !inMeetings {
            let from = try args.date("from"), to = try args.date("to", end: true)
            let pool = liveThoughts().filter { t in
                if let from, t.date < from { return false }
                if let to, t.date > to { return false }
                return true
            }
            for (t, ok) in zip(pool, await matches(pool.map(\.text), words)) where ok {
                spots.append(Spot(kind: "thought", text: t.text, owner: thoughts.count))
                thoughts.append(t)
            }
            if searched.isEmpty { label = LogScope.thoughts }
        }

        if !searched.isEmpty {
            let scope = try scope(args)
            label = scope.label
            // As the app: every word somewhere in the meeting, asked of the whole
            // first (cheap, cached), before any line is ranked.
            let keep = await matches(scope.meetings.map { everything(of: $0, parts: searched) }, words)
            var lines: [Spot] = []
            for (m, ok) in zip(scope.meetings, keep) where ok {
                let owner = meetings.count
                meetings.append(m)
                // The title is shared with the meeting; it counts as the summary's when
                // summaries are searched, else as the notes'.
                if searched.contains(.summaries) {
                    lines.append(Spot(kind: "summary", part: "title", text: title(of: m), owner: owner))
                    lines += MeetingSearch.summaryLines(of: m).map { Spot(kind: "summary", part: $0.kind, text: $0.text, at: $0.at, owner: owner) }
                }
                if searched.contains(.notes) {
                    if !searched.contains(.summaries) { lines.append(Spot(kind: "note", part: "title", text: title(of: m), owner: owner)) }
                    lines += m.notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { Spot(kind: "note", part: "note", text: $0.text, at: $0.at, owner: owner) }
                    lines += m.marks.compactMap { mark in
                        mark.text.map { Spot(kind: "note", part: "mark", text: "\(mark.kind.rawValue): \($0)", at: mark.at, owner: owner) }
                    }
                }
                if searched.contains(.transcripts) {
                    lines += MeetingSearch.sentences(of: m).map { Spot(kind: "transcript", text: $0.text, at: $0.start, speaker: $0.speaker, owner: owner) }
                }
            }
            let rank = await ranks(lines.map(\.text), words)
            // Meeting by meeting: the lines with the most of the words first, then in order.
            var first = 0
            while first < lines.count {
                var end = first
                while end < lines.count, lines[end].owner == lines[first].owner { end += 1 }
                let found = (first..<end).filter { rank[$0] > 0 }.sorted { a, b in
                    rank[a] != rank[b] ? rank[a] > rank[b] : (lines[a].at ?? -1) < (lines[b].at ?? -1)
                }
                spots += found.map { lines[$0] }
                first = end
            }
        }

        let total = spots.count
        var rows: [[String: Any]] = spots.prefix(limit).map { s in
            if s.kind == "thought" {
                let t = thoughts[s.owner]
                return ["kind": "thought", "id": t.id.uuidString, "text": excerpt(t.text, around: words),
                        "date": iso.string(from: t.date), "link": link(thought: t.id)]
            }
            let m = meetings[s.owner]
            var hit: [String: Any] = ["kind": s.kind, "text": excerpt(s.text, around: words), "meeting": brief(m),
                                      "link": link(meeting: m.id, at: s.at)]
            if let part = s.part { hit["part"] = part }
            if let at = s.at { hit["t_seconds"] = clampedInt(at) }
            if let speaker = s.speaker, !speaker.isEmpty { hit["speaker"] = speaker }
            return hit
        }
        var result: [String: Any] = ["total": total]
        let cut = fit(&rows, in: result, key: "hits", budget: listBudget)
        result["hits"] = rows
        if cut || rows.count < total { result["note"] = moreNote }
        note(&result, try args.cappedNote(max: maxLimit, paged: false))
        return (result, label, rows.count)
    }

    // MARK: mindtalk_list_tasks

    private static func listTasks(_ args: Args) throws -> ([String: Any], String, Int) {
        let scope = try scope(args, meeting: false)
        let status = try args.string("status")?.lowercased() ?? "open"
        guard ["open", "done", "all"].contains(status) else { throw Failure(message: "status must be open, done or all.") }
        let owner = try args.string("owner")
        let limit = try args.limit(default: 50, max: maxLongLimit)
        let offset = try args.offset()
        var rows: [[String: Any]] = []
        for m in scope.meetings {
            // The summary's tasks, and the moments you marked as tasks with words the
            // summary didn't take up (as the app's own notes, LibraryContext.notes).
            var tasks: [(text: String, owner: String?, done: Bool, at: Double?)] = []
            if let s = m.summary { tasks = s.tasks.map { ($0.text, $0.owner, $0.done == true, $0.at) } }
            let written = Set(tasks.map { $0.text.lowercased() })
            for mark in m.marks where mark.kind == .task {
                guard let words = mark.text?.trimmingCharacters(in: .whitespaces), !words.isEmpty,
                      !written.contains(words.lowercased()) else { continue }
                tasks.append((words, nil, false, mark.at))
            }
            for t in tasks {
                if status == "open", t.done { continue }
                if status == "done", !t.done { continue }
                if let owner, !(t.owner?.localizedCaseInsensitiveContains(owner) ?? false) { continue }
                var d: [String: Any] = ["task": t.text, "done": t.done, "meeting": brief(m), "link": link(meeting: m.id, at: t.at)]
                if let o = t.owner, !o.isEmpty { d["owner"] = o }
                if let at = t.at { d["t_seconds"] = clampedInt(at) }
                rows.append(d)
            }
        }
        let total = rows.count
        rows = Array(rows.dropFirst(offset).prefix(limit))
        var result: [String: Any] = ["total": total]
        let cut = fit(&rows, in: result, key: "tasks", budget: listBudget)
        result["tasks"] = rows
        if cut || offset + rows.count < total {
            result["nextCursor"] = cursor(offset: offset + rows.count)
            result["note"] = moreNote
        }
        note(&result, try args.cappedNote(max: maxLongLimit, paged: true))
        return (result, scope.label, rows.count)
    }

    // MARK: mindtalk_list_thoughts

    private static func listThoughts(_ args: Args) async throws -> ([String: Any], String, Int) {
        var thoughts = liveThoughts()
        if let from = try args.date("from") { thoughts.removeAll { $0.date < from } }
        if let to = try args.date("to", end: true) { thoughts.removeAll { $0.date > to } }
        let words = try words(try args.string("query"))
        if !words.isEmpty {
            let keep = await matches(thoughts.map(\.text), words)
            thoughts = zip(thoughts, keep).filter(\.1).map(\.0)
        }
        let limit = try args.limit(default: 50, max: maxLongLimit)
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
        note(&result, try args.cappedNote(max: maxLongLimit, paged: true))
        return (result, LogScope.thoughts, rows.count)
    }
}
