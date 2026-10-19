import SwiftUI

// MARK: - Your notes, your marks, and telling the room
//
// While a meeting runs you can jot a few words and press ↩ — a note, with its time —
// and mark a moment as a decision, a task or something important (with the words
// you wrote, if you wrote any). Each note and mark keeps the
// moment in the recording, so it can be heard again, and the summary builds on
// them: your notes say what mattered, your marks become decisions, tasks and
// points even where the words alone didn't say so.
//
// And before anything else, the others should know they're being recorded: a
// sentence to read out, and a note in the meeting that you did.

extension MeetingRecord.Mark.Kind {
    /// For VoiceOver: "Markera ett beslut".
    var markLabel: String {
        switch self {
        case .decision: return String(localized: "Markera ett beslut")
        case .task: return String(localized: "Markera något att göra")
        case .important: return String(localized: "Markera något viktigt")
        }
    }

    /// The tooltip on its button: what it does, and that what you wrote goes with it.
    var markHelp: String {
        switch self {
        case .decision: return String(localized: "Markera ett beslut. Har du skrivit något blir det beslutet.")
        case .task: return String(localized: "Markera något att göra. Har du skrivit något blir det uppgiften.")
        case .important: return String(localized: "Markera något viktigt. Har du skrivit något sparas det som viktigt.")
        }
    }

    var title: String {
        switch self {
        // Its own key: one marked decision ("Decision"), not the summary's "Beslut" heading
        // ("Decisions"). The Swedish is the text after the bar (scripts/strings.py).
        case .decision: return String(localized: "mark|Beslut")
        case .task: return String(localized: "Att göra")
        case .important: return String(localized: "Viktigt")
        }
    }

    var symbol: String {
        switch self {
        case .decision: return "checkmark.seal.fill"
        case .task: return "list.bullet.clipboard.fill"
        case .important: return "star.fill"
        }
    }

    /// Its quiet colour — on the icon and the label, nowhere bigger.
    var tint: Color {
        switch self {
        case .decision: return DS.Colors.markDecision
        case .task: return DS.Colors.markTask
        case .important: return DS.Colors.markImportant
        }
    }
}

/// What you're typing as a note in a meeting: one draft, whether typed in the window
/// or the panel. ↩ adds it to the meeting's notes; a mark pressed takes it as its words.
@MainActor final class NoteDraft: ObservableObject {
    static let shared = NoteDraft()
    @Published var text = "" {
        didSet {
            if trimmed.isEmpty { begunAt = nil }
            else if begunAt == nil {
                let session = MeetingSession.shared
                begunAt = session.isRecording ? session.elapsed : nil
            }
        }
    }
    /// Where the recording was when you began writing it: the note's moment.
    private(set) var begunAt: Double?
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The draft, taken out of the field (which is empty again), with its moment.
    func take() -> (text: String, at: Double?)? {
        let taken = trimmed, at = begunAt
        guard !taken.isEmpty else { return nil }
        text = ""
        return (taken, at)
    }

    #if DEBUG
    /// `--render-island`: the field drawn as text, since an image can't draw the text view.
    static var still = false
    #endif
}

extension VerticalAlignment {
    private enum NoteField: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// The island's row lines up on the note field, not on the notes above it.
    static let noteField = VerticalAlignment(NoteField.self)
}

/// While a meeting records, in the window: one island at the foot of the text — the
/// time, a note, the marks, stop. Dark in both appearances, as the recording pill
/// always was. ↩ adds what you wrote as a note with its time, and the last few stand
/// above the field, so you see that they're kept.
struct NoteIsland<Leading: View, Trailing: View>: View {
    @ObservedObject var session: MeetingSession
    /// The panel: too narrow for one row — the note above, the marks and stop below.
    var compact = false
    /// Drawn to an image: a mark under the pointer, the check after ↩.
    var stillHovered: MeetingRecord.Mark.Kind? = nil
    var stillAdded = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ObservedObject private var draft = NoteDraft.shared
    @FocusState private var focused: Bool
    /// For a moment after ↩: a check in the field.
    @State private var added = false

