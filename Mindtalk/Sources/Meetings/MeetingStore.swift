import Foundation

// MARK: - Meetings
//
// A meeting in the room: recorded from the Mac's microphone, written out live by
// the same speech model as dictation, with who is speaking told apart by NVIDIA's
// Nemotron 3 Diarization. When it ends, the whole recording is read once more —
// words and speakers — for the final transcript (MeetingSession.swift).
//
// Everything stays on the Mac, in Application Support/Mindtalk/Meetings/<id>/:
//   meeting.json — title, date, the speakers' names, every word with its time
//   audio.caf    — the recording (16 kHz, 16-bit)

/// One word, where it was said, and by whom.
struct MeetingWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    /// Who said it: a speaker number; `unknown` when no one clearly was; nil
    /// while the voices haven't caught up yet.
    var speaker: Int?

    static let unknown = -1
}

struct MeetingRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: Double = 0
    var language: SpeechModel
    var words: [MeetingWord] = []
    /// Names given to speakers ("Anna" for speaker 2).
    var names: [String: String] = [:]
    /// The final pass over the whole recording has run.
    var refined = false
    /// Notes written by Apple Intelligence (MeetingNotes.swift).
    var summary: MeetingSummary?
    var answers: [MeetingAnswer] = []
    /// You named it — the notes don't give it a title then.
    var userTitled = false
    /// Recorded to the end. False while recording — and after a crash or a quit
    /// mid-meeting, when the meeting can still be finished (MeetingSession.finishInterrupted).
    var finished = true
    /// What the final pass changed compared with the live text.
    var heal: Heal?
    /// Stretches you gave to another speaker. Kept by their time, so they hold
    /// when the words are written again (the final pass, the voices catching up).
    var moves: [Move] = []
    /// Your own notes, a line each, with the moment in the meeting you began it
    /// (nil for lines written afterwards). The summary builds on them.
    var notes: [Note] = []
    /// Moments you marked while it ran: a decision, a task, something important.
    var marks: [Mark] = []
    /// When you told the others the meeting is recorded (MeetingConsent).
    var informed: Date?
    /// The recording went to the Trash (kept for a set time, or removed by you);
    /// the text and the notes stay.
    var audioRemoved: Date?
    /// Speakers Mindtalk named itself, from a voice you named before (VoiceMemory),
    /// with how sure it was. Cleared when you name them yourself.
    var recognized: [String: Float] = [:]

    var hasAudio: Bool { audioRemoved == nil }
    var notesText: String { notes.map(\.text).joined(separator: "\n") }

    struct Note: Codable, Equatable {
        var text: String
        var at: Double?
    }

    struct Mark: Codable, Equatable, Identifiable {
        var id = UUID()
        var at: Double
        var kind: Kind

        enum Kind: String, Codable, CaseIterable, Identifiable {
            case decision, task, important
            var id: String { rawValue }
        }
    }

    struct Move: Codable, Equatable {
        var start: Double
        var end: Double
        var speaker: Int
    }

    struct Heal: Codable, Equatable {
        /// Words the final pass wrote differently.
        var words: Int
        /// Turns whose speaker it corrected.
        var speakers: Int
        /// Which words (indices into `words`) are new.
        var changed: [Int]
    }

    init(title: String, date: Date, language: SpeechModel) {
        self.title = title
        self.date = date
        self.language = language
    }

    // Every field but the id may be missing — adding one later never loses a meeting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        language = try c.decodeIfPresent(SpeechModel.self, forKey: .language) ?? .swedish
        words = try c.decodeIfPresent([MeetingWord].self, forKey: .words) ?? []
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        refined = try c.decodeIfPresent(Bool.self, forKey: .refined) ?? false
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        answers = try c.decodeIfPresent([MeetingAnswer].self, forKey: .answers) ?? []
        userTitled = try c.decodeIfPresent(Bool.self, forKey: .userTitled) ?? false
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        heal = try c.decodeIfPresent(Heal.self, forKey: .heal)
        moves = try c.decodeIfPresent([Move].self, forKey: .moves) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
        informed = try c.decodeIfPresent(Date.self, forKey: .informed)
        audioRemoved = try c.decodeIfPresent(Date.self, forKey: .audioRemoved)
        recognized = try c.decodeIfPresent([String: Float].self, forKey: .recognized) ?? [:]
    }

    /// Speakers in the order they first spoke.
    var speakers: [Int] { cast.order }

    /// Who's who, worked out once — views ask it many times per redraw.
    var cast: Cast { Cast(words: words, names: names) }

    /// "Anna", or "Talare 2" — numbered in the order people first spoke.
    func name(of speaker: Int) -> String { cast.name(of: speaker) }

    /// "Möte tisdag 29 september" — the notes replace it with a real title.
    static func defaultTitle(for date: Date) -> String {
        let day = date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
        return String(localized: "Möte \(day)")
    }

    /// "I dag 22:30", "I går 09:15", "tisdag 14:00" this week, then the date.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
        if calendar.isDateInToday(date) { return String(localized: "I dag \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "I går \(time)") }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 6 {
            let weekday = date.formatted(Date.FormatStyle().weekday(.wide).locale(AppLanguage.locale))
            return "\(weekday) \(time)"
        }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let style = sameYear ? Date.FormatStyle().day().month(.abbreviated) : Date.FormatStyle().day().month(.abbreviated).year()
        return "\(date.formatted(style.locale(AppLanguage.locale))) \(time)"
    }
}

