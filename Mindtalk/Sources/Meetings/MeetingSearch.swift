import Foundation
import NaturalLanguage
import os

// MARK: - Search and ask across all meetings
//
// Search: type a few words and see every meeting where they were said, written in
// your notes, or put in the summary — with the sentence and the moment, one click
// from hearing it.
//
// Ask: a question about all of them ("vad bestämde vi om budgeten?", "vad ska Anna
// göra den här veckan?"). The meetings worth reading are picked first — by the
// words they share with the question, and by the days it names ("i går", "förra
// veckan", "i tisdags") — then the model (Apple Intelligence, or Gemma 4 when
// installed) answers from their summaries and the lines that matter, and names the
// lines it used. Each source is a meeting and a moment you can open.
//
// Everything stays on the Mac, as with a single meeting.

/// One place a search matched.
struct MeetingHit: Identifiable, Equatable {
    enum Kind: Equatable { case title, summary, note, said }

    let id = UUID()
    let kind: Kind
    /// The sentence, cut to fit around the match.
    let text: String
    /// Who said it ("Anna"), for what was said.
    let who: String?
    /// The moment, for what was said and for timed notes and summary items.
    let at: Double?
}

/// A meeting with the places it matched.
struct MeetingMatch: Identifiable, Equatable {
    var id: UUID { record.id }
    let record: MeetingRecord
    let hits: [MeetingHit]
}

enum MeetingSearch {
    /// Every meeting with all the words of `query` somewhere in it, newest first, and
    /// where — the title, the summary, your notes, what was said. Case doesn't matter;
    /// å, ä and ö do ("bäst" isn't "bast").
    @MainActor static func find(_ query: String, in meetings: [MeetingRecord], limit: Int = 4) -> [MeetingMatch] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        func has(_ text: String, _ word: String) -> Bool { text.range(of: word, options: [.caseInsensitive]) != nil }

