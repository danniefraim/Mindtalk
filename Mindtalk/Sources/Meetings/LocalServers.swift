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
//   • Ollama's cloud models (passed on to ollama.com) are never listed, and a
//     transcript is only sent to a model that a fresh list just confirmed is local.
//     LM Studio's list has no mark for a model served from another computer (LM
//     Link), so that is said in the settings instead.
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
        case .notInstalled: return String(localized: "Inte installerat")
        }
    }
}

/// A model one of the backends has on this Mac.
struct ServerModel: Identifiable, Hashable, Sendable {
    /// LM Studio: a copy of the model loaded in memory, with the context it was given.
    struct Instance: Hashable, Sendable {
        let id: String
        let context: Int?
    }

    let backend: ServerBackend
    /// What the backend calls it in a request: "qwen3.5:9b", "google/gemma-4-26b-a4b".
    let id: String
    let bytes: Int64?
    /// The most it can read, in tokens, when known.
    let contextLength: Int?
    /// Ollama: the model can be told not to think (only those take `think`).
    /// LM Studio: reasoning can be switched off (only those take `reasoning`).
    let thinking: Bool
    /// LM Studio: loaded now, each with its context.
    var instances: [Instance] = []

    /// LM Studio: the largest context any loaded copy has.
    var loadedContext: Int? { instances.compactMap(\.context).max() }

    var sizeText: String? { bytes.map { BetterNotes.gigabytes($0) } }
    /// "upp till 100 000 ord": what it reads at once, in words rather than tokens.
    var wordsText: String? { contextLength.map { String(localized: "upp till \(Self.words($0)) ord") } }

    /// Tokens as words (about two and a half tokens a word in Swedish), rounded to
    /// thousands, and to ten thousands from a hundred thousand: "13 000", "100 000".
    static func words(_ tokens: Int) -> String {
        let words = Double(tokens) / 2.5
        let unit = words >= 100_000 ? 10_000.0 : 1_000.0
        let rounded = Int((words / unit).rounded() * unit)
        return rounded.formatted(.number.locale(AppLanguage.locale))
    }

