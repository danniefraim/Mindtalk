import Foundation
import Combine
import os

// MARK: - Mindtalk i Claude: what may be read, and what was
//
// Claude (and other programs that speak MCP) read meetings and thoughts through the
// helper `mindtalk` in the app bundle. The helper never reads the disk itself: it asks
// the running app over a local socket, and the app answers only what these settings
// allow. So one place decides, the log sees every call, and switching off is instant.
//
// Off until switched on. Audio and voiceprints are never shared.

/// The owner's choices under Inställningar → Mindtalk i Claude.
@MainActor
final class ClaudeSharing: ObservableObject {
    static let shared = ClaudeSharing()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Claude")

    /// How much Claude may read. Each level includes the ones before it.
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
            case .summaries: return String(localized: "Tankar och mötenas sammanfattningar, beslut och uppgifter")
            case .everything: return String(localized: "Allt, även hela texten från mötena")
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
        }
    }
    /// Everything by default: the owner chose that the connection, once on, reads it all.
    @Published var level: Level {
        didSet { if !previewing { defaults.set(level.rawValue, forKey: "claude.level") } }
    }
    /// Folders kept away from Claude. Meetings in no folder are shared.
    @Published var excludedFolders: Set<UUID> {
        didSet { if !previewing { defaults.set(excludedFolders.map(\.uuidString), forKey: "claude.excludedFolders") } }
    }

    /// One call Claude made: what it read, how much, when. The newest first.
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date = Date()
        /// The tool, as Claude names it ("mindtalk_search").
        var tool: String
        /// Where it looked, in words: a meeting title, a folder name, "Alla möten", "Tankar".
        var scope: String
        /// How many meetings, thoughts or hits came back.
        var items: Int
        /// How much text went out, in characters.
        var characters: Int
    }
    @Published private(set) var entries: [Entry] = []

    private let defaults = UserDefaults.standard
    nonisolated private static var logURL: URL {
        MeetingStore.root.deletingLastPathComponent().appendingPathComponent("ClaudeLog.json")
    }

    private init() {
        enabled = defaults.bool(forKey: "claude.enabled")
        level = Level(rawValue: defaults.string(forKey: "claude.level") ?? "") ?? .everything
        excludedFolders = Set((defaults.stringArray(forKey: "claude.excludedFolders") ?? []).compactMap(UUID.init))
        if let data = try? Data(contentsOf: Self.logURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Whether this folder's meetings may be read. nil is "no folder": shared.
    func allows(folder: UUID?) -> Bool {
        guard let folder else { return true }
        return !excludedFolders.contains(folder)
    }

    /// Noted after every answer to Claude. Kept to the last 200.
    func record(tool: String, scope: String, items: Int, characters: Int) {
        entries.insert(Entry(tool: tool, scope: scope, items: items, characters: characters), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        let snapshot = entries
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.logURL, options: .atomic)
            }
        }
    }

    func clearLog() {
        entries = []
        try? FileManager.default.removeItem(at: Self.logURL)
    }

    #if DEBUG
    /// Screenshots (`--render-claude`): on or off with a made-up log, in memory only.
    /// Nothing is written: the settings and the log on disk are left as they are.
    func preview(enabled on: Bool, level: Level = .everything, entries demo: [Entry]) {
        previewing = true
        enabled = on
        self.level = level
        excludedFolders = []
        entries = demo
    }
    #endif
    /// A preview is on: nothing is saved.
    private var previewing = false
}