        var out: [MeetingMatch] = []
        for record in meetings {
            let sentences = sentences(of: record)
            let summary = summaryLines(of: record)
            let notes = record.notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            // All the words, anywhere in the meeting.
            let everything = ([record.title] + summary.map(\.text) + notes.map(\.text) + sentences.map(\.text)).joined(separator: " ")
            guard words.allSatisfy({ has(everything, $0) }) else { continue }

            var hits: [MeetingHit] = []
            if words.contains(where: { has(record.title, $0) }) { hits.append(MeetingHit(kind: .title, text: record.title, who: nil, at: nil)) }
            for line in summary where words.contains(where: { has(line.text, $0) }) {
                hits.append(MeetingHit(kind: .summary, text: line.text, who: nil, at: line.at))
            }
            for note in notes where words.contains(where: { has(note.text, $0) }) {
                hits.append(MeetingHit(kind: .note, text: note.text, who: nil, at: note.at))
            }
            // What was said: the sentences with the most of the words first, then in order.
            let said = sentences.filter { s in words.contains { has(s.text, $0) } }
                .sorted { a, b in
                    let na = words.filter { has(a.text, $0) }.count, nb = words.filter { has(b.text, $0) }.count
                    return na != nb ? na > nb : a.start < b.start
                }
            for s in said.prefix(limit) {
                hits.append(MeetingHit(kind: .said, text: excerpt(s.text, around: words), who: s.speaker, at: s.start))
            }
            if !hits.isEmpty { out.append(MeetingMatch(record: record, hits: Array(hits.prefix(limit + 2)))) }
        }
        return out
    }

    struct Sentence { let speaker: String; let text: String; let start: Double }

    /// The meeting sentence by sentence, with who said it and when. Kept per meeting
    /// until its words or names change, so typing a search doesn't redo every meeting.
    @MainActor static func sentences(of record: MeetingRecord) -> [Sentence] {
        let key = "\(record.words.count)-\(record.words.last?.end ?? 0)-\(record.names.sorted { $0.key < $1.key })-\(record.moves.count)"
        if let cached = cache[record.id], cached.key == key { return cached.sentences }
        let made = makeSentences(of: record)
        if cache.count > 500 { cache.removeAll() }
        cache[record.id] = (key, made)
        return made
    }
    @MainActor private static var cache: [UUID: (key: String, sentences: [Sentence])] = [:]

    @MainActor private static func makeSentences(of record: MeetingRecord) -> [Sentence] {
        let cast = record.cast
        var out: [Sentence] = []
        var words: [String] = []
        var start = 0.0
        for (k, w) in record.words.enumerated() {
            if words.isEmpty { start = w.start }
            words.append(w.text)
            let ends = w.text.last.map { ".?!".contains($0) } ?? false
            if ends || k == record.words.count - 1 || words.count >= 60 {
                let who = w.speaker.map { $0 >= 0 ? cast.name(of: $0) : "" } ?? ""
                out.append(Sentence(speaker: who, text: MeetingText.clean(words.joined(separator: " ")), start: start))
                words = []
            }
        }
        return out
    }

    /// The summary as lines: what it was about, then decisions, tasks and points.
    static func summaryLines(of record: MeetingRecord) -> [(kind: String, text: String, at: Double?)] {
        guard let s = record.summary else { return [] }
        var out: [(kind: String, text: String, at: Double?)] = []
        if !s.overview.isEmpty { out.append(("overview", s.overview, nil)) }
        for i in s.decisions { out.append(("decision", i.text, i.at)) }
        for i in s.tasks {
            let who = i.owner.map { " (\($0))" } ?? ""
            let state = i.done == true ? " – done" : ""
            out.append(("task", i.text + who + state, i.at))
        }
        for i in s.points { out.append(("point", i.text, i.at)) }
        return out
    }

    /// About 160 characters around the first word found, cut at word boundaries.
    static func excerpt(_ text: String, around words: [String]) -> String {
        guard text.count > 170,
              let hit = words.compactMap({ text.range(of: $0, options: .caseInsensitive) }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return text }
        let from = text.index(hit.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let to = text.index(from, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
        var piece = String(text[from..<to])
        if from != text.startIndex, let space = piece.firstIndex(of: " ") { piece = "…" + piece[piece.index(after: space)...] }
        if to != text.endIndex, let space = piece.lastIndex(of: " ") { piece = String(piece[..<space]) + "…" }
        return piece
    }
}

// MARK: - The meetings a question is about

/// What the model reads for a question across meetings: the meetings it's most
/// likely about, each with its summary and the lines that match, numbered — and
/// where each number leads.
struct LibraryContext: Sendable {
    struct Source: Sendable, Equatable { let meeting: UUID; let at: Double? }

    let text: String
    let sources: [Int: Source]
    let language: String
    let meetings: Int
    /// "Tuesday 6 October 2026" — so "i dag" and "förra veckan" mean something to the model.
    let today: String

    /// `budget` in words: Apple's model reads about 3 000 at a time, Gemma 4 far more.
    @MainActor init(question: String, meetings all: [MeetingRecord], budget: Int, now: Date = Date()) {
        let keys = LibraryContext.content(question)
        let range = LibraryContext.days(in: question, now: now)
        let inRange = range.map { r in all.filter { r.contains($0.date) } } ?? all
        let pool = inRange.isEmpty ? all : inRange

        // Each meeting: how much of the question it holds, in its summary and its words.
        struct Scored { let record: MeetingRecord; let score: Double; let lines: [(text: String, at: Double?, score: Double)] }
        var scored: [Scored] = []
        for record in pool {
            var lines: [(text: String, at: Double?, score: Double)] = []
            for s in MeetingSearch.summaryLines(of: record) {
                let label = switch s.kind {
                case "overview": "Summary"
                case "decision": "Decision"
                case "task": "Task"
                default: "Point"
                }
                lines.append(("\(label): \(s.text)", s.at, Lines.overlap(keys, Lines.keys(s.text)) + 0.15))
            }
            for n in record.notes where !n.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(("Your note: \(n.text)", n.at, Lines.overlap(keys, Lines.keys(n.text)) + 0.1))
            }
            for s in MeetingSearch.sentences(of: record) {
                let who = s.speaker.isEmpty ? "?" : s.speaker
                lines.append(("\(who): \(s.text)", s.start, Lines.overlap(keys, Lines.keys(s.text))))
            }
            let title = Lines.overlap(keys, Lines.keys(record.title))
            let best = lines.map(\.score).sorted(by: >).prefix(5).reduce(0, +)
            // With nothing to match (a question only about days), newer meetings first.
            let fresh = 0.01 * max(0, 30 - now.timeIntervalSince(record.date) / 86_400) / 30
            scored.append(Scored(record: record, score: best + title * 2 + fresh, lines: lines))
        }
        scored.sort { $0.score > $1.score }

        // Meetings in order of how much they hold, each with its summary and best
        // lines (and their neighbours), in the order they were said — until the budget.
        var blocks: [(record: MeetingRecord, lines: [(text: String, at: Double?)])] = []
        var words = 0
        for s in scored.prefix(keys.isEmpty ? 8 : 12) where s.score > 0 || keys.isEmpty || range != nil {
            let summaryCount = s.lines.prefix { $0.text.hasPrefix("Summary:") || $0.text.hasPrefix("Decision:")
                || $0.text.hasPrefix("Task:") || $0.text.hasPrefix("Point:") || $0.text.hasPrefix("Your note:") }.count
            var chosen = Set(0..<summaryCount)
            let said = Array(summaryCount..<s.lines.count)
            let ranked = said.sorted { s.lines[$0].score > s.lines[$1].score }
            for i in ranked.prefix(6) where s.lines[i].score > 0 {
                for j in [i - 1, i, i + 1] where said.contains(j) { chosen.insert(j) }
            }
            // Without matching lines, the beginning of what was said gives the gist.
            if chosen.count == summaryCount { for j in said.prefix(summaryCount == 0 ? 6 : 2) { chosen.insert(j) } }
            var block: [(text: String, at: Double?)] = []
            for i in chosen.sorted() {
                let n = s.lines[i].text.split(separator: " ").count
                if words + n > budget { break }
                words += n
                block.append((s.lines[i].text, s.lines[i].at))
            }
            if !block.isEmpty { blocks.append((s.record, block)) }
            if words >= budget - 30 { break }
        }

        // Numbered as one transcript, meeting by meeting, oldest first.
        var text = ""
        var sources: [Int: Source] = [:]
        var n = 0
        for (k, b) in blocks.sorted(by: { $0.record.date < $1.record.date }).enumerated() {
            let when = b.record.date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "en_GB")))
            text += "\(k > 0 ? "\n" : "")Meeting \(k + 1): \"\(b.record.title)\" – \(when)\n"
            for line in b.lines {
                n += 1
                text += "[\(n)] \(line.text)\n"
                sources[n] = Source(meeting: b.record.id, at: line.at)
            }
        }
        self.text = text
        self.sources = sources
        today = now.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: "en_GB")))
        self.meetings = blocks.count
        let sample = blocks.flatMap { $0.lines.map(\.text) }.joined(separator: " ")
        language = Lines.languageName(of: question.split(separator: " ").count >= 3 ? question : sample) ?? "Swedish"
    }

    /// What the question is about: its word stems without the small words.
    static func content(_ text: String) -> Set<String> {
        Lines.keys(text).subtracting(["vad", "vem", "vilk", "när", "hur", "varf", "något", "några", "möte", "mötet", "meeti",
                                      "what", "who", "when", "which", "with", "about", "har", "vi", "jag", "det", "den",
                                      "för", "och", "att", "som", "ska", "skull", "sagt", "sade", "sa", "pratade", "prata",
                                      "bestä", "beslu", "decid", "the", "did", "does", "veckan", "förra", "dagen", "igår",
                                      "idag", "måndag", "tisda", "onsda", "torsd", "freda", "lörda", "sönda"])
    }

    /// The days a question names: "i dag", "i går", "i förrgår", "den här veckan",
    /// "förra veckan", "förra månaden", "i måndags" (and the English).
    static func days(in question: String, now: Date) -> ClosedRange<Date>? {
        // Words only, between spaces: "i dag?" is "i dag".
        let q = " " + String(question.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ") + " "
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "sv_SE")
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> ClosedRange<Date> {
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            return start...calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        }
        if q.contains(" i förrgår ") || q.contains(" day before yesterday ") { return day(-2) }
        if q.contains(" i går ") || q.contains(" igår ") || q.contains(" yesterday ") { return day(-1) }
        if q.contains(" i dag ") || q.contains(" idag ") || q.contains(" today ") { return day(0) }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        if q.contains("förra veckan") || q.contains("last week") {
            let start = calendar.date(byAdding: .day, value: -7, to: week.start)!
            return start...week.start.addingTimeInterval(-1)
        }
        if q.contains("den här veckan") || q.contains("denna vecka") || q.contains("this week") || q.contains("i veckan") {
            return week.start...now
        }
        let month = calendar.dateInterval(of: .month, for: now)!
        if q.contains("förra månaden") || q.contains("last month") {
            let start = calendar.date(byAdding: .month, value: -1, to: month.start)!
            return start...month.start.addingTimeInterval(-1)
        }
        if q.contains("den här månaden") || q.contains("this month") { return month.start...now }
        // "i måndags", "i tisdags"… / "on monday": the last one before today.
        let weekdays: [(String, Int)] = [("måndag", 2), ("tisdag", 3), ("onsdag", 4), ("torsdag", 5), ("fredag", 6),
                                         ("lördag", 7), ("söndag", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
                                         ("thursday", 5), ("friday", 6), ("saturday", 7), ("sunday", 1)]
        for (name, weekday) in weekdays where q.contains(name) {
            for back in 1...7 {
                let d = calendar.date(byAdding: .day, value: -back, to: today)!
                if calendar.component(.weekday, from: d) == weekday { return day(-back) }
            }
        }
        return nil
    }
}

