import Foundation
import Combine
import os

// MARK: - Integrationer → MCP: what may be read, and what was
//
// The program the user picks (Claude, ChatGPT on Mac or any other that speaks MCP)
// reads meetings and thoughts through the helper `mindtalk` in the app bundle. The helper never reads the disk itself: it asks
// the running app over a local socket, and the app answers only what these settings
// allow. So one place decides, the log sees every call, and switching off is instant.
//
// Off until switched on. Audio and voiceprints are never shared.

/// The owner's choices under Inställningar → Integrationer → MCP.
@MainActor
final class ClaudeSharing: ObservableObject {
    static let shared = ClaudeSharing()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Claude")

    /// How much may be read. Each level includes the ones before it.
    enum Level: String, CaseIterable, Identifiable, Codable {
        /// Only Tankar.
        case thoughts
        /// Thoughts, and for meetings the summary: overview, decisions, tasks, your notes and marks.
        case summaries
        /// All of that and the whole text of what was said.
        case everything
        var id: String { rawValue }

        var title: String {
            switch self {
            case .thoughts: return String(localized: "Bara tankar")
            case .summaries: return String(localized: "Tankar, sammanfattningar och anteckningar")
            case .everything: return String(localized: "Allt, även texten från mötena")
            }
        }
        var includesMeetings: Bool { self != .thoughts }
        var includesTranscripts: Bool { self == .everything }
    }

    /// Switched on by the owner. Off: the helper is told so, and nothing is answered.
    @Published var enabled: Bool {
        didSet {
            guard !previewing else { return }
            defaults.set(enabled, forKey: "claude.enabled")
            Self.log.notice("sharing \(self.enabled ? "on" : "off", privacy: .public)")
            Self.setMarker(enabled)
        }
    }

    /// `~/Library/Application Support/Mindtalk/mcp.on`: there while MCP is on. The helper
    /// looks for it before it opens the app: switched off, a program that asks is told
    /// so without Mindtalk being started for it.
    nonisolated static var markerURL: URL { Bridge.supportFolder.appendingPathComponent("mcp.on") }
    nonisolated private static func setMarker(_ on: Bool) {
        let fm = FileManager.default
        if on {
            try? fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            fm.createFile(atPath: markerURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.removeItem(at: markerURL)
        }
    }
    /// Everything by default: the owner chose that the connection, once on, reads it all.
    @Published var level: Level {
        didSet { if !previewing { defaults.set(level.rawValue, forKey: "claude.level") } }
    }
    /// Folders kept away from every program. Meetings in no folder are shared.
    @Published var excludedFolders: Set<UUID> {
        didSet { if !previewing { defaults.set(excludedFolders.map(\.uuidString), forKey: "claude.excludedFolders") } }
    }
    /// "Lägg till i Claude" was pressed, or a setting copied, once.
    @Published var connectedOnce: Bool {
        didSet { if !previewing { defaults.set(connectedOnce, forKey: "claude.connectedOnce") } }
    }
    /// The owner has seen "Slå på MCP?" (where the text goes, what is never shared) and
    /// pressed Slå på once: the card asks the first time only.
    @Published var enableExplained: Bool {
        didSet { if !previewing { defaults.set(enableExplained, forKey: "claude.enableExplained") } }
    }
    /// The program that read something most recently, as the log names it ("Claude"),
    /// so the card can offer that program first.
    var lastClient: String? {
        entries.first { !($0.client ?? "").isEmpty }?.client
    }

    /// One call a program made: what it read, how much, when. The newest first.
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date = Date()
        /// The tool, as the program names it ("mindtalk_search").
        var tool: String
        /// Where it looked, in words: a meeting title, a folder name, "Alla möten", "Tankar".
        /// Refused: what was refused ("nekad: hela texten"), never an id.
        var scope: String
        /// How many meetings, thoughts or hits came back.
        var items: Int
        /// How much text went out, in characters.
        var characters: Int
        /// The program that asked ("Claude"), when the bridge could tell.
        var client: String? = nil
        /// The settings said no: nothing went out.
        var refused: Bool? = nil
        var wasRefused: Bool { refused == true }
    }
    @Published private(set) var entries: [Entry] = []

    private let defaults = UserDefaults.standard
    nonisolated private static var logURL: URL {
        MeetingStore.root.deletingLastPathComponent().appendingPathComponent("ClaudeLog.json")
    }

    /// The log is read and written on one queue, in order: a clearing never races a
    /// write that was on its way.
    private static let io = DispatchQueue(label: "ai.mindact.mindtalk.claude-log", qos: .utility)

    private init() {
        enabled = defaults.bool(forKey: "claude.enabled")
        level = Level(rawValue: defaults.string(forKey: "claude.level") ?? "") ?? .everything
        excludedFolders = Set((defaults.stringArray(forKey: "claude.excludedFolders") ?? []).compactMap(UUID.init))
        connectedOnce = defaults.bool(forKey: "claude.connectedOnce")
        enableExplained = defaults.bool(forKey: "claude.enableExplained")
        if let data = try? Data(contentsOf: Self.logURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        // The marker as the setting is, also after an update that introduced it.
        let on = enabled
        Self.io.async { Self.setMarker(on) }
    }

    /// Whether this folder's meetings may be read. nil is "no folder": shared.
    func allows(folder: UUID?) -> Bool {
        guard let folder else { return true }
        return !excludedFolders.contains(folder)
    }

    /// Noted after every answer, and after every refusal. Kept to the last 200.
    func record(tool: String, scope: String, items: Int, characters: Int, client: String? = nil, refused: Bool = false) {
        entries.insert(Entry(tool: tool, scope: scope, items: items, characters: characters, client: client,
                             refused: refused ? true : nil), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        Self.save(entries)
    }

    func clearLog() {
        entries = []
        Self.save([])
    }

    /// The log on disk, readable by you alone.
    nonisolated private static func save(_ snapshot: [Entry]) {
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
    }

    #if DEBUG
    /// Screenshots (`--render-mcp`): on or off with a made-up log, in memory only.
    /// Nothing is written: the settings and the log on disk are left as they are.
    func preview(enabled on: Bool, level: Level = .everything, entries demo: [Entry]) {
        previewing = true
        enabled = on
        self.level = level
        excludedFolders = []
        connectedOnce = !demo.isEmpty
        enableExplained = on
        entries = demo
    }
    #endif
    /// A preview is on: nothing is saved.
    private var previewing = false
}
