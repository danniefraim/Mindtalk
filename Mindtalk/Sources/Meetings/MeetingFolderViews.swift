import SwiftUI

// MARK: - The folder row
//
// Under the search field, and pinned there as the list scrolls (so a meeting far
// down can still be dragged onto a folder): "Alla", your folders with how many
// meetings each holds, and "Ny mapp". Beside the search field it's one row that
// never scrolls: the folders with the most meetings, as many as fit, and the rest
// under "Fler" (the folder chosen is always in the row). Selected, a folder is
// drawn like the page's other pickers — a raised pill. A meeting (or several)
// dragged onto a folder goes into it; onto "Alla", out of its folder; held over
// Fler, it opens. Right-click a folder to rename it or take it away.

struct FolderBar: View {
    @ObservedObject var folders: MeetingFolders
    @ObservedObject var store: MeetingStore
    /// The meeting being recorded: in the store, not in the list — not counted.
    var live: UUID?
    /// Beside the search field: in one row, the folders that don't fit under Fler.
    var oneRow = false
    /// The room for that row (0 until it's known: then all of them).
    var width: CGFloat = 0
    @State private var removing: MeetingFolder?

    var body: some View {
        let counted = store.meetings.filter { $0.id != live }
        var counts: [UUID: Int] = [:]
        for m in counted { if let f = m.folder { counts[f, default: 0] += 1 } }
        return Group {
            if oneRow {
                let row = fitted(counted: counted.count, counts: counts)
                HStack(spacing: 8) {
                    allChip(count: counted.count)
                    ForEach(row.shown) { chip($0, count: counts[$0.id] ?? 0) }
                    if row.more.isEmpty {
                        newFolder
                    } else {
                        MoreFolders(folders: folders, more: row.more, counts: counts) { removing = $0 }
                    }
                }
            } else {
                FlowLayout(spacing: 8) { chips(counted: counted, counts: counts) }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: folders.folders)
        .confirmationDialog(Text("Ta bort mappen ”\(removing?.name ?? "")”?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Ta bort mappen", role: .destructive) {
                if let id = removing?.id { withAnimation(.snappy) { folders.remove(id) } }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Mötena tas inte bort. De finns kvar under Alla.")
        }
    }

    @ViewBuilder private func chips(counted: [MeetingRecord], counts: [UUID: Int]) -> some View {
        allChip(count: counted.count)
        ForEach(folders.sorted) { chip($0, count: counts[$0.id] ?? 0) }
        newFolder
    }

    /// "Alla" alone would be a choice of one: it comes with the first folder.
    @ViewBuilder private func allChip(count: Int) -> some View {
        if !folders.folders.isEmpty {
            FolderChip(title: String(localized: "Alla"), count: count,
                       selected: folders.selected == nil, symbol: nil,
                       help: "Alla möten: släpp ett möte här för att ta det ur sin mapp") {
                select(nil)
            } drop: { ids in folders.move(ids, to: nil) }
        }
    }

    private func chip(_ folder: MeetingFolder, count: Int) -> some View {
        FolderChip(title: folder.name, count: count,
                   selected: folders.selected == folder.id, symbol: "folder",
                   help: "\(folder.name): släpp möten här för att lägga dem i mappen") {
            select(folder.id)
        } drop: { ids in folders.move(ids, to: folder.id) }
        .contextMenu {
            Button("Byt namn…") { FolderNaming.shared.request = .rename(folder) }
            Button("Ta bort mappen…", role: .destructive) { removing = folder }
        }
    }

    private var newFolder: some View {
        Button { FolderNaming.shared.request = .create(moving: []) } label: {
            Label("Ny mapp", systemImage: "plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.muted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .overlay(Capsule().strokeBorder(DS.Colors.muted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Skapa en mapp att sortera mötena i")
    }

    /// The folders in the row and those under Fler: the most meetings first (A to Ö
    /// among equals), as many as fit; the one chosen always in the row, last if it
    /// had to be brought in.
    private func fitted(counted: Int, counts: [UUID: Int]) -> (shown: [MeetingFolder], more: [MeetingFolder]) {
        let ranked = folders.sorted.enumerated()
            .sorted { a, b in
                let (x, y) = (counts[a.element.id] ?? 0, counts[b.element.id] ?? 0)
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
        guard width > 0, !ranked.isEmpty else { return (ranked, []) }
        let gap: CGFloat = 8
        let all = Self.chipWidth(String(localized: "Alla"), count: counted, symbol: false)
        func w(_ f: MeetingFolder) -> CGFloat { gap + Self.chipWidth(f.name, count: counts[f.id] ?? 0, symbol: true) }
        if ranked.reduce(all, { $0 + w($1) }) + gap + Self.newFolderWidth <= width { return (ranked, []) }
        var used = all + gap + Self.moreWidth
        var shown: [MeetingFolder] = []
        for folder in ranked {
            guard used + w(folder) <= width else { break }
            shown.append(folder)
            used += w(folder)
        }
        if let chosen = ranked.first(where: { $0.id == folders.selected }), !shown.contains(chosen) {
            while let last = shown.last, used + w(chosen) > width {
                shown.removeLast()
                used -= w(last)
            }
            shown.append(chosen)
        }
        return (shown, ranked.filter { !shown.contains($0) })
    }

    /// A chip's width as FolderChip draws it (the name in semibold, as when chosen).
    private static func chipWidth(_ title: String, count: Int, symbol: Bool) -> CGFloat {
        var width = 24 + min(170, measure(title, size: 12.5, weight: .semibold))
        if symbol { width += 15 + 6 }
        if count > 0 { width += 6 + measure("\(count)", size: 11.5, weight: .medium) }
        return ceil(width) + 2
    }
    private static var newFolderWidth: CGFloat { ceil(24 + 14 + 6 + measure(String(localized: "Ny mapp"), size: 12.5, weight: .medium)) + 2 }
    private static var moreWidth: CGFloat { ceil(24 + 10 + 5 + measure(String(localized: "Fler"), size: 12.5, weight: .medium)) + 2 }
    private static func measure(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    private func select(_ id: UUID?) {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { folders.selected = id }
    }
}

/// "Fler ▾" at the end of the row: the folders that didn't fit, in a list. A
/// meeting held over it a moment opens the list, to be dropped on one of them.
private struct MoreFolders: View {
    @ObservedObject var folders: MeetingFolders
    let more: [MeetingFolder]
    let counts: [UUID: Int]
    let remove: (MeetingFolder) -> Void
    @State private var open = false
    @State private var targeted = false
    @State private var opening: Task<Void, Never>?

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text("Fler").font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(DS.Colors.muted)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(DS.Colors.chip.opacity(0.7)))
            .overlay(Capsule().strokeBorder(DS.Colors.ink, lineWidth: targeted ? 2 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(more.count == 1 ? String(localized: "1 mapp till") : String(localized: "\(more.count) mappar till"))
        .accessibilityLabel(more.count == 1 ? String(localized: "Fler mappar, 1 till") : String(localized: "Fler mappar, \(more.count) till"))
        .dropDestination(for: MeetingDrag.self) { _, _ in false } isTargeted: { over in
            targeted = over
            opening?.cancel()
            guard over else { return }
            opening = Task {
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { open = true }
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: targeted)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(more) { folder in
                            MoreFolderRow(name: folder.name, count: counts[folder.id] ?? 0) {
                                open = false
                                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { folders.selected = folder.id }
                            } drop: { ids in
                                open = false
                                withAnimation(.snappy) { folders.move(ids, to: folder.id) }
                            }
                            .contextMenu {
                                Button("Byt namn…") { open = false; FolderNaming.shared.request = .rename(folder) }
                                Button("Ta bort mappen…", role: .destructive) { open = false; remove(folder) }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(more.count) * 32 + 12, 360))
                Divider()
                Button {
                    open = false
                    FolderNaming.shared.request = .create(moving: [])
                } label: {
                    Label("Ny mapp…", systemImage: "plus")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            .frame(width: 250)
        }
    }
}

/// A folder in Fler's list: chosen with a click, a drop target for meetings.
private struct MoreFolderRow: View {
    let name: String
    let count: Int
    let action: () -> Void
    let drop: ([UUID]) -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: targeted ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if count > 0 {
                    Text(verbatim: "\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.chip.opacity(hovering || targeted ? 0.9 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Colors.ink, lineWidth: targeted ? 1.5 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .dropDestination(for: MeetingDrag.self) { items, _ in
            let ids = items.flatMap(\.ids)
            guard !ids.isEmpty else { return false }
            drop(ids)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityLabel(count == 1 ? String(localized: "\(name), 1 möte") : String(localized: "\(name), \(count) möten"))
    }
}

/// One folder in the row: its name and how many meetings — a drop target for them.
private struct FolderChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let symbol: String?
    let help: LocalizedStringKey
    let action: () -> Void
    let drop: ([UUID]) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: targeted ? "\(symbol).fill" : symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if count > 0 {
                    // A new number is a new text, drawn afresh: with a numeric transition the
                    // old count was seen to stay in this pinned row after a meeting was
                    // deleted, while the count over the page had moved on.
                    Text(verbatim: "\(count)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                        .id(count)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Colors.muted))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                if selected {
                    Capsule().fill(DS.Colors.pill)
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                        .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke.opacity(0.6), lineWidth: 0.5))
                } else {
                    Capsule().fill(DS.Colors.chip.opacity(0.7))
                }
            }
            .overlay(Capsule().strokeBorder(DS.Colors.ink, lineWidth: targeted ? 2 : 0))
            .scaleEffect(targeted ? 1.06 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: targeted)
        .animation(.snappy, value: count)
        .dropDestination(for: MeetingDrag.self) { items, _ in
            let ids = items.flatMap(\.ids)
            guard !ids.isEmpty else { return false }
            withAnimation(.snappy) { drop(ids) }
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityLabel(count == 1 ? String(localized: "\(title), 1 möte") : String(localized: "\(title), \(count) möten"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Naming a folder

/// "Ny mapp…" and "Byt namn…", from wherever they're chosen (a chip, a menu, a
/// meeting's page) — asked in one place, MeetingsPage's `FolderNamingHost`.
@MainActor
final class FolderNaming: ObservableObject {
    static let shared = FolderNaming()
    enum Request: Equatable {
        /// A new folder — and the meetings to put in it once it's made.
        case create(moving: [UUID])
        case rename(MeetingFolder)
    }
    @Published var request: Request?
}

struct FolderNamingHost: ViewModifier {
    @ObservedObject private var naming = FolderNaming.shared
    @ObservedObject private var folders = MeetingFolders.shared
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { naming.request != nil }, set: { if !$0 { naming.request = nil } })) {
                TextField("Mappens namn", text: $name)
                Button(isRename ? "Byt namn" : "Skapa") { commit() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Avbryt", role: .cancel) { naming.request = nil }
            } message: {
                if folders.isTaken(name, except: renamingID) {
                    Text("Det finns redan en mapp som heter så. Den nya får en siffra efter namnet.")
                }
            }
            .onChange(of: naming.request) { _, request in
                if case .rename(let folder) = request { name = folder.name } else { name = "" }
            }
    }

    private var isRename: Bool { if case .rename = naming.request { return true } else { return false } }
    private var renamingID: UUID? { if case .rename(let f) = naming.request { return f.id } else { return nil } }
    private var title: String { isRename ? String(localized: "Byt namn på mappen") : String(localized: "Ny mapp") }

    private func commit() {
        guard let request = naming.request else { return }
        naming.request = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch request {
        case .create(let moving):
            guard let folder = folders.create(trimmed) else { return }
            if moving.isEmpty {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { folders.selected = folder.id }
            } else {
                withAnimation(.snappy) { folders.move(moving, to: folder.id) }
            }
        case .rename(let folder):
            folders.rename(folder.id, to: trimmed)
        }
    }
}

extension View {
    func folderNaming() -> some View { modifier(FolderNamingHost()) }
}

// MARK: - Moving

/// "Flytta till ›": "Ingen mapp", the folders, "Ny mapp…" — for the meetings given
/// (one, or those selected in the list).
struct MoveToFolderMenu: View {
    let ids: [UUID]
    /// Where they are now (one meeting): ticked.
    var current: UUID? = nil
    var title: LocalizedStringKey = "Flytta till"
    @ObservedObject private var folders = MeetingFolders.shared

    var body: some View {
        Menu(title) { MoveToFolderItems(ids: ids, current: current) }
    }
}

/// The items of that menu, for menus that are themselves the folder choice.
struct MoveToFolderItems: View {
    let ids: [UUID]
    var current: UUID? = nil
    @ObservedObject private var folders = MeetingFolders.shared

    var body: some View {
        let here = folders.folder(current)?.id
        item(String(localized: "Ingen mapp"), checked: ids.count == 1 && here == nil) { folders.move(ids, to: nil) }
        if !folders.folders.isEmpty { Divider() }
        ForEach(folders.sorted) { folder in
            item(folder.name, checked: ids.count == 1 && here == folder.id) { folders.move(ids, to: folder.id) }
        }
        Divider()
        Button("Ny mapp…") { FolderNaming.shared.request = .create(moving: ids) }
    }

    @ViewBuilder private func item(_ name: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            if checked { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}

/// On a meeting's page, after its date and length: the folder it's in, quiet like
/// the rest of that line — a menu to move it. Without a folder, "Lägg i mapp" —
/// unless the page is just suggesting one.
struct FolderTag: View {
    let record: MeetingRecord
    /// In the meeting's one quiet line: after a dot, plain text, no icon until it's in one.
    var quiet = false
    @ObservedObject private var folders = MeetingFolders.shared
    @ObservedObject private var store = MeetingStore.shared
    @State private var hovering = false

    var body: some View {
        let current = folders.folder(of: record)
        if current != nil || folders.suggestion(for: record, among: store.meetings) == nil {
            HStack(spacing: 0) {
                if quiet { Text(verbatim: " · ").foregroundStyle(DS.Colors.muted) }
                Menu {
                    MoveToFolderItems(ids: [record.id], current: record.folder)
                } label: {
                    if quiet {
                        HStack(spacing: 4) {
                            if current != nil { Image(systemName: "folder").font(.system(size: 11)) }
                            Text(current?.name ?? String(localized: "Lägg i mapp"))
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading).fixedSize()
                                .underline(hovering, color: DS.Colors.muted.opacity(0.6))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.muted)
                        .contentShape(Rectangle())
                    } else {
                        Label {
                            Text(current?.name ?? String(localized: "Lägg i mapp"))
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading).fixedSize()
                        } icon: {
                            Image(systemName: current == nil ? "folder.badge.plus" : "folder")
                        }
                        .font(.system(size: 13, weight: current == nil ? .regular : .medium))
                        .foregroundStyle(current == nil ? DS.Colors.faint : DS.Colors.muted)
                        .contentShape(Rectangle())
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hovering = $0 }
                .help(current == nil ? "Lägg mötet i en mapp" : "Flytta mötet till en annan mapp")
            }
        }
    }
}

/// When the meeting is written: "Lägg mötet i Kund X?" — once, never done by itself.
/// The folder is decided when the card appears and doesn't change under your cursor.
struct FolderSuggestion: View {
    let record: MeetingRecord
    @ObservedObject private var folders = MeetingFolders.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var notes = MeetingNotes.shared
    @State private var target: MeetingFolder?

    var body: some View {
        Group {
            if let target, folders.folder(of: record) == nil, !record.folderAsked {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(DS.Colors.muted)
                    Text("Lägg mötet i \(Text(target.name).fontWeight(.semibold))?")
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    Button("Lägg i mappen") {
                        withAnimation(.snappy) { folders.move([record.id], to: target.id) }
                    }
                    .buttonStyle(.soft)
                    Button {
                        withAnimation(.snappy) { store.dismissFolderSuggestion(for: record.id) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.muted)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Inte nu")
                    .accessibilityLabel("Inte nu")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .card()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear(perform: decide)
        .onChange(of: record.summary) { _, _ in decide() }
        .onChange(of: notes.writing) { _, _ in decide() }
    }

    private func decide() {
        guard target == nil else { return }
        let found = folders.suggestion(for: record, among: store.meetings)
        if found != nil { withAnimation(.snappy) { target = found } }
    }
}

// MARK: - After a move

/// "Flyttat till Kund X · Ångra" — a few seconds, at the foot of the list: where a
/// meeting that left the view went, and the way back.
struct MoveToast: View {
    @ObservedObject private var folders = MeetingFolders.shared

    var body: some View {
        if let move = folders.lastMove {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(DS.Colors.onInk.opacity(0.7))
                Text(move.ids.count == 1 ? String(localized: "Flyttat till \(move.to)")
                     : String(localized: "\(move.ids.count) möten flyttade till \(move.to)"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.onInk)
                    .lineLimit(1)
                Button("Ångra") { withAnimation(.snappy) { folders.undoLastMove() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.onInk)
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Capsule().fill(DS.Colors.ink))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(move.id)
        }
    }
}

// MARK: - Dragging meetings

extension View {
    /// A meeting row to drag onto a folder — with the others selected, if it's one of them.
    func meetingDrag(_ record: MeetingRecord, selection: Set<UUID> = []) -> some View {
        let ids = selection.contains(record.id) ? Array(selection) : [record.id]
        return draggable(MeetingDrag(ids: ids)) {
            HStack(spacing: 6) {
                Image(systemName: ids.count == 1 ? "doc.text" : "doc.on.doc").opacity(0.7)
                Text(verbatim: ids.count == 1 ? record.title : String(localized: "\(ids.count) möten"))
            }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 280)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(DS.Colors.ink))
                .foregroundStyle(DS.Colors.onInk)
        }
    }

    /// For VoiceOver and the keyboard: the same moves as dragging.
    func meetingMoveActions(_ ids: [UUID]) -> some View {
        accessibilityActions {
            ForEach(MeetingFolders.shared.sorted) { folder in
                Button("Flytta till \(folder.name)") { MeetingFolders.shared.move(ids, to: folder.id) }
            }
            Button("Ta ur mappen") { MeetingFolders.shared.move(ids, to: nil) }
        }
    }
}
