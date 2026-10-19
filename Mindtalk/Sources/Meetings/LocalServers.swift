import AppKit
import Foundation
import os

// MARK: - Ollama and LM Studio
//
// Your own model, on your Mac: if Ollama or LM Studio is installed, Mindtalk finds
// it, lists its models, and can let one of them write the summaries and answer
// questions about meetings. Everything still stays on the Mac:
//
//   • Every address is built in one place (LocalServerClient.url) from the literal
//     host 127.0.0.1 and the backend's port. No other host can be reached, whatever
//     the settings say. No redirects are followed, no proxy is used.
//   • Models that would leave the Mac are hidden: Ollama's cloud models (passed on
//     to ollama.com) are never listed.
//   • The model is told how much text to read (Ollama cuts long meetings silently
//     otherwise), and what it read is checked afterwards.

enum ServerBackend: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case lmStudio

    nonisolated var id: String { rawValue }

    nonisolated var name: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    nonisolated var defaultPort: Int {
        switch self {
        case .ollama: return 11434
        case .lmStudio: return 1234
        }
    }

    nonisolated var bundleID: String {
        switch self {
        case .ollama: return "com.electron.ollama"
        case .lmStudio: return "ai.elementlabs.lmstudio"
        }
    }

    /// Where to read about it when it isn't installed.
    nonisolated var site: URL {
        switch self {
        case .ollama: return URL(string: "https://ollama.com")!
        case .lmStudio: return URL(string: "https://lmstudio.ai")!
        }
    }

    /// The port Mindtalk talks to: the backend's own, unless changed under Avancerat.
    nonisolated var port: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: "serverPort.\(rawValue)")
            return (1...65_535).contains(saved) ? saved : defaultPort
        }
        nonmutating set {
            if newValue == defaultPort || !(1...65_535).contains(newValue) {
                UserDefaults.standard.removeObject(forKey: "serverPort.\(rawValue)")
            } else {
                UserDefaults.standard.set(newValue, forKey: "serverPort.\(rawValue)")
            }
        }
    }

    nonisolated var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// "Starta Ollama", "Öppna LM Studio" (LM Studio's server is started inside it).
    var openTitle: String {
        switch self {
        case .ollama: return String(localized: "Starta Ollama")
        case .lmStudio: return String(localized: "Öppna LM Studio")
        }
    }
}

enum ServerState: Equatable, Sendable {
    case running
    case installedNotRunning
    case notInstalled

    var title: String {
        switch self {
        case .running: return String(localized: "Igång")
        case .installedNotRunning: return String(localized: "Inte igång")
        case .notInstalled: return String(localized: "Finns inte")
        }
    }
}

/// A model one of the backends has on this Mac.
struct ServerModel: Identifiable, Hashable, Sendable {
    let backend: ServerBackend
    /// What the backend calls it in a request: "qwen3.5:9b", "google/gemma-4-26b-a4b".
    let id: String
    let bytes: Int64?
    /// The most it can read, in tokens, when known.
    let contextLength: Int?
    /// Ollama: the model can be told not to think (only those take `think`).
    let thinking: Bool
    /// LM Studio: loaded now, with this much context.
    let loadedContext: Int?

    var sizeText: String? { bytes.map { BetterNotes.gigabytes($0) } }
    /// "256k": thousands of tokens, as model pages write it.
    var contextText: String? { contextLength.map { Self.thousands($0) } }

    static func thousands(_ tokens: Int) -> String {
        tokens >= 1024 ? "\(tokens / 1024)k" : "\(tokens)"
    }

    /// "qwen3.5:9b · 7,6 GB · 256k"
    var title: String { [id, sizeText, contextText].compactMap { $0 }.joined(separator: " · ") }

    /// On EuroEval's Swedish list (the plan's table): gemma4 from 26B, mistral-small3.2,
    /// qwen3.5 from 9B, gpt-oss 20B, ministral-3 8B and 14B.
    var goodAtSwedish: Bool { Self.goodAtSwedish(id) }