/// The speakers of a meeting: their order, numbers and names.
struct Cast: Equatable {
    let order: [Int]
    let names: [String: String]

    init(words: [MeetingWord], names: [String: String]) {
        var seen: [Int] = []
        var known = Set<Int>()
        for w in words { if let s = w.speaker, s >= 0, known.insert(s).inserted { seen.append(s) } }
        order = seen
        self.names = names
    }

    func number(of speaker: Int) -> Int { (order.firstIndex(of: speaker) ?? order.count) + 1 }

    func name(of speaker: Int) -> String {
        if let name = names[String(speaker)], !name.isEmpty { return name }
        return String(localized: "Talare \(number(of: speaker))")
    }

    func isNamed(_ speaker: Int) -> Bool { !(names[String(speaker)] ?? "").isEmpty }
}

extension MeetingRecord {
    /// Your notes as you typed them, each line keeping the moment it was begun: an
    /// unchanged line keeps its time wherever it moved, a line being typed or edited
    /// (one begins like the other) keeps the time of the line it was, and a new line
    /// gets `now` (nil after the meeting).
    static func notes(from text: String, old: [Note], now: Double?) -> [Note] {
        let lines = text.components(separatedBy: "\n")
        var out = [Note?](repeating: nil, count: lines.count)
        var used = Set<Int>()
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        // The same line, anywhere.
        for (i, line) in lines.enumerated() where !blank(line) {
            if let k = old.indices.first(where: { !used.contains($0) && old[$0].text == line }) {
                out[i] = Note(text: line, at: old[k].at)
                used.insert(k)
            }
        }
        // The same line, changed: one begins like the other.
        for (i, line) in lines.enumerated() where out[i] == nil && !blank(line) {
            if let k = old.indices.first(where: { !used.contains($0) && alike(old[$0].text, line) }) {
                out[i] = Note(text: line, at: old[k].at)
                used.insert(k)
            }
        }
        var notes = lines.enumerated().map { i, line in out[i] ?? Note(text: line, at: blank(line) ? nil : now) }
        // Trailing empty lines carry nothing.
        while let last = notes.last, blank(last.text) { notes.removeLast() }
        return notes
    }

    private static func alike(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let common = zip(a, b).prefix { $0 == $1 }.count
        return common >= max(3, min(a.count, b.count) / 2)
    }

    /// Gives the words in `range` to `speaker`, and remembers it by their time.
    mutating func move(words range: Range<Int>, to speaker: Int) {
        let range = range.clamped(to: 0..<words.count)
        guard let first = range.first, let last = range.last else { return }
        let (start, end) = (words[first].start, words[last].end)
        // A later move over the same stretch replaces the earlier one.
        moves.removeAll { $0.start >= start - 0.01 && $0.end <= end + 0.01 }
        moves.append(Move(start: start, end: end, speaker: speaker))
        for i in range { words[i].speaker = speaker }
    }

    /// Your moves, applied to `words` from index `from` on — by where each word's
    /// middle falls, since the words themselves may have been written again.
    static func apply(_ moves: [Move], to words: inout [MeetingWord], from: Int = 0) {
        guard !moves.isEmpty, from < words.count else { return }
        for i in from..<words.count {
            let mid = (words[i].start + words[i].end) / 2
            for move in moves where mid >= move.start - 0.01 && mid <= move.end + 0.01 {
                words[i].speaker = move.speaker
            }
        }
    }

