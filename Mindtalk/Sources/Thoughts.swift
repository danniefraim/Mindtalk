import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tankar
//
// Something you think of in the middle of something else: hold the thought key and
// say it. It's written down by the same speech model as a dictation, but kept here,
// on its own page — never typed into the app you're in. Only the text is kept, on
// this Mac; the sound only until the text is there, so a thought is never lost to
// a failed transcription.
//
// The page (ThoughtsPage.swift): pinned on top, then one section per day, newest
// first. Within a day you set the order by dragging; a new thought lands on top.
// Done ones fold away at the bottom of their day. Removed ones wait thirty days in
// "Nyligen raderade". Every change can be undone, several steps back.

struct Thought: Codable, Identifiable, Equatable {
    /// Still being written down, or the writing failed (the sound is kept for "Försök igen").
    enum Writing: String, Codable { case writing, failed }

    var id = UUID()
    var text: String
    /// When you said it. Never changes — the day it belongs to.
    var date = Date()
    var done = false
    /// Its place within its day: higher is higher up. A new thought gets the time,
    /// so it lands on top; dragging puts it between its neighbours.
    var order: Double
    var pinned = false
    /// Its place among the pinned.
    var pinOrder: Double = 0
    /// In "Nyligen raderade" since then; gone for good thirty days later.
    var deleted: Date?
    var updated = Date()
    var writing: Writing?
    /// The language it was said in — for "Försök igen".
    var language: SpeechModel?

    init(text: String, date: Date = Date()) {
        self.text = text
        self.date = date
        order = date.timeIntervalSince1970
    }

    // Lenient, like the meetings: a thought missing a field still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        order = (try? c.decode(Double.self, forKey: .order)) ?? date.timeIntervalSince1970
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        pinOrder = (try? c.decode(Double.self, forKey: .pinOrder)) ?? 0
        deleted = try? c.decode(Date.self, forKey: .deleted)
        updated = (try? c.decode(Date.self, forKey: .updated)) ?? date
        writing = try? c.decode(Writing.self, forKey: .writing)
        language = try? c.decode(SpeechModel.self, forKey: .language)
    }

    var isLive: Bool { deleted == nil }
    /// Open: not done, not removed, written down.
    var isOpen: Bool { deleted == nil && !done && writing == nil }
}

extension UTType {
    static let mindtalkThought = UTType(exportedAs: "ai.mindact.mindtalk.thought")
}

/// One section of the page: the pinned, or a day.
enum ThoughtSection: Hashable {
    case pinned
    case day(Date)
}

@MainActor
final class Thoughts: ObservableObject {
    static let shared = Thoughts()

    /// Everything, removed ones too. The page reads the sections below.
    @Published private(set) var all: [Thought] = [] {
        didSet { reindex() }
    }
    /// Just saved — the page lights it up for a moment.
    @Published private(set) var fresh: UUID?
    /// The last change you can undo, said in a few words ("Tanken togs bort") —
    /// shown with "Ångra" for a few seconds.
    @Published private(set) var toast: String?

    // Kept from `all`, so the page and the tab bar don't sort on every redraw.
    private(set) var pinned: [Thought] = []
    /// Day (start of day) → its live, unpinned thoughts, top first.
    private(set) var days: [(day: Date, items: [Thought])] = []
    private(set) var removed: [Thought] = []
    private(set) var openCount = 0
    /// For Hem: open thoughts, pinned first, then newest.
    private(set) var forHome: [Thought] = []

    /// What everything was before a change, and when — a thought said after the
    /// step isn't part of it, so ⌘Z leaves it be.
    private struct Step { let label: String?; let before: [Thought]; let at: Date }
    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    /// How long removed thoughts wait in "Nyligen raderade".
    static let keepRemovedDays = 30

    nonisolated private static var url: URL {
        MeetingStore.root.deletingLastPathComponent().appendingPathComponent("Thoughts.json")
    }
    /// The sound of a thought being written down, until its text is there.
    nonisolated private static var pendingFolder: URL {
        MeetingStore.root.deletingLastPathComponent().appendingPathComponent("Thoughts-pending", isDirectory: true)
    }
    nonisolated private static func soundURL(_ id: UUID) -> URL { pendingFolder.appendingPathComponent(id.uuidString + ".f32") }

