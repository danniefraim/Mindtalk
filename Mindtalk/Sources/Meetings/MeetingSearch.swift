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
        // Who said each word too: a merge or a move changes the speakers, not the count.
        var speakers = Hasher()
        for w in record.words { speakers.combine(w.speaker) }
        for m in record.moves { speakers.combine(m.speaker) }
        let key = "\(record.words.count)-\(record.words.last?.end ?? 0)-\(record.names.sorted { $0.key < $1.key })-\(speakers.finalize())"
        if let cached = cache[record.id], cached.key == key { return cached.sentences }
        let made = makeSentences(of: record)
        if cache.count > 500 { cache.removeAll() }
        cache[record.id] = (key, made)
        return made
    }
    @MainActor private static var cache: [UUID: (key: String, sentences: [Sentence])] = [:]

    /// The word list or the filler setting changed (MeetingText.forget): cleaned afresh.
    @MainActor static func forget() { cache.removeAll() }

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

// MARK: - Broad or particular

/// What kind of question it is. Broad ("Sammanfatta", "Vad är läget?", "Vilka beslut
/// har vi tagit?", "Vem har lovat vad?") wants the whole picture: the meetings' notes
/// read one by one. Particular ("Vad sa Anna om budgeten?") wants the lines that say it.
/// Told by words alone: a word for the whole picture, and nothing else to look for.
enum QuestionKind {
    /// Broad: a word asking for the whole picture, and no subject of its own once the
    /// small words, the days and the folder's name (`ignoring`) are set aside.
    static func isBroad(_ question: String, ignoring: String = "") -> Bool {
        let q = " " + question.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ").joined(separator: " ") + " "
        let words = q.split(separator: " ").map(String.init)
        let cued = phrases.contains { q.contains(" \($0) ") } || words.contains { w in cues.contains { w.hasPrefix($0) } }
        guard cued else { return false }
        let skip = Set(ignoring.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let subject = words.filter { w in
            w.count >= 3 && !stops.contains(w) && !skip.contains(w) && !cues.contains { w.hasPrefix($0) }
                && !w.allSatisfy(\.isNumber)
        }
        return subject.isEmpty
    }

    /// What a broad question is after: the decisions, the tasks (who does what, what's
    /// promised), or everything.
    enum Focus { case all, decisions, tasks }

    static func focus(of question: String) -> Focus {
        let q = " " + question.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ").joined(separator: " ") + " "
        let words = q.split(separator: " ").map(String.init)
        func has(_ starts: [String]) -> Bool { words.contains { w in starts.contains { w.hasPrefix($0) } } }
        let tasks = has(["uppgift", "todo", "lovat", "lovade", "lovar", "åtag", "task", "promise", "commit"])
            || ["att göra", "vem ska", "vem gör", "vem tar", "vad ska jag", "vad ska vi", "vad behöver jag", "vad behöver vi",
                "nästa steg", "to do", "action item", "who will", "who does", "next step", "what should", "what do i need"]
                .contains { q.contains(" \($0) ") }
        let decisions = has(["beslut", "bestäm", "överens", "decision", "decide", "agree"])
        return decisions == tasks ? .all : decisions ? .decisions : .tasks
    }

    /// Words that ask for the whole picture (the start of the word).
    private static let cues = ["sammanfatt", "summer", "sammandrag", "läget", "läge", "status", "översikt", "överblick",
                               "hände", "hänt", "händer", "beslut", "bestäm", "överens", "uppgift", "todo", "lovat",
                               "lovade", "lovar", "åtag", "pratade", "diskuter", "viktigast", "huvudpunkt", "nyheter",
                               "summar", "recap", "overview", "happen", "decision", "decide", "agree", "task", "promise",
                               "commit", "takeaway", "highlight"]
    /// …and phrases that do.
    private static let phrases = ["att göra", "vem ska", "vem gör", "vem tar", "vad ska jag", "vad ska vi", "vad behöver jag",
                                  "vad behöver vi", "nästa steg", "gick igenom", "gick vi igenom", "vad sades", "vad sa vi",
                                  "to do", "action item", "action items", "who will", "who does", "next step", "next steps",
                                  "what should", "what do i need", "main points", "key points", "what did we talk",
                                  "what did we discuss", "what was said", "what is going on", "what s going on"]
    /// Small words, days and the words around the cues: not a subject.
    private static let stops: Set<String> = [
        "vad", "vem", "vilka", "vilken", "vilket", "när", "hur", "varför", "har", "hade", "jag", "mig", "min", "mina",
        "mitt", "oss", "vår", "våra", "vårt", "det", "den", "dem", "och", "att", "som", "ska", "skall", "skulle", "kan",
        "kunde", "för", "från", "med", "till", "ett", "över", "alla", "allt", "något", "några", "nog", "upp", "tog",
        "togs", "tagit", "fattat", "fattade", "fattats", "gjort", "gör", "göra", "gjorde", "sagt", "sade", "sades",
        "mötet", "möten", "mötena", "mötenas", "mötets", "möte", "senaste", "sista", "veckan", "vecka", "veckans", "idag",
        "igår", "går", "förrgår", "dag", "dagen", "dagar", "dagarna", "förra", "månaden", "månad", "denna", "detta",
        "här", "nu", "just", "egentligen", "sju", "kort", "korthet", "hela", "helt", "behöver", "måste", "borde",
        "nästa", "steg", "gick", "igenom", "sedan", "efter", "innan", "under", "mest", "viktigt", "viktiga", "där",
        "man", "läget", "status", "lite", "snabbt", "kortfattat", "måndags", "tisdags", "onsdags", "torsdags",
        "fredags", "lördags", "söndags", "måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag",
        "what", "who", "whom", "which", "when", "how", "why", "have", "has", "had", "the", "and", "that", "this",
        "with", "about", "for", "from", "our", "all", "any", "did", "does", "were", "was", "are", "been", "made",
        "make", "last", "week", "weeks", "today", "yesterday", "month", "these", "those", "there", "meetings",
        "meeting", "you", "your", "need", "should", "will", "done", "doing", "said", "say", "talk", "talked",
        "discuss", "action", "item", "items", "next", "step", "steps", "main", "key", "point", "points", "past",
        "seven", "days", "day", "going", "give", "brief", "briefly", "short", "whole", "everything", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "since", "lately", "recent", "recently",
        "senast", "nyligen", "dina", "din", "ditt", "kvar", "öppna", "ens", "dom", "far", "får", "fick", "var", "vara",
        "varit", "blev", "blir", "over", "into", "onto", "finns", "fanns", "kom", "fram", "vill", "ville", "hos", "inom", "mellan", "kring",
    ]
}

// MARK: - The meetings a question is about

/// What the model reads for a question across meetings, numbered, and where each
/// number leads.
///
/// A particular question: the meetings it's most likely about, each with what it was
/// about, the notes that match and the lines that say it. A broad one: the meetings'
/// notes one by one, newest first, for as many meetings as the model can read — with
/// Apple's small model in up to four parts that are condensed before the answer.
struct LibraryContext: Sendable {
    struct Source: Sendable, Equatable { let meeting: UUID; let at: Double? }

