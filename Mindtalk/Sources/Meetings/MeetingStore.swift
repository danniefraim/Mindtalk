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
    }

    /// Speakers in the order they first spoke.
    var speakers: [Int] {
        var seen: [Int] = []
        for w in words { if let s = w.speaker, s >= 0, !seen.contains(s) { seen.append(s) } }
        return seen
    }

    /// "Anna", or "Talare 2" — numbered in the order people first spoke.
    func name(of speaker: Int) -> String {
        if let name = names[String(speaker)], !name.isEmpty { return name }
        let number = (speakers.firstIndex(of: speaker) ?? speakers.count) + 1
        return String(localized: "Talare \(number)")
    }

    static func defaultTitle(for date: Date) -> String {
        let when = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale))
        return String(localized: "Möte \(when)")
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
    @MainActor static func turns(_ words: [MeetingWord], pending: [MeetingWord] = []) -> [MeetingTurn] {
        var turns: [MeetingTurn] = []
        var current: (id: Int, speaker: Int?, start: Double, words: [String], pending: [String])?
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
            if let c = current, c.speaker == speaker || speaker == nil || speaker == MeetingWord.unknown {
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
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        record.title = title
        save(record)
    }

    func name(speaker: Int, in id: UUID, as name: String) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        record.names[String(speaker)] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(record)
    }

    /// Removes the meeting — text and recording — from the Mac.
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.folder(for: id))
        meetings.removeAll { $0.id == id }
    }
}
