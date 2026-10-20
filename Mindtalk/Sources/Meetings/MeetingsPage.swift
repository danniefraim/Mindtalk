import AppKit
import SwiftUI

// MARK: - Möten
//
// The page: start a meeting, and the meetings you've had. A meeting opens in the
// same place — live while it's recorded, then as it was saved.
//
// It follows the rest of the app: serif titles on paper, ink for what you do. The
// text reads as a document: each speaker a thin line in their own quiet colour,
// their name above in it. While recording, one dark island at the bottom holds the
// time, your note, the marks and stop — dark like the dictation indicator.

struct MeetingsPage: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    /// The meeting you were reading, kept while you visit other pages.
    @State private var open: UUID? = MeetingsPage.lastOpen
    static var lastOpen: UUID?
    /// Opened from a search hit or an answer's source: the moment to show.
    static var focusAt: Double?
    /// "Nu spelar vi in": a second over the page as a meeting starts, then the room.
    @State private var startCue = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let record = session.record {
                    MeetingView(record: record, pending: session.pending, session: session, width: geo.size.width,
                                edit: .live(session))
                        .transition(.opacity)
                        .overlay { if startCue { StartCue().transition(.opacity) } }
                } else if let id = open, let record = store.meetings.first(where: { $0.id == id }) {
                    MeetingView(record: record, pending: [], session: nil, width: geo.size.width,
                                edit: .saved(store, id),
                                back: { withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = nil } })
                        .id(id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                } else {
                    MeetingList(session: session, store: store, voices: voices, dictation: dictation) { id, at in
                        MeetingsPage.focusAt = at
                        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = id }
                    }
                    .transition(.opacity)
                }
            }
        }
        .folderNaming()
        // Sound or video dropped anywhere here: transcribed, as a meeting — the list
        // shows it coming (from a meeting's page, back to the list; during a meeting,
        // the cards float at the top).
        .importDrop()
        .onReceive(NotificationCenter.default.publisher(for: .importAdded)) { _ in
            if session.record == nil { withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = nil } }
        }
        .overlay(alignment: .topTrailing) {
            if session.record != nil {
                ImportCards(compact: true) { _ in }
                    .frame(width: 380)
                    .padding(.top, 64)
                    .padding(.trailing, 24)
            }
        }
        // A meeting that just ended stays on screen, now as saved.
        .onChange(of: session.finished) { _, id in if let id { open = id } }
        // Started by hand: the start moment, clear to everyone in the room, then the
        // round or the text.
        .onChange(of: session.startMoment) { _, at in
            guard at != nil else { return }
            startCue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { startCue = false }
            }
        }
        // "Starta möte" from the menu bar or Hem: the start card, not a meeting you were reading.
        .onChange(of: session.armed) { _, armed in
            if armed, open != nil { withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = nil } }
        }
        .onAppear { if session.armed, open != nil { open = nil } }
        .onChange(of: open) { _, id in Self.lastOpen = id }
        // A mindtalk:// link while the page is already on screen: that meeting, at its second.
        .onReceive(NotificationCenter.default.publisher(for: .openMeeting)) { note in
            guard let id = note.object as? UUID, session.record == nil, open != id else { return }
            MeetingsPage.focusAt = note.userInfo?["at"] as? Double
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = id }
        }
        #if DEBUG
        .onAppear {   // screenshots: `--open-latest [--summarize]`
            guard CommandLine.arguments.contains("--open-latest"), let id = store.meetings.first?.id else { return }
            open = id
            if CommandLine.arguments.contains("--summarize") { MeetingNotes.shared.summarize(id) }
        }
        #endif
    }
}

/// Where edits to a meeting go: the session while recording, the store after.
enum MeetingEdits {
    case live(MeetingSession)
    case saved(MeetingStore, UUID)

    @MainActor func rename(_ title: String) {
        switch self {
        case .live(let s): s.rename(to: title)
        case .saved(let store, let id): store.rename(id, to: title)
        }
    }

    @MainActor func name(_ speaker: Int, _ name: String) {
        switch self {
        case .live(let s): s.name(speaker: speaker, as: name)
        case .saved(let store, let id): store.name(speaker: speaker, in: id, as: name)
        }
    }

    @MainActor func merge(_ speaker: Int, into other: Int) {
        switch self {
        case .live(let s): s.merge(speaker, into: other)
        case .saved(let store, let id): store.merge(speaker, into: other, in: id)
        }
    }

    @MainActor func move(_ range: Range<Int>, to speaker: Int) {
        switch self {
        case .live(let s): s.move(words: range, to: speaker)
        case .saved(let store, let id): store.move(words: range, to: speaker, in: id)
        }
    }

    @MainActor func notes(_ text: String) {
        switch self {
        case .live(let s): s.setNotes(text)
        case .saved(let store, let id): store.setNotes(text, in: id)
        }
    }

    @MainActor func removeMark(_ mark: UUID) {
        switch self {
        case .live(let s): s.removeMark(mark)
        case .saved(let store, let id): store.removeMark(mark, in: id)
        }
    }
}

// MARK: - The list

private struct MeetingList: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    @ObservedObject private var notes = MeetingNotes.shared
    @ObservedObject private var library = MeetingLibrary.shared
    @ObservedObject private var folders = MeetingFolders.shared
    @ObservedObject private var archiveOpen = ArchiveOpen.shared
    let open: (UUID, Double?) -> Void
    @State private var confirmDelete: MeetingRecord?
    @State private var query = ""
    /// Meetings ⌘- or ⇧-clicked: dragged and moved together.
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    /// What the search found — a moment after you stop typing.
    @State private var matches: [MeetingMatch] = []

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canAsk: Bool { MeetingNotes.isAvailable && shown.contains { !$0.words.isEmpty } }

    /// Every count the folder chips show, as one key.
    private var folderCounts: String {
        var counts: [String: Int] = [:]
        for m in store.meetings where m.id != session.record?.id { counts[m.folder?.uuidString ?? "", default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    var body: some View {
        let sections = ArchiveSection.sections(shown.filter { $0.id != session.record?.id })
        // Lazy, so the search field and the folders can stay pinned at the top as the
        // list scrolls — a meeting far down can still be dragged onto a folder.
        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
            PageHeader(title: "Möten",
                       eyebrow: store.meetings.isEmpty ? nil
                           : store.meetings.count == 1 ? String(localized: "1 möte") : String(localized: "\(store.meetings.count) möten"),
                       subtitle: "Spela in ett möte i rummet, eller gör text av en inspelning du redan har. Du ser vem som sa vad och får en sammanfattning.")
                .staggered(0)
            SaveProblemLine()
            StartCard(session: session, voices: voices, dictation: dictation).staggered(1)
            ImportCards { id in open(id, nil) }
            if !searching {
                // In a folder: its week, summed up from its meetings.
                WeekRecap(meetings: shown.filter { $0.id != session.record?.id }, all: store.meetings,
                          folder: folders.folder(folders.selected)?.name)
                    .staggered(2)
            }
            if store.meetings.isEmpty {
                EmptyArchive().staggered(2)
            } else {
                Section {
                    LibraryAnswers(library: library, open: open)
                    if searching {
                        SearchResults(matches: matches, query: query, folder: folders.folder(folders.selected)?.name,
                                      showAll: { withAnimation(.snappy) { folders.selected = nil } }, open: open)
                    } else if sections.isEmpty, let folder = folders.folder(folders.selected) {
                        emptyFolder(folder)
                    } else {
                        let order = visibleOrder(sections)
                        ForEach(Array(sections.enumerated()), id: \.element.id) { n, section in
                            archive(section, order: order)
                                .staggered(2 + min(n, 3))
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            LibrarySearchField(query: $query, folder: folders.folder(folders.selected)?.name)
                                .frame(width: showsFolders ? 260 : nil)
                                .frame(maxWidth: showsFolders ? nil : .infinity)
                            if showsFolders {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    FolderBar(folders: folders, store: store, live: session.record?.id, oneRow: true)
                                        .padding(.vertical, 2)
                                        // The pinned row kept an old count after a delete until the
                                        // page was opened again: drawn anew whenever a count changes.
                                        .id(folderCounts)
                                }
                            }
                        }
                        if !selection.isEmpty { selectionBar }
                        if let problem = folders.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12)).foregroundStyle(DS.Colors.warning)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Pinned, it covers the list scrolling under it — to the window's edges.
                    .background(DS.Colors.paper.padding(.horizontal, -DS.Layout.pageHorizontal))
                    .staggered(2)
                }
            }
        }
        .padding(.bottom, canAsk ? 90 : 0)
        .task(id: query + "\(store.meetings.count) \(shown.count)" + (folders.selected?.uuidString ?? "")) {
            guard searching else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            matches = MeetingSearch.find(query, in: shown.filter { $0.id != session.record?.id })
        }
        #if DEBUG
        .onAppear {   // screenshots: `--search-query "ord"`, `--ask-query "fråga"`
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--search-query"), i + 1 < args.count { query = args[i + 1] }
            if let i = args.firstIndex(of: "--ask-query"), i + 1 < args.count { library.ask(args[i + 1]) }
        }
        #endif
        .pageLayout()
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                MoveToast()
                if canAsk { LibraryAskBar(library: library) }
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: folders.lastMove)
        }
        .onChange(of: folders.selected) { _, _ in selection = [] }
        .onChange(of: store.meetings.count) { _, _ in selection = selection.filter { id in store.meetings.contains { $0.id == id } } }
        .animation(.snappy, value: selection)
        .animation(.easeOut(duration: 0.2), value: searching)
        .animation(.spring(duration: 0.35, bounce: 0.12), value: folders.selected)
        .confirmationDialog("Ta bort mötet?", isPresented: Binding(get: { confirmDelete != nil },
                                                                   set: { if !$0 { confirmDelete = nil } })) {
            Button("meeting|Ta bort", role: .destructive) {
                if let id = confirmDelete?.id { withAnimation(.snappy) { store.delete(id) } }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Inspelningen, texten, dina anteckningar och sammanfattningen flyttas till papperskorgen.")
        }
    }

    /// One meeting in the list: click opens it; ⌘-click adds it to a selection, ⇧-click
    /// a run of them — to drag, or move with "Flytta till", together.
    private func row(_ record: MeetingRecord, order: [UUID], compact: Bool = false, timeOnly: Bool = false) -> some View {
        let ids = selection.contains(record.id) ? Array(selection) : [record.id]
        return MeetingRow(record: record, writing: notes.writing.contains(record.id),
                          folder: folders.selected == nil ? folders.folder(of: record)?.name : nil,
                          selected: selection.contains(record.id), compact: compact, timeOnly: timeOnly) {
            let keys = NSEvent.modifierFlags
            if keys.contains(.command) {
                if selection.contains(record.id) { selection.remove(record.id) } else { selection.insert(record.id) }
                anchor = record.id
            } else if keys.contains(.shift) {
                if let from = anchor.flatMap({ order.firstIndex(of: $0) }), let to = order.firstIndex(of: record.id) {
                    selection.formUnion(order[min(from, to)...max(from, to)])
                } else {
                    selection.insert(record.id)
                    anchor = record.id
                }
            } else {
                selection = []
                open(record.id, nil)
            }
        }
        // Dragged onto a folder in the row above: into it (with the others selected).
        .meetingDrag(record, selection: selection)
        .meetingMoveActions(ids)
        .contextMenu {
            if ids.count == 1 { Button("Öppna") { open(record.id, nil) } }
            MoveToFolderMenu(ids: ids, current: ids.count == 1 ? record.folder : nil,
                             title: ids.count == 1 ? "Flytta till" : "Flytta \(ids.count) möten till")
            if ids.count == 1 {
                Divider()
                Button("Ta bort…", role: .destructive) { confirmDelete = record }
            }
        }
    }

    /// A group of the list: the recent ones as cards of full rows; an older month or
    /// year as a line that opens — its meetings then a line each.
    @ViewBuilder private func archive(_ section: ArchiveSection, order: [UUID]) -> some View {
        switch section.kind {
        case .recent:
            // The day in small capitals, close above its meetings.
            VStack(alignment: .leading, spacing: 8) {
                CapsLabel(section.title).padding(.top, 6)
                rows(section.meetings, order: order, compact: false, timeOnly: section.day)
            }
        case .month:
            VStack(alignment: .leading, spacing: 4) {
                let open = archiveOpen.isOpen(section)
                ArchiveHeader(section: section, open: open, people: open ? [] : section.people(among: store.meetings)) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) { archiveOpen.toggle(section) }
                }
                if open { rows(section.meetings, order: order, compact: section.openByDefault == false) }
            }
        case .year:
            VStack(alignment: .leading, spacing: 4) {
                let open = archiveOpen.isOpen(section)
                ArchiveHeader(section: section, open: open, people: open ? [] : section.people(among: store.meetings)) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) { archiveOpen.toggle(section) }
                }
                if open {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(section.months) { month in
                            let monthOpen = archiveOpen.isOpen(month)
                            ArchiveHeader(section: month, open: monthOpen,
                                          people: monthOpen ? [] : month.people(among: store.meetings), nested: true) {
                                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { archiveOpen.toggle(month) }
                            }
                            if monthOpen { rows(month.meetings, order: order, compact: true) }
                        }
                    }
                    .padding(.leading, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func rows(_ meetings: [MeetingRecord], order: [UUID], compact: Bool, timeOnly: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(meetings.enumerated()), id: \.element.id) { i, record in
                if i > 0 { CardDivider() }
                row(record, order: order, compact: compact, timeOnly: timeOnly)
            }
        }
        .padding(4)
        .card()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The meetings in the order they're on screen — for ⇧-click to select a run.
    private func visibleOrder(_ sections: [ArchiveSection]) -> [UUID] {
        sections.flatMap { section -> [UUID] in
            switch section.kind {
            case .recent: return section.meetings.map(\.id)
            case .month: return archiveOpen.isOpen(section) ? section.meetings.map(\.id) : []
            case .year:
                guard archiveOpen.isOpen(section) else { return [] }
                return section.months.flatMap { archiveOpen.isOpen($0) ? $0.meetings.map(\.id) : [] }
            }
        }
    }

    /// Meetings selected: how many, where to, and done.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(selection.count == 1 ? String(localized: "1 möte valt") : String(localized: "\(selection.count) möten valda"))
                .font(.system(size: 12.5, weight: .semibold))
            Menu {
                MoveToFolderItems(ids: Array(selection))
            } label: {
                Label("Flytta till", systemImage: "folder")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.soft)
            .fixedSize()
            Spacer()
            Button("Avmarkera") { withAnimation(.snappy) { selection = [] } }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.muted)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .card()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// A folder with nothing in it yet: how meetings get there.
    private func emptyFolder(_ folder: MeetingFolder) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 26, weight: .light)).foregroundStyle(DS.Colors.faint)
            Text("Inga möten i \(folder.name) än").font(.system(size: 14, weight: .semibold))
            Text("Dra ett möte till mappen här ovanför, eller högerklicka på ett möte och välj Flytta till. Möten du startar här hamnar också i mappen.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Visa alla möten") { withAnimation(.snappy) { folders.selected = nil } }
                .buttonStyle(.soft)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .transition(.opacity)
    }

    /// Folders once there's something to sort: a folder made, or six meetings. (Before
    /// that, "Ny mapp…" is in a meeting's "Flytta till".)
    private var showsFolders: Bool { !folders.folders.isEmpty || store.meetings.count >= 6 }

    /// The meetings of the folder chosen — all of them under "Alla".
    private var shown: [MeetingRecord] {
        guard let folder = folders.selected else { return store.meetings }
        return store.meetings.filter { $0.folder == folder }
    }

}

