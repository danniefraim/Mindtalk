import Foundation
import Logging
import MCP

// MARK: - The stdio transport, forgiving about what a client says it can do
//
// The Swift SDK (0.12.1, also its main branch) reads the client's
// `capabilities.experimental` as [String: String], but the spec makes every value an
// object, and ChatGPT and Codex send one: {"experimental": {"codex/auth-change": {}}}.
// The whole initialize then fails as -32603 "The data couldn't be read because it isn't
// in the correct format", and the app never gets to list the tools.
//
// The server uses nothing the client says it can do (no sampling, no elicitation, no
// roots), so an initialize the SDK cannot read is repaired before it gets there: first
// `experimental` is dropped, then, if that is not enough, the capabilities, then
// everything in clientInfo but its name and version. Every other message, and an
// initialize that reads as it is (Claude's), passes through byte for byte.

actor LenientTransport: Transport {
    private let inner: StdioTransport
    nonisolated var logger: Logging.Logger { inner.logger }

    init(_ inner: StdioTransport = StdioTransport()) { self.inner = inner }

    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    func send(_ data: Data) async throws { try await inner.send(data) }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let upstream = inner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await upstream.receive() {
                        continuation.yield(Lenient.repair(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum Lenient {
    /// The message as the SDK can read it: unchanged unless it is an initialize request
    /// (alone or in a batch) whose params do not decode.
    static func repair(_ data: Data) -> Data {
        guard data.range(of: Data("\"initialize\"".utf8)) != nil,
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return data }
        if let message = json as? [String: Any] {
            guard let fixed = repaired(message) else { return data }
            return (try? JSONSerialization.data(withJSONObject: fixed)) ?? data
        }
        if let batch = json as? [Any] {
            var changed = false
            let fixed = batch.map { item -> Any in
                guard let message = item as? [String: Any], let fixed = repaired(message) else { return item }
                changed = true
                return fixed
            }
            guard changed else { return data }
            return (try? JSONSerialization.data(withJSONObject: fixed)) ?? data
        }
        return data
    }

    /// nil when the message needs nothing.
    private static func repaired(_ message: [String: Any]) -> [String: Any]? {
        guard message["method"] as? String == Initialize.name,
              var params = message["params"] as? [String: Any],
              !decodes(params)
        else { return nil }
        var dropped: [String] = []

        if var capabilities = params["capabilities"] as? [String: Any] {
            if capabilities["experimental"] != nil {
                capabilities.removeValue(forKey: "experimental")
                params["capabilities"] = capabilities
                dropped.append("capabilities.experimental")
            }
        } else if params["capabilities"] != nil {
            params.removeValue(forKey: "capabilities")
            dropped.append("capabilities")
        }
        if !decodes(params), params["capabilities"] != nil {
            params["capabilities"] = [String: Any]()
            dropped.append("capabilities")
        }
        if !decodes(params), let info = params["clientInfo"] {
            let info = info as? [String: Any] ?? [:]
            var plain: [String: Any] = [:]
            if let name = info["name"] as? String { plain["name"] = name }
            if let version = info["version"] as? String { plain["version"] = version }
            if plain.count == 2 { params["clientInfo"] = plain } else { params.removeValue(forKey: "clientInfo") }
            dropped.append("clientInfo")
        }
        if !decodes(params), params["protocolVersion"] != nil, !(params["protocolVersion"] is String) {
            params.removeValue(forKey: "protocolVersion")
            dropped.append("protocolVersion")
        }

        log.notice("initialize: left out \(dropped.joined(separator: ", "), privacy: .public), which the SDK cannot read")
        var message = message
        message["params"] = params
        return message
    }

    private static func decodes(_ params: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return false }
        return (try? JSONDecoder().decode(Initialize.Parameters.self, from: data)) != nil
    }
}