// MARK: - Questions across meetings

struct LibraryAnswer: Identifiable, Equatable {
    struct Source: Identifiable, Equatable {
        var id: String { "\(meeting)-\(at ?? -1)" }
        let meeting: UUID
        let title: String
        let at: Double?
    }

    let id = UUID()
    let question: String
    let answer: String
    let sources: [Source]
    /// How many meetings it read.
    let read: Int
}

/// Questions about all your meetings, and their answers — kept while Mindtalk runs.
@MainActor
final class MeetingLibrary: ObservableObject {
    static let shared = MeetingLibrary()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "MeetingLibrary")

    @Published private(set) var answers: [LibraryAnswer] = []
    @Published private(set) var asking = false
    @Published private(set) var failed: String?

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MeetingNotes.isAvailable, !question.isEmpty, !asking else { return }
        let meetings = MeetingStore.shared.meetings.filter { !$0.words.isEmpty }
        guard !meetings.isEmpty else { return }
        asking = true
        failed = nil
        let local = BetterNotes.shared.isActive
        let context = LibraryContext(question: question, meetings: meetings,
                                     budget: local ? 12_000 : Lines.appleBudget)
        let history = answers.suffix(2).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        Task {
            defer { asking = false }
            do {
                let t0 = Date()
                let reply = try await MeetingNotes.answerAcross(question, context: context, history: history, local: local)
                let titles = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title) })
                var seen = Set<String>()
                let sources: [LibraryAnswer.Source] = reply.lines.compactMap { n in
                    guard let s = context.sources[n], let title = titles[s.meeting] else { return nil }
                    let source = LibraryAnswer.Source(meeting: s.meeting, title: title, at: s.at)
                    return seen.insert(source.id).inserted ? source : nil
                }
                answers.append(LibraryAnswer(question: question, answer: reply.answer, sources: sources, read: context.meetings))
                Self.log.info("answered across \(context.meetings) meetings in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            } catch {
                Self.log.error("ask across: \(error.localizedDescription, privacy: .public)")
                failed = MeetingNotes.explainError(error)
            }
        }
    }

    #if DEBUG
    /// Waits for the question in flight (the render test).
    func waitUntilAnswered() async { while asking { try? await Task.sleep(for: .milliseconds(200)) } }
    #endif

    func forget(_ answer: LibraryAnswer) { answers.removeAll { $0.id == answer.id } }
    func clear() { answers = []; failed = nil }
}