/// A meeting that couldn't be written (the disk full): said on the page until a save goes through.
private struct SaveProblemLine: View {
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        if let problem = store.saveProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

/// "Nu spelar vi in": the start moment, a second long, over the room as it comes in.
private struct StartCue: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Nu spelar vi in").font(.system(size: 44, weight: .regular, design: .serif))
            Text("Mötet har börjat.").font(.system(size: 16)).foregroundStyle(DS.Colors.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.paper)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// "Nytt möte": choose first, then one clear start. Nothing is recorded until a button
/// is pressed — or what's needed first, with the way to fix it.
struct StartCard: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    @ObservedObject private var folders = MeetingFolders.shared
    @ObservedObject private var importer = MeetingImport.shared
    @ObservedObject private var memory = VoiceMemory.shared
    /// Room for the two side by side.
    @State private var wide = true
    /// The card is in view: the sphere only turns while someone can see it.
    @State private var onScreen = true
    /// A start was just pressed: the sphere swells as the room takes over.
    @State private var starting = false
    /// The window can be seen (not hidden behind others or minimised): the sphere turns.
    @State private var windowVisible = true
    /// The way you started last time: filled white, and what Return does.
    @State private var remembered = MeetingSession.startMode
    /// Opened for this (the menu bar, the shortcut, Hem): the remembered button holds the keyboard.
    @FocusState private var focus: MeetingSession.StartMode?

    /// Drawn to an image (`--render-…`): no models are loaded for it.
    private static var rendering: Bool {
        #if DEBUG
        return MeetingSession.previewPreparing != nil
        #else
        return false
        #endif
    }

    /// Both doors open: the voices and the speech model are here.
    private var ready: Bool { voices.state == .ready && dictation.engine.isInstalled }

