import AVFoundation
import Accessibility
import AppKit
import FluidAudio
import os

// MARK: - Recording a meeting
//
// The microphone runs for the whole meeting; its audio goes three ways:
//   • to disk (audio.caf), so nothing is lost and the final pass can read it all;
//   • to the voice tracker, which scores who is speaking every 10 ms;
//   • to the speech model, twice a second: whatever hasn't settled yet — with two
//     seconds before it for context, at most 14 s — is written out again. Words
//     followed by a pause, with a second of audio after them, settle; the rest
//     shows as still being written. Pianissimo reads 14 s in about a tenth of a
//     second, so this keeps up easily, and a word always has context on both
//     sides before it settles. (Starting a window right at a word loses it.)
// Speakers are given per sentence — it ends at . ? ! or a pause — to whoever
// spoke most during it: people take turns at sentences, and a short word alone
// (the "Det" in "Det är bra.") says too little about a voice.
//
// When the meeting ends, the recording is read once more from start to finish:
// words without seams, and voices with 10 s of context. Names given during the
// meeting follow each voice across.

@MainActor
final class MeetingSession: ObservableObject {
    static let shared = MeetingSession()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Meeting")

    enum Phase: Equatable {
        case idle
        /// The microphone is on; the models are getting ready.
        case starting
        case recording
        /// The final pass, and what it is doing.
        case finishing(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            if case .finishing = phase { if finishingSince == nil { finishingSince = Date() } } else { finishingSince = nil }
        }
    }
    /// When the final pass began — its time is shown beside what it's doing.
    @Published private(set) var finishingSince: Date?
    /// The meeting being recorded or finished; nil otherwise.
    @Published private(set) var record: MeetingRecord?
    /// Words still being written: they may change until a pause settles them.
    @Published private(set) var pending: [MeetingWord] = []
    @Published private(set) var startedAt: Date?
    /// Something to know while recording: no sound, the mic changed, no voices.
    @Published private(set) var warning: String?
    /// The meeting that just finished — the page keeps showing it.
    @Published private(set) var finished: UUID?
    @Published var lastError: String?
    /// Stopping was asked for once; asking again within a few seconds ends the meeting.
    /// "Vem är här?": the meeting starts with a round of names (VoiceScanner).
    @Published private(set) var introducing = false
    /// "Starta möte" from the menu bar, the shortcut or Hem: the window is open on
    /// Möten and the start card waits for your choice. Nothing is recorded until then.
    @Published var armed = false
    /// The moment a meeting was started by hand: the page shows "Nu spelar vi in".
    @Published private(set) var startMoment: Date?

    /// How the last meeting was started: with the round of names, or straight in.
    /// The card's default button, and what the shortcut does.
    enum StartMode: String { case round, direct }
    static var startMode: StartMode {
        get { UserDefaults.standard.string(forKey: "meetingStartMode").flatMap(StartMode.init) ?? .round }
        set { Settings.keep(newValue.rawValue, forKey: "meetingStartMode") }
    }

    /// Starts the way you chose last time (the shortcut, the card's Return key) —
    /// not while what it needs is still being prepared: the card says so and waits.
    func startRemembered(folder: UUID? = nil) {
        guard !Self.preparing(Self.startMode) else { return }
        startFromCard(Self.startMode, folder: folder)
    }

    /// A start from the card (a tile, Return, or the shortcut while the card is in
    /// front): the card says to tell everyone it's recorded, so that is noted. The very
    /// first time, Mindtalk first asks whether to remember the voices, and nothing is
    /// recorded until that is answered.
    func startFromCard(_ mode: StartMode, folder: UUID? = nil) {
        guard phase == .idle else { return }
        if Self.asksAboutVoices {
            voiceQuestion = PendingStart(mode: mode, folder: folder)
            return
        }
        start(introducing: mode == .round, folder: folder, informed: true)
    }

    /// A start waiting for "Ska Mindtalk känna igen rösterna nästa gång?".
    struct PendingStart: Equatable {
        let mode: StartMode
        let folder: UUID?
    }
    @Published private(set) var voiceQuestion: PendingStart?

    /// Never chosen (no value stored, the question never answered): asked before the
    /// first meeting starts. Someone who chose on the card or in Settings isn't asked.
    static var asksAboutVoices: Bool { asksAboutVoices(in: .standard) }