    /// How many of the notes you added stand above the field.
    private var shownCount: Int { compact ? 2 : 3 }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 8) {
                    if hasNotes {
                        recent
                            .padding(.horizontal, 13)
                            .padding(.top, 4)
                    }
                    field
                    HStack(spacing: 10) {
                        leading
                        marks
                        Spacer(minLength: 0)
                        trailing
                    }
                    .padding(.leading, 4)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .noteField, spacing: 12) {
                    leading
                    VStack(alignment: .leading, spacing: 6) {
                        if hasNotes { recent.padding(.horizontal, 13) }
                        field.alignmentGuide(.noteField) { $0[VerticalAlignment.center] }
                    }
                    marks
                    trailing
                }
                .padding(.leading, 18)
                .padding(.trailing, 7)
                .padding(.top, hasNotes ? 11 : 7)
                .padding(.bottom, 7)
                .frame(maxWidth: 680)
            }
        }
        .background(RoundedRectangle(cornerRadius: compact ? 20 : 23, style: .continuous).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 20 : 23, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(compact ? 0.18 : 0.28), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private var marks: some View {
        MarkIcons(paused: session.isPaused, stillHovered: stillHovered) { kind in
            guard session.isRecording else { return }
            // Something written: the mark's words, and the field is empty again.
            let taken = draft.take()
            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { _ = session.mark(kind, text: taken?.text, at: taken?.at) }
        }
    }

    // MARK: The notes you added

    private var notes: [MeetingRecord.Note] {
        (session.record?.notes ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var hasNotes: Bool { !notes.isEmpty }

    /// "12:04 · Kom ihåg detta": the last few, the newest nearest the field and
    /// clearest, and "+4 till" beside the oldest when there are more.
    private var recent: some View {
        let all = notes
        let shown = Array(all.enumerated().suffix(shownCount))
        let first = shown.first?.offset ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(shown, id: \.offset) { k, note in
                HStack(spacing: 8) {
                    line(note)
                        .opacity(fade(k - first, of: shown.count))
                    if k == first, all.count > shown.count {
                        Spacer(minLength: 4)
                        Text("+\(all.count - shown.count) till")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: all.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Dina senaste anteckningar"))
        .accessibilityValue(shown.map(\.element.text).joined(separator: ", "))
    }

    private func line(_ note: MeetingRecord.Note) -> some View {
        let time = note.at.map { Text(verbatim: MeetingView.duration($0) + " · ").foregroundStyle(.white.opacity(0.6)) }
            ?? Text(verbatim: "")
        return (time + Text(verbatim: note.text).foregroundStyle(.white))
            .font(.system(size: 12).monospacedDigit())
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The newest clearest, the ones before it fainter.
    private func fade(_ k: Int, of n: Int) -> Double {
        [0.8, 0.58, 0.4][min(n - 1 - k, 2)]
    }

    // MARK: The field

    /// ↩: what you wrote becomes a note with its time, and the field is empty again.
    private func add() {
        guard session.record != nil, let taken = draft.take() else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { _ = session.addNote(taken.text, at: taken.at) }
        AccessibilityNotification.Announcement(String(localized: "Anteckningen är sparad")).post()
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { added = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.3)) { added = false }
        }
    }

    private var showsCheck: Bool { added || stillAdded }

    @ViewBuilder private var editor: some View {
        #if DEBUG
        if NoteDraft.still {
            Text(verbatim: draft.text.isEmpty ? " " : draft.text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .padding(.leading, 5)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
        } else {
            textEditor
        }
        #else
        textEditor
        #endif
    }

    private var textEditor: some View {
        TextEditor(text: $draft.text)
            .accessibilityLabel("Anteckning")
            .accessibilityHint("Tryck på retur så läggs anteckningen till. Skift och retur ger en ny rad.")
            .font(.system(size: 13.5))
            .foregroundStyle(.white)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(minHeight: 18, maxHeight: 80)
            .fixedSize(horizontal: false, vertical: true)
            // ↩ adds the note; ⇧↩ (or ⌥↩) gives a new line in it.
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                add()
                return .handled
            }
    }

    private var field: some View {
            ZStack(alignment: .topLeading) {
                // The editor writes its first line at its very top, so the air above
                // it is the editor's padding, not the placeholder's — the caret then
                // sits on the placeholder's line rather than above it.
                if draft.text.isEmpty {
                    Text("Skriv en anteckning och tryck ↩")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 5)        // the text view's own line padding
                        .allowsHitTesting(false)
                }
                editor
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(focused ? 0.1 : 0.06)))
            // Just added: a check for a moment, where the words were.
            .overlay(alignment: .trailing) {
                if showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.16)))
                        .padding(.trailing, 6)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// Pause and stop, at the end of the island. Recording: pause (quiet), then stop —
/// the stop labelled where there's room for it. Paused: "Fortsätt" first.
struct MeetingControls: View {
    @ObservedObject var session: MeetingSession
    /// The panel: stop as "Avsluta".
    var labelledStop = false

    var body: some View {
        HStack(spacing: 6) {
            if session.isPaused {
                Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { session.resume() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text(String(localized: "pause|Fortsätt")).font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [.command, .option])
                .help("Sätt på mikrofonen igen så fortsätter mötet där det pausades (⌥⌘P)")
                .accessibilityLabel(String(localized: "pause|Fortsätt mötet"))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                round(symbol: "stop.fill", filled: false, help: "Avsluta mötet. Du kan ångra i några sekunder.",
                      label: "Avsluta mötet") { _ = session.requestStop() }
            } else {
                round(symbol: "pause.fill", filled: false, help: "Pausa: mikrofonen stängs av och mötet väntar (⌥⌘P)",
                      label: "Pausa mötet") { session.pause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                if labelledStop {
                    Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold))
                            Text(String(localized: "meeting|Avsluta")).font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Avsluta mötet. Du kan ångra i några sekunder.")
                    .accessibilityLabel("Avsluta mötet")
                } else {
                    round(symbol: "stop.fill", filled: true, help: "Avsluta mötet. Du kan ångra i några sekunder.",
                          label: "Avsluta mötet") { _ = session.requestStop() }
                }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: session.isPaused)
    }

    private func round(symbol: String, filled: Bool, help: LocalizedStringKey, label: LocalizedStringKey,
                       action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(filled ? .white : .white.opacity(0.1)))
                .overlay(Circle().strokeBorder(.white.opacity(filled ? 0 : 0.14), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Recording: the red dot that breathes; paused, two quiet bars.
struct RecordingMark: View {
    @ObservedObject var session: MeetingSession
    var color: Color = .white

    var body: some View {
        if session.isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(color.opacity(0.7))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        } else {
            RecordingDot()
        }
    }
}

/// The three marks as round buttons in their colours — ⌥⌘1, ⌥⌘2, ⌥⌘3. Under the
/// pointer, a label floats above the one you're on — its name and key, at once, no
/// waiting for a tooltip, and nothing beside it moves; held still, the tooltip says
/// what it does. Something written in the field goes with the mark as its words.
/// Paused, there's nothing to mark.
private struct MarkIcons: View {
    var paused = false
    /// Drawn to an image: the one under the pointer.
    var stillHovered: MeetingRecord.Mark.Kind? = nil
    let mark: (MeetingRecord.Mark.Kind) -> Void
    @State private var flashed: MeetingRecord.Mark.Kind?
    @State private var hovered: MeetingRecord.Mark.Kind?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(MeetingRecord.Mark.Kind.allCases.enumerated()), id: \.element) { i, kind in
                Button {
                    mark(kind)
                    AccessibilityNotification.Announcement(String(localized: "Markerat: \(kind.title)")).post()
                    withAnimation(.spring(duration: 0.3, bounce: 0.3)) { flashed = kind }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        if flashed == kind { withAnimation(.spring(duration: 0.4)) { flashed = nil } }
                    }
                } label: {
                    MarkPill(kind: kind, key: i + 1,
                             open: !paused && (hovered == kind || flashed == kind || stillHovered == kind),
                             done: flashed == kind)
                }
                .buttonStyle(.plain)
                .zIndex(hovered == kind || flashed == kind ? 1 : 0)
                .onHover { inside in
                    withAnimation(.spring(duration: 0.28, bounce: 0.2)) {
                        hovered = inside ? kind : (hovered == kind ? nil : hovered)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                .help(kind.markHelp)
                .accessibilityLabel(kind.markLabel)
                .accessibilityHint("Markerar det som sägs just nu (⌥⌘\(i + 1)). Har du skrivit något följer det med.")
            }
        }
        .disabled(paused)
        .opacity(paused ? 0.4 : 1)
        .animation(.easeOut(duration: 0.2), value: paused)
    }
}

/// One mark: a tinted disc with its symbol. Open (under the pointer), the disc lights
/// up and a label floats above it with the name and key — or, for a moment after a
/// click, "Markerat".
struct MarkPill: View {
    let kind: MeetingRecord.Mark.Kind
    let key: Int
    let open: Bool
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark" : kind.symbol)
            .font(.system(size: 14, weight: .semibold))
            // The symbol in its colour, its marks cut out in the island's dark (the
            // star has none: one layer, all colour).
            .symbolRenderingMode(.palette)
            .foregroundStyle(done || kind == .important ? kind.tint : Color(white: 0.07), kind.tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 32, height: 32)
            .background(Circle().fill(kind.tint.opacity(done ? 0.28 : open ? 0.2 : 0.11)))
            .overlay(Circle().strokeBorder(kind.tint.opacity(open ? 0.55 : 0.22), lineWidth: 0.6))
            .contentShape(Circle())
            .scaleEffect(done ? 1.08 : 1)
            // The first one nearest the island's edge: its label grows to the right.
            .overlay(alignment: key == 1 ? .bottomLeading : .bottom) {
                if open {
                    label
                        .fixedSize()
                        .offset(y: -40)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: key == 1 ? .bottomLeading : .bottom))
                            .combined(with: .offset(y: 4)))
                }
            }
    }

    private var label: some View {
        HStack(spacing: 7) {
            Circle().fill(kind.tint).frame(width: 6, height: 6)
            Text(done ? String(localized: "Markerat") : kind.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
            if !done {
                Text("⌥⌘\(key)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(Color(white: 0.13)))
        .overlay(Capsule().strokeBorder(kind.tint.opacity(0.45), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .environment(\.colorScheme, .dark)
    }
}

/// After the meeting: your notes, each line with the moment you wrote it — and a
/// way to change them.
struct SavedNotes: View {
    let record: MeetingRecord
    let edit: MeetingEdits
    var startEditing = false
    let listen: (Double) -> Void
    /// "Visa i texten" on a note with a time: its index in `record.notes`, to show where
    /// in the text it was written.
    var showInText: ((Int) -> Void)? = nil
    /// Renders: the row drawn as under the pointer.
    var stillHovered: Int? = nil
    @State private var editing = false
    @State private var text = ""
    @State private var hovered: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dina anteckningar").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                Spacer()
                Button(editing ? "Klar" : "Ändra") {
                    if editing { edit.notes(text) } else { text = record.notesText; focused = true }
                    withAnimation(.easeOut(duration: 0.2)) { editing.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
            }
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.field))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                Text("Välj Sammanfatta igen i menyn ⋯ så kommer ändringarna med i sammanfattningen.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(record.notes.enumerated()), id: \.offset) { i, note in
                        if !note.text.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(DS.Colors.faint)
                                Text(note.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let at = note.at, record.hasAudio {
                                    Button { listen(at) } label: {
                                        Text(MeetingView.duration(at)).monospacedDigit()
                                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Lyssna från när du skrev det")
                                }
                                // Where in the text you wrote it: shown under the pointer, so
                                // the list stays a list.
                                if note.at != nil, let showInText {
                                    Spacer(minLength: 0)
                                    Button { showInText(i) } label: {
                                        Text("Visa i texten →")
                                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                                            .fixedSize()
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(hovered == i || stillHovered == i ? 1 : 0)
                                    .help("Visa var i texten du skrev det")
                                    .accessibilityLabel("Visa i texten")
                                }
                            }
                            .font(.system(size: 14.5))
                            .contentShape(Rectangle())
                            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h ? i : (hovered == i ? nil : hovered) } }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.card))
        .onAppear {
            if startEditing, record.notes.isEmpty { text = ""; editing = true; focused = true }
        }
        // Kept as you type (a moment after you stop), and when the page goes — not only on "Klar".
        .task(id: text) {
            guard editing else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, editing else { return }
            edit.notes(text)
        }
        .onDisappear { if editing { edit.notes(text) } }
    }
}

/// Settings → Möten: the summary's language, how long recordings stay, and where they are.
/// The language the summaries are written in (Inställningar → Möten).
struct SummaryLanguageCard: View {
    @State private var summaryLanguage = SummaryLanguage.chosen

    var body: some View {
        CardRow(title: "Sammanfattningens språk",
                detail: String(localized: "Sammanfattningen skrivs på mötets språk om du inte väljer ett annat.")) {
            MenuPicker(options: SummaryLanguage.allCases.map { ($0, $0.title) }, selection: $summaryLanguage)
                .onChange(of: summaryLanguage) { _, new in SummaryLanguage.chosen = new }
        }
        .card()
    }
}

/// How long a meeting's sound is kept, and where the meetings are (Inställningar → Möten).
struct MeetingStorageCard: View {
    @ObservedObject private var store = MeetingStore.shared
    @State private var days = MeetingAudio.keepDays
    @State private var asking: Int?
    /// What the meetings take on disk; nil while it's being counted.
    @State private var bytes: Int64?

    private var storage: String {
        let n = store.meetings.count
        let count = n == 1 ? String(localized: "1 möte") : String(localized: "\(n) möten")
        guard let bytes else { return count }
        return count + " · " + DiskSize.text(bytes)
    }

    var body: some View {
        VStack(spacing: 0) {
            // What the choice means, said for the one chosen.
            CardRow(title: "Behåll ljudet",
                    detail: days == 0 ? String(localized: "Ljudet sparas så länge mötet finns. Texten sparas alltid.")
                        : String(localized: "Ljud äldre än \(days) dagar flyttas till papperskorgen. Texten sparas alltid.")) {
                MenuPicker(options: MeetingAudio.choices.map { ($0, MeetingAudio.title($0)) },
                           selection: Binding(get: { days }, set: choose))
            }
            CardDivider()
            // Where they are, and how much room they take — mostly the recordings.
            CardRow(title: "På den här Macen", detail: storage) {
                Button("Visa i Finder") {
                    try? FileManager.default.createDirectory(at: MeetingStore.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.root])
                }
                .buttonStyle(.soft)
            }
        }
        .card()
        .task(id: store.meetings.count) {
            let root = MeetingStore.root
            bytes = await Task.detached(priority: .utility) { ModelDownload.allocatedBytes(in: root) }.value
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Flytta till papperskorgen", role: .destructive) {
                if let asking { apply(asking) }
                asking = nil
            }
            Button("Avbryt", role: .cancel) { asking = nil }
        } message: {
            Text("Texten, dina anteckningar och sammanfattningen finns kvar. Inspelningarna går att hämta ur papperskorgen tills den töms.")
        }
    }

    private var confirmTitle: String {
        let n = asking.map { store.recordingsPast(days: $0).count } ?? 0
        return n == 1 ? String(localized: "1 inspelning är äldre än så")
                      : String(localized: "\(n) inspelningar är äldre än så")
    }

    /// A shorter time with older recordings on the Mac asks first.
    private func choose(_ new: Int) {
        if new > 0, !store.recordingsPast(days: new).isEmpty { asking = new } else { apply(new) }
    }

    private func apply(_ new: Int) {
        days = new
        MeetingAudio.keepDays = new
        store.applyRetention()
    }
}

