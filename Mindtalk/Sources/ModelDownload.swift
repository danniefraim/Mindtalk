import CryptoKit
import Foundation
import os

// MARK: - Model downloads that pick up where they stopped
//
// The models are large (Gemma 4 is 16 GB in three files) and Hugging Face can be
// slow to start: the first request for a file at a server near you may crawl
// while that server fetches it. So a large file is fetched in parts of 16 MB, four
// at a time, written straight into place in one file, and a small ledger next to
// it says which parts are in. A lost connection, a quit or a restart costs only
// the parts that were under way; the next try continues from there.
//
// A file is only put in place once its SHA-256 matches the pinned one — a file at
// its final path is a checked file.

enum ModelDownload {
    static let partSize: Int64 = 16 << 20
    static let parallel = 4
    /// Small files come in one request.
    static let wholeBelow: Int64 = 32 << 20

    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Download")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = parallel + 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Fetches `file` to `dest` and checks it. `progress` gets the bytes of this file
    /// that are in — from the start, counting what an earlier try already got.
    static func fetch(_ url: URL, file: SpeechModel.RemoteFile, to dest: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Already here and checked by an earlier try.
        if let size = try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64, size == file.size {
            progress(file.size)
            return
        }
        if file.size < wholeBelow {
            try await whole(url, file: file, to: dest)
        } else {
            try await inParts(url, file: file, to: dest, progress: progress)
        }
        progress(file.size)
    }

    private static func whole(_ url: URL, file: SpeechModel.RemoteFile, to dest: URL) async throws {
        let data = try await attempt(file.path) {
            let (data, response) = try await session.data(from: url)
            try check(response, file.path, expect: 200)
            guard Int64(data.count) == file.size else { throw URLError(.cannotParseResponse) }
            return data
        }
        guard matches(data, file) else { throw ModelError.checksumMismatch(file.path) }
        try data.write(to: dest, options: .atomic)
    }

    private static func inParts(_ url: URL, file: SpeechModel.RemoteFile, to dest: URL,
                                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        let partial = dest.appendingPathExtension("part")
        let ledger = dest.appendingPathExtension("parts")
        if !fm.fileExists(atPath: partial.path) {
            try? fm.removeItem(at: ledger)
            guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let count = Int((file.size + partSize - 1) / partSize)
        let writer = try PartWriter(file: partial, size: file.size, ledger: ledger, parts: count)
        let already = await writer.bytesIn
        if already > 0 { log.info("\(file.path, privacy: .public): continuing at \(already / 1_000_000) MB") }
        progress(already)

        let todo = await writer.missing
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = todo.makeIterator()
            func start() -> Bool {
                guard let i = next.next() else { return false }
                group.addTask {
                    let from = Int64(i) * partSize
                    let to = min(file.size, from + partSize) - 1
                    let data = try await attempt(file.path) {
                        var request = URLRequest(url: url)
                        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
                        // Streamed, and the reply checked first: a server that answers a range
                        // with the whole file (200) is refused before a byte of it is kept.
                        let (bytes, response) = try await session.bytes(for: request)
                        try check(response, file.path, expect: 206)
                        let expected = to - from + 1
                        let length = response.expectedContentLength
                        guard length < 0 || length == expected else { throw URLError(.cannotParseResponse) }
                        var data = Data(capacity: Int(expected))
                        for try await byte in bytes {
                            data.append(byte)
                            if Int64(data.count) == expected { break }
                        }
                        guard Int64(data.count) == expected else { throw URLError(.networkConnectionLost) }
                        return data
                    }
                    let total = try await writer.store(data, part: i, at: from)
                    progress(total)
                }
                return true
            }
            for _ in 0..<parallel where start() {}
            while try await group.next() != nil { _ = start() }
        }
        try await writer.close()

        // Checked before it goes in place; a bad file starts over next time.
        guard try sha256(of: partial) == file.sha256 else {
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: ledger)
            throw ModelError.checksumMismatch(file.path)
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: partial, to: dest)
        try? fm.removeItem(at: ledger)
    }

    /// Three more tries after a dropped connection or a server hiccup, a little
    /// later each time — as long as the server asks, within reason, when it says
    /// so (Retry-After on 429 and 503). Not after a cancel, and not after a refusal
    /// (403, 404) or a whole file sent for a range: those come back the same.
    private static func attempt<T>(_ what: String, _ work: () async throws -> T) async throws -> T {
        var wait = 1.0
        for _ in 0..<3 {
            do { return try await work() } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                var pause = wait
                if case ModelError.badResponse(_, let code, let retryAfter) = error {
                    if (400..<500).contains(code), code != 429 { throw error }
                    if code == 200 { throw error }
                    if code == 429 || code == 503, let retryAfter { pause = min(60, max(pause, retryAfter)) }
                }
                log.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public) – trying again in \(Int(pause)) s")
                try await Task.sleep(for: .seconds(pause))
                wait *= 3
            }
        }
        return try await work()
    }

    private static func check(_ response: URLResponse, _ path: String, expect: Int) throws {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == expect else {
            // "Retry-After: 30" (seconds) or a date; a date is turned into seconds from now.
            let header = http?.value(forHTTPHeaderField: "Retry-After")
            let seconds = header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                ?? header.flatMap { httpDate.date(from: $0)?.timeIntervalSinceNow }
            throw ModelError.badResponse(path, code, seconds.map { max(0, $0) })
        }
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Streams the file through SHA-256 so a 5 GB file never sits in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A small file is checked against its SHA-256 — or, written "git:…", against the
    /// id the model's repository gives it (Git's own hash of the file), so a pinned
    /// revision can be checked without downloading its small files beforehand.
    private static func matches(_ data: Data, _ file: SpeechModel.RemoteFile) -> Bool {
        guard file.sha256.hasPrefix("git:") else { return digest(of: data) == file.sha256 }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return "git:" + hasher.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    /// Bytes on disk in a folder — what an interrupted download already has
    /// (a file being filled in parts takes only the parts written).
    static func allocatedBytes(in folder: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// Writes parts into place, one at a time, and keeps the ledger of what's in.
private actor PartWriter {
    private let handle: FileHandle
    private let ledger: URL
    private let size: Int64
    private let parts: Int
    private var done: Set<Int>

    init(file: URL, size: Int64, ledger: URL, parts: Int) throws {
        handle = try FileHandle(forWritingTo: file)
        // The full length up front: the parts are written where they belong. APFS
        // keeps the gaps empty, so this takes no space of its own.
        try handle.truncate(atOffset: UInt64(size))
        self.ledger = ledger
        self.size = size
        self.parts = parts
        let saved = (try? Data(contentsOf: ledger)).flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        done = Set(saved.filter { $0 >= 0 && $0 < parts })
    }

    var missing: [Int] { (0..<parts).filter { !done.contains($0) } }
    var bytesIn: Int64 { done.reduce(0) { $0 + length(of: $1) } }

    private func length(of part: Int) -> Int64 {
        let from = Int64(part) * ModelDownload.partSize
        return min(size, from + ModelDownload.partSize) - from
    }

    /// Returns the bytes now in.
    func store(_ data: Data, part: Int, at offset: Int64) throws -> Int64 {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        done.insert(part)
        // The data first, then the ledger: a part in the ledger is always on disk.
        try handle.synchronize()
        try JSONEncoder().encode(done.sorted()).write(to: ledger, options: .atomic)
        return bytesIn
    }

    func close() throws { try handle.close() }
}
