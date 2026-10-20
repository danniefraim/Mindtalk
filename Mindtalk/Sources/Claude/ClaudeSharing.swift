import Foundation
import Combine
import os

// MARK: - AI-appar → MCP: what may be read, and what was
//
// The program the user picks (Claude, ChatGPT on Mac or any other that speaks MCP)
// reads meetings and thoughts through the helper `mindtalk` in the app bundle. The helper
// never reads the disk itself: it asks the running app over a local socket, and the app
// answers only while MCP is on. So one place decides, the log sees every call, and
// switching off is instant. On means everything; off means nothing.
//
// Off until switched on. Audio and voiceprints are never shared.

/// The log's places that aren't a name: kept as marks in no language, and put into words
/// when shown, so a log written while Mindtalk ran in English reads in Swedish after a
/// switch ("sökte i alla möten", not "sökte i All meetings"). Entries from before were
/// kept in words: those are known in both languages.
enum LogScope {
    static let all = "@all"
    static let thoughts = "@thoughts"
    static let off = "@refused:off"
    static let unknownFolder = "@refused:folder"
    static let unknownMeeting = "@refused:meeting"

    /// A stored scope as a mark, when it is one (or the words for one, from an older log).
    static func mark(_ stored: String) -> String {
        switch stored.trimmingCharacters(in: .whitespaces) {
        case all, "Alla möten", "All meetings": return all
        case thoughts, "Tankar", "Thoughts": return thoughts
        case off, "nekad: avstängt", "refused: switched off", "refused: turned off": return off
        case unknownFolder, "nekad: okänd mapp", "refused: unknown folder": return unknownFolder
        case unknownMeeting, "nekad: okänt möte", "refused: unknown meeting": return unknownMeeting
        default: return stored
        }
    }

    /// What it says in the app's language: the words for a mark, a name as it is.
    static func shown(_ stored: String) -> String {
        switch mark(stored) {
        case all: return String(localized: "Alla möten")
        case thoughts: return String(localized: "Tankar")
        case off: return String(localized: "nekad: avstängt")
        case unknownFolder: return String(localized: "nekad: okänd mapp")
        case unknownMeeting: return String(localized: "nekad: okänt möte")
        default: return legacyRefusal(stored) ?? stored
        }
    }

    /// Refusals only older versions made (the levels and parts before 2.0), in either language.
    private static func legacyRefusal(_ stored: String) -> String? {
        let known: [(sv: String, en: String, now: String)] = [
            ("nekad: hela texten", "refused: the full text", String(localized: "nekad: hela texten")),
            ("nekad: anteckningar", "refused: notes and marks", String(localized: "nekad: anteckningar")),
            ("nekad: möten", "refused: meetings", String(localized: "nekad: möten")),
            ("nekad: nivån", "refused: the level", String(localized: "nekad: nivån")),
            ("nekad: sammanfattningar", "refused: summaries", String(localized: "nekad: sammanfattningar")),
            ("nekad: tankar", "refused: thoughts", String(localized: "nekad: tankar")),
        ]
        return known.first { $0.sv == stored || $0.en == stored }?.now
    }
}

/// The owner's choices under Inställningar → AI-appar → MCP.
@MainActor
final class ClaudeSharing: ObservableObject {
    static let shared = ClaudeSharing()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Claude")

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
        /// Where it looked: a meeting title or a folder name as they are, or one of
        /// LogScope's marks (all meetings, thoughts). Refused: LogScope's mark for what was
        /// refused, never an id. Shown with LogScope.shown, in the app's language then.
        var scope: String
        /// How many meetings, thoughts or hits came back.
        var items: Int
        /// How much text went out, in characters.
        var characters: Int
        /// The program that asked ("Claude"), when the bridge could tell.
        var client: String? = nil
        /// The settings said no: nothing went out.
        var refused: Bool? = nil
        /// Refused this many times in a row, when more than once: the same refusal again
        /// and again is one line.
        var times: Int? = nil
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
        connectedOnce = defaults.bool(forKey: "claude.connectedOnce")
        enableExplained = defaults.bool(forKey: "claude.enableExplained")
        if let data = try? Data(contentsOf: Self.logURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        // A self-test or a screenshot (any "--" flag) runs with your own settings and
        // must leave them, and the marker, as they are.
        let selfTest = CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") })
        // The marker as the setting is, also after an update that introduced it.
        if !selfTest {
            let on = enabled
            Self.io.async { Self.setMarker(on) }
        }
        // Keys from the settings that came and went before 2.0 (levels, boxes, folder
        // ticks), dropped once.
        if !selfTest {
            for key in ["claude.parts", "claude.level", "claude.excludedFolders", "claude.shareUnfiled"]
            where defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: Which meetings may be read

    /// THE one place that decides whether a meeting may be read: every tool asks it
    /// (ClaudeTools.visibleMeetings), and the command line goes through the tools.
    /// MCP on means everything that is over: not being recorded or finished, not cut off
    /// by a crash, its notes not being written, and ended at least `grace` ago.
    func allows(_ m: MeetingRecord, now: Date = Date()) -> Bool {
        guard m.finished, m.id != MeetingSession.shared.record?.id, !MeetingNotes.shared.writing.contains(m.id) else { return false }
        return now.timeIntervalSince(Self.finishedAt(m)) >= Self.grace
    }

    /// A meeting must be over before it can be read: finished this long ago, so the notes
    /// and the last words have settled.
    static let grace: TimeInterval = 120

    /// When the meeting was over: when it was last done by the clock (a pause or a
    /// continuation makes that later than its start plus its length), its start plus
    /// its length for meetings from before that was kept, or the moment it was imported.
    static func finishedAt(_ m: MeetingRecord) -> Date {
        let length = m.duration > 0 ? m.duration : (m.words.last?.end ?? 0)
        return max(m.endedAt ?? .distantPast, m.date.addingTimeInterval(length), m.source?.importedAt ?? .distantPast)
    }

    /// A refusal like the one before, from the same program within this long, adds to it.
    static let repeatWindow: TimeInterval = 60

    /// Noted after every answer, and after every refusal. Kept to the last 200.
    func record(tool: String, scope: String, items: Int, characters: Int, client: String? = nil, refused: Bool = false) {
        // A program that keeps asking while MCP is off (or for the same unknown meeting)
        // counts up one line, and doesn't push what was read out of the log.
        let now = Date()
        if refused, let last = entries.first, last.wasRefused, LogScope.mark(last.scope) == LogScope.mark(scope), last.client == client,
           now.timeIntervalSince(last.date) < Self.repeatWindow {
            entries[0].times = (last.times ?? 1) + 1
            entries[0].date = now
            entries[0].tool = tool
            Self.save(entries)
            return
        }
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
    func preview(enabled on: Bool, entries demo: [Entry]) {
        previewing = true
        enabled = on
        connectedOnce = !demo.isEmpty
        enableExplained = on
        entries = demo
    }
    #endif
    /// A preview is on: nothing is saved.
    private var previewing = false
}
