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
    @Published private(set) var levels = [Float](repeating: 0, count: 24)
    @Published private(set) var startedAt: Date?
    /// The meeting that just finished — the page keeps showing it.
    @Published private(set) var finished: UUID?
    @Published var lastError: String?

    var isRecording: Bool { phase == .starting || phase == .recording }
    var isBusy: Bool { phase != .idle }
    private(set) var language: SpeechModel = .swedish

    private var recorder = Recorder(keepSamples: false)
    private var intake: AudioIntake?
    private var tracker: VoiceTracker?
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
    private var lastLevelPush = Date.distantPast
    private var lastSave = Date()

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
        levels = [0.1, 0.3, 0.5, 0.35, 0.6, 0.45, 0.2, 0.5, 0.7, 0.4, 0.3, 0.55, 0.65, 0.4, 0.25, 0.5, 0.6, 0.3,
                  0.2, 0.45, 0.6, 0.35, 0.5, 0.4]
        phase = .recording
    }

    private func report(settled words: ArraySlice<MeetingWord>) {
        guard let simulation, let last = words.last else { return }
        let heard = Date().timeIntervalSince(simulation.start) * simulation.speed
        print(String(format: "[%5.1f s, %.1f s efter] ", heard, heard - last.end) + words.map(\.text).joined(separator: " "))
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
            lastError = String(localized: "Hämta \(language.title) först, under Inställningar → Språk.")
            return
        }
        guard VoiceModels.isInstalled else { return }
        guard Recorder.micAuthorized else {
            lastError = String(localized: "Mindtalk behöver tillgång till mikrofonen.")
            return
        }
        let date = Date()
        let new = MeetingRecord(title: MeetingRecord.defaultTitle(for: date), date: date, language: language)
        do {
            try MeetingStore.prepareFolder(for: new.id)
            let intake = try AudioIntake(file: MeetingStore.audioURL(for: new.id))
            self.intake = intake
            recorder = Recorder(keepSamples: false)
            recorder.onChunk = { chunk in intake.append(chunk) }
            recorder.onLevel = { level in Task { @MainActor in MeetingSession.shared.push(level: level) } }
            recorder.onInterrupted = { Task { @MainActor in MeetingSession.shared.inputChanged() } }
            try recorder.start(device: Microphones.shared.selectedDeviceID)
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
        settled = 0
        unresolved = 0
        startedAt = date
        lastSave = date
        phase = .starting
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Recording a meeting")
        MeetingStore.shared.save(new)
        Self.log.info("meeting started (\(self.language.rawValue, privacy: .public))")
        loop = Task { await self.run() }
    }

    func stop() {
        guard isRecording else { return }
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

    /// Mindtalk is quitting mid-meeting: keep what has been written.
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
        } catch {
            Self.log.error("meeting models: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        if phase == .starting { phase = .recording }
        while !Task.isCancelled, phase == .recording {
            await step(final: false)
            if Date().timeIntervalSince(lastSave) > 20, let record {
                lastSave = Date()
                MeetingStore.shared.save(record)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Scores the new audio for voices, then writes out what hasn't settled.
    private func step(final: Bool) async {
        guard let intake else { return }
        let newAudio = intake.takeForVoices()
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
        guard fresh >= 0.5 || (final && fresh > 0) else { return resolveSpeakers(final: final) }

        let timed: [WordTiming]
        do {
            timed = try await SpeechEngine.shared.transcribeTimed(samples: window, with: language)
        } catch {
            Self.log.error("words: \(error.localizedDescription, privacy: .public)")
            return
        }
        let base = Double(from) / Double(Self.rate)
        // Only what comes after the settled words: the context was written down already.
        var heard = timed.map { MeetingWord(text: $0.word, start: base + $0.startTime, end: base + $0.endTime) }
            .filter { ($0.start + $0.end) / 2 > settled }
        // Read again with more context, the last settled word can land a little later:
        // it's the same word, not a new one.
        if let first = heard.first, let last = record?.words.last,
           Self.same(first.text, last.text), first.start < last.end + 0.6 {
            heard.removeFirst()
        }

        guard !heard.isEmpty else {
            // Silence: nothing to wait for.
            pending = []
            if final { settle(upTo: windowEnd) } else if fresh > 3 { settle(upTo: windowEnd - 0.5) }
            return resolveSpeakers(final: final)
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
            // Someone talking without a break: settle all but the last few seconds.
            if cut == nil, fresh > 9 {
                cut = heard.lastIndex { $0.end <= windowEnd - 2.5 }
            }
        }
        if let cut {
            #if DEBUG
            report(settled: heard[...cut])
            #endif
            record?.words += heard[...cut]
            let next = cut + 1 < heard.count ? heard[cut + 1].start : windowEnd
            settle(upTo: (heard[cut].end + min(next, heard[cut].end + 0.4)) / 2)
            pending = Array(heard[(cut + 1)...])
        } else {
            pending = heard
        }
        resolveSpeakers(final: final)
    }

    private func settle(upTo seconds: Double) {
        settled = max(settled, seconds)
        intake?.drop(before: Int((settled - Self.lead) * Double(Self.rate)))
    }

    /// Gives settled words their speaker once the voices have caught up with them;
    /// words still being written get a provisional one.
    private func resolveSpeakers(final: Bool) {
        let frames = scores.count / VoiceTracker.speakers
        if var words = record?.words, unresolved < words.count {
            unresolved = Self.assignSentences(&words, from: unresolved, scores: scores, final: final)
            record?.words = words
        }
        // Still being written: whoever is speaking in them so far.
        if let first = pending.first, let last = pending.last, Int(first.start * 100) < frames {
            let s = Self.speaker(in: scores, from: first.start, to: last.end)
            for j in pending.indices { pending[j].speaker = s }
        }
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
            let s = speaker(in: scores, from: words[i].start, to: words[j].end)
            for k in i...j { words[k].speaker = s }
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
        if tracker != nil {
            await step(final: true)
            if let rest = try? await tracker?.finish() { scores += rest }
            resolveSpeakers(final: true)
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard var record else { return done() }
        record.words += pending
        pending = []
        record.duration = Double(intake?.count ?? 0) / Double(Self.rate)
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
        let url = MeetingStore.audioURL(for: id)
        do {
            phase = .finishing(String(localized: "Lyssnar igenom hela mötet…"))
            let timed = try await SpeechEngine.shared.transcribeFile(url, with: language)
            phase = .finishing(String(localized: "Känner igen rösterna…"))
            let finalScores = try await VoiceTracker.score(file: url, config: VoiceModels.final)
            var words = timed.map { MeetingWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
            guard !words.isEmpty || (record?.words.isEmpty ?? true) else { return }
            let match = Self.match(live: scores, final: finalScores)
            _ = Self.assignSentences(&words, from: 0, scores: finalScores, final: true)
            for i in words.indices { if let s = words[i].speaker, s >= 0 { words[i].speaker = match[s] ?? s } }
            guard var updated = record else { return }       // names may have changed meanwhile
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

    private func done() {
        tracker = nil
        intake = nil
        loop = nil
        finished = record?.id
        record = nil
        startedAt = nil
        levels = [Float](repeating: 0, count: levels.count)
        phase = .idle
        #if DEBUG
        if simulation != nil { simulation = nil; return }
        #endif
        Dictation.shared.meetingEnded()
    }

    // MARK: Input

    private func push(level: Float) {
        guard isRecording, Date().timeIntervalSince(lastLevelPush) > 0.06 else { return }
        lastLevelPush = Date()
        levels.removeFirst()
        levels.append(level)
    }

    /// The microphone went away (unplugged, AirPods gone): carry on with the system input.
    private func inputChanged() {
        guard isRecording else { return }
        do { try recorder.start(device: nil) } catch { lastError = error.localizedDescription }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return !key(a).isEmpty && key(a) == key(b)
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
        let n = VoiceTracker.speakers
        let frames = min(live.count, final.count) / n
        func active(_ scores: [Float], _ f: Int) -> Int? {
            var best: Int?
            var top: Float = 0.5
            for s in 0..<n where scores[f * n + s] > top { top = scores[f * n + s]; best = s }
            return best
        }
        var overlap = [[Int]](repeating: [Int](repeating: 0, count: n), count: n)
        for f in 0..<frames {
            if let a = active(final, f), let b = active(live, f) { overlap[a][b] += 1 }
        }
        var pairs: [(final: Int, live: Int, frames: Int)] = []
        for a in 0..<n { for b in 0..<n where overlap[a][b] > 0 { pairs.append((a, b, overlap[a][b])) } }
        var mapping: [Int: Int] = [:]
        var taken = Set<Int>()
        for p in pairs.sorted(by: { $0.frames > $1.frames }) where mapping[p.final] == nil && !taken.contains(p.live) {
            mapping[p.final] = p.live
            taken.insert(p.live)
        }
        var free = (0..<n).filter { !taken.contains($0) }
        for a in 0..<n where mapping[a] == nil { mapping[a] = free.isEmpty ? a : free.removeFirst() }
        return mapping
    }
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
            try? file.write(from: pcm)
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
