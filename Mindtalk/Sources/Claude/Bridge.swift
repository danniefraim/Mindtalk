import Foundation
import os

// MARK: - The bridge: how the helper `mindtalk` reaches the running app
//
// Claude never reads the disk. The helper in the app bundle (Contents/Helpers/mindtalk)
// speaks MCP to Claude and asks the app over a Unix socket in Application Support,
// readable by you alone (mode 0600). One request per line, UTF-8 JSON:
//
//   {"id": 1, "tool": "mindtalk_search", "args": {"query": "offerten"}}
//   {"id": 1, "result": {...}}      or      {"id": 1, "error": {"message": "..."}}
//
// The app alone checks the switch, the level and the folders (ClaudeSharing) and
// writes the log; every tool is answered on the main thread by ClaudeTools. The
// socket listens from launch: switched off, every request is answered with that.
//
// A fixed path for the helper: at every start the app points
// ~/Library/Application Support/Mindtalk/bin/mindtalk at the helper in the bundle,
// so Claude's configuration keeps working when the app moves or is updated.

final class Bridge: @unchecked Sendable {
    static let shared = Bridge()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Bridge")

    /// `~/Library/Application Support/Mindtalk`: the socket and the link live here. The
    /// helper computes the same path on its own.
    nonisolated static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mindtalk", isDirectory: true)
    }
    /// The socket the helper connects to.
    nonisolated static var socketURL: URL { supportFolder.appendingPathComponent("claude.sock") }
    /// The fixed path to the helper, kept pointing at the current bundle.
    nonisolated static var helperLinkURL: URL {
        supportFolder.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("mindtalk")
    }
    /// The helper inside this app.
    nonisolated static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mindtalk")
    }

    private var listener: Int32 = -1
    private var path = ""
    private let queue = DispatchQueue(label: "ai.mindact.mindtalk.bridge", qos: .userInitiated, attributes: .concurrent)

    /// At launch: the socket, and the fixed path to the helper.
    @MainActor static func launch() {
        shared.start()
        Task.detached(priority: .utility) { installHelperLink() }
    }

    /// Listens at `url` (the real socket unless a self-test says otherwise). An old
    /// socket file from a crash is replaced.
    func start(at url: URL = Bridge.socketURL) {
        guard listener < 0 else { return }
        let path = url.path
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Self.log.error("socket: \(String(cString: strerror(errno)), privacy: .public)"); return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard var address = Self.address(path) else {
            Self.log.error("socket path too long: \(path, privacy: .public)")
            close(fd)
            return
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            Self.log.error("bind \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            Self.log.error("listen: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            unlink(path)
            return
        }
        listener = fd
        self.path = path
        Self.log.notice("listening at \(path, privacy: .public)")
        queue.async { self.accept() }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
                                               object: nil, queue: nil) { [weak self] _ in self?.stop() }
    }

    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(path)
    }

    /// The path as a `sockaddr_un`, or nil when it doesn't fit (104 bytes on macOS).
    private static func address(_ path: String) -> sockaddr_un? {
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
        return address
    }

    private func accept() {
        while listener >= 0 {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            queue.async { self.serve(client) }
        }
    }

    /// One connection: a request per line, an answer per line, until the helper hangs up.
    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                var answer = Self.answer(line)
                answer.append(0x0A)
                guard Self.write(answer, to: client) else { return }
            }
            // A single line longer than any request could be: the connection is dropped.
            if buffer.count > 1_000_000 { return }
        }
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, data.count - sent) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    /// One request, answered on the main thread by ClaudeTools.
    private static func answer(_ line: Data) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let id: Any = request?["id"] ?? NSNull()
        guard let request, let tool = request["tool"] as? String else {
            return encode(["id": id, "error": ["message": "Malformed request: expected {\"id\", \"tool\", \"args\"} as one JSON object per line."]])
        }
        let args = request["args"] as? [String: Any] ?? [:]
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do {
                box.response = ["id": id, "result": try await ClaudeTools.handle(tool: tool, args: args)]
            } catch let failure as ClaudeTools.Failure {
                box.response = ["id": id, "error": ["message": failure.message]]
            } catch {
                box.response = ["id": id, "error": ["message": error.localizedDescription]]
            }
            done.signal()
        }
        done.wait()
        return encode(box.response)
    }

    private final class Box: @unchecked Sendable { var response: [String: Any] = [:] }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"error\":{\"message\":\"The answer could not be encoded.\"}}".utf8)
    }

    // MARK: The fixed path

    /// `bin/mindtalk` → the helper in this bundle. Replaced when it points elsewhere
    /// (an older copy, a moved app).
    static func installHelperLink() {
        let fm = FileManager.default
        let link = helperLinkURL, target = bundledHelperURL
        guard fm.fileExists(atPath: target.path) else {
            log.notice("no helper in the bundle at \(target.path, privacy: .public)")
            return
        }
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == target.path { return }
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            log.notice("helper link → \(target.path, privacy: .public)")
        } catch {
            log.error("helper link: \(error.localizedDescription, privacy: .public)")
        }
    }
}
