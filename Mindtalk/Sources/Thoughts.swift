import AppKit
import SwiftUI

// MARK: - Tankar
//
// Something you think of in the middle of something else: hold ⌃⌥T and say it.
// It's written down by the same speech model as a dictation, but kept here, on its
// own page — never typed into the app you're in. Each thought is new until you
// tick it off. Only the text is kept, on this Mac; never the sound.

struct Thought: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
    var done = false

    init(text: String) { self.text = text }

    // Lenient, like the meetings: a thought missing a field still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }
}

@MainActor
final class Thoughts: ObservableObject {
    static let shared = Thoughts()

    /// Newest first.
    @Published private(set) var all: [Thought] = []
    /// Just saved — the page lights it up for a moment.
    @Published private(set) var fresh: UUID?
    /// Taken away a moment ago: "Ångra" brings it back.
    @Published private(set) var removed: Thought?

    nonisolated private static var url: URL {
        MeetingStore.root.deletingLastPathComponent().appendingPathComponent("Thoughts.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let read = try? decoder.decode([Thought].self, from: data) {
            all = read.sorted { $0.date > $1.date }
        } else {
            // Kept aside, never written over.
            try? FileManager.default.moveItem(at: Self.url, to: Self.url.deletingLastPathComponent()
                .appendingPathComponent("Thoughts-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        }
    }

    private func save() {
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

    func add(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let thought = Thought(text: text.prefix(1).uppercased() + text.dropFirst())
        all.insert(thought, at: 0)
        fresh = thought.id
        save()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.fresh == thought.id { self?.fresh = nil }
        }
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].done = done
        save()
    }

    func edit(_ id: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        if text.isEmpty { remove(id); return }
        guard all[i].text != text else { return }
        all[i].text = text
        save()
    }

    func remove(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        removed = all.remove(at: i)
        save()
        let gone = removed?.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.removed?.id == gone { self?.removed = nil }
        }
    }

    func undoRemove() {
        guard let thought = removed else { return }
        removed = nil
        all.append(thought)
        all.sort { $0.date > $1.date }
        save()
    }

    func removeDone() {
        all.removeAll(where: \.done)
        save()
    }

    var openCount: Int { all.filter { !$0.done }.count }

    #if DEBUG
    /// Screenshots: thoughts in memory only — nothing written.
    func preview(_ items: [Thought]) { all = items }
    #endif
}

// MARK: - The page

struct ThoughtsPage: View {
    @ObservedObject var dictation: Dictation
    /// Screenshots: drawn without the scroll view.
    var scrolls = true
    @ObservedObject private var thoughts = Thoughts.shared
    @State private var query = ""
    @State private var typed = ""
    @State private var showDone = false
    @State private var confirmClear = false
    @FocusState private var typing: Bool

    private var chord: String { Settings.thoughtShortcut?.chip ?? "" }

