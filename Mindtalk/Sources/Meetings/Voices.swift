import AVFoundation
import CoreML
import FluidAudio
import Foundation

// MARK: - Telling voices apart
//
// NVIDIA Nemotron 3 Diarization (OpenMDW 1.1), as converted to Core ML by
// FluidInference (FluidInference/nemotron-3-diarization-coreml): up to eight
// speakers, each 10 ms of audio scored for each of them.
//
//   • Live — the "fast32" profile: 2.9 s behind, well within how long a word
//     takes to be written down anyway.
//   • After the meeting — "fast128": 10 s windows, the one that counted the
//     speakers right in all of its reference meetings.
//
// Downloaded once, like the speech models, into Mindtalk's own model folder.

@MainActor
final class VoiceModels: ObservableObject {
    static let shared = VoiceModels()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing {
        didSet { Self.installedAt = nil }
    }
    /// `warm`, to watch: the start card waits for it before the round of names.
    @Published private(set) var isWarm = false
    /// A bundle's files are in and it's being prepared for this Mac (the bar would
    /// otherwise stand still at 50 % and 100 %).
    @Published private(set) var preparing = false

    static let live = Nemotron3Config.fast32
    static let final = Nemotron3Config.fast128
    /// Both bundles, rounded — shown before downloading.
    static let sizeText = "400 MB"
    static let downloadBytes: Int64 = 400_000_000
    /// The commit of FluidInference/nemotron-3-diarization-coreml that's fetched (pinned
    /// at launch, `ModelPins`): a changed upstream branch can't slip in other weights.
    static let revision = "25a90f97f254428d4b30374b76af9c74fdee8327"
    static let repo = "FluidInference/nemotron-3-diarization-coreml"

    static var directory: URL { SpeechModel.rootDirectory.appendingPathComponent("Voices") }
    private static var repoDirectory: URL { directory.appendingPathComponent("nemotron-3-diarization") }

    private init() { state = Self.checkInstalled() ? .ready : .missing }

    private static func bundle(_ config: Nemotron3Config) -> URL {
        repoDirectory.appendingPathComponent("\(config.hubSubdirectory)/\(config.modelFileName)")
    }

    /// Both bundles whole: the manifest and the weights of each, the silence embedding,
    /// and nothing left half-fetched (FluidAudio writes the manifest first, so a download
    /// that stopped at the weights would otherwise pass as installed).
    ///
    /// Read by the start card and the menu bar panel every time they're drawn (in a
    /// scroll, every frame): looked up on disk at most once a second, and again at once
    /// whenever the state changes (a download done, the model removed).
    static var isInstalled: Bool {
        if let at = installedAt, Date().timeIntervalSince(at) < 1 { return installed }
        installed = checkInstalled()
        installedAt = Date()
        return installed
    }
    private static var installed = false
    private static var installedAt: Date?

