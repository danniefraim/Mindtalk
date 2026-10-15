import AVFoundation
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
    /// When you told the others the meeting was recorded (older meetings: the reminder
    /// is gone, but what was noted stays).
    var informed: Date?
    /// The recording went to the Trash (kept for a set time, or removed by you);
    /// the text and the notes stay.
    var audioRemoved: Date?
    /// Speakers Mindtalk named itself, from a voice you named before (VoiceMemory),
    /// with how sure it was. Cleared when you name them yourself.
    var recognized: [String: Float] = [:]
    /// Names Mindtalk gave a voice that you took away or replaced ("Fel person?"):
    /// never given to that voice again in this meeting, live or when listened again.
    var rejected: [String: [String]] = [:]
    /// The folder it's in (MeetingFolder), or nil — then it's only under "Alla".
    var folder: UUID?
    /// A folder was suggested for it and you took it or put the suggestion away: not
    /// suggested again.
    var folderAsked = false
    /// Continued after it ended: where the new part begins, in seconds. Kept until the
    /// whole meeting has been listened through again — after a crash, "Gör klart"
    /// knows it still has to.
    var continuedAt: Double?
    /// Imported from a file rather than recorded here: which, and when.
    var source: Source?

    struct Source: Codable, Equatable {
        /// The file's name, as it was.
        var file: String
        var video: Bool
        var importedAt: Date
        /// Where it was — and a bookmark that finds it again after it moved or was
        /// renamed. (Not for a copy an app handed over: that was Mindtalk's own.)
        var path: String? = nil
        var bookmark: Data? = nil
    }

    var hasAudio: Bool { audioRemoved == nil }

    /// You name a speaker (or take the name away). A name Mindtalk had guessed and you
    /// changed is remembered as wrong for that voice. Returns the name it had, and
    /// whether that was Mindtalk's guess rather than a name someone gave.
    @discardableResult
    mutating func setName(_ name: String, for speaker: Int) -> (old: String?, guessed: Bool) {
        let key = String(speaker)
        let old = names[key].flatMap { $0.isEmpty ? nil : $0 }
        let guessed = recognized[key] != nil
        if let old, guessed, old != name, !(rejected[key] ?? []).contains(old) { rejected[key, default: []].append(old) }
        names[key] = name
        recognized[key] = nil
        return (old, guessed)
    }
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
        // What Mindtalk wrote (it can be written again) never hides the meeting if it
        // can't be read; what you wrote or said is read strictly, so it is never lost.
        summary = (try? c.decodeIfPresent(MeetingSummary.self, forKey: .summary)) ?? nil
        answers = (try? c.decodeIfPresent([MeetingAnswer].self, forKey: .answers)) ?? []
        userTitled = try c.decodeIfPresent(Bool.self, forKey: .userTitled) ?? false
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        heal = (try? c.decodeIfPresent(Heal.self, forKey: .heal)) ?? nil
        moves = try c.decodeIfPresent([Move].self, forKey: .moves) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
        informed = try c.decodeIfPresent(Date.self, forKey: .informed)
        audioRemoved = try c.decodeIfPresent(Date.self, forKey: .audioRemoved)
        recognized = try c.decodeIfPresent([String: Float].self, forKey: .recognized) ?? [:]
        rejected = try c.decodeIfPresent([String: [String]].self, forKey: .rejected) ?? [:]
        folder = try? c.decodeIfPresent(UUID.self, forKey: .folder)
        folderAsked = (try? c.decodeIfPresent(Bool.self, forKey: .folderAsked)) ?? false
        continuedAt = try? c.decodeIfPresent(Double.self, forKey: .continuedAt)
        source = try? c.decodeIfPresent(Source.self, forKey: .source)
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
            // Mindtalk's guess stays a guess (it isn't learned as a name you gave).
            record.recognized[String(other)] = record.recognized[String(speaker)]
        }
        record.rejected[String(other), default: []] += record.rejected[String(speaker)] ?? []
        record.names[String(speaker)] = nil
        record.recognized[String(speaker)] = nil
        record.rejected[String(speaker)] = nil
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
    /// Someone else's "Mm" or "Ja" while this was said — shown in its place in the text
    /// rather than as a turn of its own that would split this one in two.
    var asides: [Aside] = []
    /// Words inside this turn's span that someone else said (an "Mm", an "eh") — left
    /// where they are when the turn is moved to another speaker.
    var foreign: [Range<Int>] = []

    struct Aside: Equatable {
        let speaker: Int
        let text: String
        /// Where in `text` it was said (characters).
        let at: Int
    }

    /// The turn's own words up to `end` (where the next turn starts), in runs.
    func own(until end: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var from = id
        for f in foreign.sorted(by: { $0.lowerBound < $1.lowerBound }) where f.lowerBound >= from && f.lowerBound < end {
            if f.lowerBound > from { runs.append(from..<f.lowerBound) }
            from = max(from, f.upperBound)
        }
        if from < end { runs.append(from..<end) }
        return runs
    }
}