    private init() {
        if let data = try? Data(contentsOf: Self.url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let read = try? decoder.decode([Thought].self, from: data) {
                var kept = read
                // Thirty days in "Nyligen raderade", then gone.
                let limit = Self.removedLimit
                for t in kept where (t.deleted ?? .distantFuture) < limit { try? FileManager.default.removeItem(at: Self.soundURL(t.id)) }
                kept.removeAll { ($0.deleted ?? .distantFuture) < limit }
                // Being written when Mindtalk quit: "Försök igen" if the sound is there.
                for i in kept.indices where kept[i].writing == .writing {
                    kept[i].writing = FileManager.default.fileExists(atPath: Self.soundURL(kept[i].id).path) ? .failed : nil
                }
                kept.removeAll { $0.writing == nil && $0.text.isEmpty }
                all = kept
            } else {
                // Kept aside, never written over.
                try? FileManager.default.moveItem(at: Self.url, to: Self.url.deletingLastPathComponent()
                    .appendingPathComponent("Thoughts-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            }
        }
        reindex()
        sweepSounds()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Thoughts.shared.saveNow()
                Thoughts.writer.sync {}          // written before the app is gone
            }
        }
        // Midnight: "I dag" becomes "I går", and a removed thought's thirty days may be up.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Thoughts.shared.dayChanged() }
        }
    }

    private static var removedLimit: Date { Date().addingTimeInterval(-Double(keepRemovedDays) * 86_400) }

    /// A sound with no thought still being written (a crash between the two, a
    /// thought gone for good): removed, so the folder never grows.
    private func sweepSounds() {
        #if DEBUG
        if previewing { return }
        #endif
        let kept = Set(all.filter { $0.writing != nil }.map(\.id))
        Self.writer.async { Self.sweepSounds(in: Self.pendingFolder, keeping: kept) }
    }

    /// Every sound in the folder that isn't one of `kept`: removed.
    nonisolated static func sweepSounds(in folder: URL, keeping kept: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "f32" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), kept.contains(id) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removed thoughts whose thirty days are up: gone — not an undo step, it's
    /// time passing, not you.
    private func sweepRemoved() {
        let limit = Self.removedLimit
        let gone = all.filter { ($0.deleted ?? .distantFuture) < limit }.map(\.id)
        guard !gone.isEmpty else { return }
        for id in gone { dropSound(id) }
        all.removeAll { gone.contains($0.id) }
        save()
    }

    private func dayChanged() {
        sweepRemoved()
        objectWillChange.send()
        reindex()
    }

