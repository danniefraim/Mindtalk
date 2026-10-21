import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

// MARK: - Bättre sammanfattningar
//
// Optional, larger models for meeting summaries and answers, run on the Mac through
// Apple's MLX — Google's Gemma 4 (Apache 2.0), 4-bit, in two sizes:
//
//   • Gemma 4 E4B — about 7 GB, for Macs with 16 GB of memory or more.
//   • Gemma 4 26B-A4B — about 16 GB, for 32 GB or more. In tests on real Swedish
//     meetings it found every decision and task the small Apple Intelligence model
//     missed or invented, and — unlike Apple's model — doesn't refuse a meeting for
//     its topic.
//
// You choose which writes: Apple Intelligence (built in), or one you've downloaded.
// Each is downloaded once, like the speech models: a pinned revision, every file
// checked. Loaded only to write, and let go again two minutes later.

/// One of the downloadable notes models.
enum NotesModel: String, CaseIterable, Identifiable, Sendable {
    case small = "e4b"
    case large = "a4b26"

    nonisolated var id: String { rawValue }

    nonisolated var name: String {
        switch self {
        case .small: return "Gemma 4 E4B"
        case .large: return "Gemma 4 26B"
        }
    }

    nonisolated var repo: String {
        switch self {
        case .small: return "lmstudio-community/gemma-4-E4B-it-MLX-4bit"
        case .large: return "lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit"
        }
    }

    nonisolated var revision: String {
        switch self {
        case .small: return "ce713a0013bb7090305edfb8e3773a07ccae35c1"
        case .large: return "79290e197d238113e50abe4cbd4731b65288f88e"
        }
    }

    nonisolated var page: URL {
        switch self {
        case .small: return URL(string: "https://huggingface.co/google/gemma-4-E4B-it")!
        case .large: return URL(string: "https://huggingface.co/google/gemma-4-26B-A4B-it")!
        }
    }

    /// Memory it needs to write well, with the speech models running beside it.
    nonisolated var minimumMemoryGB: Int {
        switch self {
        case .small: return 16
        case .large: return 32
        }
    }