    let text: String
    let sources: [Int: Source]
    /// Each line's meeting, as its heading reads ("Meeting 2: \"Budget\", Tuesday…"): the
    /// condensed notes are put back under their meetings by their line numbers.
    let headings: [Int: String]
    let language: String
    /// How many meetings it reads…
    let meetings: Int
    /// …of how many there are to ask about (in the folder, or the days the question names).
    let total: Int
    /// The whole picture, from the meetings' notes (QuestionKind).
    let broad: Bool
    /// A broad question with Apple's model: the meetings in parts that each fit, to be
    /// condensed one by one. One part (or none): read at once.
    let parts: [String]
    /// "Tuesday 6 October 2026" — so "i dag" and "förra veckan" mean something to the model.
    let today: String

    /// Words Gemma 4 reads across meetings at once; Apple's model reads `Lines.appleBudget`.
    static let localBudget = 12_000
    /// A broad question with Apple's model: at most this many parts, each this many words.
    static let appleParts = 4
    static let applePart = 1_100

    /// `local`: Gemma 4 answers (far more room than Apple's model). `folder`: its name,
    /// which a question may say ("i Kund X") without being about something in particular.
    @MainActor init(question: String, meetings all: [MeetingRecord], local: Bool, folder: String? = nil, now: Date = Date()) {
        let range = LibraryContext.days(in: question, now: now)
        let inRange = range.map { r in all.filter { r.contains($0.date) } } ?? all
        broad = QuestionKind.isBroad(question, ignoring: folder ?? "")
        let picked: [(record: MeetingRecord, lines: [(text: String, at: Double?)])]
        var maxParts = 1
        if broad {
            // The days it names, and only those: none there is said, not filled with others.
            total = inRange.count
            let newest = inRange.sorted { $0.date > $1.date }
            let focus = QuestionKind.focus(of: question)
            // "Vad är läget?" over all of them: what's current, the newest meetings (Apple's
            // small model retells many parts poorly). Decisions and tasks, or named days: all
            // four parts.
            maxParts = focus == .all && range == nil ? 2 : LibraryContext.appleParts
            let focused = LibraryContext.notes(of: newest, local: local, focus: focus, parts: maxParts)
            picked = focused.isEmpty ? LibraryContext.notes(of: newest, local: local, focus: .all, parts: maxParts) : focused
        } else {
            let pool = inRange.isEmpty ? all : inRange
            total = pool.count
            picked = LibraryContext.matching(question, in: pool, nameless: range != nil, now: now,
                                             budget: local ? LibraryContext.localBudget : Lines.appleBudget)
        }

        // A broad question with Apple's model: the meetings in parts that each fit, newest
        // first, as many parts as it condenses. Otherwise all in one.
        var groups: [[(record: MeetingRecord, lines: [(text: String, at: Double?)])]] = [[]]
        if broad, !local {
            var words = 0
            for p in picked {
                let n = 14 + p.lines.reduce(0) { $0 + $1.text.split(separator: " ").count + 1 }
                if words + n > LibraryContext.applePart, !groups[groups.count - 1].isEmpty {
                    if groups.count == maxParts { break }
                    groups.append([])
                    words = 0
                }
                groups[groups.count - 1].append(p)
                words += n
            }
        } else {
            groups = [picked]
        }

        // Numbered as one transcript, meeting by meeting: oldest first for a particular
        // question (the story of it), newest first for a broad one (what's current first).
        var sources: [Int: Source] = [:]
        var headings: [Int: String] = [:]
        var parts: [String] = []
        var n = 0, k = 0
        let newest = broad
        for group in newest ? groups : groups.reversed() {
            var part = ""
            for b in group.sorted(by: { newest ? $0.record.date > $1.record.date : $0.record.date < $1.record.date }) {
                k += 1
                let when = b.record.date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "en_GB")))
                let heading = "Meeting \(k): \"\(b.record.title)\", \(when)"
                var block = heading + "\n"
                for line in b.lines {
                    n += 1
                    block += "[\(n)] \(line.text)\n"
                    sources[n] = Source(meeting: b.record.id, at: line.at)
                    headings[n] = heading
                }
                part += (part.isEmpty ? "" : "\n") + block
            }
            if !part.isEmpty { parts.append(part) }
        }
        let text = parts.joined(separator: "\n")
        let read = groups.flatMap { $0 }
        self.text = text
        self.sources = sources
        self.headings = headings
        self.parts = parts
        today = now.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: "en_GB")))
        // How many it looked through: all down to the oldest it read (a broad question
        // passes over meetings without decisions when asked for decisions).
        let oldest = read.map(\.record.date).min()
        meetings = broad ? oldest.map { o in inRange.filter { $0.date >= o }.count } ?? 0 : read.count
        let sample = read.flatMap { $0.lines.map(\.text) }.joined(separator: " ")
        language = Lines.languageName(of: question.split(separator: " ").count >= 3 ? question : sample) ?? "Swedish"
    }

    /// A broad question: each meeting's notes, newest first, for as many as fit. What it
    /// was about, the decisions, the tasks with who does them, your own notes and the
    /// moments you marked with words, then what's worth remembering; a meeting without
    /// notes gives a few of its sentences from start to end instead.
    /// Asked for the decisions or the tasks: only those, from the meetings that have
    /// any, each with a line on what the meeting was about (none anywhere: everything).
    @MainActor private static func notes(of pool: [MeetingRecord], local: Bool,
                                         focus: QuestionKind.Focus, parts: Int) -> [(record: MeetingRecord, lines: [(text: String, at: Double?)])] {
        let budget = local ? localBudget : parts * applePart
        let perMeeting = local ? 1_500 : 260
        var picked: [(record: MeetingRecord, lines: [(text: String, at: Double?)])] = []
        var words = 0
        for record in pool {
            var lines: [(text: String, at: Double?)] = []
            let s = record.summary
            if focus != .all {
                let written = Set(((s?.decisions ?? []) + (s?.tasks ?? [])).map { $0.text.lowercased() })
                if focus == .decisions {
                    for d in s?.decisions ?? [] { lines.append(("Decision: \(d.text)", d.at)) }
                } else {
                    for t in s?.tasks ?? [] {
                        lines.append(("Task: \(t.text)\(t.owner.map { " (\($0))" } ?? "")\(t.done == true ? " (done)" : "")", t.at))
                    }
                }
                for mark in record.marks where mark.kind == (focus == .decisions ? .decision : .task) {
                    guard let words = mark.text?.trimmingCharacters(in: .whitespaces), !words.isEmpty,
                          !written.contains(words.lowercased()) else { continue }
                    lines.append(("You marked \(Self.kind(mark.kind)): \(words)", mark.at))
                }
                guard !lines.isEmpty else { continue }
                if let s, !s.overview.isEmpty { lines.insert(("Summary: " + MeetingNotes.firstSentences(s.overview, 1), nil), at: 0) }
                let count = 12 + lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
                if words + count > budget, !picked.isEmpty { break }
                words += count
                picked.append((record, lines))
                continue
            }
            if let s, !s.overview.isEmpty {
                lines.append(("Summary: " + (local ? s.overview : MeetingNotes.firstSentences(s.overview, 2)), nil))
            }
            for d in s?.decisions ?? [] { lines.append(("Decision: \(d.text)", d.at)) }
            for t in s?.tasks ?? [] {
                lines.append(("Task: \(t.text)\(t.owner.map { " (\($0))" } ?? "")\(t.done == true ? " (done)" : "")", t.at))
            }
            for note in record.notes where !note.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(("Your note: \(note.text)", note.at))
            }
            // A mark with words is in the notes already, unless they were written before it.
            let written = Set(((s?.decisions ?? []) + (s?.tasks ?? []) + (s?.points ?? [])).map { $0.text.lowercased() })
            for mark in record.marks {
                guard let words = mark.text?.trimmingCharacters(in: .whitespaces), !words.isEmpty,
                      !written.contains(words.lowercased()) else { continue }
                lines.append(("You marked \(Self.kind(mark.kind)): \(words)", mark.at))
            }
            for p in (s?.points ?? []).prefix(local ? 8 : 3) { lines.append(("Point: \(p.text)", p.at)) }
            if s == nil || lines.isEmpty {
                // No notes: a handful of sentences spread over the meeting.
                let said = MeetingSearch.sentences(of: record)
                let take = min(said.count, local ? 12 : 5)
                for k in 0..<take {
                    let line = said[k * said.count / max(take, 1)]
                    lines.append(("\(line.speaker.isEmpty ? "?" : line.speaker): \(line.text)", line.start))
                }
            }
            var block: [(text: String, at: Double?)] = []
            var count = 12      // the meeting's title and date
            for line in lines {
                let n = line.text.split(separator: " ").count
                if count + n > perMeeting, !block.isEmpty { break }
                block.append(line)
                count += n
            }
            // Full: the newest that fit, said in the answer.
            if words + count > budget, !picked.isEmpty { break }
            words += count
            picked.append((record, block))
        }
        return picked
    }

    private static func kind(_ kind: MeetingRecord.Mark.Kind) -> String {
        switch kind {
        case .decision: "a decision"
        case .task: "a task"
        case .important: "something important"
        }
    }

    /// A particular question: the meetings that hold the most of it, each with what it
    /// was about, the notes that match (all of them, when there's room) and the lines
    /// that say it with their neighbours, in the order they were said, until the budget.
    @MainActor private static func matching(_ question: String, in pool: [MeetingRecord], nameless: Bool, now: Date,
                                            budget: Int) -> [(record: MeetingRecord, lines: [(text: String, at: Double?)])] {
        let keys = LibraryContext.content(question)
        // Apple's small model: room for the notes that match, not all of them.
        let compact = budget < 4_000
        struct Line { let text: String; let at: Double?; let score: Double }
        struct Scored { let record: MeetingRecord; let score: Double; let head: [Line]; let said: [Line] }
        var scored: [Scored] = []
        for record in pool {
            var head: [Line] = []
            for s in MeetingSearch.summaryLines(of: record) {
                let label = switch s.kind {
                case "overview": "Summary"
                case "decision": "Decision"
                case "task": "Task"
                default: "Point"
                }
                let text = s.kind == "overview" && compact ? MeetingNotes.firstSentences(s.text, 2) : s.text
                head.append(Line(text: "\(label): \(MeetingNotes.undash(text))", at: s.at, score: Lines.overlap(keys, Lines.keys(s.text))))
            }
            for n in record.notes where !n.text.trimmingCharacters(in: .whitespaces).isEmpty {
                head.append(Line(text: "Your note: \(n.text)", at: n.at, score: Lines.overlap(keys, Lines.keys(n.text))))
            }
            let said = MeetingSearch.sentences(of: record).map { s in
                Line(text: "\(s.speaker.isEmpty ? "?" : s.speaker): \(s.text)", at: s.start, score: Lines.overlap(keys, Lines.keys(s.text)))
            }
            let title = Lines.overlap(keys, Lines.keys(record.title))
            // The notes count a little more than a line: they're what mattered.
            let best = (head.map { $0.score + 0.15 } + said.map(\.score)).sorted(by: >).prefix(5).reduce(0, +)
            // With nothing to match (a question only about days), newer meetings first.
            let fresh = 0.01 * max(0, 30 - now.timeIntervalSince(record.date) / 86_400) / 30
            scored.append(Scored(record: record, score: best + title * 2 + fresh, head: head, said: said))
        }
        scored.sort { $0.score > $1.score }

        var picked: [(record: MeetingRecord, lines: [(text: String, at: Double?)])] = []
        var words = 0
        for s in scored.prefix(keys.isEmpty ? 8 : 12) where s.score > 0 || keys.isEmpty || nameless {
            // What it was about first, then the notes that match — all of them with room.
            var block: [(text: String, at: Double?)] = []
            let head = s.head.filter { line in
                !compact || line.text.hasPrefix("Summary:") || line.score > 0 || keys.isEmpty
            }
            var chosen = Set<Int>()
            let ranked = s.said.indices.sorted { s.said[$0].score != s.said[$1].score ? s.said[$0].score > s.said[$1].score : $0 < $1 }
            for i in ranked.prefix(6) where s.said[i].score > 0 {
                for j in [i - 1, i, i + 1] where s.said.indices.contains(j) { chosen.insert(j) }
            }
            // Without matching lines, the beginning of what was said gives the gist.
            if chosen.isEmpty { for j in s.said.indices.prefix(head.isEmpty ? 6 : 2) { chosen.insert(j) } }
            for line in head + chosen.sorted().map({ s.said[$0] }) {
                let n = line.text.split(separator: " ").count
                if words + n > budget { break }
                words += n
                block.append((line.text, line.at))
            }
            if !block.isEmpty { picked.append((s.record, block)) }
            if words >= budget - 30 { break }
        }
        return picked
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
        // "den senaste veckan", "de senaste sju dagarna": the seven days up to now (as the week card counts).
        if ["senaste veckan", "senaste sju dagarna", "senaste 7 dagarna", "past week", "last 7 days", "last seven days"]
            .contains(where: { q.contains($0) }) {
            return now.addingTimeInterval(-7 * 86_400)...now
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
    /// How many meetings it read…
    let read: Int
    /// …of how many, for a broad question: fewer, and it read the newest.
    var total: Int? = nil
    /// …in this folder (nil: all of them).
    var folder: String? = nil
    var folderID: UUID? = nil
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
        // A folder chosen in the list: the question is about its meetings.
        let folder = MeetingFolders.shared.selected
        let folderName = MeetingFolders.shared.folder(folder)?.name
        let meetings = MeetingStore.shared.meetings.filter { !$0.words.isEmpty && (folder == nil || $0.folder == folder) }
        guard !meetings.isEmpty else {
            failed = folderName.map { String(localized: "Inga möten med text i \($0) än.") }
            return
        }
        // Not the large model during a meeting: it would crowd the live transcription.
        let local = BetterNotes.shared.isActive && !MeetingSession.shared.isRecording
        // Then only Apple's model answers: without it, say so plainly.
        guard local || Polisher.status == .available else {
            failed = MeetingNotes.onlyAppleDuringMeeting
            return
        }
        asking = true
        failed = nil
        // The questions before, in the same folder — not what was asked about others.
        let history = answers.filter { $0.folderID == folder }.suffix(2).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        Task {
            defer { asking = false }
            do {
                let t0 = Date()
                let answer = try await Self.answer(question, meetings: meetings, folder: folder, folderName: folderName,
                                                   history: history, local: local)
                answers.append(answer)
                Self.log.info("answered across \(answer.read) meetings in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            } catch {
                Self.log.error("ask across: \(error.localizedDescription, privacy: .public)")
                failed = MeetingNotes.explainError(error)
            }
        }
    }

    /// A question about `meetings` (a folder's, or all), answered — saves nothing.
    static func answer(_ question: String, meetings: [MeetingRecord], folder: UUID?, folderName: String?,
                       history: String, local: Bool, now: Date = Date()) async throws -> LibraryAnswer {
        let context = LibraryContext(question: question, meetings: meetings, local: local, folder: folderName, now: now)
        // Nothing to read (no meetings on the days asked about, nothing that matches):
        // said plainly, not filled in by the model.
        guard context.meetings > 0 else {
            let none = context.broad ? String(localized: "Det finns inga möten från den tiden.")
                                     : String(localized: "Jag hittar inget om det i mötena.")
            return LibraryAnswer(question: question, answer: none, sources: [], read: 0, total: context.broad ? 0 : nil,
                                 folder: folderName, folderID: folder)
        }
        let reply = try await MeetingNotes.answerAcross(question, context: context, history: history, local: local)
        let titles = Dictionary(meetings.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let sources: [LibraryAnswer.Source] = reply.lines.compactMap { n in
            guard let s = context.sources[n], let title = titles[s.meeting] else { return nil }
            let source = LibraryAnswer.Source(meeting: s.meeting, title: title, at: s.at)
            return seen.insert(source.id).inserted ? source : nil
        }
        return LibraryAnswer(question: question, answer: reply.answer, sources: sources, read: context.meetings,
                             total: context.broad ? context.total : nil, folder: folderName, folderID: folder)
    }

    #if DEBUG
    /// Waits for the question in flight (the render test).
    func waitUntilAnswered() async { while asking { try? await Task.sleep(for: .milliseconds(200)) } }
    #endif

    func forget(_ answer: LibraryAnswer) { answers.removeAll { $0.id == answer.id } }
    func clear() { answers = []; failed = nil }
}

#if DEBUG
// MARK: - Self-test: questions at three levels, read-only

/// `Mindtalk --ask-test [--store dir] [--model apple|gemma] [--now 2026-10-16T16:00:00Z]
/// [--title "del av titel"] [--folder "namn"] [--one "fråga|fråga"] [--lib "fråga|fråga"]`:
/// questions about one meeting, a folder's meetings and all meetings, with each model
/// there is, printed with how many meetings were read and the sources. The meetings
/// are read from their meeting.json files into memory only: nothing is saved, moved or
/// trashed, and the app's own store is never loaded.
enum AskTest {
    @MainActor static func run() async {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let root = value("--store").map { URL(fileURLWithPath: $0) } ?? MeetingStore.root
        let meetings = read(root).filter { !$0.words.isEmpty }.sorted { $0.date > $1.date }
        let names = folderNames(root)
        let now = value("--now").flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        var models: [Bool] = []
        if BetterNotes.shared.isActive, value("--model") != "apple" { models.append(true) }
        if Polisher.status == .available, value("--model") != "gemma" { models.append(false) }
        print("\(meetings.count) möten i \(root.path) · Apple Intelligence: \(Polisher.status) · Gemma: \(BetterNotes.shared.writerName)")
        // How questions are told apart (QuestionKind): broad reads the notes, particular the lines.
        let samples = ["Vad är läget?", "Sammanfatta mötet.", "Vad hände den här veckan?", "Vilka beslut har vi tagit?",
                       "Vad ska jag göra?", "Vem har lovat vad?", "Vilka uppgifter har jag?", "Vad pratade vi om i går?",
                       "Vem gör vad?", "Vad var det viktigaste?", "What happened last week?", "Vad bestämde vi om budgeten?",
                       "Vad sa Anna om priset?", "Vilka risker togs upp?", "Vad sades om gratis AI-modeller?",
                       "När ska offerten skickas?", "Vad har vi sagt om presentationsverktyget?"]
        for q in samples { print("\(QuestionKind.isBroad(q) ? "bred     " : "särskild ") \(q)") }
        guard !meetings.isEmpty, !models.isEmpty else { return print("Inget att fråga med.") }

        // One meeting: the one named, or the longest with notes.
        let one = value("--title").flatMap { t in meetings.first { $0.title.localizedCaseInsensitiveContains(t) } }
            ?? meetings.filter { $0.summary != nil }.max { $0.words.count < $1.words.count } ?? meetings[0]
        // A folder: the one named, or the one with the most meetings.
        let counts = Dictionary(grouping: meetings.compactMap(\.folder), by: { $0 }).mapValues(\.count)
        let folder = value("--folder").flatMap { n in names.first { $0.value.localizedCaseInsensitiveContains(n) }?.key }
            ?? counts.max { $0.value < $1.value }?.key
        let oneQuestions = value("--one")?.split(separator: "|").map(String.init)
            ?? ["Sammanfatta mötet.", "Vad bestämdes?", "Vem ska göra vad?"]
        let libQuestions = value("--lib")?.split(separator: "|").map(String.init)
            ?? ["Vad hände i mötena den senaste veckan?", "Vilka beslut har vi tagit?", "Vad ska jag göra?", "Vem har lovat vad?"]

        for local in models {
            print("\n════ \(local ? BetterNotes.shared.writerName : "Apple Intelligence") ════")
            print("\n── Ett möte: \"\(one.title)\" (\(one.words.count) ord) ──")
            for q in oneQuestions {
                let t0 = Date()
                do {
                    let a = try await MeetingNotes.answer(q, from: Lines(one), summary: one.summary, local: local)
                    print(String(format: "\n? %@  (%.1f s, %@)\n  %@\n  källor: %@", q, Date().timeIntervalSince(t0),
                                 QuestionKind.isBroad(q) ? "bred" : "särskild", a.answer,
                                 a.sources.map { MeetingView.duration($0) }.joined(separator: ", ")))
                } catch { print("\n? \(q)\n  Fel: \(MeetingNotes.explainError(error)) (\(error))") }
            }
            var levels: [(String, UUID?, String?, [MeetingRecord])] = []
            if let folder {
                let name = names[folder] ?? "Mappen"
                levels.append(("Mappen \"\(name)\"", folder, name, meetings.filter { $0.folder == folder }))
            }
            levels.append(("Alla möten", nil, nil, meetings))
            for (label, id, name, scope) in levels {
                print("\n── \(label) (\(scope.count) möten) ──")
                for q in libQuestions {
                    let t0 = Date()
                    do {
                        let a = try await MeetingLibrary.answer(q, meetings: scope, folder: id, folderName: name,
                                                                history: "", local: local, now: now)
                        print(String(format: "\n? %@  (%.1f s, %@, läste %d möten%@)\n  %@", q, Date().timeIntervalSince(t0),
                                     a.total == nil ? "särskild" : "bred", a.read, a.total.map { " av \($0)" } ?? "", a.answer))
                        for s in a.sources { print("  källa: \(s.title) \(s.at.map { MeetingView.duration($0) } ?? "")") }
                    } catch { print("\n? \(q)\n  Fel: \(MeetingNotes.explainError(error)) (\(error))") }
                }
            }
        }
    }

    /// Every meeting.json under `root`, decoded — nothing else is touched.
    private static func read(_ root: URL) -> [MeetingRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("meeting.json"))).flatMap { try? decoder.decode(MeetingRecord.self, from: $0) }
        }
    }

    private static func folderNames(_ root: URL) -> [UUID: String] {
        struct Folder: Decodable { let id: UUID; let name: String }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Folders.json")),
              let folders = try? JSONDecoder().decode([Folder].self, from: data) else { return [:] }
        return Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
}
#endif