enum MeetingText {
    /// Groups words into turns. Words with no clear speaker stay with the one before.
    /// With `paragraphs`, someone speaking at length is broken up — at a pause of two
    /// seconds, or at a full stop once a paragraph is long — so a monologue isn't one
    /// endless bubble (and the live view only redraws its last part).
    @MainActor static func turns(_ words: [MeetingWord], pending: [MeetingWord] = [],
                                 paragraphs: Bool = false) -> [MeetingTurn] {
        guard paragraphs else { return raw(ArraySlice(words), pending: pending, paragraphs: false) }
        // For reading, redrawn twice a second while a meeting runs: all but the last
        // few hundred words are grouped once and kept (they've settled), only the end
        // is grouped anew — so a long meeting costs no more per update than a short one.
        let p = max(0, (words.count - 400) / 200 * 200)
        guard p > 0 else { return folded(raw(ArraySlice(words), pending: pending, paragraphs: true)) }
        var speakers = Hasher()
        for w in words[..<p] { speakers.combine(w.speaker) }
        let key = PrefixKey(count: p, speakers: speakers.finalize(), first: words[0].start, last: words[p - 1].start)
        if prefix?.key != key { prefix = (key, raw(words[..<p], pending: [], paragraphs: true)) }
        var head = prefix?.turns ?? []
        guard let open = head.popLast() else { return folded(raw(ArraySlice(words), pending: pending, paragraphs: true)) }
        // The last kept turn may go on: grouped again from its first word.
        // (Its first word may have no voice of its own: it had the speaker before it.)
        return folded(head + raw(words[open.id...], pending: pending, paragraphs: true, seed: open.speaker))
    }

    #if DEBUG
    @MainActor static func turnsAllAnew(_ words: [MeetingWord], pending: [MeetingWord]) -> [MeetingTurn] {
        folded(raw(ArraySlice(words), pending: pending, paragraphs: true))
    }
    #endif

    private struct PrefixKey: Equatable {
        let count: Int
        let speakers: Int
        let first: Double
        let last: Double
    }
    @MainActor private static var prefix: (key: PrefixKey, turns: [MeetingTurn])?

