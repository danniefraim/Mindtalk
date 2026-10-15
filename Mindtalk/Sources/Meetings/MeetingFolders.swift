import Foundation

// MARK: - Folders
//
// A meeting can be in one folder ("Kund X", "Styrelsen") — or in none, and then it's
// only under "Alla". The folder is a field of the meeting (MeetingRecord.folder);
// the folders themselves, their names and order, are kept in Folders.json beside the
// meetings. Nothing moves on disk, so renaming a folder only changes its name, and
// taking a folder away never takes a meeting with it.

struct MeetingFolder: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
}

@MainActor
final class MeetingFolders: ObservableObject {
    static let shared = MeetingFolders()

    @Published private(set) var folders: [MeetingFolder] = []
    /// The folder the list shows — nil: "Alla". A meeting started meanwhile goes in it.
    /// (Not kept across launches: Mindtalk opens on all your meetings.)
    @Published var selected: UUID?

    private init() {
        folders = Self.read()
    }

    nonisolated private static var url: URL { MeetingStore.root.appendingPathComponent("Folders.json") }

    private static func read() -> [MeetingFolder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode([MeetingFolder].self, from: data) } catch {
            // Kept aside rather than overwritten: the meetings still say which folder
            // they're in, so a folder list put back brings them all back.
            NSLog("Mindtalk: could not read Folders.json: \(error.localizedDescription)")
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent("Folders-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return []
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: MeetingStore.root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(folders).write(to: Self.url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        } catch {
            NSLog("Mindtalk: could not save Folders.json: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Screenshots: folders in memory only — nothing written.
    func preview(_ names: [String]) { folders = names.map { MeetingFolder(name: $0) } }
    #endif

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

    @discardableResult
    func create(_ name: String) -> MeetingFolder? {
        let name = unique(name)
        guard !name.isEmpty else { return nil }
        let folder = MeetingFolder(name: name)
        folders.append(folder)
        write()
        return folder
    }

    func rename(_ id: UUID, to name: String) {
        let name = unique(name, except: id)
        guard !name.isEmpty, let i = folders.firstIndex(where: { $0.id == id }), folders[i].name != name else { return }
        folders[i].name = name
        write()
    }

    /// The folder goes; its meetings stay, under "Alla".
    func remove(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        folders.removeAll { $0.id == id }
        write()
        if selected == id { selected = nil }
        let store = MeetingStore.shared
        for record in store.meetings where record.folder == id { store.setFolder(nil, of: record.id) }
    }

    /// The folders in the order you see them, A to Ö.
    var sorted: [MeetingFolder] {
        folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Suggesting a folder

    /// The folder a finished meeting looks like it belongs in — or nil. Never put
    /// there by itself: the meeting page asks ("Lägga i Kund X?").
    ///   • the folder's name is in the meeting's title or summary ("Kund X – uppstart"), or
    ///   • the people named in it are the ones the folder's meetings have, two of
    ///     those meetings at least.
    /// Only one folder may fit; two equally good ones are no suggestion.
    func suggestion(for record: MeetingRecord, among meetings: [MeetingRecord]) -> MeetingFolder? {
        guard record.folder == nil, !record.folderAsked, record.finished, !folders.isEmpty else { return nil }
        var score: [UUID: Double] = [:]
        let text = ([record.title, record.summary?.title ?? "", record.summary?.overview ?? ""])
            .joined(separator: " ").lowercased()
        for folder in folders {
            let name = folder.name.lowercased()
            if name.count >= 3, Self.contains(text, word: name) { score[folder.id, default: 0] += 3 }
        }
        let people = Set(record.names.values.map { $0.lowercased() }.filter { !$0.isEmpty })
        if !people.isEmpty {
            var meetingsWith: [UUID: Int] = [:]
            for other in meetings where other.id != record.id {
                guard let folder = other.folder, self.folder(folder) != nil else { continue }
                let theirs = Set(other.names.values.map { $0.lowercased() })
                if !people.isDisjoint(with: theirs) { meetingsWith[folder, default: 0] += 1 }
            }
            for (folder, n) in meetingsWith where n >= 2 { score[folder, default: 0] += Double(min(n, 5)) / 2 + 1 }
        }
        let ranked = score.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 2 else { return nil }
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
}

extension MeetingStore {
    /// Into a folder, or out of it (nil). A meeting being recorded changes in the
    /// session, which saves it — not over it here.
    func setFolder(_ folder: UUID?, of id: UUID) {
        let session = MeetingSession.shared
        if session.record?.id == id {
            session.setFolder(folder)
            return
        }
        guard var record = meetings.first(where: { $0.id == id }), record.folder != folder else { return }
        record.folder = folder
        record.folderAsked = true
        save(record)
    }

    /// The suggestion put away: not asked again for this meeting.
    func dismissFolderSuggestion(for id: UUID) {
        guard var record = meetings.first(where: { $0.id == id }), !record.folderAsked else { return }
        record.folderAsked = true
        save(record)
    }
}
