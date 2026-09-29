import Foundation
import FoundationModels
import NaturalLanguage
import os

// MARK: - Notes and answers
//
// After a meeting, Apple's on-device model (Apple Intelligence) writes notes:
// what it was about, what was decided, who does what, what's worth remembering.
// And it answers questions about the meeting. Nothing leaves the Mac.
//
// The model sees the transcript as numbered lines and names the line behind
// everything it writes. That line is then checked: the item has to share words
// with it (or with a line close by) — otherwise it gets no source rather than a
// wrong one. Every source can be heard: it's a moment in the recording.
//
// The model reads about 3 000 words at a time, so a long meeting is read in
// parts and the parts' notes are put together.

struct MeetingSummary: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var owner: String? = nil
        /// Where it was said, in seconds — nil when no line could be checked.
        var at: Double? = nil
    }

    var overview: String
    var decisions: [Item] = []
    var tasks: [Item] = []
    var points: [Item] = []
    var created = Date()
}

struct MeetingAnswer: Codable, Equatable, Identifiable {
    var id = UUID()
    var question: String
    var answer: String
    var sources: [Double] = []
    var date = Date()
}

@MainActor
final class MeetingNotes: ObservableObject {
    static let shared = MeetingNotes()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "MeetingNotes")

    /// Meetings whose notes are being written right now.
    @Published private(set) var writing: Set<UUID> = []
    /// Meetings with a question being answered.
    @Published private(set) var answering: Set<UUID> = []
    @Published private(set) var failed: [UUID: String] = [:]

    static var isAvailable: Bool { Polisher.status == .available }

    /// Writes (or rewrites) the notes for a saved meeting.
    func summarize(_ id: UUID) {
        guard Self.isAvailable, !writing.contains(id),
              let record = MeetingStore.shared.meetings.first(where: { $0.id == id }), !record.words.isEmpty else { return }
        writing.insert(id)
        failed[id] = nil
        let lines = Lines(record)
        Task {
            defer { writing.remove(id) }
            do {
                let t0 = Date()
                let summary = try await Self.write(lines)
                guard var latest = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                latest.summary = summary
                MeetingStore.shared.save(latest)
                Self.log.info("notes written in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            } catch {
                Self.log.error("notes: \(error.localizedDescription, privacy: .public)")
                failed[id] = Self.explain(error)
            }
        }
    }

    func ask(_ question: String, about id: UUID) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAvailable, !question.isEmpty, !answering.contains(id),
              let record = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        answering.insert(id)
        failed[id] = nil
        let lines = Lines(record)
        Task {
            defer { answering.remove(id) }
            do {
                let answer = try await Self.answer(question, from: lines)
                guard var latest = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                latest.answers.append(answer)
                MeetingStore.shared.save(latest)
            } catch {
                Self.log.error("answer: \(error.localizedDescription, privacy: .public)")
                failed[id] = Self.explain(error)
            }
        }
    }

    #if DEBUG
    /// Self-test: notes and an answer for the newest meeting, printed, nothing saved.
    static func selfTest(question: String) async {
        guard let record = MeetingStore.shared.meetings.first else { return print("Inga möten.") }
        let lines = Lines(record)
        print("Språk: \(lines.language), \(lines.lines.count) rader, \(lines.parts().count) del(ar)")
        do {
            let t0 = Date()
            let s = try await write(lines)
            print(String(format: "\n(%.1f s)\nÖversikt: %@", Date().timeIntervalSince(t0), s.overview))
            let show = { (title: String, items: [MeetingSummary.Item]) in
                print(title)
                for i in items { print("  - \(i.text)\(i.owner.map { " (\($0))" } ?? "")  [\(i.at.map { MeetingView.duration($0) } ?? "ingen källa")]") }
            }
            show("Beslut:", s.decisions); show("Att göra:", s.tasks); show("Viktigt:", s.points)
            let t1 = Date()
            let a = try await answer(question, from: lines)
            print(String(format: "\nFråga: %@\nSvar (%.1f s): %@  %@", question, Date().timeIntervalSince(t1), a.answer,
                         a.sources.map { MeetingView.duration($0) }.joined(separator: ", ")))
        } catch {
            print("Fel: \(explain(error)) – \(error)")
        }
    }
    #endif

    func forget(_ answer: MeetingAnswer, in id: UUID) {
        guard var record = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        record.answers.removeAll { $0.id == answer.id }
        MeetingStore.shared.save(record)
    }

    private static func explain(_ error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return String(localized: "Mötet blev för långt för Apple Intelligence.")
            case .guardrailViolation, .refusal: return String(localized: "Apple Intelligence ville inte svara på det här.")
            case .unsupportedLanguageOrLocale: return String(localized: "Apple Intelligence kan inte det här språket.")
            default: break
            }
        }
        return String(localized: "Apple Intelligence kunde inte svara just nu. Försök igen om en stund.")
    }

    // MARK: Writing notes

    @Generable struct Item {
        @Guide(description: "A short sentence in your own words.") var text: String
        @Guide(description: "The number in brackets of the line where this is said.") var line: Int
    }

    @Generable struct Todo {
        @Guide(description: "What will be done, a short sentence in your own words.") var text: String
        @Guide(description: "Who will do it: the name of the one who says they will, or who is asked to and agrees, exactly as written before the colon in the transcript. Empty if unclear.")
        var owner: String
        @Guide(description: "The number in brackets of the line where this is agreed.") var line: Int
    }

    @Generable struct Outcomes {
        @Guide(description: "Every decision or agreement. Empty if nothing was decided.", .maximumCount(10))
        var decisions: [Item]
        @Guide(description: "Every task someone takes on or is given for after the meeting. Empty if none.", .maximumCount(12))
        var tasks: [Todo]
    }

    @Generable struct Overview {
        @Guide(description: "What the meeting was about and what came out of it, in one to three sentences, in the third person with the people's names (\"Anna och Erik gick igenom …\"). One sentence if the meeting was short.")
        var summary: String
        @Guide(description: "Important facts, figures, concerns or ideas that came up. Empty for a short or casual conversation.", .maximumCount(6))
        var points: [Item]
    }

    @Generable struct Reply {
        @Guide(description: "The answer, short and direct, only from what is said in the transcript. If the transcript doesn't say, say so plainly.")
        var answer: String
        @Guide(description: "The numbers in brackets of the lines the answer comes from. Empty if the transcript doesn't say.", .maximumCount(4))
        var lines: [Int]
    }

    private static func instructions(_ language: String, _ task: String) -> String {
        """
        You read a meeting transcript. Each line is "[n] Name: what they said". Write in \(language), in your own words, short. \
        Only use what was actually said: never invent names, numbers, dates or decisions. Give the line number n for every item. \
        Refer to people by their names as written in the transcript, never as "you". \
        \(task)
        """
    }

    private static let options = GenerationOptions(sampling: .greedy)

    nonisolated private static func write(_ lines: Lines) async throws -> MeetingSummary {
        var outcomes: [Outcomes] = []
        var overviews: [Overview] = []
        for part in lines.parts() {
            let text = "Transcript:\n" + part
            outcomes.append(try await LanguageModelSession(instructions: instructions(lines.language, "Find the decisions and the tasks."))
                .respond(to: text, generating: Outcomes.self, options: options).content)
            overviews.append(try await LanguageModelSession(instructions: instructions(
                lines.language, "Write the overview and the important points, not repeating decisions or tasks."))
                .respond(to: text, generating: Overview.self, options: options).content)
        }
        // A long meeting: one overview from the parts' overviews.
        var overview = overviews.first?.summary ?? ""
        if overviews.count > 1 {
            let parts = overviews.enumerated().map { "Part \($0.offset + 1): \($0.element.summary)" }.joined(separator: "\n")
            overview = try await LanguageModelSession(instructions: """
                These are summaries of consecutive parts of one meeting. Write one summary of the whole meeting \
                in \(lines.language), in two or three sentences. Only use what is in the summaries.
                """).respond(to: parts, options: options).content
        }

        var summary = MeetingSummary(overview: Self.tidy(overview))
        summary.decisions = outcomes.flatMap(\.decisions).compactMap { lines.checked($0.text, line: $0.line) }
        summary.tasks = outcomes.flatMap(\.tasks).compactMap { task in
            guard var item = lines.checked(task.text, line: task.line) else { return nil }
            item.owner = lines.person(task.owner)
            return item
        }
        let taken = Set((summary.decisions + summary.tasks).compactMap(\.at))
        summary.points = overviews.flatMap(\.points).compactMap { lines.checked($0.text, line: $0.line) }
            .filter { $0.at == nil || !taken.contains($0.at!) }
        summary.decisions = Self.unique(summary.decisions)
        summary.tasks = Self.unique(summary.tasks)
        summary.points = Array(Self.unique(summary.points).prefix(8))
        return summary
    }

    nonisolated private static func answer(_ question: String, from lines: Lines) async throws -> MeetingAnswer {
        let language = Lines.languageName(of: question) ?? lines.language
        let context = lines.relevant(to: question)
        let reply = try await LanguageModelSession(instructions: instructions(
            language, "Answer the question about the meeting. If the transcript doesn't answer it, say so."))
            .respond(to: "Transcript:\n\(context)\n\nQuestion: \(question)", generating: Reply.self, options: options).content
        // An answer is often a name or a yes, sharing no words with its line: the
        // lines it names are its sources, as long as they exist.
        let sources = reply.lines.compactMap { lines.start(ofLine: $0) }
        return MeetingAnswer(question: question, answer: Self.tidy(reply.answer),
                             sources: Array(Set(sources)).sorted())
    }

    /// Drops a sentence said twice (small models sometimes loop).
    nonisolated static func tidy(_ text: String) -> String {
        var seen = Set<String>()
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            if seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out.joined(separator: " ")
    }

    nonisolated private static func unique(_ items: [MeetingSummary.Item]) -> [MeetingSummary.Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.text.lowercased()).inserted }
    }
}