/// "✓ Beslut 3:12" under the words you marked — in the panel and the window alike.
/// It appears with a small pop when you press, so you see that it took.
struct MarkChips: View {
    let marks: [MeetingRecord.Mark]
    var compact = false
    var remove: ((UUID) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(marks) { mark in
                HStack(spacing: 4) {
                    Image(systemName: mark.kind.symbol).foregroundStyle(mark.kind.tint)
                    Text("\(mark.kind.title) \(MeetingView.duration(mark.at))")
                        .fixedSize()
                    // What you wrote when you marked it: the start of it, all of it under the pointer.
                    if let text = mark.text {
                        Text(verbatim: Self.start(of: text, compact ? 24 : 44))
                            .fontWeight(.regular)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 3)
                            .layoutPriority(-1)
                    }
                }
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, compact ? 8 : 9)
                    .frame(height: compact ? 22 : 24)
                    .background(Capsule().fill(mark.kind.tint.opacity(0.12)))
                    .contextMenu {
                        if let remove { Button("Ta bort markeringen") { remove(mark.id) } }
                    }
                    .help(mark.text ?? String(localized: "Du markerade det här under mötet"))
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.35), value: marks.map(\.id))
    }

    /// "Kunderna i Norge vill ha…": a long text cut at a word, so a chip stays a chip.
    static func start(of text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        let cut = text.prefix(count)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// Your own notes under the words being said when you wrote them: a pencil, "Du", the
/// moment, and what you wrote. In the family of the mark chips, but yours: muted
/// ink, no colour. Several from the same moment sit together.
struct NoteLines: View {
    let notes: [NotePlacement.Placed]
    /// "Visa i texten" from the summary: the note to light for a moment.
    var focused: Int? = nil
    var listen: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes) { placed in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.muted)
                    if let listen, let at = placed.note.at {
                        Button { listen(at) } label: {
                            Text(verbatim: "\(String(localized: "Du")) \(MeetingView.duration(at))")
                                .fixedSize()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Lyssna från strax innan du skrev det")
                        .accessibilityLabel("Lyssna från när du skrev det, \(MeetingView.spoken(at))")
                    } else {
                        Text(verbatim: "\(String(localized: "Du")) \(placed.note.at.map(MeetingView.duration) ?? "")")
                            .fixedSize()
                    }
                    Text(placed.note.text)
                        .fontWeight(.regular)
                        .foregroundStyle(DS.Colors.ink.opacity(0.8))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.Colors.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(focused == placed.id ? DS.Colors.ink.opacity(0.1) : DS.Colors.chip.opacity(0.55))
                )
                .animation(.easeOut(duration: 0.25), value: focused == placed.id)
                .help("Du skrev det här under mötet")
            }
        }
    }
}

