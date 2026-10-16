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

    @Published private(set) var state: State = .missing

    static let live = Nemotron3Config.fast32
    static let final = Nemotron3Config.fast128
    /// Both bundles, rounded — shown before downloading.
    static let sizeText = "400 MB"
    private static let downloadBytes: Int64 = 400_000_000

    static var directory: URL { SpeechModel.rootDirectory.appendingPathComponent("Voices") }
    private static var repoDirectory: URL { directory.appendingPathComponent("nemotron-3-diarization") }

    private init() { state = Self.isInstalled ? .ready : .missing }

    static var isInstalled: Bool {
        let fm = FileManager.default
        let bundles = [live, final].map {
            repoDirectory.appendingPathComponent("\($0.hubSubdirectory)/\($0.modelFileName)/coremldata.bin")
        }
        return bundles.allSatisfy { fm.fileExists(atPath: $0.path) }
            && fm.fileExists(atPath: repoDirectory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile).path)
    }

    func download() {
        if case .downloading = state { return }
        // Room for the download and for preparing it for this Mac, with some to spare
        // (as for the speech models).
        guard BetterNotes.freeBytes > Self.downloadBytes * 2 + 500_000_000 else {
            state = .failed(String(localized: "Det behövs drygt \(BetterNotes.gigabytes(Self.downloadBytes * 2)) ledigt på disken."))
            return
        }
        state = .downloading(0)
        Task {
            do {
                for (i, config) in [Self.live, Self.final].enumerated() {
                    _ = try await Nemotron3Models.loadFromHuggingFace(
                        config: config, cacheDirectory: Self.directory,
                        progressHandler: { progress in
                            let total = (Double(i) + progress.fractionCompleted) / 2
                            Task { @MainActor in
                                if case .downloading = VoiceModels.shared.state { VoiceModels.shared.state = .downloading(total) }
                            }
                        })
                }
                state = Self.isInstalled ? .ready : .failed(String(localized: "Nedladdningen blev inte komplett."))
            } catch {
                state = .failed(Self.plainWords(for: error))
            }
        }
    }

    /// A failed download in words anyone understands, not the system's.
    private static func plainWords(for error: Error) -> String {
        switch Dictation.DownloadTrouble(error) {
        case .offline: return String(localized: "Ingen internetanslutning – försök igen när du är uppkopplad.")
        case .diskFull: return String(localized: "Det finns inte plats på disken.")
        case .unreachable, .other: return String(localized: "Röstmodellen kunde inte laddas ned – försök igen.")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.directory)
        state = .missing
    }

    /// Loads a profile from disk (never downloads — check `isInstalled` first).
    /// Loaded once and kept: a meeting started right after another (or while its notes
    /// are being written) doesn't wait for them again — the first load after an update
    /// can take a minute while macOS prepares them for this Mac.
    nonisolated static func load(_ config: Nemotron3Config) async throws -> Nemotron3Models {
        try await ModelCache.shared.models(for: config).models
    }

    /// At launch, quietly: so the first meeting starts at once, also after an update.
    static func warmUp() {
        guard isInstalled else { return }
        let configs = [live, final]
        Task.detached(priority: .utility) {
            for config in configs { _ = try? await load(config) }
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
