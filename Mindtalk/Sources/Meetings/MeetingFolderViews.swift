import SwiftUI
import UniformTypeIdentifiers

// MARK: - The folder row
//
// Under the search field: "Alla", your folders A to Ö with how many meetings each
// holds, and "Ny mapp". A meeting dragged onto a folder goes into it; dragged onto
// "Alla", out of its folder. Right-click a folder to rename it or take it away.

struct FolderBar: View {
    @ObservedObject var folders: MeetingFolders
    @ObservedObject var store: MeetingStore
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: UUID?
    @State private var removing: MeetingFolder?
    /// Screenshots: drawn without the scroll view (an image can't show one).
    var scrolls = true

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) { chips }
                    .scrollClipDisabled()
            } else {
                chips
            }
        }
        .confirmationDialog(Text("Ta bort mappen \"\(removing?.name ?? "")\"?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Ta bort mappen", role: .destructive) {
                if let id = removing?.id { withAnimation(.snappy) { folders.remove(id) } }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Mötena i den tas inte bort – de finns kvar under Alla.")
        }
    }

    private var chips: some View {
            HStack(spacing: 8) {
                FolderChip(title: String(localized: "Alla"), count: store.meetings.count,
                           selected: folders.selected == nil, symbol: nil) {
                    select(nil)
                } drop: { id in store.setFolder(nil, of: id) }
                ForEach(folders.sorted) { folder in
                    if renaming == folder.id {
                        nameField(initial: folder.name) { name in
                            folders.rename(folder.id, to: name)
                            renaming = nil
                        } cancel: { renaming = nil }
                    } else {
                        FolderChip(title: folder.name, count: store.meetings.filter { $0.folder == folder.id }.count,
                                   selected: folders.selected == folder.id, symbol: "folder") {
                            select(folder.id)
                        } drop: { id in
                            withAnimation(.snappy) { store.setFolder(folder.id, of: id) }
                        }
                        .contextMenu {
                            Button("Byt namn…") { renaming = folder.id }
                            Button("Ta bort mappen…", role: .destructive) { removing = folder }
                        }
                    }
                }
                if naming {
                    nameField(initial: "") { name in
                        if let folder = folders.create(name) { select(folder.id) }
                        naming = false
                    } cancel: { naming = false }
                } else {
                    Button { naming = true } label: {
                        Label("Ny mapp", systemImage: "plus")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Skapa en mapp att sortera mötena i")
                }
            }
            .padding(.vertical, 2)
            .animation(.spring(duration: 0.3, bounce: 0.15), value: folders.folders)
            .animation(.spring(duration: 0.3, bounce: 0.15), value: naming)
    }

    private func select(_ id: UUID?) {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { folders.selected = id }
    }

    /// Naming a new folder, or renaming one, right where its chip is.
    private func nameField(initial: String, done: @escaping (String) -> Void, cancel: @escaping () -> Void) -> some View {
        FolderNameField(initial: initial, done: done, cancel: cancel)
    }
}

/// One folder in the row: its name and how many meetings, a drop target for meetings.
private struct FolderChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let symbol: String?
    let action: () -> Void
    let drop: (UUID) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: targeted ? "\(symbol).fill" : symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("\(count)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(selected ? DS.Colors.onInk.opacity(0.65) : DS.Colors.faint)
            }
            .foregroundStyle(selected ? DS.Colors.onInk : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(selected ? DS.Colors.ink : DS.Colors.chip))
            .overlay(Capsule().strokeBorder(DS.Colors.ink, lineWidth: targeted ? 2 : 0))
            .scaleEffect(targeted ? 1.06 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: targeted)
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids { drop(id) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityLabel("\(title), \(count) möten")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A folder's name being written: Return keeps it, Escape (or an empty name) lets it go.
private struct FolderNameField: View {
    let initial: String
    let done: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            TextField("Mappens namn", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .focused($focused)
                .frame(width: 130)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(DS.Colors.field))
        .overlay(Capsule().strokeBorder(DS.Colors.ink.opacity(0.5), lineWidth: 1))
        .onAppear {
            name = initial
            focused = true
        }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == initial { cancel() } else { done(trimmed) }
    }
}

/// "Flytta till ›": the folders, "Ingen mapp" and a new one — for a meeting's
/// context menu and its page.
struct MoveToFolderMenu: View {
    let record: MeetingRecord
    @ObservedObject var folders = MeetingFolders.shared
    @State private var creating = false

    var body: some View {
        Menu("Flytta till") {
            Button {
                MeetingStore.shared.setFolder(nil, of: record.id)
            } label: {
                if record.folder == nil { Label("Ingen mapp", systemImage: "checkmark") } else { Text("Ingen mapp") }
            }
            if !folders.folders.isEmpty { Divider() }
            ForEach(folders.sorted) { folder in
                Button {
                    MeetingStore.shared.setFolder(folder.id, of: record.id)
                } label: {
                    if record.folder == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                }
            }
        }
    }
}

/// On a meeting's page, beside its date: the folder it's in — a menu to move it.
struct FolderTag: View {
    let record: MeetingRecord
    @ObservedObject var folders = MeetingFolders.shared
    @State private var naming = false

    var body: some View {
        let current = folders.folder(of: record)
        if !folders.folders.isEmpty || current != nil {
            Menu {
                Button {
                    MeetingStore.shared.setFolder(nil, of: record.id)
                } label: {
                    if current == nil { Label("Ingen mapp", systemImage: "checkmark") } else { Text("Ingen mapp") }
                }
                Divider()
                ForEach(folders.sorted) { folder in
                    Button {
                        MeetingStore.shared.setFolder(folder.id, of: record.id)
                    } label: {
                        if current?.id == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: current == nil ? "folder.badge.plus" : "folder")
                        .font(.system(size: 11, weight: .semibold))
                    Text(current?.name ?? String(localized: "Lägg i mapp"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(current == nil ? DS.Colors.muted : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(DS.Colors.chip.opacity(current == nil ? 0.6 : 1)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(current == nil ? "Lägg mötet i en mapp" : "Flytta mötet till en annan mapp")
        }
    }
}

/// When the meeting is written: "Lägga i Kund X?" — once, never done by itself.
struct FolderSuggestion: View {
    let record: MeetingRecord
    @ObservedObject var folders = MeetingFolders.shared
    @ObservedObject var store = MeetingStore.shared

    var body: some View {
        if let folder = folders.suggestion(for: record, among: store.meetings) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(DS.Colors.muted)
                Text("Lägga mötet i \(Text(folder.name).fontWeight(.semibold))?")
                    .font(.system(size: 13))
                Spacer()
                Button("Lägg där") {
                    withAnimation(.snappy) { store.setFolder(folder.id, of: record.id) }
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
}
