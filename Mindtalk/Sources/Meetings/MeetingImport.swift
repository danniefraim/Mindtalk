import AVFoundation
import AppKit
import UniformTypeIdentifiers
import os

// MARK: - Importing a recording
//
// An audio or video file dropped on the Möten page (or chosen with "Importera fil…",
// or opened with Mindtalk from Finder) becomes a meeting like the others: the same
// text with its speakers and names, the same notes, questions, folders and export.
// Its sound is read once into the meeting's own recording (16 kHz, as a meeting
// records — of a video only the sound is kept), then listened through as a meeting
// is when it ends. Files are taken one at a time; nothing leaves the Mac.

@MainActor
final class MeetingImport: ObservableObject {
    static let shared = MeetingImport()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Import")

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var name: String { url.deletingPathExtension().lastPathComponent }
        let video: Bool
        /// The folder chosen when it was dropped.
        let folder: UUID?
        var stage: Stage = .waiting
        #if DEBUG
        init(url: URL, video: Bool, folder: UUID?, stage: Stage = .waiting, progress: Double = 0) {
            self.url = url; self.video = video; self.folder = folder; self.stage = stage; self.progress = progress
            if stage == .done { meeting = UUID() }
            if stage == .failed { error = String(localized: "Det här är inte en ljud- eller videofil som macOS kan läsa.") }
        }
        #else
        init(url: URL, video: Bool, folder: UUID?) { self.url = url; self.video = video; self.folder = folder }
        #endif
        /// Of the whole job, 0…1 — estimated within a step from the recording's length.
        var progress: Double = 0
        var meeting: UUID?
        var error: String?
    }

    enum Stage: Equatable {
        case waiting, reading, writing, voices, notes, done, failed

        var title: String {
            switch self {
            case .waiting: return String(localized: "Väntar på sin tur")
            case .reading: return String(localized: "Läser in ljudet")
            case .writing: return String(localized: "Skriver ut")
            case .voices: return String(localized: "Håller isär rösterna")
            case .notes: return String(localized: "Skriver anteckningar")
            case .done: return String(localized: "Klar")
            case .failed: return String(localized: "Gick inte")
            }
        }

        /// Where the step begins in the whole, 0…1.
        var start: Double {
            switch self {
            case .waiting, .reading: return 0
            case .writing: return 0.12
            case .voices: return 0.55
            case .notes: return 0.9
            case .done, .failed: return 1
            }
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var running: Task<Void, Never>?

    /// Sound and video — whatever macOS can read (mp3, m4a, wav, aiff, mp4, mov…).
    static let types: [UTType] = [.audiovisualContent]

    static func canImport(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    /// "Importera fil…": one or more files from a panel.
    func choose(folder: UUID?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Välj en ljud- eller videofil att skriva ut")
        panel.prompt = String(localized: "Importera")
        guard panel.runModal() == .OK else { return }
        add(panel.urls, folder: folder)
    }

    /// Files dropped or opened: each one queued; anything that isn't sound or video is
    /// said so, not silently left out.
    func add(_ urls: [URL], folder: UUID?) {
        var refused: [String] = []
        for url in urls {
            guard Self.canImport(url) else { refused.append(url.lastPathComponent); continue }
            guard !jobs.contains(where: { $0.url == url && $0.stage != .done && $0.stage != .failed }) else { continue }
            let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
            jobs.append(Job(url: url, video: video, folder: MeetingFolders.shared.folder(folder)?.id))
        }
        if !refused.isEmpty {
            var job = Job(url: URL(fileURLWithPath: refused.joined(separator: ", ")), video: false, folder: nil)
            job.stage = .failed
            job.error = String(localized: "Det här är inte en ljud- eller videofil som macOS kan läsa.")
            jobs.append(job)
        }
        kick()
    }

    /// Taken away: a waiting or finished card, or one being worked on (stopped).
    func remove(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].stage != .waiting && jobs[i].stage != .done && jobs[i].stage != .failed {
            running?.cancel()
        }
        jobs.remove(at: i)
    }

    /// The next file — not while a meeting is being recorded or finished (they share
    /// the speech model and the Mac's attention).
    func kick() {
        guard running == nil, let i = jobs.firstIndex(where: { $0.stage == .waiting }) else { return }
        let id = jobs[i].id
        running = Task { @MainActor [weak self] in
            while MeetingSession.shared.isBusy { try? await Task.sleep(for: .seconds(2)) }
            await self?.run(id)
            self?.running = nil
            self?.kick()
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    /// A step's progress creeping on while it works — from what such a step usually
    /// takes for this much sound — never quite to its end until it's done.
    private func creep(_ id: UUID, _ stage: Stage, seconds: Double) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let began = Date()
            let next: Double = { switch stage { case .reading: 0.12; case .writing: 0.55; case .voices: 0.9; default: 1 } }()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(began) / max(1, seconds)
                let share = 1 - exp(-2.2 * t)                      // quick at first, slower near the end
                self?.update(id) { $0.progress = stage.start + (next - stage.start) * min(0.95, share) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let language = Dictation.shared.engine
        guard language.isInstalled, VoiceModels.isInstalled else {
            update(id) { $0.stage = .failed; $0.error = String(localized: "Ladda ned talmodellen och Nemotron 3 först – på sidan Möten.") }
            return
        }
        Self.log.info("import: \(job.video ? "video" : "audio", privacy: .public), \(job.url.pathExtension, privacy: .public)")
        let date = await Self.recordedDate(job.url)
        var record = MeetingRecord(title: job.name, date: date, language: language)
        record.finished = false
        record.folder = job.folder
        record.folderAsked = job.folder != nil
        record.source = MeetingRecord.Source(file: job.url.lastPathComponent, video: job.video, importedAt: Date())
        let audio = MeetingStore.audioURL(for: record.id)
        do {
            // 1. The sound, read once into the meeting's own recording.
            update(id) { $0.stage = .reading; $0.meeting = record.id }
            try MeetingStore.prepareFolder(for: record.id)
            let url = job.url
            let reading = Task.detached(priority: .userInitiated) { [weak self] in
                try await Self.readSound(from: url, to: audio) { share in
                    Task { @MainActor in self?.update(id) { $0.progress = 0.12 * share } }
                }
            }
            let duration = try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
            try Task.checkCancellation()
            guard duration >= 1 else { throw ImportError.silent }
            record.duration = duration
            MeetingStore.shared.save(record)

            // 2. What was said.
            update(id) { $0.stage = .writing }
            var creeping = creep(id, .writing, seconds: 8 + duration / 50)
            let timed = try await SpeechEngine.shared.transcribeFile(audio, with: language)
            creeping.cancel()
            try Task.checkCancellation()
            var words = timed.map { MeetingWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
            guard !words.isEmpty else { throw ImportError.noSpeech }

            // 3. Who said it — and the names of voices you've named before.
            update(id) { $0.stage = .voices; $0.progress = Stage.voices.start }
            creeping = creep(id, .voices, seconds: 10 + duration / 25)
            let scores = try await VoiceTracker.score(file: audio, config: VoiceModels.final)
            _ = MeetingSession.assignSentences(&words, from: 0, scores: scores, final: true)
            let terms = VocabularyBoost.terms(from: Vocabulary.shared.entries.map(\.word))
            if !terms.isEmpty { words = await VocabularyBoost.shared.refine(words: words, audio: audio, terms: terms).words }
            let found = await VoiceMemory.shared.recognise(words: words, audio: audio, names: [:])
            creeping.cancel()
            try Task.checkCancellation()
            record.words = words
            for (speaker, match) in found {
                record.names[String(speaker)] = match.name
                record.recognized[String(speaker)] = match.score
            }
            record.refined = true
            record.finished = true
            MeetingStore.shared.save(record)

            // 4. The notes — written in the background like a meeting's; the card waits a
            // moment for them, then lets you open it.
            update(id) { $0.stage = .notes; $0.progress = Stage.notes.start }
            MeetingNotes.shared.summarize(record.id)
            for _ in 0..<240 where MeetingNotes.shared.writing.contains(record.id) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            update(id) { $0.stage = .done; $0.progress = 1 }
            Self.log.info("import: done, \(Int(duration)) s, \(words.count) words, \(Set(words.compactMap(\.speaker)).count) voices")
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            Self.log.error("import: \(error.localizedDescription, privacy: .public)")
            // Nothing half made is left in the list.
            if MeetingStore.shared.meetings.contains(where: { $0.id == record.id }) {
                MeetingStore.shared.delete(record.id)
            } else {
                try? FileManager.default.removeItem(at: MeetingStore.folder(for: record.id))
            }
            guard !cancelled else { return }
            update(id) {
                $0.stage = .failed
                $0.meeting = nil
                $0.error = (error as? ImportError)?.message ?? String(localized: "Filen kunde inte läsas: \(error.localizedDescription)")
            }
        }
    }

    enum ImportError: Error {
        case noSound, silent, noSpeech
        var message: String {
            switch self {
            case .noSound: return String(localized: "Filen har inget ljud.")
            case .silent: return String(localized: "Filen är för kort – under en sekund.")
            case .noSpeech: return String(localized: "Inget tal hördes i filen.")
            }
        }
    }

    // MARK: The sound

    /// Reads the file's sound — any format macOS can, video too — as 16 kHz mono into
    /// `out`, as a meeting records it. Returns its length in seconds.
    nonisolated static func readSound(from url: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let length = (try? await asset.load(.duration)) ?? .zero
        guard !tracks.isEmpty else { throw ImportError.noSound }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw ImportError.noSound }
        reader.add(output)
        let file = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard reader.startReading() else { throw reader.error ?? ImportError.noSound }
        let total = max(1, length.seconds)
        var written = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = pcm.floatChannelData?[0] else { continue }
            pcm.frameLength = AVAudioFrameCount(count)
            _ = channel.withMemoryRebound(to: UInt8.self, capacity: bytes) { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw)
            }
            try file.write(from: pcm)
            written += count
            progress(min(1, Double(written) / 16_000 / total))
        }
        if reader.status == .failed { throw reader.error ?? ImportError.noSound }
        file.close()
        return Double(written) / 16_000
    }

    /// When it was recorded: what the file itself says (a phone's video, a voice memo),
    /// else when the file was made, else now — never in the future.
    nonisolated static func recordedDate(_ url: URL) async -> Date {
        let now = Date()
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue), date < now {
            return date
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let created = attributes[.creationDate] as? Date, created < now {
            return created
        }
        return now
    }
}
