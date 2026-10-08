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
        case .decision: return "checkmark.seal"
        case .task: return "checklist"
        case .important: return "star"
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

/// The sentence to read out at the start. Yours, if you wrote one in Settings.
enum MeetingConsent {
    private static let key = "meetingConsentText"

    static var standard: String {
        String(localized: "Jag spelar in mötet med Mindtalk för att få anteckningar. Allt stannar på min dator. Säg till om du hellre vill att jag inte gör det.")
    }

    static var text: String {
        get {
            let own = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return own.isEmpty ? standard : own
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(t == standard ? nil : t, forKey: key)
        }
    }
}

/// "Innan ni börjar": what a meeting opens with — telling the others it's recorded,
/// and the round where everyone says their name. Both are offered, neither is in
/// the way: the recording runs from the first word whatever you choose.
struct OpeningCard: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var memory = VoiceMemory.shared
    var compact = false
    /// The panel opens the round in the large window (it needs the room's screen).
    var startRound: (() -> Void)? = nil

    private var consent: Bool { session.isRecording && session.record?.informed == nil && !session.consentDismissed }

    var body: some View {
        // Re-checked as words come in and seconds pass.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let round = session.offersIntroduction
            if consent || round {
                VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Innan ni börjar").font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) { session.consentDismissed = true; session.skipIntroduction() }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(DS.Colors.muted)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Göm – mötet fortsätter som vanligt")
                        .accessibilityLabel("Göm")
                    }
                    if consent { consentRow }
                    if consent, round { Divider().opacity(0.6) }
                    if round { roundRow }
                }
                .padding(compact ? 12 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.card))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var consentRow: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Label("Berätta att mötet spelas in", systemImage: "person.2.wave.2")
                .font(.system(size: compact ? 12 : 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
            Text("”\(MeetingConsent.text)”")
                .font(.system(size: compact ? 12.5 : 13.5, design: .serif))
                .italic()
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button {
                withAnimation(.easeOut(duration: 0.25)) { session.informed() }
            } label: {
                Label("Jag har berättat", systemImage: "checkmark").font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.soft)
            .help("Noteras i mötet, så att det syns i efterhand att de andra visste")
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
            .modifier(RoundShortcut(enabled: !compact))
            .help(compact ? "Öppnar rundan i Mindtalks fönster" : "Presentationsrunda (⌘↩)")
            .accessibilityHint("Alla säger sitt namn, och Mindtalk sätter namnen på rösterna")
        }
    }
}

/// ⌘↩ starts the round from the window (not from the panel, where you may be typing elsewhere).
private struct RoundShortcut: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.return, modifiers: .command) } else { content }
    }
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
    @State private var text = ""
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
        .onAppear { text = session.record?.notesText ?? "" }
        .onChange(of: text) { _, new in session.setNotes(new) }
    }

    private var marks: some View {
        MarkIcons { kind in
            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { _ = session.mark(kind) }
        }
    }

    private var field: some View {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Anteckning – en rad per sak")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 7)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
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

/// The three marks as round buttons in their colours — ⌥⌘1, ⌥⌘2, ⌥⌘3.
private struct MarkIcons: View {
    let mark: (MeetingRecord.Mark.Kind) -> Void
    @State private var flashed: MeetingRecord.Mark.Kind?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(MeetingRecord.Mark.Kind.allCases.enumerated()), id: \.element) { i, kind in
                let on = flashed == kind
                Button {
                    mark(kind)
                    AccessibilityNotification.Announcement(String(localized: "Markerat: \(kind.title)")).post()
                    withAnimation(.easeOut(duration: 0.15)) { flashed = kind }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if flashed == kind { withAnimation(.easeOut(duration: 0.4)) { flashed = nil } }
                    }
                } label: {
                    Image(systemName: on ? "checkmark" : kind.symbol)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(kind.tint)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(on ? kind.tint.opacity(0.22) : .white.opacity(0.06)))
                        .scaleEffect(on ? 1.08 : 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                .help("\(kind.title) – markera det som sägs just nu (⌥⌘\(i + 1))")
                .accessibilityLabel("Markera \(kind.title.lowercased())")
            }
        }
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

/// Settings → Möten: how long recordings stay, and what you read out at the start.
struct MeetingPrivacyCard: View {
    @ObservedObject private var store = MeetingStore.shared
    @State private var days = MeetingAudio.keepDays
    @State private var asking: Int?
    @State private var consent = MeetingConsent.text

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
            CardDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Att läsa upp när mötet börjar").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if consent != MeetingConsent.standard {
                        Button("Återställ") { consent = MeetingConsent.standard }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }
                Text("Visas när ett möte börjar, tills du trycker ”Jag har berättat”. Det noteras i mötet.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                TextField("", text: $consent, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(2...5)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                    .onChange(of: consent) { _, new in MeetingConsent.text = new }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
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
