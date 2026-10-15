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

/// "Innan ni börjar": the round where everyone says their name, offered when a
/// meeting began without it — never in the way: the recording runs from the first word.
struct OpeningCard: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var memory = VoiceMemory.shared
    var compact = false
    /// The panel opens the round in the large window (it needs the room's screen).
    var startRound: (() -> Void)? = nil

    var body: some View {
        // Re-checked as words come in and seconds pass.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let round = session.offersIntroduction
            if round {
                VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Innan ni börjar").font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) { session.skipIntroduction() }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(DS.Colors.muted)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Göm – mötet fortsätter som vanligt")
                        .accessibilityLabel("Göm")
                    }
                    roundRow
                }
                .padding(compact ? 12 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.card))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var roundRow: some View {
        let knows = memory.enabled && memory.people.contains { !$0.prints.isEmpty }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Vem är här?", systemImage: "person.wave.2")
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                Text(knows ? "Låt alla säga sitt namn – Mindtalk känner igen dem som varit med förut."
                           : "Låt alla säga sitt namn – då står namnen i texten.")
                    .font(.system(size: compact ? 12.5 : 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                if let startRound { startRound() } else { withAnimation(.spring(duration: 0.5, bounce: 0.15)) { session.introduce() } }
            } label: {
                Text("Presentationsrunda").font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.soft)
            .fixedSize()
            .help(compact ? "Öppnar rundan i Mindtalks fönster" : "Låt alla säga sitt namn")
            .accessibilityHint("Alla säger sitt namn, och Mindtalk sätter namnen på rösterna")
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
        MarkIcons { kind in
            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { _ = session.mark(kind) }
        }
    }

    private var field: some View {
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text("Anteckning – en rad per sak")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 7)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.text)
                    .accessibilityLabel("Anteckning")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 30, maxHeight: 92)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
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
                        Text("Fortsätt").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Sätt på mikrofonen igen – mötet fortsätter där det var")
                .accessibilityLabel("Fortsätt mötet")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                round(symbol: "stop.fill", filled: false, help: "Avsluta mötet – du kan ångra i några sekunder",
                      label: "Avsluta mötet") { _ = session.requestStop() }
            } else {
                round(symbol: "pause.fill", filled: false, help: "Pausa – mikrofonen stängs av, och mötet väntar",
                      label: "Pausa mötet") { session.pause() }
                if labelledStop {
                    Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold))
                            Text("Avsluta").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Avsluta mötet – du kan ångra i några sekunder")
                    .accessibilityLabel("Avsluta mötet")
                } else {
                    round(symbol: "stop.fill", filled: true, help: "Avsluta mötet – du kan ångra i några sekunder",
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

/// The three marks as round buttons in their colours — ⌥⌘1, ⌥⌘2, ⌥⌘3. The one
/// under the pointer opens into a pill with its name and key at once — no waiting
/// for a tooltip, and it shows in the panel while another app is in front.
private struct MarkIcons: View {
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
                    MarkPill(kind: kind, key: i + 1, open: hovered == kind || flashed == kind, done: flashed == kind)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
                        hovered = inside ? kind : (hovered == kind ? nil : hovered)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                .help("\(kind.title) – markera det som sägs just nu (⌥⌘\(i + 1))")
                .accessibilityLabel("Markera \(kind.title.lowercased())")
            }
        }
    }
}

/// One mark: a tinted disc with its symbol; open, a pill with the name and key —
/// and for a moment after a click, "Markerat".
struct MarkPill: View {
    let kind: MeetingRecord.Mark.Kind
    let key: Int
    let open: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: done ? "checkmark" : kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                // The symbol in its colour, its marks cut out in the island's dark (the
                // star has none: one layer, all colour).
                .symbolRenderingMode(.palette)
                .foregroundStyle(done || kind == .important ? kind.tint : Color(white: 0.07), kind.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 17)
            if open {
                Text(done ? String(localized: "Markerat") : kind.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                if !done {
                    Text("⌥⌘\(key)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.42))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, open ? 11 : 0)
        .frame(minWidth: 32, minHeight: 32)
        .background(
            Capsule().fill(kind.tint.opacity(done ? 0.26 : open ? 0.18 : 0.11))
        )
        .overlay(
            Capsule().strokeBorder(kind.tint.opacity(open ? 0.5 : 0.22), lineWidth: 0.6)
        )
        .contentShape(Capsule())
        .scaleEffect(done ? 1.04 : 1)
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
                Text("Sammanfatta igen i menyn ⋯ så tas ändringarna med.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in
                        if !note.text.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("–").foregroundStyle(DS.Colors.faint)
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
    }
}

/// Settings → Möten: the summary's language and how long recordings stay.
struct MeetingPrivacyCard: View {
    @ObservedObject private var store = MeetingStore.shared
    @State private var days = MeetingAudio.keepDays
    @State private var asking: Int?

    @State private var summaryLanguage = SummaryLanguage.chosen

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Sammanfattningens språk",
                    detail: String(localized: "Mötets språk skriver anteckningarna på det språk som talades. Välj ett språk för att alltid få dem på det.")) {
                MenuPicker(options: SummaryLanguage.allCases.map { ($0, $0.title) }, selection: $summaryLanguage)
                    .onChange(of: summaryLanguage) { _, new in SummaryLanguage.chosen = new }
            }
            CardDivider()
            CardRow(title: "Spara inspelningar",
                    detail: String(localized: "Texten, dina anteckningar och sammanfattningen sparas alltid. Äldre inspelningar flyttas till papperskorgen.")) {
                MenuPicker(options: MeetingAudio.choices.map { ($0, MeetingAudio.title($0)) },
                           selection: Binding(get: { days }, set: choose))
            }
        }
        .card()
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

/// "Avslutar om 3 s · Ångra" — on ink, in the panel's stop button and the window's
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
                        Text("Avslutar om \(Int(left.rounded(.up))) s")
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
            .help("Fortsätt mötet")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mötet avslutas om några sekunder")
    }
}
