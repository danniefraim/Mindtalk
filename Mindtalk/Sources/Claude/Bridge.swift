import Foundation
import os

// MARK: - The bridge: how the helper `mindtalk` reaches the running app
//
// The assistant (Claude, ChatGPT or any other MCP app) never reads the disk. The
// helper in the app bundle (Contents/Helpers/mindtalk) speaks MCP to it and asks the
// app over a Unix socket in Application Support, readable by you alone (mode 0600).
// One request per line, UTF-8 JSON:
//
//   {"id": 1, "tool": "mindtalk_search", "args": {"query": "offerten"}}
//   {"id": 1, "result": {...}}      or      {"id": 1, "error": {"message": "..."}}
//
// The app alone checks the switch and which meetings are over (ClaudeSharing) and
// writes the log; every tool is answered on the main thread by ClaudeTools. The
// socket listens from launch: switched off, every request is answered with that. A
// request that comes in before the meetings are read from disk (the helper opens the
// app when it isn't running) waits for them: ClaudeTools awaits MeetingStore.ready().
//
// A fixed path for the helper: at every start the app points
// ~/Library/Application Support/Mindtalk/bin/mindtalk at the helper in the bundle,
// so the assistant's configuration keeps working when the app moves or is updated.

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
    nonisolated static var socketURL: URL { supportFolder.appendingPathComponent("mcp.sock") }
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
    /// Connections being served right now: more than `room` at once are turned away.
    private let open = OSAllocatedUnfairLock(initialState: 0)
    static let room = 16
    /// A connection that neither sends nor takes an answer for this long is dropped.
    static let timeout: Int = 30
    /// Another copy holds the socket: looked at again this often, so that when it quits
    /// (a build from Xcode, stopped) this one takes the bridge over.
    static let retry: Int = 10
    /// The socket another copy held when this one last looked: said once in the log, not every time.
    private var waitingAt: String?

    /// At launch: the socket, and the fixed path to the helper.
    @MainActor static func launch() {
        shared.start()
        Task.detached(priority: .utility) { installHelperLink() }
    }

    /// Listens at `url` (the real socket unless a self-test says otherwise). An old
    /// socket file from a crash is replaced; one that answers belongs to another copy
    /// of the app (the installed one, while a build from Xcode runs) and is left alone,
    /// and looked at again every `retry` seconds until it is gone.
    func start(at url: URL = Bridge.socketURL) {
        guard listener < 0 else { return }
        let path = url.path
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Yours alone also when the folder was made before, by an older build or by hand.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        guard var address = Self.address(path) else {
            Self.log.error("socket path too long: \(path, privacy: .public)")
            return
        }
        if Self.answers(&address) {
            if waitingAt != path {
                waitingAt = path
                Self.log.notice("another Mindtalk listens at \(path, privacy: .public): this one leaves the bridge to it until it quits")
                #if DEBUG
                print("Bryggan: en annan Mindtalk lyssnar redan på \(path), den här tar över när den slutar.")
                #endif
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.retry)) { [weak self] in self?.start(at: url) }
            return
        }
        if waitingAt == path { Self.log.notice("the other Mindtalk is gone: this one takes the bridge over") }
        waitingAt = nil
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Self.log.error("socket: \(String(cString: strerror(errno)), privacy: .public)"); return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Made 0600 from the start: no moment when another user could connect.
        let mask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
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

    /// Someone accepts connections at this address right now. A socket file left by a
    /// crash refuses, and is then safe to replace.
    private static func answers(_ address: inout sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0
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
            // Only you: a connection from another user (the folder and the socket
            // already keep them out) is closed unanswered.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Self.log.error("refused a connection from another user")
                close(client)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var wait = timeval(tv_sec: Self.timeout, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let serving = open.withLock { n -> Int in n += 1; return n }
            guard serving <= Self.room else {
                open.withLock { $0 -= 1 }
                var line = Self.encode(["error": ["message": "Mindtalk is busy with too many connections at once. Try again in a moment."]])
                line.append(0x0A)
                _ = Self.write(line, to: client)
                close(client)
                continue
            }
            // Who is asking, before the first line: the program at the other end, or the
            // one that started our helper.
            let asking = Self.peerName(of: client)
            queue.async { self.serve(client, client: asking) }
        }
    }

    /// One connection: a request per line, an answer per line, until the helper hangs up.
    private func serve(_ client: Int32, client name: String?) {
        defer {
            close(client)
            open.withLock { $0 -= 1 }
        }
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
                var answer = Self.answer(line, client: name)
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
    private static func answer(_ line: Data, client: String?) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let id: Any = request?["id"] ?? NSNull()
        guard let request, let tool = request["tool"] as? String else {
            return encode(["id": id, "error": ["message": "Malformed request: expected {\"id\", \"tool\", \"args\"} as one JSON object per line."]])
        }
        let args: [String: Any]
        switch request["args"] {
        case nil, is NSNull: args = [:]
        case let object as [String: Any]: args = object
        default: return encode(["id": id, "error": ["message": "Malformed request: args must be a JSON object with the tool's arguments."]])
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do {
                box.response = ["id": id, "result": try await ClaudeTools.handle(tool: tool, args: args, client: client)]
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

    // MARK: Who is asking

    /// The program at the other end of the socket, by name: the app it runs inside
    /// ("Claude" for Claude.app) or its executable. Our own helper `mindtalk` is never
    /// the answer: then it is the program that started it (the MCP client). nil when
    /// the system won't say.
    static func peerName(of fd: Int32) -> String? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0, let path = path(of: pid) else { return nil }
        if URL(fileURLWithPath: path).lastPathComponent == "mindtalk" {
            guard let parent = parent(of: pid), parent > 1, let above = Self.path(of: parent) else { return nil }
            return clientName(fromPath: above)
        }
        return clientName(fromPath: path)
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))     // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// "Claude" for /Applications/Claude.app/Contents/MacOS/Claude; "claude" for a bare
    /// executable. The outermost .app, so a helper inside an app counts as the app.
    static func clientName(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let app = parts.first(where: { $0.hasSuffix(".app") && $0.count > 4 }) { return String(app.dropLast(4)) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        // `mindtalk folders` typed in a shell: the shell is the parent.
        if ["zsh", "bash", "sh", "fish", "dash", "tcsh", "ksh", "nu", "login"].contains(last) { return String(localized: "Terminalen") }
        return last
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"error\":{\"message\":\"The answer could not be encoded.\"}}".utf8)
    }

    // MARK: The fixed path

    /// `bin/mindtalk` → the helper in this bundle. Replaced when it points elsewhere
    /// (an older copy, a moved app) by the app in /Applications, or by any copy when
    /// there is no working link: a build run from Xcode never takes the link away from
    /// the installed app, which the assistant's configuration should keep reaching.
    static func installHelperLink() {
        let fm = FileManager.default
        let link = helperLinkURL, target = bundledHelperURL
        guard fm.fileExists(atPath: target.path) else {
            log.notice("no helper in the bundle at \(target.path, privacy: .public)")
            return
        }
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if current == target.path { return }
            let installed = Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
            // A link that still leads somewhere is another copy's: left, unless we are the installed app.
            guard installed || !fm.fileExists(atPath: current) else {
                log.notice("helper link stays at \(current, privacy: .public): this copy is not in /Applications")
                return
            }
        }
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
