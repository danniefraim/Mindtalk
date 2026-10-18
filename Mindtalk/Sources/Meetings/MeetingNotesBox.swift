import SwiftUI

// MARK: - Your notes, your marks, and telling the room
//
// While a meeting runs you can jot a few words — a line each — and mark a moment
// as a decision, a task or something important. Each line and mark keeps the
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

/// What you're typing as notes in a meeting — one text, whether typed in the window
/// or the panel: each island shows it, and neither can overwrite what the other took.
@MainActor final class NoteDraft: ObservableObject {
    static let shared = NoteDraft()
    @Published var text = ""
}

/// While a meeting records, in the window: one island at the foot of the text — the
/// time, a note (a line per thing), the marks, stop. Dark in both appearances, as
/// the recording pill always was.
struct NoteIsland<Leading: View, Trailing: View>: View {
    @ObservedObject var session: MeetingSession
    /// The panel: too narrow for one row — the note above, the marks and stop below.
    var compact = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ObservedObject private var draft = NoteDraft.shared
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 8) {
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
                HStack(alignment: .center, spacing: 12) {
                    leading
                    field
                    marks
                    trailing
                }
                .padding(.leading, 18)
                .padding(.trailing, 7)
                .padding(.vertical, 7)
                .frame(maxWidth: 680)
            }
        }
        .background(RoundedRectangle(cornerRadius: compact ? 20 : 23, style: .continuous).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 20 : 23, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(compact ? 0.18 : 0.28), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .onChange(of: draft.text) { _, new in if focused { session.setNotes(new) } }
    }

    private var marks: some View {
        MarkIcons(paused: session.isPaused) { kind in
            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { _ = session.mark(kind) }
        }
    }

    private var field: some View {
            ZStack(alignment: .topLeading) {
                // The editor writes its first line at its very top, so the air above
                // it is the editor's padding, not the placeholder's — the caret then
                // sits on the placeholder's line rather than above it.
                if draft.text.isEmpty {
                    Text("Anteckning: en rad per sak")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 5)        // the text view's own line padding
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.text)
                    .accessibilityLabel("Anteckning")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 18, maxHeight: 80)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(focused ? 0.1 : 0.06)))
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
                round(symbol: "stop.fill", filled: false, help: "Avsluta mötet. Du kan ångra i några sekunder",
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
                    .help("Avsluta mötet. Du kan ångra i några sekunder")
                    .accessibilityLabel("Avsluta mötet")
                } else {
                    round(symbol: "stop.fill", filled: true, help: "Avsluta mötet. Du kan ångra i några sekunder",
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
/// waiting for a tooltip, and nothing beside it moves. Paused, there's nothing to mark.
private struct MarkIcons: View {
    var paused = false
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
                    MarkPill(kind: kind, key: i + 1, open: !paused && (hovered == kind || flashed == kind),
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
                .accessibilityLabel(kind.markLabel)
                .accessibilityHint("Markerar det som sägs just nu (⌥⌘\(i + 1))")
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
                    .foregroundStyle(.white.opacity(0.45))
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
    @State private var editing = false
    @State private var text = ""
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
                    ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in
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
                            }
                            .font(.system(size: 14.5))
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
struct MeetingPrivacyCard: View {
    @ObservedObject private var store = MeetingStore.shared
    @State private var days = MeetingAudio.keepDays
    @State private var asking: Int?

    @State private var summaryLanguage = SummaryLanguage.chosen
    /// What the meetings take on disk; nil while it's being counted.
    @State private var bytes: Int64?

    private var storage: String {
        let n = store.meetings.count
        let count = n == 1 ? String(localized: "1 möte") : String(localized: "\(n) möten")
        guard let bytes else { return count }
        return count + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Sammanfattningens språk",
                    detail: String(localized: "Sammanfattningen skrivs på mötets språk om du inte väljer ett annat.")) {
                MenuPicker(options: SummaryLanguage.allCases.map { ($0, $0.title) }, selection: $summaryLanguage)
                    .onChange(of: summaryLanguage) { _, new in SummaryLanguage.chosen = new }
            }
            CardDivider()
            CardRow(title: "Spara inspelningar",
                    detail: String(localized: "Texten, dina anteckningar och sammanfattningen sparas alltid. Äldre inspelningar flyttas till papperskorgen.")) {
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
                }
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, compact ? 8 : 9)
                    .frame(height: compact ? 22 : 24)
                    .background(Capsule().fill(mark.kind.tint.opacity(0.12)))
                    .contextMenu {
                        if let remove { Button("Ta bort markeringen") { remove(mark.id) } }
                    }
                    .help("Du markerade det här under mötet")
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.35), value: marks.map(\.id))
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