    static func goodAtSwedish(_ name: String) -> Bool {
        let n = name.lowercased().split(separator: "/").last.map(String.init) ?? name.lowercased()
        func billions() -> Double? {
            // "9b", "26b-a4b", "3.2" is a version, not a size: the first "<number>b" after the family.
            guard let r = n.range(of: #"(\d+(?:\.\d+)?)b\b"#, options: .regularExpression) else { return nil }
            return Double(n[r].dropLast())
        }
        if n.contains("gemma4") || n.contains("gemma-4") { return (billions() ?? 0) >= 26 }
        if n.contains("mistral-small3.2") || n.contains("mistral-small-3.2") { return true }
        if n.contains("qwen3.5") { return (billions() ?? 0) >= 9 }
        if n.contains("gpt-oss") { return (billions() ?? 0) >= 20 }
        if n.contains("ministral-3") { return (billions() ?? 0) >= 8 }
        return false
    }
}

/// What went wrong, said plainly (the plan's wording).
enum ServerError: Error, Equatable {
    case notRunning(ServerBackend)
    case notInstalled(ServerBackend)
    case noModels(ServerBackend)
    case modelGone
    case noMemory
    case timeout
    /// The model read less than it was sent: a long meeting was cut.
    case truncated
    case noSources
    case failed(String)

    var plainWords: String {
        switch self {
        case .notRunning(.ollama): return String(localized: "Ollama är installerat men inte igång.")
        case .notRunning(.lmStudio): return String(localized: "LM Studio är installerat men inte igång.")
        case .notInstalled(.ollama): return String(localized: "Ollama finns inte på den här Macen.")
        case .notInstalled(.lmStudio): return String(localized: "LM Studio finns inte på den här Macen.")
        case .noModels(.ollama): return String(localized: "Det finns inga modeller i Ollama än.")
        case .noModels(.lmStudio): return String(localized: "Det finns inga modeller i LM Studio än.")
        case .modelGone: return String(localized: "Modellen finns inte längre. Välj en annan.")
        case .noMemory: return String(localized: "Modellen fick inte plats i minnet. Välj en mindre modell.")
        case .timeout: return String(localized: "Modellen svarade inte i tid.")
        case .truncated: return String(localized: "Modellen hann inte läsa hela mötet. Välj en modell som orkar mer text.")
        case .noSources: return String(localized: "Svaret saknade källor, så det visas inte.")
        case .failed: return String(localized: "Modellen kunde inte svara just nu. Försök igen om en stund.")
        }
    }
}

// MARK: - The one way out

/// Every request to Ollama or LM Studio goes through here: to 127.0.0.1 and the
/// backend's port, nowhere else, with no proxy and no redirects.
final class LocalServerClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LocalServerClient()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "LocalServers")
    private let session: URLSession

    private override init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        config.timeoutIntervalForRequest = 200
        config.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        super.init()
    }

    /// The only place an address is made: this Mac, the backend's port, the path.
    nonisolated static func url(_ backend: ServerBackend, _ path: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = backend.port
        parts.path = path
        return parts.url!
    }

    /// A redirect would lead elsewhere: refused.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        Self.log.error("refused a redirect from port \(self.backendName(of: task), privacy: .public)")
        completionHandler(nil)
    }

    private func backendName(of task: URLSessionTask) -> String {
        task.originalRequest?.url?.port.map { String($0) } ?? "?"
    }

    private func request(_ backend: ServerBackend, _ path: String, json: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: Self.url(backend, path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    /// A whole answer, as JSON. The status comes back with it: 404 says a model or
    /// an endpoint isn't there.
    func call(_ backend: ServerBackend, _ path: String, json: [String: Any]? = nil,
              timeout: TimeInterval = 5) async throws -> (status: Int, body: [String: Any]) {
        let request = try request(backend, path, json: json, timeout: timeout)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: self)
        } catch {
            throw Self.connectionError(error, backend)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, body)
    }

    /// A streamed answer, line by line: at most `firstToken` seconds to the first line,
    /// then `between` seconds to each next one. A non-200 answer is thrown, with what
    /// the server said.
    func stream(_ backend: ServerBackend, _ path: String, json: [String: Any], firstToken: TimeInterval = 180,
                between: TimeInterval = 60, onLine: @escaping @Sendable (String) throws -> Void) async throws {
        let request = try request(backend, path, json: json, timeout: firstToken + 10)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: self)
        } catch {
            throw Self.connectionError(error, backend)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 100_000 { break } }
            throw Self.serverError(status: status, body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        let watchdog = Watchdog(firstToken)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    watchdog.touch(between)
                    try onLine(line)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if watchdog.expired { throw ServerError.timeout }
                }
            }
            // The first to finish: the reader, done, or the watchdog, out of time.
            try await group.next()
            group.cancelAll()
        }
    }

    /// Nothing answered on the port: not running (or not here at all).
    nonisolated static func connectionError(_ error: Error, _ backend: ServerBackend) -> Error {
        if error is CancellationError { return error }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .timedOut, .badServerResponse:
                return backend.isInstalled ? ServerError.notRunning(backend) : ServerError.notInstalled(backend)
            case .cancelled: return CancellationError()
            default: break
            }
        }
        return ServerError.failed(error.localizedDescription)
    }

    /// What the server's refusal means.
    nonisolated static func serverError(status: Int, body: [String: Any]) -> ServerError {
        let message = (body["error"] as? String) ?? ((body["error"] as? [String: Any])?["message"] as? String) ?? ""
        let lower = message.lowercased()
        if status == 404 || lower.contains("not found") || lower.contains("no such model") || lower.contains("does not exist") {
            return .modelGone
        }
        if lower.contains("memory") || lower.contains("out of vram") || lower.contains("insufficient") {
            return .noMemory
        }
        log.error("server said \(status): \(message, privacy: .public)")
        return .failed(message.isEmpty ? "HTTP \(status)" : message)
    }

    /// When the last line came, and how long the next one may take.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: Date
        init(_ first: TimeInterval) { deadline = Date().addingTimeInterval(first) }
        func touch(_ between: TimeInterval) { lock.lock(); deadline = Date().addingTimeInterval(between); lock.unlock() }
        var expired: Bool { lock.lock(); defer { lock.unlock() }; return Date() > deadline }
    }
}