    /// Groups words into turns (ids are indices in the whole meeting).
    @MainActor private static func raw(_ words: ArraySlice<MeetingWord>, pending: [MeetingWord],
                                       paragraphs: Bool, seed: Int? = nil) -> [MeetingTurn] {
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
        for (n, (word, isPending)) in all.enumerated() {
            let i = words.startIndex + n
            var speaker = word.speaker
            if n == 0, speaker == nil || speaker == MeetingWord.unknown, let seed { speaker = seed }
            // Words still being written that no voice has claimed yet, after a pause:
            // someone may have taken over — a row of their own until it's known.
            let unclaimed = isPending && speaker == nil && previous.map { word.start - $0.end >= 1.0 } ?? false
            if unclaimed, current?.speaker != nil {
                flush()
                current = (i, nil, word.start, [], [word.text])
                previous = word
                continue
            }
            if speaker == nil || speaker == MeetingWord.unknown { speaker = current?.speaker ?? speaker }
            defer { previous = word }
            var breaks = false
            if paragraphs, let c = current, let previous {
                let sentenceOver = previous.text.last.map { ".?!".contains($0) } ?? false
                breaks = isPending || !c.pending.isEmpty
                    ? word.start - previous.end >= 2
                    : word.start - previous.end >= 2 || (c.words.count >= 60 && sentenceOver)
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

    /// For reading: a turn that came out empty (only "eh") goes, and someone else's
    /// short "Mm", "Ja", "Precis" goes into the turn it interrupted — which then reads
    /// on as one, instead of being split in two by it.
    @MainActor static func folded(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        var out: [MeetingTurn] = []
        var rejoin = false
        for (k, turn) in turns.enumerated() {
            let next = k + 1 < turns.count ? turns[k + 1] : nil
            let span = turn.id..<(next?.id ?? turn.id + 1)
            if turn.text.isEmpty && turn.pending.isEmpty {
                if let last = out.last, last.speaker != turn.speaker { out[out.count - 1].foreign.append(span) }
                rejoin = true
                continue
            }
            // Someone else's "Mm" while one person talks — they go on after it. (A short
            // answer that ends a turn, "Nej." to a question, stays a turn of its own.)
            if let speaker = turn.speaker, speaker >= 0, turn.pending.isEmpty, isBackchannel(turn.text),
               let last = out.last, let other = last.speaker, other >= 0, other != speaker, next?.speaker == other {
                out[out.count - 1].asides.append(.init(speaker: speaker, text: turn.text, at: last.text.count))
                out[out.count - 1].foreign.append(span)
                rejoin = true
                continue
            }
            if rejoin, let last = out.last, last.speaker == turn.speaker, last.pending.isEmpty {
                let shift = last.text.isEmpty || turn.text.isEmpty ? last.text.count : last.text.count + 1
                if !turn.text.isEmpty { out[out.count - 1].text += last.text.isEmpty ? turn.text : " " + turn.text }
                out[out.count - 1].pending = turn.pending
                out[out.count - 1].asides += turn.asides.map { .init(speaker: $0.speaker, text: $0.text, at: $0.at + shift) }
                out[out.count - 1].foreign += turn.foreign
            } else {
                out.append(turn)
            }
            rejoin = false
        }
        return out
    }

    private static let backchannels: Set<String> = [
        "mm", "mhm", "mmm", "hm", "ja", "jaa", "japp", "jo", "precis", "exakt", "okej", "ok", "absolut", "visst",
        "just det", "jaha", "aha", "nej", "nä", "yes", "yeah", "right", "sure", "okay", "uh-huh", "ja ja", "mm mm",
    ]

    static func isBackchannel(_ text: String) -> Bool {
        guard text.utf8.count <= 16 else { return false }       // most turns: at once
        let key = text.lowercased().filter { $0.isLetter || $0 == " " || $0 == "-" }
            .trimmingCharacters(in: .whitespaces)
        return key.split(separator: " ").count <= 2 && backchannels.contains(key)
    }

    /// Hesitation sounds out, your spellings in — as for dictation. Remembered,
    /// since a live meeting redraws its turns twice a second.
    @MainActor static func clean(_ raw: String) -> String {
        if let done = cache[raw] { return done }
        if let done = older[raw] { cache[raw] = done; return done }
        let text = Vocabulary.shared.reapply(TextCleanup.apply(raw, fillers: Settings.removeFillers, commands: false))
        // Two generations: when this one fills, it becomes the older one — what's still
        // on screen is found there, rather than all cleaned again in one frame.
        if cache.count > 2_000 { older = cache; cache = [:] }
        cache[raw] = text
        return text
    }
    @MainActor private static var cache: [String: String] = [:]
    @MainActor private static var older: [String: String] = [:]

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

    nonisolated static var root: URL {
        SpeechModel.rootDirectory.deletingLastPathComponent().appendingPathComponent("Meetings")
    }

    nonisolated static func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    nonisolated static func audioURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("audio.caf") }
    private static func recordURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meeting.json") }

    /// The meetings are read from disk once, off the main thread (a long history is
    /// many megabytes of text); until then the list is empty, and a meeting saved
    /// meanwhile stays as saved.
    private(set) var loaded = false
    private var retentionWaiting = false

    private init() {
        Task.detached(priority: .userInitiated) {
            let read = Self.readAll()
            await MainActor.run { MeetingStore.shared.finishLoading(read) }
        }
    }

    #if DEBUG
    /// Self-tests read the meetings at once, before anything else.
    func loadNow() { if !loaded { finishLoading(Self.readAll()) } }
    #endif

    /// Waits until the meetings are read (instant once they are).
    func ready() async {
        while !loaded { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func finishLoading(_ read: [MeetingRecord]) {
        let saved = Set(meetings.map(\.id))
        meetings = (meetings + read.filter { !saved.contains($0.id) }).sorted { $0.date > $1.date }
        loaded = true
        if retentionWaiting { retentionWaiting = false; applyRetention() }
    }

    nonisolated private static func readAll() -> [MeetingRecord] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var seen = Set<UUID>()
        return folders.compactMap { folder -> MeetingRecord? in
            let url = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: url) else {
                // Only sound, no meeting: an import cut off (Mindtalk quit mid-way). An
                // hour old, it is left over for good — to the Trash.
                let audio = folder.appendingPathComponent("audio.caf")
                if UUID(uuidString: folder.lastPathComponent) != nil, fm.fileExists(atPath: audio.path),
                   let made = (try? fm.attributesOfItem(atPath: audio.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(made) > 3600 {
                    try? fm.trashItem(at: folder, resultingItemURL: nil)
                }
                return nil
            }
            do {
                let record = try decoder.decode(MeetingRecord.self, from: data)
                // A copied folder (Finder, a restore) can carry the same meeting twice.
                guard seen.insert(record.id).inserted else { return nil }
                return record
            } catch {
                // Left untouched on disk — never overwritten — and said in the log.
                NSLog("Mindtalk: could not read \(url.path): \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// A finished meeting continued: the new part is recorded here, then put after
    /// the first (joinContinuation) — the meeting has one recording again.
    nonisolated static func continuationURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("audio-more.caf") }
    nonisolated private static func joinedURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("audio-joined.caf") }
    /// The quiet put between the parts, in samples (16 kHz): a second, so the words and
    /// voices on either side don't run together.
    nonisolated static let continuationGap = 16_000

    /// The continued part after the first, with a second of quiet between. Safe to
    /// call again after it was cut off: the joined file is written beside the two,
    /// the new part removed only once it is complete, and only then does it take
    /// the recording's place.
    nonisolated static func joinContinuation(for id: UUID) throws {
        let fm = FileManager.default
        let main = audioURL(for: id), more = continuationURL(for: id), joined = joinedURL(for: id)
        if !fm.fileExists(atPath: more.path) {
            // Cut off after the join was written: it only has to take its place.
            if fm.fileExists(atPath: joined.path) { _ = try fm.replaceItemAt(main, withItemAt: joined) }
            return
        }
        try? fm.removeItem(at: joined)                 // half written before
        let first = try AVAudioFile(forReading: main)
        let out = try AVAudioFile(forWriting: joined, settings: first.fileFormat.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        func copy(_ file: AVAudioFile) throws {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { return }
            while file.framePosition < file.length {
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
            }
        }
        try copy(first)
        if let gap = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(continuationGap)),
           let channel = gap.floatChannelData?[0] {
            gap.frameLength = AVAudioFrameCount(continuationGap)
            channel.update(repeating: 0, count: continuationGap)
            try out.write(from: gap)
        }
        try copy(AVAudioFile(forReading: more))
        out.close()
        try fm.removeItem(at: more)
        _ = try fm.replaceItemAt(main, withItemAt: joined)
    }

    /// Creates the meeting's folder, private to you.
    static func prepareFolder(for id: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: folder(for: id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func save(_ record: MeetingRecord) {
        let url = Self.recordURL(for: record.id)
        Self.writer.sync {}          // a quiet save still on its way lands first, not over this one
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
            // In its place by date — an imported recording may be from long ago.
            meetings.insert(record, at: meetings.firstIndex { $0.date < record.date } ?? meetings.count)
        }
    }

    /// While a meeting is recorded (every 20 s, notes): written on a queue of its own,
    /// so a long meeting's file never stalls the page — and the list isn't redrawn
    /// for it (it gets the meeting when it ends).
    func saveQuietly(_ record: MeetingRecord) {
        let url = Self.recordURL(for: record.id)
        Self.writer.async {
            do {
                try Self.prepareFolder(for: record.id)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(record).write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("Mindtalk: could not save meeting: \(error.localizedDescription)")
            }
        }
    }
    nonisolated private static let writer = DispatchQueue(label: "ai.mindact.mindtalk.meeting-writer", qos: .utility)

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
        // A name someone gave, corrected: the voice remembered under it follows. A
        // guess of Mindtalk's replaced: it was someone else — that voice stays as it is.
        let (old, guessed) = record.setName(name, for: speaker)
        if let old, !guessed { VoiceMemory.shared.corrected(from: old, to: name, meeting: id.uuidString) }
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
        // An imported recording is kept from when it was imported, not from when it was made.
        return meetings.filter { $0.hasAudio && $0.finished && $0.refined
            && max($0.date, $0.source?.importedAt ?? $0.date) < limit }.map(\.id)
    }

    /// Keeps recordings no longer than you chose. At launch and after each meeting.
    func applyRetention() {
        guard loaded else { retentionWaiting = true; return }
        for id in recordingsPast(days: MeetingAudio.keepDays) { removeAudio(of: id) }
    }

    /// When it really was (a file whose own date was wrong).
    func setDate(_ date: Date, of id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }) else { return }
        record.date = date
        save(record)
        meetings.sort { $0.date > $1.date }
    }

    /// Many meetings changed at once (moved to a folder), already written quietly.
    func replaceAll(_ changed: [MeetingRecord]) { meetings = changed }

    /// Removes the meeting — text and recording — from the Mac.
    func delete(_ id: UUID) {
        Self.writer.sync {}          // a save on its way would bring the folder back
        // To the Trash, like a removed recording — there for a while if it was a mistake.
        let folder = Self.folder(for: id)
        if (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: folder)
        }
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
