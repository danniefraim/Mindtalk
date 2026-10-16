import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Tankar page
//
// One line to type in (or the button, or the thought key anywhere); then the pinned;
// then a section per day, today and yesterday open, older days folded with a count.
// Click a thought to choose it, click it again (or Return) to change the words.
// ↑↓ move between them, Space marks one done, ⌫ removes, ⌥⌘↑↓ moves it, ⌘Z undoes.
// Drag one by its handle: between two, it moves there (within its day); onto
// another, they become one. Several are chosen with ⌘- and ⇧-click.

struct ThoughtsPage: View {
    /// Screenshots: no drag and drop (ImageRenderer can't draw it).
    nonisolated(unsafe) static var still = false
    @ObservedObject var dictation: Dictation
    /// Screenshots: drawn without the scroll view.
    var scrolls = true
    @ObservedObject private var thoughts = Thoughts.shared
    @State private var query = ""
    @State private var typed = ""
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var editing: UUID?
    /// Days opened or closed by you (today and yesterday start open).
    @State private var opened: [Date: Bool] = [:]
    /// Days whose done thoughts are showing.
    @State private var showingDone: Set<Date> = []
    @State private var showingRemoved = false
    @State private var confirmPurge: [UUID]?
    @FocusState private var typing: Bool
    @FocusState private var searching: Bool
    @FocusState private var listFocused: Bool