    var body: some View {
        Group {
            if ready {
                // One light tile, like Hem: the ways in with the sphere beside them,
                // and under a line, a recording you already have.
                tile
            } else {
                // Getting ready: one door — both ways need the same models.
                HStack(alignment: .center, spacing: 18) {
                    RecordGlyph()
                    VStack(alignment: .leading, spacing: 8) {
                        CapsLabel(String(localized: "Nytt möte"))
                        Text(LocalizedStringKey(detail))
                            .font(.system(size: 13.5))
                            .foregroundStyle(DS.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = session.lastError {
                            Text(error).font(.system(size: 12)).foregroundStyle(DS.Colors.warning)
                        }
                    }
                    Spacer(minLength: 16)
                    control
                }
                .padding(28)
                .tile()
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: importer.dropping)
        // Whether it's on screen: a file dragged over the page then lights this card's
        // zone, rather than covering the page.
        .onScrollVisibilityChange(threshold: 0.4) { visible in importer.zoneVisible = visible; onScreen = visible }
        .onDisappear { importer.zoneVisible = false; onScreen = false; putDown() }
        .onChange(of: session.phase) { _, now in if now == .idle { starting = false } }
        .onAppear {
            windowVisible = AppDelegate.mainWindowVisible
            if session.armed { takeKeyboard() }
            // The voices made ready now, if launch hasn't got to it yet: the round waits for them.
            if voices.state == .ready, !voices.isWarm, !Self.rendering { VoiceModels.warmUp() }
        }
        .onChange(of: session.armed) { _, armed in if armed { takeKeyboard() } }
        // Ready again after preparing: the keyboard back on the remembered button.
        .onChange(of: MeetingSession.preparing(remembered)) { _, now in if !now, session.armed { takeKeyboard() } }
        .background {
            // Esc while the card waits: nothing starts, nothing is recorded.
            if session.armed {
                Button("") { putDown(escaped: true) }.keyboardShortcut(.cancelAction)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window.contentViewController is NSHostingController<MainView> else { return }
            windowVisible = window.occlusionState.contains(.visible)
        }
    }

    /// The light tile: the words and the ways in on the left, the listening sphere in
    /// a column of its own on the right — the same one that falls into each voice's
    /// figure once the meeting is going — and under a line, the drop zone as one row.
    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 28) {
                room.frame(maxWidth: .infinity, alignment: .topLeading)
                // (The cloud is about two thirds of its frame: the rest is let go.)
                InkSphere(meter: dictation.meter, listening: false, paused: !onScreen || importer.dropping)
                    .frame(width: DS.Layout.sphere, height: DS.Layout.sphere)
                    .scaleEffect(starting ? 1.8 : 1)
                    .padding(.vertical, -34).padding(.trailing, -14)
                    .animation(.easeIn(duration: 0.7), value: starting)
                    .allowsHitTesting(false)
            }
            Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.top, 22).padding(.bottom, 16)
            ImportZone(folder: folders.selected, compact: true)
            // A file just done: where it went, for a moment.
            ImportDoneLine()
        }
        .padding(28)
        .tile()
        .animation(.easeOut(duration: 0.25), value: importer.lastDone)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 600 } action: { wide = $0 }
    }

    /// A new meeting: the choice, the two ways in, the voices, and what it runs on.
    private var room: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsLabel(String(localized: "Nytt möte"))
            Text("Är ni flera? Ta en namnrunda, så står rätt namn i texten.")
                .font(.system(size: 15)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .frame(maxWidth: 440, alignment: .leading)
            if let error = session.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            roomControl.padding(.top, 20)
            if dictation.micGranted {
                // On from the start; switched off here or in Settings. The voices are other people's, so the line asks you to tell them.
                Toggle(isOn: $memory.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kom ihåg rösterna till nästa möte").font(.system(size: 13, weight: .medium))
                        Text("Mindtalk känner igen rösten utan att spara den som ljud. Fråga de andra i rummet först.")
                            .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(InkCheckboxStyle())
                .padding(.top, 20)
            }
            // The shortcut, what it runs on, and where a new one goes — quietly, at the foot.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if dictation.micGranted {
                    KeyChip(text: StatusPanelView.meetingKeys, small: true)
                        .help("Starta möte (\(StatusPanelView.meetingKeys)). Du väljer om ni tar en namnrunda eller startar direkt.")
                }
                if let caption {
                    Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(DS.Colors.faint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 16)
        }
        .opacity(starting ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: starting)
        .opacity(importer.dropping ? 0.4 : 1)
    }

    private var caption: String? {
        var parts: [String] = []
        if let note { parts.append(note) }
        if let folder = folders.folder(folders.selected) { parts.append(String(localized: "Sparas i \(folder.name)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The ways in: the round of names, or straight into the meeting.
    @ViewBuilder private var roomControl: some View {
        if !dictation.micGranted {
            VStack(alignment: .leading, spacing: 10) {
                roomButton("Tillåt mikrofonen", filled: true, dot: false, help: "Mindtalk behöver få använda mikrofonen") {
                    dictation.fix(.microphone)
                }
                Text("Mindtalk behöver mikrofonen för att spela in. Slå på den i Systeminställningar under Integritet och säkerhet.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    choice(.round, "Starta med namnrunda", caption: "Alla säger hej och sitt namn. En halv minut.")
                    choice(.direct, "Starta direkt", caption: "Namnge talarna under mötet om du vill.")
                }
                .disabled(dictation.phase != .idle || starting)
                if let line = waitingLine {
                    Text(verbatim: line)
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if case .failed = dictation.model {
                    // Never stuck waiting: a model that failed to start can be tried again.
                    HStack(spacing: 10) {
                        Text("Talmodellen kunde inte startas.")
                            .font(.system(size: 12)).foregroundStyle(DS.Colors.warning)
                        Button("Försök igen") { dictation.retryModel() }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                } else if session.armed {
                    Text(verbatim: remembered == .round
                         ? String(localized: "Tryck ↩ för att starta med namnrunda. Esc avbryter.")
                         : String(localized: "Tryck ↩ för att starta direkt. Esc avbryter."))
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: waitingLine)
        }
    }

    /// What a start still waits for, in a line under the buttons (nil: nothing).
    private var waitingLine: String? {
        if MeetingSession.preparing(.direct) {
            return String(localized: "Talmodellen förbereds. Det tar någon minut första gången.")
        }
        if MeetingSession.preparing(.round) {
            return String(localized: "Röstmodellen förbereds. Det tar någon minut första gången.")
        }
        return nil
    }

    /// One way in, with a line under it. The one you took last time is ink and on
    /// Return while the card waits for you; the other is soft. While what it needs is
    /// being prepared, it waits: "Förbereder…", and Return does nothing.
    private func choice(_ mode: MeetingSession.StartMode, _ title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        let filled = remembered == mode
        let waiting = MeetingSession.preparing(mode)
        return VStack(alignment: .leading, spacing: 8) {
            roomButton(waiting ? "Förbereder…" : title, filled: filled, dot: !waiting, ring: filled && session.armed && !waiting,
                       help: caption) { begin(introducing: mode == .round) }
                .disabled(waiting)
                .focused($focus, equals: mode)
                .keyboardShortcut(filled && session.armed && !waiting ? .defaultAction : nil)
                .accessibilityHint(caption)
            Text(caption).font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 176, alignment: .leading)
        }
    }

    /// A button on the tile, as on Hem: ink with paper text, or soft grey.
    private func roomButton(_ title: LocalizedStringKey, filled: Bool, dot: Bool = true, ring: Bool = false,
                            help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 7) {
                if dot { Circle().fill(DS.Colors.recording).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(shape.fill(filled ? DS.Colors.ink : DS.Colors.chip))
            .foregroundStyle(filled ? DS.Colors.onInk : .primary)
            .contentShape(shape)
        }
        .buttonStyle(RoomPressStyle())
        // Opened for this: the button that Return presses, ringed.
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control + 3, style: .continuous)
            .strokeBorder(DS.Colors.ink.opacity(ring ? 0.55 : 0), lineWidth: 1.5).padding(-4))
        .animation(.easeOut(duration: 0.25), value: ring)
        .help(help)
    }

    /// Disabled (preparing): a quieter button, clearly not ready.
    private struct RoomPressStyle: ButtonStyle {
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
        }
    }

    /// A press: the way is remembered, the sphere swells, and the meeting starts this moment.
    private func begin(introducing: Bool) {
        guard !MeetingSession.preparing(introducing ? .round : .direct) else { return }
        MeetingSession.startMode = introducing ? .round : .direct
        remembered = MeetingSession.startMode
        starting = true
        session.start(introducing: introducing, folder: MeetingFolders.shared.selected)
        if session.phase == .idle { starting = false }     // it couldn't: the card says why
    }

    /// Opened for a meeting: the remembered button holds the keyboard, so Return starts.
    private func takeKeyboard() {
        DispatchQueue.main.async { focus = remembered }
    }

    /// Esc, or away from the page, while the card waits: nothing starts, nothing is
    /// recorded. Esc on a card opened from elsewhere (the menu bar, the shortcut, Hem):
    /// back to where you were, the window out of the way.
    private func putDown(escaped: Bool = false) {
        guard session.phase == .idle, session.armed else { return }
        let elsewhere = MeetingPanel.shared.startedElsewhere
        session.armed = false
        MeetingPanel.shared.startedElsewhere = false
        if escaped, elsewhere {
            AppDelegate.hideMainWindow()
            NSApp.deactivate()
        }
    }

    private var detail: String {
        let speech: String? = {
            guard !dictation.engine.isInstalled else { return nil }
            if case .downloading = dictation.model {
                return String(localized: "Talmodellen laddas ned, så att Mindtalk kan skriva ned det som sägs.")
            }
            return voices.state == .ready
                ? String(localized: "Mindtalk behöver talmodellen för att skriva ned det som sägs.")
                : String(localized: "Mindtalk behöver också talmodellen för att skriva ned det som sägs.")
        }()
        let voicesLine: String?
        switch voices.state {
        case .ready:
            voicesLine = speech == nil ? String(localized: "Mindtalk hör vem som säger vad och skriver ned det medan ni pratar.") : nil
        case .downloading:
            voicesLine = String(localized: "Laddar ned Nemotron 3 från NVIDIA, så att Mindtalk hör vem som pratar.")
        case .missing, .failed:
            voicesLine = String(localized: "För att hålla isär vem som pratar behövs Nemotron 3 från NVIDIA (\(VoiceModels.sizeText)). Den laddas ned en gång och fungerar sedan utan internet.")
        }
        return [voicesLine, speech].compactMap { $0 }.joined(separator: " ")
    }

    private var note: String? {
        guard voices.state == .ready else { return nil }
        if !MeetingNotes.isAvailable {
            return String(localized: "Utan Apple Intelligence eller Gemma 4 blir det text men ingen sammanfattning.")
        }
        if BetterNotes.shared.isActive {
            return String(localized: "\(dictation.engine.modelName) och \(BetterNotes.shared.writerSentenceName)")
        }
        return String(localized: "\(dictation.engine.modelName) och Apple Intelligence")
    }

    @ViewBuilder private var control: some View {
        switch voices.state {
        case .ready:
            // (Ready and the speech model here is the tile above: here it's missing.)
            if !dictation.micGranted {
                Button("Tillåt mikrofonen") { dictation.fix(.microphone) }.buttonStyle(.ink)
            } else if case .downloading(let p) = dictation.model {
                VStack(alignment: .trailing, spacing: 6) {
                    ProgressView(value: p).tint(DS.Colors.ink).frame(width: 140)
                        .accessibilityLabel("Laddar ned talmodellen")
                    Text(p, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                }
            } else if dictation.model == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Förbereder talmodellen").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                }
            } else {
                Button("Ladda ned \(dictation.engine.title)") {
                    SettingsPage.open(.language)     // the language rows, each with its Ladda ned
                }
                .buttonStyle(.soft)
            }
        case .downloading(let p):
            VStack(alignment: .trailing, spacing: 6) {
                ProgressView(value: p).tint(DS.Colors.ink).frame(width: 140)
                    .accessibilityLabel("Laddar ned Nemotron 3")
                Text(p, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            }
        case .missing:
            Button("Ladda ned \(VoiceModels.sizeText)") { voices.download() }.buttonStyle(.ink)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Button("Försök igen") { voices.download() }.buttonStyle(.soft)
                Text(message).font(.system(size: 11)).foregroundStyle(DS.Colors.warning)
                    .lineLimit(2).frame(maxWidth: 200, alignment: .trailing)
            }
        }
    }
}

/// The last seven days in one card: how many meetings, how long, with whom most often —
/// and a way to have them summed up. Only with two or more. In a folder, its meetings.
private struct WeekRecap: View {
    let meetings: [MeetingRecord]
    let all: [MeetingRecord]
    /// The folder chosen, by name: the card and the summary are its meetings.
    var folder: String? = nil
    @ObservedObject private var library = MeetingLibrary.shared

    var body: some View {
        let since = Date().addingTimeInterval(-7 * 86_400)
        // The meetings with text: what a question can read.
        let week = meetings.filter { $0.date > since && !$0.words.isEmpty }
        if week.count >= 2 {
            let time = week.reduce(0) { $0 + $1.duration }
            let people = ArchiveSection(id: "week", title: "", kind: .recent, meetings: week).people(among: all)
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    CapsLabel(String(localized: "Senaste veckan"))
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: String(localized: "\(week.count) möten"))
                            .font(.system(size: 30, weight: .regular, design: .serif)).monospacedDigit()
                        Text(verbatim: Stats.duration(time)).font(.system(size: 15)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    }
                    if !people.isEmpty {
                        Text(verbatim: String(localized: "Oftast med \(ListFormatter.localizedString(byJoining: people))"))
                            .font(.system(size: 13)).foregroundStyle(DS.Colors.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if MeetingNotes.isAvailable {
                    Button {
                        // "den senaste veckan": the same seven days as the card counts.
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            library.ask(folder.map { String(localized: "Vad hände i mötena i \($0) den senaste veckan?") }
                                        ?? String(localized: "Vad hände i mina möten den senaste veckan?"))
                        }
                    } label: {
                        Label(folder.map { String(localized: "Sammanfatta veckan i \($0)") } ?? String(localized: "Sammanfatta veckan"),
                              systemImage: "text.alignleft")
                    }
                    .buttonStyle(.soft)
                    .disabled(library.asking)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .card()
            .accessibilityElement(children: .contain)
        }
    }
}

/// No meetings yet: a glimpse of what one looks like.
private struct EmptyArchive: View {
    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ghost(width: 220, mark: 0)
                ghost(width: 160, mark: 1).padding(.leading, 34)
                ghost(width: 250, mark: 0)
            }
            .opacity(0.55)
            .accessibilityHidden(true)
            Text("Dina möten och inspelningar hamnar här.")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func ghost(width: CGFloat, mark: Int) -> some View {
        HStack(spacing: 10) {
            Circle().fill(SpeakerMark.fill(mark).opacity(0.5)).frame(width: 22, height: 22)
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.chip).frame(width: width, height: 30)
        }
    }
}

struct MeetingRow: View {
    let record: MeetingRecord
    let writing: Bool
    /// Under "Alla": the folder it's in, beside its time.
    var folder: String? = nil
    /// ⌘- or ⇧-clicked, to move with others.
    var selected = false
    /// In an older month: a line, not three.
    var compact = false
    /// Under a day's heading ("I går"): the time, not the day again.
    var timeOnly = false
    /// For "Importerad i dag" (a screenshot is drawn at a made-up moment).
    var now = Date()
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let cast = record.cast
        Button(action: open) {
            if compact { line } else { full(cast) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(record.title)
    }

    /// An older meeting: its title, its day, how long — one line.
    private var line: some View {
        HStack(spacing: 10) {
            if let source = record.source {
                Image(systemName: source.video ? "film" : "waveform")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            }
            Text(record.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
            if !record.finished {
                Text("Inte klart").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.warning)
            }
            Spacer(minLength: 12)
            if let folder {
                Label(folder, systemImage: "folder").font(.system(size: 11.5)).foregroundStyle(DS.Colors.faint).lineLimit(1)
            }
            Text(record.date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(AppLanguage.locale)))
                .font(.system(size: 12)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(Stats.duration(record.duration))
                .font(.system(size: 12)).foregroundStyle(DS.Colors.faint).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Colors.faint)
                .opacity(hovering ? 1 : 0.4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.chip.opacity(selected ? 1 : hovering ? 0.6 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(DS.Colors.ink.opacity(selected ? 0.35 : 0), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func full(_ cast: Cast) -> some View {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let source = record.source {
                            Image(systemName: source.video ? "film" : "waveform")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DS.Colors.muted)
                                .help(String(localized: "Importerad från \(source.file)"))
                        }
                        Text(record.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                        if !record.finished {
                            Text("Inte klart").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.warning)
                        }
                    }
                    if let lede {
                        Text(lede).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).lineLimit(1)
                    }
                    (Text(meta) + (folder.map { Text("  \(Image(systemName: "folder")) \($0)") } ?? Text("")))
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 12)
                if record.words.isEmpty {
                    SpeakerStack(cast: cast)
                } else {
                    MeetingRibbon(record: record, cast: cast, segments: MeetingText.segments(record.words), compact: true)
                        .frame(width: 96)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.faint)
                    .opacity(hovering ? 1 : 0.5)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.chip.opacity(selected ? 1 : hovering ? 0.6 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Colors.ink.opacity(selected ? 0.35 : 0), lineWidth: 1))
            .contentShape(Rectangle())
    }

    /// The first sentence of the notes — what the meeting was about.
    private var lede: String? {
        if writing { return String(localized: "Skriver sammanfattningen…") }
        guard let overview = record.summary?.overview, !overview.isEmpty else { return nil }
        var first = overview
        overview.enumerateSubstrings(in: overview.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s { first = s.trimmingCharacters(in: .whitespaces) }
            stop = true
        }
        return first
    }

    /// "I går 09:15 · 34 min · Anna, Erik" — or, just imported, "Importerad i dag ·
    /// inspelad 14 aug. · 34 min"; a file with no date in it says "Datum okänt".
    private var meta: String {
        let time: String
        if let imported = record.importMeta(at: now) { time = imported }
        else if record.source?.dateKnown == false { time = String(localized: "Datum okänt") }
        else if timeOnly { time = record.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale)) }
        else { time = MeetingRecord.when(record.date) }
        return ([time, Stats.duration(record.duration)] + (people.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// "Anna, Erik +2" — the people named in it, in the order they first spoke.
    private var people: String? {
        let cast = record.cast
        let named = cast.order.compactMap { cast.names[String($0)] }.filter { !$0.isEmpty }
        guard !named.isEmpty else { return nil }
        let shown = named.prefix(2).joined(separator: ", ")
        return named.count > 2 ? shown + " +\(named.count - 2)" : shown
    }
}

// MARK: - Speakers

/// A speaker's mark: their initial — or number, until named — on a quiet colour.
/// The same colour marks them everywhere: the line beside their words, their name,
/// the timeline.
struct SpeakerMark: View {
    let speaker: Int?
    let cast: Cast
    var size: CGFloat = 22

    /// Muted pigments, in the order people first speak; lighter in dark mode.
    private static let pigments: [(light: UInt32, dark: UInt32)] = [
        (0x5B7896, 0x7F9DBB), (0xA6705A, 0xC48F79), (0x6E8F78, 0x8FB09A), (0x86708F, 0xA892B0),
        (0x9C8646, 0xBBA466), (0x5A8A8C, 0x7CAAAC), (0x76706A, 0x98928C), (0x6A6F86, 0x8C91A8),
    ]

    /// A speaker's colour, the same wherever they appear; none known yet: faint.
    static func color(of speaker: Int?, in cast: Cast) -> Color {
        guard let speaker, speaker >= 0 else { return DS.Colors.faint }
        return fill(cast.number(of: speaker) - 1)
    }

    /// Their colour for a name written in it: a shade deeper on light paper, so it
    /// reads as well as the text (4.5:1).
    static func ink(of speaker: Int?, in cast: Cast) -> Color {
        guard let speaker, speaker >= 0 else { return DS.Colors.muted }
        let p = pigments[(cast.number(of: speaker) - 1) % pigments.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = dark ? p.dark : p.light
            let k: CGFloat = dark ? 1 : 0.72
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255 * k, green: CGFloat((hex >> 8) & 0xFF) / 255 * k,
                           blue: CGFloat(hex & 0xFF) / 255 * k, alpha: 1)
        })
    }

    static func fill(_ position: Int) -> Color {
        let p = pigments[position % pigments.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.dark : p.light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    var body: some View {
        ZStack {
            if let speaker, speaker >= 0 {
                Circle().fill(Self.fill(cast.number(of: speaker) - 1))
                Text(label(speaker))
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.onInk)
            } else {
                Circle().strokeBorder(DS.Colors.faint, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
                Text("?").font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.faint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func label(_ speaker: Int) -> String {
        guard cast.isNamed(speaker), let c = cast.name(of: speaker).first else { return "\(cast.number(of: speaker))" }
        return String(c).uppercased()
    }
}

/// Overlapping marks: who took part.
private struct SpeakerStack: View {
    let cast: Cast

    var body: some View {
        HStack(spacing: -6) {
            ForEach(cast.order.prefix(5), id: \.self) { s in
                SpeakerMark(speaker: s, cast: cast, size: 20)
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 2))
            }
            if cast.order.count > 5 {
                Text("+\(cast.order.count - 5)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.muted)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DS.Colors.chip))
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cast.order.map { cast.name(of: $0) }.joined(separator: ", "))
    }
}

/// A speaker's name; click to name them, or to say they're someone else.
struct SpeakerChip: View {
    let speaker: Int
    let cast: Cast
    /// Named by Mindtalk from a voice you named before.
    var recognized = false
    /// A capsule in the header, or the name above what they said in the text.
    var style: Style = .chip
    let rename: (String) -> Void
    let merge: (Int) -> Void
    @State private var editing = false

    enum Style { case chip, name }
    @State private var draft = ""
    /// Under the pointer: the name underlined and a pencil, so it reads as something to click.
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            draft = cast.isNamed(speaker) ? cast.name(of: speaker) : ""
            editing = true
        } label: {
            switch style {
            case .chip:
                HStack(spacing: 6) {
                    VoiceBadge(speaker: speaker, cast: cast, size: 18)
                    Text(cast.name(of: speaker)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading).fixedSize()
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.Colors.chip))
                .contentShape(Capsule())
                .accessibilityLabel(recognized ? String(localized: "\(cast.name(of: speaker)), igenkänd röst") : cast.name(of: speaker))
            case .name:
                HStack(spacing: 5) {
                    Text(cast.name(of: speaker))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SpeakerMark.ink(of: speaker, in: cast))
                        .underline(hovering, color: SpeakerMark.ink(of: speaker, in: cast).opacity(0.5))
                        .lineLimit(1)
                    Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.faint)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(recognized ? Text("Mindtalk kände igen rösten. Klicka för att ändra.") : Text("Ge talaren ett namn"))
        .accessibilityHint("Ge talaren ett namn")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vem är det här?").font(.system(size: 13, weight: .semibold))
                if recognized {
                    // A wrong guess, undone: the name goes, this meeting only — the voice
                    // Mindtalk remembers stays as it is.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mindtalk kände igen rösten.").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        Button { editing = false; rename("") } label: {
                            Label("Fel person? Ta bort namnet", systemImage: "xmark")
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Namnet tas bort i det här mötet. Mindtalk känner fortfarande igen rösten.")
                    }
                }
                TextField(cast.name(of: speaker), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($focused)
                    .onSubmit(save)
                let others = cast.order.filter { $0 != speaker }
                if !others.isEmpty {
                    Menu("Samma person som…") {
                        ForEach(others, id: \.self) { other in
                            Button(cast.name(of: other)) { editing = false; merge(other) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Två talare som är samma person slås ihop")
                }
                HStack {
                    Spacer()
                    Button("Avbryt") { editing = false }.buttonStyle(.soft)
                    Button("Spara", action: save).buttonStyle(.ink).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .onAppear { focused = true }
        }
    }

    private func save() {
        rename(draft)
        editing = false
    }
}

/// "Vem är här?" while the round lasts, the meeting after — watching the session
/// itself, so the meeting is there the moment the round ends, not at the next word.
private struct IntroductionGate<Meeting: View, Bar: View>: View {
    @ObservedObject var session: MeetingSession
    @ViewBuilder let meeting: () -> Meeting
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        ZStack(alignment: .bottom) {
            if session.introducing {
                // The round fills the room; the recording pill floats at its foot.
                VoiceScanner(session: session)
                    .transition(.opacity)
                bar()
            } else {
                // The meeting: the text above, your notes and the pill below it — the
                // text ends where they begin, nothing slides in behind them.
                VStack(spacing: 0) {
                    meeting().frame(maxHeight: .infinity)
                    bar()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: session.introducing)
    }
}

// MARK: - One meeting

struct MeetingView: View {
    let record: MeetingRecord
    let pending: [MeetingWord]
    /// Set while the meeting is being recorded or finished.
    let session: MeetingSession?
    let width: CGFloat
    let edit: MeetingEdits
    var back: (() -> Void)? = nil

    @ObservedObject private var notes = MeetingNotes.shared
    @ObservedObject private var epoch = WindowEpoch.shared
    /// For "Fortsätt mötet" on a saved meeting: whether it can, and why not.
    @ObservedObject private var recorder = MeetingSession.shared
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var confirmRemoveAudio = false
    @State private var changingDate = false
    @State private var copied = false
    @State private var tab: Tab = .summary
    /// "Visa i texten" from a source: the turn to scroll to.
    @State private var focusTurn: Int?
    /// "Visa i texten" from one of your notes: its index in `record.notes`, lit under its turn.
    @State private var focusNote: Int?
    /// Underline what the final pass changed.
    @State private var showChanges = false
    @FocusState private var editingTitle: Bool

    enum Tab: Hashable { case summary, transcript }

    private var live: Bool { session != nil }

    /// The meeting itself: its header, and the transcript or the summary.
    private var meeting: some View {
        let cast = record.cast
        let turns = MeetingText.turns(record.words, pending: pending, paragraphs: true)
        return VStack(spacing: 0) {
            header(cast)
            RememberVoicesOffer(record: record, live: live).padding(.bottom, 12)
            ZStack {
                if live || tab == .transcript {
                    TranscriptView(record: record, turns: turns, cast: cast, session: session, width: width,
                                   edit: edit, focusTurn: $focusTurn, focusNote: $focusNote,
                                   changed: showChanges ? Set(record.heal?.changed ?? []) : [])
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    SummaryView(record: record, turns: turns, cast: cast, notes: notes, width: width, edit: edit, showInText: { at in
                        focusTurn = turns.last { $0.start <= at + 0.05 }?.id
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = .transcript }
                    }, showNote: { i in
                        guard record.notes.indices.contains(i), let at = record.notes[i].at, !turns.isEmpty else { return }
                        focusNote = i
                        focusTurn = NotePlacement.turn(at: at, in: turns)
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = .transcript }
                    })
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .id(epoch.value)   // see WindowEpoch
            .frame(maxHeight: .infinity)
        }
    }

    var body: some View {
        Group {
            if let session {
                IntroductionGate(session: session) { meeting } bar: { LiveBar(session: session) }
                    .id(epoch.value)   // the bar too: built anew when the window comes back (see WindowEpoch)
            } else {
                ZStack(alignment: .bottom) {
                    meeting
                    bottomBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            // A title being typed when the page goes (⌘[, the meeting ending) is kept.
            if editingTitle { commitTitle() }
            if MeetingPlayer.shared.meeting == record.id { MeetingPlayer.shared.stop() }
            // A "Fortsätt mötet" that couldn't is said here — not later on another page.
            if !live, recorder.phase == .idle { recorder.lastError = nil }
        }
        .onAppear {
            title = record.title
            // Nothing can write a summary on this Mac: the text first, not an empty tab.
            if !live, !MeetingNotes.isAvailable, record.summary == nil { tab = .transcript }
            if let at = MeetingsPage.focusAt, !live {
                MeetingsPage.focusAt = nil
                tab = .transcript
                focusTurn = MeetingText.turns(record.words, paragraphs: true).last { $0.start <= at + 0.05 }?.id
            }
            #if DEBUG
            if CommandLine.arguments.contains("--meeting-text") { tab = .transcript }
            #endif
        }
        .onChange(of: record.title) { _, t in if !editingTitle { title = t } }
        .confirmationDialog("Ta bort mötet?", isPresented: $confirmDelete) {
            Button("meeting|Ta bort", role: .destructive) {
                if case .saved(let store, let id) = edit { back?(); store.delete(id) }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Inspelningen, texten, dina anteckningar och sammanfattningen flyttas till papperskorgen.")
        }
        .confirmationDialog("Ta bort inspelningen?", isPresented: $confirmRemoveAudio) {
            Button("Flytta till papperskorgen", role: .destructive) {
                if case .saved(let store, let id) = edit { store.removeAudio(of: id) }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Inspelningen flyttas till papperskorgen. Texten, dina anteckningar och sammanfattningen finns kvar, men det går inte längre att lyssna på mötet.")
        }
    }

    // MARK: Header

    private func header(_ cast: Cast) -> some View {
        let segments = MeetingText.segments(record.words)
        return headerStack(cast, segments)
    }

    private func headerStack(_ cast: Cast, _ segments: [MeetingText.Segment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let back {
                    Button(action: back) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                            Text("Möten").font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(DS.Colors.chip))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Alla möten (⌘[)")
                }
                Spacer()
                actions
            }
            .frame(height: 30)
            TextField("Namnlöst möte", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.pageTitle)
                .lineLimit(1...2)
                .focused($editingTitle)
                .onSubmit(commitTitle)
                .onChange(of: editingTitle) { _, editing in if !editing { commitTitle() } }
                .help("Ändra mötets titel")
            HStack(alignment: .center, spacing: 12) {
                FlowLayout(spacing: 8) {
                    Text(meta).font(.system(size: 13)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                        .padding(.trailing, 4)
                    // Imported: the file it came from — a click shows it in Finder — and
                    // the date to change, since a file's date can be wrong or missing.
                    // (A meeting recorded here keeps its real time.)
                    if !live, let source = record.source {
                        SourceLink(source: source).padding(.trailing, 4)
                        Button("Ändra datum") { changingDate = true }
                            .buttonStyle(SoftButtonStyle(small: true))
                            .help(source.dateKnown ? "Filens datum kan vara fel: ange när mötet var" : "Filen säger inte när den spelades in: ange när mötet var")
                            .popover(isPresented: $changingDate, arrowEdge: .bottom) {
                                MeetingDatePopover(record: record) { changingDate = false }
                            }
                    }
                    FolderTag(record: record)
                    ForEach(cast.order, id: \.self) { s in
                        SpeakerChip(speaker: s, cast: cast, recognized: record.recognized[String(s)] != nil,
                                    rename: { edit.name(s, $0) },
                                    merge: { other in withAnimation(.snappy) { edit.merge(s, into: other) } })
                    }
                }
                Spacer(minLength: 12)
                if !live {
                    PillPicker(options: [(Tab.summary, "Sammanfattning"), (Tab.transcript, "Text")], selection: $tab)
                }
            }
            if !segments.isEmpty {
                MeetingRibbon(record: record, cast: cast, segments: segments, live: live, now: session?.elapsed)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
            healLine
            banner
            SaveProblemLine()
            if !live { FolderSuggestion(record: record) }
            // "Fortsätt mötet" couldn't: why, here where you pressed it.
            if !live, let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.top, DS.Layout.pageTop - 10)
        .padding(.bottom, 12)
        .pageColumn(width)
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { title = record.title } else { edit.rename(t) }
    }

    private var meta: String {
        // A file that didn't say when it was recorded: "Datum okänt", and the import's
        // day in the source link beside it ("importerad i dag från …").
        let when = record.source?.dateKnown == false ? String(localized: "Datum okänt") : MeetingRecord.when(record.date)
        guard !live else { return when }
        var parts = [when, Self.duration(record.duration)]
        if record.informed != nil { parts.append(String(localized: "deltagarna informerades")) }
        if !record.hasAudio { parts.append(String(localized: "inspelningen borttagen")) }
        return parts.joined(separator: " · ")
    }

    /// What listening through the whole meeting changed — and a way to see it.
    @ViewBuilder private var healLine: some View {
        if !live, let heal = record.heal, heal.words + heal.speakers > 0 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal").foregroundStyle(DS.Colors.muted)
                Text(Self.healText(heal)).foregroundStyle(DS.Colors.muted)
                if heal.words > 0 {
                    Button(showChanges ? "Dölj ändringar" : "Visa ändringar") {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            showChanges.toggle()
                            if showChanges { tab = .transcript }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                }
            }
            .font(.system(size: 12.5))
        }
    }

    /// Whole sentences, each its own string (English counts words and changes itself).
    static func healText(_ heal: MeetingRecord.Heal) -> String {
        let words = heal.words, changes = heal.speakers
        switch (words > 0, changes) {
        case (true, 0):
            return String(localized: "Mindtalk lyssnade igenom mötet igen och rättade \(words) ord.")
        case (false, 1):
            return String(localized: "Mindtalk lyssnade igenom mötet igen och justerade ett talarbyte.")
        case (false, _):
            return String(localized: "Mindtalk lyssnade igenom mötet igen och justerade \(changes) talarbyten.")
        case (true, 1):
            return String(localized: "Mindtalk lyssnade igenom mötet igen. \(words) ord rättades och ett talarbyte justerades.")
        case (true, _):
            return String(localized: "Mindtalk lyssnade igenom mötet igen. \(words) ord rättades och \(changes) talarbyten justerades.")
        }
    }

    /// A meeting that didn't get its final pass: say so, and offer it.
    @ViewBuilder private var banner: some View {
        if !live, record.hasAudio, MeetingSession.shared.phase == .idle, !record.finished || (!record.refined && !record.words.isEmpty) {
            HStack(spacing: 10) {
                Image(systemName: record.finished ? "text.badge.checkmark" : "exclamationmark.circle")
                    .foregroundStyle(record.finished ? DS.Colors.muted : DS.Colors.warning)
                Text(record.finished
                     ? String(localized: "Texten skrevs medan ni pratade. Lyssna igenom mötet igen för en mer exakt text.")
                     : String(localized: "Mötet avbröts innan det blev klart. Inspelningen finns kvar."))
                    .font(.system(size: 13))
                Spacer()
                Button(record.finished ? "Lyssna igenom" : "Gör klart") {
                    MeetingSession.shared.finishInterrupted(record.id)
                }
                .buttonStyle(.soft)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .card()
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            // The meeting beside your work instead — the same as closing the window.
            if let session, session.isBusy {
                Button { MeetingPanel.shared.collapse() } label: {
                    Label("Visa som panel", systemImage: "pip.enter")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(DS.Colors.chip))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Mötet fortsätter i en liten panel bredvid det du gör")
            }
            if !live { ExportMenu(record: record) }
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.chip))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(record.words.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help(copyHelp)
            .accessibilityLabel(copyHelp)
            if !live {
                Menu {
                    Menu("Sammanfatta igen") {
                        ForEach(SummaryLanguage.allCases) { choice in
                            Button(choice.menuTitle) {
                                notes.summarize(record.id, in: choice)
                            }
                        }
                    }
                    .disabled(!MeetingNotes.isAvailable || notes.writing.contains(record.id))
                    if record.source != nil { Button("Ändra datum…") { changingDate = true } }
                    if record.hasAudio {
                        Button("Spela in mer") { AppDelegate.continueMeeting(record.id) }
                            .disabled(!record.finished || MeetingSession.shared.phase != .idle)
                        // Again — in another language too, when there's more than one.
                        let models = SpeechModel.allCases.filter(\.isInstalled)
                        if models.count > 1 {
                            Menu("Lyssna igenom igen") {
                                ForEach(models, id: \.self) { model in
                                    Button {
                                        MeetingSession.shared.finishInterrupted(record.id, language: model)
                                    } label: {
                                        if model == record.language { Label(model.listenIn, systemImage: "checkmark") } else { Text(model.listenIn) }
                                    }
                                }
                            }
                            .disabled(MeetingSession.shared.phase != .idle)
                        } else {
                            Button("Lyssna igenom igen") { MeetingSession.shared.finishInterrupted(record.id) }
                                .disabled(MeetingSession.shared.phase != .idle)
                        }
                        Button("Visa inspelningen i Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.audioURL(for: record.id)])
                        }
                        Button("Ta bort inspelningen…") { confirmRemoveAudio = true }
                    }
                    Divider()
                    Button("Ta bort mötet…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.Colors.chip))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mer")
                .accessibilityLabel("Mer")
            }
        }
    }

    private var copyHelp: String {
        !live && tab == .summary && record.summary != nil
            ? String(localized: "Kopiera sammanfattningen (⇧⌘C)") : String(localized: "Kopiera texten (⇧⌘C)")
    }

    private func copy() {
        put(!live && tab == .summary && record.summary != nil ? MeetingNotes.markdown(record) : MeetingText.plain(record))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The notes and the text as a Markdown file.
    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        if let session {
            LiveBar(session: session)
        } else if !record.words.isEmpty {
            ReviewBar(record: record, notes: notes, width: width) {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = .summary }
            }
        }
    }

    // MARK: Shared

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "1 minut 12 sekunder" — for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Paper fading out under a floating bar, so text slides under it rather than being cut.
private struct BottomScrim: View {
    var height: CGFloat = 70
    var body: some View {
        LinearGradient(colors: [DS.Colors.paper.opacity(0), DS.Colors.paper], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    let record: MeetingRecord
    let turns: [MeetingTurn]
    let cast: Cast
    let session: MeetingSession?
    let width: CGFloat
    let edit: MeetingEdits
    @Binding var focusTurn: Int?
    @Binding var focusNote: Int?
    var changed: Set<Int> = []
    /// Renders: the rows in a plain stack, no scroll view (ImageRenderer draws none).
    var flat = false
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var atBottom = true
    /// Following the newest text — until you scroll up yourself; back at the bottom
    /// (or "Till det senaste"), it follows again. Not decided by where the view happens to be
    /// when a burst of text arrives.
    @State private var following = true
    @State private var userScrolling = false

    private var live: Bool { session != nil }

    var body: some View {
        // Your notes under the turns they were written in (saved meetings: live, the
        // island shows them as they come).
        let notes = live ? [:] : NotePlacement.place(record, turns: turns)
        if flat {
            VStack(alignment: .leading, spacing: 0) { rows(notes) }.pageColumn(width).padding(.top, 8)
        } else {
            scrolling(notes)
        }
    }

    @ViewBuilder private func rows(_ notes: [Int: [NotePlacement.Placed]]) -> some View {
        if turns.isEmpty { empty }
        ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
            let newSpeaker = i == 0 || turns[i - 1].speaker != turn.speaker
            let end = i + 1 < turns.count ? turns[i + 1].id : record.words.count
            let next = i + 1 < turns.count ? turns[i + 1].start : .infinity
            let playing = isPlaying(turn, next: next)
            TurnRow(turn: turn, cast: cast, showName: newSpeaker, live: live,
                    isLast: i == turns.count - 1,
                    playing: playing,
                    words: live ? [] : Array(record.words[turn.id..<max(turn.id, end)]),
                    firstIndex: turn.id,
                    changed: changed,
                    karaoke: playing ? player.time : nil,
                    focused: focusTurn == turn.id,
                    play: live || !record.hasAudio ? nil : { player.play(record.id, from: turn.start) },
                    move: turn.id < end && turn.pending.isEmpty
                        ? { speaker in
                            // Their own words — someone else's "Mm" inside stays theirs.
                            withAnimation(.snappy) { for run in turn.own(until: end) { edit.move(run, to: speaker) } }
                        } : nil,
                    marks: record.marks.filter { $0.at >= (i == 0 ? -.infinity : turn.start) && $0.at < next },
                    removeMark: { id in withAnimation(.snappy) { edit.removeMark(id) } },
                    notes: notes[turn.id] ?? [],
                    focusedNote: focusNote,
                    listen: record.hasAudio ? { at in player.play(record.id, from: max(0, at - 8)) } : nil,
                    recognized: turn.speaker.map { record.recognized[String($0)] != nil } ?? false,
                    rename: turn.speaker.flatMap { s in s >= 0 ? { edit.name(s, $0) } : nil },
                    merge: turn.speaker.flatMap { s in
                        s >= 0 ? { other in withAnimation(.snappy) { edit.merge(s, into: other) } } : nil
                    })
                .padding(.top, i == 0 ? 0 : newSpeaker ? 26 : 12)
                .id(turn.id)
        }
        Color.clear.frame(height: 1).id("end")
    }

    private func scrolling(_ notes: [Int: [NotePlacement.Placed]]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { rows(notes) }
                .pageColumn(width)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, live ? 28 : 120, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
                if bottom { following = true }
            }
            // A mouse wheel or the keys move the view without a scroll phase: moved up
            // while the text stayed the same — that's you, reading back.
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentSize.height] } action: { old, new in
                if new[1] == old[1], new[0] < old[0] - 4, !atBottom { following = false }
            }
            // Only your own scrolling stops the following: where it ends decides.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: userScrolling = true
                case .idle:
                    if userScrolling { userScrolling = false; following = atBottom }
                default: break
                }
            }
            // Follow the conversation — unless you've scrolled up to read. On what the
            // text takes up, not on how many words: a new name row, a mark or a line
            // that settles also grows it.
            // (Or when the room for it shrinks: a card below appears, the note grows.)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentSize.height, $0.containerSize.height] } action: { old, new in
                guard live, following, !userScrolling, new != old else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Listening: the text follows the voice.
            .onChange(of: playingTurn) { _, id in
                guard let id, player.isPlaying else { return }
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: focusTurn, initial: true) { _, id in
                guard let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(id, anchor: .center) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if focusTurn == id { focusTurn = nil; focusNote = nil } }
            }
            // The text slips away under the header rather than being cut off.
            .overlay(alignment: .top) {
                LinearGradient(colors: [DS.Colors.paper, DS.Colors.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    BottomScrim(height: live ? 22 : 70)
                    if live, !following, !turns.isEmpty {
                        Button {
                            following = true
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
                        } label: {
                            Label("Till det senaste", systemImage: "arrow.down")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(DS.Colors.onInk)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(Capsule().fill(DS.Colors.ink))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, live ? 14 : 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.15), value: following)
            }
            // Built anew mid-meeting (WindowEpoch): back to where the conversation is.
            .onAppear {
                guard live, !turns.isEmpty else { return }
                following = true
                // Once now, and once more after the layout has settled (after the round).
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if following { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
    }

    private var playingTurn: Int? {
        guard player.meeting == record.id else { return nil }
        return turns.last { $0.start - 0.4 <= player.time }?.id
    }

    private func isPlaying(_ turn: MeetingTurn, next: Double) -> Bool {
        player.meeting == record.id && player.isPlaying && player.time >= turn.start - 0.4 && player.time < next - 0.4
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(DS.Colors.faint)
            if session?.phase == .starting {
                Text("Förbereder…").font(.system(size: 15, weight: .semibold))
                Text("Inspelningen är igång, inget går förlorat.")
            } else if live {
                Text("Lyssnar").font(.system(size: 15, weight: .semibold))
                Text("Börja prata, så kommer texten här.")
            } else {
                Text("Inget hördes").font(.system(size: 15, weight: .semibold))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DS.Colors.muted)
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

extension MeetingTurn {
    /// What was said, with others' "Mm" in its place — small and muted, named.
    @MainActor func spoken(cast: Cast) -> Text {
        guard !asides.isEmpty else { return Text(text) }
        var out = Text("")
        var from = text.startIndex
        for aside in asides {
            let cut = text.index(text.startIndex, offsetBy: min(aside.at, text.count))
            if cut > from { out = Text("\(out)\(String(text[from..<cut]))") }
            let tag = Text(" (\(cast.name(of: aside.speaker)): \(aside.text))")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            out = Text("\(out)\(tag)")
            from = max(from, cut)
        }
        return Text("\(out)\(String(text[from...]))")
    }
}

/// One turn: the speaker's mark in the margin, their name, and what they said —
/// what's still being written in grey, ending in Mindtalk's cursor.
private struct TurnRow: View {
    let turn: MeetingTurn
    let cast: Cast
    let showName: Bool
    let live: Bool
    let isLast: Bool
    let playing: Bool
    /// The turn's words — for playback in step, and to show what the final pass changed.
    var words: [MeetingWord] = []
    var firstIndex = 0
    var changed: Set<Int> = []
    /// Listening: how far the voice has come.
    var karaoke: Double? = nil
    let focused: Bool
    let play: (() -> Void)?
    let move: ((Int) -> Void)?
    /// The moments you marked during this turn.
    var marks: [MeetingRecord.Mark] = []
    var removeMark: ((UUID) -> Void)? = nil
    /// Your own notes written while this was said, and the one "Visa i texten" asked for.
    var notes: [NotePlacement.Placed] = []
    var focusedNote: Int? = nil
    var listen: ((Double) -> Void)? = nil
    /// The name above the text: click it to name or correct them, as in the header.
    var recognized = false
    var rename: ((String) -> Void)? = nil
    var merge: ((Int) -> Void)? = nil

    private var speaker: Int? { turn.speaker.flatMap { $0 >= 0 ? $0 : nil } }
    private var showsChanges: Bool { !changed.isEmpty && (firstIndex..<(firstIndex + words.count)).contains { changed.contains($0) } }

    private var tint: Color { SpeakerMark.color(of: speaker, in: cast) }
    private var lit: Bool { playing || focused }

    /// A document, not a chat: who spoke in a thin line of their colour beside what
    /// they said, their name above it when it's someone new.
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showName { nameRow }
            line
            if !marks.isEmpty {
                markRow
                    .padding(.top, 3)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }
            if !notes.isEmpty {
                NoteLines(notes: notes, focused: focusedNote, listen: listen)
                    .padding(.top, 3)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, lit ? 7 : 0)
        .padding(.trailing, lit ? 12 : 0)
        .background(alignment: .leading) {
            Capsule().fill(tint.opacity(speaker == nil ? 0.6 : 1)).frame(width: lit ? 3.5 : 2.5)
        }
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.09)).transition(.opacity)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: lit)
        .contextMenu {
            Button("Kopiera") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.text, forType: .string)
            }
            if let play { Button("Lyssna härifrån", action: play) }
            if let move, cast.order.count > 1 {
                Menu("Fel talare? Flytta till…") {
                    ForEach(cast.order.filter { $0 != speaker }, id: \.self) { s in
                        Button(cast.name(of: s)) { move(s) }
                    }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// "Beslut 3:12" — what you marked while this was said.
    private var markRow: some View { MarkChips(marks: marks, remove: removeMark) }

    private var nameRow: some View {
        HStack(spacing: 8) {
            if let speaker, let rename, let merge {
                SpeakerChip(speaker: speaker, cast: cast, recognized: recognized, style: .name, rename: rename, merge: merge)
            } else {
                Text(speaker.map { cast.name(of: $0) }
                     ?? (live ? String(localized: "Känner igen rösten…") : String(localized: "Okänd talare")))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpeakerMark.ink(of: speaker, in: cast))
            }
            if let play {
                Button(action: play) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 7.5))
                        Text(MeetingView.duration(turn.start)).monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.faint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lyssna härifrån")
                .accessibilityLabel("Lyssna från \(MeetingView.spoken(turn.start))")
            } else {
                Text(MeetingView.duration(turn.start))
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DS.Colors.faint)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var line: some View {
        Group {
            if live && isLast {
                // The words still arriving, and the cursor blinking after them. One view
                // whether or not words are pending — so settling fades rather than snaps —
                // on a fixed beat that a redraw doesn't restart.
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.5)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                    text(cursor: turn.pending.isEmpty ? nil : on)
                }
            } else if !words.isEmpty, karaoke != nil || showsChanges {
                Text(wordByWord)
            } else {
                text(cursor: nil)
            }
        }
        // Live: words settle from grey into ink rather than switching.
        .contentTransition(.interpolate)
        .font(.system(size: 16))
        .lineSpacing(6)
        .textSelection(.enabled)
        // All its lines, whatever sits under it (two of your notes made it one line and an ellipsis).
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 640, alignment: .leading)
        // The text grows with its words, rather than snapping to the new size.
        .animation(live ? .smooth(duration: 0.4) : nil, value: turn.text)
    }

    private func text(cursor: Bool?) -> Text {
        var out = turn.spoken(cast: cast)
        if !turn.pending.isEmpty {
            let pending = Text(turn.text.isEmpty ? turn.pending : " " + turn.pending).foregroundStyle(DS.Colors.muted)
            out = Text("\(out)\(pending)")
        }
        if let cursor {
            let glyph = Text(" \(Image(nsImage: Self.cursor))")
                .foregroundStyle(DS.Colors.ink.opacity(cursor ? 0.9 : 0.15))
            out = Text("\(out)\(glyph)")
        }
        return out
    }

    /// The words one by one: said so far in ink, still to come in grey — and what the
    /// final pass rewrote, underlined.
    private var wordByWord: AttributedString {
        var out = AttributedString()
        // Your spellings and no hesitation sounds, as in the rest of the text — when
        // the cleanup keeps the word count, so each word still has its time.
        let cleaned = MeetingText.clean(words.map(\.text).joined(separator: " ")).split(separator: " ").map(String.init)
        let shown = cleaned.count == words.count ? cleaned : words.map(\.text)
        for (k, w) in words.enumerated() {
            var piece = AttributedString((k == 0 ? "" : " ") + shown[k])
            if let t = karaoke { piece.foregroundColor = w.start <= t ? .primary : DS.Colors.muted }
            if changed.contains(firstIndex + k) {
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: DS.Colors.accent.opacity(0.7))
            }
            out += piece
        }
        return out
    }

    /// Mindtalk's I-beam (as in the icon and the HUD), as an image text can hold.
    private static let cursor: NSImage = {
        let image = NSImage(size: NSSize(width: 7, height: 15), flipped: false) { r in
            let stem: CGFloat = 1.6
            NSColor.black.setFill()
            for bar in [NSRect(x: (r.width - stem) / 2, y: 0, width: stem, height: r.height),
                        NSRect(x: 0, y: 0, width: r.width, height: stem),
                        NSRect(x: 0, y: r.height - stem, width: r.width, height: stem)] {
                NSBezierPath(roundedRect: bar, xRadius: stem / 2, yRadius: stem / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

// MARK: - Sammanfattning

/// The notes as a document: what it was about, decisions, tasks to tick off, what's
/// worth remembering — and your questions. Everything with a time you can hear.
private struct SummaryView: View {
    let record: MeetingRecord
    let turns: [MeetingTurn]
    let cast: Cast
    @ObservedObject var notes: MeetingNotes
    let width: CGFloat
    let edit: MeetingEdits
    let showInText: (Double) -> Void
    /// One of your notes: show where in the text it was written.
    let showNote: (Int) -> Void
    @State private var addingNotes = false

    private var writing: Bool { notes.writing.contains(record.id) }
    /// Just written again: say so for a moment.
    @State private var justRewritten = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Color.clear.frame(height: 0).id("top")
                    ownNotes
                    notesSection
                    if record.notes.isEmpty, !addingNotes {
                        Button { withAnimation(.easeOut(duration: 0.2)) { addingNotes = true } } label: {
                            Label("Lägg till anteckningar", systemImage: "plus")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(DS.Colors.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Skriv det som var viktigt för dig, så bygger sammanfattningen på det")
                    }
                    if let error = notes.failed[record.id] {
                        HStack(spacing: 10) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13)).foregroundStyle(DS.Colors.warning)
                            // Ollama or LM Studio wasn't running: open it, then try again with it.
                            if let backend = notes.failedServer[record.id] {
                                Spacer(minLength: 8)
                                if backend.isInstalled {
                                    Button(backend.openTitle) { LocalServers.shared.open(backend) }.buttonStyle(.soft)
                                }
                                Button("Försök igen") { notes.summarize(record.id) }.buttonStyle(.soft)
                                    .disabled(writing)
                            }
                        }
                    }
                    if !record.answers.isEmpty || notes.answering.contains(record.id) { answers }
                    Color.clear.frame(height: 1).id("end")
                }
                .pageColumn(width)
                .padding(.top, 14)
            }
            .contentMargins(.bottom, 150, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .bottom) { BottomScrim() }
            .onChange(of: record.answers.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: notes.answering.contains(record.id)) { _, busy in
                if busy { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            // Rewriting: up to where it happens; done: a word that it's new.
            .onChange(of: writing) { was, now in
                if now { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) } }
                if was && !now && record.summary != nil {
                    justRewritten = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { justRewritten = false }
                }
            }
        }
    }

    /// What you wrote yourself — first, since it's what mattered to you.
    @ViewBuilder private var ownNotes: some View {
        if !record.notes.isEmpty || addingNotes {
            SavedNotes(record: record, edit: edit, startEditing: addingNotes, listen: { at in
                MeetingPlayer.shared.play(record.id, from: max(0, at - 8))
            }, showInText: showNote)
        }
    }

    /// "3 beslut · 2 uppgifter · 41 min" — under the summary, what it holds.
    static func contents(_ summary: MeetingSummary, duration: Double) -> String {
        var parts: [String] = []
        let d = summary.decisions.count, t = summary.tasks.count
        if d > 0 { parts.append(d == 1 ? String(localized: "1 beslut") : String(localized: "\(d) beslut")) }
        if t > 0 { parts.append(t == 1 ? String(localized: "1 uppgift") : String(localized: "\(t) uppgifter")) }
        parts.append(Stats.duration(duration))
        return parts.joined(separator: " · ")
    }

    /// You wrote to your notes (or gave a mark words) after the summary was written:
    /// it doesn't know. Not while it's being written again, not for summaries from
    /// before this was kept, and not when nothing on this Mac can write one.
    private var notesChanged: Bool {
        guard let from = record.summary?.notesFrom, !writing, MeetingNotes.isAvailable else { return false }
        return from != record.notesFingerprint
    }

    @ViewBuilder private var notesSection: some View {
        // A summary already written is shown also when no model can write one now.
        if let summary = record.summary {
            VStack(alignment: .leading, spacing: 32) {
            if writing || justRewritten {
                RewriteBanner(writing: writing, cancel: BetterNotes.shared.server == nil ? nil : { notes.cancelSummary(record.id) })
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if notesChanged {
                NotesChangedRow { notes.summarize(record.id) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // The old notes stay while the new ones are written — faded, so it's
            // clear they're about to change.
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary.overview)
                        .font(.system(size: 20, weight: .regular, design: .serif))
                        .lineSpacing(7)
                        .textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading)
                    Text(verbatim: Self.contents(summary, duration: record.duration))
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                }
                .staggered(0)
                if !summary.decisions.isEmpty {
                    NotesList(title: "Beslut", kind: .decision, items: summary.decisions, record: record, cast: cast,
                              turns: turns, showInText: showInText).staggered(1)
                }
                if !summary.tasks.isEmpty {
                    NotesList(title: "Att göra", kind: .task, items: summary.tasks, record: record, cast: cast,
                              turns: turns, showInText: showInText).staggered(2)
                }
                if !summary.points.isEmpty {
                    NotesList(title: "Värt att komma ihåg", kind: .point, items: summary.points, record: record, cast: cast,
                              turns: turns, showInText: showInText).staggered(3)
                }
                HStack(alignment: .center, spacing: 7) {
                    Image(systemName: summary.writer == nil ? "apple.intelligence" : "sparkle")
                        .font(.system(size: 12))
                    Text(String(localized: "Sammanfattat av \(summary.writer ?? "Apple Intelligence")."))
                    // Who writes the summaries is chosen in Settings → Möten: one click away.
                    Button("Byt modell") { SettingsPage.open(.meetings) }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(DS.Colors.accent)
                        .help("Välj vilken modell som skriver sammanfattningarna i Inställningar → Möten.")
                    Text("Stämmer något inte? Klicka på en tid och lyssna själv.")
                    Spacer(minLength: 16)
                    if MeetingNotes.isAvailable {
                        Button {
                            notes.summarize(record.id)
                        } label: {
                            Label("Sammanfatta igen", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.soft)
                        .disabled(writing)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colors.muted)
                .staggered(4)
                // Written by Apple Intelligence: once, the Gemma that suits this Mac.
                if summary.writer == nil, MeetingSession.shared.record?.id != record.id { NotesModelOffer().staggered(5) }
            }
            .id(summary.created)
            .opacity(writing ? 0.35 : 1)
            .blur(radius: writing ? 1.2 : 0)
            .allowsHitTesting(!writing)
            .animation(.easeInOut(duration: 0.4), value: writing)
            }
            .animation(.spring(duration: 0.4, bounce: 0.12), value: writing || justRewritten)
        } else if writing {
            WritingPlaceholder(cancel: BetterNotes.shared.server == nil ? nil : { notes.cancelSummary(record.id) })
        } else if !MeetingNotes.isAvailable {
            unavailable
        } else {
            HStack(spacing: 14) {
                Image(systemName: "apple.intelligence").font(.system(size: 18)).foregroundStyle(DS.Colors.muted)
                Text("Ingen sammanfattning än").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    notes.summarize(record.id)
                } label: {
                    Label("Sammanfatta", systemImage: "apple.intelligence")
                }
                .buttonStyle(.ink)
                .disabled(record.words.isEmpty)
            }
            .padding(20)
            .card()
        }
    }

    private var unavailable: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.intelligence").font(.system(size: 18)).foregroundStyle(DS.Colors.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sammanfattningar behöver Apple Intelligence eller Gemma 4").font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(unavailableDetail))
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            }
            Spacer()
            if Polisher.status == .notEnabled {
                Button("Slå på") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
                .buttonStyle(.soft)
            }
            // The other way: Gemma 4, on this Mac, when it can run it.
            if NotesModel.recommended != nil {
                Button("Ladda ned Gemma 4") { SettingsPage.open(.meetings) }
                    .buttonStyle(.soft)
            }
        }
        .padding(20)
        .card()
    }

    private var unavailableDetail: String {
        switch Polisher.status {
        case .notEnabled: return String(localized: "Slå på Apple Intelligence för att få en sammanfattning. Texten finns under fliken Text.")
        case .notReady: return String(localized: "Apple Intelligence laddas ned. Sammanfatta när den är klar.")
        default:
            return NotesModel.recommended != nil
                ? String(localized: "Den här Macen kan inte köra Apple Intelligence. Ladda ned Gemma 4 under Inställningar → Möten. Texten finns under fliken Text.")
                : String(localized: "Den här Macen kan inte köra Apple Intelligence. Texten finns under fliken Text.")
        }
    }

    /// Your questions in ink, the answers on paper — with their sources.
    private var answers: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle("Frågor")
            ForEach(record.answers) { a in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer(minLength: 80)
                        Text(a.question)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DS.Colors.onInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.ink))
                            .frame(maxWidth: 420, alignment: .trailing)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "apple.intelligence").font(.system(size: 13)).foregroundStyle(DS.Colors.faint)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(a.answer).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                            if !a.sources.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(a.sources, id: \.self) { at in
                                        Receipt(at: at, record: record, cast: cast, turns: turns, showInText: showInText)
                                    }
                                }
                            }
                        }
                    }
                }
                .contextMenu {
                    Button("Kopiera svaret") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(a.answer, forType: .string)
                    }
                    Button("Ta bort frågan", role: .destructive) { notes.forget(a, in: record.id) }
                }
            }
            if notes.answering.contains(record.id) {
                HStack(spacing: 10) {
                    SettlingLine(color: DS.Colors.ink).scaleEffect(0.8)
                    Text("Letar i mötet…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                }
            }
        }
    }
}

