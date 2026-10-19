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

    /// What may be read, one box each on the card. Any of the three meeting parts makes
    /// the meetings listable: their title, date, length, folder and who spoke.
    struct Parts: OptionSet, Codable, Hashable {
        let rawValue: Int
        /// Tankar.
        static let thoughts = Parts(rawValue: 1 << 0)
        /// The summary Mindtalk wrote: its title, overview, decisions, tasks and points.
        static let summaries = Parts(rawValue: 1 << 1)
        /// What you wrote yourself: your notes, and the moments you marked.
        static let notes = Parts(rawValue: 1 << 2)
        /// What was said, the whole text.
        static let transcripts = Parts(rawValue: 1 << 3)

        static let all: Parts = [.thoughts, .summaries, .notes, .transcripts]
        static let meetings: Parts = [.summaries, .notes, .transcripts]
        /// One at a time, in the card's order.
        static let each: [Parts] = [.thoughts, .summaries, .notes, .transcripts]

        /// The box on the card.
        var title: String {
            switch self {
            case .thoughts: return String(localized: "Tankar")
            case .summaries: return String(localized: "Mötenas sammanfattningar")
            case .notes: return String(localized: "Dina anteckningar och markeringar")
            default: return String(localized: "Mötenas hela text")
            }
        }
        /// The box as the English card names it: what the assistant is told was not ticked.
        var english: String {
            switch self {
            case .thoughts: return "Thoughts"
            case .summaries: return "Meeting summaries"
            case .notes: return "Your notes and marks"
            default: return "Meetings’ full text"
            }
        }
        /// The log's line for a refusal of this part.
        var refusal: String {
            switch self {
            case .thoughts: return String(localized: "nekad: tankar")
            case .summaries: return String(localized: "nekad: sammanfattningar")
            case .notes: return String(localized: "nekad: anteckningar")
            default: return String(localized: "nekad: hela texten")
            }
        }
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
    /// All four by default: the owner chose that the connection, once on, reads it all.
    @Published var parts: Parts {
        didSet { if !previewing { defaults.set(parts.rawValue, forKey: "claude.parts") } }
    }
    /// Any of the meeting boxes is ticked: the meetings can be listed.
    var meetingsShared: Bool { !parts.isDisjoint(with: .meetings) }
    /// "Lägg till i Claude" was pressed, or a setting copied, once.
    @Published var connectedOnce: Bool {
        didSet { if !previewing { defaults.set(connectedOnce, forKey: "claude.connectedOnce") } }
    }
    /// The owner has seen "Slå på MCP?" (where the text goes, what is never shared) and
    /// pressed Slå på once: the card asks the first time only.
    @Published var enableExplained: Bool {
        didSet { if !previewing { defaults.set(enableExplained, forKey: "claude.enableExplained") } }
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
        if let raw = defaults.object(forKey: "claude.parts") as? Int {
            parts = Parts(rawValue: raw).intersection(.all)
        } else {
            parts = Self.parts(fromLevel: defaults.string(forKey: "claude.level"))
        }
        connectedOnce = defaults.bool(forKey: "claude.connectedOnce")
        enableExplained = defaults.bool(forKey: "claude.enableExplained")
        if let data = try? Data(contentsOf: Self.logURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        // The marker as the setting is, also after an update that introduced it.
        let on = enabled
        Self.io.async { Self.setMarker(on) }
        // The settings from before the boxes, moved over once. Not in a self-test or a
        // screenshot (any "--" flag): those run with your own settings and must leave
        // them, and your meetings, as they are.
        if !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
            legacyExcluded = Set((defaults.stringArray(forKey: "claude.excludedFolders") ?? []).compactMap(UUID.init))
            legacyHideUnfiled = defaults.object(forKey: "claude.shareUnfiled") as? Bool == false
            if defaults.object(forKey: "claude.level") != nil || !legacyExcluded.isEmpty || legacyHideUnfiled {
                Task { @MainActor in
                    if await Self.migrate(defaults, folders: .shared, store: .shared) {
                        self.legacyExcluded = []
                        self.legacyHideUnfiled = false
                    }
                }
            }
        }
    }

    // MARK: Which meetings may be read

    /// THE one place that decides whether a meeting may be read: every tool asks it
    /// (ClaudeTools.visibleMeetings), and the command line goes through the tools.
    ///   • a meeting box is ticked,
    ///   • not hidden from AI apps, by itself or by its folder,
    ///   • over: not being recorded or finished, not cut off by a crash, its notes not
    ///     being written, and ended at least `grace` ago (the owner may still be hiding it).
    func allows(_ m: MeetingRecord, now: Date = Date()) -> Bool {
        guard meetingsShared, !m.hiddenFromAI else { return false }
        let folder = MeetingFolders.shared.folder(of: m)
        if folder?.hiddenFromAI == true { return false }
        // Until the old settings are moved over: a folder unticked, or "Utan mapp".
        if let id = folder?.id, legacyExcluded.contains(id) { return false }
        if folder == nil, legacyHideUnfiled { return false }
        guard m.finished, m.id != MeetingSession.shared.record?.id, !MeetingNotes.shared.writing.contains(m.id) else { return false }
        return now.timeIntervalSince(Self.finishedAt(m)) >= Self.grace
    }

    /// A folder may be listed: meetings are shared and it isn't hidden.
    func allows(folder f: MeetingFolder) -> Bool {
        meetingsShared && !f.hiddenFromAI && !legacyExcluded.contains(f.id)
    }

    /// A meeting must be over before it can be read: finished this long ago, so the owner
    /// has a moment to hide it or put it in a hidden folder.
    static let grace: TimeInterval = 120

    /// When the meeting was over: its start plus its length, or the moment it was imported.
    static func finishedAt(_ m: MeetingRecord) -> Date {
        let length = m.duration > 0 ? m.duration : (m.words.last?.end ?? 0)
        return max(m.date.addingTimeInterval(length), m.source?.importedAt ?? .distantPast)
    }

    // MARK: From the levels and the folder ticks (before 2.0)

    /// Folders unticked, and "Utan mapp" unticked, under the old settings: kept away
    /// until the move below has gone through, so nothing hidden is shown meanwhile.
    private var legacyExcluded: Set<UUID> = []
    private var legacyHideUnfiled = false

    /// One level became the boxes it covered. No level: all four, as before.
    static func parts(fromLevel level: String?) -> Parts {
        switch level {
        case "thoughts": return [.thoughts]
        case "summaries": return [.thoughts, .summaries, .notes]
        default: return .all
        }
    }

    /// Moves the old settings over, once: the level to the boxes, an unticked folder to
    /// "Dölj för AI-program" on it, and with "Utan mapp" unticked every meeting in no
    /// folder (or one since removed) hidden by itself, so nothing that was hidden comes
    /// into view. The old keys go only when everything was written. `defaults` is your
    /// own, or a test's.
    static func migrate(_ defaults: UserDefaults, folders: MeetingFolders, store: MeetingStore) async -> Bool {
        if defaults.object(forKey: "claude.parts") == nil, defaults.object(forKey: "claude.level") != nil {
            defaults.set(parts(fromLevel: defaults.string(forKey: "claude.level")).rawValue, forKey: "claude.parts")
        }
        var done = true
        let excluded = Set((defaults.stringArray(forKey: "claude.excludedFolders") ?? []).compactMap(UUID.init))
        for id in excluded where folders.folder(id) != nil {
            if !folders.setHiddenFromAI(true, folder: id) { done = false }
        }
        if defaults.object(forKey: "claude.shareUnfiled") as? Bool == false {
            await store.ready()
            let loose = store.meetings.filter { folders.folder(of: $0) == nil && !$0.hiddenFromAI }.map(\.id)
            store.setHiddenFromAI(true, of: loose)
            store.flushQuietSaves()
        }
        guard done else { return false }
        for key in ["claude.level", "claude.excludedFolders", "claude.shareUnfiled"] { defaults.removeObject(forKey: key) }
        log.notice("moved the old sharing settings over")
        return true
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
    /// Screenshots (`--render-mcp`) and self-tests: on or off with a made-up log, in
    /// memory only. Nothing is written: the settings and the log on disk are left as they are.
    func preview(enabled on: Bool, parts: Parts = .all, entries demo: [Entry]) {
        previewing = true
        enabled = on
        self.parts = parts
        legacyExcluded = []
        legacyHideUnfiled = false
        connectedOnce = !demo.isEmpty
        enableExplained = on
        entries = demo
    }
    #endif
    /// A preview is on: nothing is saved.
    private var previewing = false
}
