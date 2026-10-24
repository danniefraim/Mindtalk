import AppKit
import Foundation
import os

// MARK: - The guided round ("Vem är här?")
//
// One person at a time: "Tur 1 – säg hej, ditt namn och vad du gör här." Mindtalk
// knows whose turn it is, so it doesn't wait for the voices to be told apart: the
// audio from that person's first word is theirs. A ring fills as they speak; from a
// second and a half of speech the voice is compared with the people you know, twice
// a second — a known voice is greeted at once ("Välkommen tillbaka, Anna"), a new one
// is asked for its name (filled in when they said it). Then the next turn. A short
// silence after someone has spoken moves the round on by itself; "Nästa" is there
// to skip the wait. When nobody new speaks, it counts down and ends.
//
// After the round, each name goes to the voice that said it (RoundPlacement): the voice
// of the name word, never a voice heard through the whole round (a TV, the next table),
// and — for someone you know — never a voice that clearly isn't them.
//
// Measured on real meetings (scripts in the scratchpad bench): recognition is safe
// from 1.5 s of speech with the usual thresholds (0.60, lead 0.10) — strangers never
// scored above 0.58 — and most known voices are found within 2–3 s. Pauses inside an
// introduction are often 0.7–1 s, so a turn ends only after a longer silence.

@MainActor
final class IntroRound: ObservableObject {
    enum Phase: Equatable {
        case ready              // "Tur 2 – nästa person"
        case listening          // the ring filling
        case known(String)      // "Välkommen tillbaka, Anna"
        case new                // the name card
        case same(String)       // the last person again
        case closing            // nobody new: counting down to the meeting
    }

    struct Capture: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let known: Bool
        let score: Float?
        /// Where the name was heard (the name and the words leading up to it) — or, not
        /// heard said, the turn.
        let from: Double
        let to: Double
        var print: [Float]?
        let figure: VoiceFigure
        let colour: Int
        /// The whole turn, from its first sound to when it was done…
        var turnFrom: Double? = nil
        var turnTo: Double? = nil
        /// …the name word itself (nil: typed, or the voice recognised)…
        var said: ClosedRange<Double>? = nil
        /// …and typed by hand in the name card.
        var typed = false

