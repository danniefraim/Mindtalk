import Foundation

// MARK: - mindtalk:// links
//
// Every answer the helper gives carries a link back into the app, so "Styrelsemöte 14 okt,
// 12:04" opens that meeting at that second:
//
//   mindtalk://meeting/<uuid>?t=<seconds>     Möten, the meeting, its text at t (and played from there)
//   mindtalk://thought/<uuid>                 Tankar, scrolled to the thought
//   mindtalk://settings/mcp                   Inställningar, on Integrationer (MCP)
//                                             (mindtalk://settings/claude still works, the old name)
//
// The scheme is registered in Info.plist (CFBundleURLTypes); AppDelegate hands the
// URLs here. Anything else is ignored, with a line in the log.

enum MindtalkLink: Equatable {
    case meeting(UUID, at: Double?)
    case thought(UUID)
    /// Inställningar → Integrationer → MCP.
    case mcpSettings

    static let scheme = "mindtalk"

    /// nil for a URL that isn't one of ours.
    static func parse(_ url: URL) -> MindtalkLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // "mindtalk://meeting/<id>": the host is the kind, the path the id.
        let kind = url.host?.lowercased() ?? ""
        let rest = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch kind {
        case "meeting":
            guard let id = rest.first.flatMap(UUID.init(uuidString:)) else { return nil }
            // "?t=" must be a real number of seconds: NaN, infinity and a negative are 0.
            let t = query.first { $0.name == "t" }?.value.flatMap(Double.init)
            return .meeting(id, at: t.map { $0.isFinite ? max(0, $0) : 0 })
        case "thought":
            guard let id = rest.first.flatMap(UUID.init(uuidString:)) else { return nil }
            return .thought(id)
        case "settings":
            switch rest.first?.lowercased() {
            case "mcp", "claude": return .mcpSettings
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The link for a meeting (the helper puts these in its answers).
    static func url(meeting id: UUID, at seconds: Double? = nil) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "meeting"
        c.path = "/" + id.uuidString
        // Rounded down, as the helper's links are (ClaudeTools.link), and never a trap.
        if let seconds { c.queryItems = [URLQueryItem(name: "t", value: String(ClaudeTools.clampedInt(seconds, .down)))] }
        return c.url!
    }

    static func url(thought id: UUID) -> URL {
        URL(string: "\(scheme)://thought/\(id.uuidString)")!
    }

    static let mcpSettingsURL = URL(string: "\(scheme)://settings/mcp")!
}

extension Notification.Name {
    /// Open a saved meeting on the Möten page (object: UUID; userInfo["at"]: seconds).
    static let openMeeting = Notification.Name("MindtalkOpenMeeting")
    /// Show a thought on the Tankar page (object: UUID).
    static let showThought = Notification.Name("MindtalkShowThought")
}
