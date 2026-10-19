import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - Folders
//
// A meeting can be in one folder ("Kund X", "Styrelsen") — or in none, and then it's
// only under "Alla". The folder is a field of the meeting (MeetingRecord.folder);
// the folders themselves, their names, are kept in Folders.json beside the
// meetings. Nothing moves on disk, so renaming a folder only changes its name, and
// taking a folder away never takes a meeting with it: a meeting whose folder is
// gone simply has none (`folder(of:)`) — and comes back to it if the folder list
// is ever put back.

struct MeetingFolder: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()

    init(name: String) { self.name = name }

    // Lenient, like the meetings: a folder missing a field still opens, and one written
    // with a field since dropped ("hiddenFromAI") opens as if it weren't there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? String(localized: "Mapp")
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
    }
}

/// One or more meetings being dragged — a type of Mindtalk's own (declared in
/// Info.plist), so text dragged from elsewhere is never taken for a meeting.
struct MeetingDrag: Codable, Transferable {
    var ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mindtalkMeeting)
    }
}

extension UTType {
    static let mindtalkMeeting = UTType(exportedAs: "ai.mindact.mindtalk.meeting")
}

@MainActor
final class MeetingFolders: ObservableObject {
    static let shared = MeetingFolders()

    @Published private(set) var folders: [MeetingFolder] = []
    /// The folder the list shows — nil: "Alla". (Not kept across launches: Mindtalk
    /// opens on all your meetings.)
    @Published var selected: UUID?
    /// The last move, for "Ångra" — gone after a few seconds.
    @Published private(set) var lastMove: Move?
    /// Saving the folders failed (the disk, the file's rights): said where they are.
    @Published private(set) var problem: String?

    struct Move: Equatable {
        let id = UUID()
        let ids: [UUID]
        let before: [UUID: UUID?]
        let to: String
    }

    /// Folders.json couldn't be read for a reason other than not being there yet:
    /// it is never written over this run — it may well hold your folders.
    private var readOnly = false

    private init() {
        folders = read()
    }

    nonisolated private static var url: URL { MeetingStore.root.appendingPathComponent("Folders.json") }