    private func reindex() {
        let calendar = Calendar.current
        let live = all.filter(\.isLive)
        pinned = live.filter(\.pinned).sorted { $0.pinOrder > $1.pinOrder }
        var byDay: [Date: [Thought]] = [:]
        for t in live where !t.pinned { byDay[calendar.startOfDay(for: t.date), default: []].append(t) }
        days = byDay.keys.sorted(by: >).map { day in (day, byDay[day]!.sorted { $0.order > $1.order }) }
        removed = all.filter { !$0.isLive }.sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }
        openCount = live.filter(\.isOpen).count
        forHome = pinned.filter(\.isOpen) + live.filter { $0.isOpen && !$0.pinned }.sorted { $0.date > $1.date }
    }

    // MARK: Saving — a moment after the last change, and on quit

    private func save() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        #if DEBUG
        if previewing { return }
        #endif
        let snapshot = all
        Self.writer.async {
            do {
                let dir = Self.url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: Self.url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
            } catch {
                NSLog("Mindtalk: could not save thoughts: \(error.localizedDescription)")
            }
        }
    }
    nonisolated private static let writer = DispatchQueue(label: "ai.mindact.mindtalk.thoughts", qos: .utility)

    // MARK: Undo, several steps back

    /// Every change goes through here: what it was before, so ⌘Z brings it back.
    private func change(_ label: String? = nil, _ body: (inout [Thought]) -> Void) {
        var next = all
        body(&next)
        guard next != all else { return }
        undoSteps.append(Step(label: label, before: all, at: Date()))
        if undoSteps.count > 30 { undoSteps.removeFirst() }
        redoSteps.removeAll()
        all = next
        save()
        if let label { say(label) }
    }

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        redoSteps.append(Step(label: step.label, before: all, at: Date()))
        all = restored(step)
        toast = nil
        save()
    }

    func redo() {
        guard let step = redoSteps.popLast() else { return }
        undoSteps.append(Step(label: step.label, before: all, at: Date()))
        all = restored(step)
        save()
    }

    /// The step's snapshot, with what the app did on its own since left as it is:
    /// a thought being written down then has the text it got (or is gone, if not
    /// a word was heard), and one said after the step is still there.
    private func restored(_ step: Step) -> [Thought] {
        var next = step.before
        for i in next.indices.reversed() where next[i].writing != nil {
            if let now = all.first(where: { $0.id == next[i].id }) {
                next[i].text = now.text
                next[i].writing = now.writing
                next[i].language = now.language
                next[i].updated = now.updated
            } else {
                next.remove(at: i)
            }
        }
        let known = Set(next.map(\.id))
        next += all.filter { $0.date > step.at && !known.contains($0.id) }
        return next
    }

    private func say(_ label: String) {
        toast = label
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Adding

    func add(_ text: String) {
        let text = Self.tidy(text)
        guard !text.isEmpty else { return }
        let thought = Thought(text: text)
        change { $0.append(thought) }
        light(thought.id)
    }

    /// A thought just said: on the page at once ("Skriver ned…"), its sound kept
    /// until the text is there.
    func hold(_ samples: [Float], language: SpeechModel) -> UUID {
        var thought = Thought(text: "")
        thought.writing = .writing
        thought.language = language
        all.append(thought)          // not an undo step: it's the app writing, not you
        let id = thought.id
        #if DEBUG
        if previewing { return id }
        #endif
        Self.writer.async {
            let url = Self.soundURL(id)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        save()
        return id
    }

    /// Written down: the text in, the sound gone.
    func fill(_ id: UUID, text: String) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { dropSound(id); return add(text) }
        let text = Self.tidy(text)
        if text.isEmpty { return discard(id) }
        all[i].text = text
        all[i].writing = nil
        all[i].updated = Date()
        dropSound(id)
        save()
        light(id)
    }

    /// The writing failed: kept, with its sound, for "Försök igen".
    func failWriting(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].writing = .failed
        save()
    }

    /// Nothing to keep (not a word heard): as if it was never said.
    func discard(_ id: UUID) {
        all.removeAll { $0.id == id }
        dropSound(id)
        save()
    }

    /// "Försök igen": the kept sound, written down once more.
    func retry(_ id: UUID) async {
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].writing == .failed else { return }
        let language = all[i].language ?? Dictation.shared.engine
        all[i].writing = .writing
        let url = Self.soundURL(id)
        let samples: [Float]? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }.value
        guard let samples, !samples.isEmpty else { return failWriting(id) }
        do {
            let terms = VocabularyBoost.terms(from: Vocabulary.shared.entries.map(\.word))
            let (raw, heard) = try await SpeechEngine.shared.transcribe(samples: samples, with: language, listeningFor: terms)
            Vocabulary.shared.noteHeard(heard)
            var text = Vocabulary.shared.apply(TextCleanup.apply(raw, fillers: Settings.removeFillers, commands: Settings.voiceCommands))
            // As when said: polished if that's on, unless the polish split a listed word.
            if Settings.aiPolish, let polished = await Polisher.shared.polish(text) {
                let fixed = Vocabulary.shared.reapply(polished)
                if Vocabulary.shared.keepsWords(of: text, in: fixed) { text = fixed }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failWriting(id) }
            Stats.shared.record(text: text, seconds: Double(samples.count) / 16_000)
            fill(id, text: text)
        } catch {
            failWriting(id)
        }
    }

    private func dropSound(_ id: UUID) {
        #if DEBUG
        if previewing { return }
        #endif
        let url = Self.soundURL(id)
        Self.writer.async { try? FileManager.default.removeItem(at: url) }
    }

    private func light(_ id: UUID) {
        fresh = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.fresh == id { self?.fresh = nil }
        }
    }

    /// Trimmed, with a capital first letter.
    private static func tidy(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: Changing

    func setDone(_ ids: [UUID], _ done: Bool) {
        change(ids.count > 1 ? (done ? String(localized: "\(ids.count) tankar är klara") : nil) : nil) { all in
            for i in all.indices where ids.contains(all[i].id) { all[i].done = done; all[i].updated = Date() }
        }
    }

    func edit(_ id: UUID, text: String) {
        let text = Self.tidy(text)
        if text.isEmpty { return remove([id]) }
        change { all in
            guard let i = all.firstIndex(where: { $0.id == id }), all[i].text != text else { return }
            all[i].text = text
            all[i].updated = Date()
        }
    }

    func setPinned(_ ids: [UUID], _ pinned: Bool) {
        let top = (self.pinned.first?.pinOrder ?? 0) + 1
        change { all in
            var n = 0.0
            for i in all.indices where ids.contains(all[i].id) && all[i].pinned != pinned {
                all[i].pinned = pinned
                all[i].pinOrder = pinned ? top + Double(ids.count) - n : 0
                n += 1
            }
        }
    }

    /// To "Nyligen raderade".
    func remove(_ ids: [UUID]) {
        let label = ids.count == 1 ? String(localized: "Tanken togs bort") : String(localized: "\(ids.count) tankar togs bort")
        change(label) { all in
            for i in all.indices where ids.contains(all[i].id) { all[i].deleted = Date() }
        }
        sweepRemoved()
    }

    /// Back from "Nyligen raderade", where it was.
    func restore(_ ids: [UUID]) {
        change { all in
            for i in all.indices where ids.contains(all[i].id) { all[i].deleted = nil }
        }
    }

    /// Gone for good — only from "Nyligen raderade", after you said yes.
    func purge(_ ids: [UUID]) {
        for id in ids { dropSound(id) }
        change { $0.removeAll { ids.contains($0.id) && $0.deleted != nil } }
        // Not undoable once it's gone for good.
        undoSteps.removeAll()
        redoSteps.removeAll()
    }

    /// Into one: the first keeps its place and time, the others' words follow it,
    /// a line each.
    func merge(_ ids: [UUID], into target: UUID) {
        let others = ids.filter { $0 != target }
        guard !others.isEmpty else { return }
        change(String(localized: "Tankarna slogs ihop")) { all in
            guard let t = all.firstIndex(where: { $0.id == target }) else { return }
            let texts = all.filter { others.contains($0.id) && $0.writing == nil }.sorted { $0.order > $1.order }.map(\.text)
            guard !texts.isEmpty else { return }
            all[t].text = ([all[t].text] + texts).joined(separator: "\n")
            all[t].updated = Date()
            all.removeAll { others.contains($0.id) && $0.writing == nil }
        }
    }

    /// Dragged to a place in a section — only thoughts already in it move (a thought
    /// stays on the day you said it); a pinned one dragged to a day is unpinned there.
    func move(_ ids: [UUID], to index: Int, in section: ThoughtSection) {
        let calendar = Calendar.current
        let list: [Thought]
        switch section {
        case .pinned: list = pinned
        case .day(let day): list = days.first { $0.day == day }?.items ?? []
        }
        let moving: [UUID] = {
            switch section {
            case .pinned: return ids.filter { id in all.contains { $0.id == id && $0.pinned } }
            case .day(let day): return ids.filter { id in all.contains { $0.id == id && calendar.isDate($0.date, inSameDayAs: day) } }
            }
        }()
        guard !moving.isEmpty else { return }
        let rest = list.filter { !moving.contains($0.id) }
        let before = list.prefix(min(index, list.count)).filter { !moving.contains($0.id) }.count
        let value: (Thought) -> Double = { section == .pinned ? $0.pinOrder : $0.order }
        // Between the neighbours: above has the higher number.
        let above = before > 0 ? value(rest[before - 1]) : nil
        let below = before < rest.count ? value(rest[before]) : nil
        let hi = above ?? ((below ?? Date().timeIntervalSince1970) + Double(moving.count + 1))
        let lo = below ?? (hi - Double(moving.count + 1))
        let step = (hi - lo) / Double(moving.count + 1)
        let ordered = list.filter { moving.contains($0.id) }.map(\.id)
        change { all in
            for (n, id) in ordered.enumerated() {
                guard let i = all.firstIndex(where: { $0.id == id }) else { continue }
                let v = hi - step * Double(n + 1)
                if section == .pinned { all[i].pinOrder = v } else { all[i].order = v }
            }
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓: one place up or down in its section.
    func nudge(_ id: UUID, by delta: Int) {
        guard let t = all.first(where: { $0.id == id }) else { return }
        let section: ThoughtSection = t.pinned ? .pinned : .day(Calendar.current.startOfDay(for: t.date))
        let list: [Thought] = t.pinned ? pinned : (days.first { $0.day == Calendar.current.startOfDay(for: t.date) }?.items ?? [])
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let target = i + delta
        guard target >= 0, target < list.count else { return }
        move([id], to: delta > 0 ? target + 1 : target, in: section)
    }

    // MARK: Out

    /// All of them, by day, as Markdown — for "Exportera…".
    func markdown() -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale)
        var lines = ["# " + String(localized: "Tankar"), ""]
        func line(_ t: Thought) -> String {
            "- " + t.date.formatted(time) + ": " + t.text.replacingOccurrences(of: "\n", with: "\n  ")
                + (t.done ? " " + String(localized: "(klar)") : "")
        }
        if !pinned.isEmpty {
            lines += ["## " + String(localized: "Fäst"), ""]
            lines += pinned.filter { $0.writing == nil }.map(line)
            lines.append("")
        }
        for day in days {
            let title = day.day.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).year().locale(AppLanguage.locale))
            lines += ["## " + title.prefix(1).uppercased() + title.dropFirst(), ""]
            lines += day.items.filter { $0.writing == nil }.map(line)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    #if DEBUG
    private var previewing = false
    /// Screenshots: thoughts in memory only — nothing written.
    func preview(_ items: [Thought]) { previewing = true; all = items }
    #endif
}

/// A thought dragged: its id for drops in Tankar (and Hem), its words for other apps.
enum ThoughtDragging {
    /// The thoughts being dragged right now — set as a drag starts in Tankar.
    @MainActor static var ids: [UUID] = []

    @MainActor static func provider(ids: [UUID], text: String) -> NSItemProvider {
        Self.ids = ids
        let provider = NSItemProvider(object: text as NSString)
        let data = ids.map(\.uuidString).joined(separator: "\n").data(using: .utf8) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.mindtalkThought.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }
}
