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
        set { Settings.keep(newValue.rawValue, forKey: "summaryLanguage") }
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
    /// Your notes and the marks you gave words, as they were when this was written
    /// (MeetingRecord.notesFingerprint): differ now, and the summary says so. Nil in
    /// summaries from before it was kept; they never say so.
    var notesFrom: String? = nil

    /// Spelled your way: the Ordlista over every line the model wrote (the words it
    /// read were fixed, but a model may spell a name as it likes). Strings only.
    @MainActor mutating func applyVocabulary() {
        let fix = { (text: String) in Vocabulary.shared.reapply(text) }
        title = title.map(fix)
        overview = fix(overview)
        for keyPath in [\MeetingSummary.decisions, \MeetingSummary.tasks, \MeetingSummary.points] {
            for i in self[keyPath: keyPath].indices {
                self[keyPath: keyPath][i].text = fix(self[keyPath: keyPath][i].text)
                self[keyPath: keyPath][i].owner = self[keyPath: keyPath][i].owner.map(fix)
            }
        }
    }
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
    /// The notes weren't written because Ollama or LM Studio, chosen to write them,
    /// isn't running or isn't on this Mac: which, so the page can offer to open it and
    /// try again. Never written by another model instead.
    @Published private(set) var failedServer: [UUID: ServerBackend] = [:]

    /// Apple Intelligence — or Gemma 4, or your own model in Ollama or LM Studio, when chosen.
    static var isAvailable: Bool { Polisher.status == .available || BetterNotes.shared.isActive }

    /// Whether `choice` can be asked to write: Apple Intelligence only when it is on;
    /// the others are asked, and say so themselves when they can't.
    static func canWrite(_ choice: SummaryWriterChoice) -> Bool { choice != .apple || Polisher.status == .available }

    /// A writer picked for one meeting ("Sammanfatta igen med"), by meeting, while its
    /// notes are being written. The setting is left as it is.
    @Published private(set) var writers: [UUID: SummaryWriterChoice] = [:]
    /// A writer picked for one meeting wrote its notes, and isn't the one chosen for all:
    /// the page asks whether it should be (`keepTried`).
    @Published private(set) var tried: [UUID: SummaryWriterChoice] = [:]

    /// Who writes (or is writing) this meeting's notes, in a sentence: the one picked
    /// for it, else the one chosen for all.
    func writerSentenceName(for id: UUID) -> String { (writers[id] ?? BetterNotes.shared.choice).sentenceName }

    #if DEBUG
    /// `--render-window … --tried`: the meeting just rewritten by `choice`, as if picked
    /// in Skriv om, so the question under the foot shows. In memory only.
    func previewTried(_ id: UUID, _ choice: SummaryWriterChoice) {
        guard Settings.previewing else { return }
        tried[id] = choice
    }
    #endif

    /// "Använd Gemma 4 E4B i alla möten?" answered: Ja makes it the choice for all.
    func keepTried(_ id: UUID, _ keep: Bool) {
        guard let choice = tried.removeValue(forKey: id) else { return }
        if keep { BetterNotes.shared.choice = choice }
    }

    /// Writes (or rewrites) the notes for a saved meeting. `pick`: a writer for this
    /// meeting only; nil for the one chosen under Inställningar.
    func summarize(_ id: UUID, in choice: SummaryLanguage = .chosen, with pick: SummaryWriterChoice? = nil) {
        guard pick.map(Self.canWrite) ?? Self.isAvailable else { return }
        // Asked again while they're being written: written again after, from the
        // meeting as it is then.
        if writing.contains(id) { again[id] = (choice, pick); return }
        guard let record = MeetingStore.shared.meetings.first(where: { $0.id == id }), !record.words.isEmpty else { return }
        writing.insert(id)
        failed[id] = nil
        failedServer[id] = nil
        tried[id] = nil
        writers[id] = pick
        var lines = Lines(record)
        if let name = choice.name { lines.write(in: name) }
        let picked = pick ?? BetterNotes.shared.choice
        let writer = picked.writer
        Self.logStart("summary", writer: writer, reason: pick == nil ? "chosen" : "picked:\(picked.stored)")
        let written = (words: record.words.count, duration: record.duration)
        let notesFrom = record.notesFingerprint
        summaryTasks[id] = Task {
            defer {
                writing.remove(id)
                writers[id] = nil
                summaryTasks[id] = nil
                if let next = again.removeValue(forKey: id) { summarize(id, in: next.language, with: next.writer) }
            }
            // Not while a meeting is being recorded: the live words come first.
            while MeetingSession.shared.isRecording { try? await Task.sleep(for: .seconds(2)) }
            do {
                let t0 = Date()
                var fresh: MeetingSummary?
                var writeError: Error?
                do { fresh = try await Self.write(lines, writer: writer) } catch { writeError = error }
                // Done or not, the writer lets go of what it can (and its progress line).
                await writer?.finished()
                if let writeError { throw writeError }
                guard var summary = fresh else { return }
                // The meeting went on meanwhile (continued, or listened through again):
                // these notes are of what it was — written again once it's done.
                if MeetingSession.shared.record?.id == id {
                    afterMeeting.insert(id)
                    return
                }
                guard var latest = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                if latest.duration > written.duration + 1 || latest.words.count != written.words, again[id] == nil {
                    again[id] = (choice, pick)
                    return
                }
                // Written again (a continued meeting, "Sammanfatta igen"): the tasks you
                // ticked off stay ticked where the same task is there again.
                let ticked = Set((latest.summary?.tasks ?? []).filter { $0.done == true }.map { Self.taskKey($0.text) })
                for i in summary.tasks.indices where ticked.contains(Self.taskKey(summary.tasks[i].text)) {
                    summary.tasks[i].done = true
                }
                summary.notesFrom = notesFrom
                summary.applyVocabulary()
                latest.summary = summary
                if !latest.userTitled, let title = summary.title, !title.isEmpty { latest.title = title }
                MeetingStore.shared.save(latest)
                // Written by one picked for this meeting: offered for all, once it's done.
                if let pick, pick != BetterNotes.shared.choice, again[id] == nil { tried[id] = pick }
                Self.log.info("notes written in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            } catch is CancellationError {
                // Avbryt pressed: no notes, and nothing to explain.
            } catch {
                Self.logFailure("summary", writer: writer, error: error)
                failed[id] = Self.explain(error)
                failedServer[id] = Self.server(of: error)
            }
        }
    }

    /// The notes being written, by meeting: Avbryt stops one.
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private var answerTasks: [UUID: Task<Void, Never>] = [:]

    func cancelSummary(_ id: UUID) {
        again[id] = nil
        summaryTasks[id]?.cancel()
    }

    func cancelAnswer(_ id: UUID) { answerTasks[id]?.cancel() }

    /// Notes asked for again while they were being written: in which language, and by
    /// which writer picked for the meeting (nil: the one chosen for all).
    private var again: [UUID: (language: SummaryLanguage, writer: SummaryWriterChoice?)] = [:]
    /// Notes put aside because the meeting was being recorded or listened to again —
    /// written when it's done (MeetingSession.done).
    private var afterMeeting: Set<UUID> = []
    func takeAfterMeeting(_ id: UUID) -> Bool { afterMeeting.remove(id) != nil }
    /// Notes to write again once the meeting is listened through.
    func writeAfterMeeting(_ id: UUID) { afterMeeting.insert(id) }

    private static func taskKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func ask(_ question: String, about id: UUID) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAvailable, !question.isEmpty, !answering.contains(id),
              let record = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        let recording = MeetingSession.shared.isRecording
        let writer = recording ? nil : BetterNotes.shared.writer   // not during a meeting
        // During a meeting only Apple's model answers: without it, say so plainly.
        guard writer != nil || Polisher.status == .available else {
            failed[id] = Self.onlyAppleDuringMeeting
            failedServer[id] = nil
            return
        }
        Self.logStart("answer", writer: writer, reason: recording ? "fallback:recording" : "chosen")
        answering.insert(id)
        failed[id] = nil
        failedServer[id] = nil
        let lines = Lines(record)
        let summary = record.summary
        // The last questions, so "och vem?" knows what it follows.
        let history = record.answers.suffix(2).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        // "Vad lovade jag?": who "jag" is, when you've said which of them you are.
        let asker = record.cast.order.map { record.name(of: $0) }.first { record.isMe($0) }
        answerTasks[id] = Task {
            defer { answering.remove(id); answerTasks[id] = nil }
            do {
                let answer = try await Self.answer(question, from: lines, summary: summary, history: history, asker: asker,
                                                   writer: writer)
                // Continued meanwhile: the answer goes with the meeting being recorded.
                if MeetingSession.shared.record?.id == id {
                    MeetingSession.shared.addAnswer(answer)
                    return
                }
                guard var latest = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                latest.answers.append(answer)
                MeetingStore.shared.save(latest)
            } catch is CancellationError {
            } catch {
                Self.logFailure("answer", writer: writer, error: error)
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
        // `--own-notes "rad|rad"` and `--marks "decision@30,task@55=Anna skickar offerten"`:
        // as if written and marked during the meeting (a mark's words after "=") — on a
        // copy, nothing saved.
        var record = found
        if let i = args.firstIndex(of: "--own-notes"), i + 1 < args.count {
            record.notes = args[i + 1].split(separator: "|").map { MeetingRecord.Note(text: String($0), at: nil) }
        }
        if let i = args.firstIndex(of: "--marks"), i + 1 < args.count {
            record.marks = args[i + 1].split(separator: ",").compactMap { part -> MeetingRecord.Mark? in
                let words = part.split(separator: "=", maxSplits: 1)
                let p = words[0].split(separator: "@")
                guard p.count == 2, let kind = MeetingRecord.Mark.Kind(rawValue: String(p[0])), let at = Double(p[1]) else { return nil }
                return MeetingRecord.Mark(at: at, kind: kind, text: words.count == 2 ? String(words[1]) : nil)
            }
        }
        var lines = Lines(record)
        // `--in English`: notes in another language than the meeting's.
        if let i = args.firstIndex(of: "--in"), i + 1 < args.count { lines.write(in: args[i + 1]) }
        print("Språk: \(lines.language), \(lines.lines.count) rader, \(lines.parts().count) del(ar)")
        do {
            let t0 = Date()
            let writer = BetterNotes.shared.writer
            print("Modell: \(BetterNotes.shared.writerName)")
            let s = try await write(lines, writer: writer)
            print(String(format: "\n(%.1f s)\nTitel: %@\nÖversikt: %@", Date().timeIntervalSince(t0), s.title ?? "•", s.overview))
            let show = { (title: String, items: [MeetingSummary.Item]) in
                print(title)
                for i in items { print("  - \(i.marked == true ? "⚑ " : "")\(i.text)\(i.owner.map { " (\($0))" } ?? "")  [\(i.at.map { MeetingView.duration($0) } ?? "ingen källa")]") }
            }
            show("Beslut:", s.decisions); show("Att göra:", s.tasks); show("Viktigt:", s.points)
            let t1 = Date()
            let a = try await answer(question, from: lines, summary: record.summary, writer: writer)
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

    static var onlyAppleDuringMeeting: String {
        String(localized: "Under mötet går frågor bara med Apple Intelligence. Fråga igen när mötet är klart.")
    }

    /// The program a failure was about, when it wasn't running or isn't on this Mac.
    private static func server(of error: Error) -> ServerBackend? {
        switch error as? ServerError {
        case .notRunning(let backend)?, .notInstalled(let backend)?: return backend
        default: return nil
        }
    }

    /// One line in the system log when a summary or an answer starts: who writes, what
    /// is chosen, and why they differ when they do. No meeting text.
    static func logStart(_ what: String, writer: (any SummaryWriter)?, reason: String) {
        let chosen = BetterNotes.shared.choice.stored
        log.notice("\(what, privacy: .public): writer=\(writer?.name ?? "Apple Intelligence", privacy: .public) chosen=\(chosen, privacy: .public) reason=\(reason, privacy: .public)")
    }

    /// The writer chosen couldn't write (not running, not on the disk, the model gone):
    /// said so in the log, and nothing is written by anyone else.
    nonisolated static func logFailure(_ what: String, writer: (any SummaryWriter)?, error: Error) {
        let name = writer?.name ?? "Apple Intelligence"
        if isUnavailable(error) {
            log.notice("\(what, privacy: .public): \(name, privacy: .public) unavailable (\(String(describing: error), privacy: .public)), not written")
        } else {
            log.error("\(what, privacy: .public): \(name, privacy: .public) failed (\(String(describing: error), privacy: .public))")
        }
    }

    /// The writer itself was out of reach, rather than failing on the meeting.
    nonisolated private static func isUnavailable(_ error: Error) -> Bool {
        if error is WriterError { return true }
        if let e = error as? ModelError, case .notInstalled = e { return true }
        switch error as? ServerError {
        case .notRunning?, .notInstalled?, .noModels?, .modelGone?, .noEndpoint?: return true
        default: break
        }
        if let e = error as? LanguageModelSession.GenerationError, case .assetsUnavailable = e { return true }
        return false
    }

    private static func explain(_ error: Error) -> String {
        if let e = error as? ServerError { return e.plainWords }
        if let e = error as? WriterError { return e.plainWords }
        if error is EmptyAnswer { return String(localized: "Modellen skrev inget svar. Försök igen.") }
        if error is CancellationError { return String(localized: "Avbrutet.") }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return String(localized: "Mötet blev för långt för Apple Intelligence.")
            case .guardrailViolation, .refusal: return String(localized: "Apple Intelligence ville inte svara på det här.")
            case .unsupportedLanguageOrLocale: return String(localized: "Apple Intelligence kan inte det här språket.")
            default: break
            }
        }
        return String(localized: "Sammanfattningen kunde inte skrivas klart just nu. Försök igen om en stund.")
    }

    // MARK: Writing notes

    @Generable struct Item {
        @Guide(description: "A short sentence in your own words.") var text: String
        @Guide(description: "The number in brackets of the line where this is said.") var line: Int
    }

    @Generable struct Todo {
        @Guide(description: "Something a person will actually do after the meeting: an action, not a thought, opinion or feeling. A short sentence in your own words.") var text: String
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
        @Guide(description: "What the meeting was about and what came out of it, in one to three sentences, in the third person, naming people only as they are named before the colon in the transcript, never other names. One sentence if the meeting was short.")
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
        Never use dashes (– or —): write commas or full sentences instead. \
        \(task)
        """
    }

    private static let options = GenerationOptions(sampling: .greedy)
    /// Answers and condensed notes are short: a model that loops stops long before the
    /// context is full.
    private static let answerOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: 450)
    private static let condenseOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: 350)

    /// The notes transform what was said in the meeting — Apple's guardrails for
    /// that, so a meeting about, say, security or health isn't refused as a topic.
    nonisolated private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    nonisolated private static func session(_ instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    nonisolated private static func write(_ lines: Lines, writer: (any SummaryWriter)? = nil) async throws -> MeetingSummary {
        var outcomes: [Outcomes] = []
        var overviews: [Overview] = []
        var lastError: Error?
        // Gemma 4 or your own model: the whole meeting at once when it fits (a long one
        // in as few parts as it can read), in the same line format — and through the
        // same checks below.
        if let writer {
            // All the parts first: the writer makes itself ready once for the whole job.
            let system = plainPrompt(lines.language)
            let prompts = lines.parts(budget: writer.wordBudget).map { lines.guidance + "Transcript:\n" + $0 }
            try await writer.begin(system: system, prompts: prompts)
            for prompt in prompts {
                let p = parsePlain(try await writer.complete(system: system, user: prompt, maxTokens: 800))
                outcomes.append(Outcomes(decisions: p.decisions, tasks: p.tasks))
                overviews.append(Overview(title: p.title, summary: p.summary, points: p.points))
            }
            if overviews.count > 1 {
                let parts = overviews.enumerated().map { "Part \($0.offset + 1): \($0.element.summary)" }.joined(separator: "\n")
                let merged = try await writer.complete(system: "", user: """
                    These are summaries of consecutive parts of one meeting. Write one summary of the whole meeting \
                    in \(lines.language), in two or three sentences. Only use what is in the summaries.

                    \(parts)
                    """, maxTokens: 300)
                overviews[0].summary = merged
                overviews = [overviews[0]] + overviews.dropFirst().map { Overview(title: "", summary: "", points: $0.points) }
            }
            var summary = await withMarks(finish(lines, outcomes: outcomes, overviews: overviews), lines, writer: writer)
            summary.writer = writer.name
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
        return await withMarks(finish(lines, outcomes: outcomes, overviews: overviews), lines, writer: nil)
    }

    /// The moments you marked: each one is in the notes — the item the model wrote
    /// about it if there is one (flagged as yours), otherwise one written from the
    /// lines around it. A mark is pressed just after something is said, so it
    /// covers the line it falls in and the one before. A mark you gave words is
    /// those words: the item that says the same, or one with them.
    nonisolated private static func withMarks(_ summary: MeetingSummary, _ lines: Lines, writer: (any SummaryWriter)?) async -> MeetingSummary {
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
            // Your own words say what it is: not whatever the model wrote nearby.
            if mark.text == nil {
                switch mark.kind {
                case .decision: if flag(&summary.decisions, where: near) { continue }
                case .task: if flag(&summary.tasks, where: near) { continue }
                case .important:
                    if flag(&summary.points, where: near) || flag(&summary.decisions, where: nearAny)
                        || flag(&summary.tasks, where: nearAny) { continue }
                }
            }
            // Otherwise your words, or one written from the sentences there.
            let (said, pressed) = lines.around(mark.at)
            let text: String
            if let own = mark.text {
                text = own
            } else {
                guard !said.isEmpty else { continue }
                let shown = said.enumerated().map { k, line in "\(k == pressed ? "▶ " : "")\(line.speaker): \(line.text)" }
                text = await phrase(mark.kind, shown.joined(separator: "\n"), lines.language, writer: writer)
                    ?? firstSentences(said[pressed].text, 1)
            }
            // Where it was said: the sentence it was written from — the pressed one or
            // the one before when they match as well as a later one.
            let keys = Lines.keys(text)
            let score = { (k: Int) in Lines.overlap(keys, Lines.keys(said[k].text)) + (k == pressed || k == pressed - 1 ? 0.15 : 0) }
            let source = said.isEmpty ? nil : said[said.indices.max { score($0) < score($1) } ?? pressed]
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
            var item = MeetingSummary.Item(text: text.trimmingCharacters(in: .whitespaces), at: source?.start ?? mark.at, marked: true)
            switch mark.kind {
            case .decision: summary.decisions.append(item)
            case .task:
                // Who takes it on: whoever said it, unless the words are yours (they may name someone else).
                if mark.text == nil, let source { item.owner = lines.person(source.speaker) }
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
                                           writer: (any SummaryWriter)?) async -> String? {
        let what = switch kind {
        case .decision: "a decision"
        case .task: "a task someone takes on"
        case .important: "something important"
        }
        let how = kind == .task
            ? "Write the task as a short action in \(language), without saying who does it (that is shown next to it): " +
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
            if let writer {
                line = try await writer.complete(system: "", user: ask, maxTokens: 60)
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

    /// A question about one meeting. The model reads the transcript (all of it when it
    /// fits, otherwise the lines that matter) and the meeting's notes: for a broad
    /// question ("Vad bestämdes?", "Sammanfatta") the notes first and the lines where
    /// they were said; for a particular one the lines that say it first, then what the
    /// meeting was about and the notes that match.
    nonisolated static func answer(_ question: String, from lines: Lines, summary: MeetingSummary? = nil, history: String = "",
                                   asker: String? = nil, writer: (any SummaryWriter)? = nil) async throws -> MeetingAnswer {
        // A short question ("vad?") is in the language of the meeting.
        let language = question.split(separator: " ").count >= 3 ? Lines.languageName(of: question) ?? lines.language : lines.language
        let broad = QuestionKind.isBroad(question)
        let local = writer != nil
        let budget = writer?.wordBudget ?? Lines.appleBudget
        // The notes, numbered after the transcript's lines: each leads to its moment.
        let keys = Lines.keys(history + " " + question)
        var notes: [(text: String, at: Double?)] = []
        if let summary {
            if !summary.overview.isEmpty { notes.append(("Summary: " + summary.overview, nil)) }
            for d in summary.decisions { notes.append(("Decision: \(d.text)", d.at)) }
            for t in summary.tasks {
                notes.append(("Task: \(t.text)\(t.owner.map { " (\($0))" } ?? "")\(t.done == true ? " (done)" : "")", t.at))
            }
            for p in summary.points { notes.append(("Point: \(p.text)", p.at)) }
        }
        for n in lines.notes { notes.append(("Your note: \(n)", nil)) }
        for m in lines.marks {
            guard let text = m.text, !notes.contains(where: { $0.text.hasSuffix(": " + text) }) else { continue }
            let kind = switch m.kind {
            case .decision: "a decision"
            case .task: "a task"
            case .important: "something important"
            }
            notes.append(("You marked \(kind): \(text)", m.at))
        }
        // A particular question with Apple's small model: what it was about and the notes
        // that match, not all of them.
        if !broad, !local {
            notes = notes.filter { $0.text.hasPrefix("Summary:") || Lines.overlap(keys, Lines.keys($0.text)) > 0 }
        }
        var noteWords = 0
        var shown: [(text: String, at: Double?)] = []
        for note in notes {
            let n = note.text.split(separator: " ").count
            // At most half the room: the transcript is what answers.
            if noteWords + n > budget / 2 { break }
            noteWords += n
            shown.append(note)
        }
        var extra: [Int: Double] = [:]
        let first = lines.lines.count + 1
        let numbered = shown.enumerated().map { k, note in
            if let at = note.at { extra[first + k] = at }
            return "[\(first + k)] \(note.text)"
        }.joined(separator: "\n")
        // The lines where the notes' items were said: for a broad question, the right parts
        // of a long meeting.
        let anchors = broad ? shown.compactMap(\.at) : []
        let transcript = lines.relevant(to: history + " " + question, budget: budget - noteWords, anchors: anchors)
        let notesPart = shown.isEmpty ? "" : "Meeting notes (written from this meeting, and the note-taker's own):\n\(numbered)"
        let context = broad || shown.isEmpty
            ? [notesPart, "Transcript:\n\(transcript)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
            : "Transcript:\n\(transcript)\n\n\(notesPart)"
        let earlier = history.isEmpty ? "" : "\n\nEarlier questions and answers:\n\(history)"
        let who = asker.map { "\n\nThe person asking is \($0) (\"I\" and \"me\" in the question mean \($0))." } ?? ""
        let prompt = "\(context)\(earlier)\(who)\n\nQuestion: \(question)"
        let about = shown.isEmpty ? "" : " The meeting notes are numbered too: use them, and the lines that say it."
        let reply: Reply
        do {
            if local { throw LocalAnswer() }
            let session = session(instructions(language, (broad
                ? "Answer the question about the whole meeting, in two to five full sentences. For a task, say who does it."
                : "Answer the question about the meeting. If the transcript doesn't answer it, say so.") + about))
            if broad {
                let r = try await session.respond(to: prompt, generating: BroadReply.self, options: answerOptions).content
                reply = Reply(answer: r.answer, lines: r.lines)
            } else {
                reply = try await session.respond(to: prompt, generating: Reply.self, options: answerOptions).content
            }
        } catch {
            // Your own model, Gemma 4, or Apple's model refusing structure: plain text, sources on a last line.
            if !(error is LocalAnswer) { log.error("answer: \(String(describing: error), privacy: .public)") }
            let ask = instructions(language, """
                Answer the question about the meeting in \(broad ? "two to five" : "one to three") full sentences, in your own \
                words. Don't copy the transcript. If the transcript doesn't answer it, say so.\(about) \
                On a last line write "SOURCES:" and the numbers of the lines the answer comes from.
                """)
            let text = try await (writer ?? AppleWriter()).complete(system: ask, user: prompt, maxTokens: broad ? 450 : 300)
            reply = parseSources(text, keep: broad ? 6 : 4)
        }
        // Lines quoted as "[4] Anna: …" read as the answer's words, not its references.
        let cleaned = reply.answer.replacingOccurrences(of: #"\[\d+\]\s*([^:\n]{1,40}:\s*)?"#, with: "",
                                                        options: .regularExpression)
        // An answer is often a name or a yes, sharing no words with its line: the
        // lines it names are its sources, as long as they exist.
        let sources = reply.lines.compactMap { lines.start(ofLine: $0) ?? extra[$0] }
        let answer = Self.firstSentences(Self.tidy(Self.unnumbered(cleaned)), broad ? 5 : 3)
        // Nothing written (it happens): said as a failure, never saved as an empty answer.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EmptyAnswer() }
        // Your own model: an answer that names no line it came from isn't shown.
        if let writer, writer.requiresSources, sources.isEmpty { throw ServerError.noSources }
        return MeetingAnswer(question: question, answer: answer, sources: Array(Set(sources)).sorted())
    }

    /// A question across meetings (MeetingSearch.swift): answered from the meetings the
    /// context picked, with the numbers of the lines it used. A broad question that
    /// doesn't fit Apple's model at once: each part condensed first (keeping the
    /// decisions, the tasks with who does them, the days and the line numbers), then
    /// answered from the condensed notes.
    nonisolated static func answerAcross(_ question: String, context: LibraryContext, history: String,
                                         writer: (any SummaryWriter)?) async throws -> (answer: String, lines: [Int]) {
        let language = context.language
        let local = writer != nil
        let earlier = history.isEmpty ? "" : "\n\nEarlier questions and answers:\n\(history)"
        var meetings = context.text
        if context.broad, !local, context.parts.count > 1 {
            // Back under their meetings, by the numbers they kept: the titles and the days
            // as they are, not as the model retold them. A part whose condensed lines kept
            // no number is taken as it is, cut to its notes; never the whole raw text.
            var order: [String] = []
            var under: [String: [String]] = [:]
            func place(_ text: String) -> Bool {
                var any = false
                for line in text.components(separatedBy: .newlines) {
                    let numbers = line.matches(of: #/\[(\d+)\]/#).compactMap { Int($0.output.1) }
                    let headings = numbers.compactMap { context.headings[$0] }
                    guard !headings.isEmpty else { continue }
                    // "[n] what", as the lines were: a number at the end reads like a date.
                    var what = line.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•*")))
                    if what.hasPrefix("Meeting "), let colon = what.firstIndex(of: ":") { what = String(what[what.index(after: colon)...]) }
                    what = what.trimmingCharacters(in: .whitespaces)
                    // Several lines cited: under each of their meetings, once.
                    var seen = Set<String>()
                    for heading in headings where seen.insert(heading).inserted {
                        let own = zip(numbers, numbers.compactMap { context.headings[$0] }).filter { $0.1 == heading }.map { "[\($0.0)]" }
                        if under[heading] == nil { order.append(heading) }
                        under[heading, default: []].append(own.joined(separator: " ") + " " + what)
                    }
                    any = true
                }
                return any
            }
            for part in context.parts.prefix(LibraryContext.appleParts) {
                if !place(await condense(part, for: question, language: language)) {
                    _ = place(fallbackCondensed(part))
                }
            }
            if order.isEmpty {
                for part in context.parts.prefix(LibraryContext.appleParts) { _ = place(fallbackCondensed(part)) }
            }
            meetings = order.sorted { a, b in
                (Int(a.dropFirst(8).prefix { $0.isNumber }) ?? 0) < (Int(b.dropFirst(8).prefix { $0.isNumber }) ?? 0)
            }.map { $0 + "\n" + (under[$0] ?? []).joined(separator: "\n") }.joined(separator: "\n\n")
        }
        let prompt = "Today is \(context.today).\n\nMeetings:\n\(meetings)\(earlier)\n\nQuestion: \(question)"
        let task = context.broad
            ? "You read the notes of several meetings, newest first. Each meeting starts with its title and date, then lines " +
              "\"[n] …\": what it was about, decisions, tasks with who does them in brackets, the note-taker's own notes and marks. " +
              "Answer the question across the meetings in \(language), in two to six full sentences, in your own words, " +
              "directly, without a greeting. Name the meeting (by its title or day) for what you mention, and leave out " +
              "meetings that have nothing for the question; put the newest first. " +
              "For a task, say who does it; a task marked (done) is finished. When asked what I or we should do, give the " +
              "open tasks and who has each. Only use what the lines say; if they don't answer it, say so plainly. " +
              "Never invent names, numbers, dates or decisions. Never use dashes."
            : "You read notes and transcripts from several meetings. Each meeting starts with its title and date; " +
              "each line is \"[n] …\". Answer the question across the meetings in \(language), in one to four full sentences, " +
              "in your own words, speaking to the person who recorded them. Say which meeting when it matters (by its title or " +
              "day). Only use what the lines say; " +
              "if they don't answer it, say so plainly. Never invent names, numbers, dates or decisions."
        let reply: Reply
        do {
            if local { throw LocalAnswer() }
            if context.broad {
                let r = try await LanguageModelSession(model: model, instructions: task)
                    .respond(to: prompt, generating: BroadReply.self, options: answerOptions).content
                reply = Reply(answer: r.answer, lines: r.lines)
            } else {
                reply = try await LanguageModelSession(model: model, instructions: task)
                    .respond(to: prompt, generating: Reply.self, options: answerOptions).content
            }
        } catch {
            if !(error is LocalAnswer) { log.error("answer across: \(String(describing: error), privacy: .public)") }
            let ask = task + " On a last line write \"SOURCES:\" and the numbers of the lines the answer comes from."
            let text = try await (writer ?? AppleWriter()).complete(system: ask, user: prompt, maxTokens: context.broad ? 600 : 400)
            reply = parseSources(text, keep: context.broad ? 6 : 4)
        }
        let cleaned = reply.answer.replacingOccurrences(of: #"\[\d+\]\s*([^:\n]{1,40}:\s*)?"#, with: "",
                                                        options: .regularExpression)
        let answer = Self.firstSentences(Self.tidy(Self.unnumbered(cleaned)), context.broad ? 6 : 4)
        // Nothing written (it happens): said as a failure, not shown as an empty answer.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EmptyAnswer() }
        // Your own model: an answer that names no line it came from isn't shown.
        if let writer, writer.requiresSources, !reply.lines.contains(where: { context.sources[$0] != nil }) { throw ServerError.noSources }
        return (answer, reply.lines)
    }

    @Generable struct BroadReply {
        @Guide(description: "The answer in two to six full sentences, in your own words, only from what you read. No numbers in brackets: those go in lines. If it doesn't say, say so plainly.")
        var answer: String
        @Guide(description: "The numbers in brackets of the lines the answer comes from. Empty if the notes don't say.", .maximumCount(6))
        var lines: [Int]
    }

    /// One part of many meetings' notes, condensed by Apple's model for a broad question:
    /// short lines that keep each meeting's title and day, its decisions, tasks with who
    /// does them, and the line numbers. Refused or failed: the decisions and tasks as
    /// they are, cut short — the part is never left out.
    nonisolated private static func condense(_ part: String, for question: String, language: String) async -> String {
        let ask = "You condense notes from meetings so that a question about them can be answered later. Each meeting " +
            "starts with its title and date, then lines \"[n] …\". Write in \(language), at most 140 words, one short line " +
            "for each thing that matters for the question, each ending with the number in brackets [n] of the line it comes " +
            "from. Keep every decision, every task with who does it. Leave out small talk and meetings with nothing for " +
            "the question. Never invent anything. Never use dashes."
        do {
            let text = try await LanguageModelSession(model: model, instructions: ask)
                .respond(to: "Question: \(question)\n\nNotes:\n\(part)", options: condenseOptions).content
            if text.range(of: #"\[\d+\]"#, options: .regularExpression) != nil {
                // Longer than asked: cut at a line, so the parts together still fit the answer.
                var kept: [String] = []
                var words = 0
                for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    words += line.split(separator: " ").count
                    if words > 170, !kept.isEmpty { break }
                    kept.append(line)
                }
                return kept.joined(separator: "\n")
            }
            log.error("condense: no line numbers kept")
        } catch {
            log.error("condense: \(String(describing: error), privacy: .public)")
        }
        return fallbackCondensed(part)
    }

    /// Without the model: each meeting's title, what it was about, decisions and tasks.
    nonisolated private static func fallbackCondensed(_ part: String) -> String {
        var out: [String] = []
        var words = 0
        for line in part.components(separatedBy: .newlines) {
            let keep = line.hasPrefix("Meeting ") || line.contains("] Summary:") || line.contains("] Decision:")
                || line.contains("] Task:") || line.contains("] You marked")
            guard keep else { continue }
            let short = line.contains("] Summary:") ? firstSentences(line, 1) : line
            words += short.split(separator: " ").count
            if words > 220 { break }
            out.append(short)
        }
        return out.joined(separator: "\n")
    }

    /// A plain answer with its sources on a last line ("SOURCES: 3, 7").
    nonisolated private static func parseSources(_ text: String, keep: Int = 4) -> Reply {
        var answer: [String] = []
        var sources: [Int] = []
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for (k, line) in lines.enumerated() {
            let upper = line.uppercased()
            let trimmed = upper.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*(-•")))
            // The marker at the start of a line, or anywhere on the last one (the model
            // put it after its final sentence): elsewhere, "sources" is a word in the answer.
            let marker = (upper.range(of: "SOURCES:") ?? upper.range(of: "KÄLLOR:"))
                .flatMap { r in trimmed.hasPrefix("SOURCES:") || trimmed.hasPrefix("KÄLLOR:") || k == lines.count - 1 ? r : nil }
            if let r = marker {
                sources = Self.numbers(after: String(line[r.upperBound...]))
                // The sources on the answer's own last line: the words before them are the answer.
                let before = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*(")))
                if !before.isEmpty { answer.append(before) }
            } else {
                answer.append(line)
            }
        }
        return Reply(answer: Plain.unmark(answer.joined(separator: " ")), lines: Array(sources.prefix(keep)))
    }

    /// "3, 7 and [12]." → [3, 7, 12]: read until the first thing that isn't a number.
    nonisolated private static func numbers(after text: String) -> [Int] {
        var out: [Int] = []
        for token in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]().*"))
            if bare.isEmpty || ["och", "and", "&"].contains(bare.lowercased()) { continue }
            guard let n = Int(bare) else { break }
            out.append(n)
        }
        return out
    }

    /// Without line numbers written into the answer as "(13)" or "(3, 7)".
    nonisolated static func unnumbered(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\((\d{1,3})(,\s*\d{1,3})*\)"#, with: "", options: .regularExpression)
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
        let own = record.ownLines.map(\.text)
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
    private struct EmptyAnswer: Error {}

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
    /// No dashes in what's shown (the models like them): a comma instead. (A range
    /// such as 10–12 has no spaces and stays.)
    nonisolated static func undash(_ text: String) -> String {
        text.replacingOccurrences(of: " – ", with: ", ").replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
    }

    nonisolated static func tidy(_ text: String) -> String {
        let text = undash(text)
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
    /// Each with what you wrote when you pressed it, if anything.
    let marks: [(at: Double, kind: MeetingRecord.Mark.Kind, text: String?)]
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
        marks = record.marks.map { ($0.at, $0.kind, $0.text) }.sorted { $0.at < $1.at }
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
    /// the most words with the question (and their neighbours), in order. `anchors`:
    /// moments that matter (where the notes' items were said) — their lines first.
    /// Nothing to go by: lines spread over the whole meeting, not only its beginning.
    func relevant(to question: String, budget: Int = Lines.appleBudget, anchors: [Double] = []) -> String {
        let total = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard total > budget else { return numbered(0..<lines.count) }
        let q = Self.keys(question)
        var score = lines.map { Self.overlap(q, Self.keys($0.text)) }
        for at in anchors { if let i = index(at: at) { score[i] += 1 } }
        // Ties (often: nothing matches) spread evenly over the meeting.
        let spread = { (i: Int) in (Double(i) * 0.618_034).truncatingRemainder(dividingBy: 1) }
        let ranked = lines.indices.sorted { score[$0] != score[$1] ? score[$0] > score[$1] : spread($0) < spread($1) }
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
        // What you wrote with a mark is a note too, saying what kind of thing it is.
        let marked = marks.compactMap { mark in
            mark.text.map { text in
                let kind = switch mark.kind {
                case .decision: "Decision"
                case .task: "Task"
                case .important: "Important"
                }
                return "\(kind): \(text)"
            }
        }
        let all = notes + marked
        guard !all.isEmpty else { return "" }
        return "The note-taker wrote these notes during the meeting. They show what mattered most to them: " +
            "make sure each one is covered, with the details from the transcript, " +
            "besides everything else in the meeting worth noting.\nNotes:\n" +
            all.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
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
        let text = MeetingNotes.undash(text)
        if translating {
            guard let at = start(ofLine: line) else { return strict || text.isEmpty ? nil : MeetingSummary.Item(text: text) }
            return MeetingSummary.Item(text: text, at: at)
        }
        let words = Self.keys(text)
        let named = line - 1
        var best: (index: Int, score: Double)?
        for i in lines.indices {
            // The line the model named wins a tie: an item in its own words often shares
            // as much with the line before it (and the first one would win otherwise).
            let score = Self.overlap(words, Self.keys(lines[i].text)) - (abs(i - named) <= 2 ? 0 : 0.35)
                + (i == named ? 0.01 : 0)
            if best == nil || score > best!.score { best = (i, score) }
        }
        guard let best, best.score >= 0.2 else {
            return strict || text.isEmpty ? nil : MeetingSummary.Item(text: text)
        }
        return MeetingSummary.Item(text: text, at: moment(of: words, inLine: best.index))
    }

    /// Where in line `i` the item is said: the start of the sentence in it that shares
    /// the most words with the item. A line is a whole turn (up to 60 words), so one
    /// person talking for half a minute is one line from 0:00, while the transcript
    /// shows the paragraph, at 0:07, where it was really said.
    func moment(of words: Set<String>, inLine i: Int) -> Double {
        let start = lines[i].start
        let end = i + 1 < lines.count ? lines[i + 1].start : .infinity
        var best: (start: Double, score: Double)?
        for sentence in sentences where sentence.start >= start - 0.05 && sentence.start < end {
            let score = Self.overlap(words, Self.keys(sentence.text))
            if best == nil || score > best!.score { best = (sentence.start, score) }
        }
        guard let best, best.score > 0 else { return start }
        return best.start
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