/// Above the summary when you've written to your notes since it was written: a
/// quiet question, and the button that answers it. Nothing happens until you press.
struct NotesChangedRow: View {
    let again: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.muted)
            Text("Du har skrivit till anteckningar. Sammanfatta igen?")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Sammanfatta igen", action: again)
                .buttonStyle(.soft)
                .help("Skriver sammanfattningen igen, med det du skrivit")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.card))
        .accessibilityElement(children: .contain)
    }
}

/// Your notes with a time, each under the turn that was being said when you began
/// it (the first turn for a note from before anything was said). Worked out once per
/// change to the meeting, not at every redraw: the text is redrawn while you listen.
enum NotePlacement {
    struct Placed: Identifiable, Equatable {
        /// Its index in `record.notes`: what "Visa i texten" points at.
        let id: Int
        let note: MeetingRecord.Note
    }

    private struct Key: Equatable {
        let meeting: UUID
        let notes: [MeetingRecord.Note]
        let turns: Int
    }
    @MainActor private static var cache: (key: Key, placed: [Int: [Placed]])?

    /// The notes by the id of the turn they sit under.
    @MainActor static func place(_ record: MeetingRecord, turns: [MeetingTurn]) -> [Int: [Placed]] {
        guard !turns.isEmpty, record.notes.contains(where: { $0.at != nil }) else { return [:] }
        var hasher = Hasher()
        for t in turns { hasher.combine(t.id); hasher.combine(t.start) }
        let key = Key(meeting: record.id, notes: record.notes, turns: hasher.finalize())
        if let cache, cache.key == key { return cache.placed }
        var out: [Int: [Placed]] = [:]
        for (i, note) in record.notes.enumerated() {
            guard let at = note.at, !note.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            out[turn(at: at, in: turns), default: []].append(Placed(id: i, note: note))
        }
        cache = (key, out)
        return out
    }