    static func merge(_ speaker: Int, into other: Int, in record: inout MeetingRecord) {
        guard speaker != other else { return }
        for i in record.words.indices where record.words[i].speaker == speaker { record.words[i].speaker = other }
        if (record.names[String(other)] ?? "").isEmpty, let name = record.names[String(speaker)] {
            record.names[String(other)] = name
        }
        record.names[String(speaker)] = nil
        for i in record.moves.indices where record.moves[i].speaker == speaker { record.moves[i].speaker = other }
    }
}

/// A run of words by one speaker — one bubble.
struct MeetingTurn: Identifiable, Equatable {
    let id: Int              // index of its first word
    let speaker: Int?
    let start: Double
    var text: String
    /// Still being written: may change.
    var pending: String
}

enum MeetingText {
    /// Groups words into turns. Words with no clear speaker stay with the one before.
    /// With `paragraphs`, someone speaking at length is broken up — at a pause of two
    /// seconds, or at a full stop once a paragraph is long — so a monologue isn't one
    /// endless bubble (and the live view only redraws its last part).
    @MainActor static func turns(_ words: [MeetingWord], pending: [MeetingWord] = [],
                                 paragraphs: Bool = false) -> [MeetingTurn] {
        var turns: [MeetingTurn] = []
        var current: (id: Int, speaker: Int?, start: Double, words: [String], pending: [String])?
        var previous: MeetingWord?
        func flush() {
            guard let c = current else { return }
            turns.append(MeetingTurn(id: c.id, speaker: c.speaker, start: c.start,
                                     text: clean(c.words.joined(separator: " ")),
                                     pending: c.pending.joined(separator: " ")))
        }
        let all = words.map { ($0, false) } + pending.map { ($0, true) }
        for (i, (word, isPending)) in all.enumerated() {
            var speaker = word.speaker
            if speaker == nil || speaker == MeetingWord.unknown { speaker = current?.speaker ?? speaker }
            defer { previous = word }
            var breaks = false
            if paragraphs, !isPending, let c = current, c.pending.isEmpty, let previous {
                let sentenceOver = previous.text.last.map { ".?!".contains($0) } ?? false
                breaks = word.start - previous.end >= 2 || (c.words.count >= 60 && sentenceOver)
            }
            if !breaks, let c = current, c.speaker == speaker || speaker == nil || speaker == MeetingWord.unknown {
                if isPending { current?.pending.append(word.text) } else if c.pending.isEmpty {
                    current?.words.append(word.text)
                } else {
                    current?.pending.append(word.text)
                }
                continue
            }
            flush()
            current = (i, speaker, word.start, isPending ? [] : [word.text], isPending ? [word.text] : [])
        }
        flush()
        return turns
    }

    /// Hesitation sounds out, your spellings in — as for dictation. Remembered,
    /// since a live meeting redraws its turns twice a second.
    @MainActor static func clean(_ raw: String) -> String {
        if let done = cache[raw] { return done }
        let text = Vocabulary.shared.reapply(TextCleanup.apply(raw, fillers: Settings.removeFillers, commands: false))
        if cache.count > 4_000 { cache.removeAll() }
        cache[raw] = text
        return text
    }
    @MainActor private static var cache: [String: String] = [:]

    /// Who spoke when: runs of one speaker, a pause of up to 1.5 s kept inside.
    struct Segment: Equatable {
        let speaker: Int
        let start: Double
        var end: Double
    }

    static func segments(_ words: [MeetingWord]) -> [Segment] {
        var out: [Segment] = []
        var last: Int?
        for w in words {
            var s = w.speaker ?? MeetingWord.unknown
            if s < 0 { s = last ?? -1 }
            guard s >= 0 else { continue }
            if let i = out.indices.last, out[i].speaker == s, w.start - out[i].end < 1.5 {
                out[i].end = w.end
            } else {
                out.append(Segment(speaker: s, start: w.start, end: w.end))
            }
            last = s
        }
        return out
    }