        /// The turn as the placement sees it (RoundPlacement).
        var turn: RoundPlacement.Turn {
            RoundPlacement.Turn(name: name, from: min(turnFrom ?? from, from), to: max(turnTo ?? to, to), said: said,
                                known: known, score: score, typed: typed, print: print)
        }
    }

    @Published private(set) var turn = 1
    @Published private(set) var phase: Phase = .ready
    /// The ring: how much of the speech needed has been heard (0…1).
    @Published private(set) var progress: Double = 0
    /// A print of this turn so far, the moment a comparison has made one (from a second
    /// and a half of speech). From then on the cloud has a figure to fall into.
    @Published private(set) var formingPrint: [Float]?
    @Published private(set) var captures: [Capture] = [] {
        didSet { if captures.count > oldValue.count { thankedAt = Date(); quietTurns = 0 } }
    }
    /// When the last person was added: "Tack, Anna!" stays up a moment into the next turn.
    @Published private(set) var thankedAt: Date?
    /// Turns in a row where only people already here spoke: the meeting has begun.
    private var quietTurns = 0
    /// The figure the cloud falls into: from the first print of the turn (a second and
    /// a half in) a provisional one, which the cloud forms into as the ring fills; a
    /// known voice's own the moment it is recognised.
    @Published private(set) var figure: VoiceFigure?
    /// Nothing heard for a while in this turn.
    @Published private(set) var quiet = false
    /// A new voice: the name said ("jag heter Erik"), and when it saves by itself.
    @Published var draft = ""
    @Published private(set) var autoSaveAt: Date?
    /// Typed by hand: a name said aloud no longer replaces it.
    private var typed = false
    /// Where the name card's listening began (seconds into the meeting).
    private var askedAt = 0.0
    @Published private(set) var closingAt: Date?
    /// The round wants to end (the countdown ran out): the scanner fades it out.
    @Published private(set) var wantsToEnd = false

    private weak var session: MeetingSession?
    private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Meeting")

    // The turn, in samples of the meeting's opening audio (16 kHz).
    private var turnStart = 0
    private var cursor = 0
    private var speechStart: Int?
    /// Where this turn's speech began — kept while the name card listens afresh.
    private var turnSpeech: Int?
    /// The name word heard in the name card ("Anna", "det är Anna"), and where it was said.
    private var draftSaid: ClosedRange<Double>?
    private var voiced = 0.0
    private var silence = 0.0
    private var lastSpeech = Date()
    private var phaseSince = Date()
    private var inSpeech = false
    private var runFrames = 0
    private var floor: [Float] = []
    private var checking = false
    private var lastCheck = 0.0
    private var turnPrint: [Float]?
    private var knownMatch: (name: String, score: Float)?

    private static let rate = 16_000.0
    private static let frame = 320                  // 20 ms
    private static let needed = 3.0                 // seconds of speech for a full ring

    init(session: MeetingSession) {
        self.session = session
        cursor = session.openingCountForRound
        turnStart = cursor
    }

    func start() {
        guard task == nil else { return }
        beginTurn()
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var recognitionOn: Bool {
        let memory = VoiceMemory.shared
        return memory.isOn && memory.state == .ready && memory.people.contains { !$0.prints.isEmpty }
    }

    // MARK: Turns

    private func beginTurn() {
        session?.keepRoundAudio()
        turnStart = cursor
        speechStart = nil
        turnSpeech = nil
        draftSaid = nil
        voiced = 0
        silence = 0
        inSpeech = false
        runFrames = 0
        lastCheck = 0
        turnPrint = nil
        formingPrint = nil
        knownMatch = nil
        candidate = nil
        progress = 0
        quiet = false
        figure = nil
        draft = ""
        spokenDraft = ""
        typed = false
        autoSaveAt = nil
        closingAt = nil
        wantsToEnd = false
        lastSpeech = Date()
        set(.ready)
    }

    /// Everyone's here: the scanner fades the round out — and should it not be on
    /// screen (another page), the round ends anyway a moment later.
    private func requestEnd() {
        guard !wantsToEnd else { return }
        wantsToEnd = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.wantsToEnd, let session = self.session, session.introducing else { return }
            session.endIntroduction()
        }
    }

    private func set(_ new: Phase) {
        phase = new
        phaseSince = Date()
    }

    /// "Nästa": on to the next person without waiting for the silence.
    func next() {
        switch phase {
        case .listening where voiced >= 1.5: Task { await finishTurn() }
        case .known: captureKnown()
        case .new: save()
        case .same, .ready, .listening, .closing: break
        }
    }

    /// The name card: saved, the voice joins the room.
    func save() {
        guard case .new = phase else { return }
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let colour = captures.count
        let fig = figure ?? VoiceFigure.from(seed: "\(name)-\(colour)")
        // Said aloud: where (the name goes to whoever said it). Typed: the turn decides.
        let spoken = !typed || name == spokenDraft
        captures.append(Capture(name: name, known: false, score: nil, from: seconds(speechStart ?? turnStart),
                                to: seconds(cursor), print: turnPrint, figure: fig, colour: colour,
                                turnFrom: seconds(turnSpeech ?? turnStart), turnTo: seconds(cursor),
                                said: spoken ? draftSaid : nil, typed: !spoken))
        VoiceMemory.shared.reserve(fig, for: name)
        Self.log.notice("round: turn \(self.turn) named after \(Int(Date().timeIntervalSince(self.phaseSince))) s")
        turn += 1
        beginTurn()
    }

    /// Typing in the name card: it waits for you rather than saving by itself.
    func typing() {
        guard draft != spokenDraft else { return }
        autoSaveAt = nil
        typed = true
    }
    private var spokenDraft = ""

    /// The name card put away: the voice stays unnamed ("Talare 2"), on to the next.
    func skipName() {
        guard case .new = phase else { return }
        turn += 1
        beginTurn()
    }

    private func captureKnown() {
        guard let knownMatch else { return }
        let colour = captures.count
        let fig = VoiceFigure.remembered(knownMatch.name) ?? VoiceFigure.from(seed: knownMatch.name)
        captures.append(Capture(name: knownMatch.name, known: true, score: knownMatch.score,
                                from: seconds(speechStart ?? turnStart), to: seconds(cursor),
                                print: turnPrint, figure: fig, colour: colour,
                                turnFrom: seconds(turnSpeech ?? turnStart), turnTo: seconds(cursor)))
        turn += 1
        beginTurn()
    }

    private func seconds(_ sample: Int) -> Double { Double(sample) / Self.rate }

    // MARK: Listening

    private func tick() async {
        guard let session, session.introducing else { return }
        // Not before the speech model is ready: names are found in its words. The audio
        // waits (it's kept), and is listened to once it is.
        guard session.phase != .starting else { return }
        // The round's audio is kept as long as it goes on (up to ten minutes; past that,
        // the meeting has long begun: on with it).
        session.keepRoundAudio()
        let fresh = session.roundAudio(from: cursor)
        if fresh.isEmpty, session.openingCountForRound >= AudioIntake.longestOpening { requestEnd(); return }
        let since = Date().timeIntervalSince(phaseSince)
        analyse(fresh)
        cursor += fresh.count

        switch phase {
        case .ready:
            // A moment for the prompt (and the last person's tail) before listening.
            if since >= 0.8 { speechStart = nil; voiced = 0; silence = 0; set(.listening) }
        case .listening:
            progress = min(1, voiced / Self.needed)
            quiet = speechStart == nil && Date().timeIntervalSince(lastSpeech) > 7
            // Nobody new for a while (and someone has introduced themselves): end.
            if speechStart == nil, !captures.isEmpty, Date().timeIntervalSince(lastSpeech) > 10 {
                closingAt = Date().addingTimeInterval(4)
                set(.closing)
                return
            }
            // Someone already here, talking on (by the live voices, when there's no print
            // of them to compare): them again.
            if voiced >= 2, let v = voice(of: turnWords()),
               let here = captures.first(where: { $0.print == nil && voice(from: $0.from, to: $0.to) == v }) {
                Self.log.notice("round: turn \(self.turn) is a voice already in the room (live voices)")
                figure = here.figure
                set(.same(here.name))
                return
            }
            // The name, the moment it's said ("Matilda", "jag heter Anna"): thanked, on to
            // the next. The voice itself is learned from the whole meeting afterwards —
            // nobody has to talk on for it here.
            if let heard = nameInTurn(), settled(on: heard.name) {
                if let again = captures.first(where: { Self.sameName($0.name, heard.name) }) {
                    Self.log.notice("round: turn \(self.turn) said a name already in the room")
                    figure = again.figure
                    set(.same(again.name))
                } else {
                    captureHeard(heard.name, from: heard.from, to: heard.to, said: heard.said)
                }
                return
            }
            // A second and a half of speech: someone already here talking on, or a voice
            // you've named before?
            if voiced >= 1.5, !checking, seconds(cursor) - lastCheck >= 0.5, VoiceMemory.shared.state == .ready {
                await check()
            }
            guard case .listening = phase else { return }
            // Talked, but no name: asked for it. (After a few words and a pause, or a
            // few seconds of speech and a pause, or ten seconds whatever.)
            if (voiced >= 3.5 && silence >= 1.4) || voiced >= 10 || saidWithoutName() {
                await finishTurn()
            }
        case .known:
            // Greeted: on when they stop, or after a few seconds anyway.
            if (silence >= 1.2 && since >= 1.2) || since >= 4 { captureKnown() }
        case .new:
            if !typed, voiced >= 1.5, !checking, seconds(cursor) - lastCheck >= 0.5, VoiceMemory.shared.state == .ready {
                await check()
                guard case .new = phase else { return }
            }
            // Someone says the name ("Anna", "det är Anna"): it fills in, and saves itself.
            if !typed, let heard = heardName(), settled(on: heard.name) {
                if let again = captures.first(where: { Self.sameName($0.name, heard.name) }) {
                    figure = again.figure
                    set(.same(again.name))
                    return
                }
                propose(heard.name, saveIn: 1.2, said: heard.said)
            }
            if let at = autoSaveAt, Date() >= at { save() }
            // No name in twenty seconds: on without one ("Talare 2" — named later in the text).
            if !typed, draft.isEmpty, since >= 20 { skipName() }
        case .same:
            guard since >= 2.2 else { break }
            // Twice in a row only people already here: the meeting has begun — close.
            quietTurns += 1
            if quietTurns >= 2, !captures.isEmpty {
                closingAt = Date().addingTimeInterval(4)
                set(.closing)
            } else {
                beginTurn()
            }
        case .closing:
            // Talk during the countdown: perhaps someone new — unless the meeting is
            // already under way (only people already here have been talking).
            if inSpeech, quietTurns < 2 { beginTurn(); return }
            if let at = closingAt, Date() >= at { requestEnd() }
        }
    }

    /// Levels in 20 ms frames against the room's own floor (its quietest tenth over the
    /// last five seconds): speech 10 dB above it, silence under 6 dB above it.
    private func analyse(_ samples: [Float]) {
        var i = 0
        while i + Self.frame <= samples.count {
            var sum: Float = 0
            for k in i..<(i + Self.frame) { sum += samples[k] * samples[k] }
            let db = 10 * log10(sum / Float(Self.frame) + 1e-10)
            floor.append(db)
            if floor.count > 250 { floor.removeFirst(floor.count - 250) }
            let sorted = floor.sorted()
            let quietest = sorted[sorted.count / 10]
            let speaking = db > quietest + 10 && db > -62
            let silent = db < quietest + 6 || db < -66
            if speaking { runFrames += 1 } else if silent { runFrames = 0 }
            if runFrames >= 10 { inSpeech = true }      // 200 ms of speech: it has begun
            if silent { inSpeech = false }
            if inSpeech, speechStart == nil, phase == .listening || phase == .new {
                speechStart = max(turnStart, cursor + i - 10 * Self.frame - 1_600)
                if turnSpeech == nil { turnSpeech = speechStart }
            }
            if case .ready = phase { i += Self.frame; continue }
            if inSpeech {
                voiced += 0.02
                silence = 0
                lastSpeech = Date()
            } else if speechStart != nil {
                silence += 0.02
            }
            i += Self.frame
        }
    }

    /// From a second and a half of speech, twice a second: is it someone you know?
    private func check() async {
        guard let session, let start = speechStart else { return }
        checking = true
        defer { checking = false }
        lastCheck = seconds(cursor)
        let audio = session.roundAudio(from: start, to: cursor)
        guard let print = await VoicePrints.shared.print(raw: audio) else { return }
        // Asked for a name, someone talks: a voice you know (or one already here)
        // answers it too — not only a name said aloud.
        let asking = phase == .new
        guard phase == .listening || asking else { return }
        if !asking { turnPrint = print; formingPrint = print }
        // Someone already here, talking on: them again, not a stranger.
        if let previous = alreadyHere(print) {
            Self.log.notice("round: turn \(self.turn) is a voice already in the room")
            figure = previous.figure
            set(.same(previous.name))
            return
        }
        // A voice, and a print of it: the cloud starts to form its figure (the
        // first one stands for the turn — a known voice's own replaces it below).
        if !asking, figure == nil {
            figure = VoiceMemory.shared.figureForNew(print, alsoAvoiding: Set(captures.map(\.figure.rhythm)))
        }
        guard recognitionOn else { return }
        let taken = Set(captures.map(\.name))
        VoiceMemory.shared.logBest(print, speaker: -turn, heard: voiced)
        if let match = VoiceMemory.shared.match(print, excluding: taken) {
            knownMatch = match
            figure = VoiceFigure.remembered(match.name)
            progress = 1
            Self.log.notice("round: turn \(self.turn) known after \(self.voiced, format: .fixed(precision: 1)) s of speech")
            set(.known(match.name))
        }
    }

    /// The turn heard out without a known voice: a new one — its name asked for.
    private func finishTurn() async {
        guard let session, case .listening = phase else { return }
        let thisTurn = turn, thisStart = turnStart
        let start = speechStart ?? turnStart
        if turnPrint == nil || recognitionOn {
            turnPrint = await VoicePrints.shared.print(raw: session.roundAudio(from: start, to: cursor)) ?? turnPrint
        }
        guard case .listening = phase, turn == thisTurn, turnStart == thisStart else { return }
        formingPrint = turnPrint
        if let print = turnPrint, let previous = alreadyHere(print) {
            figure = previous.figure
            set(.same(previous.name))
            return
        }
        if recognitionOn, let print = turnPrint, let match = VoiceMemory.shared.match(print, excluding: Set(captures.map(\.name))) {
            knownMatch = match
            figure = VoiceFigure.remembered(match.name)
            set(.known(match.name))
            return
        }
        progress = 1
        figure = finalFigure(from: turnPrint) ?? VoiceFigure.from(seed: "turn-\(turn)-\(session.record?.id.uuidString ?? "")")
        // "Jag heter Erik": the name from what was said in this turn.
        let from = seconds(start) - 0.3, to = seconds(cursor) + 0.3
        let turnWords = ((session.record?.words ?? []) + session.pending).filter { $0.end > from && $0.start < to }
        let said = turnWords.map(\.text).joined(separator: " ")
        askedAt = seconds(cursor)
        // Listened to afresh while asking: whoever answers.
        candidate = nil
        speechStart = nil
        voiced = 0
        silence = 0
        lastCheck = 0
        set(.new)
        if let name = Self.name(in: MeetingText.clean(said), whole: false) {
            propose(name, saveIn: 1.5, said: Self.whereSaid(name, in: turnWords))
        }
    }

    /// A name heard is taken once the person has stopped talking and the speech model
    /// has written it the same way twice — not the first guess at a word still being
    /// said ("Käll…" for "Känner du igen mig").
    private var candidate: (name: String, since: Date)?
    private func settled(on name: String) -> Bool {
        guard let candidate, candidate.name == name else {
            self.candidate = (name, Date())
            return false
        }
        return !inSpeech && Date().timeIntervalSince(candidate.since) >= 0.4
    }

    /// Someone already in the room, by their voice: this round's print of them, or the
    /// voice you know them by.
    private func alreadyHere(_ print: [Float]) -> Capture? {
        if let c = captures.first(where: { c in c.print.map { VoiceMemory.cosine(print, $0) >= VoiceMemory.sameVoice } ?? false }) {
            return c
        }
        guard recognitionOn, let known = VoiceMemory.shared.match(print, excluding: []) else { return nil }
        return captures.first { Self.sameName($0.name, known.name) }
    }

    /// The figure a new voice keeps, from the whole turn's print: the one the cloud
    /// has formed already stays, unless the final print gives the same loop turned a
    /// little (then that, and the cloud glides over) — the figure never falls apart
    /// and re-forms the moment a name is settled.
    private func finalFigure(from print: [Float]?) -> VoiceFigure? {
        guard let print else { return figure }
        let final = VoiceMemory.shared.figureForNew(print, alsoAvoiding: Set(captures.map(\.figure.rhythm)))
        guard let shown = figure else { return final }
        return shown.rhythm == final.rhythm ? final : shown
    }

    /// "Matilda" and "Matilda Berg" are the same person in a round.
    static func sameName(_ a: String, _ b: String) -> Bool {
        let first = { (s: String) in s.split(separator: " ").first.map { $0.lowercased() } ?? "" }
        return first(a) == first(b)
    }

    /// This turn's words — after the last person added, so their tail doesn't count.
    private func turnWords() -> [MeetingWord] {
        guard let session else { return [] }
        let after = max(seconds(turnStart) - 0.3, captures.last.map { $0.to } ?? 0)
        return ((session.record?.words ?? []) + session.pending).filter { $0.start >= after }
    }

    /// The words in runs, split where someone paused (0.8 s).
    /// The words in runs, split where someone paused (0.8 s) — or where the live voices
    /// hear someone else take over.
    private static func utterances(_ words: [MeetingWord]) -> [[MeetingWord]] {
        var runs: [[MeetingWord]] = []
        for w in words {
            let otherVoice = runs.last?.last.map { p in
                (p.speaker ?? -1) >= 0 && (w.speaker ?? -1) >= 0 && p.speaker != w.speaker
            } ?? false
            if let p = runs.last?.last, w.start - p.end <= 0.8, !otherVoice { runs[runs.count - 1].append(w) } else { runs.append([w]) }
        }
        return runs
    }

    /// The live voice (speaker number) heard most in some words, if any.
    private func voice(of words: [MeetingWord]) -> Int? {
        var time: [Int: Double] = [:]
        for w in words { if let s = w.speaker, s >= 0 { time[s, default: 0] += w.end - w.start } }
        return time.max { $0.value < $1.value }?.key
    }

    private func voice(from: Double, to: Double) -> Int? {
        guard let session else { return nil }
        return voice(of: ((session.record?.words ?? []) + session.pending).filter { $0.end > from && $0.start < to })
    }

    /// A name said in this turn, with where it was said. Only once half a second of
    /// sound has followed it: the speech model can still be finishing the word.
    private func nameInTurn() -> (name: String, from: Double, to: Double, said: ClosedRange<Double>?)? {
        let heardTo = seconds(cursor)
        let here = Set(captures.compactMap { voice(from: $0.from, to: $0.to) })
        for run in Self.utterances(turnWords()).reversed() {
            // (The speech model can stretch the last word over the quiet after it —
            // "här" 11.8–15.6 — so a pause the microphone hears counts too.)
            guard let first = run.first, let last = run.last, last.end <= heardTo - 0.5 || silence >= 0.5 else { continue }
            // Someone already here mentioning a name ("… och det här är Erik") isn't
            // that person introducing themselves.
            if let v = voice(of: run), here.contains(v) { continue }
            let text = MeetingText.clean(run.map(\.text).joined(separator: " "))
            guard let name = Self.name(in: text, whole: true) else { continue }
            // Where the name was said (with the words leading up to it) — that's whose
            // voice it goes to, not everything in the run.
            let key = name.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let at = run.lastIndex { $0.text.lowercased().filter(\.isLetter).hasPrefix(key) } ?? (run.count - 1)
            let from = max(first.start, run[at].start - 1.2)
            return (name, from - 0.1, min(run[at].end, run[at].start + 1.2) + 0.1, Self.whereSaid(name, in: run))
        }
        return nil
    }

    /// Where a name was said among some words: the word that is it (and the surname
    /// after it, "Anna Svensson") — the last time it was said. nil: not among them.
    static func whereSaid(_ name: String, in words: [MeetingWord]) -> ClosedRange<Double>? {
        let parts = name.split(separator: " ").map { $0.lowercased() }
        let letters = { (w: MeetingWord) in w.text.lowercased().filter { $0.isLetter || $0 == "-" } }
        guard let first = parts.first, let at = words.lastIndex(where: { RoundPlacement.isNameWord($0.text, first) })
        else { return nil }
        var end = words[at].end
        if parts.count > 1, at + 1 < words.count, letters(words[at + 1]).hasPrefix(parts[1]) {
            end = words[at + 1].end
        }
        return words[at].start...max(end, words[at].start)
    }

    /// Some words said and then a pause, none of them a name: time to ask.
    private func saidWithoutName() -> Bool {
        let words = turnWords()
        guard words.count >= 4, let last = words.last else { return false }
        return seconds(cursor) - last.end >= 1.5
    }

    /// A new person by the name they said — no card, no waiting.
    private func captureHeard(_ name: String, from: Double, to: Double, said: ClosedRange<Double>?) {
        let colour = captures.count
        let remembered = VoiceFigure.remembered(name)
        // A turn that began well before the name is said (the one before talked on into
        // it) has a print of them, not of this person: it's made again from the name.
        let spokeFirst = speechStart.map(seconds) ?? from
        let late = from - spokeFirst > 2
        let print = late ? nil : turnPrint
        let fig = remembered ?? finalFigure(from: print) ?? VoiceFigure.from(seed: "\(name)-\(colour)")
        captures.append(Capture(name: name, known: false, score: nil, from: from, to: to, print: print,
                                figure: fig, colour: colour,
                                turnFrom: min(from, seconds(turnSpeech ?? speechStart ?? turnStart)),
                                turnTo: max(to, seconds(cursor)), said: said))
        if remembered == nil { VoiceMemory.shared.reserve(fig, for: name) }
        // Its voice, from what it said this turn (when that was long enough): so someone
        // talking on in the next turn is heard as them, not as a new person.
        let spoke = late ? from : min(from, spokeFirst)
        if print == nil, seconds(cursor) - spoke >= 1.5, let session {
            let audio = session.roundAudio(from: Int(spoke * Self.rate), to: cursor)
            let id = captures.last!.id
            Task { [weak self] in
                guard let print = await VoicePrints.shared.print(raw: audio),
                      let self, let i = self.captures.firstIndex(where: { $0.id == id }) else { return }
                self.captures[i].print = print
            }
        }
        Self.log.notice("round: turn \(self.turn) said its name after \(Date().timeIntervalSince(self.phaseSince), format: .fixed(precision: 1)) s")
        turn += 1
        beginTurn()
    }

    private func propose(_ name: String, saveIn seconds: Double, said: ClosedRange<Double>?) {
        guard name != draft, !captures.contains(where: { Self.sameName($0.name, name) }) else { return }
        draft = name
        spokenDraft = name
        draftSaid = said
        autoSaveAt = Date().addingTimeInterval(seconds)
        Self.log.notice("round: turn \(self.turn) heard its name")
    }

    /// What was said since the card asked — the latest short utterance, if it names
    /// someone — and where the name was said.
    private func heardName() -> (name: String, said: ClosedRange<Double>?)? {
        guard let session else { return nil }
        let words = ((session.record?.words ?? []) + session.pending).filter { $0.start >= askedAt - 0.2 }
        guard !words.isEmpty else { return nil }
        // The last utterance: words with no pause over 0.8 s between them.
        var last: [MeetingWord] = []
        for w in words {
            if let p = last.last, w.start - p.end > 0.8 { last = [] }
            last.append(w)
        }
        guard let name = Self.name(in: MeetingText.clean(last.map(\.text).joined(separator: " ")), whole: true) else { return nil }
        return (name, Self.whereSaid(name, in: last))
    }

    /// A name in what was said: "jag heter Anna", "det är Anna", "Anna här" — or, said
    /// on its own (`whole`), just "Anna": a first name people in Sweden have (or one in
    /// your Ordlista, or a voice you've named), not an ordinary word — so a misheard
    /// sound never becomes someone's name.
    static func name(in text: String, whole: Bool) -> String? {
        if let name = VoiceScanner.spokenName(in: text) { return name }
        // A first name people have — Emma, Björn, Linda, though they're words too —
        // or, for "… här", a capitalised word that isn't an ordinary word.
        let firstName = { (t: String) in
            t.count >= 2 && t.first?.isUppercase == true && !notNames.contains(t.lowercased()) && FirstNames.isName(t)
        }
        let ns = text as NSString
        if let here = try? NSRegularExpression(pattern: #"(\p{Lu}[\p{L}\-]+)(?: [\p{Lu}][\p{L}\-]+)? här\b"#),
           let m = here.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: m.range(at: 1))
            if firstName(candidate) || !notNames.contains(candidate.lowercased())
                && !TextCleanup.isOrdinaryWord(candidate.lowercased(), in: text) { return candidate }
        }
        guard whole else { return nil }
        let tokens = text.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
        guard (1...3).contains(tokens.count) else { return nil }
        guard let i = tokens.firstIndex(where: firstName) else { return nil }
        // "Anna Svensson": the surname too, when said with it.
        if i + 1 < tokens.count, let next = tokens.dropFirst(i + 1).first, next.count >= 2, next.first?.isUppercase == true,
           !notNames.contains(next.lowercased()), !TextCleanup.isOrdinaryWord(next.lowercased(), in: text) {
            return tokens[i] + " " + next
        }
        return tokens[i]
    }

    /// Words that are first names too (all in the name list) but said on their own are
    /// almost always just the word: "Man", "Vi", "Nu", "Sen", "Alla" …
    static let notNames: Set<String> = VoiceScanner.greetings.union([
        "man", "vi", "nu", "sen", "han", "hon", "alla", "inga", "jo", "du", "den", "det", "de", "en", "ett", "är", "och",
        "bra", "så", "här", "där", "var", "vad", "när", "men", "om", "till", "för", "på", "av", "med", "kan", "ska",
        "vill", "har", "hade", "bli", "blir", "mer", "bara", "också", "nog", "ju", "väl", "nästa", "kanske", "precis",
        "exakt", "visst", "absolut", "the", "and", "you", "so", "yes", "no", "well", "right", "sure", "next", "fine",
        // "min", "din", "sin" … ("i östra minnen" from a radio was taken for Min).
        "min", "mitt", "din", "ditt", "sin", "sitt", "sina",
    ])

    /// Keeps the round's place in a countdown the scanner can show.
    var secondsLeft: Int? {
        if case .closing = phase, let closingAt { return max(0, Int(ceil(closingAt.timeIntervalSinceNow))) }
        return nil
    }

    // MARK: After the round
    //
    // Which voice each turn's name goes on is RoundPlacement's: by the voice that said the
    // name, never a voice heard through the whole round, checked against the voices you
    // know (MeetingSession.placeRound asks it again as the words settle, and at the end).

    #if DEBUG
    /// Screenshots: the moment a name is settled, held still (`--demo-phase reveal`):
    /// the name, and whether the voice was known.
    private(set) var demoReveal: (name: String, known: Bool)?

    /// Screenshots: a round in a given state (`--demo-phase listening|forming|known|new|ready|reveal`):
    /// listening is early in a turn, the ring filling; forming is further in, with a
    /// print of the turn so far and the cloud halfway into its figure.
    func demo(_ phase: String) {
        if phase == "first" { set(.ready); task?.cancel(); return }
        captures = [Capture(name: "Anna", known: true, score: 0.8, from: 1, to: 6, print: VoiceMemory.demoPrint("anna"),
                            figure: VoiceFigure.from(seed: "anna"), colour: 0)]
        turn = 2
        switch phase {
        case "listening":
            progress = 0.3
            set(.listening)
        case "forming":
            formingPrint = VoiceMemory.demoPrint("sara")
            figure = VoiceFigure.from(seed: "sara")
            progress = 0.6
            set(.listening)
        case "known":
            // `--round-name "Kristoffer"`: a longer name, to see the greeting fit.
            let name = CommandLine.arguments.firstIndex(of: "--round-name")
                .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "Erik"
            figure = VoiceFigure.from(seed: name.lowercased()); progress = 1; knownMatch = (name, 0.8); set(.known(name))
        case "new":
            figure = VoiceFigure.from(seed: "sara"); progress = 1; draft = "Sara"
            formingPrint = VoiceMemory.demoPrint("sara")
            set(.new)
        case "reveal":
            // Two in the room, and Sara's voiceprint just made: the next turn has begun.
            captures.append(Capture(name: "Erik", known: false, score: nil, from: 8, to: 13, print: VoiceMemory.demoPrint("erik"),
                                    figure: VoiceFigure.from(seed: "erik"), colour: 1))
            captures.append(Capture(name: "Sara", known: false, score: nil, from: 15, to: 19, print: VoiceMemory.demoPrint("sara"),
                                    figure: VoiceFigure.from(seed: "sara"), colour: 2))
            turn = 4
            figure = VoiceFigure.from(seed: "sara")
            demoReveal = ("Sara", false)
            set(.ready)
        default: set(.ready)
        }
        task?.cancel()
    }

    /// Self-test: a name typed for a new voice (`--round-names "Anna,Erik"`).
    func typeForTest(_ names: [String]) {
        guard case .new = phase else { return }
        let i = captures.filter { !$0.known }.count
        if draft.isEmpty, i < names.count { draft = names[i] }
        save()
    }
    #endif
}