    private var chord: String { Settings.thoughtShortcut?.chip.replacingOccurrences(of: " ", with: "") ?? "" }
    private var live: Int { thoughts.pinned.count + thoughts.days.reduce(0) { $0 + $1.items.count } }
    /// Keys go to the list, not to a field being typed in.
    private var listKeys: Bool { editing == nil && !typing && !searching }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header.staggered(0)
            captureBar.staggered(1)
            if showingRemoved {
                removedList.staggered(2)
            } else if live == 0 {
                empty.staggered(2)
                if !thoughts.removed.isEmpty { removedLink }
            } else {
                searchField.staggered(2)
                list.staggered(2)
                if !thoughts.removed.isEmpty { removedLink }
            }
        }
        .modifier(PageScroll(on: scrolls))
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in listKeys ? key(press) : .ignored }
        .background { shortcuts }
        .overlay(alignment: .bottom) { bottomBar }
        .animation(.spring(duration: 0.3, bounce: 0.12), value: thoughts.all)
        .animation(.spring(duration: 0.3, bounce: 0.12), value: thoughts.toast)
        .animation(.spring(duration: 0.3, bounce: 0.12), value: selection)
        .confirmationDialog(confirmPurge?.count == 1 ? "Ta bort tanken för gott?" : "Ta bort \(confirmPurge?.count ?? 0) tankar för gott?",
                            isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } })) {
            Button("Ta bort för gott", role: .destructive) {
                if let ids = confirmPurge { withAnimation(.snappy) { thoughts.purge(ids) } }
                confirmPurge = nil
            }
            Button("Avbryt", role: .cancel) { confirmPurge = nil }
        } message: {
            Text("De går inte att få tillbaka.")
        }
    }

    // MARK: Top

    private var header: some View {
        HStack(alignment: .top) {
            PageHeader(title: "Tankar",
                       subtitle: live < 5 ? "Det du kommer på mitt i något annat. Håll in genvägen och säg det – det hamnar här, inte i appen du står i." : nil)
            Spacer(minLength: 16)
            Menu {
                Button("Exportera alla som Markdown…", action: export).disabled(live == 0)
                Button(showingRemoved ? "Tillbaka till tankarna" : "Nyligen raderade (\(thoughts.removed.count))") {
                    withAnimation(.snappy) { showingRemoved.toggle(); selection = [] }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(DS.Colors.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 14)
            .help("Mer")
            .accessibilityLabel("Mer")
        }
    }

    /// Type one, or say one.
    private var captureBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
            TextField(chord.isEmpty ? "Skriv en tanke och tryck på retur" : "Skriv en tanke – eller håll in \(chord) och säg den", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($typing)
                .onSubmit {
                    withAnimation(.snappy) { thoughts.add(typed) }
                    typed = ""
                }
            Button {
                dictation.startThought()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                    Text("Säg en tanke")
                }
            }
            .buttonStyle(.ink)
            .disabled(dictation.phase == .recording || dictation.phase == .transcribing || !dictation.engine.isInstalled)
            .help("Börja lyssna – tryck på ✓ i bubblan när du är klar")
        }
        .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
        .raised(cornerRadius: 16)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                .accessibilityHidden(true)
            TextField("Sök i tankarna", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searching)
                .onExitCommand { query = ""; searching = false }
            if !query.isEmpty {
                let n = matches
                Text(n == 1 ? "1 träff" : "\(n) träffar").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Colors.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rensa sökningen")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
    }

    private var empty: some View {
        VStack(spacing: 14) {
            if let keys = Settings.thoughtShortcut {
                // The key you hold — big, and it sinks while you do.
                Keycap(text: keys.chip, pressed: dictation.forThought && dictation.phase == .recording, isCombination: false)
                    .scaleEffect(0.75)
                    .frame(height: 80)
                    .accessibilityHidden(true)
                Text("Håll in och säg det du kommer på")
                    .font(.system(size: 20, weight: .regular, design: .serif))
            } else {
                Image(systemName: "lightbulb").font(.system(size: 28, weight: .light)).foregroundStyle(DS.Colors.muted)
                    .accessibilityHidden(true)
            }
            Text("Inga tankar än").font(.system(size: 14, weight: .semibold))
            Text(chord.isEmpty ? "Prova: tryck på Säg en tanke och säg ”Ring tillbaka om offerten”."
                               : "Prova: håll in \(chord) var du än är och säg ”Ring tillbaka om offerten”.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: The list

    private func matching(_ items: [Thought]) -> [Thought] {
        query.isEmpty ? items : items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var matches: Int {
        matching(thoughts.pinned).count + thoughts.days.reduce(0) { $0 + matching($1.items).count }
    }

    private func isOpen(_ day: Date) -> Bool {
        if !query.isEmpty { return true }
        let calendar = Calendar.current
        return opened[day] ?? (calendar.isDateInToday(day) || calendar.isDateInYesterday(day))
    }

    private func doneShowing(_ day: Date) -> Bool { !query.isEmpty || showingDone.contains(day) }

    /// Top to bottom, as they're drawn — for ↑↓ and ⇧-click.
    private var visibleOrder: [UUID] {
        var ids = matching(thoughts.pinned).map(\.id)
        for day in thoughts.days where isOpen(day.day) {
            let items = matching(day.items)
            ids += items.filter { !$0.done }.map(\.id)
            if doneShowing(day.day) { ids += items.filter(\.done).map(\.id) }
        }
        return ids
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            let pinned = matching(thoughts.pinned)
            if !pinned.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "pin.fill").font(.system(size: 10.5)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                        Text("Fäst").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .modifier(PinDropping(on: !Self.still) { ids in withAnimation(.snappy) { thoughts.setPinned(ids, true) } })
                    card(pinned, section: .pinned)
                }
            }
            if !query.isEmpty, matches == 0 {
                Text("Inga tankar innehåller det.").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            }
            ForEach(thoughts.days, id: \.day) { day in
                let items = matching(day.items)
                if !items.isEmpty { daySection(day.day, items) }
            }
        }
    }

    private func daySection(_ day: Date, _ items: [Thought]) -> some View {
        let open = items.filter { !$0.done }
        let done = items.filter(\.done)
        let expanded = isOpen(day)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) { opened[day] = !expanded }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(DS.Colors.muted)
                        .accessibilityHidden(true)
                    Text(verbatim: Self.title(day)).font(.system(size: 15, weight: .semibold))
                    Text(verbatim: items.count == 1 ? String(localized: "1 tanke") : String(localized: "\(items.count) tankar"))
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded ? Text("Öppen") : Text("Stängd"))
            if expanded {
                VStack(spacing: 0) {
                    if !open.isEmpty { rows(open, section: .day(day)) }
                    if !done.isEmpty {
                        if !open.isEmpty { CardDivider() }
                        Button {
                            withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                                if showingDone.contains(day) { showingDone.remove(day) } else { showingDone.insert(day) }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold)).accessibilityHidden(true)
                                Text(verbatim: done.count == 1 ? String(localized: "1 klar") : String(localized: "\(done.count) klara"))
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(doneShowing(day) ? 90 : 0)).accessibilityHidden(true)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if doneShowing(day) { rows(done, section: .day(day)) }
                    }
                }
                .padding(4)
                .card()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func card(_ items: [Thought], section: ThoughtSection) -> some View {
        VStack(spacing: 0) { rows(items, section: section) }
            .padding(4)
            .card()
    }

    @ViewBuilder private func rows(_ items: [Thought], section: ThoughtSection) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { i, thought in
            if i > 0 { CardDivider() }
            ThoughtRow(thought: thought,
                       selected: selection.contains(thought.id),
                       editing: editing == thought.id,
                       fresh: thoughts.fresh == thought.id,
                       dragged: { dragged(thought.id) },
                       click: { click(thought.id) },
                       edit: { startEditing(thought.id) },
                       endEdit: { text in endEditing(thought.id, text) },
                       drop: { zone, ids in drop(zone, ids, on: thought, at: i, in: section, of: items) })
        }
    }

    // MARK: Choosing

    private func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let a = visibleOrder.firstIndex(of: anchor), let b = visibleOrder.firstIndex(of: id) {
            selection = Set(visibleOrder[min(a, b)...max(a, b)])
        } else if selection == [id] {
            // Chosen already: a second click changes the words, like a name in Finder.
            startEditing(id)
        } else {
            selection = [id]
            anchor = id
        }
        typing = false
        searching = false
        listFocused = true
    }

    private func startEditing(_ id: UUID) {
        guard let t = thoughts.all.first(where: { $0.id == id }), t.writing == nil else { return }
        selection = [id]
        editing = id
    }

    private func endEditing(_ id: UUID, _ text: String?) {
        if let text { thoughts.edit(id, text: text) }
        if editing == id { editing = nil }
        listFocused = true
    }

    private var chosen: [UUID] { visibleOrder.filter { selection.contains($0) } }

    // MARK: Keys

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let order = visibleOrder
        switch press.key {
        case .upArrow, .downArrow:
            let up = press.key == .upArrow
            if press.modifiers.contains(.command), press.modifiers.contains(.option) {
                guard selection.count == 1, let id = selection.first else { return .handled }
                withAnimation(.snappy) { thoughts.nudge(id, by: up ? -1 : 1) }
                return .handled
            }
            guard !order.isEmpty else { return .ignored }
            let current = (up ? chosen.first : chosen.last).flatMap { order.firstIndex(of: $0) }
            let next = current.map { max(0, min(order.count - 1, $0 + (up ? -1 : 1))) } ?? (up ? order.count - 1 : 0)
            if press.modifiers.contains(.shift) { selection.insert(order[next]) } else { selection = [order[next]] }
            anchor = order[next]
            return .handled
        case .space:
            guard !selection.isEmpty else { return .ignored }
            let ids = chosen
            let allDone = thoughts.all.filter { ids.contains($0.id) }.allSatisfy(\.done)
            withAnimation(.snappy) { thoughts.setDone(ids, !allDone) }
            return .handled
        case .delete, .deleteForward:
            guard !selection.isEmpty else { return .ignored }
            removeChosen()
            return .handled
        case .return:
            guard selection.count == 1, let id = selection.first else { return .ignored }
            startEditing(id)
            return .handled
        case .escape:
            guard !selection.isEmpty else { return .ignored }
            selection = []
            return .handled
        default:
            if press.characters == "p", press.modifiers.isEmpty, !selection.isEmpty {
                let ids = chosen
                let allPinned = thoughts.all.filter { ids.contains($0.id) }.allSatisfy(\.pinned)
                withAnimation(.snappy) { thoughts.setPinned(ids, !allPinned) }
                return .handled
            }
            return .ignored
        }
    }

    /// ⌘Z, ⇧⌘Z, ⌘C and ⌘A for the list — only while no field is being typed in, so
    /// a field keeps its own.
    @ViewBuilder private var shortcuts: some View {
        if listKeys {
            ZStack {
                Button("") { withAnimation(.snappy) { thoughts.undo() } }.keyboardShortcut("z", modifiers: .command)
                Button("") { withAnimation(.snappy) { thoughts.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { copyChosen() }.keyboardShortcut("c", modifiers: .command)
                Button("") { selection = Set(visibleOrder) }.keyboardShortcut("a", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Actions

    private func removeChosen() {
        let ids = chosen
        // The next one gets chosen, so ⌫ ⌫ ⌫ goes down the list.
        let order = visibleOrder
        let after = order.firstIndex(where: { ids.contains($0) }).flatMap { first in
            order[first...].first { !ids.contains($0) }
        }
        withAnimation(.snappy) { thoughts.remove(ids) }
        selection = after.map { [$0] } ?? []
    }

    private func copyChosen() {
        let ids = chosen
        guard !ids.isEmpty else { return }
        let text = ids.compactMap { id in thoughts.all.first { $0.id == id }?.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func mergeChosen() {
        let ids = chosen
        guard let first = ids.first else { return }
        withAnimation(.snappy) { thoughts.merge(ids, into: first) }
        selection = [first]
    }

    /// What a drag from this row carries: the chosen ones if it's among them.
    private func dragged(_ id: UUID) -> (ids: [UUID], text: String) {
        let ids = selection.contains(id) ? chosen : [id]
        let text = ids.compactMap { i in thoughts.all.first { $0.id == i }?.text }.joined(separator: "\n")
        return (ids, text)
    }

    private func drop(_ zone: DropZone, _ ids: [UUID], on target: Thought, at index: Int, in section: ThoughtSection, of items: [Thought]) {
        withAnimation(.snappy) {
            switch zone {
            case .into:
                guard !ids.contains(target.id) else { return }
                thoughts.merge([target.id] + ids, into: target.id)
                selection = [target.id]
            case .before, .after:
                // Items here is what's drawn (done ones after the open); the place
                // is among the section's thoughts.
                let all: [Thought] = {
                    switch section {
                    case .pinned: return thoughts.pinned
                    case .day(let day): return thoughts.days.first { $0.day == day }?.items ?? []
                    }
                }()
                guard let at = all.firstIndex(where: { $0.id == target.id }) else { return }
                if case .day = section {
                    // A pinned thought dragged into its day: unpinned there.
                    let pinnedHere = ids.filter { id in thoughts.pinned.contains { $0.id == id } }
                    if !pinnedHere.isEmpty { thoughts.setPinned(pinnedHere, false) }
                }
                thoughts.move(ids, to: zone == .before ? at : at + 1, in: section)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Tankar") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try thoughts.markdown().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Nyligen raderade

    private var removedLink: some View {
        Button {
            withAnimation(.snappy) { showingRemoved = true; selection = [] }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash").font(.system(size: 11)).accessibilityHidden(true)
                Text(verbatim: String(localized: "Nyligen raderade") + " · \(thoughts.removed.count)")
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var removedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    withAnimation(.snappy) { showingRemoved = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                        Text("Tankar")
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if !thoughts.removed.isEmpty {
                    Button("Töm…") { confirmPurge = thoughts.removed.map(\.id) }.buttonStyle(.soft)
                }
            }
            Text("Nyligen raderade").font(.system(size: 20, weight: .regular, design: .serif))
            Text("Tankar du tar bort ligger här i \(Thoughts.keepRemovedDays) dagar.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            if thoughts.removed.isEmpty {
                Text("Inget här.").font(.system(size: 13)).foregroundStyle(DS.Colors.muted).padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(thoughts.removed.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { CardDivider() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.text.isEmpty ? String(localized: "(utan text)") : t.text).font(.system(size: 14))
                                    .foregroundStyle(DS.Colors.muted).lineLimit(3)
                                Text(verbatim: MeetingRecord.when(t.date)).font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Återställ") { withAnimation(.snappy) { thoughts.restore([t.id]) } }.buttonStyle(.soft)
                            Button {
                                confirmPurge = [t.id]
                            } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .help("Ta bort för gott")
                            .accessibilityLabel("Ta bort för gott")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                }
                .padding(4)
                .card()
            }
        }
    }

    // MARK: Bottom: several chosen, or "Ångra"

    @ViewBuilder private var bottomBar: some View {
        if selection.count > 1, !showingRemoved {
            HStack(spacing: 4) {
                Text(verbatim: String(localized: "\(selection.count) valda")).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                barButton("Klar", "checkmark") { withAnimation(.snappy) { thoughts.setDone(chosen, true) }; selection = [] }
                barButton("Fäst", "pin") { withAnimation(.snappy) { thoughts.setPinned(chosen, true) } }
                barButton("Kopiera", "doc.on.doc") { copyChosen() }
                barButton("Slå ihop", "arrow.triangle.merge") { mergeChosen() }
                barButton("Ta bort", "trash") { removeChosen() }
                Button { selection = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Avmarkera")
                .accessibilityLabel("Avmarkera")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(Capsule().fill(DS.Colors.night))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.bottom, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let toast = thoughts.toast {
            HStack(spacing: 12) {
                Text(verbatim: toast).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Button("Ångra") { withAnimation(.snappy) { thoughts.undo() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Capsule().fill(DS.Colors.night))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.bottom, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(toast)
        }
    }

    private func barButton(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Capsule().fill(.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// "I dag", "I går", then the day.
    static func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "I dag") }
        if calendar.isDateInYesterday(day) { return String(localized: "I går") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        let style = sameYear ? Date.FormatStyle().weekday(.wide).day().month(.wide) : Date.FormatStyle().weekday(.wide).day().month(.wide).year()
        let text = day.formatted(style.locale(AppLanguage.locale))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - A thought

enum DropZone { case before, into, after }

private struct ThoughtRow: View {
    let thought: Thought
    let selected: Bool
    let editing: Bool
    let fresh: Bool
    let dragged: () -> (ids: [UUID], text: String)
    let click: () -> Void
    let edit: () -> Void
    /// nil: Esc — leave the words as they were.
    let endEdit: (String?) -> Void
    let drop: (DropZone, [UUID]) -> Void

    @State private var hovering = false
    @State private var draft = ""
    @State private var cancelled = false
    @State private var height: CGFloat = 44
    @State private var zone: DropZone?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The handle: drag here.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Colors.muted)
                .frame(width: 12)
                .opacity((hovering || selected) && thought.writing == nil && !editing ? 1 : 0)
                .accessibilityHidden(true)
            content
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(zone == .into ? DS.Colors.ink : (selected ? DS.Colors.ink.opacity(0.25) : .clear), lineWidth: zone == .into ? 1.5 : 1))
        .overlay(alignment: .top) { if zone == .before { insertLine.offset(y: -1) } }
        .overlay(alignment: .bottom) { if zone == .after { insertLine.offset(y: 1) } }
        .contentShape(Rectangle())
        .onTapGesture { if !editing { click() } }
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .modifier(Dragging(on: !ThoughtsPage.still) {
            let d = dragged()
            return ThoughtDragging.provider(ids: d.ids, text: d.text)
        } delegate: { RowDrop(id: thought.id, height: height, zone: $zone, act: drop) })
        .contextMenu { menuItems }
        .animation(.easeOut(duration: 0.12), value: zone)
        .animation(.easeOut(duration: 0.5), value: fresh)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(Text(verbatim: [thought.done ? String(localized: "klar") : nil, thought.pinned ? String(localized: "fäst") : nil,
                                            time].compactMap { $0 }.joined(separator: ", ")))
    }

    private var fill: Color {
        if fresh { return DS.Colors.chip }
        if selected { return DS.Colors.chip.opacity(0.85) }
        return DS.Colors.chip.opacity(hovering ? 0.45 : 0)
    }

    private var insertLine: some View {
        Capsule().fill(DS.Colors.ink).frame(height: 2).padding(.horizontal, 6)
    }

    private var time: String {
        thought.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
    }

    @ViewBuilder private var content: some View {
        switch thought.writing {
        case .writing:
            HStack(spacing: 10) {
                SettlingLine(color: DS.Colors.ink).frame(width: 36)
                Text("Skriver ned tanken…").font(.system(size: 14)).foregroundStyle(DS.Colors.muted)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(DS.Colors.warning)
                        .accessibilityHidden(true)
                    Text("Tanken kunde inte skrivas ned.").font(.system(size: 14))
                }
                HStack(spacing: 8) {
                    Button("Försök igen") { Task { await Thoughts.shared.retry(thought.id) } }.buttonStyle(.soft)
                    Button("Ta bort") { withAnimation(.snappy) { Thoughts.shared.discard(thought.id) } }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                }
            }
        case nil:
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { endEdit(draft) }
                    .onExitCommand { cancelled = true; endEdit(nil) }
                    .onChange(of: focused) { _, now in if !now, !cancelled { endEdit(draft) } }
                    .onAppear {
                        draft = thought.text
                        cancelled = false
                        DispatchQueue.main.async { focused = true }
                    }
            } else {
                Text(thought.text)
                    .font(.system(size: 14))
                    .foregroundStyle(thought.done ? DS.Colors.muted : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if thought.writing == nil, !editing, hovering || selected {
            HStack(spacing: 2) {
                icon(thought.pinned ? "pin.slash" : "pin", thought.pinned ? "Lossa" : "Fäst") {
                    withAnimation(.snappy) { Thoughts.shared.setPinned([thought.id], !thought.pinned) }
                }
                icon(thought.done ? "arrow.uturn.backward" : "checkmark", thought.done ? "Inte klar" : "Klar") {
                    withAnimation(.snappy) { Thoughts.shared.setDone([thought.id], !thought.done) }
                }
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mer")
                .accessibilityLabel("Mer")
            }
            .foregroundStyle(DS.Colors.muted)
        } else {
            HStack(spacing: 6) {
                if thought.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                }
                Text(verbatim: time).font(.system(size: 12)).foregroundStyle(DS.Colors.muted).monospacedDigit()
            }
        }
    }

    private func icon(_ name: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    @ViewBuilder private var menuItems: some View {
        if thought.writing == nil {
            Button("Ändra") { edit() }
            Button("Kopiera") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(thought.text, forType: .string)
            }
            ShareLink(item: thought.text) { Text("Dela…") }
            Divider()
            Button(thought.pinned ? "Lossa" : "Fäst") { Thoughts.shared.setPinned([thought.id], !thought.pinned) }
            Button(thought.done ? "Inte klar" : "Klar") { Thoughts.shared.setDone([thought.id], !thought.done) }
            Divider()
            Button("Ta bort", role: .destructive) { withAnimation(.snappy) { Thoughts.shared.remove([thought.id]) } }
        }
    }
}

/// Where a dragged thought lands on another: the top quarter puts it above, the
/// bottom quarter below, the middle makes them one.
private struct RowDrop: DropDelegate {
    let id: UUID
    let height: CGFloat
    @Binding var zone: DropZone?
    let act: (DropZone, [UUID]) -> Void

    private func zone(at y: CGFloat) -> DropZone {
        if y < height * 0.28 { return .before }
        if y > height * 0.72 { return .after }
        return .into
    }

    func validateDrop(info: DropInfo) -> Bool {
        let ids = MainActor.assumeIsolated { ThoughtDragging.ids }
        return !ids.isEmpty && ids != [id]
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let ids = MainActor.assumeIsolated { ThoughtDragging.ids }
        let z = zone(at: info.location.y)
        zone = (z == .into && ids.contains(id)) ? nil : z
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let ids = MainActor.assumeIsolated { ThoughtDragging.ids }
        let z = zone ?? zone(at: info.location.y)
        zone = nil
        guard !ids.isEmpty else { return false }
        act(z, ids)
        MainActor.assumeIsolated { ThoughtDragging.ids = [] }
        return true
    }
}

/// Dropped on "Fäst": pinned.
private struct PinDrop: DropDelegate {
    let act: ([UUID]) -> Void
    func validateDrop(info: DropInfo) -> Bool { !MainActor.assumeIsolated { ThoughtDragging.ids }.isEmpty }
    func performDrop(info: DropInfo) -> Bool {
        let ids = MainActor.assumeIsolated { ThoughtDragging.ids }
        act(ids)
        MainActor.assumeIsolated { ThoughtDragging.ids = [] }
        return true
    }
}

/// Drag from a row and drop on it — left out for screenshots.
private struct Dragging<D: DropDelegate>: ViewModifier {
    let on: Bool
    let provider: () -> NSItemProvider
    let delegate: () -> D
    func body(content: Content) -> some View {
        if on { content.onDrag(provider).onDrop(of: [.mindtalkThought], delegate: delegate()) } else { content }
    }
}

private struct PinDropping: ViewModifier {
    let on: Bool
    let act: ([UUID]) -> Void
    func body(content: Content) -> some View {
        if on { content.onDrop(of: [.mindtalkThought], delegate: PinDrop(act: act)) } else { content }
    }
}

struct PageScroll: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.pageLayout() } else { content.padding(28) }
    }
}
