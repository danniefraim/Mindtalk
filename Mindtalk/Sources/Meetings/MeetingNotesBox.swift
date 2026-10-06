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
        case .decision: return String(localized: "Beslut")
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

/// "Berätta att mötet spelas in" — until you have, or put it away.
struct ConsentCard: View {
    @ObservedObject var session: MeetingSession
    var compact = false
    @State private var dismissed = false

    var body: some View {
        if session.isRecording, session.record?.informed == nil, !dismissed {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Berätta att mötet spelas in", systemImage: "person.2.wave.2")
                        .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Button { withAnimation(.easeOut(duration: 0.25)) { dismissed = true } } label: {
                        Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(DS.Colors.muted)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Göm – utan att notera att de andra vet")
                }
                Text("”\(MeetingConsent.text)”")
                    .font(.system(size: compact ? 12.5 : 13.5, design: .serif))
                    .italic()
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { session.informed() }
                } label: {
                    Label("Jag har berättat", systemImage: "checkmark")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.soft)
                .help("Noteras i mötet, så att det syns i efterhand att de andra visste")
            }
            .padding(compact ? 12 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.card))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Your notes while the meeting runs, and the three marks.
struct LiveNotesBox: View {
    @ObservedObject var session: MeetingSession
    var compact = false
    @State private var text = ""
    @State private var marked: MeetingRecord.Mark?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Skriv en anteckning – en rad per sak")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.faint)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: compact ? 44 : 40, maxHeight: compact ? 120 : 96)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? DS.Colors.ink.opacity(0.5) : DS.Colors.fieldStroke, lineWidth: 1))
            HStack(spacing: 6) {
                ForEach(MeetingRecord.Mark.Kind.allCases) { kind in
                    MarkButton(kind: kind) {
                        // With a spring, so the label pops in under the words.
                        let made = withAnimation(.spring(duration: 0.35, bounce: 0.35)) { session.mark(kind) }
                        if let mark = made {
                            withAnimation(.easeOut(duration: 0.2)) { marked = mark }
                            let id = mark.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                if marked?.id == id { withAnimation(.easeOut(duration: 0.3)) { marked = nil } }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                if let marked {
                    HStack(spacing: 5) {
                        Text("\(marked.kind.title) \(MeetingView.duration(marked.at))")
                        Button("Ångra") {
                            session.removeMark(marked.id)
                            withAnimation(.easeOut(duration: 0.2)) { self.marked = nil }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colors.muted)
                    .transition(.opacity)
                }
            }
        }
        .onAppear { text = session.record?.notesText ?? "" }
        .onChange(of: text) { _, new in session.setNotes(new) }
    }
}

private struct MarkButton: View {
    let kind: MeetingRecord.Mark.Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(kind.title, systemImage: kind.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(DS.Colors.chip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Markera det som just sades: \(kind.title.lowercased())")
        .accessibilityLabel("Markera \(kind.title.lowercased())")
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

    var body: some View {
        VStack(spacing: 0) {
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
                Label("\(mark.kind.title) \(MeetingView.duration(mark.at))", systemImage: mark.kind.symbol)
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, compact ? 8 : 9)
                    .frame(height: compact ? 22 : 24)
                    .background(Capsule().fill(DS.Colors.chip))
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