/// A section of the notes: its items, each with what kind it is and its source.
private struct NotesList: View {
    enum Kind { case decision, task, point }

    let title: String
    let kind: Kind
    let items: [MeetingSummary.Item]
    let record: MeetingRecord
    let cast: Cast
    let turns: [MeetingTurn]
    let showInText: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .semibold))
                Text("\(items.count)").font(.system(size: 13)).foregroundStyle(DS.Colors.faint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { CardDivider() }
                    row(item)
                }
            }
            .card()
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
    }

    private func row(_ item: MeetingSummary.Item) -> some View {
        let done = item.done == true
        return HStack(alignment: .center, spacing: 12) {
            marker(item, done: done)
            Text(item.text)
                .font(.system(size: 15))
                .strikethrough(done, color: DS.Colors.muted)
                .foregroundStyle(done ? DS.Colors.muted : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.marked == true {
                Image(systemName: "flag.fill").font(.system(size: 10.5)).foregroundStyle(markTint)
                    .help("Du markerade det här under mötet")
                    .accessibilityLabel("Markerat av dig")
            }
            if let owner = item.owner { OwnerTag(name: owner, cast: cast) }
            if let at = item.at {
                Receipt(at: at, record: record, cast: cast, turns: turns, showInText: showInText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .animation(.easeOut(duration: 0.25), value: done)
    }

    /// The colour of what you marked: the list's kind.
    private var markTint: Color {
        switch kind {
        case .decision: return MeetingRecord.Mark.Kind.decision.tint
        case .task: return MeetingRecord.Mark.Kind.task.tint
        case .point: return MeetingRecord.Mark.Kind.important.tint
        }
    }

    @ViewBuilder private func marker(_ item: MeetingSummary.Item, done: Bool) -> some View {
        switch kind {
        case .decision:
            Image(systemName: "checkmark.circle").font(.system(size: 15)).foregroundStyle(DS.Colors.muted)
                .accessibilityHidden(true)
        case .task:
            Button {
                MeetingStore.shared.setDone(item.id, !done, in: record.id)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(done ? AnyShapeStyle(DS.Colors.ink) : AnyShapeStyle(DS.Colors.faint))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Klar" : "Inte klar")
            .help(done ? "Markera som inte klar" : "Markera som klar")
        case .point:
            Circle().fill(DS.Colors.muted).frame(width: 5, height: 5).frame(width: 16).accessibilityHidden(true)
        }
    }
}

/// Who does it — their mark and name, if they're one of the speakers.
private struct OwnerTag: View {
    let name: String
    let cast: Cast

    var body: some View {
        let speaker = cast.order.first { cast.name(of: $0).caseInsensitiveCompare(name) == .orderedSame }
        HStack(spacing: 5) {
            if let speaker { SpeakerMark(speaker: speaker, cast: cast, size: 18) }
            Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                .lineLimit(1).frame(maxWidth: 120, alignment: .trailing).fixedSize()
        }
    }
}

/// The source: when it was said — play from there. Click for the words.
private struct Receipt: View {
    let at: Double
    let record: MeetingRecord
    let cast: Cast
    let turns: [MeetingTurn]
    let showInText: (Double) -> Void
    @State private var open = false
    @State private var hovering = false

    private var turn: MeetingTurn? { turns.last { $0.start <= at + 0.05 } ?? turns.first }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 7.5))
                Text(MeetingView.duration(at)).monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(hovering ? DS.Colors.onInk : DS.Colors.muted)
            .frame(minWidth: 48)
            .frame(height: 22)
            .padding(.horizontal, 6)
            .background(Capsule().fill(hovering ? DS.Colors.ink : DS.Colors.control))
            .overlay(Capsule().strokeBorder(hovering ? Color.clear : DS.Colors.fieldStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Visa var det sades")
        .accessibilityLabel("Källa, \(MeetingView.spoken(at))")
        .accessibilityHint("Visar och spelar upp det som sades")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                if let turn {
                    let speaker = turn.speaker.flatMap { $0 >= 0 ? $0 : nil }
                    HStack(spacing: 8) {
                        SpeakerMark(speaker: speaker, cast: cast, size: 20)
                        Text(speaker.map { cast.name(of: $0) } ?? String(localized: "Okänd talare"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(MeetingView.duration(turn.start)).font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(DS.Colors.muted)
                    }
                    Text("”\(turn.text)”")
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(3)
                        .lineLimit(10)
                        .textSelection(.enabled)
                        .frame(width: 360, alignment: .leading)
                }
                HStack(spacing: 8) {
                    if record.hasAudio {
                        Button {
                            MeetingPlayer.shared.play(record.id, from: at)
                        } label: {
                            Label("Lyssna", systemImage: "play.fill")
                        }
                        .buttonStyle(.ink)
                    }
                    Button("Visa i texten") {
                        open = false
                        showInText(at)
                    }
                    .buttonStyle(.soft)
                }
            }
            .padding(18)
        }
    }
}

/// While the notes are being written: the shape of what's coming.
private struct WritingPlaceholder: View {
    /// Your own model in Ollama or LM Studio can be stopped.
    var cancel: (() -> Void)? = nil
    @State private var sweep = false
    /// Your own model says where it is: starting, reading, writing.
    @ObservedObject private var servers = LocalServers.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 8) {
                SettlingLine(color: DS.Colors.ink).scaleEffect(0.8)
                Text(servers.progress
                     ?? (BetterNotes.shared.isActive ? String(localized: "\(BetterNotes.shared.writerSentenceName) skriver sammanfattningen…")
                                                     : String(localized: "Skriver sammanfattningen…")))
                if let cancel {
                    Button("Avbryt", action: cancel).buttonStyle(.soft).controlSize(.small).padding(.leading, 6)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Colors.muted)
            VStack(alignment: .leading, spacing: 10) {
                bar(0.95); bar(0.88); bar(0.6)
            }
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 5).fill(DS.Colors.chip).frame(width: 90, height: 12)
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.card).frame(height: 96)
                }
            }
        }
        .opacity(reduceMotion ? 0.7 : sweep ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
        .onAppear { sweep = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skriver sammanfattningen…")
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(DS.Colors.chip)
            .frame(maxWidth: .infinity).frame(height: 16)
            .scaleEffect(x: width, anchor: .leading)
    }
}