/// The transcript as the model sees it: numbered lines, one per turn (long turns
/// split at sentences), each with the moment it starts.
struct Lines: Sendable {
    struct Line: Sendable {
        let speaker: String
        let text: String
        let start: Double
    }

    let lines: [Line]
    let language: String
    private let people: [String]

    @MainActor init(_ record: MeetingRecord) {
        var lines: [Line] = []
        let turns = MeetingText.turns(record.words)
        for (t, turn) in turns.enumerated() {
            let who = turn.speaker.map { $0 >= 0 ? record.name(of: $0) : "?" } ?? "?"
            // Long turns in pieces of about 60 words, at sentence ends.
            let end = t + 1 < turns.count ? turns[t + 1].id : record.words.count
            var piece: [String] = []
            var pieceStart = turn.start
            for w in record.words[turn.id..<end] {
                if piece.isEmpty { pieceStart = w.start }
                piece.append(w.text)
                if piece.count >= 60, let c = w.text.last, ".?!".contains(c) {
                    lines.append(Line(speaker: who, text: MeetingText.clean(piece.joined(separator: " ")), start: pieceStart))
                    piece = []
                }
            }
            if !piece.isEmpty {
                lines.append(Line(speaker: who, text: MeetingText.clean(piece.joined(separator: " ")), start: pieceStart))
            }
        }
        self.lines = lines
        people = Array(Set(lines.map(\.speaker)))
        let all = lines.map(\.text).joined(separator: " ")
        language = Self.languageName(of: all) ?? (record.language == .swedish ? "Swedish" : "English")
    }