    /// On disk, now: where a download or a removal needs the answer as it is.
    private static func checkInstalled() -> Bool {
        let fm = FileManager.default
        for config in [live, final] {
            let bundle = bundle(config)
            guard fm.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path),
                  fm.fileExists(atPath: bundle.appendingPathComponent("weights/weight.bin").path) else { return false }
        }
        return fm.fileExists(atPath: repoDirectory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile).path)
            && !hasUnfinishedFiles(in: repoDirectory)
    }

    /// A `.partial` or `.etag` somewhere under `folder`: a download that stopped midway.
    private static func hasUnfinishedFiles(in folder: URL) -> Bool {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in items where url.pathExtension == "partial" || url.pathExtension == "etag" { return true }
        return false
    }

    /// Before a download: a bundle whose manifest is in but whose weights aren't (or
    /// that still has a file half-fetched) loses its manifest, so FluidAudio fetches the
    /// bundle again rather than taking it for complete. A folder from before the revision
    /// was pinned (no marker, or another) goes whole, so both bundles come in one go
    /// instead of FluidAudio wiping it midway.
    private static func tidyBeforeDownload() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoDirectory.path), !checkInstalled() else { return }
        let marker = (try? String(contentsOf: repoDirectory.appendingPathComponent(".fluidaudio-revision"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if marker != revision {
            try? fm.removeItem(at: repoDirectory)
            return
        }
        for config in [live, final] {
            let bundle = bundle(config)
            let whole = fm.fileExists(atPath: bundle.appendingPathComponent("weights/weight.bin").path) && !hasUnfinishedFiles(in: bundle)
            if !whole { try? fm.removeItem(at: bundle.appendingPathComponent("coremldata.bin")) }
        }
    }

    func download() {
        if case .downloading = state { return }
        // Room for the download and for preparing it for this Mac, with some to spare
        // (as for the speech models).
        guard BetterNotes.freeBytes > Self.downloadBytes * 2 + 500_000_000 else {
            state = .failed(String(localized: "Det behövs drygt \(DiskSize.text(Self.downloadBytes * 2)) ledigt på disken."))
            return
        }
        Self.tidyBeforeDownload()
        state = .downloading(0)
        preparing = false
        Task {
            do {
                for (i, config) in [Self.live, Self.final].enumerated() {
                    // Already fetched by an earlier try: no progress comes, it's only prepared.
                    preparing = FileManager.default.fileExists(atPath: Self.bundle(config).appendingPathComponent("coremldata.bin").path)
                    let models = try await Nemotron3Models.loadFromHuggingFace(
                        config: config, cacheDirectory: Self.directory,
                        progressHandler: { progress in
                            let fraction = progress.fractionCompleted
                            let total = (Double(i) + fraction) / 2
                            Task { @MainActor in
                                let shared = VoiceModels.shared
                                guard case .downloading(let sofar) = shared.state else { return }
                                shared.state = .downloading(max(sofar, total))
                                shared.preparing = fraction >= 0.999
                            }
                        })
                    // Loaded once here; kept, so warming up doesn't load it a second time.
                    await ModelCache.shared.put(models, for: config)
                }
                preparing = false
                state = Self.checkInstalled() ? .ready : .failed(String(localized: "Nedladdningen blev inte klar."))
                // Prepared for this Mac right away, so the first meeting doesn't wait for it.
                if state == .ready { Self.warmUp() }
            } catch {
                preparing = false
                state = .failed(Self.plainWords(for: error))
            }
        }
    }

    /// A failed download in words anyone understands, not the system's — the same
    /// words as for the speech models, with one of its own for the unknown case.
    private static func plainWords(for error: Error) -> String {
        if case .other = Dictation.DownloadTrouble(error) {
            return String(localized: "Röstmodellen kunde inte laddas ned. Försök igen.")
        }
        return Dictation.plainWords(for: error)
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.directory)
        state = .missing
        preparing = false
        Self.warm = false
        isWarm = false
        Task { await ModelCache.shared.clear() }
    }

    /// Loads a profile from disk (never downloads — check `isInstalled` first).
    /// Loaded once and kept: a meeting started right after another (or while its notes
    /// are being written) doesn't wait for them again — the first load after an update
    /// can take a minute while macOS prepares them for this Mac.
    nonisolated static func load(_ config: Nemotron3Config) async throws -> Nemotron3Models {
        try await ModelCache.shared.models(for: config).models
    }

    /// Loaded and prepared for this Mac, this launch: a meeting starts at once.
    @MainActor static private(set) var warm = false

    /// At launch (and right after the download), quietly: so the first meeting starts
    /// at once, also after an update. The speech model's own Neural Engine preparation
    /// waits for this (SpeechEngine): macOS prepares one model at a time.
    static func warmUp() {
        guard isInstalled else { return }
        let configs = [live, final]
        Task.detached(priority: .utility) {
            for config in configs { _ = try? await load(config) }
            await MainActor.run { warm = true; VoiceModels.shared.isWarm = true }
        }
    }
}

