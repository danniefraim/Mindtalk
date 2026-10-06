import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

// MARK: - Bättre anteckningar
//
// An optional, larger model for meeting notes and answers: Google's Gemma 4
// 26B-A4B (Apache 2.0), 4-bit, run on the Mac through Apple's MLX. In tests on
// real Swedish meetings it found every decision and task the small Apple
// Intelligence model missed or invented, answered more fully, and — unlike
// Apple's model — doesn't refuse a meeting for its topic.
//
// Only offered where it runs well: Apple Silicon with at least 32 GB of memory
// (it uses about 17 GB while writing). Downloaded once, like the speech models:
// a pinned revision, every file checked against its SHA-256. Loaded only to
// write, and let go again two minutes later.

@MainActor
final class BetterNotes: ObservableObject {
    static let shared = BetterNotes()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "BetterNotes")

    enum State: Equatable {
        /// This Mac has too little memory.
        case unsupported
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State
    /// Installed, but you can still choose Apple Intelligence.
    @Published var enabled = UserDefaults.standard.object(forKey: "betterNotes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "betterNotes") }
    }
    private(set) var downloadStarted: Date?
    /// Where this try began (0 unless an earlier one got part of the way).
    private(set) var downloadBase: Double?
    private var task: Task<Void, Never>?

    /// In use for the next notes.
    var isActive: Bool { state == .ready && enabled }

    // MARK: The model

    nonisolated static let modelName = "Gemma 4 26B-A4B"
    nonisolated static let credit = "Google DeepMind (Apache 2.0)"
    nonisolated static let repo = "lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit"
    nonisolated static let revision = "79290e197d238113e50abe4cbd4731b65288f88e"
    nonisolated static let modelPage = URL(string: "https://huggingface.co/google/gemma-4-26B-A4B-it")!

    nonisolated static let files: [SpeechModel.RemoteFile] = [
        .init(path: "README.md", size: 2295, sha256: "af123d57b54edaab319a6c2a8e3d2a448b3720fcca18bfbeff7f57888efa7c73"),
        .init(path: "chat_template.jinja", size: 16448, sha256: "85a08664d16d8f3be4416c92427b3ac10df1024ac566cc0b4bc3bab409393f98"),
        .init(path: "config.json", size: 33381, sha256: "a64883e3afd8e8b76e7370ba1b288f6f2dc9a0e071337c9eddb420b747555209"),
        .init(path: "generation_config.json", size: 208, sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
        .init(path: "model-00001-of-00003.safetensors", size: 5275612587, sha256: "6a6cba167e5c630a69b527b2b095c0da623507511e43c05a57c5527d9b66fa0d"),
        .init(path: "model-00002-of-00003.safetensors", size: 5296718232, sha256: "922461e4da8c9e3ae2dc5e4f0ccedf5a0259f1e81d3ebda20b3af39e28118f33"),
        .init(path: "model-00003-of-00003.safetensors", size: 5036507755, sha256: "2e92af87837744c385101b71883b4af898be7a6ce03e5babca475899a8268347"),
        .init(path: "model.safetensors.index.json", size: 176940, sha256: "5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80"),
        .init(path: "processor_config.json", size: 902, sha256: "1bd0d00776284f369c1eff5fb631e865dfcdca861e0b7d60dbef27fcf37436a8"),
        .init(path: "tokenizer.json", size: 32169626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        .init(path: "tokenizer_config.json", size: 21819, sha256: "c3d077c8c65a5734a2a22361e8718c83bd4bff1f114f65c1c9558419cbf816e2"),
    ]

    nonisolated static var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    nonisolated static var sizeText: String { String(format: "%.1f GB", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",") }

    nonisolated static var directory: URL {
        SpeechModel.rootDirectory.appendingPathComponent("Notes/gemma-4-26b-a4b-\(revision.prefix(8))")
    }

    // MARK: This Mac

    nonisolated static let minimumMemoryGB = 32
    nonisolated static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }
    nonisolated static var supported: Bool { memoryGB >= minimumMemoryGB }

    /// Free space for something you asked for (counts what macOS can clear).
    nonisolated static var freeBytes: Int64 {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Where an unfinished download waits to be continued.
    nonisolated static var staging: URL {
        directory.deletingLastPathComponent().appendingPathComponent(".staging-gemma-\(revision.prefix(8))")
    }

    /// What's still to fetch — less when an earlier try got part of it.
    nonisolated static var remainingBytes: Int64 { max(0, bytes - ModelDownload.allocatedBytes(in: staging)) }

    /// Room for what's left and 2 GB to spare.
    nonisolated static var hasRoom: Bool { freeBytes > remainingBytes + 2_000_000_000 }

    nonisolated private static let completeMarker = ".complete"
    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(completeMarker).path)
    }

    private init() {
        state = !Self.supported ? .unsupported : Self.isInstalled ? .ready : .missing
    }

    // MARK: Download

    func download() {
        guard Self.supported, task == nil else { return }
        guard Self.hasRoom else {
            state = .failed(String(localized: "Det behövs \(Self.sizeText) ledigt på disken, och lite till."))
            return
        }
        state = .downloading(0)
        downloadStarted = Date()
        downloadBase = nil
        task = Task {
            defer { task = nil }
            do {
                try await Self.install { p in
                    Task { @MainActor in
                        if case .downloading = BetterNotes.shared.state {
                            if BetterNotes.shared.downloadBase == nil { BetterNotes.shared.downloadBase = p }
                            BetterNotes.shared.state = .downloading(p)
                        }
                    }
                }
                state = .ready
                Self.log.info("installed")
            } catch is CancellationError {
                state = .missing
            } catch {
                Self.log.error("download: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .missing
    }

    func remove() {
        Task {
            await LocalWriter.shared.unload()
            try? FileManager.default.removeItem(at: Self.directory)
            try? FileManager.default.removeItem(at: Self.staging)
            state = Self.supported ? .missing : .unsupported
        }
    }

    /// Downloads every file to a staging folder, checks it, and moves the folder into
    /// place only when all are in — a half download is never mistaken for a model.
    nonisolated private static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // The same folder every try, kept when one stops: the next continues it.
        let staging = Self.staging
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var done: Int64 = 0
        let total = Double(bytes)
        for file in files {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(file.path)
            let base = done
            try await SpeechModel.download(repo: repo, revision: revision, file: file, to: dest) { written in
                progress(Double(base + written) / total)
            }
            done += file.size
        }
        try Data().write(to: staging.appendingPathComponent(completeMarker))
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: staging, to: directory)
        progress(1)
    }
}

/// Runs the model: loaded when notes are to be written, unloaded when idle, so the
/// 17 GB it takes are only in use while it writes.
actor LocalWriter {
    static let shared = LocalWriter()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "BetterNotes")

    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?

    /// One answer, at temperature 0 (the same text for the same meeting), thinking off.
    func respond(_ prompt: String, maxTokens: Int = 800) async throws -> String {
        let model = try await load()
        unloadTask?.cancel()
        defer { scheduleUnload() }
        let session = ChatSession(model,
                                  generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
                                  additionalContext: ["enable_thinking": false])
        let t0 = Date()
        let text = try await session.respond(to: prompt)
        Self.log.info("wrote in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
        return text
    }

    func unload() {
        unloadTask?.cancel()
        loading?.cancel()
        loading = nil
        container = nil
        MLX.GPU.clearCache()
    }

    private func load() async throws -> ModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task { () async throws -> ModelContainer in
            // Keep memory for the model, not for a cache of old buffers.
            MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
            let t0 = Date()
            let model = try await loadModelContainer(from: BetterNotes.directory, using: TokenizerFolder())
            Self.log.info("loaded in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            return model
        }
        loading = task
        defer { loading = nil }
        let model = try await task.value
        container = model
        return model
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }
}

/// The model's tokenizer, read from its folder by swift-transformers, in MLX's terms.
private struct TokenizerFolder: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