    /// The id of the turn a moment falls in: as "Visa i texten" finds it from a source.
    static func turn(at: Double, in turns: [MeetingTurn]) -> Int {
        var lo = 0, hi = turns.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if turns[mid].start <= at + 0.05 { lo = mid } else { hi = mid - 1 }
        }
        return turns[lo].id
    }
}

/// "Avslutas om 3 s · Ångra" — on ink, in the panel's stop button and the window's
/// recording pill. The ring empties as the seconds run out.
struct StopCountdown: View {
    @ObservedObject var session: MeetingSession
    var compact = false
    /// On the window's recording pill, which is dark in light mode too.
    var onDark = false
    private var fore: Color { onDark ? .white : DS.Colors.onInk }
    private var back: Color { onDark ? .black : DS.Colors.ink }

    var body: some View {
        HStack(spacing: compact ? 9 : 11) {
            if let stopAt = session.stopAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let left = max(0, stopAt.timeIntervalSince(context.date))
                    HStack(spacing: compact ? 9 : 11) {
                        ZStack {
                            Circle().stroke(fore.opacity(0.25), lineWidth: 2)
                            Circle().trim(from: 0, to: left / MeetingSession.undoSeconds)
                                .stroke(fore, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 15, height: 15)
                        Text("Avslutas om \(Int(left.rounded(.up))) s")
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .foregroundStyle(fore)
                            .fixedSize()
                    }
                }
            }
            if !compact { Spacer(minLength: 8) }
            Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { session.cancelStop() } } label: {
                Text("Ångra")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(back)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(Capsule().fill(fore))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Ångra, så fortsätter mötet")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mötet avslutas om några sekunder")
    }
}