// MARK: - Finding them

/// Where Ollama and LM Studio stand on this Mac, and what models they have.
@MainActor
final class LocalServers: ObservableObject {
    static let shared = LocalServers()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "LocalServers")

    @Published private(set) var states: [ServerBackend: ServerState] = [:]
    @Published private(set) var models: [ServerBackend: [ServerModel]] = [:]
    /// Something a backend said, shown under its line ("Det finns inga modeller i Ollama än.").
    @Published private(set) var notes: [ServerBackend: String] = [:]
    @Published private(set) var probing: Set<ServerBackend> = []
    /// While a model writes: "Startar modellen", "Läser mötet", "Skriver".
    @Published private(set) var phase: Phase?
    /// "Testa": what the model answered, how long it took, and how much it reads.
    @Published private(set) var test: TestResult?
    @Published private(set) var testing: ServerBackend?
    /// The ports, published so Avancerat follows along.
    @Published var ports: [ServerBackend: Int] = [:] {
        didSet { for b in ServerBackend.allCases { if let p = ports[b], p != b.port { b.port = p } } }
    }

    enum Phase: Equatable {
        case starting, reading, writing
        var title: String {
            switch self {
            case .starting: return String(localized: "Startar modellen…")
            case .reading: return String(localized: "Läser mötet…")
            case .writing: return String(localized: "Skriver…")
            }
        }
    }

    struct TestResult: Equatable {
        let backend: ServerBackend
        let model: String
        let answer: String?
        let seconds: Double
        let context: Int
        /// The plain error, when it failed.
        let error: String?
    }

    #if DEBUG
    /// `--server-demo running|stopped|missing`: made-up states and models for the renders.
    static var demo: String?
    #endif

    private init() {
        for b in ServerBackend.allCases {
            states[b] = b.isInstalled ? .installedNotRunning : .notInstalled
            ports[b] = b.port
            if let saved = UserDefaults.standard.array(forKey: "serverModels.\(b.rawValue)") as? [[String: Any]] {
                models[b] = saved.compactMap { ServerModel(stored: $0, backend: b) }
            }
        }
        #if DEBUG
        if let demo = Self.demo { applyDemo(demo) }
        #endif
    }

    /// How much context this Mac affords a model, by its memory: 32k up to 16 GB,
    /// 64k at 32 GB, 128k above.
    nonisolated static var contextCap: Int {
        let gb = BetterNotes.memoryGB
        return gb <= 16 ? 32_768 : gb <= 32 ? 65_536 : 131_072
    }

    /// Memory nothing is using right now (free and inactive pages).
    nonisolated static var freeMemoryBytes: Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)
        return pages * Int64(vm_kernel_page_size)
    }

    func state(_ backend: ServerBackend) -> ServerState { states[backend] ?? .notInstalled }

    func model(_ backend: ServerBackend, _ id: String) -> ServerModel? { models[backend]?.first { $0.id == id } }

    /// The context a chosen model gets: what it can read, capped by this Mac's memory.
    func context(for backend: ServerBackend, model id: String) -> Int {
        min(model(backend, id)?.contextLength ?? 8_192, Self.contextCap)
    }

    /// Looks for both, and lists their models.
    func refresh() async {
        #if DEBUG
        if Self.demo != nil { return }
        #endif
        await withTaskGroup(of: Void.self) { group in
            for b in ServerBackend.allCases { group.addTask { await self.probe(b) } }
        }
    }

    /// Is it running? Then which models does it have.
    func probe(_ backend: ServerBackend) async {
        #if DEBUG
        if Self.demo != nil { return }
        #endif
        probing.insert(backend)
        defer { probing.remove(backend) }
        let installed = backend.isInstalled
        do {
            let found = try await Self.list(backend)
            states[backend] = .running
            models[backend] = found
            notes[backend] = found.isEmpty ? ServerError.noModels(backend).plainWords : nil
            UserDefaults.standard.set(found.map(\.stored), forKey: "serverModels.\(backend.rawValue)")
            Self.log.info("\(backend.name, privacy: .public): \(found.count) models")
        } catch let error as ServerError {
            states[backend] = installed ? .installedNotRunning : .notInstalled
            switch error {
            case .notRunning, .notInstalled: notes[backend] = nil
            default: notes[backend] = error.plainWords
            }
        } catch {
            states[backend] = installed ? .installedNotRunning : .notInstalled
            notes[backend] = nil
        }
    }

    /// Opens the app, then looks again for half a minute (Ollama's server comes up a
    /// few seconds after the app).
    func open(_ backend: ServerBackend) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: backend.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = backend == .lmStudio
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        Task {
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                await probe(backend)
                if state(backend) == .running { break }
            }
        }
    }

    /// Both backends' models: the model list, as the writer and the picker need it.
    nonisolated static func list(_ backend: ServerBackend) async throws -> [ServerModel] {
        switch backend {
        case .ollama: return try await ollamaModels()
        case .lmStudio: return try await lmStudioModels()
        }
    }

    /// Ollama's models, without the cloud ones: a model with a `remote_host`, or a
    /// `:cloud` / `-cloud` tag, is run by ollama.com and never listed.
    nonisolated private static func ollamaModels() async throws -> [ServerModel] {
        let (status, body) = try await LocalServerClient.shared.call(.ollama, "/api/tags", timeout: 3)
        guard status == 200, let list = body["models"] as? [[String: Any]] else {
            throw LocalServerClient.serverError(status: status, body: body)
        }
        var models: [ServerModel] = []
        for m in list {
            guard let name = (m["name"] as? String) ?? (m["model"] as? String) else { continue }
            if m["remote_host"] != nil || m["remote_model"] != nil { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(":cloud") || lower.contains("-cloud") || lower.contains(":cloud") { continue }
            let capabilities = (m["capabilities"] as? [String]) ?? ["completion"]
            // Embedding models and the like can't write.
            guard capabilities.contains("completion") else { continue }
            let details = m["details"] as? [String: Any] ?? [:]
            var context = (details["context_length"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            if context == nil { context = try? await ollamaContext(name) }
            models.append(ServerModel(backend: .ollama, id: name, bytes: (m["size"] as? NSNumber)?.int64Value,
                                      contextLength: context, thinking: capabilities.contains("thinking"), loadedContext: nil))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Older Ollama versions don't say the context in the list: asked for one model.
    nonisolated private static func ollamaContext(_ model: String) async throws -> Int? {
        let (status, body) = try await LocalServerClient.shared.call(.ollama, "/api/show", json: ["model": model], timeout: 5)
        guard status == 200, let info = body["model_info"] as? [String: Any] else { return nil }
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let n = (value as? NSNumber)?.intValue, n > 0 { return n }
        }
        return nil
    }

    /// LM Studio's language models. (Its list has no mark for models served from another
    /// computer, so all are shown; the request itself only ever goes to this Mac.)
    nonisolated private static func lmStudioModels() async throws -> [ServerModel] {
        let (status, body) = try await LocalServerClient.shared.call(.lmStudio, "/api/v1/models", timeout: 3)
        if status == 200, let list = (body["models"] as? [[String: Any]]) ?? (body["data"] as? [[String: Any]]) {
            return list.compactMap { m -> ServerModel? in
                guard let key = (m["key"] as? String) ?? (m["id"] as? String) else { return nil }
                if let type = m["type"] as? String, type != "llm" { return nil }
                let loaded = (m["loaded_instances"] as? [[String: Any]])?.first
                let loadedContext = ((loaded?["config"] as? [String: Any])?["context_length"] as? NSNumber)?.intValue
                let reasoning = ((m["capabilities"] as? [String: Any])?["reasoning"] as? [String: Any])?["allowed_options"] as? [String]
                return ServerModel(backend: .lmStudio, id: key, bytes: (m["size_bytes"] as? NSNumber)?.int64Value,
                                   contextLength: (m["max_context_length"] as? NSNumber)?.intValue,
                                   thinking: reasoning?.contains("off") ?? false, loadedContext: loadedContext)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        // An older LM Studio: only the OpenAI-style list, names only.
        let (status2, body2) = try await LocalServerClient.shared.call(.lmStudio, "/v1/models", timeout: 3)
        guard status2 == 200, let list = body2["data"] as? [[String: Any]] else {
            throw LocalServerClient.serverError(status: status2, body: body2)
        }
        return list.compactMap { m in
            (m["id"] as? String).map { ServerModel(backend: .lmStudio, id: $0, bytes: nil, contextLength: nil, thinking: false, loadedContext: nil) }
        }
    }

    // MARK: Using one

    /// A chosen model is loaded right away, so the first summary doesn't wait for it.
    func prewarm(_ backend: ServerBackend, _ model: String) {
        Task.detached(priority: .utility) {
            let writer = await LocalServerWriter(backend: backend, model: model)
            try? await writer.load()
        }
    }

    /// "Testa": two numbered lines in Swedish, one cited sentence back.
    func runTest(_ backend: ServerBackend, _ model: String) {
        guard testing == nil else { return }
        testing = backend
        test = nil
        Task {
            defer { testing = nil }
            let writer = LocalServerWriter(backend: backend, model: model)
            let t0 = Date()
            do {
                let text = try await writer.complete(system: """
                    You read a meeting transcript. Each line is "[n] Name: what they said". Answer in Swedish, in one \
                    sentence, in your own words, and end it with the number in brackets of the line it comes from.
                    """, user: """
                    Transcript:
                    [1] Anna: Vi behöver bestämma när vi lanserar.
                    [2] Johan: Jag föreslår den 14 november, då är allt klart.

                    Question: När föreslås lanseringen?
                    """, maxTokens: 80)
                let answer = MeetingNotes.tidy(text.trimmingCharacters(in: .whitespacesAndNewlines))
                test = TestResult(backend: backend, model: model, answer: answer.isEmpty ? nil : answer,
                                  seconds: Date().timeIntervalSince(t0), context: writer.contextTokens,
                                  error: answer.isEmpty ? ServerError.failed("empty").plainWords : nil)
            } catch {
                test = TestResult(backend: backend, model: model, answer: nil, seconds: Date().timeIntervalSince(t0),
                                  context: writer.contextTokens, error: LocalServerWriter.plainWords(error))
            }
        }
    }

    func setPhase(_ phase: Phase?) { self.phase = phase }

    func resetPorts() {
        for b in ServerBackend.allCases { ports[b] = b.defaultPort }
    }

    #if DEBUG
    private func applyDemo(_ demo: String) {
        let ollama = [
            ServerModel(backend: .ollama, id: "qwen3.5:9b", bytes: 7_639_229_431, contextLength: 262_144, thinking: true, loadedContext: nil),
            ServerModel(backend: .ollama, id: "gemma4:26b", bytes: 17_300_000_000, contextLength: 131_072, thinking: true, loadedContext: nil),
            ServerModel(backend: .ollama, id: "llama3.2:3b", bytes: 2_019_000_000, contextLength: 131_072, thinking: false, loadedContext: nil),
        ]
        switch demo {
        case "running":
            states = [.ollama: .running, .lmStudio: .installedNotRunning]
            models = [.ollama: ollama]
        case "stopped":
            states = [.ollama: .installedNotRunning, .lmStudio: .installedNotRunning]
        default:
            states = [.ollama: .notInstalled, .lmStudio: .notInstalled]
        }
    }
    #endif
}

extension ServerModel {
    /// Kept between launches, so a chosen model has its context before the server is asked again.
    var stored: [String: Any] {
        var d: [String: Any] = ["id": id, "thinking": thinking]
        if let bytes { d["bytes"] = bytes }
        if let contextLength { d["context"] = contextLength }
        return d
    }

    init?(stored: [String: Any], backend: ServerBackend) {
        guard let id = stored["id"] as? String else { return nil }
        self.init(backend: backend, id: id, bytes: (stored["bytes"] as? NSNumber)?.int64Value,
                  contextLength: (stored["context"] as? NSNumber)?.intValue, thinking: stored["thinking"] as? Bool ?? false,
                  loadedContext: nil)
    }
}

// MARK: - Writing with one

/// Your own model in Ollama or LM Studio as a writer: the whole meeting in one go
/// when it fits, told exactly how much to read, with thinking off and its answer
/// checked for what it read.
struct LocalServerWriter: SummaryWriter {
    let backend: ServerBackend
    let model: String
    let contextTokens: Int
    private let thinking: Bool
    private let loadedContext: Int?
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "LocalServers")

    #if DEBUG
    /// `--server-ctx 2048`: a context far too small, to see that a cut meeting is caught.
    nonisolated(unsafe) static var debugContext: Int?
    #endif

    @MainActor init(backend: ServerBackend, model: String) {
        self.backend = backend
        self.model = model
        let known = LocalServers.shared.model(backend, model)
        contextTokens = LocalServers.shared.context(for: backend, model: model)
        thinking = known?.thinking ?? false
        loadedContext = known?.loadedContext
    }

    var name: String { "\(backend.name) · \(model)" }
    let requiresSources = true

    /// Words per part: about two and a half tokens a word in Swedish, 2 500 tokens
    /// kept for the instructions and the answer. At least what Apple's model reads.
    var wordBudget: Int { max(Lines.appleBudget, min(Lines.localBudget, (contextTokens - 2_500) * 2 / 5)) }

    /// Tokens a prompt will take, generously (Swedish and names cost more than English).
    nonisolated static func estimateTokens(_ text: String) -> Int { text.utf8.count / 3 + 32 }

    /// The context for one prompt: what it needs and room for the answer, within the model's and this Mac's.
    func contextFor(_ system: String, _ user: String) -> Int {
        #if DEBUG
        if let forced = Self.debugContext { return forced }
        #endif
        return min(contextTokens, max(4_096, Self.estimateTokens(system + user) + 2_048))
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let context = contextFor(system, user)
        await LocalServers.shared.setPhase(.starting)
        defer { Task { @MainActor in LocalServers.shared.setPhase(nil) } }
        try await load(context: context)
        await LocalServers.shared.setPhase(.reading)
        let t0 = Date()
        let (text, read): (String, Int?)
        switch backend {
        case .ollama: (text, read) = try await ollama(system: system, user: user, context: context, maxTokens: maxTokens)
        case .lmStudio: (text, read) = try await lmStudio(system: system, user: user, maxTokens: maxTokens)
        }
        Self.log.info("\(self.name, privacy: .public) wrote in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s, read \(read ?? -1) of about \(Self.estimateTokens(system + user)) tokens in \(context)")
        // Read far less than it was sent: the prompt was cut to the context. Counted
        // leanly here (four letters a token, fewer than any language needs), so a model
        // that read 70 % of that read all of it.
        let lean = (system + user).utf8.count / 4
        if let read, lean > 1_000, read < lean * 7 / 10 { throw ServerError.truncated }
        return Self.unthought(text)
    }

    /// Without the thinking a model may write out anyway.
    nonisolated static func unthought(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        // A think block never closed: everything from it.
        if let r = out.range(of: "<think>") { out = String(out[..<r.lowerBound]) }
        return out.replacingOccurrences(of: #"(?s)<\|channel\|>.*?<\|message\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads the model (Ollama: an empty chat; LM Studio: the load call with the context).
    func load(context: Int? = nil) async throws {
        switch backend {
        case .ollama:
            var body: [String: Any] = ["model": model, "messages": [], "keep_alive": "5m"]
            if let context { body["options"] = ["num_ctx": context] }
            let (status, reply) = try await LocalServerClient.shared.call(.ollama, "/api/chat", json: body, timeout: 180)
            guard status == 200 else { throw LocalServerClient.serverError(status: status, body: reply) }
        case .lmStudio:
            let wanted = context ?? contextTokens
            // Loaded with enough context already: kept as it is.
            if let loadedContext, loadedContext >= wanted { return }
            let (status, reply) = try await LocalServerClient.shared.call(
                .lmStudio, "/api/v1/models/load", json: ["model": model, "context_length": wanted], timeout: 180)
            // An older LM Studio without the call loads the model with the chat itself.
            guard status == 200 || status == 404 else { throw LocalServerClient.serverError(status: status, body: reply) }
        }
    }

    /// After a summary, when memory is tight: the model is let go now, not in five minutes.
    func finished() async {
        guard LocalServers.freeMemoryBytes < 3_000_000_000 else { return }
        Self.log.info("memory is tight: unloading \(self.model, privacy: .public)")
        switch backend {
        case .ollama:
            _ = try? await LocalServerClient.shared.call(.ollama, "/api/chat", json: ["model": model, "messages": [], "keep_alive": 0], timeout: 10)
        case .lmStudio:
            _ = try? await LocalServerClient.shared.call(.lmStudio, "/api/v1/models/unload", json: ["instance_id": model], timeout: 10)
        }
    }

    private func ollama(system: String, user: String, context: Int, maxTokens: Int) async throws -> (String, Int?) {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]].filter { !($0["content"]!.isEmpty) },
            "stream": true,
            "keep_alive": "5m",
            "options": ["num_ctx": context, "temperature": 0.2, "num_predict": maxTokens],
        ]
        if thinking { body["think"] = false }
        let out = Collected()
        try await LocalServerClient.shared.stream(.ollama, "/api/chat", json: body) { line in
            guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = json["error"] as? String { throw LocalServerClient.serverError(status: 500, body: ["error": error]) }
            if let content = (json["message"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                if out.append(content) { Task { @MainActor in LocalServers.shared.setPhase(.writing) } }
            }
            if json["done"] as? Bool == true { out.read = (json["prompt_eval_count"] as? NSNumber)?.intValue }
        }
        return (out.text, out.read)
    }

    /// The OpenAI-style chat every LM Studio has, streamed; reasoning comes apart from the
    /// text there and is left out.
    private func lmStudio(system: String, user: String, maxTokens: Int) async throws -> (String, Int?) {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]].filter { !($0["content"]!.isEmpty) },
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": 0.2,
            "max_tokens": maxTokens,
        ]
        let out = Collected()
        try await LocalServerClient.shared.stream(.lmStudio, "/v1/chat/completions", json: body) { line in
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = json["error"] { throw LocalServerClient.serverError(status: 500, body: ["error": error]) }
            if let delta = ((json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]),
               let content = delta["content"] as? String, !content.isEmpty {
                if out.append(content) { Task { @MainActor in LocalServers.shared.setPhase(.writing) } }
            }
            if let usage = json["usage"] as? [String: Any], let n = (usage["prompt_tokens"] as? NSNumber)?.intValue { out.read = n }
        }
        return (out.text, out.read)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        private var _read: Int?
        /// True for the first piece: the model has begun to write.
        @discardableResult func append(_ s: String) -> Bool { lock.lock(); defer { lock.unlock() }; parts.append(s); return parts.count == 1 }
        var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
        var read: Int? {
            get { lock.lock(); defer { lock.unlock() }; return _read }
            set { lock.lock(); _read = newValue; lock.unlock() }
        }
    }

    /// The plain words for whatever went wrong.
    nonisolated static func plainWords(_ error: Error) -> String {
        if let e = error as? ServerError { return e.plainWords }
        if error is CancellationError { return String(localized: "Avbrutet.") }
        return ServerError.failed(error.localizedDescription).plainWords
    }
}