// MARK: - Bars

/// While recording: the island (time, note, marks, stop); otherwise the dark pill, as
/// when you dictate — time, sound, stop. Above
/// it, a word when something needs attention.
private struct LiveBar: View {
    @ObservedObject var session: MeetingSession
    /// Until the panel has been used once: closing the window doesn't end the meeting.
    @AppStorage(MeetingPanel.tipSeenKey) private var panelTipSeen = false

    var body: some View {
        VStack(spacing: 10) {
            if let caption {
                // A warning carries its sign, not only its colour (as in the panel).
                (caption.warning ? Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(caption.text)") : Text(caption.text))
                    .font(.system(size: 12.5, weight: caption.warning ? .medium : .regular))
                    .foregroundStyle(caption.warning ? DS.Colors.warning : DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.paper.opacity(0.9)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Recording: one island — the time, your note, the marks, stop.
            if session.isRecording, !session.introducing, !session.stopping {
                NoteIsland(session: session) { timer } trailing: { MeetingControls(session: session) }
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            } else {
                pill
            }
        }
        .padding(.bottom, 22)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: session.phase)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: session.stopping)
        .animation(.easeOut(duration: 0.25), value: caption?.text)
        // Read out when a warning appears: it may be the only sign something's off.
        .onChange(of: session.warning) { _, w in
            if let w { AccessibilityNotification.Announcement(w).post() }
        }
    }

    private var caption: (text: String, warning: Bool)? {
        if case .finishing = session.phase { return (String(localized: "Texten blir mer exakt när mötet är klart."), false) }
        if session.stopping {
            return (session.isPaused ? String(localized: "Mötet avslutas om några sekunder.")
                                     : String(localized: "Spelar in tills nedräkningen är klar."), false)
        }
        if session.isPaused { return (String(localized: "Pausat. Mikrofonen är av och det som sagts finns kvar."), false) }
        if let w = session.warning { return (w, true) }
        if !panelTipSeen, session.isRecording, !session.introducing {
            return (String(localized: "Stäng fönstret så fortsätter mötet i en liten panel."), false)
        }
        return nil
    }

    private var pill: some View {
        HStack(spacing: 14) {
            switch session.phase {
            case .finishing(let what):
                SettlingLine()
                Text(what).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .accessibilityLabel(what)
                FinishingClock(session: session)
            default:
                timer
                if session.stopping {
                    StopCountdown(session: session, compact: true, onDark: true)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                } else {
                    LiveWave().frame(width: 96, height: 22).accessibilityHidden(true)
                    stopButton
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, session.isRecording ? 7 : 18)
        .frame(height: 46)
        .background(Capsule().fill(Color(white: 0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .fixedSize()
    }

    /// One press ends it — with a few seconds to undo, the recording going on meanwhile.
    /// The red dot and how long it has been going.
    private var timer: some View {
        HStack(spacing: 10) {
            RecordingMark(session: session)
            if let start = session.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let time = session.clock(at: context.date)
                    Text(MeetingView.duration(time))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(session.isPaused ? 0.55 : 1))
                        .accessibilityLabel(session.isPaused ? "Pausat, \(MeetingView.spoken(time))" : "Spelar in, \(MeetingView.spoken(time))")
                }
            }
        }
        .fixedSize()
    }

    private var stopButton: some View {
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() }
        } label: {
            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Avsluta mötet. Du kan ångra i några sekunder.")
        .accessibilityLabel("Avsluta mötet")
    }
}

/// How long the final pass has been going, beside what it's doing — a long meeting
/// takes a while, and a clock that moves says it hasn't stopped.
struct FinishingClock: View {
    @ObservedObject var session: MeetingSession
    var color: Color = .white.opacity(0.55)

    var body: some View {
        if let since = session.finishingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(MeetingView.duration(context.date.timeIntervalSince(since)))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(color)
            }
            .accessibilityHidden(true)
        }
    }
}