    /// "qwen3.5:9b · 7,6 GB · upp till 100 000 ord"
    var title: String { [id, sizeText, wordsText].compactMap { $0 }.joined(separator: " · ") }

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
    /// The model stopped at its output limit before the answer was whole.
    case cutOff
    case noSources
    /// The server has no such call (an older LM Studio): tried another way.
    case noEndpoint
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
        case .cutOff: return String(localized: "Svaret blev avklippt. Välj en modell som orkar mer text.")
        case .noSources: return String(localized: "Svaret saknade källor, så det visas inte.")
        case .noEndpoint, .failed: return String(localized: "Modellen kunde inte svara just nu. Försök igen om en stund.")
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
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        watchdog.touch(between)
                        try onLine(line)
                    }
                } catch {
                    // Avbryt pressed: said as cancelled, not as a broken connection.
                    if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    throw error
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

    /// Nothing answered on the port: not running (or not here at all). A slow answer
    /// is a slow answer (a large model loading), not a server that isn't there.
    nonisolated static func connectionError(_ error: Error, _ backend: ServerBackend) -> Error {
        if error is CancellationError { return error }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .networkConnectionLost:
                return backend.isInstalled ? ServerError.notRunning(backend) : ServerError.notInstalled(backend)
            case .timedOut: return ServerError.timeout
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
        if lower.contains("context length") || lower.contains("longer than the context") || lower.contains("exceeds") {
            return .truncated
        }
        if lower.contains("no such model") || lower.contains("model not found") || lower.contains("does not exist")
            || (lower.contains("not found") && lower.contains("model")) {
            return .modelGone
        }
        if lower.contains("memory") || lower.contains("out of vram") || lower.contains("insufficient") {
            return .noMemory
        }
        if status == 404 {
            // Without a word about a model: the call itself isn't there (an older server).
            return message.isEmpty || lower.contains("endpoint") || lower.contains("route") || lower.contains("unexpected") ? .noEndpoint : .modelGone
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
    /// Where each job stands while its model writes, by job: "qwen3.5:9b läser mötet…".
    @Published private(set) var phases: [UUID: (model: String, phase: Phase)] = [:]
    /// "Testa": what the model answered, how long it took, and how much it reads.
    @Published private(set) var test: TestResult?
    @Published private(set) var testing: ServerBackend?
    /// Why a port wasn't taken ("Ollama och LM Studio kan inte ha samma port.").
    @Published private(set) var portNote: String?
    /// The ports, published so Avancerat follows along. Kept within 1…65 535, and never
    /// the same for both (then the old value stays, and `portNote` says why).
    @Published var ports: [ServerBackend: Int] = [:] {
        didSet {
            for b in ServerBackend.allCases {
                guard let p = ports[b] else { continue }
                let clamped = min(65_535, max(1, p))
                let other = ServerBackend.allCases.first { $0 != b }.flatMap { ports[$0] }
                if clamped == other {
                    ports[b] = oldValue[b] ?? b.defaultPort
                    portNote = String(localized: "Ollama och LM Studio kan inte ha samma port.")
                } else if clamped != p {
                    ports[b] = clamped
                }
                if let now = ports[b], now != b.port { b.port = now; portNote = nil }
            }
        }
    }

    enum Phase: Equatable {
        case starting, reading, writing
        /// With the model as its subject: "qwen3.5:9b läser mötet…".
        func title(_ model: String) -> String {
            switch self {
            case .starting: return String(localized: "\(model) startar…")
            case .reading: return String(localized: "\(model) läser mötet…")
            case .writing: return String(localized: "\(model) skriver…")
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

    /// A model run by ollama.com rather than this Mac, by its name: ":cloud", "-cloud".
    nonisolated static func isCloudName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(":cloud") || n.contains(":cloud") || n.contains("-cloud") || n.hasSuffix("cloud")
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
            switch error {
            case .notRunning, .notInstalled:
                states[backend] = installed ? .installedNotRunning : .notInstalled
                notes[backend] = nil
            case .timeout:
                // Answering, but slowly (loading something): still running.
                notes[backend] = error.plainWords
            default:
                states[backend] = installed ? .installedNotRunning : .notInstalled
                notes[backend] = error.plainWords
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
            if m["remote_host"] != nil || m["remote_model"] != nil || isCloudName(name) { continue }
            let details = m["details"] as? [String: Any] ?? [:]
            var context = (details["context_length"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            var capabilities = m["capabilities"] as? [String]
            // Older Ollama versions say neither in the list: asked for the model.
            if context == nil || capabilities == nil, let shown = try? await ollamaShow(name) {
                if context == nil { context = shown.context }
                if capabilities == nil { capabilities = shown.capabilities }
            }
            let can = capabilities ?? ["completion"]
            // Embedding models and the like can't write.
            guard can.contains("completion") else { continue }
            models.append(ServerModel(backend: .ollama, id: name, bytes: (m["size"] as? NSNumber)?.int64Value,
                                      contextLength: context, thinking: can.contains("thinking")))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// One model's context and capabilities, from `/api/show`.
    nonisolated private static func ollamaShow(_ model: String) async throws -> (context: Int?, capabilities: [String]?) {
        let (status, body) = try await LocalServerClient.shared.call(.ollama, "/api/show", json: ["model": model], timeout: 5)
        guard status == 200 else { return (nil, nil) }
        var context: Int?
        if let info = body["model_info"] as? [String: Any] {
            for (key, value) in info where key.hasSuffix(".context_length") {
                if let n = (value as? NSNumber)?.intValue, n > 0 { context = n; break }
            }
        }
        return (context, body["capabilities"] as? [String])
    }

    /// LM Studio's language models. Its list has no mark for a model served from another
    /// computer (LM Link), so all are shown and the settings say so; the request itself
    /// only ever goes to this Mac.
    nonisolated private static func lmStudioModels() async throws -> [ServerModel] {
        let (status, body) = try await LocalServerClient.shared.call(.lmStudio, "/api/v1/models", timeout: 3)
        if status == 200, let list = (body["models"] as? [[String: Any]]) ?? (body["data"] as? [[String: Any]]) {
            return list.compactMap { m -> ServerModel? in
                guard let key = (m["key"] as? String) ?? (m["id"] as? String), !isCloudName(key) else { return nil }
                if let type = m["type"] as? String, type != "llm" { return nil }
                let instances = ((m["loaded_instances"] as? [[String: Any]]) ?? []).compactMap { i -> ServerModel.Instance? in
                    guard let id = i["id"] as? String else { return nil }
                    return ServerModel.Instance(id: id, context: ((i["config"] as? [String: Any])?["context_length"] as? NSNumber)?.intValue)
                }
                let reasoning = ((m["capabilities"] as? [String: Any])?["reasoning"] as? [String: Any])?["allowed_options"] as? [String]
                return ServerModel(backend: .lmStudio, id: key, bytes: (m["size_bytes"] as? NSNumber)?.int64Value,
                                   contextLength: (m["max_context_length"] as? NSNumber)?.intValue,
                                   thinking: reasoning?.contains("off") ?? false, instances: instances)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        // An older LM Studio: only the OpenAI-style list, names only.
        let (status2, body2) = try await LocalServerClient.shared.call(.lmStudio, "/v1/models", timeout: 3)
        guard status2 == 200, let list = body2["data"] as? [[String: Any]] else {
            throw LocalServerClient.serverError(status: status2, body: body2)
        }
        return list.compactMap { m in
            guard let id = m["id"] as? String, !isCloudName(id) else { return nil }
            return ServerModel(backend: .lmStudio, id: id, bytes: nil, contextLength: nil, thinking: false)
        }
    }

    // MARK: Using one

    /// A chosen model is loaded right away, so the first summary doesn't wait for it:
    /// with the context most meetings need (LocalServerWriter.contextFloor), the same
    /// one a job then asks for, so Ollama doesn't load it twice.
    func prewarm(_ backend: ServerBackend, _ model: String) {
        Task.detached(priority: .utility) {
            let writer = await LocalServerWriter(backend: backend, model: model)
            try? await writer.load(context: min(writer.contextTokens, LocalServerWriter.contextFloor))
        }
    }

    /// A recording is about to start: the chosen server model is let go now, so the
    /// speech models have the memory.
    func release() {
        guard let server = BetterNotes.shared.server else { return }
        Task.detached(priority: .utility) {
            let writer = await LocalServerWriter(backend: server.backend, model: server.model)
            await writer.unload()
        }
    }

    /// "Testa": two numbered lines in Swedish, one cited sentence back.
    func runTest(_ backend: ServerBackend, _ model: String) {
        guard testing == nil else { return }
        testing = backend
        test = nil
        testTask = Task {
            defer { testing = nil; testTask = nil }
            let writer = LocalServerWriter(backend: backend, model: model, test: true)
            let t0 = Date()
            do {
                let text = try await writer.complete(system: """
                    You read a meeting transcript. Each line is "[n] Name: what they said". Answer in Swedish, in one \
                    sentence, in your own words, and end it with the number in brackets of the line it comes from.
                    """, user: """
                    Transcript:
                    [1] Anna: Vi behöver bestämma när vi lanserar.
                    [2] Johan: Jag föreslår den 14 november, då är allt klart.

                    Question: \(Self.testQuestion)
                    """, maxTokens: 80)
                let answer = MeetingNotes.tidy(text.trimmingCharacters(in: .whitespacesAndNewlines))
                test = TestResult(backend: backend, model: model, answer: answer.isEmpty ? nil : answer,
                                  seconds: Date().timeIntervalSince(t0), context: writer.contextTokens,
                                  error: answer.isEmpty ? ServerError.failed("empty").plainWords : nil)
            } catch is CancellationError {
                test = nil
            } catch {
                test = TestResult(backend: backend, model: model, answer: nil, seconds: Date().timeIntervalSince(t0),
                                  context: writer.contextTokens, error: LocalServerWriter.plainWords(error))
            }
        }
    }

    /// The question Testa asks about its made-up meeting.
    static let testQuestion = "När föreslås lanseringen?"

    private var testTask: Task<Void, Never>?

    /// Avbryt next to Testa.
    func cancelTest() { testTask?.cancel() }

    /// Another model or backend chosen: the old answer would mislead.
    func clearTest() { test = nil }

    /// One job's phase: nil when it's done.
    func setPhase(_ phase: Phase?, job: UUID, model: String) {
        if let phase { phases[job] = (model, phase) } else { phases[job] = nil }
    }

    /// Where the notes stand, as a sentence ("qwen3.5:9b läser mötet…"): the first job
    /// that isn't Testa, so a test doesn't show in a meeting's placeholder.
    var progress: String? {
        phases.first { $0.key != testJob }.map { $0.value.phase.title($0.value.model) }
    }
    fileprivate var testJob: UUID?
    func noteTestJob(_ id: UUID) { testJob = id }

    func resetPorts() {
        for b in ServerBackend.allCases { ports[b] = b.defaultPort }
        portNote = nil
    }

    #if DEBUG
    private func applyDemo(_ demo: String) {
        let ollama = [
            ServerModel(backend: .ollama, id: "qwen3.5:9b", bytes: 7_639_229_431, contextLength: 262_144, thinking: true),
            ServerModel(backend: .ollama, id: "gemma4:26b", bytes: 17_300_000_000, contextLength: 131_072, thinking: true),
            ServerModel(backend: .ollama, id: "llama3.2:3b", bytes: 2_019_000_000, contextLength: 131_072, thinking: false),
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
                  contextLength: (stored["context"] as? NSNumber)?.intValue, thinking: stored["thinking"] as? Bool ?? false)
    }
}

// MARK: - Writing with one

/// Your own model in Ollama or LM Studio as a writer: the whole meeting in one go
/// when it fits, told exactly how much to read, with thinking off and its answer
/// checked for what it read. One writer is one job (a summary, an answer, a test):
/// the model is confirmed local once, given one context for all its parts, and the
/// progress shown is this job's.
struct LocalServerWriter: SummaryWriter {
    let backend: ServerBackend
    let model: String
    let contextTokens: Int
    private let thinking: Bool
    private let test: Bool
    private let job = Job()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "LocalServers")

    /// What one job keeps between its parts.
    private final class Job: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var _context: Int?
        private var _verified = false
        private var _begun = false
        private var _instance: String?
        private var _bytes: Int64?
        /// The context every call of the job uses, once fixed.
        var context: Int? {
            get { lock.lock(); defer { lock.unlock() }; return _context }
            set { lock.lock(); _context = newValue; lock.unlock() }
        }
        /// A fresh list said the model is here and local.
        var verified: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _verified }
            set { lock.lock(); _verified = newValue; lock.unlock() }
        }
        /// `begin` fixed the context for several parts: the phase lasts until `finished`.
        var begun: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _begun }
            set { lock.lock(); _begun = newValue; lock.unlock() }
        }
        /// LM Studio: the loaded copy this job uses.
        var instance: String? {
            get { lock.lock(); defer { lock.unlock() }; return _instance }
            set { lock.lock(); _instance = newValue; lock.unlock() }
        }
        /// The model's size on disk, from the fresh list: about what it takes in memory.
        var bytes: Int64? {
            get { lock.lock(); defer { lock.unlock() }; return _bytes }
            set { lock.lock(); _bytes = newValue; lock.unlock() }
        }
    }

    #if DEBUG
    /// `--server-ctx 2048`: a context far too small, to see that a cut meeting is caught.
    nonisolated(unsafe) static var debugContext: Int?
    #endif

    @MainActor init(backend: ServerBackend, model: String, test: Bool = false) {
        self.backend = backend
        self.model = model
        self.test = test
        let known = LocalServers.shared.model(backend, model)
        contextTokens = LocalServers.shared.context(for: backend, model: model)
        thinking = known?.thinking ?? false
        if test { LocalServers.shared.noteTestJob(job.id) }
    }

    /// "Ollama · qwen3.5:9b", for a row.
    var name: String { "\(backend.name) · \(model)" }
    /// "qwen3.5:9b i Ollama", in a sentence.
    var sentenceName: String { String(localized: "\(model) i \(backend.name)") }
    let requiresSources = true

    /// Words per part: about two and a half tokens a word in Swedish, 2 500 tokens
    /// kept for the instructions and the answer. At least what Apple's model reads.
    var wordBudget: Int { max(Lines.appleBudget, min(Lines.localBudget, (contextTokens - 2_500) * 2 / 5)) }

    /// Tokens a prompt will take, generously (Swedish and names cost more than English).
    nonisolated static func estimateTokens(_ text: String) -> Int { text.utf8.count / 3 + 32 }

    /// The least a job asks for: what most meetings need, and what a chosen model is
    /// warmed with, so the two agree and the model isn't loaded twice.
    static let contextFloor = 16_384

    /// One context for a whole job: the largest part's need with room for the answer,
    /// rounded up to a multiple of 4 096, at least the floor, within the model's and
    /// this Mac's.
    func jobContext(system: String, prompts: [String]) -> Int {
        #if DEBUG
        if let forced = Self.debugContext { return forced }
        #endif
        let need = prompts.map { Self.estimateTokens(system + $0) + 2_048 }.max() ?? 4_096
        let rounded = (need + 4_095) / 4_096 * 4_096
        return min(contextTokens, max(Self.contextFloor, rounded))
    }

    /// A job of several parts (a summary): the context is fixed for all of them, the
    /// model confirmed and loaded once, and the phase shown until `finished`.
    func begin(system: String, prompts: [String]) async throws {
        job.begun = true
        job.context = jobContext(system: system, prompts: prompts)
        try await prepare()
    }

    /// The model confirmed local and loaded, with this job's context: "startar…".
    private func prepare() async throws {
        await setPhase(.starting)
        try await verify()
        try await load(context: job.context)
    }

    /// Nothing is sent to a model a fresh list doesn't have as a local one: a cloud
    /// model, or one renamed to look local, is refused.
    private func verify() async throws {
        guard !job.verified else { return }
        guard !LocalServers.isCloudName(model) else { throw ServerError.modelGone }
        let fresh = try await LocalServers.list(backend)
        guard let found = fresh.first(where: { $0.id == model }) else { throw ServerError.modelGone }
        job.bytes = found.bytes
        if let wanted = job.context, let loaded = found.instances.first(where: { ($0.context ?? 0) >= wanted }) {
            job.instance = loaded.id
        }
        job.verified = true
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        // Not a begun job (an answer, a test): each call sizes and readies itself.
        if !job.begun {
            job.context = jobContext(system: system, prompts: [user])
            try await prepare()
        }
        let context = job.context!
        defer { if !job.begun { Task { @MainActor in LocalServers.shared.setPhase(nil, job: job.id, model: model) } } }
        await setPhase(.reading)
        let t0 = Date()
        let out: Collected
        switch backend {
        case .ollama: out = try await ollama(system: system, user: user, context: context, maxTokens: maxTokens)
        case .lmStudio: out = try await lmStudio(system: system, user: user, context: context, maxTokens: maxTokens)
        }
        let read = out.read
        Self.log.info("\(self.name, privacy: .public) wrote in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s, read \(read ?? -1) of about \(Self.estimateTokens(system + user)) tokens in \(context), stopped: \(out.finish ?? "?", privacy: .public)")
        // Read far less than it was sent: the prompt was cut to the context. Counted
        // leanly here (four letters a token, fewer than any language needs), so a model
        // that read 70 % of that read all of it. Only Ollama's count is trusted, and
        // only with its cache counted in.
        let lean = (system + user).utf8.count / 4
        if let read, lean > 1_000, read < lean * 7 / 10 { throw ServerError.truncated }
        let text = Self.unthought(out.text)
        // Stopped at the output limit with nothing, or without the sources line the
        // answer needs: not an answer.
        if out.finish == "length" {
            let needsSources = system.contains("SOURCES:")
            let hasSources = text.uppercased().contains("SOURCES:") || text.uppercased().contains("KÄLLOR:")
            if text.isEmpty || (needsSources && !hasSources) { throw ServerError.cutOff }
        }
        return text
    }

    /// Without the thinking a model may write out anyway: `<think>` blocks, and the
    /// analysis channel of gpt-oss (only the final channel is the answer).
    nonisolated static func unthought(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        // A think block never closed: everything from it.
        if let r = out.range(of: "<think>") { out = String(out[..<r.lowerBound]) }
        if out.contains("<|channel|>final<|message|>"), let r = out.range(of: "<|message|>", options: .backwards) {
            out = String(out[r.upperBound...])
        } else {
            out = out.replacingOccurrences(of: #"(?s)<\|channel\|>analysis<\|message\|>.*?(<\|end\|>|$)"#, with: "", options: .regularExpression)
        }
        return out.replacingOccurrences(of: #"<\|(end|return|start|channel|message)\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads the model with the context given. Ollama: an empty chat with `num_ctx`.
    /// LM Studio: only when no loaded copy has that much context; the chat itself says
    /// its context, so an older LM Studio without the call loads it then.
    func load(context: Int?) async throws {
        switch backend {
        case .ollama:
            var body: [String: Any] = ["model": model, "messages": [], "keep_alive": "5m"]
            if let context { body["options"] = ["num_ctx": context] }
            let (status, reply) = try await LocalServerClient.shared.call(.ollama, "/api/chat", json: body, timeout: 180)
            guard status == 200 else { throw LocalServerClient.serverError(status: status, body: reply) }
        case .lmStudio:
            let wanted = context ?? Self.contextFloor
            if job.instance != nil { return }
            // Loaded with enough context already: kept as it is.
            if let listed = try? await LocalServers.list(.lmStudio).first(where: { $0.id == model }),
               let loaded = listed.instances.first(where: { ($0.context ?? 0) >= wanted }) {
                job.instance = loaded.id
                return
            }
            let (status, reply) = try await LocalServerClient.shared.call(
                .lmStudio, "/api/v1/models/load", json: ["model": model, "context_length": wanted], timeout: 180)
            if status == 200 { job.instance = reply["instance_id"] as? String ?? model; return }
            // An older LM Studio without the call loads the model with the chat itself
            // (the model is here: the fresh list just said so).
            guard status == 404 else { throw LocalServerClient.serverError(status: status, body: reply) }
        }
    }

    /// After a summary: the phase is done. The model is let go only when it would not
    /// fit beside what's running: free memory below its own size, or a recording or
    /// dictation under way. Otherwise it stays for the next summary (Ollama's own five
    /// minutes; LM Studio keeps it until told).
    func finished() async {
        await MainActor.run { LocalServers.shared.setPhase(nil, job: job.id, model: model) }
        // Its size unknown (an older LM Studio's list): not judged tight.
        let tight = job.bytes.map { LocalServers.freeMemoryBytes < $0 } ?? false
        let busy = await MainActor.run { MeetingSession.shared.isRecording || MeetingSession.shared.armed || Dictation.shared.phase == .recording }
        guard tight || busy else { return }
        Self.log.info("\(tight ? "memory is tight" : "recording", privacy: .public): unloading \(self.model, privacy: .public)")
        await unload()
    }

    /// The model let go now, not in five minutes.
    func unload() async {
        switch backend {
        case .ollama:
            _ = try? await LocalServerClient.shared.call(.ollama, "/api/chat", json: ["model": model, "messages": [], "keep_alive": 0], timeout: 10)
        case .lmStudio:
            // By the loaded copy's id, from this job or a fresh list.
            var ids = job.instance.map { [$0] } ?? []
            if ids.isEmpty, let listed = try? await LocalServers.list(.lmStudio).first(where: { $0.id == model }) {
                ids = listed.instances.map(\.id)
            }
            for id in ids {
                _ = try? await LocalServerClient.shared.call(.lmStudio, "/api/v1/models/unload", json: ["instance_id": id], timeout: 10)
            }
        }
    }

    private func setPhase(_ phase: LocalServers.Phase) async {
        await MainActor.run { LocalServers.shared.setPhase(phase, job: job.id, model: model) }
    }

    private func ollama(system: String, user: String, context: Int, maxTokens: Int) async throws -> Collected {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]].filter { !($0["content"]!.isEmpty) },
            "stream": true,
            "keep_alive": "5m",
            // Too long for the context: an error, never a silent cut.
            "truncate": false,
            "options": ["num_ctx": context, "temperature": 0.2, "num_predict": maxTokens],
        ]
        if thinking { body["think"] = false }
        let out = Collected()
        let job = job, model = model
        try await LocalServerClient.shared.stream(.ollama, "/api/chat", json: body) { line in
            guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = json["error"] as? String { throw LocalServerClient.serverError(status: 500, body: ["error": error]) }
            if let content = (json["message"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                if out.append(content) { Task { @MainActor in LocalServers.shared.setPhase(.writing, job: job.id, model: model) } }
            }
            if json["done"] as? Bool == true {
                out.finish = json["done_reason"] as? String
                // What it read: the prompt's tokens and those it had cached. Without the
                // cached count the number can't be trusted, and isn't checked.
                if let n = (json["prompt_eval_count"] as? NSNumber)?.intValue, let cached = (json["prompt_eval_cached_count"] as? NSNumber)?.intValue {
                    out.read = n + cached
                }
            }
        }
        return out
    }

    /// LM Studio's own chat, streamed: reasoning off for models that can, the context
    /// said in the request. An older LM Studio without it: the OpenAI-style chat.
    private func lmStudio(system: String, user: String, context: Int, maxTokens: Int) async throws -> Collected {
        var body: [String: Any] = [
            "model": model,
            "input": user,
            "stream": true,
            "store": false,
            "temperature": 0.2,
            "context_length": context,
            "max_output_tokens": maxTokens,
        ]
        if !system.isEmpty { body["system_prompt"] = system }
        if thinking { body["reasoning"] = "off" }
        let out = Collected()
        let job = job, model = model
        do {
            try await LocalServerClient.shared.stream(.lmStudio, "/api/v1/chat", json: body) { line in
                guard line.hasPrefix("data:") else { return }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                switch json["type"] as? String {
                case "message.delta":
                    if let content = json["content"] as? String, !content.isEmpty, out.append(content) {
                        Task { @MainActor in LocalServers.shared.setPhase(.writing, job: job.id, model: model) }
                    }
                case "error":
                    throw LocalServerClient.serverError(status: 500, body: ["error": json["error"] ?? "error"])
                case "chat.end":
                    // The token count here is for the log only.
                    if let stats = ((json["result"] as? [String: Any])?["stats"] as? [String: Any]),
                       let n = (stats["input_tokens"] as? NSNumber)?.intValue {
                        Self.log.info("LM Studio read \(n) tokens")
                    }
                default: break
                }
            }
            return out
        } catch ServerError.noEndpoint {
            return try await lmStudioCompletions(system: system, user: user, maxTokens: maxTokens)
        }
    }

    /// The OpenAI-style chat every LM Studio has; reasoning comes apart from the text
    /// there and is left out. Stopped at the limit with nothing: an error.
    private func lmStudioCompletions(system: String, user: String, maxTokens: Int) async throws -> Collected {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]].filter { !($0["content"]!.isEmpty) },
            "stream": true,
            "temperature": 0.2,
            "max_tokens": maxTokens,
        ]
        let out = Collected()
        let job = job, model = model
        try await LocalServerClient.shared.stream(.lmStudio, "/v1/chat/completions", json: body) { line in
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = json["error"] { throw LocalServerClient.serverError(status: 500, body: ["error": error]) }
            let choice = (json["choices"] as? [[String: Any]])?.first
            if let content = (choice?["delta"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                if out.append(content) { Task { @MainActor in LocalServers.shared.setPhase(.writing, job: job.id, model: model) } }
            }
            if let reason = choice?["finish_reason"] as? String { out.finish = reason }
        }
        if out.finish == "length", out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ServerError.cutOff }
        return out
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        private var _read: Int?
        private var _finish: String?
        /// True for the first piece: the model has begun to write.
        @discardableResult func append(_ s: String) -> Bool { lock.lock(); defer { lock.unlock() }; parts.append(s); return parts.count == 1 }
        var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
        var read: Int? {
            get { lock.lock(); defer { lock.unlock() }; return _read }
            set { lock.lock(); _read = newValue; lock.unlock() }
        }
        /// Why it stopped: "stop", or "length" at the output limit.
        var finish: String? {
            get { lock.lock(); defer { lock.unlock() }; return _finish }
            set { lock.lock(); _finish = newValue; lock.unlock() }
        }
    }

    /// The plain words for whatever went wrong.
    nonisolated static func plainWords(_ error: Error) -> String {
        if let e = error as? ServerError { return e.plainWords }
        if error is CancellationError { return String(localized: "Avbrutet.") }
        return ServerError.failed(error.localizedDescription).plainWords
    }
}
