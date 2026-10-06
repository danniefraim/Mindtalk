import AVFoundation
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

    @Published private(set) var phase: Phase = .idle
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
    /// Ending: the moment it ends, unless you undo it. Recording goes on until then.
    @Published private(set) var stopAt: Date?
    var stopping: Bool { stopAt != nil }
    private var stopCountdown: Task<Void, Never>?
    static let undoSeconds = 3.0

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
                guard session.isRecording else { return }
                session.lastError = String(localized: "Mötet avslutades när Macen gick i vila.")
                session.stop()
            }
        }
    }

    private static let rate = 16_000

    #if DEBUG
    /// Self-test: an audio file played in as if it were the microphone.
    private var simulation: (start: Date, speed: Double)?

    func simulate(file: URL, language: SpeechModel, speed: Double) async {
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
        do {
            let source = try AudioChunks(url: file)
            while let chunk = try source.next(seconds: 0.1) {
                intake?.append(chunk)
                try? await Task.sleep(for: .milliseconds(Int(100 / speed)))
            }
        } catch { print("Fel: \(error.localizedDescription)") }
        stop()
        while phase != .idle { try? await Task.sleep(for: .milliseconds(200)) }
        if let id = finished {
            if let saved = MeetingStore.shared.meetings.first(where: { $0.id == id }) {
                print("\n=== Efter genomgången (\(saved.speakers.count) talare) ===\n" + MeetingText.plain(saved))
                if let heal = saved.heal { print("\n" + MeetingView.healText(heal) + " – ändrade ord: " + heal.changed.map { saved.words[$0].text }.joined(separator: ", ")) }
            }
            MeetingStore.shared.delete(id)
        }
    }

    /// Screenshots: a meeting twelve minutes in, three people, one of them named.
    func showDemo(finished: Bool) {
        let script: [(Int, String)] = [
            (0, "Då kör vi. Välkomna allihop – idag ska vi gå igenom lanseringen och bestämma vad som händer härnäst."),
            (1, "Siffrorna ser riktigt bra ut. Vi hade fler nedladdningar första dagen än hela förra månaden."),
            (0, "Vad kul! Vet vi var de flesta användarna kommer ifrån?"),
            (2, "Mest från Sverige, men vi ser en del från Norge och Danmark också. The feedback in English is great too."),
            (1, "Jag tycker att vi ska prioritera mötesfunktionen. Det är det folk frågar mest om."),
            (0, "Håller med. Kan du ta fram en plan till torsdag?"),
        ]
        var new = MeetingRecord(title: "Veckomöte – lansering", date: Date().addingTimeInterval(-754), language: .swedish)
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

    func start() {
        guard phase == .idle else { return }
        lastError = nil
        let dictation = Dictation.shared
        guard dictation.phase == .idle else { return }
        language = dictation.engine
        guard language.isInstalled else {
            lastError = String(localized: "Ladda ned \(language.modelName) först, under Inställningar → Språk.")
            return
        }
        guard VoiceModels.isInstalled else { return }
        guard Recorder.micAuthorized else {
            lastError = String(localized: "Mindtalk behöver tillgång till mikrofonen.")
            return
        }
        let date = Date()
        var new = MeetingRecord(title: MeetingRecord.defaultTitle(for: date), date: date, language: language)
        new.finished = false
        do {
            try MeetingStore.prepareFolder(for: new.id)
            let intake = try AudioIntake(file: MeetingStore.audioURL(for: new.id))
            self.intake = intake
            recorder = Recorder(keepSamples: false)
            recorder.onChunk = { chunk in intake.append(chunk) }
            recorder.onLevel = { level in Task { @MainActor in MeetingSession.shared.heard(level) } }
            recorder.onInterrupted = { Task { @MainActor in MeetingSession.shared.inputChanged() } }
            let chosen = Microphones.shared.selectedDeviceID
            do {
                try recorder.start(device: chosen)
            } catch where chosen != nil {
                // The chosen mic won't open — the Mac's own will do.
                Self.log.error("chosen microphone failed, using the system input")
                try recorder.start(device: nil)
            }
        } catch {
            intake = nil
            try? FileManager.default.removeItem(at: MeetingStore.folder(for: new.id))
            lastError = error.localizedDescription
            return
        }
        record = new
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
        phase = .starting
        Cue.start()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Recording a meeting")
        MeetingStore.shared.save(new)
        Self.log.info("meeting started (\(self.language.rawValue, privacy: .public))")
        loop = Task { await self.run() }
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
        stopCountdown?.cancel()
        stopCountdown = nil
        stopAt = nil
        phase = .finishing(String(localized: "Skriver klart…"))
        _ = recorder.stop()
        let loop = self.loop
        Task {
            await loop?.value
            await finish()
        }
    }

    // MARK: Editing while it runs

    func rename(to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        record?.title = title
        if let record { MeetingStore.shared.save(record) }
    }

    func name(speaker: Int, as name: String) {
        record?.names[String(speaker)] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let record { MeetingStore.shared.save(record) }
    }

    /// Two voices that are one person — from now on too.
    func merge(_ speaker: Int, into other: Int) {
        guard var record else { return }
        MeetingRecord.merge(speaker, into: other, in: &record)
        for (from, to) in aliases where to == speaker { aliases[from] = other }
        aliases[speaker] = other
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
        guard var record else { return }
        let notes = MeetingRecord.notes(from: text, old: record.notes, now: isRecording ? elapsed : nil)
        guard notes != record.notes else { return }
        record.notes = notes
        self.record = record
        notesSave?.cancel()
        notesSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let record = self?.record else { return }
            MeetingStore.shared.save(record)
        }
    }
    private var notesSave: Task<Void, Never>?

    /// A moment worth finding again — when you pressed. Whether that was just before
    /// or just after it was said, the notes look at the seconds around it.
    @discardableResult
    func mark(_ kind: MeetingRecord.Mark.Kind) -> MeetingRecord.Mark? {
        guard var record, isRecording else { return nil }
        let mark = MeetingRecord.Mark(at: elapsed, kind: kind)
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

    /// You told the others it's recorded.
    func informed() {
        guard var record, record.informed == nil else { return }
        record.informed = Date()
        self.record = record
        MeetingStore.shared.save(record)
    }

    /// Mindtalk is quitting mid-meeting: keep what has been written. It opens as
    /// an unfinished meeting next time, ready to be finished.
    func saveBeforeQuit() {
        guard var record, isBusy else { return }
        record.words += pending
        record.duration = Double(intake?.count ?? 0) / Double(Self.rate)
        intake?.close()
        MeetingStore.shared.save(record)
    }

    // MARK: The live loop

    private func run() async {
        do {
            try await SpeechEngine.shared.load(language)
            tracker = try await VoiceTracker.make(VoiceModels.live)
            steady = try? await VoiceTracker.make(VoiceModels.final)
        } catch {
            Self.log.error("meeting models: \(error.localizedDescription, privacy: .public)")
            warning = tracker == nil && language.isInstalled
                ? String(localized: "Rösterna kunde inte startas – texten skrivs utan talare.")
                : error.localizedDescription
        }
        if phase == .starting { phase = .recording }
        while !Task.isCancelled, phase == .recording {
            await step(final: false)
            if Date().timeIntervalSince(lastSave) > 20, var record {
                lastSave = Date()
                record.duration = Double(intake?.count ?? 0) / Double(Self.rate)
                MeetingStore.shared.save(record)
            }
            checkInput()
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private static var noText: String {
        String(localized: "Texten kan inte skrivas just nu – ljudet spelas in och skrivs ut efter mötet.")
    }

    /// Says so when the recording can't be trusted.
    private func checkInput() {
        if intake?.writeFailed == true {
            warning = String(localized: "Ljudet kan inte sparas – är disken full? Texten skrivs ändå.")
        } else if Date().timeIntervalSince(lastHeard) > 20 {
            warning = String(localized: "Jag hör nästan ingenting – är rätt mikrofon vald?")
        } else if warning == String(localized: "Jag hör nästan ingenting – är rätt mikrofon vald?") {
            warning = nil
        }
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

        let from = max(0, Int((settled - Self.lead) * Double(Self.rate)))
        var window = intake.samples(from: from, to: intake.count)
        let longest = 14 * Self.rate
        if window.count > longest { window = Array(window.prefix(longest)) }
        let windowEnd = Double(from + window.count) / Double(Self.rate)
        let fresh = windowEnd - settled
        guard fresh >= 0.5 || (final && fresh > 0) else { return resolveSpeakers(final: false) }

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

    /// Keeps whoever is speaking in the words still being written until the voices
    /// say otherwise, and only publishes a change.
    private func setPending(_ words: [MeetingWord]) {
        var words = words
        if let speaker = pending.first?.speaker { for j in words.indices { words[j].speaker = speaker } }
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
        for i in from..<unresolved { if let s = words[i].speaker, let to = aliases[s] { words[i].speaker = to } }
        // Not yet: the quick voices' guess, in the steady ones' numbering.
        let map = steady == nil ? [:] : quickToSteady()
        if unresolved < words.count {
            var rest = Array(words[unresolved...])
            _ = Self.assignSentences(&rest, from: 0, scores: scores, final: true)
            for k in rest.indices {
                guard let s = rest[k].speaker, s >= 0 else { continue }
                let mapped = map[s] ?? s
                rest[k].speaker = aliases[mapped] ?? mapped
            }
            words.replaceSubrange(unresolved..., with: rest)
        }
        // What you moved stays moved, whatever the voices say.
        MeetingRecord.apply(record?.moves ?? [], to: &words, from: from)
        // The page redraws on every change: only say so when there is one.
        if words != before { record?.words = words }
        // Still being written: whoever is speaking in them so far.
        let frames = scores.count / VoiceTracker.speakers
        if let first = pending.first, let last = pending.last, Int(first.start * 100) < frames {
            let s = Self.speaker(in: scores, from: first.start, to: last.end)
            let mapped = s >= 0 ? (map[s] ?? s) : s
            var labelled = pending
            for j in labelled.indices { labelled[j].speaker = aliases[mapped] ?? mapped }
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
        // The last words are written also when the voices never started.
        await step(final: true)
        if let rest = try? await tracker?.finish() { scores += rest }
        if let rest = try? await steady?.finish() { steadyScores += rest }
        resolveSpeakers(final: true)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard var record else { return done() }
        record.words += pending
        pending = []
        record.duration = Double(intake?.count ?? 0) / Double(Self.rate)
        // A slip of the finger: nothing said, a few seconds long — not worth keeping.
        if record.words.isEmpty, record.duration < 10 {
            MeetingStore.shared.delete(record.id)
            self.record = nil
            return done()
        }
        self.record = record
        MeetingStore.shared.save(record)
        Self.log.info("meeting recorded: \(Int(record.duration)) s, \(record.words.count) words")
        #if DEBUG
        if simulation != nil { print("\n=== Live (\(record.speakers.count) talare) ===\n" + MeetingText.plain(record)) }
        #endif
        await refine()
        done()
    }

    /// Reads the whole recording once more: seamless words, voices with more context.
    private func refine() async {
        guard let id = record?.id, (record?.duration ?? 0) > 2 else { return }
        do {
            let url = MeetingStore.audioURL(for: id)
            let listening = String(localized: "Lyssnar igenom hela mötet…")
            phase = .finishing(listening)
            // Normally a second or two. When it isn't, the speech model is being prepared
            // again by macOS — say so rather than stand still.
            let slow = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, self.phase == .finishing(listening) else { return }
                self.phase = .finishing(String(localized: "Talmodellen förbereds – det kan ta någon minut…"))
            }
            defer { slow.cancel() }
            let timed = try await SpeechEngine.shared.transcribeFile(url, with: language)
            // The steady voices heard the whole meeting with the same ten seconds of
            // context a second listen would use: when they cover it all, they are the
            // final word. Otherwise (an interrupted meeting, a hiccup) listen again.
            let covered = Double(steadyScores.count / VoiceTracker.speakers) / 100
            let finalScores: [Float]
            let match: [Int: Int]
            if !steadyScores.isEmpty, abs(covered - (record?.duration ?? 0)) < 1.5 {
                finalScores = steadyScores
                match = [:]
            } else {
                phase = .finishing(String(localized: "Känner igen rösterna…"))
                finalScores = try await VoiceTracker.score(file: url, config: VoiceModels.final)
                let live = steadyScores.isEmpty ? scores : steadyScores
                match = live.isEmpty ? [:] : Self.match(live: live, final: finalScores)
            }
            var words = timed.map { MeetingWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
            guard !words.isEmpty || (record?.words.isEmpty ?? true) else { return }
            _ = Self.assignSentences(&words, from: 0, scores: finalScores, final: true)
            for i in words.indices {
                if let s = words[i].speaker, s >= 0 {
                    let mapped = match[s] ?? s
                    words[i].speaker = aliases[mapped] ?? mapped
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
            guard var updated = record else { return }       // names may have changed meanwhile
            MeetingRecord.apply(updated.moves, to: &words)
            if !updated.words.isEmpty { updated.heal = Self.heal(from: updated.words, to: words) }
            updated.words = words
            updated.refined = true
            record = updated
            MeetingStore.shared.save(updated)
            Self.log.info("meeting refined: \(words.count) words")
        } catch {
            // The live transcript stays.
            Self.log.error("refine: \(error.localizedDescription, privacy: .public)")
        }
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
    func finishInterrupted(_ id: UUID) {
        guard phase == .idle, var saved = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
        let url = MeetingStore.audioURL(for: id)
        if let file = try? AVAudioFile(forReading: url) {
            saved.duration = Double(file.length) / file.processingFormat.sampleRate
        }
        language = saved.language
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
            await refine()
            done()
        }
    }

    private func done() {
        if var record {
            record.finished = true
            MeetingStore.shared.save(record)
            self.record = record
        }
        tracker = nil
        steady = nil
        intake = nil
        loop = nil
        finished = record?.id
        record = nil
        startedAt = nil
        warning = nil
        LiveMeter.shared.reset()
        phase = .idle
        Updates.shared.meetingEnded()
        #if DEBUG
        if simulation != nil { simulation = nil; return }
        #endif
        Dictation.shared.meetingEnded()
        if let finished { MeetingNotes.shared.summarize(finished) }
        MeetingStore.shared.applyRetention()
    }

    // MARK: Input

    private func heard(_ level: Float) {
        guard isRecording else { return }
        if level > 0.04 { lastHeard = Date() }
        LiveMeter.shared.push(level)
    }

    /// The microphone went away (unplugged, AirPods gone): carry on with the system input.
    private func inputChanged() {
        guard isRecording else { return }
        // The recorder still counts itself as running on the lost device — let it
        // go first, or the restart is a no-op and the meeting records silence.
        _ = recorder.stop()
        do {
            try recorder.start(device: nil)
            warning = String(localized: "Mikrofonen kopplades bort – inspelningen fortsätter med Macens mikrofon.")
        } catch {
            warning = error.localizedDescription
        }
    }

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

    init(file url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// From the audio thread.
    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer += chunk
        total += chunk.count
        forVoices += chunk
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