/// The waveform — observing only the sound level, so nothing else redraws with it.
private struct LiveWave: View {
    @ObservedObject private var meter = LiveMeter.shared
    var body: some View {
        Waveform(levels: meter.levels, gap: 2.5, color: .white)
    }
}

/// A red dot that breathes while recording.
struct RecordingDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(DS.Colors.recording)
            .frame(width: 9, height: 9)
            .opacity(on || reduceMotion ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Reviewing a saved meeting: playback when listening, and a question field.
private struct ReviewBar: View {
    let record: MeetingRecord
    @ObservedObject var notes: MeetingNotes
    let width: CGFloat
    let asked: () -> Void
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var question = ""
    @FocusState private var focused: Bool

    private var busy: Bool { notes.answering.contains(record.id) }
    private var empty: Bool { question.trimmingCharacters(in: .whitespaces).isEmpty }
    private static let suggestions: [LocalizedStringResource] = ["Vad bestämdes?", "Vem gör vad?", "Vad var det viktigaste?"]

    var body: some View {
        VStack(spacing: 10) {
            if player.meeting == record.id {
                PlayerBar(player: player).transition(.move(edge: .bottom).combined(with: .opacity))
            } else if MeetingNotes.isAvailable, record.answers.isEmpty, empty, !busy {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.key) { s in
                        Button { ask(String(localized: s)) } label: {
                            Text(s)
                                .font(.system(size: 12.5, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Capsule().fill(DS.Colors.field))
                                .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
            if MeetingNotes.isAvailable { field }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: player.meeting)
        .padding(.bottom, 20)
        .pageColumn(width)
    }

    private var field: some View {
        HStack(spacing: 10) {
            TextField("Fråga om det här mötet", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { ask(question) }
                .accessibilityLabel("Fråga om det här mötet")
            if busy {
                SettlingLine(color: DS.Colors.ink).scaleEffect(0.7).frame(width: 40)
            } else {
                Button { ask(question) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(empty ? DS.Colors.faint : DS.Colors.onInk)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(empty ? DS.Colors.chip : DS.Colors.ink))
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .animation(.spring(duration: 0.25, bounce: 0.2), value: empty)
                .help("Skicka frågan (↩)")
                .accessibilityLabel("Skicka frågan")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.08), radius: 12, y: 4))
        .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.fieldStroke),
                                        lineWidth: focused ? 1.5 : 1))
    }

    private func ask(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        notes.ask(q, about: record.id)
        question = ""
        asked()
    }
}

/// Listening: play/pause, ±15 s, where it is (drag to move), speed, close.
private struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.plain).help("15 sekunder bakåt").accessibilityLabel("15 sekunder bakåt")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Colors.onInk)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pausa" : "Spela upp")
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.plain).help("15 sekunder framåt").accessibilityLabel("15 sekunder framåt")
            Text(MeetingView.duration(player.time)).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            GeometryReader { geo in
                let progress = player.duration > 0 ? player.time / player.duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.chip)
                    Capsule().fill(DS.Colors.ink).frame(width: max(4, geo.size.width * progress))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(to: max(0, min(1, v.location.x / geo.size.width)) * player.duration)
                })
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            Text(MeetingView.duration(player.duration)).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : player.rate == 1.5 ? "1,5×" : "2×")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(width: 36, height: 24)
                    .background(Capsule().fill(DS.Colors.chip))
            }
            .buttonStyle(.plain)
            .help("Uppspelningshastighet")
            Button { player.stop() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.muted)
            .help("Sluta lyssna")
            .accessibilityLabel("Sluta lyssna")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.08), radius: 12, y: 4))
        .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
    }
}

