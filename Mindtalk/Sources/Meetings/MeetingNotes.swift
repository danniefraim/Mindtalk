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

/// The language meeting notes are written in: the meeting's own (as spoken), or one
/// you choose — notes in English from a meeting held in Swedish, for instance.
enum SummaryLanguage: String, CaseIterable, Identifiable {
    case meeting, swedish, english
    var id: String { rawValue }

    static var chosen: SummaryLanguage {
        get { UserDefaults.standard.string(forKey: "summaryLanguage").flatMap(SummaryLanguage.init) ?? .meeting }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "summaryLanguage") }
    }

    var title: String {
        switch self {
        case .meeting: return String(localized: "Mötets språk")
        case .swedish: return "Svenska"
        case .english: return "English"
        }
    }

    /// In the ⋯ menu: "Sammanfatta igen › På engelska".
    var menuTitle: String {
        switch self {
        case .meeting: return String(localized: "På mötets språk")
        case .swedish: return String(localized: "På svenska")
        case .english: return String(localized: "På engelska")
        }
    }

    /// What the model is told ("Swedish"), or nil for the meeting's own.
    var name: String? {
        switch self {
        case .meeting: return nil
        case .swedish: return "Swedish"
        case .english: return "English"
        }
    }
}

struct MeetingSummary: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var owner: String? = nil
        /// Where it was said, in seconds — nil when no line could be checked.
        var at: Double? = nil
        /// Tasks: ticked off.
        var done: Bool? = nil
        /// You marked this moment during the meeting.
        var marked: Bool? = nil
    }

    /// A short title for the meeting, used unless you named it yourself.
    var title: String? = nil
    /// Which model wrote it ("Gemma 4"); nil for Apple Intelligence.
    var writer: String? = nil
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
    nonisolated private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "MeetingNotes")

    /// Meetings whose notes are being written right now.
    @Published private(set) var writing: Set<UUID> = []
    /// Meetings with a question being answered.
    @Published private(set) var answering: Set<UUID> = []
    @Published private(set) var failed: [UUID: String] = [:]

    /// Apple Intelligence — or "Bättre anteckningar" (Gemma 4), when installed.
    static var isAvailable: Bool { Polisher.status == .available || BetterNotes.shared.isActive }

    /// Writes (or rewrites) the notes for a saved meeting.
    func summarize(_ id: UUID, in choice: SummaryLanguage = .chosen) {
        guard Self.isAvailable else { return }
        // Asked again while they're being written: written again after, from the
        // meeting as it is then.
        if writing.contains(id) { again[id] = choice; return }
        guard let record = MeetingStore.shared.meetings.first(where: { $0.id == id }), !record.words.isEmpty else { return }
        writing.insert(id)
        failed[id] = nil
        var lines = Lines(record)
        if let name = choice.name { lines.write(in: name) }
        let local = BetterNotes.shared.isActive
        let written = (words: record.words.count, duration: record.duration)
        Task {
            defer {
                writing.remove(id)
                if let next = again.removeValue(forKey: id) { summarize(id, in: next) }
            }
            // Not while a meeting is being recorded: the live words come first.
            while MeetingSession.shared.isRecording { try? await Task.sleep(for: .seconds(2)) }
            do {
                let t0 = Date()
                var summary = try await Self.write(lines, local: local)
                // The meeting went on meanwhile (continued, or listened through again):
                // these notes are of what it was — written again once it's done.
                if MeetingSession.shared.record?.id == id {
                    afterMeeting.insert(id)
                    return
                }
                guard var latest = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                if latest.duration > written.duration + 1 || latest.words.count != written.words, again[id] == nil {
                    again[id] = choice
                    return
                }
                // Written again (a continued meeting, "Sammanfatta igen"): the tasks you
                // ticked off stay ticked where the same task is there again.
                let ticked = Set((latest.summary?.tasks ?? []).filter { $0.done == true }.map { Self.taskKey($0.text) })
                for i in summary.tasks.indices where ticked.contains(Self.taskKey(summary.tasks[i].text)) {
                    summary.tasks[i].done = true
                }
                latest.summary = summary
                if !latest.userTitled, let title = summary.title, !title.isEmpty { latest.title = title }
                MeetingStore.shared.save(latest)
                Self.log.info("notes written in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            } catch {
                Self.log.error("notes: \(error.localizedDescription, privacy: .public)")
                failed[id] = Self.explain(error)
            }
        }
    }

    /// Notes asked for again while they were being written.
    private var again: [UUID: SummaryLanguage] = [:]
    /// Notes put aside because the meeting was being recorded or listened to again —
    /// written when it's done (MeetingSession.done).
    private var afterMeeting: Set<UUID> = []
    func takeAfterMeeting(_ id: UUID) -> Bool { afterMeeting.remove(id) != nil }

    private static func taskKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func ask(_ question: String, about id: UUID) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAvailable, !question.isEmpty, !answering.contains(id),
              let record = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        answering.insert(id)
        failed[id] = nil
        let lines = Lines(record)
        // The last questions, so "och vem?" knows what it follows.
        let history = record.answers.suffix(2).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        let local = BetterNotes.shared.isActive && !MeetingSession.shared.isRecording   // not during a meeting
        Task {
            defer { answering.remove(id) }
            do {
                let answer = try await Self.answer(question, from: lines, history: history, local: local)
                // Continued meanwhile: the answer goes with the meeting being recorded.
                if MeetingSession.shared.record?.id == id {
                    MeetingSession.shared.addAnswer(answer)
                    return
                }
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
        let args = CommandLine.arguments
        let wanted = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        MeetingStore.shared.loadNow()
        guard let found = MeetingStore.shared.meetings.first(where: { wanted == nil || $0.title.contains(wanted!) })
        else { return print("Inga möten.") }
        // `--own-notes "rad|rad"` and `--marks "decision@30,task@55"`: as if written and
        // marked during the meeting — on a copy, nothing saved.
        var record = found
        if let i = args.firstIndex(of: "--own-notes"), i + 1 < args.count {
            record.notes = args[i + 1].split(separator: "|").map { MeetingRecord.Note(text: String($0), at: nil) }
        }
        if let i = args.firstIndex(of: "--marks"), i + 1 < args.count {
            record.marks = args[i + 1].split(separator: ",").compactMap { part -> MeetingRecord.Mark? in
                let p = part.split(separator: "@")
                guard p.count == 2, let kind = MeetingRecord.Mark.Kind(rawValue: String(p[0])), let at = Double(p[1]) else { return nil }
                return MeetingRecord.Mark(at: at, kind: kind)
            }
        }
        var lines = Lines(record)
        // `--in English`: notes in another language than the meeting's.
        if let i = args.firstIndex(of: "--in"), i + 1 < args.count { lines.write(in: args[i + 1]) }
        print("Språk: \(lines.language), \(lines.lines.count) rader, \(lines.parts().count) del(ar)")
        do {
            let t0 = Date()
            let local = BetterNotes.shared.isActive
            print(local ? "Modell: \(BetterNotes.modelName)" : "Modell: Apple Intelligence")
            let s = try await write(lines, local: local)
            print(String(format: "\n(%.1f s)\nTitel: %@\nÖversikt: %@", Date().timeIntervalSince(t0), s.title ?? "–", s.overview))
            let show = { (title: String, items: [MeetingSummary.Item]) in
                print(title)
                for i in items { print("  - \(i.marked == true ? "⚑ " : "")\(i.text)\(i.owner.map { " (\($0))" } ?? "")  [\(i.at.map { MeetingView.duration($0) } ?? "ingen källa")]") }
            }
            show("Beslut:", s.decisions); show("Att göra:", s.tasks); show("Viktigt:", s.points)
            let t1 = Date()
            let a = try await answer(question, from: lines, local: BetterNotes.shared.isActive)
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
        return String(localized: "Apple Intelligence kunde inte göra klart just nu. Försök igen om en stund.")
    }

    // MARK: Writing notes

    @Generable struct Item {
        @Guide(description: "A short sentence in your own words.") var text: String
        @Guide(description: "The number in brackets of the line where this is said.") var line: Int
    }

    @Generable struct Todo {
        @Guide(description: "Something a person will actually do after the meeting — an action, not a thought, opinion or feeling. A short sentence in your own words.") var text: String
        @Guide(description: "Who will do it: the name of the one who says they will, or who is asked to and agrees, exactly as written before the colon in the transcript. Empty if unclear.")
        var owner: String
        @Guide(description: "The number in brackets of the line where this is agreed.") var line: Int
    }

    @Generable struct Outcomes {
        @Guide(description: "Every decision or agreement. Empty if nothing was decided.", .maximumCount(10))
        var decisions: [Item]
        @Guide(description: "Every action someone takes on or is given for after the meeting. Not thoughts or feelings. Empty if none.", .maximumCount(12))
        var tasks: [Todo]
    }

    @Generable struct Overview {
        @Guide(description: "A short title for the meeting: two to five words, no date, no quotation marks.")
        var title: String
        @Guide(description: "What the meeting was about and what came out of it, in one to three sentences, in the third person, naming people only as they are named before the colon in the transcript — never other names. One sentence if the meeting was short.")
        var summary: String
        @Guide(description: "Important facts, figures, concerns or ideas that came up. Empty for a short or casual conversation.", .maximumCount(6))
        var points: [Item]
    }

    @Generable struct Reply {
        @Guide(description: "The answer in one to three full sentences, in your own words, only from what is said in the transcript. Don't copy whole lines. If the transcript doesn't say, say so plainly.")
        var answer: String
        @Guide(description: "The numbers in brackets of the lines the answer comes from. Empty if the transcript doesn't say.", .maximumCount(4))
        var lines: [Int]
    }

    nonisolated private static func instructions(_ language: String, _ task: String) -> String {
        """
        You read a meeting transcript. Each line is "[n] Name: what they said". Write in \(language), in your own words, short. \
        Only use what was actually said: never invent names, numbers, dates or decisions. Give the line number n for every item. \
        Refer to people by their names as written in the transcript, never as "you". \
        \(task)
        """
    }

    private static let options = GenerationOptions(sampling: .greedy)

    /// The notes transform what was said in the meeting — Apple's guardrails for
    /// that, so a meeting about, say, security or health isn't refused as a topic.
    nonisolated private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    nonisolated private static func session(_ instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    nonisolated private static func write(_ lines: Lines, local: Bool = false) async throws -> MeetingSummary {
        var outcomes: [Outcomes] = []
        var overviews: [Overview] = []
        var lastError: Error?
        // Gemma 4: the whole meeting at once (it reads a long one in a single go), in
        // the same line format — and through the same checks below.
        if local {
            for part in lines.parts(budget: Lines.localBudget) {
                let p = parsePlain(try await LocalWriter.shared.respond(
                    plainPrompt(lines.language) + "\n\n" + lines.guidance + "Transcript:\n" + part))
                outcomes.append(Outcomes(decisions: p.decisions, tasks: p.tasks))
                overviews.append(Overview(title: p.title, summary: p.summary, points: p.points))
            }
            if overviews.count > 1 {
                let parts = overviews.enumerated().map { "Part \($0.offset + 1): \($0.element.summary)" }.joined(separator: "\n")
                let merged = try await LocalWriter.shared.respond("""
                    These are summaries of consecutive parts of one meeting. Write one summary of the whole meeting \
                    in \(lines.language), in two or three sentences. Only use what is in the summaries.

                    \(parts)
                    """, maxTokens: 300)
                overviews[0].summary = merged
                overviews = [overviews[0]] + overviews.dropFirst().map { Overview(title: "", summary: "", points: $0.points) }
            }
            var summary = await withMarks(finish(lines, outcomes: outcomes, overviews: overviews), lines, local: true)
            summary.writer = "Gemma 4"
            return summary
        }
        // Each pass on its own: if one is refused, the rest of the notes still come.
        // Apple's guardrails can refuse structured answers about some topics (security,
        // health…) that they allow as plain text — then the same notes are asked for
        // as lines in a fixed format and read back.
        for part in lines.parts() {
            let text = lines.guidance + "Transcript:\n" + part
            var fallback: Plain?
            do {
                outcomes.append(try await session(instructions(lines.language, "Find the decisions and the tasks."))
                    .respond(to: text, generating: Outcomes.self, options: options).content)
            } catch {
                log.error("notes, decisions and tasks: \(String(describing: error), privacy: .public)")
                lastError = error
                fallback = try? await plain(text, lines.language)
                if let fallback { outcomes.append(Outcomes(decisions: fallback.decisions, tasks: fallback.tasks)) }
            }
            do {
                overviews.append(try await session(instructions(
                    lines.language, "Write the overview and the important points, not repeating decisions or tasks."))
                    .respond(to: text, generating: Overview.self, options: options).content)
            } catch {
                log.error("notes, overview: \(String(describing: error), privacy: .public)")
                lastError = error
                if fallback == nil { fallback = try? await plain(text, lines.language) }
                if let fallback, !fallback.summary.isEmpty {
                    overviews.append(Overview(title: fallback.title, summary: fallback.summary, points: fallback.points))
                }
            }
        }
        // Nothing at all: a plain summary, without structure, as a last try.
        if overviews.isEmpty, outcomes.isEmpty {
            do {
                let plain = try await session("""
                    Summarize this meeting transcript in \(lines.language) in two or three sentences, \
                    only from what was said.
                    """).respond(to: "Transcript:\n" + (lines.parts().first ?? ""), options: options).content
                return MeetingSummary(overview: Self.tidy(plain))
            } catch {
                log.error("notes, plain: \(String(describing: error), privacy: .public)")
                throw lastError ?? error
            }
        }
        // A long meeting: one overview from the parts' overviews.
        if overviews.count > 1 {
            let parts = overviews.enumerated().map { "Part \($0.offset + 1): \($0.element.summary)" }.joined(separator: "\n")
            overviews[0].summary = (try? await session("""
                These are summaries of consecutive parts of one meeting. Write one summary of the whole meeting \
                in \(lines.language), in two or three sentences. Only use what is in the summaries.
                """).respond(to: parts, options: options).content) ?? overviews.map(\.summary).joined(separator: " ")
        }
        return await withMarks(finish(lines, outcomes: outcomes, overviews: overviews), lines, local: false)
    }

    /// The moments you marked: each one is in the notes — the item the model wrote
    /// about it if there is one (flagged as yours), otherwise one written from the
    /// lines around it. A mark is pressed just after something is said, so it
    /// covers the line it falls in and the one before.
    nonisolated private static func withMarks(_ summary: MeetingSummary, _ lines: Lines, local: Bool) async -> MeetingSummary {
        var summary = summary
        for mark in lines.marks {
            // The item the model already wrote about those seconds, flagged as yours —
            // unless another mark has it: each mark is its own item.
            let near: (MeetingSummary.Item) -> Bool = { item in
                guard item.marked != true, let at = item.at else { return false }
                return at >= mark.at - 16 && at <= mark.at + 8
            }
            func flag(_ items: inout [MeetingSummary.Item], where match: (MeetingSummary.Item) -> Bool) -> Bool {
                guard let k = items.firstIndex(where: match) else { return false }
                items[k].marked = true
                return true
            }
            // "Viktigt" says something already noted matters: a decision or task there,
            // even one another mark made, is flagged rather than written twice.
            let nearAny: (MeetingSummary.Item) -> Bool = { item in
                guard let at = item.at else { return false }
                return at >= mark.at - 16 && at <= mark.at + 8
            }
            switch mark.kind {
            case .decision: if flag(&summary.decisions, where: near) { continue }
            case .task: if flag(&summary.tasks, where: near) { continue }
            case .important:
                if flag(&summary.points, where: near) || flag(&summary.decisions, where: nearAny)
                    || flag(&summary.tasks, where: nearAny) { continue }
            }
            // Otherwise one written from the sentences there.
            let (said, pressed) = lines.around(mark.at)
            guard !said.isEmpty else { continue }
            let shown = said.enumerated().map { k, line in "\(k == pressed ? "▶ " : "")\(line.speaker): \(line.text)" }
            let fallback = said[pressed].text
            let text = await phrase(mark.kind, shown.joined(separator: "\n"), lines.language, local: local)
                ?? firstSentences(fallback, 1)
            // Where it was said: the sentence it was written from — the pressed one or
            // the one before when they match as well as a later one.
            let keys = Lines.keys(text)
            let score = { (k: Int) in Lines.overlap(keys, Lines.keys(said[k].text)) + (k == pressed || k == pressed - 1 ? 0.15 : 0) }
            let source = said[said.indices.max { score($0) < score($1) } ?? pressed]
            // Already in the notes in other words (often from your own notes): that one, flagged.
            let about = lines.content(text)
            let same: (MeetingSummary.Item) -> Bool = { $0.marked != true && Lines.overlap(about, lines.content($0.text)) >= 0.5 }
            let sameAny: (MeetingSummary.Item) -> Bool = { Lines.overlap(about, lines.content($0.text)) >= 0.6 }
            switch mark.kind {
            case .decision: if flag(&summary.decisions, where: same) { continue }
            case .task: if flag(&summary.tasks, where: same) { continue }
            case .important:
                if flag(&summary.points, where: same) || flag(&summary.decisions, where: sameAny)
                    || flag(&summary.tasks, where: sameAny) { continue }
            }
            // Two marks on one thing (pressed twice while it was said): one item, the fuller.
            func merged(_ items: inout [MeetingSummary.Item]) -> Bool {
                guard let k = items.firstIndex(where: { other in
                    let theirs = lines.content(other.text)
                    return other.marked == true && (Lines.overlap(theirs, about) >= 0.6 || Lines.overlap(about, theirs) >= 0.6)
                }) else { return false }
                if text.count > items[k].text.count { items[k].text = text.trimmingCharacters(in: .whitespaces) }
                return true
            }
            switch mark.kind {
            case .decision: if merged(&summary.decisions) { continue }
            case .task: if merged(&summary.tasks) { continue }
            case .important: if merged(&summary.points) { continue }
            }
            var item = MeetingSummary.Item(text: text.trimmingCharacters(in: .whitespaces), at: source.start, marked: true)
            switch mark.kind {
            case .decision: summary.decisions.append(item)
            case .task:
                item.owner = lines.person(source.speaker)
                summary.tasks.append(item)
            case .important: summary.points.append(item)
            }
        }
        for keyPath in [\MeetingSummary.decisions, \.tasks, \.points] {
            summary[keyPath: keyPath].sort { ($0.at ?? .infinity) < ($1.at ?? .infinity) }
        }
        return summary
    }

    /// One short sentence for a marked moment, from the sentences around it.
    nonisolated private static func phrase(_ kind: MeetingRecord.Mark.Kind, _ said: String, _ language: String,
                                           local: Bool) async -> String? {
        let what = switch kind {
        case .decision: "a decision"
        case .task: "a task someone takes on"
        case .important: "something important"
        }
        let how = kind == .task
            ? "Write the task as a short action in \(language), without saying who does it (that is shown next to it) — " +
              "no I, he, she or name, just what is to be done."
            : "Write it as one short sentence in \(language). Name people as the lines name them (for example " +
              "\"\(language == "English" ? "Speaker 1" : "Talare 1")\"); never write I, he, she or they for a person." +
              (kind == .important ? " Say what is important, not that someone finds it important: if the ▶ line only " +
               "says \"that's important\", write what it refers to from the lines before it." : "")
        let ask = "These lines were said in a meeting. Someone pressed a button to mark \(what) while the line " +
            "marked ▶ was being said:\n\n\(said)\n\nWhat was marked is most likely in the ▶ line or the one before it; " +
            "use a later line only if those hold no \(what). \(how) At most 15 words, only from what was said. " +
            "Just the sentence."
        do {
            var line: String
            if local {
                line = try await LocalWriter.shared.respond(ask, maxTokens: 60)
            } else {
                line = try await LanguageModelSession(model: model,
                                                      instructions: "You write one short note about a moment in a meeting.")
                    .respond(to: ask, generating: MarkPhrase.self, options: options).content.sentence
            }
            line = line.split(separator: "\n").first.map(String.init) ?? line
            // "1. …", "[2] …", "- …": a list the model started.
            if let r = line.range(of: #"^\s*(\[\d+\]|\d+[.)]|[-–•])\s*"#, options: .regularExpression) { line.removeSubrange(r) }
            line = line.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "”", with: "")
            let clean = firstSentences(tidy(line), 1)
            return clean.isEmpty || clean.count > 160 ? nil : clean
        } catch {
            log.error("notes, mark: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @Generable
    struct MarkPhrase {
        @Guide(description: "One short sentence, at most 15 words.")
        var sentence: String
    }

    /// From what the model wrote to the notes shown: every item checked against the
    /// line it came from, decisions and tasks only where something was decided or
    /// promised, owners only if they're in the meeting.
    nonisolated private static func finish(_ lines: Lines, outcomes: [Outcomes], overviews: [Overview]) -> MeetingSummary {
        let overview = overviews.first?.summary ?? ""
        var summary = MeetingSummary(overview: Self.tidy(overview))
        summary.title = overviews.first.map { Self.cleanTitle($0.title) }
        // A decision or task must be found in what was said — in a line where someone
        // decides, or says they'll do something. Otherwise it's left out: the small
        // model likes to turn what a meeting is about into things to do.
        summary.decisions = outcomes.flatMap(\.decisions).compactMap { lines.checked($0.text, line: $0.line, strict: true) }
            .filter { lines.says(.decision, at: $0.at) }
        summary.tasks = outcomes.flatMap(\.tasks).compactMap { task in
            guard var item = lines.checked(task.text, line: task.line, strict: true),
                  lines.says(.intent, at: item.at) else { return nil }
            item.owner = lines.person(task.owner)
            return item
        }
        let taken = Set((summary.decisions + summary.tasks).compactMap(\.at))
        // Worth remembering only if it can be shown where it was said — and few of
        // them for a short talk, where the model otherwise pads.
        summary.points = overviews.flatMap(\.points).compactMap { lines.checked($0.text, line: $0.line) }
            .filter { $0.at != nil && !taken.contains($0.at!) }
        summary.decisions = Self.unique(summary.decisions)
        summary.tasks = Self.unique(summary.tasks)
        let words = lines.wordCount
        summary.points = Array(Self.unique(summary.points).prefix(words < 150 ? 0 : words < 400 ? 2 : 8))
        return summary
    }

    nonisolated private static func answer(_ question: String, from lines: Lines, history: String = "",
                                           local: Bool = false) async throws -> MeetingAnswer {
        // A short question ("vad?") is in the language of the meeting.
        let language = question.split(separator: " ").count >= 3 ? Lines.languageName(of: question) ?? lines.language : lines.language
        let context = lines.relevant(to: history + " " + question, budget: local ? Lines.localBudget : Lines.appleBudget)
        let earlier = history.isEmpty ? "" : "\n\nEarlier questions and answers:\n\(history)"
        let prompt = "Transcript:\n\(context)\(earlier)\n\nQuestion: \(question)"
        let reply: Reply
        do {
            if local { throw LocalAnswer() }
            reply = try await session(instructions(
                language, "Answer the question about the meeting. If the transcript doesn't answer it, say so."))
                .respond(to: prompt, generating: Reply.self, options: options).content
        } catch {
            // Gemma 4, or Apple's model refusing structure: plain text, sources on a last line.
            if !(error is LocalAnswer) { log.error("answer: \(String(describing: error), privacy: .public)") }
            let ask = instructions(language, """
                Answer the question about the meeting in one to three full sentences, in your own words — don't copy \
                the transcript. If the transcript doesn't answer it, say so. \
                On a last line write "SOURCES:" and the numbers of the lines the answer comes from.
                """)
            let text = local
                ? try await LocalWriter.shared.respond(ask + "\n\n" + prompt, maxTokens: 300)
                : try await session(ask).respond(to: prompt, options: options).content
            var answer: [String] = []
            var sources: [Int] = []
            for line in text.components(separatedBy: .newlines) {
                if line.uppercased().contains("SOURCES:") || line.uppercased().contains("KÄLLOR:") {
                    sources = line.split { !$0.isNumber }.compactMap { Int($0) }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    answer.append(line)
                }
            }
            reply = Reply(answer: Plain.unmark(answer.joined(separator: " ")), lines: Array(sources.prefix(4)))
        }
        // Lines quoted as "[4] Anna: …" read as the answer's words, not its references.
        let cleaned = reply.answer.replacingOccurrences(of: #"\[\d+\]\s*([^:\n]{1,40}:\s*)?"#, with: "",
                                                        options: .regularExpression)
        // An answer is often a name or a yes, sharing no words with its line: the
        // lines it names are its sources, as long as they exist.
        let sources = reply.lines.compactMap { lines.start(ofLine: $0) }
        return MeetingAnswer(question: question, answer: Self.firstSentences(Self.tidy(cleaned), 3),
                             sources: Array(Set(sources)).sorted())
    }

    /// A question across meetings (MeetingSearch.swift): answered from the meetings the
    /// context picked, with the numbers of the lines it used.
    nonisolated static func answerAcross(_ question: String, context: LibraryContext, history: String,
                                         local: Bool) async throws -> (answer: String, lines: [Int]) {
        let language = context.language
        let earlier = history.isEmpty ? "" : "\n\nEarlier questions and answers:\n\(history)"
        let prompt = "Today is \(context.today).\n\nMeetings:\n\(context.text)\(earlier)\n\nQuestion: \(question)"
        let task = "You read notes and transcripts from several meetings. Each meeting starts with its title and date; " +
            "each line is \"[n] …\". Answer the question across the meetings in \(language), in one to four full sentences, " +
            "in your own words, speaking to the person who recorded them. Say which meeting when it matters (by its title or " +
            "day). Only use what the lines say; " +
            "if they don't answer it, say so plainly. Never invent names, numbers, dates or decisions."
        let reply: Reply
        do {
            if local { throw LocalAnswer() }
            reply = try await LanguageModelSession(model: model, instructions: task)
                .respond(to: prompt, generating: Reply.self, options: options).content
        } catch {
            if !(error is LocalAnswer) { log.error("answer across: \(String(describing: error), privacy: .public)") }
            let ask = task + " On a last line write \"SOURCES:\" and the numbers of the lines the answer comes from."
            let text = local
                ? try await LocalWriter.shared.respond(ask + "\n\n" + prompt, maxTokens: 400)
                : try await LanguageModelSession(model: model, instructions: ask).respond(to: prompt, options: options).content
            var answer: [String] = []
            var sources: [Int] = []
            for line in text.components(separatedBy: .newlines) {
                if line.uppercased().contains("SOURCES:") || line.uppercased().contains("KÄLLOR:") {
                    sources = line.split { !$0.isNumber }.compactMap { Int($0) }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    answer.append(line)
                }
            }
            reply = Reply(answer: Plain.unmark(answer.joined(separator: " ")), lines: Array(sources.prefix(4)))
        }
        let cleaned = reply.answer.replacingOccurrences(of: #"\[\d+\]\s*([^:\n]{1,40}:\s*)?"#, with: "",
                                                        options: .regularExpression)
        return (Self.firstSentences(Self.tidy(cleaned), 4), reply.lines)
    }

    /// What went wrong, in words for the person asking.
    static func explainError(_ error: Error) -> String { explain(error) }

    nonisolated private static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”“«».")))
        if t.count > 60 { t = String(t.prefix(60)) }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// The notes as Markdown — for mail, Slack, a document.
    static func markdown(_ record: MeetingRecord) -> String {
        let cast = record.cast
        var out = "# \(record.title)\n\n"
        let date = record.date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(AppLanguage.locale))
        let people = cast.order.map { cast.name(of: $0) }.joined(separator: ", ")
        out += people.isEmpty ? "\(date)\n\n" : "\(date) · \(people)\n\n"
        if let informed = record.informed {
            let time = informed.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
            out += String(localized: "Deltagarna informerades om inspelningen kl. \(time).") + "\n\n"
        }
        let own = record.notes.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !own.isEmpty {
            out += "## " + String(localized: "Dina anteckningar") + "\n" + own.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        }
        guard let s = record.summary else { return out + MeetingText.plain(record) }
        out += s.overview + "\n"
        func section(_ title: String, _ items: [MeetingSummary.Item], task: Bool = false) {
            guard !items.isEmpty else { return }
            out += "\n## \(title)\n"
            for i in items {
                let box = task ? (i.done == true ? "[x] " : "[ ] ") : ""
                out += "- \(box)\(i.text)\(i.owner.map { " (\($0))" } ?? "")\n"
            }
        }
        section(String(localized: "Beslut"), s.decisions)
        section(String(localized: "Att göra"), s.tasks, task: true)
        section(String(localized: "Värt att komma ihåg"), s.points)
        return out
    }

    /// The notes as plain lines — for when structured answers are refused.
    struct Plain {
        var title = ""
        var summary = ""
        var decisions: [Item] = []
        var tasks: [Todo] = []
        var points: [Item] = []

        /// "text [12]" → ("text", 12)
        static func split(_ s: String) -> (String, Int) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let open = t.lastIndex(of: "["), let n = Int(t[t.index(after: open)...].filter(\.isNumber)) else {
                return (unmark(t), 0)
            }
            return (unmark(String(t[..<open])), n)
        }

        /// Without Markdown asterisks and stray quotes.
        static func unmark(_ s: String) -> String {
            s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"*")))
        }
    }

    private struct LocalAnswer: Error {}

    nonisolated private static func plainPrompt(_ language: String) -> String {
        """
        You read a meeting transcript. Each line is "[n] Name: what they said". Write in \(language), in your own \
        words, short. Only use what was actually said: never invent names, numbers, dates or decisions. Refer to \
        people only by the names written before the colon. Answer in exactly this format, one item per line, and \
        nothing else:
        TITLE: a title of two to five words
        SUMMARY: one to three sentences about what the meeting was about and what came out of it
        DECISION: a decision that was actually made [n]
        TASK: a concrete action someone will do after the meeting | who will do it [n]
        POINT: an important fact, figure or concern [n]
        Leave out DECISION, TASK or POINT lines when there are none. Thoughts or what the meeting is about are not tasks.
        """
    }

    nonisolated private static func plain(_ text: String, _ language: String) async throws -> Plain {
        parsePlain(try await session(plainPrompt(language)).respond(to: text, options: options).content)
    }

    nonisolated private static func parsePlain(_ reply: String) -> Plain {
        var p = Plain()
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•*")))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].uppercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
            switch key {
            case "TITLE", "TITEL": p.title = Plain.unmark(value)
            case "SUMMARY", "SAMMANFATTNING": p.summary = Plain.unmark(value)
            case "DECISION", "BESLUT":
                let (t, n) = Plain.split(value); if !t.isEmpty { p.decisions.append(Item(text: t, line: n)) }
            case "TASK", "UPPGIFT":
                let (t, n) = Plain.split(value)
                let parts = t.components(separatedBy: "|")
                let what = parts[0].trimmingCharacters(in: .whitespaces)
                if !what.isEmpty {
                    p.tasks.append(Todo(text: what, owner: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "", line: n))
                }
            case "POINT", "PUNKT":
                let (t, n) = Plain.split(value); if !t.isEmpty { p.points.append(Item(text: t, line: n)) }
            default: continue
            }
        }
        return p
    }

    nonisolated static func firstSentences(_ text: String, _ n: Int) -> String {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
            if out.count >= n { stop = true }
        }
        return out.isEmpty ? text : out.joined(separator: " ")
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

        /// Where it ends: where the next one starts.
        func end(in lines: [Line]) -> Double {
            lines.first { $0.start > start }?.start ?? start + 10
        }
    }

    private(set) var lines: [Line]
    /// The language the notes are written in — the meeting's own unless you chose another.
    private(set) var language: String
    /// The notes are in another language than what was said: an item can't be matched
    /// to its line by shared words, so the line the model names is trusted when it exists.
    private(set) var translating = false

    mutating func write(in name: String) {
        translating = name != language
        language = name
        // Unnamed speakers in the notes' language: "Speaker 2" in English notes, "Talare 2" in Swedish.
        let (from, to) = name == "English" ? ("Talare", "Speaker") : name == "Swedish" ? ("Speaker", "Talare") : ("", "")
        guard !from.isEmpty else { return }
        func relabel(_ who: String) -> String {
            who.range(of: #"^\#(from) \d+$"#, options: .regularExpression) != nil
                ? who.replacingOccurrences(of: from, with: to) : who
        }
        lines = lines.map { Line(speaker: relabel($0.speaker), text: $0.text, start: $0.start) }
        sentences = sentences.map { Line(speaker: relabel($0.speaker), text: $0.text, start: $0.start) }
        people = people.map(relabel)
    }
    /// Your own notes and marks (MeetingNotesBox.swift): they steer the notes.
    let notes: [String]
    let marks: [(at: Double, kind: MeetingRecord.Mark.Kind)]
    /// Sentence by sentence, each with its moment — for the marks, which point at
    /// a few seconds rather than a whole line.
    private(set) var sentences: [Line]
    var wordCount: Int { lines.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    private var people: [String]

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
        var sentences: [Line] = []
        var sentence: [String] = []
        var sentenceStart = 0.0
        let cast = record.cast
        for (k, w) in record.words.enumerated() {
            if sentence.isEmpty { sentenceStart = w.start }
            sentence.append(w.text)
            let ends = w.text.last.map { ".?!".contains($0) } ?? false
            if ends || k == record.words.count - 1 {
                let who = w.speaker.map { $0 >= 0 ? cast.name(of: $0) : "?" } ?? "?"
                sentences.append(Line(speaker: who, text: MeetingText.clean(sentence.joined(separator: " ")), start: sentenceStart))
                sentence = []
            }
        }
        self.sentences = sentences
        notes = record.notes.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        marks = record.marks.map { ($0.at, $0.kind) }.sorted { $0.at < $1.at }
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

    /// Words per part: room for instructions and the answer. Apple's model reads about
    /// 3 000 words at a time; Gemma 4 a whole long meeting.
    static let appleBudget = 1_300
    static let localBudget = 60_000

    /// The transcript in parts that fit the model.
    func parts(budget: Int = Lines.appleBudget) -> [String] {
        var parts: [String] = []
        var start = 0, words = 0
        for i in lines.indices {
            let n = lines[i].text.split(separator: " ").count
            if words + n > budget, i > start {
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
    func relevant(to question: String, budget: Int = Lines.appleBudget) -> String {
        let total = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard total > budget else { return numbered(0..<lines.count) }
        let q = Self.keys(question)
        let ranked = lines.indices.sorted { Self.overlap(q, Self.keys(lines[$0].text)) > Self.overlap(q, Self.keys(lines[$1].text)) }
        var chosen = Set<Int>(), words = 0
        for i in ranked {
            for j in [i - 1, i, i + 1] where lines.indices.contains(j) && !chosen.contains(j) {
                let n = lines[j].text.split(separator: " ").count
                guard words + n <= budget else { continue }
                chosen.insert(j)
                words += n
            }
            if words >= budget - 40 { break }
        }
        return chosen.sorted().map { "[\($0 + 1)] \(lines[$0].speaker): \(lines[$0].text)" }.joined(separator: "\n")
    }

    func start(ofLine n: Int) -> Double? { lines.indices.contains(n - 1) ? lines[n - 1].start : nil }

    /// Your notes, put before the transcript: what mattered to you, to be covered.
    var guidance: String {
        guard !notes.isEmpty else { return "" }
        return "The note-taker wrote these notes during the meeting. They show what mattered most to them: " +
            "make sure each one is covered, with the details from the transcript — " +
            "besides everything else in the meeting worth noting.\nNotes:\n" +
            notes.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
    }

    /// The line being said at `at`.
    func index(at: Double) -> Int? { lines.lastIndex { $0.start <= at + 0.5 } ?? (lines.isEmpty ? nil : 0) }

    /// The sentences around a mark — a quarter of a minute before and a few seconds
    /// after — and which of them was being said when it was pressed. That one and
    /// the one before are what it's most likely about; one after only if they aren't.
    func around(_ at: Double) -> (lines: [Line], pressed: Int) {
        var near = sentences.filter { $0.end(in: sentences) >= at - 15 && $0.start <= at + 8 }
        if near.isEmpty { near = sentences.last { $0.start <= at + 0.5 }.map { [$0] } ?? [] }
        let pressed = near.lastIndex { $0.start <= at + 0.5 } ?? 0
        return (near, pressed)
    }

    enum Cue { case decision, intent }

    /// Words that mark a decision or a promise, Swedish and English.
    private static let cues: [Cue: [String]] = [
        .decision: ["bestäm", "beslut", "överens", "kör på", "kör vi", "vi tar", "vi gör", "vi siktar", "siktar på", "då blir det",
                    "vi väljer", "vi satsar", "vi håller med", "håller med", "så gör vi", "låt oss", "agreed", "decide", "decision",
                    "let's", "we'll go", "we will", "go with", "settled"],
        .intent: ["ska ", "ska jag", "jag tar", "jag fixar", "jag kollar", "jag skickar", "jag bokar", "jag gör", "jag ringer",
                  "kan du", "kan ni", "fixar", "tar hand om", "kommer att", "måste", "behöver", "lovar", "bokar", "skickar",
                  "ringer", "gör det", "i'll", "i will", "i can", "can you", "could you", "will you", "we'll", "need to",
                  "going to", "take care"],
    ]

    /// Whether the line said at `at` (or the one right after, where the reply often is)
    /// holds a decision or a promise.
    func says(_ cue: Cue, at: Double?) -> Bool {
        guard let at, let i = lines.lastIndex(where: { $0.start <= at + 0.05 }) else { return false }
        let words = Self.cues[cue] ?? []
        return [i, i + 1].contains { j in
            guard lines.indices.contains(j) else { return false }
            let text = " " + lines[j].text.lowercased() + " "
            return words.contains { text.contains($0) }
        }
    }

    /// The item, with the moment it was said — if the line the model named (or one
    /// close to it) really says it. `strict`: without a matching line, drop the item.
    func checked(_ text: String, line: Int, strict: Bool = false) -> MeetingSummary.Item? {
        if translating {
            guard let at = start(ofLine: line) else { return strict || text.isEmpty ? nil : MeetingSummary.Item(text: text) }
            return MeetingSummary.Item(text: text, at: at)
        }
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

    /// What a sentence is about: its word stems without the people's names and the
    /// small words every sentence has ("Talare 1 behöver…" is not a match in itself).
    func content(_ text: String) -> Set<String> {
        let names = people.reduce(into: Set<String>()) { $0.formUnion(Self.keys($1)) }
        return Self.keys(text).subtracting(names).subtracting(Self.common)
    }

    private static let common: Set<String> = ["behöv", "måste", "kommer", "också", "det", "att", "och", "som", "för",
                                              "inte", "ska", "kan", "the", "and", "need", "will", "that", "this"]

    /// Word stems (first five letters) of words of three letters or more.
    static func keys(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map { String($0.prefix(5)) })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.count)
    }
}