    nonisolated var files: [SpeechModel.RemoteFile] {
        switch self {
        case .small: return [
            .init(path: "README.md", size: 2267, sha256: "git:389dd0c0598ee66aa512237733cfb244bb918e29"),
            .init(path: "chat_template.jinja", size: 16317, sha256: "git:07e50e69a8c445f2c31a089b828e85b2a93942bf"),
            .init(path: "config.json", size: 36493, sha256: "git:e2528534df634937cf275c3721fb22a3abd12e46"),
            .init(path: "generation_config.json", size: 208, sha256: "git:e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6"),
            .init(path: "model-00001-of-00002.safetensors", size: 4280494809, sha256: "e58e5ed66324cdc0ce22f51d4d71a9b2db8c24f666278d1b71c3440a18c0f163"),
            .init(path: "model-00002-of-00002.safetensors", size: 2548805689, sha256: "5ae9ab6d6e86dd4d8f7eb6957eb7ad151121431df3855516e89c185824d640cf"),
            .init(path: "model.safetensors.index.json", size: 295363, sha256: "git:78e04d32002516ad758d44c5d55323b9b13e1f57"),
            .init(path: "processor_config.json", size: 902, sha256: "git:13e92a44d19566f334d7450e7898935e16e16f3d"),
            .init(path: "tokenizer.json", size: 32169626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            .init(path: "tokenizer_config.json", size: 21700, sha256: "git:1e7b23af17a6274bb5fdc3fd40e92ad893f7f0e2"),
        ]
        case .large: return [
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
        }
    }

    nonisolated var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    nonisolated var sizeText: String { BetterNotes.gigabytes(bytes) }

    /// "gemma-4-e4b-ce713a00".
    nonisolated var folderName: String {
        switch self {
        case .small: return "gemma-4-e4b-\(revision.prefix(8))"
        case .large: return "gemma-4-26b-a4b-\(revision.prefix(8))"
        }
    }

    nonisolated var directory: URL { SpeechModel.rootDirectory.appendingPathComponent("Notes/\(folderName)") }
    /// Where an unfinished download waits to be continued.
    nonisolated var staging: URL {
        // The large one keeps the name it had, so a download begun before goes on.
        SpeechModel.rootDirectory.appendingPathComponent(self == .large ? "Notes/.staging-gemma-\(revision.prefix(8))" : "Notes/.staging-\(folderName)")
    }
    nonisolated var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(BetterNotes.completeMarker).path)
    }
    nonisolated var supported: Bool { BetterNotes.memoryGB >= minimumMemoryGB }
    /// What's still to fetch — less when an earlier try got part of it.
    nonisolated var remainingBytes: Int64 { max(0, bytes - ModelDownload.allocatedBytes(in: staging)) }
    /// Room for what's left and 2 GB to spare.
    nonisolated var hasRoom: Bool { BetterNotes.freeBytes > remainingBytes + 2_000_000_000 }
    /// The largest this Mac runs well that is here or has room on the disk; when none
    /// has room, the largest it runs. Nil only on a Mac with too little memory for any.
    nonisolated static var recommended: NotesModel? {
        allCases.last { $0.supported && ($0.isInstalled || $0.hasRoom) } ?? allCases.last { $0.supported }
    }
}

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

    @Published private(set) var states: [NotesModel: State] = [:]
    /// Which writes the summaries: Apple Intelligence, one of the Gemmas, or your own
    /// model in Ollama or LM Studio (SummaryWriter.swift).
    @Published var choice: SummaryWriterChoice = .apple {
        didSet {
            // In the system log, so a summary by the wrong writer can be traced.
            Self.log.notice("writer chosen: \(self.choice.stored, privacy: .public), was \(oldValue.stored, privacy: .public)")
            let defaults = UserDefaults.standard
            defaults.set(choice.stored, forKey: "summaryWriter")
            // As the versions before kept it (a server model reads as Apple to them).
            defaults.set(chosen?.rawValue ?? "apple", forKey: "notesModel")
            if case .server(let backend, let model) = choice, choice != oldValue {
                defaults.set(model, forKey: "serverModel.\(backend.rawValue)")
                LocalServers.shared.prewarm(backend, model)
            }
        }
    }
    /// The Gemma chosen, or nil: Apple Intelligence or a server model.
    var chosen: NotesModel? {
        get { if case .gemma(let m) = choice { return m }; return nil }
        set { choice = newValue.map { .gemma($0) } ?? .apple }
    }
    private(set) var downloadStarted: Date?
    /// Where this try began (0 unless an earlier one got part of the way).
    private(set) var downloadBase: Double?
    private var task: Task<Void, Never>?
    private var downloadingModel: NotesModel?

    func state(_ model: NotesModel) -> State { states[model] ?? .missing }

    /// The Gemma writing the next notes — nil: Apple Intelligence or a server model.
    /// Asked of the disk too: one moved to the Trash in Finder writes nothing.
    var active: NotesModel? {
        guard let chosen, state(chosen) == .ready, chosen.isInstalled else { return nil }
        return chosen
    }
    /// The server model chosen, if one is.
    var server: (backend: ServerBackend, model: String)? {
        if case .server(let b, let m) = choice { return (b, m) }
        return nil
    }
    /// Who writes the next notes, unless it's Apple Intelligence (nil). The one chosen,
    /// whether it can write right now or not: a Gemma moved to the Trash, or a server
    /// that isn't running, says so when asked to write. Never another writer instead.
    var writer: (any SummaryWriter)? {
        switch choice {
        case .apple: return nil
        case .gemma(let m): return GemmaWriter(model: m)
        case .server(let b, let m): return LocalServerWriter(backend: b, model: m)
        }
    }
    /// Something other than Apple Intelligence is chosen to write.
    var isActive: Bool { choice != .apple }
    /// "Gemma 4 E4B", "Ollama · qwen3.5:9b", or "Apple Intelligence".
    var writerName: String { writer?.name ?? "Apple Intelligence" }
    /// The same in a sentence: "qwen3.5:9b i Ollama".
    var writerSentenceName: String { writer?.sentenceName ?? "Apple Intelligence" }

    nonisolated static let credit = "Google DeepMind (Apache 2.0)"
    nonisolated static let completeMarker = ".complete"

    // MARK: This Mac

    nonisolated static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Free space for something you asked for (counts what macOS can clear).
    nonisolated static var freeBytes: Int64 {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// "6,9 GB" — "6.9 GB" when the app runs in English.
    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale)) + " GB"
    }

    private init() {
        for model in NotesModel.allCases {
            states[model] = !model.supported ? .unsupported : model.isInstalled ? .ready : .missing
        }
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "summaryWriter") {
            if let c = SummaryWriterChoice(stored: saved) {
                choice = c
            } else {
                // Not understood (a newer version's choice?): Apple Intelligence writes,
                // but what was saved stays as it is, for the version that wrote it.
                Self.log.error("writer at launch: stored choice \(saved, privacy: .public) not understood, Apple Intelligence writes")
            }
        } else if let saved = defaults.string(forKey: "notesModel") {
            chosen = NotesModel(rawValue: saved)
        } else {
            // From before there were two: the large one, on unless it was switched off.
            let wasOn = defaults.object(forKey: "betterNotes") as? Bool ?? true
            chosen = wasOn && NotesModel.large.isInstalled ? .large : nil
        }
        Self.log.notice("writer at launch: \(self.choice.stored, privacy: .public)")
    }

    /// The Gemmas as they are on disk: one moved to the Trash in Finder is no longer
    /// ready, one put back is. Asked when the app comes to the front and when the card
    /// appears; a download on its way is left as it is.
    func refresh() {
        for model in NotesModel.allCases where model.supported {
            switch state(model) {
            case .ready where !model.isInstalled: states[model] = .missing
            case .missing where model.isInstalled, .failed where model.isInstalled: states[model] = .ready
            default: break
            }
        }
    }

    // MARK: Download

    var downloading: NotesModel? { downloadingModel }

    func download(_ model: NotesModel) {
        guard model.supported, task == nil else { return }
        guard model.hasRoom else {
            states[model] = .failed(String(localized: "Det behövs drygt \(model.sizeText) ledigt på disken."))
            return
        }
        states[model] = .downloading(0)
        downloadingModel = model
        downloadStarted = Date()
        downloadBase = nil
        generation += 1
        let mine = generation, before = unwinding
        task = Task {
            // A cancelled download finishes unwinding first: two never write the same files.
            await before?.value
            defer { if generation == mine { task = nil; downloadingModel = nil } }
            do {
                try await Self.install(model) { p in
                    Task { @MainActor in
                        let notes = BetterNotes.shared
                        if case .downloading(let sofar) = notes.state(model) {
                            if notes.downloadBase == nil { notes.downloadBase = p }
                            // Parts land out of order: the number never ticks backwards.
                            notes.states[model] = .downloading(max(sofar, p))
                        }
                    }
                }
                if generation == mine {
                    states[model] = .ready
                    // Downloaded to be used, in place of Apple Intelligence or a Gemma
                    // no longer on the disk. Another Gemma that is here, or a model in
                    // Ollama or LM Studio you picked, stays picked.
                    if active == nil, server == nil { chosen = model }
                }
                Self.log.info("installed \(model.rawValue, privacy: .public)")
            } catch is CancellationError {
                if generation == mine { states[model] = .missing }
            } catch {
                Self.log.error("download: \(error.localizedDescription, privacy: .public)")
                if generation == mine { states[model] = .failed(Dictation.plainWords(for: error)) }
            }
        }
    }

    /// Which download is the current one — an older, cancelled one may still be unwinding.
    private var generation = 0
    private var unwinding: Task<Void, Never>?

    func cancel() {
        generation += 1
        task?.cancel()
        unwinding = task
        task = nil
        if let model = downloadingModel { states[model] = .missing }
        downloadingModel = nil
    }

    func remove(_ model: NotesModel) {
        Task {
            await LocalWriter.shared.unload()
            try? FileManager.default.removeItem(at: model.directory)
            try? FileManager.default.removeItem(at: model.staging)
            states[model] = model.supported ? .missing : .unsupported
            if chosen == model { chosen = successor(of: model) }
        }
    }

    /// The Gemma that writes once `model` is removed: the other one, if it is here.
    /// Nil: Apple Intelligence.
    func successor(of model: NotesModel) -> NotesModel? {
        NotesModel.allCases.last { $0 != model && state($0) == .ready && $0.isInstalled }
    }

    /// Downloads every file to a staging folder, checks it, and moves the folder into
    /// place only when all are in — a half download is never mistaken for a model.
    nonisolated private static func install(_ model: NotesModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let directory = model.directory
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The same folder every try, kept when one stops: the next continues it.
        let staging = model.staging
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var done: Int64 = 0
        let total = Double(model.bytes)
        for file in model.files {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(file.path)
            let base = done
            try await SpeechModel.download(repo: model.repo, revision: model.revision, file: file, to: dest) { written in
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
    /// Which model's folder `container` was loaded from — another chosen means a reload.
    private var loadedFrom: URL?
    /// A load on its way: for which folder, and which load it is (a newer one may replace it).
    private var loading: (directory: URL, id: UUID, task: Task<ModelContainer, Error>)?
    private var unloadTask: Task<Void, Never>?
    /// Answers being written now: the model isn't unloaded under any of them.
    private var inFlight = 0

    /// One answer, at temperature 0 (the same text for the same meeting), thinking off.
    /// `model`: which Gemma; nil for the one chosen.
    func respond(_ prompt: String, model which: NotesModel? = nil, maxTokens: Int = 800) async throws -> String {
        inFlight += 1
        unloadTask?.cancel()
        defer {
            inFlight -= 1
            scheduleUnload()
        }
        let model = try await load(which)
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
        loading?.task.cancel()
        loading = nil
        dropModel()
    }

    private func dropModel() {
        container = nil
        loadedFrom = nil
        MLX.GPU.clearCache()
    }

    private func load(_ which: NotesModel? = nil) async throws -> ModelContainer {
        let chosen = which?.isInstalled == true ? which : await MainActor.run(body: { BetterNotes.shared.active })
        guard let directory = chosen?.directory else { throw ModelError.notInstalled }
        if let container, loadedFrom == directory { return container }
        // Already being loaded: wait for that one, rather than starting over.
        if let loading {
            if loading.directory == directory { return try await loading.task.value }
            // Another model chosen meanwhile: that load goes.
            loading.task.cancel()
            self.loading = nil
        }
        if loadedFrom != nil { dropModel() }      // another model was loaded
        let id = UUID()
        let task = Task { () async throws -> ModelContainer in
            // Keep memory for the model, not for a cache of old buffers.
            MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
            let t0 = Date()
            let model = try await loadModelContainer(from: directory, using: TokenizerFolder())
            Self.log.info("loaded in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            return model
        }
        loading = (directory, id, task)
        // Only this load's own: a newer one started meanwhile is left alone.
        defer { if loading?.id == id { loading = nil } }
        let model = try await task.value
        if loading?.id == id {
            container = model
            loadedFrom = directory
        }
        return model
    }

    /// Unloaded two minutes after the last answer — never while one is being written.
    private func scheduleUnload() {
        unloadTask?.cancel()
        guard inFlight == 0 else { return }
        unloadTask = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, self.inFlight == 0 else { return }
            self.unload()
        }
    }
}

/// The model's tokenizer, read from its folder by swift-transformers, in MLX's terms.
struct TokenizerFolder: MLXLMCommon.TokenizerLoader {
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