/// Writing the notes again: clearly at the top, with who writes them and for how
/// long — then, for a moment, that it's done.
private struct RewriteBanner: View {
    let writing: Bool
    /// Your own model in Ollama or LM Studio can be stopped.
    var cancel: (() -> Void)? = nil
    @State private var started = Date()

    private var writer: String { BetterNotes.shared.writerSentenceName }
    @ObservedObject private var servers = LocalServers.shared

    var body: some View {
        HStack(spacing: 14) {
            if writing {
                SettlingLine(color: DS.Colors.ink).frame(width: 56)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(DS.Colors.good)
                    .transition(.scale.combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(writing ? String(localized: "\(writer) skriver en ny sammanfattning…") : String(localized: "Den nya sammanfattningen är klar"))
                    .font(.system(size: 14, weight: .semibold))
                if writing {
                    Text(servers.progress.map { $0 + " " + String(localized: "Den gamla syns tills den nya är klar.") }
                         ?? String(localized: "Det tar några sekunder. Den gamla syns tills den nya är klar."))
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                }
            }
            Spacer()
            if writing {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(MeetingView.duration(context.date.timeIntervalSince(started)))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                }
                if let cancel { Button("Avbryt", action: cancel).buttonStyle(.soft) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .raised(cornerRadius: 16)
        .onAppear { started = Date() }
        .onChange(of: writing) { _, now in if now { started = Date() } }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: writing)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Screenshots (`--render-archive`): folded months and years, an opened old month.
/// Screenshots: the top of Möten — the night tile and the week — with your meetings.
struct MeetingsTopPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StartCard(session: .shared, voices: .shared, dictation: .shared)
            WeekRecap(meetings: MeetingStore.shared.meetings, all: MeetingStore.shared.meetings)
        }
    }
}

/// `--render-transcript`: a saved meeting's Text tab, with your notes and the marks
/// under the lines they were written in.
struct TranscriptPreview: View {
    let record: MeetingRecord
    @State private var focusTurn: Int?
    @State private var focusNote: Int?