    var body: some View {
        let shown = thoughts.all.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        let open = shown.filter { !$0.done }
        let done = shown.filter(\.done)
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Tankar",
                       subtitle: "Det du kommer på mitt i något annat. Håll in genvägen och säg det – det hamnar här, inte i appen du står i.")
                .staggered(0)
            speakCard.staggered(1)
            if thoughts.all.isEmpty {
                empty.staggered(2)
            } else {
                searchField.staggered(2)
                if open.isEmpty, done.isEmpty {
                    Text("Inga tankar innehåller det.").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                }
                ForEach(groups(open), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(group.title)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { i, thought in
                                if i > 0 { CardDivider() }
                                ThoughtRow(thought: thought, fresh: thoughts.fresh == thought.id)
                            }
                        }
                        .padding(4)
                        .card()
                    }
                }
                if !done.isEmpty { doneSection(done) }
            }
        }
        .modifier(PageScroll(on: scrolls))
        .overlay(alignment: .bottom) { undoToast }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: thoughts.all)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: thoughts.removed)
        .confirmationDialog("Ta bort alla klara tankar?", isPresented: $confirmClear) {
            Button("Ta bort", role: .destructive) { withAnimation(.snappy) { thoughts.removeDone() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("De klara tankarna tas bort från din Mac och går inte att få tillbaka.")
        }
    }

    /// How to add one: the shortcut, the button, or typing.
    private var speakCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().fill(DS.Colors.chip)
                    Image(systemName: "lightbulb")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DS.Colors.ink)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fånga en tanke").font(.system(size: 15, weight: .semibold))
                    Text(chord.isEmpty ? "Tryck på knappen och säg det du kommer på. Genvägen ställer du in under Inställningar."
                                       : "Håll in \(chord) var du än är, eller tryck snabbt för att prata längre.")
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    dictation.startThought()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold))
                        Text("Säg en tanke")
                    }
                }
                .buttonStyle(.ink)
                .disabled(dictation.phase == .recording || dictation.phase == .transcribing)
                .help("Börja lyssna – tryck på ✓ i bubblan när du är klar")
            }
            .padding(20)
            // Or typed, here.
            HStack(spacing: 10) {
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(DS.Colors.faint)
                TextField("Eller skriv en tanke och tryck på retur", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($typing)
                    .onSubmit {
                        withAnimation(.snappy) { thoughts.add(typed) }
                        typed = ""
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous)
                .fill(DS.Colors.chip.opacity(0.25)))
            .overlay(alignment: .top) { Rectangle().fill(DS.Colors.divider).frame(height: 0.5) }
        }
        .raised(cornerRadius: 20)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            TextField("Sök i tankarna", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onExitCommand { query = "" }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "lightbulb").font(.system(size: 28, weight: .light)).foregroundStyle(DS.Colors.faint)
            Text("Inga tankar än").font(.system(size: 14, weight: .semibold))
            Text(chord.isEmpty ? "Prova: tryck på Säg en tanke och säg ”Ring Eva om offerten”."
                               : "Prova: håll in \(chord) och säg ”Ring Eva om offerten”.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder private func doneSection(_ done: [Thought]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) { showDone.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                        Text("Klara").font(.system(size: 15, weight: .semibold))
                        Text("\(done.count)").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if showDone {
                    Button("Ta bort klara…") { confirmClear = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.Colors.muted)
                }
            }
            .padding(.top, 8)
            if showDone {
                VStack(spacing: 0) {
                    ForEach(Array(done.enumerated()), id: \.element.id) { i, thought in
                        if i > 0 { CardDivider() }
                        ThoughtRow(thought: thought, fresh: false)
                    }
                }
                .padding(4)
                .card()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private var undoToast: some View {
        if let removed = thoughts.removed {
            HStack(spacing: 12) {
                Text("Tanken togs bort").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Button("Ångra") { withAnimation(.snappy) { thoughts.undoRemove() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Capsule().fill(Color(white: 0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.bottom, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(removed.id)
        }
    }

    /// "I dag", "I går", then the day.
    private func groups(_ items: [Thought]) -> [(title: String, items: [Thought])] {
        let calendar = Calendar.current
        var out: [(title: String, items: [Thought])] = []
        for t in items {
            let title: String
            if calendar.isDateInToday(t.date) { title = String(localized: "I dag") }
            else if calendar.isDateInYesterday(t.date) { title = String(localized: "I går") }
            else {
                let day = t.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
                title = day.prefix(1).uppercased() + day.dropFirst()
            }
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].items.append(t) } else { out.append((title, [t])) }
        }
        return out
    }
}

/// A thought: tick it off, click the text to change it.
private struct ThoughtRow: View {
    let thought: Thought
    let fresh: Bool
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { Thoughts.shared.setDone(thought.id, !thought.done) }
            } label: {
                Image(systemName: thought.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(thought.done ? DS.Colors.good : DS.Colors.faint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(thought.done ? "Markera som ny" : "Klar")
            .accessibilityLabel(thought.done ? "Markera som ny" : "Markera som klar")
            if editing {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(thought.text)
                    .font(.system(size: 14))
                    .foregroundStyle(thought.done ? DS.Colors.muted : Color.primary)
                    .strikethrough(thought.done, color: DS.Colors.faint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing() }
            }
            Text(thought.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12)).foregroundStyle(DS.Colors.faint).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(fresh ? DS.Colors.chip : DS.Colors.chip.opacity(hovering ? 0.5 : 0)))
        .animation(.easeOut(duration: 0.6), value: fresh)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Ändra") { startEditing() }
            Button("Kopiera") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(thought.text, forType: .string)
            }
            Button(thought.done ? "Markera som ny" : "Markera som klar") { Thoughts.shared.setDone(thought.id, !thought.done) }
            Divider()
            Button("Ta bort", role: .destructive) { withAnimation(.snappy) { Thoughts.shared.remove(thought.id) } }
        }
    }

    private func startEditing() {
        text = thought.text
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        Thoughts.shared.edit(thought.id, text: text)
    }
}

private struct PageScroll: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.pageLayout() } else { content.padding(28) }
    }
}