    /// "Swedish", "English"… — the model is told in English which language to write.
    static func languageName(of text: String) -> String? {
        guard let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
    }

    private func numbered(_ range: Range<Int>) -> String {
        range.map { "[\($0 + 1)] \(lines[$0].speaker): \(lines[$0].text)" }.joined(separator: "\n")
    }

    private static let budget = 1_300           // words per part: room for instructions and the answer

    /// The transcript in parts that fit the model.
    func parts() -> [String] {
        var parts: [String] = []
        var start = 0, words = 0
        for i in lines.indices {
            let n = lines[i].text.split(separator: " ").count
            if words + n > Self.budget, i > start {
                parts.append(numbered(start..<i))
                start = i
                words = 0
            }
            words += n
        }
        if start < lines.count { parts.append(numbered(start..<lines.count)) }
        return parts
    }

    /// For a question: the whole meeting if it fits, otherwise the lines that share
    /// the most words with the question (and their neighbours), in order.
    func relevant(to question: String) -> String {
        let total = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard total > Self.budget else { return numbered(0..<lines.count) }
        let q = Self.keys(question)
        let ranked = lines.indices.sorted { Self.overlap(q, Self.keys(lines[$0].text)) > Self.overlap(q, Self.keys(lines[$1].text)) }
        var chosen = Set<Int>(), words = 0
        for i in ranked {
            for j in [i - 1, i, i + 1] where lines.indices.contains(j) && !chosen.contains(j) {
                let n = lines[j].text.split(separator: " ").count
                guard words + n <= Self.budget else { continue }
                chosen.insert(j)
                words += n
            }
            if words >= Self.budget - 40 { break }
        }
        return chosen.sorted().map { "[\($0 + 1)] \(lines[$0].speaker): \(lines[$0].text)" }.joined(separator: "\n")
    }

    func start(ofLine n: Int) -> Double? { lines.indices.contains(n - 1) ? lines[n - 1].start : nil }

    /// The item, with the moment it was said — if the line the model named (or one
    /// close to it) really says it. `strict`: without a matching line, drop the item.
    func checked(_ text: String, line: Int, strict: Bool = false) -> MeetingSummary.Item? {
        let words = Self.keys(text)
        let named = line - 1
        var best: (index: Int, score: Double)?
        for i in lines.indices {
            let score = Self.overlap(words, Self.keys(lines[i].text)) - (abs(i - named) <= 2 ? 0 : 0.35)
            if best == nil || score > best!.score { best = (i, score) }
        }
        guard let best, best.score >= 0.2 else {
            return strict || text.isEmpty ? nil : MeetingSummary.Item(text: text)
        }
        return MeetingSummary.Item(text: text, at: lines[best.index].start)
    }

    /// A name the model gave as owner, if it's someone in the meeting or mentioned in it.
    func person(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > 1 else { return nil }
        if let match = people.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        let mentioned = lines.contains { $0.text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return mentioned ? name : nil
    }

    /// Word stems (first five letters) of words of three letters or more.
    static func keys(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map { String($0.prefix(5)) })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.count)
    }
}