    nonisolated static func asksAboutVoices(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "voiceMemory") == nil && !defaults.bool(forKey: "voiceMemoryAsked")
    }

    /// The answer: the setting as said, never asked again, and the meeting starts.
    func answerVoiceQuestion(remember: Bool) {
        guard let pending = voiceQuestion else { return }
        voiceQuestion = nil
        Settings.keep(true, forKey: "voiceMemoryAsked")
        VoiceMemory.shared.enabled = remember
        Self.log.notice("voices: asked before the first meeting, remember \(remember)")
        start(introducing: pending.mode == .round, folder: pending.folder, informed: true)
    }

    /// Esc on the question: nothing starts, nothing is recorded.
    func cancelVoiceQuestion() { voiceQuestion = nil }

    /// After a meeting ends: the one sentence said about it, wherever it's said (Hem,
    /// the panel, the notification, VoiceOver). Without anything to summarise with, the
    /// first half only.
    static func endedSentence(summarizing: Bool? = nil) -> String {
        summarizing ?? MeetingNotes.isAvailable
            ? String(localized: "Mötet är sparat. Sammanfattningen skrivs nu.") : String(localized: "Mötet är sparat.")
    }

    /// The models a start needs are still being made ready — the speech model, and for
    /// the round the voices too. The start card's buttons wait; nothing starts on its own
    /// once they're ready.
    static func preparing(_ mode: StartMode) -> Bool {
        #if DEBUG
        if let previewPreparing { return previewPreparing }
        #endif
        return Dictation.shared.model == .loading
            || (mode == .round && VoiceModels.isInstalled && !VoiceModels.shared.isWarm)
    }
    #if DEBUG
    /// Screenshots: the start card as if preparing (true) or ready (false).
    static var previewPreparing: Bool?
    #endif
    /// Voices you've named before, recognised while the meeting runs (the round does
    /// its own while it's up).
    private var recognition: Task<Void, Never>?
    /// Voices of the round Mindtalk has tried to recognise — until then the scanner
    /// says "Känner igen rösten…" rather than asking for a name.
    @Published private(set) var introChecked: Set<Int> = []
    /// The figures of new voices in the round (VoiceFigure), from their voiceprints —
    /// kept when the voice is named and saved.
    @Published private(set) var introFigures: [Int: VoiceFigure] = [:]
    /// Recording from a Bluetooth headset — no sounds then (they can cost the mic).
    var usesBluetooth: Bool { recorder.usesBluetooth }
    /// A sound would reach a Bluetooth headset — recorded from, or played to (the
    /// output or the alert device): no sounds while recording then.
    var soundsReachBluetooth: Bool { recorder.usesBluetooth || Recorder.outputIsBluetooth }

    /// Ending: the moment it ends, unless you undo it. Recording goes on until then.
    @Published private(set) var stopAt: Date?
    var stopping: Bool { stopAt != nil }
    private var stopCountdown: Task<Void, Never>?
    static let undoSeconds = 3.0

    /// Paused: the microphone is off and the meeting waits — the time stands still,
    /// and it goes on from where it was.
    @Published private(set) var pausedAt: Date?
    var isPaused: Bool { pausedAt != nil }
    /// The meeting's time at `date`: since it began, less the pauses — and, continued,
    /// on from where it ended.
    func clock(at date: Date) -> Double {
        guard let startedAt else { return 0 }
        return max(0, (pausedAt ?? date).timeIntervalSince(startedAt))
    }
    /// Continuing a finished meeting: the voices of this part are numbered from here,
    /// after those already in its text…
    private var speakerBase = 0
    /// …and those voices of the part before, as prints: a voice now that matches one
    /// is that person, name and all.
    private var earlier: [Int: [Float]] = [:]
    /// This recording continues a finished meeting (`continueMeeting`)…
    private(set) var continuing = false
    /// …which was this when it was continued: a continuation that recorded nothing
    /// puts it back as it was.
    private var before: MeetingRecord?
    /// A continuation's recordings couldn't be joined: the meeting stays unfinished,
    /// and "Gör klart" tries again.
    private var keepUnfinished = false

    var isRecording: Bool { phase == .starting || phase == .recording }
    var isBusy: Bool { phase != .idle }
    private(set) var language: SpeechModel = .swedish

    private var recorder = Recorder(keepSamples: false)
    private var intake: AudioIntake?
    private var tracker: VoiceTracker?
    /// The same voices with ten seconds of context: slower, steadier — what the
    /// quick one says is confirmed or corrected by this one a few seconds later.
    private var steady: VoiceTracker?
    private var steadyScores: [Float] = []
    private var loop: Task<Void, Never>?
    /// Who is speaking: `VoiceTracker.speakers` scores per 10 ms, from the start.
    private var scores: [Float] = []
    /// Seconds already settled into words.
    private var settled: Double = 0
    /// Audio heard again before what hasn't settled, for context.
    private static let lead: Double = 2
    /// The first word whose speaker isn't known yet.
    private var unresolved = 0
    private var activity: NSObjectProtocol?
    private var lastSave = Date()
    /// When the room last sounded like someone speaking.
    private var lastHeard = Date()
    /// Two voices said to be one person: speaker → the one it became.
    private var aliases: [Int: Int] = [:]
    /// How often each quick voice and each steady voice spoke at the same moment,
    /// over the whole meeting so far — and how many frames of it are counted.
    private var voiceOverlap = MeetingSession.noOverlap
    private var overlapFrames = 0
    /// Transcriptions that failed in a row.
    private var failures = 0
    /// Live scores kept after a meeting, for the final pass to carry names across.
    private var sleepObserver: NSObjectProtocol?

    private init() {
        // A Mac going to sleep ends the meeting cleanly rather than cutting it off.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let session = MeetingSession.shared
                // Paused, the mic is already off: the meeting waits through the sleep.
                guard session.isRecording, !session.isPaused else { return }
                session.lastError = String(localized: "Mötet avslutades när Macen gick i vila.")
                session.stop()
            }
        }
    }

    private static let rate = 16_000

    /// `--fake-mic fil.caf` (DEBUG): a real meeting, window and all, heard from a recording.
    static var fakeMic: URL? {
        #if DEBUG
        CommandLine.arguments.firstIndex(of: "--fake-mic").flatMap {
            $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil
        }
        #else
        nil
        #endif
    }

    #if DEBUG
    /// Self-test: an audio file played in as if it were the microphone.
    private var simulation: (start: Date, speed: Double)?

    #if DEBUG
    private var lastRoundState = ""
    /// The part of the fake mic's file to play: `--fake-from`, `--fake-limit` (seconds).
    var fakeRange: (from: Double, to: Double?) = (argSeconds("--fake-from") ?? 0, argSeconds("--fake-limit"))

    private func feedFake(_ url: URL) {
        simulation = (Date(), 1)              // nothing learned, no notes written
        setvbuf(stdout, nil, _IOLBF, 0)        // each line out at once — a stopped test keeps its output
        Task { @MainActor in
            guard let source = try? AudioChunks(url: url) else { return print("Fel: kan inte läsa \(url.path)") }
            var lastReport = 0
            // `--fake-wait`: the recording begins once the models are ready (a test of
            // the live text that isn't eaten by a long first load).
            if CommandLine.arguments.contains("--fake-wait") {
                while phase == .starting || phase == .idle { try? await Task.sleep(for: .milliseconds(200)) }
            }
            // Paced by the clock, not by the sleeps: macOS stretches a background app's
            // timers, and a mic doesn't wait.
            var skipped = 0.0
            while skipped < fakeRange.from, let more = try? source.next(seconds: 1), !more.isEmpty { skipped += 1 }
            var began = Date()
            var fed = 0.0
            var paused = false
            feeding: while isRecording || phase == .starting {
                // `--pause-at s --pause-for s`: a pause, as with the button.
                if !paused, let at = Self.argSeconds("--pause-at"), fed >= at, phase == .recording {
                    paused = true
                    print("[\(Int(elapsed)) s] paus")
                    pause()
                    let p0 = Date()
                    try? await Task.sleep(for: .seconds(Self.argSeconds("--pause-for") ?? 5))
                    print("[\(Int(elapsed)) s] fortsätter efter paus (klockan \(Int(clock(at: Date()))) s)")
                    resume()
                    began = began.addingTimeInterval(Date().timeIntervalSince(p0))
                }
                var chunk: [Float] = []
                while fed < Date().timeIntervalSince(began) {
                    if let to = fakeRange.to, skipped + fed >= to { break feeding }
                    guard let more = try? source.next(seconds: 0.1), !more.isEmpty else { break feeding }
                    intake?.append(more)
                    chunk = more
                    fed += 0.1
                }
                let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count)))
                heard(min(1, rms * 8))
                if let at = Self.argSeconds("--introduce-at"), elapsed >= at, !introducing, !introductionHeld {
                    print("[\(Int(elapsed)) s] Presentationsrunda trycks"); introduce()
                }
                if let round {
                    let state = "tur \(round.turn) \(round.phase) ring \(Int(round.progress * 100)) % · i rummet \(round.captures.map(\.name))"
                    if state != lastRoundState { lastRoundState = state; print("[\(String(format: "%.1f", elapsed)) s] \(state)") }
                    if case .new = round.phase, let i = CommandLine.arguments.firstIndex(of: "--round-names"), i + 1 < CommandLine.arguments.count {
                        round.typeForTest(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
                    }
                }
                if let n = Self.argSeconds("--name-at"), elapsed >= n, introducing, let r = record,
                   r.names.values.allSatisfy(\.isEmpty) {
                    for s in Set(r.words.compactMap(\.speaker)).filter({ $0 >= 0 }) { name(speaker: s, as: "Person \(s)") }
                    print("[\(Int(elapsed)) s] namn: \(record?.names ?? [:])")
                }
                if Int(elapsed) / 2 > lastReport {
                    lastReport = Int(elapsed) / 2
                    print("[\(Int(elapsed)) s] ord \(record?.words.count ?? 0) · väntande \(pending.count) · avklarat \(String(format: "%.1f", settled)) s · runda \(introducing) · fas \(phase)")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("[\(Int(elapsed)) s] ljudet slut")
            if isRecording { stop() }
        }
    }
    #endif

    static func argSeconds(_ flag: String) -> Double? {
        CommandLine.arguments.firstIndex(of: flag).flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil }
    }

    /// Self-test (`--relisten "titel"`): a copy of a named meeting listened to again, as
    /// "Gör klart" does — are the names (and merges) where they were? The copy is
    /// removed after, nothing is learned.
    func relistenTest(title: String) async {
        MeetingStore.shared.loadNow()
        guard let original = MeetingStore.shared.meetings.first(where: { $0.title.contains(title) && $0.hasAudio }) else {
            return print("Inget möte med ljud som heter \(title).")
        }
        var copy = original
        copy.id = UUID()
        copy.title = "Självtest: " + original.title
        do {
            try MeetingStore.prepareFolder(for: copy.id)
            try FileManager.default.copyItem(at: MeetingStore.audioURL(for: original.id), to: MeetingStore.audioURL(for: copy.id))
        } catch { return print("Fel: \(error.localizedDescription)") }
        MeetingStore.shared.save(copy)
        simulation = (Date(), 1)              // nothing learned, no notes written
        finishInterrupted(copy.id)
        try? await Task.sleep(for: .milliseconds(300))
        while phase != .idle { try? await Task.sleep(for: .milliseconds(200)) }
        guard let after = MeetingStore.shared.meetings.first(where: { $0.id == copy.id }) else { return print("Kopian försvann.") }
        // Per second of speech: the name before and after.
        func nameAt(_ record: MeetingRecord, _ t: Double) -> String? {
            guard let w = record.words.first(where: { $0.start <= t && t < $0.end + 0.2 }), let s = w.speaker, s >= 0 else { return nil }
            return record.name(of: s)
        }
        var same = 0, total = 0
        var t = 0.0
        while t < original.duration {
            if let a = nameAt(original, t), let b = nameAt(after, t) { total += 1; if a == b { same += 1 } }
            t += 0.5
        }
        print("Före: \(original.cast.order.map { original.name(of: $0) }.joined(separator: ", "))")
        print("Efter: \(after.cast.order.map { after.name(of: $0) }.joined(separator: ", "))")
        print(String(format: "Samma namn på samma ställe: %.0f %% av talet (%d av %d halvsekunder)",
                     total == 0 ? 0 : Double(same) / Double(total) * 100, same, total))
        print("Sammanfattningen kvar: \(after.summary != nil ? "ja" : (original.summary == nil ? "fanns ingen" : "NEJ"))")
        try? FileManager.default.removeItem(at: MeetingStore.folder(for: copy.id))
    }

    /// `round`: `--round-replay-test` — the guided round from the first second, the audio
    /// held back until the models are ready (as a real round waits for them), and the
    /// names the meeting ended with printed as one line of JSON (ROUND-RESULT).
    func simulate(file: URL, language: SpeechModel, speed: Double, round replay: Bool = false) async {
        setvbuf(stdout, nil, _IOLBF, 0)        // each line out at once, also into a file
        if !VoiceModels.isInstalled {
            print("Hämtar röstmodellen…")
            VoiceModels.shared.download()
            while case .downloading = VoiceModels.shared.state { try? await Task.sleep(for: .milliseconds(500)) }
            guard VoiceModels.isInstalled else { return print("Fel: \(VoiceModels.shared.state)") }
        }
        self.language = language
        let new = MeetingRecord(title: "Självtest", date: Date(), language: language)
        do {
            try MeetingStore.prepareFolder(for: new.id)
            intake = try AudioIntake(file: MeetingStore.audioURL(for: new.id))
        } catch { return print("Fel: \(error.localizedDescription)") }
        record = new
        startedAt = Date()
        phase = .starting
        simulation = (Date(), speed)
        loop = Task { await self.run() }
        if CommandLine.arguments.contains("--introduce") || replay { beginIntroduction() }
        if replay {
            let t0 = Date()
            while phase == .starting { try? await Task.sleep(for: .milliseconds(200)) }
            print("Modellerna redo efter \(Int(Date().timeIntervalSince(t0))) s")
            startedAt = Date()
        }
        do {
            let source = try AudioChunks(url: file)
            // `--introduce-at 20`: "Presentationsrunda" pressed that many seconds in.
            let at = CommandLine.arguments.firstIndex(of: "--introduce-at").flatMap {
                $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil
            }
            while let chunk = try source.next(seconds: 0.1) {
                intake?.append(chunk)
                if let at, elapsed >= at, !introducing, !introductionHeld { print("Presentationsrunda vid \(Int(elapsed)) s"); introduce() }
                // `--name-at 22` and `--end-round-at 28`: names given and "Alla är här" pressed, as in the round.
                if let n = Self.argSeconds("--name-at"), elapsed >= n, introducing, let r = record, r.names.isEmpty {
                    for s in Set(r.words.compactMap(\.speaker)).filter({ $0 >= 0 }) { name(speaker: s, as: "Person \(s)") }
                    print("Namn givna vid \(Int(elapsed)) s: \(record?.names ?? [:])")
                }
                if let e = Self.argSeconds("--end-round-at"), elapsed >= e, introducing {
                    print("Rundan slut vid \(Int(elapsed)) s, ord hittills: \(record?.words.count ?? 0)")
                    endIntroduction()
                }
                if let round {
                    let state = "tur \(round.turn) \(round.phase) · i rummet \(round.captures.map(\.name))"
                    if state != lastRoundState { lastRoundState = state; print("[\(String(format: "%.1f", elapsed)) s] \(state)") }
                }
                try? await Task.sleep(for: .milliseconds(Int(100 / speed)))
            }
        } catch { print("Fel: \(error.localizedDescription)") }
        if introducing, let record {
            print("Under presentationen kändes igen: " + record.names.filter { record.recognized[$0.key] != nil }
                .map { "talare \($0.key) = \($0.value) (\(String(format: "%.2f", record.recognized[$0.key] ?? 0)))" }
                .joined(separator: ", "))
        }
        stop()
        while phase != .idle { try? await Task.sleep(for: .milliseconds(200)) }
        if let id = finished {
            if let saved = MeetingStore.shared.meetings.first(where: { $0.id == id }) {
                print("\n=== Efter genomgången (\(saved.speakers.count) talare) ===\n" + MeetingText.plain(saved))
                if replay { printRoundResult(saved) }
                if let heal = saved.heal { print("\n" + MeetingView.healText(heal) + " – ändrade ord: " + heal.changed.map { saved.words[$0].text }.joined(separator: ", ")) }
            }
            // `--keep`: left in Möten, to look at afterwards.
            if !CommandLine.arguments.contains("--keep") { MeetingStore.shared.delete(id, quietly: true) } else { print("Sparat: \(id.uuidString)") }
        }
    }

    /// The round's turns as they were when it ended (`--round-replay-test` prints them).
    private var replayTurns: [IntroRound.Capture] = []

    /// One line a script can read: the names each voice ended with, which of them were
    /// recognised, the round's turns and every word with its voice.
    private func printRoundResult(_ saved: MeetingRecord) {
        let turns: [[String: Any]] = replayTurns.map { ["name": $0.name, "from": $0.from, "to": $0.to, "known": $0.known] }
        let words: [[Any]] = saved.words.map { [$0.start, $0.end, $0.speaker ?? -2, $0.text] }
        let out: [String: Any] = ["names": saved.names, "recognized": saved.recognized.mapValues { Double($0) },
                                  "turns": turns, "words": words]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print("ROUND-RESULT " + line) }
    }

    /// Screenshots: a meeting twelve minutes in, three people, one of them named.
    func showDemo(finished: Bool) {
        // `--demo-scanner`: the introduction round — Anna known, Erik just said his name.
        if CommandLine.arguments.contains("--demo-scanner") {
            var new = MeetingRecord(title: "Veckomöte om lanseringen", date: Date().addingTimeInterval(-40), language: .swedish)
            var t = 1.0
            for (speaker, line) in [(0, "Hej allihop, det är Anna här."), (1, "Hej, jag heter Erik och jobbar med försäljningen."),
                                    (2, "Och så är det jag här också, hej.")] {
                for word in line.split(separator: " ") {
                    new.words.append(MeetingWord(text: String(word), start: t, end: t + 0.3, speaker: speaker))
                    t += 0.38
                }
                t += 1.2
            }
            new.names = ["0": "Anna"]
            new.recognized = ["0": 0.82]
            new.duration = 40
            record = new
            startedAt = Date().addingTimeInterval(-40)
            phase = .recording
            // `--demo-opening`: the meeting just begun, "Innan ni börjar" offered.
            introducing = !CommandLine.arguments.contains("--demo-opening")
            // `--demo-comparing`: still comparing voiceprints — the listening sphere.
            if !CommandLine.arguments.contains("--demo-comparing") { introChecked = [0, 1, 2] }
            LiveMeter.shared.demo([0.2, 0.5, 0.35, 0.7, 0.45, 0.6, 0.3, 0.55])
            return
        }
        let script: [(Int, String)] = [
            (0, "Då kör vi. Välkomna allihop. Idag ska vi gå igenom lanseringen och bestämma vad som händer härnäst."),
            (1, "Siffrorna ser riktigt bra ut. Vi hade fler nedladdningar första dagen än hela förra månaden."),
            (0, "Vad kul! Vet vi var de flesta användarna kommer ifrån?"),
            (2, "Mest från Sverige, men vi ser en del från Norge och Danmark också. The feedback in English is great too."),
            (1, "Jag tycker att vi ska prioritera mötesfunktionen. Det är det folk frågar mest om."),
            (0, "Håller med. Kan du ta fram en plan till torsdag?"),
        ]
        var new = MeetingRecord(title: "Veckomöte om lanseringen", date: Date().addingTimeInterval(-754), language: .swedish)
        var t = 3.0
        for (speaker, line) in script {
            for word in line.split(separator: " ") {
                new.words.append(MeetingWord(text: String(word), start: t, end: t + 0.3, speaker: speaker))
                t += 0.38
            }
            t += 1.2
        }
        new.names = ["0": "Anna", "1": "Erik"]
        new.duration = 754
        // Two moments marked, so the labels show (Erik's priority, Anna's ask).
        let erik = new.words.firstIndex { $0.text == "prioritera" }.map { new.words[$0].start + 1 } ?? 30
        let anna = new.words.firstIndex { $0.text == "plan" }.map { new.words[$0].start + 1 } ?? 40
        new.marks = [MeetingRecord.Mark(at: erik, kind: .decision), MeetingRecord.Mark(at: anna, kind: .task)]
        if finished {
            new.refined = true
            MeetingStore.shared.save(new)
            self.finished = new.id
            return
        }
        record = new
        pending = ["Ja,", "absolut.", "Jag", "skickar", "den"].enumerated().map {
            MeetingWord(text: $1, start: t + Double($0) * 0.38, end: t + Double($0) * 0.38 + 0.3, speaker: 1)
        }
        startedAt = Date().addingTimeInterval(-754)
        LiveMeter.shared.demo([0.1, 0.3, 0.5, 0.35, 0.6, 0.45, 0.2, 0.5, 0.7, 0.4, 0.3, 0.55, 0.65, 0.4, 0.25, 0.5, 0.6, 0.3,
                  0.2, 0.45, 0.6, 0.35, 0.5, 0.4])
        phase = CommandLine.arguments.contains("--demo-finishing")
            ? .finishing(String(localized: "Lyssnar igenom hela mötet…")) : .recording
    }

    private func report(settled words: ArraySlice<MeetingWord>) {
        guard simulation != nil, let last = words.last else { return }
        // Against the audio fed so far, not the clock: the feed's sleeps run a little long.
        let heard = Double(intake?.count ?? 0) / Double(Self.rate)
        // How long each word waited to settle — the oldest in the block waited longest.
        let waits = words.map { String(format: "%.1f", heard - $0.end) }.joined(separator: " ")
        print(String(format: "[%5.1f s, %.1f s efter] ", heard, heard - last.end) + words.map(\.text).joined(separator: " ")
              + "  {väntan: \(waits)}")
    }
    #endif

    // MARK: Start and stop

    /// `folder`: started on the Möten page while a folder is chosen there — it goes
    /// in it. (From the menu bar or the shortcut, in none: the page suggests one after.)
    /// `informed`: started from the card, where it says to tell everyone the meeting is
    /// recorded; the moment is noted ("Deltagarna informerades") in the meeting.
    func start(introducing: Bool = false, folder: UUID? = nil, informed: Bool = false) {
        guard phase == .idle else { return }
        voiceQuestion = nil
        lastError = nil
        let dictation = Dictation.shared
        // What stands in the way first, said on the card — the card stays as it was.
        // Only while the dictation has the microphone — a thought just saved or text
        // just copied (the HUD still saying so) doesn't stand in the way.
        guard dictation.phase != .recording, dictation.phase != .transcribing else {
            lastError = String(localized: "Avsluta dikteringen först.")
            return
        }
        guard dictation.engine.isInstalled else {
            lastError = String(localized: "Ladda ned \(dictation.engine.modelName) först, under Inställningar → Språk.")
            return
        }
        guard VoiceModels.isInstalled else {
            lastError = String(localized: "Ladda ned Nemotron 3 först, under Inställningar → Möten.")
            return
        }
        guard Recorder.micAuthorized else {
            lastError = String(localized: "Mindtalk behöver få använda mikrofonen.")
            return
        }
        armed = false
        // Nothing plays while the microphone listens — into AirPods, or back into the text.
        MeetingPlayer.shared.stop()
        // A model in Ollama or LM Studio is let go: the speech models have the memory.
        LocalServers.shared.release()
        NoteDraft.shared.text = ""
        steps = 0
        // A round from a meeting before is never this one's.
        resetRound()
        roundMeeting = nil
        language = dictation.engine
        let date = Date()
        var new = MeetingRecord(title: MeetingRecord.defaultTitle(for: date), date: date, language: language)
        new.finished = false
        new.folder = MeetingFolders.shared.folder(folder)?.id
        new.folderAsked = new.folder != nil
        if informed { new.informed = date }
        do {
            try MeetingStore.prepareFolder(for: new.id)
            let intake = try AudioIntake(file: MeetingStore.audioURL(for: new.id))
            self.intake = intake
            try openMicrophone(into: intake)
        } catch {
            intake = nil
            try? FileManager.default.removeItem(at: MeetingStore.folder(for: new.id))
            lastError = error.localizedDescription
            return
        }
        record = new
        continuing = false
        speakerBase = 0
        earlier = [:]
        pausedAt = nil
        finished = nil
        pending = []
        scores = []
        steadyScores = []
        settled = 0
        unresolved = 0
        aliases = [:]
        voiceOverlap = Self.noOverlap
        overlapFrames = 0
        failures = 0
        warning = nil
        startedAt = date
        lastSave = date
        lastHeard = date
        resetWatch(newVoicesAfter: 180)
        phase = .starting
        startMoment = date
        lastRestart = nil
        gaveUpOnSignal = false
        // Not into a Bluetooth headset: when a sound there ends, macOS may hand the
        // headset's link over (to a phone it's also paired with) and the mic goes dead.
        if !soundsReachBluetooth { Cue.start() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Recording a meeting")
        MeetingStore.shared.save(new)
        Self.log.info("meeting started (\(self.language.rawValue, privacy: .public))")
        begin()
        introductionHeld = false
        // The round from the first second: the mic just opened, so it listens from 0 s.
        if introducing { beginIntroduction() }
    }

    /// The microphone, into the meeting's audio.
    private func openMicrophone(into intake: AudioIntake) throws {
        recorder = Recorder(keepSamples: false)
        recorder.onChunk = { chunk in intake.append(chunk) }
        recorder.onLevel = { level in Task { @MainActor in MeetingSession.shared.heard(level) } }
        recorder.onInterrupted = { Task { @MainActor in MeetingSession.shared.inputChanged() } }
        recorder.onSignalLost = { Task { @MainActor in MeetingSession.shared.signalLost() } }
        try startMicrophone()
    }

    private func startMicrophone() throws {
        guard Self.fakeMic == nil else { return }
        let chosen = Microphones.shared.selectedDeviceID
        do {
            try recorder.start(device: chosen)
        } catch where chosen != nil {
            // The chosen mic won't open — the Mac's own will do.
            Self.log.error("chosen microphone failed, using the system input")
            try recorder.start(device: nil)
        }
    }

    /// The live text, the voices and the recognising, from the moment the mic is on.
    private func begin() {
        loop = Task { await self.run() }
        heartbeat = Task { await self.beat() }
        recognition = Task { @MainActor [weak self] in
            var checked: [Int: Double] = [:]          // speaker → speech heard when last checked
            var earlierChecked: [Int: Double] = [:]
            while let self, self.isRecording || self.phase == .starting {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !self.introducing {
                    await self.recogniseEarlier(&earlierChecked)
                    await self.recogniseIntroduced(&checked)
                }
            }
        }
        #if DEBUG
        if let fake = Self.fakeMic { feedFake(fake) }
        #endif
    }

    /// Goes on with a finished meeting: recording again, its time running on from
    /// where it ended, the voices you know from its first part named as they speak.
    /// Ended, the whole meeting is listened through again and its notes rewritten.
    func continueMeeting(_ id: UUID) {
        guard phase == .idle, let saved = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        lastError = nil
        guard Dictation.shared.phase == .idle else {
            lastError = String(localized: "Avsluta dikteringen först.")
            return
        }
        guard VoiceModels.isInstalled else {
            lastError = String(localized: "Ladda ned Nemotron 3 först, under Inställningar → Möten.")
            return
        }
        guard saved.finished, saved.hasAudio else {
            lastError = saved.hasAudio
                ? String(localized: "Tryck Gör klart först, sedan kan du spela in mer.")
                : String(localized: "Inspelningen är borttagen, så det går inte att spela in mer i mötet.")
            return
        }
        language = saved.language
        guard language.isInstalled else {
            lastError = String(localized: "Ladda ned \(language.modelName) först, under Inställningar → Språk.")
            return
        }
        guard Recorder.micAuthorized else {
            lastError = String(localized: "Mindtalk behöver få använda mikrofonen.")
            return
        }
        let url = MeetingStore.audioURL(for: id)
        // Left from a continuation that was cut off: in its place first — and if that
        // can't be done, nothing is touched (it is someone's recording).
        do { try MeetingStore.joinContinuation(for: id) } catch {
            Self.log.error("continued: an earlier part could not be joined: \(error.localizedDescription, privacy: .public)")
            lastError = String(localized: "Inspelningen av mötet kunde inte läsas, så mötet går inte att fortsätta.")
            return
        }
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate == Double(Self.rate) else {
            lastError = String(localized: "Inspelningen av mötet kunde inte läsas, så mötet går inte att fortsätta.")
            return
        }
        // Where the new part begins: after the first, and the second of quiet put between.
        let offset = Int(file.length) + MeetingStore.continuationGap
        let more = MeetingStore.continuationURL(for: id)
        do {
            let intake = try AudioIntake(file: more, startingAt: offset)
            self.intake = intake
            try openMicrophone(into: intake)
        } catch {
            intake?.close()
            intake = nil
            try? FileManager.default.removeItem(at: more)       // made just now, empty
            lastError = error.localizedDescription
            return
        }
        MeetingPlayer.shared.stop()
        // Your notes so far stand above the note field; what you add comes after them.
        NoteDraft.shared.text = ""
        steps = 0
        before = saved
        var record = saved
        record.finished = false
        record.refined = false           // until the whole is listened through again
        record.heal = nil
        record.continuedAt = Double(offset) / Double(Self.rate)
        self.record = record
        continuing = true
        let seconds = Double(offset) / Double(Self.rate)
        let frames = offset / (Self.rate / 100)
        // The voices of this part come after every number the text already has.
        let numbers = record.words.compactMap(\.speaker) + record.names.keys.compactMap { Int($0) }
        speakerBase = (numbers.max() ?? -1) + 1
        earlier = [:]
        pausedAt = nil
        finished = nil
        pending = []
        // The voices are scored from the meeting's start: nothing for the part before.
        scores = [Float](repeating: 0, count: frames * VoiceTracker.speakers)
        steadyScores = scores
        settled = seconds
        unresolved = record.words.count
        aliases = [:]
        voiceOverlap = Self.noOverlap
        overlapFrames = frames
        failures = 0
        warning = nil
        startedAt = Date().addingTimeInterval(-seconds)
        lastSave = Date()
        lastHeard = Date()
        resetWatch(newVoicesAfter: seconds + 180)
        phase = .starting
        lastRestart = nil
        gaveUpOnSignal = false
        introductionHeld = true          // who's here is known; a new voice is named with a click
        // The new part's opening kept for recognising voices — ten minutes, not three:
        // someone from before may first speak a while in.
        intake?.keepOpening(seconds: 600)
        if !soundsReachBluetooth { Cue.start() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Recording a meeting")
        MeetingStore.shared.save(record)
        Self.log.info("meeting continued at \(Int(seconds)) s, voices from \(self.speakerBase)")
        begin()
        // The voices of the first part, as prints, to know them again.
        let words = record.words
        Task { @MainActor [weak self] in
            var prints: [Int: [Float]] = [:]
            for speaker in Set(words.compactMap(\.speaker).filter { $0 >= 0 }).sorted() {
                if let print = await VoicePrints.shared.print(of: speaker, in: words, audio: url) { prints[speaker] = print }
            }
            guard let self, self.continuing, self.record?.id == id else { return }
            self.earlier = prints
            Self.log.notice("continued: \(prints.count) voices of the first part to know again")
        }
    }

    /// A voice of the part continued that is someone from the part before: theirs —
    /// from two seconds of speech, checked again as it says more, up to forty seconds.
    private func recogniseEarlier(_ checked: inout [Int: Double]) async {
        guard continuing, !earlier.isEmpty, let record, let intake else { return }
        let words = record.words + pending
        var speech: [Int: Double] = [:]
        for w in words { if let s = w.speaker, s >= speakerBase { speech[s, default: 0] += w.end - w.start } }
        let audio = intake.openingSamples()
        let origin = Double(intake.start) / Double(Self.rate)
        for (speaker, heard) in speech where heard >= 2 && heard - (checked[speaker] ?? 0) >= 2 && heard <= 40 {
            guard let print = await VoicePrints.shared.print(of: speaker, in: words, samples: audio,
                                                             minimum: 2, origin: origin) else { continue }
            checked[speaker] = heard
            let scored = earlier.map { (speaker: $0.key, score: VoiceMemory.cosine(print, $0.value)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first, let latest = self.record else { continue }
            let lead = best.score - (scored.dropFirst().first?.score ?? -1)
            // Surer when there's little to tell apart: one voice from before to compare
            // with (the lead says nothing then), or someone from before said too little
            // for a print of their own. From under four seconds, surer still.
            let voicesBefore = Set(latest.words.compactMap(\.speaker).filter { $0 >= 0 && $0 < speakerBase })
            let thin = earlier.count < 2 || voicesBefore.count > earlier.count
            let bar: Float = heard < 4 ? 0.7 : thin ? 0.7 : VoiceMemory.sameVoice
            guard best.score >= bar, lead >= VoiceMemory.margin,
                  latest.words.contains(where: { $0.speaker == speaker }) || pending.contains(where: { $0.speaker == speaker })
            else { continue }
            // The voice from before, as it is now (you may have merged it since).
            let target = aliases[best.speaker] ?? best.speaker
            // A name you gave this voice wins over a guess — unless it's the same name.
            let given = latest.names[String(speaker)] ?? ""
            if !given.isEmpty, latest.recognized[String(speaker)] == nil,
               given.lowercased() != (latest.names[String(target)] ?? "").lowercased() { continue }
            Self.log.notice("continued: voice \(speaker) is \(target) of the first part (\(best.score, format: .fixed(precision: 2)))")
            merge(speaker, into: target)
        }
    }

    /// The microphone off, the meeting kept: what was said so far settles, and the
    /// time stands still until it goes on.
    func pause() {
        guard isRecording, !isPaused, !stopping else { return }
        _ = recorder.stop()
        // A second of quiet: the last words settle, and they don't run into the first
        // ones after the pause.
        intake?.append([Float](repeating: 0, count: Self.rate))
        pausedAt = Date()
        settledForPause = false
        LiveMeter.shared.reset()
        if warning == Self.quietWarning { warning = nil }
        // Nothing to keep the Mac awake for until it goes on.
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        AccessibilityNotification.Announcement(String(localized: "Pausat. Mikrofonen är av")).post()
        Self.log.notice("meeting paused at \(Int(self.elapsed)) s")
    }
    /// The words before the pause are written out once, then the live loop rests.
    private var settledForPause = false

    func resume() {
        guard isRecording, let pausedAt else { return }
        gaveUpOnSignal = false          // unmuted meanwhile, perhaps
        do {
            try startMicrophone()
        } catch {
            // Said where you're looking: on the meeting, not on the start card.
            warning = String(localized: "Mikrofonen kunde inte startas igen. Är den ansluten?")
            Self.log.error("resume: \(error.localizedDescription, privacy: .public)")
            return
        }
        if warning == String(localized: "Mikrofonen kunde inte startas igen. Är den ansluten?") { warning = nil }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Recording a meeting")
        AccessibilityNotification.Announcement(String(localized: "Mötet fortsätter")).post()
        // The pause doesn't count; the second of quiet does — it is in the recording.
        startedAt = startedAt?.addingTimeInterval(Date().timeIntervalSince(pausedAt) - 1)
        self.pausedAt = nil
        lastHeard = Date()
        lastSpeech = Date()             // the pause doesn't count as silence
        Self.log.notice("meeting resumed at \(Int(self.elapsed)) s")
    }

    /// The round was held (or put away) in this meeting: it isn't offered again.
    @Published private(set) var introductionHeld = false

    /// "Presentationsrunda" in a meeting already recording.
    func introduce() {
        // Not in a continued meeting: the round reads its audio from the meeting's start.
        guard isRecording, !introducing, !continuing, !isPaused else { return }
        beginIntroduction()
    }

    /// Put away without holding it.
    func skipIntroduction() { introductionHeld = true }

    // MARK: Who's here

    private func beginIntroduction() {
        Self.log.notice("round: begins at \(Int(self.elapsed)) s")
        // The voices are heard from the start of the meeting: keep that audio as long
        // as the round goes on (it is otherwise kept for the first minutes only).
        intake?.keepOpening(seconds: 300)
        introducing = true
        introChecked = []
        introFigures = [:]
        resetRound()
        roundMeeting = record?.id
        roundSpan = (elapsed, nil)
        // The guided round: one person at a time (IntroRound).
        let round = IntroRound(session: self)
        self.round = round
        round.start()
        #if DEBUG
        if let phase = CommandLine.arguments.firstIndex(of: "--demo-phase").flatMap({ $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }) {
            round.demo(phase)
        }
        #endif
    }

    /// The guided round while it runs.
    @Published private(set) var round: IntroRound?
    /// The round's turns, kept after it ends: their names are placed again, from scratch,
    /// whenever the evidence is better — the words settled, the final pass (RoundPlacement).
    private var roundTurns: [IntroRound.Capture] = []
    /// Names the round put on voices (speaker → name), while they're still there as it put
    /// them: a name you change is yours, and the round leaves that voice alone after.
    private var roundPlaced: [String: String] = [:]
    /// Names you took off (or changed) where the round had put them: not put back there.
    private var roundRefused: [String: Set<String>] = [:]
    /// Voices Mindtalk itself named in this recording by their print: its own to correct.
    private var recognisedHere: [String: String] = [:]
    /// What the log last said about each turn — each decision is logged once.
    private var roundLogged: [Int: String] = [:]
    /// Prints of the voices heard so far, from the opening audio, with the speech they
    /// were made from — made again as a voice says more (up to forty seconds).
    private var livePrints: [Int: RoundPlacement.Voice] = [:]
    /// The meeting those turns belong to — a later meeting never gets its names.
    private var roundMeeting: UUID?
    /// When the round began and ended (seconds into the meeting): a voice talking through
    /// it outside the turns is background (RoundPlacement.outsideTurns).
    private var roundSpan: (from: Double, to: Double?)?

    private func resetRound() {
        roundSpan = nil
        roundTurns = []
        roundPlaced = [:]
        roundRefused = [:]
        recognisedHere = [:]
        roundLogged = [:]
        livePrints = [:]
    }

    var openingCountForRound: Int { intake?.openingCount ?? 0 }
    func keepRoundAudio() { intake?.keepOpening(seconds: 180) }
    func roundAudio(from start: Int, to end: Int? = nil) -> [Float] {
        guard let intake else { return [] }
        return intake.opening(from: start, to: end ?? intake.openingCount)
    }

    /// The round's names onto the voices: when it ends, again as the words settle, once
    /// more when the meeting ends and on the final pass's words. Worked out anew each time
    /// (RoundPlacement.place): a name the round put on a voice that the evidence no longer
    /// supports comes off it again; a name you changed meanwhile is yours. Returns whether
    /// some turn still waits (for words to settle, or a voice to be heard).
    @discardableResult
    private func placeRound(final: (words: [MeetingWord], voices: [Int: RoundPlacement.Voice])? = nil) async -> Bool {
        guard let id = record?.id, roundMeeting == id, !roundTurns.isEmpty else { return false }
        let people = VoiceMemory.shared.known
        // The voices' prints — only needed to check names of people you know.
        let voices: [Int: RoundPlacement.Voice]
        if let final { voices = final.voices } else if people.isEmpty { voices = [:] } else {
            voices = await refreshLivePrints(words: (record?.words ?? []) + pending)
        }
        // From here on nothing waits: the record is read and written in one go.
        guard var latest = record, latest.id == id else { return false }
        let words = final?.words ?? (latest.words + pending)
        // Changed by you since the round put it there: yours, and not put back on that voice.
        for (key, name) in roundPlaced where latest.names[key] != name {
            roundPlaced[key] = nil
            roundRefused[key, default: []].insert(name)
        }
        var fixed: [Int: String] = [:]
        for (key, name) in latest.names where !name.isEmpty && roundPlaced[key] == nil {
            if let s = Int(key) { fixed[s] = name }
        }
        var refused: [Int: Set<String>] = [:]
        for (key, names) in latest.rejected { if let s = Int(key) { refused[s, default: []].formUnion(names) } }
        for (key, names) in roundRefused { if let s = Int(key) { refused[s, default: []].formUnion(names) } }
        let span = roundSpan.flatMap { s in s.to.map { s.from...$0 } }
        let decisions = RoundPlacement.place(roundTurns.map(\.turn), words: words, voices: voices, people: people,
                                             fixed: fixed, rejected: refused, round: span, final: final != nil)
        var wanted: [String: IntroRound.Capture] = [:]
        for (d, turn) in zip(decisions, roundTurns) { if case .placed(let v) = d.outcome { wanted[String(v)] = turn } }
        for (key, name) in roundPlaced where wanted[key]?.name != name {
            latest.names.removeValue(forKey: key)
            latest.recognized[key] = nil
            roundPlaced[key] = nil
        }
        for (key, turn) in wanted where latest.names[key] != turn.name {
            latest.names[key] = turn.name
            latest.recognized[key] = turn.known ? turn.score : nil
            roundPlaced[key] = turn.name
        }
        for d in decisions {
            let line = "\(d.outcome) · \(d.why)"
            guard roundLogged[d.turn] != line else { continue }
            roundLogged[d.turn] = line
            noteRound("round: turn \(d.turn)\(final != nil ? " (final pass)" : ""): \(line)")
        }
        if latest.names != record?.names || latest.recognized != record?.recognized {
            record = latest
            MeetingStore.shared.save(latest)
        }
        return decisions.contains { $0.outcome == .waiting }
    }

    /// A decision about who's who, into the log (`log show --predicate 'subsystem ==
    /// "ai.mindact.mindtalk"'`) — and printed, in a replay.
    private func noteRound(_ line: String) {
        Self.log.notice("\(line, privacy: .public)")
        #if DEBUG
        if simulation != nil { print("[\(String(format: "%.1f", elapsed)) s] \(line)") }
        #endif
    }

    /// Voices this recording's round or recognition named, and that are still as it named
    /// them: Mindtalk's own, so a sure voice match may move them. Never a name typed in
    /// the round, given by hand or from a continued meeting's part before.
    private func movableVoices(in record: MeetingRecord) -> Set<Int> {
        var out = Set<Int>()
        for (key, name) in roundPlaced where record.names[key] == name {
            if roundTurns.first(where: { $0.name == name })?.typed == true { continue }
            if let s = Int(key) { out.insert(s) }
        }
        for (key, name) in recognisedHere where record.names[key] == name && record.recognized[key] != nil {
            if let s = Int(key) { out.insert(s) }
        }
        return out
    }

    /// Prints of the voices heard so far, from the opening audio kept in memory: made from
    /// two seconds of a voice's speech, again each time it has said two seconds more, up
    /// to forty.
    private func refreshLivePrints(words: [MeetingWord]) async -> [Int: RoundPlacement.Voice] {
        guard let intake else { return livePrints }
        var speech: [Int: Double] = [:]
        for w in words { if let s = w.speaker, s >= 0 { speech[s, default: 0] += w.end - w.start } }
        let audio = intake.openingSamples()
        let origin = Double(intake.start) / Double(Self.rate)
        for (speaker, heard) in speech.sorted(by: { $0.key < $1.key }) where heard >= RoundPlacement.shortestPrint {
            if let had = livePrints[speaker], heard - had.seconds < 2 || had.seconds >= 40 { continue }
            guard let print = await VoicePrints.shared.print(of: speaker, in: words, samples: audio,
                                                             minimum: RoundPlacement.shortestPrint, origin: origin) else { continue }
            livePrints[speaker] = RoundPlacement.Voice(print: print, seconds: min(heard, 40))
        }
        return livePrints
    }

    /// The voices heard so far that you've named before, named — from two seconds of
    /// speech, each checked again as it says more, up to forty seconds. (From the
    /// meeting's opening minutes, which are kept in memory; later voices are recognised
    /// when the meeting is written out.)
    private func recogniseIntroduced(_ checked: inout [Int: Double]) async {
        // Not before the voice model is ready: a check then would call every voice new.
        guard let record, VoiceMemory.shared.isOn, VoiceMemory.shared.state == .ready,
              !VoiceMemory.shared.people.isEmpty else { return }
        // The words still being written count too: their speaker is known before they settle.
        let words = record.words + pending
        var speech: [Int: Double] = [:]
        for w in words { if let s = w.speaker, s >= 0 { speech[s, default: 0] += w.end - w.start } }
        let named = Set(record.names.compactMap { $0.value.isEmpty ? nil : $0.key })
        let due = speech.filter { !named.contains(String($0.key)) && $0.value >= 2 && $0.value - (checked[$0.key] ?? 0) >= 2 && $0.value <= 40 }
        guard !due.isEmpty else { return }
        // Every voice's print, as far as it has been heard: the one to check, and those
        // holding a name Mindtalk gave that a sure match might move.
        let prints = await refreshLivePrints(words: words)
        for (speaker, heard) in due.sorted(by: { $0.key < $1.key }) {
            guard let voice = prints[speaker] else { continue }
            checked[speaker] = heard
            defer { introChecked.insert(speaker) }
            guard var latest = self.record, (latest.names[String(speaker)] ?? "").isEmpty else { continue }
            VoiceMemory.shared.logBest(voice.print, speaker: speaker, heard: heard)
            // Continued: a name from the first part isn't taken by someone else — a voice
            // now that is that person is them (merged below), not the next best match.
            var names: [Int: String] = [:], earlier: [Int: String] = [:]
            for (key, name) in latest.names where !name.isEmpty {
                guard let s = Int(key) else { continue }
                if continuing, s < speakerBase { earlier[s] = name } else { names[s] = name }
            }
            let movable = movableVoices(in: latest)
            let (found, notes) = RoundPlacement.recognise(
                unnamed: [speaker: voice], holders: prints.filter { movable.contains($0.key) }, names: names,
                movable: movable, people: VoiceMemory.shared.known,
                rejected: [speaker: Set(latest.rejected[String(speaker)] ?? [])], earlier: earlier)
            for note in notes { noteRound("voices: \(note)") }
            switch found.first {
            case .merge(_, let earlierSpeaker, let score):
                noteRound("continued: voice \(speaker) is \(earlierSpeaker) of the first part, by the voice you named (\(RoundPlacement.fmt(score)))")
                merge(speaker, into: aliases[earlierSpeaker] ?? earlierSpeaker)
            case .name(_, let name, let score):
                latest.names[String(speaker)] = name
                latest.recognized[String(speaker)] = score
                recognisedHere[String(speaker)] = name
                self.record = latest
                MeetingStore.shared.save(latest)
                noteRound("voices: speaker \(speaker) recognised after \(RoundPlacement.fmt(heard)) s of speech (\(RoundPlacement.fmt(score)))")
            case .move(let name, let from, _, let score, let holder):
                moveName(name, from: from, to: speaker, score: score, in: &latest)
                self.record = latest
                MeetingStore.shared.save(latest)
                noteRound("voices: a name moved from voice \(from) (clearly not them, \(RoundPlacement.fmt(holder))) to voice \(speaker) (\(RoundPlacement.fmt(score)) after \(RoundPlacement.fmt(heard)) s)")
            case nil:
                // A new voice: its figure, once, unlike the others in the room.
                if introFigures[speaker] == nil {
                    introFigures[speaker] = VoiceMemory.shared.figureForNew(voice.print, alsoAvoiding: Set(introFigures.values.map(\.rhythm)))
                }
            }
        }
    }

    /// A name off a voice that clearly isn't that person ("Talare N" again), onto the one
    /// that surely is — marked as recognised, so it's shown as Mindtalk's guess.
    private func moveName(_ name: String, from: Int, to: Int, score: Float, in record: inout MeetingRecord) {
        RoundPlacement.move(name, from: from, to: to, score: score, in: &record)
        roundPlaced[String(from)] = nil
        recognisedHere[String(from)] = nil
        recognisedHere[String(to)] = name
    }

    /// "Alla är här": on with the meeting.
    func endIntroduction() {
        guard introducing else { return }
        Self.log.notice("round: ends at \(Int(self.elapsed)) s, words \(self.record?.words.count ?? 0) + \(self.pending.count)")
        introducing = false
        introductionHeld = true
        if let round {
            round.stop()
            #if DEBUG
            replayTurns = round.captures
            #endif
            roundTurns = round.captures
            if let span = roundSpan { roundSpan = (span.from, max(span.from, elapsed)) }
            // Who's here is known now: a voice heard first after this is someone new.
            if !round.captures.isEmpty {
                newVoicesAfter = elapsed
                namesGiven = true
            }
            if round.captures.count > VoiceTracker.speakers, !manyVoicesNoted { noteManyVoices() }
            self.round = nil
            // The names onto the voices now — and, while some turn waits for its words to
            // settle (or for a voice to be heard), again every three seconds for a while.
            let meeting = record?.id
            Task { @MainActor [weak self] in
                guard let self, await self.placeRound() else { return }
                for _ in 0..<20 {
                    try? await Task.sleep(for: .seconds(3))
                    guard self.isRecording, self.record?.id == meeting, await self.placeRound() else { return }
                }
            }
        }
    }

    /// Ending, from a button or the shortcut: a few seconds to undo, and the
    /// recording goes on meanwhile, so nothing said is lost either way. Asked again
    /// while it counts down, it ends at once. Returns whether it ended now.
    @discardableResult
    func requestStop() -> Bool {
        guard isRecording else { return false }
        if stopping {
            stop()
            return true
        }
        stopAt = Date().addingTimeInterval(Self.undoSeconds)
        // Said aloud too: there are a few seconds to change your mind.
        AccessibilityNotification.Announcement(String(localized: "Mötet avslutas om \(Int(Self.undoSeconds)) sekunder. Du kan ångra.")).post()
        stopCountdown?.cancel()
        stopCountdown = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, let self, self.stopping else { return }
            self.stop()
        }
        return false
    }

    /// "Ångra": the meeting goes on as if nothing happened.
    func cancelStop() {
        stopCountdown?.cancel()
        stopCountdown = nil
        stopAt = nil
    }

    func stop() {
        guard isRecording else { return }
        takeDraft()
        applyNotes()
        endIntroduction()
        stopCountdown?.cancel()
        stopCountdown = nil
        stopAt = nil
        phase = .finishing(String(localized: "Skriver klart…"))
        pausedAt = nil
        // Ended while paused: awake again for the final pass.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Mindtalk lyssnar igenom ett möte")
        }
        _ = recorder.stop()
        let loop = self.loop
        Task {
            await loop?.value
            await finish()
        }
    }

    // MARK: Editing while it runs

    /// An answer about this meeting, asked before it was continued.
    func addAnswer(_ answer: MeetingAnswer) {
        guard var record else { return }
        record.answers.append(answer)
        self.record = record
        MeetingStore.shared.save(record)
    }

    /// Into a folder (or out of it) while it's being recorded.
    func setFolder(_ folder: UUID?) {
        guard var record, record.folder != folder else { return }
        record.folder = folder
        record.folderAsked = true
        self.record = record
        MeetingStore.shared.save(record)
    }

    func rename(to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        record?.title = title
        record?.userTitled = true        // the notes written after don't give it another
        if let record { MeetingStore.shared.save(record) }
    }

    /// The figure a voice of the introduction round is shown with: from its print once
    /// Mindtalk has one, otherwise from its number.
    func introFigure(of speaker: Int) -> VoiceFigure {
        introFigures[speaker] ?? VoiceFigure.from(seed: "\(record?.id.uuidString ?? "")-\(speaker)")
    }

    func name(speaker: Int, as name: String) {
        // A new voice named in the round keeps the figure it was shown with.
        if introducing, let figure = introFigures[speaker] { VoiceMemory.shared.reserve(figure, for: name) }
        guard var latest = record else { return }
        let (old, guessed) = latest.setName(name.trimmingCharacters(in: .whitespacesAndNewlines), for: speaker)
        if let old, !guessed { VoiceMemory.shared.corrected(from: old, to: name, meeting: latest.id.uuidString) }
        // An unusual name ("Klang") is worth suggesting for the word list.
        if old == nil || guessed { Vocabulary.shared.suggest(name, from: latest.title) }
        record = latest
        MeetingStore.shared.save(latest)
        // Named by hand: the moment to ask which of them is you (once, ever).
        if !name.trimmingCharacters(in: .whitespaces).isEmpty, !introducing { namesGiven = true }
    }

    /// Two voices that are one person — from now on too.
    func merge(_ speaker: Int, into other: Int) {
        guard var record else { return }
        MeetingRecord.merge(speaker, into: other, in: &record)
        for (from, to) in aliases where to == speaker { aliases[from] = other }
        aliases[speaker] = other
        // A voice from before merged away: its print speaks for the one it became.
        if let print = earlier.removeValue(forKey: speaker), earlier[other] == nil { earlier[other] = print }
        for j in pending.indices where pending[j].speaker == speaker { pending[j].speaker = other }
        self.record = record
        MeetingStore.shared.save(record)
    }

    func move(words range: Range<Int>, to speaker: Int) {
        guard var record else { return }
        record.move(words: range, to: speaker)
        self.record = record
        MeetingStore.shared.save(record)
    }

    /// Where the recording is now, in seconds — the time notes and marks are given.
    var elapsed: Double { Double(intake?.count ?? 0) / Double(Self.rate) }

    /// Your notes as typed: new lines get the moment they were begun. Saved a moment
    /// after you stop typing, not at every key.
    func setNotes(_ text: String) {
        // Typed: taken in once you pause — the page isn't redrawn for every key.
        notesDraft = text
        notesApply?.cancel()
        notesApply = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.applyNotes()
        }
    }
    private var notesDraft: String?
    private var notesApply: Task<Void, Never>?

    private func applyNotes() {
        notesApply?.cancel()
        guard let text = notesDraft, var record else { return }
        notesDraft = nil
        let notes = MeetingRecord.notes(from: text, old: record.notes, now: isRecording ? elapsed : nil)
        guard notes != record.notes else { return }
        record.notes = notes
        self.record = record
        notesSave?.cancel()
        notesSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let record = self?.record else { return }
            MeetingStore.shared.saveQuietly(record)
        }
    }
    private var notesSave: Task<Void, Never>?

    /// A note added with ↩: a line of the meeting's notes (a line each, if you wrote
    /// several), at the moment you began writing it. Returns whether one was added.
    @discardableResult
    func addNote(_ text: String, at begun: Double? = nil) -> Bool {
        applyNotes()          // an edit still on its way lands first
        guard var record else { return false }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let at = isRecording ? min(begun ?? elapsed, elapsed) : nil
        // Blank lines at the end of the notes carry nothing.
        while let last = record.notes.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty { record.notes.removeLast() }
        record.notes += lines.map { MeetingRecord.Note(text: $0, at: at) }
        self.record = record
        MeetingStore.shared.save(record)
        return true
    }

    #if DEBUG
    /// `--render-island`: notes and marks as if added, on the demo meeting; nothing saved.
    func preview(notes: [MeetingRecord.Note], marks: [MeetingRecord.Mark]? = nil) {
        record?.notes = notes
        if let marks { record?.marks = marks }
    }
    #endif

    /// Written but not added when the meeting ends: a note all the same, not lost.
    private func takeDraft() {
        guard isRecording, let draft = NoteDraft.shared.take() else { return }
        addNote(draft.text, at: draft.at)
    }

    /// A moment worth finding again — when you pressed. Whether that was just before
    /// or just after it was said, the notes look at the seconds around it. Pressed
    /// with something written, that is the mark's words, and its moment is when you
    /// began writing them.
    @discardableResult
    func mark(_ kind: MeetingRecord.Mark.Kind, text: String? = nil, at begun: Double? = nil) -> MeetingRecord.Mark? {
        guard var record, isRecording else { return nil }
        let words = (text ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let at = words.isEmpty ? elapsed : min(begun ?? elapsed, elapsed)
        let mark = MeetingRecord.Mark(at: at, kind: kind, text: words.isEmpty ? nil : words)
        record.marks.append(mark)
        self.record = record
        MeetingStore.shared.save(record)
        return mark
    }

    func removeMark(_ id: UUID) {
        guard var record else { return }
        record.marks.removeAll { $0.id == id }
        self.record = record
        MeetingStore.shared.save(record)
    }

    /// Mindtalk is quitting mid-meeting: keep what has been written. It opens as
    /// an unfinished meeting next time, ready to be finished.
    func saveBeforeQuit() {
        takeDraft()           // written, not yet added
        applyNotes()          // what you typed in the last moment
        guard var record, isBusy else { return }
        record.words += pending
        // (Listening again to a finished meeting there's no intake: its length stands.)
        if let intake { record.duration = Double(intake.count) / Double(Self.rate) }
        intake?.close()
        MeetingStore.shared.save(record)
    }

    // MARK: The live loop

    private func run() async {
        // Each on its own: the voices are told apart also if the speech model won't load,
        // and the text is written also if the voices won't.
        var speechFailed = false
        do { try await SpeechEngine.shared.load(language) } catch {
            Self.log.error("meeting speech model: \(error.localizedDescription, privacy: .public)")
            speechFailed = true
        }
        do {
            tracker = try await VoiceTracker.make(VoiceModels.live)
            steady = try? await VoiceTracker.make(VoiceModels.final)
        } catch {
            Self.log.error("meeting voice model: \(error.localizedDescription, privacy: .public)")
            if !speechFailed {
                warning = String(localized: "Nemotron 3 kunde inte startas, så texten skrivs utan att visa vem som pratar.")
            }
        }
        if speechFailed {
            warning = String(localized: "\(language.modelName) kunde inte startas, så ingen text skrivs just nu. Inspelningen fortsätter.")
        }
        // No words will come: silence is then told by the sound level instead.
        speechDown = speechFailed
        if phase == .starting { phase = .recording }
        while !Task.isCancelled, phase == .recording {
            // Paused: what was said before it is written out once (the second of quiet
            // settles it); then nothing new comes until it goes on.
            if isPaused {
                if !settledForPause {
                    settledForPause = true
                    await settleAll()
                }
                checkInput()
                watch()
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }
            let t0 = Date()
            await step(final: false)
            steps += 1
            lastStep = Date()
            lastStepTook = lastStep.timeIntervalSince(t0)
            if lastStepTook > 3 { Self.log.notice("live: slow step \(Int(self.lastStepTook * 1000)) ms") }
            if Date().timeIntervalSince(lastSave) > 20, var record {
                lastSave = Date()
                record.duration = Double(intake?.count ?? 0) / Double(Self.rate)
                MeetingStore.shared.saveQuietly(record)
            }
            checkInput()
            watch()
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    // MARK: Watching the room: silence, new voices, many voices, who you are

    /// No one has said anything for ten minutes: "Är mötet slut?" — and with no answer
    /// and still nothing said for thirty more, it ends by itself, saved as any other.
    @Published private(set) var silenceAsked = false
    static let silenceAsk: TimeInterval = 10 * 60
    static let silenceEnd: TimeInterval = 30 * 60
    /// When words last came (written, or still being written).
    private var lastSpeech = Date()
    private var wordsHeard = 0
    /// The speech model didn't start: no words come, so the sound level tells instead.
    private var speechDown = false

    /// A voice first heard after the round (or the first minutes): "Ny röst. Vem är det?"
    @Published private(set) var latecomer: Int?
    private var latecomersSeen: Set<Int> = []
    /// The meeting's second after which a voice heard for the first time is someone new.
    private var newVoicesAfter: Double = 180
    /// More voices than Mindtalk can keep apart well: said once, quietly.
    @Published private(set) var manyVoices = false
    private var manyVoicesNoted = false
    /// "Vem av er är du?" — once, the first time names are given.
    @Published private(set) var askingWhoYouAre = false
    private var namesGiven = false
    /// Every few passes of the loop is enough for the voices.
    private var watchTick = 0

    private func resetWatch(newVoicesAfter seconds: Double) {
        lastSpeech = Date()
        wordsHeard = 0
        speechDown = false
        silenceAsked = false
        latecomer = nil
        latecomersSeen = []
        newVoicesAfter = seconds
        manyVoices = false
        manyVoicesNoted = false
        askingWhoYouAre = false
        namesGiven = false
        watchTick = 0
    }

    /// Twice a second from the live loop.
    private func watch() {
        guard phase == .recording, !stopping else { return }
        checkSilence()
        watchTick += 1
        if watchTick % 4 == 0 { checkVoices() }
    }

    private func checkSilence() {
        // Paused, or the round going on: neither counts as silence.
        if isPaused || introducing {
            lastSpeech = Date()
            if silenceAsked { silenceAsked = false }
            return
        }
        let words = (record?.words.count ?? 0) + pending.count
        if words != wordsHeard { wordsHeard = words; lastSpeech = Date() }
        let since = speechDown ? max(lastHeard, lastSpeech) : lastSpeech
        let quiet = Date().timeIntervalSince(since)
        if quiet >= Self.silenceAsk + Self.silenceEnd {
            Self.log.notice("meeting: nothing said for \(Int(quiet / 60)) min, ended by itself")
            silenceAsked = false
            stop()
            return
        }
        let ask = quiet >= Self.silenceAsk
        guard ask != silenceAsked else { return }
        silenceAsked = ask
        if ask {
            Self.log.notice("meeting: nothing said for ten minutes, asked whether it is over")
            AccessibilityNotification.Announcement(String(localized: "Ingen har sagt något på tio minuter. Är mötet slut?")).post()
        }
    }

    /// "Fortsätt" on the question: it goes on, and is asked again after ten more quiet minutes.
    func keepGoing() {
        lastSpeech = Date()
        silenceAsked = false
    }

    private func checkVoices() {
        guard let record else { return }
        var first: [Int: Double] = [:]
        var speech: [Int: Double] = [:]
        for w in record.words + pending {
            guard let s = w.speaker, s >= 0 else { continue }
            if first[s] == nil { first[s] = w.start }
            speech[s, default: 0] += w.end - w.start
        }
        if !manyVoicesNoted, first.count >= VoiceTracker.speakers { noteManyVoices() }
        if namesGiven, !askingWhoYouAre, !Self.whoAmIAsked, !VoiceMemory.namesToRemember(in: record).isEmpty {
            askingWhoYouAre = true
        }
        guard !introducing else { return }
        // Named meanwhile (by you, or recognised), or merged into someone: the chip goes.
        if let late = latecomer, !(record.names[String(late)] ?? "").isEmpty || first[late] == nil { latecomer = nil }
        guard latecomer == nil else { return }
        for (s, at) in first.sorted(by: { $0.value < $1.value })
        where at >= newVoicesAfter && !latecomersSeen.contains(s) && (record.names[String(s)] ?? "").isEmpty
            && (speech[s] ?? 0) >= 4 {
            latecomersSeen.insert(s)
            latecomer = s
            Self.log.notice("voices: a new voice (\(s)) first heard at \(Int(at)) s, after the room was known")
            break
        }
    }

    /// "Ny röst" put away without naming it.
    func dismissLatecomer() { latecomer = nil }

    private func noteManyVoices() {
        manyVoicesNoted = true
        manyVoices = true
        Self.log.notice("voices: eight or more, names may be less sure")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.manyVoices = false
        }
    }

    func dismissManyVoices() { manyVoices = false }

    /// Answered once, ever: "Vem av er är du?"
    static var whoAmIAsked: Bool { UserDefaults.standard.bool(forKey: "whoAmIAsked") }

    /// "Det är jag": your name in this meeting; with the voices remembered, in the
    /// meetings after it too (Settings → Möten can change it). nil: none of them.
    func iAm(_ name: String?) {
        Settings.keep(true, forKey: "whoAmIAsked")
        askingWhoYouAre = false
        guard let name, var record else { return }
        record.me = name
        self.record = record
        MeetingStore.shared.save(record)
        if VoiceMemory.shared.enabled { Settings.myName = name }
        Self.log.notice("voices: you are one of the named speakers")
    }

    #if DEBUG
    /// Renders (`--meeting-state …`): the meeting view, or the start card, as it looks
    /// in that moment. Nothing is recorded or saved.
    func preview(state: String) {
        switch state {
        case "voiceconsent":
            voiceQuestion = PendingStart(mode: .round, folder: nil)
            return
        default: break
        }
        showDemo(finished: false)
        // Two notes of your own, so the margin has something in its list.
        record?.notes = [MeetingRecord.Note(text: "Rekorddag för nedladdningar", at: 9),
                         MeetingRecord.Note(text: "Norge och Danmark växer, fråga supporten om engelskan", at: 25)]
        switch state {
        case "silence": silenceAsked = true
        case "latecomer": latecomer = 2
        case "manyvoices": manyVoices = true
        case "whoareyou": askingWhoYouAre = true
        case "paused": pausedAt = Date()
        case "scrolled": Self.previewScrolledUp = true
        case "ended":
            // The meeting ends a moment after the page is up: the finished meeting as
            // it shows right after, in memory only (nothing is written).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                guard var done = record else { return }
                done.refined = true
                done.duration = 754
                MeetingStore.shared.replaceAll([done] + MeetingStore.shared.meetings)
                pending = []
                record = nil
                startedAt = nil
                phase = .idle
                finished = done.id
            }
        default: break
        }
    }

    /// `--meeting-state scrolled`: the text read back to its start, "Till det senaste" showing.
    static var previewScrolledUp = false
    #endif

    // MARK: How the live text keeps up (in the log macOS keeps)

    private var heartbeat: Task<Void, Never>?
    private var steps = 0
    private var lastStep = Date()
    private var lastStepTook = 0.0

    /// Every five seconds while recording: how far the live text has come. A meeting
    /// whose text stops shows here where and when — not only that it did.
    private func beat() async {
        while !Task.isCancelled, isRecording || phase == .starting {
            try? await Task.sleep(for: .seconds(5))
            guard isRecording else { continue }
            let behind = elapsed - settled
            Self.log.notice("live: \(Int(self.elapsed)) s · words \(self.record?.words.count ?? 0) + \(self.pending.count) · settled \(self.settled, format: .fixed(precision: 1)) s · behind \(behind, format: .fixed(precision: 1)) s · steps \(self.steps) · last step \(Int(self.lastStepTook * 1000)) ms, \(Int(Date().timeIntervalSince(self.lastStep))) s ago · round \(self.introducing) · audio \(Double(self.intake?.count ?? 0) / Double(Self.rate), format: .fixed(precision: 1)) s · waiting at \(self.pending.map { String(format: "%.1f–%.1f", $0.start, $0.end) }.joined(separator: " "), privacy: .public)")
        }
    }

    private static var noText: String {
        String(localized: "Texten kan inte skrivas just nu. Ljudet spelas in och skrivs ned efter mötet.")
    }

    /// Nothing heard for three quarters of a minute: a pause in the talk is longer than
    /// one would think, so not sooner — and said softly.
    private static var quietWarning: String { String(localized: "Jag hör inget just nu. Är rätt mikrofon vald?") }

    /// Says so when the recording can't be trusted.
    private func checkInput() {
        if intake?.writeFailed == true {
            warning = String(localized: "Inspelningen kan inte sparas. Är disken full? Texten skrivs ändå.")
        } else if !isPaused, Date().timeIntervalSince(lastHeard) > 45 {
            warning = Self.quietWarning
        } else if warning == Self.quietWarning {
            warning = nil
        }
    }

    /// Everything heard so far written out. One step reads at most 14 s, so when the
    /// live text is further behind (a busy Mac), it steps on until the rest fits in one
    /// window, then settles that. Stops if a step makes no headway.
    private func settleAll() async {
        let reach = 14 - Self.lead          // a window starts `lead` before `settled`
        for _ in 0..<600 {                  // 600 steps of ~12 s: two hours behind
            guard let intake else { return }
            let behind = Double(intake.count) / Double(Self.rate) - settled
            guard behind > reach else { break }
            let before = settled
            await step(final: false)
            if settled <= before { break }
        }
        await step(final: true)
    }

    /// Scores the new audio for voices, then writes out what hasn't settled.
    private func step(final: Bool) async {
        guard let intake else { return }
        let newAudio = intake.takeForVoices()
        if let steady, !newAudio.isEmpty, let more = try? await steady.feed(newAudio) { steadyScores += more }
        if let tracker, !newAudio.isEmpty {
            do { scores += try await tracker.feed(newAudio) } catch {
                Self.log.error("voices: \(error.localizedDescription, privacy: .public)")
            }
        }

        // (Continued: the intake begins where the new part does.)
        let from = max(intake.start, Int((settled - Self.lead) * Double(Self.rate)))
        var window = intake.samples(from: from, to: intake.count)
        let longest = 14 * Self.rate
        if window.count > longest { window = Array(window.prefix(longest)) }
        let windowEnd = Double(from + window.count) / Double(Self.rate)
        let fresh = windowEnd - settled
        guard fresh >= 0.5 || (final && fresh > 0) else {
            #if DEBUG
            if CommandLine.arguments.contains("--trace-live") { print(String(format: "[steg] inget nytt: fönster till %.1f, avklarat %.1f, ljud %.1f", windowEnd, settled, Double(intake.count) / Double(Self.rate))) }
            #endif
            return resolveSpeakers(final: false)
        }

        let timed: [WordTiming]
        do {
            timed = try await SpeechEngine.shared.transcribeTimed(samples: window, with: language)
            if failures > 0 {
                failures = 0
                if warning == Self.noText { warning = nil }
            }
        } catch {
            Self.log.error("words: \(error.localizedDescription, privacy: .public)")
            failures += 1
            if failures >= 5 {
                warning = Self.noText
                // Don't let unwritten audio pile up: the final pass reads it from the file.
                if fresh > 11 {
                    setPending([])
                    settle(upTo: windowEnd - 0.5)
                }
            }
            return
        }
        let base = Double(from) / Double(Self.rate)
        // Only what comes after the settled words: the context was written down already.
        var heard = timed.map { MeetingWord(text: $0.word, start: base + $0.startTime, end: base + $0.endTime) }
            .filter { ($0.start + $0.end) / 2 > settled }
        // Read again with more context, the last settled word can land a little later:
        // it's the same word, not a new one.
        // Only when it really is the same stretch of sound: a "nej, nej" is two words.
        if let first = heard.first, let last = record?.words.last, Self.again(first, after: last) {
            heard.removeFirst()
        }

        guard !heard.isEmpty else {
            // Silence: nothing to wait for.
            setPending([])
            if final { settle(upTo: windowEnd) } else if fresh > 3 { settle(upTo: windowEnd - 0.5) }
            return resolveSpeakers(final: false)
        }

        var cut: Int?
        if final {
            cut = heard.count - 1
        } else {
            // The last word followed by a pause, with a second of audio after it.
            let edge = windowEnd - 1.0
            for i in heard.indices where heard[i].end <= edge {
                let next = i + 1 < heard.count ? heard[i + 1].start : windowEnd
                if next - heard[i].end >= 0.35 { cut = i }
            }
            // Someone talking without a break: settle all but the last few seconds —
            // at the longest gap there is, so the seam doesn't land inside a word.
            if cut == nil, fresh > 6 {
                var widest = -1.0
                for i in heard.indices where heard[i].end <= windowEnd - 2.5 && heard[i].end >= windowEnd - 5
                    && i + 1 < heard.count {
                    let gap = heard[i + 1].start - heard[i].end
                    if gap >= widest { widest = gap; cut = i }
                }
                if cut == nil { cut = heard.lastIndex { $0.end <= windowEnd - 2.5 } }
            }
        }
        // The window is as long as it gets and nothing in it can settle — the speech
        // model heard words only at its very end. What came before them had no words:
        // settled up to them, so the window moves on instead of reading the same
        // fourteen seconds again and again (the text would stop for good).
        if cut == nil, !final, window.count >= longest {
            if let first = heard.first, first.start - 0.3 > settled + 0.5 {
                settle(upTo: first.start - 0.3)
                Self.log.notice("live: moved past \(fresh, format: .fixed(precision: 1)) s with words only at the end")
            } else {
                cut = heard.lastIndex { $0.end <= windowEnd - 0.5 } ?? (heard.count - 1)
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--trace-live") {
            print(String(format: "[steg] fönster %.1f–%.1f · nytt %.1f · hört %@ · skär %@", base, windowEnd, fresh,
                         heard.map { String(format: "%@ %.1f–%.1f", $0.text, $0.start, $0.end) }.joined(separator: ", "),
                         cut.map(String.init) ?? "•"))
        }
        #endif
        if let cut {
            #if DEBUG
            report(settled: heard[...cut])
            #endif
            record?.words += heard[...cut]
            let next = cut + 1 < heard.count ? heard[cut + 1].start : windowEnd
            settle(upTo: (heard[cut].end + min(next, heard[cut].end + 0.4)) / 2)
            setPending(Array(heard[(cut + 1)...]))
        } else {
            setPending(heard)
        }
        resolveSpeakers(final: false)
    }

    /// A voice as the tracker numbers it, as it is in the text: after the voices of
    /// the part before (continued), and as you merged it.
    private func own(_ raw: Int) -> Int {
        let s = raw + speakerBase
        return aliases[s] ?? s
    }

    /// Keeps whoever is speaking in the words still being written until the voices
    /// say otherwise, and only publishes a change.
    /// The words still being written (resolveSpeakers gives them their speakers next).
    private func setPending(_ words: [MeetingWord]) {
        if words != pending { pending = words }
    }

    private func settle(upTo seconds: Double) {
        settled = max(settled, seconds)
        intake?.drop(before: Int((settled - Self.lead) * Double(Self.rate)))
    }

    /// Gives settled words their speaker once the voices have caught up with them;
    /// words still being written get a provisional one.
    private func resolveSpeakers(final: Bool) {
        guard var words = record?.words else { return }
        let before = words
        // Confirmed: sentences the steady voices cover get their speaker for good.
        let confirmed = steady == nil ? scores : steadyScores
        let from = unresolved
        unresolved = Self.assignSentences(&words, from: from, scores: confirmed, final: final)
        for i in from..<unresolved { if let s = words[i].speaker, s >= 0 { words[i].speaker = own(s) } }
        // Not yet: the quick voices' guess, in the steady ones' numbering.
        let map = steady == nil ? [:] : quickToSteady()
        if unresolved < words.count {
            var rest = Array(words[unresolved...])
            _ = Self.assignSentences(&rest, from: 0, scores: scores, final: true)
            for k in rest.indices {
                guard let s = rest[k].speaker, s >= 0 else { continue }
                rest[k].speaker = own(map[s] ?? s)
            }
            words.replaceSubrange(unresolved..., with: rest)
        }
        // What you moved stays moved, whatever the voices say.
        MeetingRecord.apply(record?.moves ?? [], to: &words, from: from)
        // The page redraws on every change: only say so when there is one.
        if words != before { record?.words = words }
        // Still being written: whoever the voices hear in each part of them. Beyond
        // what they've heard so far (they lag a few seconds), a word goes on with the
        // speaker before it when there's no real pause — after one, it waits ("Känner
        // igen rösten…") rather than showing up under the wrong name.
        if !pending.isEmpty {
            var labelled = pending
            _ = Self.assignSentences(&labelled, from: 0, scores: scores, final: true)
            var before = words.last
            for j in labelled.indices {
                if let s = labelled[j].speaker, s >= 0 {
                    labelled[j].speaker = own(map[s] ?? s)
                } else if let b = before, let bs = b.speaker, bs >= 0, labelled[j].start - b.end < 1.0 {
                    labelled[j].speaker = bs
                } else {
                    labelled[j].speaker = nil
                }
                before = labelled[j]
            }
            if labelled != pending { pending = labelled }
        }
    }

    /// Which steady speaker each quick one is, from everything they have both heard:
    /// someone quiet for a few minutes is still themselves when they speak again.
    private func quickToSteady() -> [Int: Int] {
        let frames = min(scores.count, steadyScores.count) / VoiceTracker.speakers
        guard frames > 100 else { return [:] }
        Self.count(&voiceOverlap, of: scores, with: steadyScores, frames: overlapFrames..<frames)
        overlapFrames = frames
        return Self.mapping(voiceOverlap)
    }

    /// Gives each finished sentence from `start` on the speaker who spoke most during
    /// it, once the voices cover it. Returns the first word still waiting.
    nonisolated static func assignSentences(_ words: inout [MeetingWord], from start: Int, scores: [Float],
                                            final: Bool) -> Int {
        let frames = scores.count / VoiceTracker.speakers
        var i = start
        while i < words.count {
            guard let j = sentenceEnd(words, from: i, final: final),
                  final || Int(words[j].end * 100) < frames else { break }
            // Usually one voice per sentence. But when someone takes over without a
            // pause or a full stop, split where the voice clearly changes: three words
            // or more in a row by someone else.
            let perWord = (i...j).map { speaker(in: scores, from: words[$0].start, to: words[$0].end) }
            var runs: [(from: Int, to: Int, speaker: Int)] = []
            for (n, s) in perWord.enumerated() {
                if let last = runs.last, last.speaker == s || s == MeetingWord.unknown {
                    runs[runs.count - 1].to = i + n
                } else {
                    runs.append((i + n, i + n, s))
                }
            }
            runs = runs.reduce(into: []) { merged, run in
                if let last = merged.last, run.to - run.from < 2 || last.to - last.from < 2 && merged.count == 1 && last.speaker == MeetingWord.unknown {
                    merged[merged.count - 1].to = run.to
                } else {
                    merged.append(run)
                }
            }
            if runs.count <= 1 {
                let s = speaker(in: scores, from: words[i].start, to: words[j].end)
                for k in i...j { words[k].speaker = s }
            } else {
                for run in runs {
                    let s = speaker(in: scores, from: words[run.from].start, to: words[run.to].end)
                    for k in run.from...run.to { words[k].speaker = s }
                }
            }
            i = j + 1
        }
        return i
    }

    /// The last word of the sentence starting at `i`, or nil if it isn't over yet.
    nonisolated static func sentenceEnd(_ words: [MeetingWord], from i: Int, final: Bool) -> Int? {
        var k = i
        while k < words.count {
            if let c = words[k].text.last, ".?!".contains(c) { return k }
            if k + 1 < words.count, words[k + 1].start - words[k].end >= 0.5 { return k }
            if k - i >= 40 { return k }            // a very long run: don't wait forever
            if k + 1 == words.count { return final ? k : nil }
            k += 1
        }
        return nil
    }

    // MARK: The end

    private func finish() async {
        intake?.close()
        // The last words are written also when the voices never started — all of them,
        // also when the live text was far behind.
        await settleAll()
        if let rest = try? await tracker?.finish() { scores += rest }
        if let rest = try? await steady?.finish() { steadyScores += rest }
        resolveSpeakers(final: true)
        // The round's names once more, now that every word is in.
        await placeRound()
        guard var record else { return done() }
        record.words += pending
        pending = []
        record.duration = Double(intake?.count ?? 0) / Double(Self.rate)
        // A slip of the finger: nothing said, a few seconds long — not worth keeping.
        if !continuing, record.words.isEmpty, record.duration < 10, record.notes.isEmpty, record.marks.isEmpty {
            MeetingStore.shared.delete(record.id)
            self.record = nil
            // Said on the start card, so it doesn't look as if the meeting went missing.
            lastError = String(localized: "Mötet var för kort för att sparas.")
            return done()
        }
        self.record = record
        MeetingStore.shared.save(record)
        Self.log.info("meeting recorded: \(Int(record.duration)) s, \(record.words.count) words")
        #if DEBUG
        if simulation != nil { print("\n=== Live (\(record.speakers.count) talare) ===\n" + MeetingText.plain(record)) }
        #endif
        // Continued by a slip of the finger — nothing said, nothing noted, a few
        // seconds: the meeting goes back to how it was.
        if continuing, let before, record.words.count == before.words.count, record.notes == before.notes,
           record.marks == before.marks, record.duration - (record.continuedAt ?? 0) < 10 {
            try? FileManager.default.removeItem(at: MeetingStore.continuationURL(for: record.id))
            var restored = before
            restored.title = record.title
            restored.userTitled = record.userTitled
            restored.names = record.names
            restored.recognized = record.recognized
            restored.rejected = record.rejected
            restored.folder = record.folder
            restored.folderAsked = record.folderAsked
            restored.answers = record.answers
            self.record = restored
            continuing = false
            Self.log.info("continued: nothing recorded — the meeting is as it was")
            return done()
        }
        // Continued: the new part after the first — one recording to listen through.
        // If that fails, the text written live stays (a pass over the first part
        // alone would lose the rest), and the meeting waits, unfinished, for "Gör klart".
        if continuing, !(await Self.join(record.id)) {
            keepUnfinished = true
            return done()
        }
        await refine()
        done()
    }

    /// A continued meeting's two recordings made one, off the main thread.
    private static func join(_ id: UUID) async -> Bool {
        do {
            try await Task.detached(priority: .userInitiated) { try MeetingStore.joinContinuation(for: id) }.value
            return true
        } catch {
            log.error("continued: joining the recordings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Reads the whole recording once more: seamless words, voices with more context.
    private func refine() async {
        guard let id = record?.id, (record?.duration ?? 0) > 2 else { return }
        // The recording is shorter than the meeting (the disk filled, a write failed):
        // a pass over it would replace the whole live text with part of it. Keep the text.
        let length = (try? AVAudioFile(forReading: MeetingStore.audioURL(for: id))).map { Double($0.length) / Double(Self.rate) } ?? 0
        if intake?.writeFailed == true || length < (record?.duration ?? 0) - 2 {
            Self.log.error("final pass skipped: the recording has \(Int(length)) of \(Int(self.record?.duration ?? 0)) s")
            return
        }
        do {
            let url = MeetingStore.audioURL(for: id)
            let listening = String(localized: "Lyssnar igenom hela mötet…")
            phase = .finishing(listening)
            // Normally a second or two. When it isn't, the speech model is being prepared
            // again by macOS — say so rather than stand still.
            let slow = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, self.phase == .finishing(listening) else { return }
                self.phase = .finishing(String(localized: "Talmodellen förbereds. Det kan ta någon minut."))
            }
            defer { slow.cancel() }
            let timed = try await SpeechEngine.shared.transcribeFile(url, with: language)
            // The steady voices heard the whole meeting with the same ten seconds of
            // context a second listen would use: when they cover it all, they are the
            // final word. Otherwise (an interrupted meeting, a hiccup) listen again.
            let covered = Double(steadyScores.count / VoiceTracker.speakers) / 100
            let finalScores: [Float]
            let match: [Int: Int]
            // (Continued, they heard only the new part: the whole is listened to again.)
            if !continuing, !steadyScores.isEmpty, abs(covered - (record?.duration ?? 0)) < 1.5 {
                finalScores = steadyScores
                match = [:]
            } else {
                phase = .finishing(String(localized: "Känner igen rösterna…"))
                finalScores = try await VoiceTracker.score(file: url, config: VoiceModels.final)
                let live = steadyScores.isEmpty ? scores : steadyScores
                // Continued: numbered as in the text instead (carryOver, below) — the
                // live voices were only heard in the new part.
                match = live.isEmpty || continuing ? [:] : Self.match(live: live, final: finalScores)
            }
            var words = timed.map { MeetingWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
            guard !words.isEmpty || (record?.words.isEmpty ?? true) else { return }
            _ = Self.assignSentences(&words, from: 0, scores: finalScores, final: true)
            for i in words.indices {
                if let s = words[i].speaker, s >= 0 {
                    let mapped = match[s] ?? s
                    words[i].speaker = continuing ? mapped : aliases[mapped] ?? mapped
                }
            }
            // Your Ordlista, heard: names the model wrote as something that sounds alike.
            let terms = VocabularyBoost.terms(from: Vocabulary.shared.entries.map(\.word))
            if !terms.isEmpty {
                let heard = await VocabularyBoost.shared.refine(words: words, audio: url, terms: terms)
                words = heard.words
                #if DEBUG
                if simulation == nil { Vocabulary.shared.noteHeard(heard.fixed) }   // the self-test leaves your counts alone
                #else
                Vocabulary.shared.noteHeard(heard.fixed)
                #endif
            }
            // What the list puts right in the text (as it's shown) counts too — once, here.
            #if DEBUG
            if simulation == nil { Vocabulary.shared.noteFixes(in: words.map(\.text).joined(separator: " ")) }
            #else
            Vocabulary.shared.noteFixes(in: words.map(\.text).joined(separator: " "))
            #endif
            // Listened to again ("Gör klart", "Lyssna igenom på nytt"): the new pass numbers
            // the voices its own way — each takes the number of the voice it overlaps
            // most in the text you have, so names and merges stay where you put them.
            // Continued: a voice heard in the first part takes its number from there —
            // its name too — even when the new part has more of it.
            if match.isEmpty, let old = record?.words, old.contains(where: { ($0.speaker ?? -1) >= 0 }) {
                Self.carryOver(from: old, to: &words, before: record?.continuedAt)
            }
            MeetingRecord.apply(record?.moves ?? [], to: &words)
            // The voices' prints from the whole recording (from six seconds of speech; a voice
            // with less keeps the one made while the meeting ran — the final voices are
            // numbered as the live ones), for the names of people you know.
            var prints: [Int: RoundPlacement.Voice] = [:]
            if !VoiceMemory.shared.known.isEmpty {
                prints = livePrints
                for (speaker, voice) in await VoiceMemory.shared.prints(words: words, audio: url) { prints[speaker] = voice }
            }
            // The round's names once more, on the final pass's voices: they cover every word.
            await placeRound(final: (words, prints))
            // Voices you've named in earlier meetings, named here too (when switched on) — and
            // a name Mindtalk put on a voice that clearly isn't them moved to the one that is.
            let found = VoiceMemory.shared.recognise(voices: prints, names: record?.names ?? [:],
                                                     rejected: record?.rejected ?? [:],
                                                     movable: record.map(movableVoices) ?? [])
            guard var updated = record else { return }       // names may have changed meanwhile
            MeetingRecord.apply(updated.moves, to: &words)
            // What the final pass changed — worked out off the main thread (a long meeting
            // that differs a lot takes a while), and not at all past a size where it
            // would take too long to be worth it.
            if !updated.words.isEmpty, max(updated.words.count, words.count) <= 40_000 {
                let live = updated.words, final = words
                updated.heal = await Task.detached(priority: .utility) { Self.heal(from: live, to: final) }.value
            }
            // Named, merged or marked meanwhile (the window works during the final pass):
            // kept — only what this pass made is put in.
            if var latest = record {
                latest.heal = updated.heal
                updated = latest
                MeetingRecord.apply(updated.moves, to: &words)     // moves made meanwhile too
            }
            for r in found {
                switch r {
                case .name(let speaker, let name, let score):
                    let key = String(speaker)
                    guard (updated.names[key] ?? "").isEmpty, !updated.names.values.contains(name),
                          !(updated.rejected[key] ?? []).contains(name) else { continue }
                    updated.names[key] = name
                    updated.recognized[key] = score
                    recognisedHere[key] = name
                case .move(let name, let from, let to, let score, let holder):
                    guard updated.names[String(from)] == name, movableVoices(in: updated).contains(from),
                          (updated.names[String(to)] ?? "").isEmpty,
                          !(updated.rejected[String(to)] ?? []).contains(name) else { continue }
                    moveName(name, from: from, to: to, score: score, in: &updated)
                    noteRound("voices (final pass): a name moved from voice \(from) (clearly not them, \(RoundPlacement.fmt(holder))) to voice \(to) (\(RoundPlacement.fmt(score)))")
                case .merge:
                    break                  // continued: the voices are carried over by time instead
                }
            }
            // Voices merged while this pass ran (in the text's numbering).
            if !aliases.isEmpty {
                for i in words.indices { if let s = words[i].speaker, let to = aliases[s] { words[i].speaker = to } }
            }
            updated.words = words
            updated.refined = true
            updated.language = language          // listened to in another language: it is that now
            record = updated
            MeetingStore.shared.save(updated)
            Self.log.info("meeting refined: \(words.count) words, \(found.count) voices recognised")
            // The names you gave, remembered — not the ones Mindtalk gave itself — as they are
            // now: a name moved off a voice that wasn't them is learned from neither.
            let given = updated.names.filter { updated.recognized[$0.key] == nil }
            #if DEBUG
            // (A replay with `--learn-people` learns too: into its own file, never People.json.)
            if simulation == nil || CommandLine.arguments.contains("--learn-people") {
                await VoiceMemory.shared.learn(words: words, audio: url, names: given)
            }
            #else
            await VoiceMemory.shared.learn(words: words, audio: url, names: given)
            #endif
        } catch {
            // The live transcript stays.
            Self.log.error("refine: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The voices of a new pass, numbered as in the text before it: each new voice
    /// takes the number of the old voice it shares the most time with (two may take
    /// the same — voices you merged); a voice new to the meeting gets a free number.
    nonisolated static func carryOver(from old: [MeetingWord], to new: inout [MeetingWord], before boundary: Double? = nil) {
        var overlap: [Int: [Int: Double]] = [:]
        var earlier: [Int: [Int: Double]] = [:]
        var j = 0
        for w in new {
            guard let s = w.speaker, s >= 0 else { continue }
            while j < old.count, old[j].end <= w.start { j += 1 }
            var k = j
            while k < old.count, old[k].start < w.end {
                if let o = old[k].speaker, o >= 0 {
                    let shared = min(w.end, old[k].end) - max(w.start, old[k].start)
                    if shared > 0 {
                        overlap[s, default: [:]][o, default: 0] += shared
                        if let boundary, old[k].end <= boundary { earlier[s, default: [:]][o, default: 0] += shared }
                    }
                }
                k += 1
            }
        }
        var next = (old.compactMap(\.speaker).max() ?? -1) + 1
        var map: [Int: Int] = [:]
        for s in Set(new.compactMap(\.speaker).filter { $0 >= 0 }).sorted() {
            if let first = earlier[s], first.values.reduce(0, +) >= 2,
               let best = first.max(by: { $0.value < $1.value })?.key {
                map[s] = best
            } else if let best = overlap[s]?.max(by: { $0.value < $1.value })?.key {
                map[s] = best
            } else {
                map[s] = next; next += 1
            }
        }
        for i in new.indices { if let s = new[i].speaker, let m = map[s] { new[i].speaker = m } }
    }

    /// What the final pass changed: words written differently, and turns given to
    /// another speaker.
    nonisolated static func heal(from live: [MeetingWord], to final: [MeetingWord]) -> MeetingRecord.Heal {
        let key = { (w: MeetingWord) in w.text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = live.map(key), b = final.map(key)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Words in both: did the speaker change? Counted once per run.
        var i = 0, j = 0, turns = 0, inRun = false
        while i < a.count, j < b.count {
            if removed.contains(i) { i += 1; continue }
            if inserted.contains(j) { j += 1; continue }
            let was = live[i].speaker ?? -1, now = final[j].speaker ?? -1
            let moved = was >= 0 && now >= 0 && was != now
            if moved && !inRun { turns += 1 }
            inRun = moved
            i += 1; j += 1
        }
        return MeetingRecord.Heal(words: inserted.count, speakers: turns, changed: inserted.sorted())
    }

    /// A meeting cut short — Mindtalk quit or crashed while recording: its recording
    /// is on disk, so the final pass can still run, and the notes after it.
    /// `language`: listened through in another one ("Lyssna igenom på ›").
    func finishInterrupted(_ id: UUID, language other: SpeechModel? = nil) {
        guard phase == .idle, let saved = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        // Another language: its notes are written again from the new text.
        if let other, other.isInstalled, other != saved.language { MeetingNotes.shared.writeAfterMeeting(id) }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Mindtalk lyssnar igenom ett möte")
        language = other.flatMap { $0.isInstalled ? $0 : nil } ?? saved.language
        // Cut off while continued (or while its recordings were being joined): the
        // new part may still be a recording of its own — joined first.
        continuing = saved.continuedAt != nil
            || FileManager.default.fileExists(atPath: MeetingStore.continuationURL(for: id).path)
        speakerBase = 0
        earlier = [:]
        pausedAt = nil
        record = saved
        pending = []
        scores = []
        steadyScores = []
        aliases = [:]
        voiceOverlap = Self.noOverlap
        overlapFrames = 0
        finished = nil
        phase = .finishing(String(localized: "Lyssnar igenom hela mötet…"))
        Task {
            if !(await Self.join(id)) {
                keepUnfinished = true
                return done()
            }
            if let file = try? AVAudioFile(forReading: MeetingStore.audioURL(for: id)) {
                record?.duration = Double(file.length) / file.processingFormat.sampleRate
            }
            await refine()
            done()
        }
    }

    private func done() {
        // Awake until here — the final pass too, which can take minutes.
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let continued = continuing || record?.continuedAt != nil
        if var record {
            record.finished = !keepUnfinished
            if record.finished { record.endedAt = Date() }
            // Listened through as one: a continuation no longer.
            if record.refined { record.continuedAt = nil }
            MeetingStore.shared.save(record)
            self.record = record
        }
        keepUnfinished = false
        before = nil
        continuing = false
        resetRound()
        roundMeeting = nil
        speakerBase = 0
        earlier = [:]
        pausedAt = nil
        tracker = nil
        steady = nil
        intake = nil
        loop = nil
        heartbeat?.cancel()
        heartbeat = nil
        recognition?.cancel()
        recognition = nil
        silenceAsked = false
        latecomer = nil
        manyVoices = false
        askingWhoYouAre = false
        finished = record?.id
        record = nil
        startedAt = nil
        warning = nil
        LiveMeter.shared.reset()
        phase = .idle
        #if DEBUG
        if simulation != nil { simulation = nil; Updates.shared.meetingEnded(); return }
        #endif
        Dictation.shared.meetingEnded()
        // Notes are written once; listening again keeps the ones you have (and your
        // ticked tasks) — "Sammanfatta igen" is there for a new summary.
        // Continued: written again for the whole meeting (as are notes that were being
        // written when it went on).
        if let finished, MeetingNotes.shared.takeAfterMeeting(finished) || continued
            || MeetingStore.shared.meetings.first(where: { $0.id == finished })?.summary == nil {
            MeetingNotes.shared.summarize(finished)
        }
        if let finished {
            AccessibilityNotification.Announcement(Self.endedSentence(summarizing: MeetingNotes.shared.writing.contains(finished))).post()
        }
        // A postponed update restarts Mindtalk: only once the notes are written.
        Task { @MainActor in
            // (Nor while a meeting runs again — continued, or a new one.)
            for _ in 0..<600 where !MeetingNotes.shared.writing.isEmpty || MeetingSession.shared.isBusy {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !MeetingSession.shared.isBusy else { return }     // that meeting's end will do it
            Updates.shared.meetingEnded()
        }
        MeetingStore.shared.applyRetention()
    }

    // MARK: Input

    private func heard(_ level: Float) {
        guard isRecording else { return }
        if level > 0.04 {
            lastHeard = Date()
            gaveUpOnSignal = false
            if warning == Self.restarting || warning == Self.silent { warning = nil }      // back
        }
        LiveMeter.shared.push(level)
    }

    /// When the microphone was last opened again after losing its signal.
    private var lastRestart: Date?
    /// Restarting and the fallback both failed (a muted mic, one that sends digital
    /// silence): no more restarts until real sound comes back or the input changes.
    private var gaveUpOnSignal = false
    private static var restarting: String { String(localized: "Mikrofonen slutade ge ljud. Startar om den…") }
    private static var silent: String { String(localized: "Mikrofonen ger inget ljud. Är den avstängd?") }

    /// Something you should know but needn't do anything about: said, then let go of
    /// after a while — it doesn't hang over the rest of the meeting.
    private func inform(_ text: String) {
        warning = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.warning == text { self?.warning = nil }
        }
    }

    /// The microphone sends nothing but zeros. Opened again — the usual cure. When it
    /// dies again within half a minute: a headset carries on with the Mac's own mic;
    /// any other mic stays (it may be muted on purpose) and you're told.
    private func signalLost() {
        guard isRecording, !isPaused else { return }      // paused: the mic is off on purpose
        guard !gaveUpOnSignal else { return }
        let device = recorder.inputDevice
        let bluetooth = recorder.usesBluetooth
        let again = lastRestart.map { Date().timeIntervalSince($0) < 30 } ?? false
        lastRestart = Date()
        _ = recorder.stop()
        Self.log.error("meeting: input lost its signal (bluetooth \(bluetooth), again \(again))")
        if !again, (try? recorder.start(device: device)) != nil {
            warning = Self.restarting
            return
        }
        if bluetooth, let builtIn = Microphones.shared.devices.first(where: \.isBuiltIn)?.id,
           (try? recorder.start(device: builtIn)) != nil {
            inform(String(localized: "Hörlurarnas mikrofon slutade fungera. Inspelningen fortsätter med Macens mikrofon."))
            return
        }
        try? recorder.start(device: device)
        warning = Self.silent
        gaveUpOnSignal = true
    }

    /// The microphone went away (unplugged, AirPods gone): carry on with the system input.
    private func inputChanged() {
        guard isRecording, !isPaused else { return }
        gaveUpOnSignal = false          // another input: worth trying again if it goes quiet
        // The recorder still counts itself as running on the lost device — let it
        // go first, or the restart is a no-op and the meeting records silence.
        _ = recorder.stop()
        do {
            try startMicrophone()
            inform(String(localized: "Mikrofonen kopplades bort. Inspelningen fortsätter med Macens mikrofon."))
        } catch {
            warning = error.localizedDescription
            retryMicrophone()
        }
    }

    /// Tries the microphone again every few seconds for a minute — a headset coming
    /// back, macOS settling — rather than recording silence for the rest of the meeting.
    private func retryMicrophone() {
        micRetry?.cancel()
        micRetry = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.isRecording, !self.isPaused else { return }
                if (try? self.startMicrophone()) != nil {
                    self.warning = nil
                    self.inform(String(localized: "Mikrofonen är tillbaka och inspelningen fortsätter."))
                    return
                }
            }
        }
    }
    private var micRetry: Task<Void, Never>?

    /// Is `word`, just heard, the settled `last` read once more? Read again with more
    /// context a word can land a little later, or come out differently ("höger" →
    /// "högre") — but then it sits on top of the old one. A word that starts after
    /// it is a new word, also when it is the same one ("nej, nej").
    nonisolated static func again(_ word: MeetingWord, after last: MeetingWord) -> Bool {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if !key(word.text).isEmpty, key(word.text) == key(last.text) { return word.start < last.end - 0.02 }
        // Other words: only when it clearly begins inside the old one (times move
        // by a frame or so between readings).
        return word.start < last.end - max(0.1, (last.end - last.start) / 2)
    }

    // MARK: Voices → speakers

    /// The speaker most active from `start` to `end`, or `unknown` if no one clearly was.
    nonisolated static func speaker(in scores: [Float], from start: Double, to end: Double) -> Int {
        let n = VoiceTracker.speakers
        let frames = scores.count / n
        let a = max(0, Int(start * 100))
        let b = min(frames, max(a + 1, Int((end * 100).rounded(.up))))
        guard a < b else { return MeetingWord.unknown }
        var sums = [Float](repeating: 0, count: n)
        for f in a..<b { for s in 0..<n { sums[s] += scores[f * n + s] } }
        guard let best = sums.indices.max(by: { sums[$0] < sums[$1] }) else { return MeetingWord.unknown }
        // Two voices about as strong (talking at once, or a near tie): undecided — the
        // words stay with whoever spoke before rather than flip back and forth.
        let second = sums.indices.filter { $0 != best }.map { sums[$0] }.max() ?? 0
        guard (sums[best] - second) / Float(b - a) >= 0.02 else { return MeetingWord.unknown }
        return sums[best] / Float(b - a) > 0.05 ? best : MeetingWord.unknown
    }

    /// Pairs the final pass's speakers with the live ones (by how much they speak at
    /// the same moments), so names and colours stay with each voice.
    nonisolated static func match(live: [Float], final: [Float]) -> [Int: Int] {
        var overlap = noOverlap
        count(&overlap, of: final, with: live, frames: 0..<(min(live.count, final.count) / VoiceTracker.speakers))
        return mapping(overlap)
    }

    nonisolated static var noOverlap: [[Int]] {
        [[Int]](repeating: [Int](repeating: 0, count: VoiceTracker.speakers), count: VoiceTracker.speakers)
    }

    /// Adds, for `frames`, how often speaker a of `scores` and speaker b of `other`
    /// were the one speaking at the same moment.
    nonisolated static func count(_ overlap: inout [[Int]], of scores: [Float], with other: [Float], frames: Range<Int>) {
        let n = VoiceTracker.speakers
        func active(_ scores: [Float], _ f: Int) -> Int? {
            var best: Int?
            var top: Float = 0.5
            for s in 0..<n where scores[f * n + s] > top { top = scores[f * n + s]; best = s }
            return best
        }
        for f in frames {
            if let a = active(scores, f), let b = active(other, f) { overlap[a][b] += 1 }
        }
    }

    /// The pairing that agrees most. A voice with nothing to go on keeps its own
    /// number (both listeners number voices as they first speak) rather than
    /// borrowing someone else's.
    nonisolated static func mapping(_ overlap: [[Int]]) -> [Int: Int] {
        let n = VoiceTracker.speakers
        var pairs: [(final: Int, live: Int, frames: Int)] = []
        for a in 0..<n { for b in 0..<n where overlap[a][b] > 0 { pairs.append((a, b, overlap[a][b])) } }
        var mapping: [Int: Int] = [:]
        var taken = Set<Int>()
        for p in pairs.sorted(by: { $0.frames > $1.frames }) where mapping[p.final] == nil && !taken.contains(p.live) {
            mapping[p.final] = p.live
            taken.insert(p.live)
        }
        for a in 0..<n where mapping[a] == nil && !taken.contains(a) {
            mapping[a] = a
            taken.insert(a)
        }
        var free = (0..<n).filter { !taken.contains($0) }
        for a in 0..<n where mapping[a] == nil { mapping[a] = free.isEmpty ? a : free.removeFirst() }
        return mapping
    }
}

/// The sound level while recording, apart from the session — the waveform redraws
/// many times a second, the transcript shouldn't.
@MainActor
final class LiveMeter: ObservableObject {
    static let shared = LiveMeter()
    @Published private(set) var levels = [Float](repeating: 0, count: 28)
    private var last = Date.distantPast

    func push(_ level: Float) {
        guard Date().timeIntervalSince(last) > 0.06 else { return }
        last = Date()
        levels.removeFirst()
        levels.append(level)
    }

    func reset() { levels = [Float](repeating: 0, count: levels.count) }

    #if DEBUG
    func demo(_ values: [Float]) { levels = Array((values + values).suffix(levels.count)) }
    #endif
}

/// The meeting's audio as it arrives: kept in memory until its words have settled,
/// handed to the voice tracker, and written to disk.
final class AudioIntake: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []
    /// Sample number of `buffer[0]` since the start.
    private var bufferStart = 0
    private var total = 0
    private var forVoices: [Float] = []
    private let file: AVAudioFile
    private let queue = DispatchQueue(label: "ai.mindact.mindtalk.meeting-audio")
    private var closed = false
    private var failed = false
    /// Writing to disk has failed (full disk): the words carry on, the recording doesn't.
    var writeFailed: Bool { queue.sync { failed } }

    /// Where the meeting's time starts in this file: 0, or — continuing a finished
    /// meeting — the length of what was recorded before (and the quiet between).
    let start: Int

    init(file url: URL, startingAt start: Int = 0) throws {
        self.start = start
        bufferStart = start
        total = start
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        // Readable only by you, like the meeting's text.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// From the audio thread.
    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer += chunk
        total += chunk.count
        forVoices += chunk
        if opening.count < openingLimit { opening += chunk.prefix(openingLimit - opening.count) }
        lock.unlock()
        queue.async { [self] in
            guard !closed, let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(chunk.count)),
                  let channel = pcm.floatChannelData?[0] else { return }
            pcm.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.count) }
            do { try file.write(from: pcm) } catch { failed = true }
        }
    }

    var count: Int { lock.withLock { total } }

    func samples(from start: Int, to end: Int) -> [Float] {
        lock.withLock {
            let a = max(start, bufferStart) - bufferStart
            let b = min(end, bufferStart + buffer.count) - bufferStart
            return a < b ? Array(buffer[a..<b]) : []
        }
    }

    /// The first minutes, kept whole: who's in the room is heard there (the
    /// introduction), long after the rolling buffer has moved on. They begin at `start`.
    private var opening: [Float] = []
    private var openingLimit = 3 * 60 * 16_000
    static let longestOpening = 10 * 60 * 16_000
    func openingSamples() -> [Float] { lock.withLock { opening } }
    /// How much of the opening there is, and a part of it — the round reads it a
    /// tenth of a second at a time.
    var openingCount: Int { lock.withLock { opening.count } }
    func opening(from start: Int, to end: Int) -> [Float] {
        lock.withLock {
            let a = max(0, start), b = min(end, opening.count)
            return a < b ? Array(opening[a..<b]) : []
        }
    }

    /// A round begins: keep the opening going this much longer (if it still runs
    /// unbroken from the start), at most ten minutes in all.
    func keepOpening(seconds: Int) {
        lock.withLock {
            guard opening.count == total - start else { return }
            openingLimit = min(max(openingLimit, opening.count + seconds * 16_000), Self.longestOpening)
        }
    }

    func drop(before sample: Int) {
        lock.withLock {
            let k = min(max(0, sample - bufferStart), buffer.count)
            buffer.removeFirst(k)
            bufferStart += k
        }
    }

    func takeForVoices() -> [Float] {
        lock.withLock {
            defer { forVoices = [] }
            return forVoices
        }
    }

    /// Writes what's queued and closes the file.
    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            file.close()
        }
    }
}