/// The voice models, loaded once per kind and shared; two meetings asking at once
/// wait for the same load rather than doing it twice.
private actor ModelCache {
    static let shared = ModelCache()
    private var loaded: [String: Loaded] = [:]
    private var loading: [String: Task<Loaded, Error>] = [:]

    /// The models are only read once loaded (each meeting's diarizer keeps its own
    /// state), so they can be handed out to every meeting.
    struct Loaded: @unchecked Sendable { let models: Nemotron3Models }

    func models(for config: Nemotron3Config) async throws -> Loaded {
        let key = "\(config)"
        if let models = loaded[key] { return models }
        if let task = loading[key] { return try await task.value }
        let task = Task {
            Loaded(models: try await Nemotron3Models.loadFromHuggingFace(config: config, cacheDirectory: VoiceModels.directory))
        }
        loading[key] = task
        defer { loading[key] = nil }
        let models = try await task.value
        loaded[key] = models
        return models
    }

    /// Models the download just loaded: kept, so they aren't loaded again.
    func put(_ models: Nemotron3Models, for config: Nemotron3Config) {
        loaded["\(config)"] = Loaded(models: models)
    }

    /// After "Ta bort": nothing kept from the folder that's gone.
    func clear() {
        loaded = [:]
    }
}

// MARK: - Pinned revisions

/// The two models FluidAudio fetches itself (the voices, the word list's listener) are
/// pinned to one commit each, like the speech models Mindtalk fetches on its own: set
/// before anything else runs, so no call can go to a moving branch. A folder downloaded
/// before the pin (no revision marker) is fetched again once by FluidAudio when it next
/// checks the listener; the voices' folder is only read, never re-fetched, once whole.
enum ModelPins {
    static func apply() {
        ModelRegistry.revisionOverrides = [
            VoiceModels.repo: VoiceModels.revision,
            VocabularyBoost.repo: VocabularyBoost.revision,
        ]
    }
}

/// Scores who is speaking, 10 ms at a time. The diarizer isn't thread-safe, so it
/// lives in an actor of its own.
actor VoiceTracker {
    private let diarizer: Nemotron3Diarizer
    static let speakers = 8

    private init(diarizer: Nemotron3Diarizer) { self.diarizer = diarizer }

    static func make(_ config: Nemotron3Config) async throws -> VoiceTracker {
        let models = try await VoiceModels.load(config)
        return VoiceTracker(diarizer: Nemotron3Diarizer(config: config, models: models))
    }

    /// Feeds 16 kHz audio; returns the scores for every 10 ms now settled
    /// (`speakers` values per frame).
    func feed(_ samples: [Float]) throws -> [Float] {
        diarizer.appendAudio(samples)
        return try diarizer.processBufferedAudio().flatMap(\.probabilities)
    }

    /// The rest, at the end of the recording.
    func finish() throws -> [Float] {
        try diarizer.finishStream().flatMap(\.probabilities)
    }

    /// A whole recording, read from disk a minute at a time.
    static func score(file url: URL, config: Nemotron3Config) async throws -> [Float] {
        let tracker = try await make(config)
        let samples = try AudioChunks(url: url)
        var scores: [Float] = []
        while let chunk = try samples.next(seconds: 60) {
            try Task.checkCancellation()
            scores += try await tracker.feed(chunk)
        }
        scores += try await tracker.finish()
        return scores
    }
}

/// Reads a 16 kHz mono recording a piece at a time.
final class AudioChunks {
    private let file: AVAudioFile

    init(url: URL) throws { file = try AVAudioFile(forReading: url) }

    func next(seconds: Double) throws -> [Float]? {
        let frames = AVAudioFrameCount(seconds * file.processingFormat.sampleRate)
        guard file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        try file.read(into: buffer, frameCount: frames)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