    private func read() -> [MeetingFolder] {
        let data: Data
        do { data = try Data(contentsOf: Self.url) } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile { return [] }
            NSLog("Mindtalk: could not read Folders.json: \(error.localizedDescription)")
            readOnly = true
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Folder by folder: one that can't be read doesn't take the others with it.
        struct Lossy: Decodable {
            let folder: MeetingFolder?
            init(from decoder: Decoder) throws { folder = try? MeetingFolder(from: decoder) }
        }
        do {
            return try decoder.decode([Lossy].self, from: data).compactMap(\.folder)
        } catch {
            // Not a list at all: kept aside, never written over.
            NSLog("Mindtalk: could not read Folders.json: \(error.localizedDescription)")
            try? FileManager.default.moveItem(at: Self.url, to: Self.url.deletingLastPathComponent()
                .appendingPathComponent("Folders-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return []
        }
    }

    /// Writes the folders; false — and nothing changed — if it couldn't.
    private func write(_ new: [MeetingFolder]) -> Bool {
        guard !readOnly else {
            problem = String(localized: "Mapparna kunde inte läsas från disken och kan inte ändras just nu. Starta om Mindtalk.")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: MeetingStore.root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(new).write(to: Self.url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        } catch {
            NSLog("Mindtalk: could not save Folders.json: \(error.localizedDescription)")
            problem = String(localized: "Mapparna kunde inte sparas. Är disken full?")
            return false
        }
        folders = new
        problem = nil
        return true
    }

    func folder(_ id: UUID?) -> MeetingFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    /// The folder the meeting is in — nil also when its folder was taken away.
    func folder(of record: MeetingRecord) -> MeetingFolder? { folder(record.folder) }

    /// A name trimmed and unlike the others ("Kund X" twice becomes "Kund X 2").
    private func unique(_ name: String, except id: UUID? = nil) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(folders.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Whether another folder is called that already.
    func isTaken(_ name: String, except id: UUID? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folders.contains { $0.id != id && $0.name.lowercased() == name }
    }

    @discardableResult
    func create(_ name: String) -> MeetingFolder? {
        let name = unique(name)
        guard !name.isEmpty else { return nil }
        let folder = MeetingFolder(name: name)
        return write(folders + [folder]) ? folder : nil
    }

    func rename(_ id: UUID, to name: String) {
        let name = unique(name, except: id)
        guard !name.isEmpty, let i = folders.firstIndex(where: { $0.id == id }), folders[i].name != name else { return }
        var new = folders
        new[i].name = name
        _ = write(new)
    }

    /// The folder goes; its meetings stay — under "Alla" (they still name it, so a
    /// folder list put back brings them back too).
    func remove(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        guard write(folders.filter { $0.id != id }) else { return }
        if selected == id { selected = nil }
    }

    /// The folders in the order you see them, A to Ö.
    var sorted: [MeetingFolder] {
        folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Moving

    /// Meetings into a folder (nil: out of their folder) — remembered for "Ångra".
    func move(_ ids: [UUID], to folder: UUID?) {
        let store = MeetingStore.shared
        var before: [UUID: UUID?] = [:]
        for id in ids {
            let current = MeetingSession.shared.record?.id == id ? MeetingSession.shared.record?.folder
                : store.meetings.first(where: { $0.id == id })?.folder
            if current != folder { before[id] = current }
        }
        guard !before.isEmpty else { return }
        store.setFolder(folder, of: Array(before.keys))
        let move = Move(ids: Array(before.keys), before: before,
                        to: self.folder(folder)?.name ?? String(localized: "Alla"))
        lastMove = move
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.lastMove == move { self?.lastMove = nil }
        }
    }

    /// "Ångra": each meeting back where it was.
    func undoLastMove() {
        guard let move = lastMove else { return }
        lastMove = nil
        let store = MeetingStore.shared
        for (folder, ids) in Dictionary(grouping: move.before, by: { $0.value }) {
            store.setFolder(folder, of: ids.map(\.key))
        }
    }

    // MARK: Suggesting a folder

    /// The folder a meeting just written looks like it belongs in — or nil. Never put
    /// there by itself: the meeting page asks ("Lägg mötet i Kund X?").
    ///   • a folder's name in the title you gave or the notes' title ("Kund X – uppstart"),
    ///   • people in the meeting whose meetings are mostly in one folder — not
    ///     someone in nearly all your meetings (you, most likely): they say nothing.
    /// Only for meetings of the last two days, once their notes are written, and
    /// only one folder may fit.
    func suggestion(for record: MeetingRecord, among meetings: [MeetingRecord]) -> MeetingFolder? {
        guard folder(of: record) == nil, !record.folderAsked, record.finished, !folders.isEmpty,
              record.date > Date().addingTimeInterval(-2 * 86_400),
              record.summary != nil || !MeetingNotes.isAvailable,
              !MeetingNotes.shared.writing.contains(record.id) else { return nil }
        var score: [UUID: Double] = [:]
        // The title you gave, and the notes' title — not the default "Möte torsdag …".
        let text = ((record.userTitled ? record.title : "") + " " + (record.summary?.title ?? "")).lowercased()
        for folder in folders {
            let name = folder.name.lowercased()
            if name.count >= 3, Self.contains(text, word: name) { score[folder.id, default: 0] += 3 }
        }
        let people = Set(record.names.values.map { $0.lowercased() }.filter { !$0.isEmpty })
        let others = meetings.filter { $0.id != record.id }
        if !people.isEmpty, others.count >= 3 {
            var withName: [String: Int] = [:]
            var inFolder: [UUID: [String: Int]] = [:]
            for m in others {
                for n in Set(m.names.values.map { $0.lowercased() }) where people.contains(n) {
                    withName[n, default: 0] += 1
                    if let f = folder(of: m)?.id { inFolder[f, default: [:]][n, default: 0] += 1 }
                }
            }
            for (folder, names) in inFolder {
                for (name, n) in names {
                    let all = withName[name] ?? 0
                    // In half your meetings or more: everyone's colleague, no clue.
                    guard n >= 2, Double(all) <= Double(others.count) * 0.5, Double(n) >= Double(all) * 0.6 else { continue }
                    score[folder, default: 0] += 1.5
                }
            }
        }
        let ranked = score.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 1.5 else { return nil }
        if ranked.count > 1, ranked[1].value >= best.value - 0.5 { return nil }
        return folder(best.key)
    }

    /// Whole words: "Ica" in "Ica Maxi" but not in "Mexica".
    private static func contains(_ text: String, word: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: word, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
            let after = r.upperBound == text.endIndex || !text[r.upperBound].isLetter
            if before && after { return true }
            from = r.upperBound
        }
        return false
    }

    #if DEBUG
    /// Screenshots: folders in memory only — nothing written.
    func preview(_ names: [String]) {
        folders = names.map { MeetingFolder(name: $0) }
    }
    #endif
}

extension MeetingStore {
    /// Meetings into a folder, or out of it (nil). One that is being recorded changes
    /// in the session, which saves it; the others are written off the main thread —
    /// a folder of long meetings doesn't stall the page.
    func setFolder(_ folder: UUID?, of ids: [UUID]) {
        let session = MeetingSession.shared
        var changed = meetings
        for id in ids {
            if session.record?.id == id {
                session.setFolder(folder)
                continue
            }
            guard let i = changed.firstIndex(where: { $0.id == id }), changed[i].folder != folder else { continue }
            changed[i].folder = folder
            changed[i].folderAsked = true
            saveQuietly(changed[i])
        }
        replaceAll(changed)
    }

    func setFolder(_ folder: UUID?, of id: UUID) { setFolder(folder, of: [id]) }

    /// The suggestion put away: not asked again for this meeting.
    func dismissFolderSuggestion(for id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }), !record.folderAsked else { return }
        record.folderAsked = true
        save(record)
    }
}