    /// The whole meeting as plain text: "Anna: …" per turn.
    @MainActor static func plain(_ record: MeetingRecord) -> String {
        turns(record.words).map { turn in
            let who = turn.speaker.map { $0 >= 0 ? record.name(of: $0) : "" } ?? ""
            return who.isEmpty ? turn.text : "\(who): \(turn.text)"
        }
        .joined(separator: "\n\n")
    }
}

/// The meetings on this Mac.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [MeetingRecord] = []

    static var root: URL {
        SpeechModel.rootDirectory.deletingLastPathComponent().appendingPathComponent("Meetings")
    }

    static func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    static func audioURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("audio.caf") }
    private static func recordURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meeting.json") }

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        meetings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(MeetingRecord.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    /// Creates the meeting's folder, private to you.
    static func prepareFolder(for id: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: folder(for: id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func save(_ record: MeetingRecord) {
        let url = Self.recordURL(for: record.id)
        do {
            try Self.prepareFolder(for: record.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Mindtalk: could not save meeting: \(error.localizedDescription)")
        }
        if let i = meetings.firstIndex(where: { $0.id == record.id }) { meetings[i] = record } else {
            meetings.insert(record, at: 0)
        }
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var record = meetings.first(where: { $0.id == id }), record.title != title else { return }
        record.title = title
        record.userTitled = true
        save(record)
    }

    /// Ticks a task off (or back on).
    func setDone(_ item: UUID, _ done: Bool, in id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }),
              let i = record.summary?.tasks.firstIndex(where: { $0.id == item }) else { return }
        record.summary?.tasks[i].done = done
        save(record)
    }

    /// Two voices that are one person: `speaker`'s words become `into`'s.
    func merge(_ speaker: Int, into other: Int, in id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        MeetingRecord.merge(speaker, into: other, in: &record)
        save(record)
    }

    /// A turn said by someone else than Mindtalk thought.
    func move(words range: Range<Int>, to speaker: Int, in id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        record.move(words: range, to: speaker)
        save(record)
    }

    func name(speaker: Int, in id: UUID, as name: String) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.names[String(speaker)] = name
        record.recognized[String(speaker)] = nil
        save(record)
        // Remembered for the next meeting (when you've switched that on).
        guard !name.isEmpty, record.hasAudio else { return }
        let words = record.words
        Task { await VoiceMemory.shared.learn(words: words, audio: Self.audioURL(for: id), names: [String(speaker): name]) }
    }

    /// Your notes, edited after the meeting.
    func setNotes(_ text: String, in id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        let notes = MeetingRecord.notes(from: text, old: record.notes, now: nil)
        guard notes != record.notes else { return }
        record.notes = notes
        save(record)
    }

    func removeMark(_ mark: UUID, in id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        record.marks.removeAll { $0.id == mark }
        save(record)
    }

    /// The recording to the Trash; the text, notes and summary stay.
    func removeAudio(of id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }), record.hasAudio else { return }
        if MeetingPlayer.shared.meeting == id { MeetingPlayer.shared.stop() }
        let url = Self.audioURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                NSLog("Mindtalk: could not move a recording to the Trash: \(error.localizedDescription)")
                return
            }
        }
        record.audioRemoved = Date()
        save(record)
    }

    /// Meetings whose recording is older than the time recordings are kept
    /// (Inställningar → Möten). Only finished ones — never a meeting still to be finished.
    func recordingsPast(days: Int) -> [UUID] {
        guard days > 0 else { return [] }
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        return meetings.filter { $0.hasAudio && $0.finished && $0.refined && $0.date < limit }.map(\.id)
    }

    /// Keeps recordings no longer than you chose. At launch and after each meeting.
    func applyRetention() {
        for id in recordingsPast(days: MeetingAudio.keepDays) { removeAudio(of: id) }
    }

    /// Removes the meeting — text and recording — from the Mac.
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.folder(for: id))
        meetings.removeAll { $0.id == id }
    }
}

/// How long recordings are kept. Text, notes and summary stay either way.
enum MeetingAudio {
    static let choices = [0, 90, 30, 7]          // 0: always

    static var keepDays: Int {
        get { UserDefaults.standard.integer(forKey: "meetingAudioDays") }
        set { UserDefaults.standard.set(newValue, forKey: "meetingAudioDays") }
    }

    static func title(_ days: Int) -> String {
        days == 0 ? String(localized: "Alltid") : String(localized: "\(days) dagar")
    }
}
