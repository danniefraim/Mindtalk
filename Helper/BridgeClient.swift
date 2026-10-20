import Foundation
import MCP

// MARK: - The app's socket, from the helper's side
//
// One request per call, over a fresh connection: a line of JSON in, a line out.
// Not reachable: the app is opened once in the background (`open -gjb`), and the
// socket waited for up to eight seconds.

enum BridgeClient {
    struct Failure: Error { let message: String }

    static let notRunning = "Mindtalk could not be reached: it is not running or did not start in time. Ask the user to open Mindtalk, then try again."
    /// Word for word what the app answers when MCP is off (ClaudeTools.offMessage).
    static let off = "MCP is switched off in Mindtalk, so nothing can be read. Ask the user to switch it on in Mindtalk under Settings → Integrations → AI apps (Inställningar → Integrationer → AI-program in Swedish)."
    static let bundleID = "ai.mindact.mindtalk"

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mindtalk", isDirectory: true)
    }
    /// The same path the app listens at. `MINDTALK_SOCKET` points a test elsewhere.
    static var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["MINDTALK_SOCKET"], !env.isEmpty { return env }
        return supportFolder.appendingPathComponent("mcp.sock").path
    }
    /// The app leaves `mcp.on` here while MCP is switched on (ClaudeSharing). Without
    /// it there is nothing to ask for, so the app is never started on a program's behalf.
    static var markerPath: String { supportFolder.appendingPathComponent("mcp.on").path }
    /// A test (`MINDTALK_SOCKET`) or `MINDTALK_NO_OPEN`: the app is never opened.
    static var mayOpenApp: Bool {
        let env = ProcessInfo.processInfo.environment
        return (env["MINDTALK_SOCKET"] ?? "").isEmpty && (env["MINDTALK_NO_OPEN"] ?? "").isEmpty
    }

    private static let queue = DispatchQueue(label: "ai.mindact.mindtalk.helper.bridge", qos: .userInitiated)
    private static var nextID = 0

    static func call(tool: String, arguments: [String: Value]) async -> Result<Value, Failure> {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: send(tool: tool, arguments: arguments)) }
        }
    }

    /// The answer's `result`, as JSON text for the content the assistant reads.
    static func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private struct Response: Decodable {
        struct Problem: Decodable { let message: String }
        let result: Value?
        let error: Problem?
    }

    private static func send(tool: String, arguments: [String: Value]) -> Result<Value, Failure> {
        nextID += 1
        let request: Value = .object(["id": .int(nextID), "tool": .string(tool), "args": .object(arguments)])
        guard var data = try? JSONEncoder().encode(request) else { return .failure(Failure(message: "The request could not be encoded.")) }
        data.append(0x0A)

        let fd: Int32
        switch connect() {
        case .success(let open): fd = open
        case .failure(let why): return .failure(why)
        }
        defer { close(fd) }
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return .failure(Failure(message: notRunning)) }
            sent += n
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return .failure(Failure(message: "Mindtalk closed the connection without answering. Try again.")) }
            buffer.append(chunk, count: n)
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard let response = try? JSONDecoder().decode(Response.self, from: line) else {
            return .failure(Failure(message: "Mindtalk sent an answer that could not be read."))
        }
        if let problem = response.error { return .failure(Failure(message: problem.message)) }
        return .success(response.result ?? .object([:]))
    }

    /// A connection to the app, opening it once if it isn't running: only when MCP is
    /// switched on (the marker), never for a test. Off, the answer is the app's own.
    private static func connect() -> Result<Int32, Failure> {
        if let fd = tryConnect() { return .success(fd) }
        guard mayOpenApp else { return .failure(Failure(message: notRunning)) }
        guard FileManager.default.fileExists(atPath: markerPath) else { return .failure(Failure(message: off)) }
        // The installed app by its path when it is there, so a build left under
        // another folder is never the one that gets started; else by its identifier.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let installed = "/Applications/Mindtalk.app"
        open.arguments = FileManager.default.fileExists(atPath: installed) ? ["-gj", "-a", installed] : ["-gjb", bundleID]
        try? open.run()
        open.waitUntilExit()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if let fd = tryConnect() { return .success(fd) }
        }
        return .failure(Failure(message: notRunning))
    }

    private static func tryConnect() -> Int32? {
        let path = socketPath
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= room else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: room) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A search over years of meetings takes a while; an app that never answers must not hang the assistant.
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }
}