    /// `focusNote`: the row lit as after "Visa i texten" from the summary.
    init(record: MeetingRecord, focusNote: Int? = nil) {
        self.record = record
        _focusNote = State(initialValue: focusNote)
        let turns = MeetingText.turnsAllAnew(record.words, pending: [])
        _focusTurn = State(initialValue: focusNote.flatMap { i in record.notes[i].at.map { NotePlacement.turn(at: $0, in: turns) } })
    }

    var body: some View {
        TranscriptView(record: record, turns: MeetingText.turnsAllAnew(record.words, pending: []), cast: record.cast,
                       session: nil, width: 760, edit: .saved(MeetingStore.shared, record.id),
                       focusTurn: $focusTurn, focusNote: $focusNote, flat: true)
    }

    /// A short meeting with three voices, notes written during it (two at one moment,
    /// one afterwards without a time) and marks with and without words.
    static func sample() -> MeetingRecord {
        let script: [(Int, String)] = [
            (0, "Då kör vi. Välkomna allihop. Idag ska vi gå igenom lanseringen och bestämma vad som händer härnäst."),
            (1, "Siffrorna ser riktigt bra ut. Vi hade fler nedladdningar första dagen än hela förra månaden."),
            (0, "Vad kul! Vet vi var de flesta användarna kommer ifrån?"),
            (2, "Mest från Sverige, men vi ser en del från Norge och Danmark också. Supporten får frågor på engelska redan nu."),
            (1, "Jag tycker att vi ska prioritera mötesfunktionen. Det är det folk frågar mest om, både kunder och partner."),
            (0, "Håller med. Kan du ta fram en plan till torsdag? Då hinner vi stämma av den innan styrelsen."),
            (2, "Jag kan ta budgeten samtidigt, så vi har siffrorna på plats när planen är klar."),
        ]
        var r = MeetingRecord(title: "Veckomöte om lanseringen", date: ArchivePreview.now.addingTimeInterval(-3600), language: .swedish)
        var t = 3.0
        var starts: [Double] = []
        for (speaker, line) in script {
            starts.append(t)
            for word in line.split(separator: " ") {
                r.words.append(MeetingWord(text: String(word), start: t, end: t + 0.3, speaker: speaker))
                t += 0.38
            }
            t += 1.2
        }
        r.names = ["0": "Anna", "1": "Erik", "2": "Sara"]
        r.duration = t + 2
        r.notes = [MeetingRecord.Note(text: "Kolla hur många som kom via nyhetsbrevet", at: starts[1] + 3),
                   MeetingRecord.Note(text: "Norge: prata med Klang om säljstöd", at: starts[3] + 2),
                   MeetingRecord.Note(text: "Danska översättningen är inte klar", at: starts[3] + 2),
                   MeetingRecord.Note(text: "Planen ska med i styrelseunderlaget", at: starts[5] + 1),
                   MeetingRecord.Note(text: "Skriven efteråt, utan tid", at: nil)]
        r.marks = [MeetingRecord.Mark(at: starts[4] + 1, kind: .decision, text: "Mötesfunktionen först"),
                   MeetingRecord.Mark(at: starts[5] + 2, kind: .task),
                   MeetingRecord.Mark(at: starts[6] + 1, kind: .important, text: "Budgeten och planen hänger ihop")]
        return r
    }
}

struct ArchivePreview: View {
    let records: [MeetingRecord]

    var body: some View {
        let sections = ArchiveSection.sections(records, now: ArchivePreview.now)
        // As the list lays them out (MeetingList.archive), on its 20 pt rhythm.
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections) { section in
                switch section.kind {
                case .recent:
                    VStack(alignment: .leading, spacing: 8) {
                        CapsLabel(section.title).padding(.top, 6)
                        VStack(spacing: 0) {
                            ForEach(section.meetings) { MeetingRow(record: $0, writing: false, timeOnly: section.day, now: ArchivePreview.now) {} }
                        }.padding(4).card()
                    }
                case .month:
                    VStack(alignment: .leading, spacing: 4) {
                        ArchiveHeader(section: section, open: section.openByDefault,
                                      people: section.openByDefault ? [] : section.people(among: records)) {}
                        if section.openByDefault {
                            VStack(spacing: 0) {
                                ForEach(section.meetings) { MeetingRow(record: $0, writing: false) {} }
                            }.padding(4).card()
                        }
                    }
                case .year:
                    VStack(alignment: .leading, spacing: 4) {
                        ArchiveHeader(section: section, open: true, people: []) {}
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(section.months.enumerated()), id: \.element.id) { i, month in
                                ArchiveHeader(section: month, open: i == 0, people: i == 0 ? [] : month.people(among: records), nested: true) {}
                                if i == 0 {
                                    VStack(spacing: 0) {
                                        ForEach(Array(month.meetings.enumerated()), id: \.element.id) { j, r in
                                            if j > 0 { CardDivider() }
                                            MeetingRow(record: r, writing: false, compact: true) {}
                                        }
                                    }.padding(4).card()
                                }
                            }
                        }.padding(.leading, 18)
                    }
                }
            }
        }
    }

    static let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!

    static func sample() -> [MeetingRecord] {
        let f = ISO8601DateFormatter()
        func m(_ date: String, _ title: String, _ names: [String], _ minutes: Double) -> MeetingRecord {
            var r = MeetingRecord(title: title, date: f.date(from: date + "T09:30:00Z")!, language: .swedish)
            r.names = Dictionary(uniqueKeysWithValues: names.enumerated().map { (String($0.offset), $0.element) })
            r.duration = minutes * 60
            return r
        }
        // Two files dropped this morning: one recorded in August, one that didn't say when.
        var board = m("2026-08-14", "Styrelsemöte", ["Jag", "Kim", "Anna"], 71)
        board.source = MeetingRecord.Source(file: "Styrelsemöte.mp4", video: true, importedAt: now.addingTimeInterval(-2 * 3600))
        var memo = m("2026-10-15", "Röstmemo om offerten", ["Jag"], 6)
        memo.date = now.addingTimeInterval(-5 * 3600)
        memo.source = MeetingRecord.Source(file: "Nytt memo 3.m4a", video: false, importedAt: memo.date, dateKnown: false)
        return [
            board, memo,
            m("2026-10-15", "Veckomöte", ["Jag", "Anna"], 34), m("2026-10-14", "Kund Nordljus, uppstart", ["Jag", "Eva"], 52),
            m("2026-10-02", "Planering Q4", ["Jag", "Anna", "Erik"], 41),
            m("2026-09-24", "Styrelsemöte", ["Jag", "Kim"], 88), m("2026-09-10", "Intervju", ["Jag", "Olle"], 25),
            m("2026-08-28", "Budget", ["Jag", "Anna", "Erik"], 47), m("2026-08-12", "Avstämning", ["Jag", "Anna"], 18),
            m("2026-08-05", "Kund Nordljus, status", ["Jag", "Eva"], 30),
            m("2026-06-19", "Sommarplanering", ["Jag", "Erik"], 22),
            m("2025-12-11", "Julmöte", ["Jag", "Anna", "Kim"], 64), m("2025-12-03", "Uppföljning", ["Jag", "Olle"], 21),
            m("2025-11-20", "Offertgenomgång", ["Jag", "Eva"], 37), m("2025-03-04", "Kickoff", ["Jag", "Anna"], 55),
        ]
    }
}
#endif
