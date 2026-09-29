import AppKit
import SwiftUI

// MARK: - Möten
//
// The page: start a meeting, and the meetings you've had. A meeting opens in
// the same place — live while it's recorded, then as it was saved.

struct MeetingsPage: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    @State private var open: UUID?

    var body: some View {
        ZStack {
            if let record = session.record {
                MeetingView(record: record, pending: session.pending, session: session,
                            rename: { session.rename(to: $0) },
                            nameSpeaker: { session.name(speaker: $0, as: $1) })
                    .transition(.opacity)
            } else if let id = open, let record = store.meetings.first(where: { $0.id == id }) {
                MeetingView(record: record, pending: [], session: nil,
                            rename: { store.rename(id, to: $0) },
                            nameSpeaker: { store.name(speaker: $0, in: id, as: $1) },
                            back: { withAnimation(.snappy) { open = nil } },
                            delete: { withAnimation(.snappy) { open = nil; store.delete(id) } })
                    .transition(.opacity)
            } else {
                MeetingList(session: session, store: store, voices: voices, dictation: dictation) { id in
                    withAnimation(.snappy) { open = id }
                }
                .transition(.opacity)
            }
        }
        // A meeting that just ended stays on screen, now as saved.
        .onChange(of: session.finished) { _, id in if let id { open = id } }
        #if DEBUG
        .onAppear {   // screenshots: `--open-latest [--summarize]`
            guard CommandLine.arguments.contains("--open-latest"), let id = store.meetings.first?.id else { return }
            open = id
            if CommandLine.arguments.contains("--summarize") { MeetingNotes.shared.summarize(id) }
        }
        #endif
    }
}

// MARK: - The list

private struct MeetingList: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    let open: (UUID) -> Void
    @State private var confirmDelete: MeetingRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Möten",
                       subtitle: "Spela in ett möte i rummet. Mindtalk skriver ut vad som sägs och känner igen vem som pratar – allt stannar på din Mac.")
                .staggered(0)
            startCard.staggered(1)
            if !store.meetings.isEmpty {
                SectionTitle("Tidigare möten").staggered(2)
                VStack(spacing: 0) {
                    ForEach(Array(store.meetings.enumerated()), id: \.element.id) { i, record in
                        if i > 0 { CardDivider() }
                        MeetingRow(record: record) { open(record.id) }
                            .contextMenu {
                                Button("Öppna") { open(record.id) }
                                Button("Radera…", role: .destructive) { confirmDelete = record }
                            }
                    }
                }
                .card()
                .staggered(2)
            }
        }
        .pageLayout()
        .confirmationDialog("Radera mötet?", isPresented: Binding(get: { confirmDelete != nil },
                                                                  set: { if !$0 { confirmDelete = nil } })) {
            Button("Radera", role: .destructive) {
                if let id = confirmDelete?.id { withAnimation(.snappy) { store.delete(id) } }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Texten och inspelningen tas bort från din Mac och går inte att få tillbaka.")
        }
    }

    private var startCard: some View {
        HStack(spacing: 18) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 46, height: 46)
                .background(Circle().fill(DS.Colors.chip))
            VStack(alignment: .leading, spacing: 4) {
                Text("Nytt möte").font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = session.lastError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(22)
        .card()
    }

    private var detail: String {
        switch voices.state {
        case .ready:
            return String(localized: "Skrivs ut med \(dictation.engine.modelName) medan ni pratar. Upp till åtta personer hålls isär.")
        case .downloading:
            return String(localized: "Hämtar NVIDIA:s modell Nemotron 3, som håller isär rösterna…")
        case .missing, .failed:
            return String(localized: "För att hålla isär vem som pratar behövs NVIDIA:s modell Nemotron 3 (\(VoiceModels.sizeText)). Den hämtas en gång och fungerar sedan offline.")
        }
    }

    @ViewBuilder private var control: some View {
        switch voices.state {
        case .ready:
            Button {
                session.start()
            } label: {
                Label("Starta", systemImage: "record.circle")
            }
            .buttonStyle(.ink)
            .disabled(dictation.phase != .idle || !dictation.engine.isInstalled)
        case .downloading(let p):
            VStack(alignment: .trailing, spacing: 6) {
                ProgressView(value: p).frame(width: 120)
                Text("\(Int(p * 100)) %").font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            }
        case .missing:
            Button("Hämta") { voices.download() }.buttonStyle(.soft)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Button("Försök igen") { voices.download() }.buttonStyle(.soft)
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(summary).font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                }
                Spacer(minLength: 12)
                SpeakerDots(record: record)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.faint)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(DS.Colors.chip.opacity(hovering ? 0.5 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var summary: String {
        let when = record.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale))
        let people = record.speakers.count
        return [when, MeetingView.duration(record.duration),
                people > 0 ? String(localized: "\(people) talare") : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A dot per speaker, in their colours.
private struct SpeakerDots: View {
    let record: MeetingRecord
    var body: some View {
        HStack(spacing: -4) {
            ForEach(record.speakers.prefix(6), id: \.self) { s in
                Circle().fill(MeetingView.color(for: s, in: record))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 2))
            }
        }
    }
}

// MARK: - One meeting

struct MeetingView: View {
    let record: MeetingRecord
    let pending: [MeetingWord]
    /// Set while the meeting is being recorded or finished.
    let session: MeetingSession?
    let rename: (String) -> Void
    let nameSpeaker: (Int, String) -> Void
    var back: (() -> Void)? = nil
    var delete: (() -> Void)? = nil

    @ObservedObject private var notes = MeetingNotes.shared
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var tab: Tab = .summary
    @FocusState private var editingTitle: Bool

    enum Tab: Hashable { case summary, transcript }

    private var turns: [MeetingTurn] { MeetingText.turns(record.words, pending: pending) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if session == nil { tabs }
            if session != nil || tab == .transcript {
                transcript
            } else {
                SummaryView(record: record, turns: turns, notes: notes, player: player)
            }
            if let session {
                LiveBar(session: session)
            } else if MeetingNotes.isAvailable, !record.words.isEmpty {
                AskBar(record: record, notes: notes) { withAnimation(.snappy) { tab = .summary } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { if player.meeting == record.id { player.stop() } }
        .onAppear { title = record.title }
        .onChange(of: record.title) { _, t in if !editingTitle { title = t } }
        .confirmationDialog("Radera mötet?", isPresented: $confirmDelete) {
            Button("Radera", role: .destructive) { delete?() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Texten och inspelningen tas bort från din Mac och går inte att få tillbaka.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(DS.Colors.chip))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Alla möten")
                    .accessibilityLabel("Alla möten")
                }
                TextField("Namnlöst möte", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .focused($editingTitle)
                    .onSubmit { rename(title) }
                    .onChange(of: editingTitle) { _, editing in if !editing { rename(title) } }
                Spacer(minLength: 12)
                if session == nil { actions }
            }
            HStack(spacing: 10) {
                Text(meta).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                if !record.speakers.isEmpty {
                    Rectangle().fill(DS.Colors.divider).frame(width: 1, height: 14)
                    ForEach(record.speakers, id: \.self) { s in
                        SpeakerChip(name: record.name(of: s), color: Self.color(for: s, in: record)) { nameSpeaker(s, $0) }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Layout.pageHorizontal)
        .padding(.top, 34)
        .padding(.bottom, 14)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var meta: String {
        let when = record.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale))
        return session == nil ? "\(when) · \(Self.duration(record.duration))" : when
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MeetingText.plain(record), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Kopierat" : "Kopiera texten", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.soft)
            .disabled(record.words.isEmpty)
            Menu {
                Button("Visa inspelningen i Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.audioURL(for: record.id)])
                }
                Divider()
                Button("Radera mötet…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
    }

    private var tabs: some View {
        HStack(spacing: 12) {
            PillPicker(options: [(Tab.summary, "Sammanfattning"), (Tab.transcript, "Text")], selection: $tab)
            Spacer()
            if player.meeting == record.id { PlayerChip(player: player) }
        }
        .padding(.horizontal, DS.Layout.pageHorizontal)
        .padding(.bottom, 6)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if turns.isEmpty { empty }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        let showName = i == 0 || turns[i - 1].speaker != turn.speaker
                        let next = i + 1 < turns.count ? turns[i + 1].start : .infinity
                        TurnView(turn: turn, name: name(of: turn.speaker), color: color(of: turn.speaker),
                                 showName: showName,
                                 playing: player.meeting == record.id && player.isPlaying
                                     && player.time >= turn.start - 0.4 && player.time < next - 0.4,
                                 play: session == nil ? { player.play(record.id, from: turn.start) } : nil)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, DS.Layout.pageHorizontal)
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: record.words.count + pending.count) { _, _ in
                guard session != nil else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(DS.Colors.faint)
            if session?.phase == .starting {
                Text("Förbereder…").font(.system(size: 15, weight: .semibold))
                Text("Inspelningen är redan igång – inget går förlorat.")
            } else if session != nil {
                Text("Lyssnar").font(.system(size: 15, weight: .semibold))
                Text("Börja prata, så dyker texten upp här.")
            } else {
                Text("Inget sades").font(.system(size: 15, weight: .semibold))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DS.Colors.muted)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func name(of speaker: Int?) -> String? {
        guard let speaker, speaker >= 0 else { return nil }
        return record.name(of: speaker)
    }

    private func color(of speaker: Int?) -> Color {
        guard let speaker, speaker >= 0 else { return DS.Colors.faint }
        return Self.color(for: speaker, in: record)
    }

    // MARK: Shared

    static let palette: [Color] = [
        Color(red: 0.23, green: 0.47, blue: 0.86), Color(red: 0.90, green: 0.50, blue: 0.13),
        Color(red: 0.20, green: 0.62, blue: 0.38), Color(red: 0.58, green: 0.38, blue: 0.86),
        Color(red: 0.86, green: 0.31, blue: 0.52), Color(red: 0.12, green: 0.60, blue: 0.66),
        Color(red: 0.64, green: 0.46, blue: 0.26), Color(red: 0.40, green: 0.42, blue: 0.82),
    ]

    /// Colours follow the order people first spoke, so the first voice is always blue.
    static func color(for speaker: Int, in record: MeetingRecord) -> Color {
        palette[(record.speakers.firstIndex(of: speaker) ?? speaker) % palette.count]
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One turn: who, when, and what they said — what's still being written in grey.
private struct TurnView: View {
    let turn: MeetingTurn
    let name: String?
    let color: Color
    let showName: Bool
    var playing = false
    /// Saved meetings: hear this turn.
    var play: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showName {
                HStack(spacing: 7) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(name ?? String(localized: "Lyssnar…"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(name == nil ? DS.Colors.faint : color)
                    if let play {
                        Button(action: play) {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill").font(.system(size: 8))
                                Text(MeetingView.duration(turn.start)).monospacedDigit()
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.faint)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Lyssna härifrån")
                    } else {
                        Text(MeetingView.duration(turn.start))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(DS.Colors.faint)
                    }
                }
                .transition(.opacity)
            }
            text
                .font(.system(size: 15))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.card))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 3).padding(.vertical, 10)
                }
                .overlay {
                    if playing {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color, lineWidth: 1.5)
                    }
                }
                .contextMenu {
                    if let play { Button("Lyssna härifrån", action: play) }
                }
        }
        .animation(.easeOut(duration: 0.2), value: turn)
    }

    private var text: Text {
        let settled = Text(turn.text)
        guard !turn.pending.isEmpty else { return settled }
        let pending = Text(turn.text.isEmpty ? turn.pending : " " + turn.pending).foregroundStyle(DS.Colors.faint)
        return Text("\(settled)\(pending)")
    }
}

/// A speaker's name; click to give them one.
private struct SpeakerChip: View {
    let name: String
    let color: Color
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = name
            editing = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.Colors.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Klicka för att ge talaren ett namn")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Vem är det här?").font(.system(size: 13, weight: .semibold))
                TextField("Namn", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button("Avbryt") { editing = false }.buttonStyle(.soft)
                    Button("Spara", action: save).buttonStyle(.ink).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    private func save() {
        rename(draft)
        editing = false
    }
}

/// While recording: the time, the sound, a reminder to tell the room, and Stop.
private struct LiveBar: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        HStack(spacing: 14) {
            switch session.phase {
            case .finishing(let what):
                ProgressView().controlSize(.small)
                Text(what).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Texten blir skarpare när det är klart.").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
            default:
                RecordingDot()
                if let start = session.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(MeetingView.duration(context.date.timeIntervalSince(start)))
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    }
                }
                Waveform(levels: Array(session.levels.suffix(18)), gap: 2.5, color: .primary)
                    .frame(width: 60, height: 18)
                Spacer(minLength: 12)
                Text("Berätta för de andra att mötet spelas in.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    .lineLimit(1)
                Button {
                    session.stop()
                } label: {
                    Label("Avsluta mötet", systemImage: "stop.fill")
                }
                .buttonStyle(.ink)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.10), radius: 14, y: 4))
        .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
        .padding(.horizontal, DS.Layout.pageHorizontal)
        .padding(.bottom, 20)
        .frame(maxWidth: 900)
    }
}

/// A red dot that breathes while recording.
private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(DS.Colors.recording)
            .frame(width: 9, height: 9)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityLabel("Spelar in")
    }
}

// MARK: - Sammanfattning

/// The notes: what it was about, decisions, tasks, what's worth remembering —
/// and your questions. Everything with a source you can listen to.
private struct SummaryView: View {
    let record: MeetingRecord
    let turns: [MeetingTurn]
    @ObservedObject var notes: MeetingNotes
    @ObservedObject var player: MeetingPlayer

    private var writing: Bool { notes.writing.contains(record.id) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    notesSection
                    if let error = notes.failed[record.id] {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
                    }
                    if !record.answers.isEmpty || notes.answering.contains(record.id) { answers }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, DS.Layout.pageHorizontal)
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: record.answers.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: notes.answering.contains(record.id)) { _, busy in
                if busy { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var notesSection: some View {
        if !MeetingNotes.isAvailable {
            unavailable
        } else if let summary = record.summary {
            VStack(alignment: .leading, spacing: 26) {
                Text(summary.overview)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                if !summary.decisions.isEmpty {
                    NotesList(title: "Beslut", icon: "checkmark.seal", items: summary.decisions, record: record, turns: turns)
                }
                if !summary.tasks.isEmpty {
                    NotesList(title: "Att göra", icon: "checklist", items: summary.tasks, record: record, turns: turns)
                }
                if !summary.points.isEmpty {
                    NotesList(title: "Värt att komma ihåg", icon: "lightbulb", items: summary.points, record: record, turns: turns)
                }
                HStack(spacing: 10) {
                    Image(systemName: "apple.intelligence").foregroundStyle(DS.Colors.faint)
                    Text("Skrivet av Apple Intelligence på din Mac. Klicka på en källa för att höra vad som faktiskt sades.")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    Spacer()
                    if writing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Skriv om") { notes.summarize(record.id) }.buttonStyle(.soft)
                    }
                }
            }
            .transition(.opacity)
        } else if writing {
            WritingPlaceholder()
        } else {
            HStack(spacing: 14) {
                Image(systemName: "apple.intelligence").font(.system(size: 18)).foregroundStyle(DS.Colors.muted)
                Text("Ingen sammanfattning än.").font(.system(size: 14))
                Spacer()
                Button("Sammanfatta") { notes.summarize(record.id) }.buttonStyle(.ink).disabled(record.words.isEmpty)
            }
            .padding(20)
            .card()
        }
    }

    private var unavailable: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.intelligence").font(.system(size: 18)).foregroundStyle(DS.Colors.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sammanfattningar kräver Apple Intelligence").font(.system(size: 14, weight: .semibold))
                Text("Allt skrivs på din Mac. Texten finns under fliken Text.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            }
            Spacer()
            if Polisher.status == .notEnabled {
                Button("Slå på") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
                .buttonStyle(.soft)
            }
        }
        .padding(20)
        .card()
    }

    private var answers: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Frågor", systemImage: "bubble.left.and.text.bubble.right")
                .font(.system(size: 15, weight: .semibold))
            ForEach(record.answers) { a in
                VStack(alignment: .leading, spacing: 8) {
                    Text(a.question).font(.system(size: 14, weight: .semibold))
                    Text(a.answer).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                    if !a.sources.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(a.sources, id: \.self) { at in Receipt(at: at, record: record, turns: turns) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .contextMenu {
                    Button("Ta bort frågan", role: .destructive) { notes.forget(a, in: record.id) }
                }
            }
            if notes.answering.contains(record.id) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Letar i mötet…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                }
            }
        }
    }
}

/// A heading and its items, each with its source.
private struct NotesList: View {
    let title: String
    let icon: String
    let items: [MeetingSummary.Item]
    let record: MeetingRecord
    let turns: [MeetingTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { CardDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle().fill(DS.Colors.faint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0.height + 1 }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.text).font(.system(size: 14)).textSelection(.enabled)
                            if let owner = item.owner { OwnerTag(name: owner, record: record) }
                        }
                        Spacer(minLength: 12)
                        if let at = item.at { Receipt(at: at, record: record, turns: turns) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            }
            .card()
        }
    }
}

/// Who does it — in their colour, if they're one of the speakers.
private struct OwnerTag: View {
    let name: String
    let record: MeetingRecord

    var body: some View {
        let speaker = record.speakers.first { record.name(of: $0).caseInsensitiveCompare(name) == .orderedSame }
        let color = speaker.map { MeetingView.color(for: $0, in: record) } ?? DS.Colors.muted
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.chip))
    }
}

/// The source: when it was said. Click for the words and to hear them.
private struct Receipt: View {
    let at: Double
    let record: MeetingRecord
    let turns: [MeetingTurn]
    @State private var open = false

    private var turn: MeetingTurn? { turns.last { $0.start <= at + 0.05 } ?? turns.first }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "quote.bubble").font(.system(size: 10))
                Text(MeetingView.duration(at)).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.Colors.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(DS.Colors.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Visa var det sades")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                if let turn {
                    let speaker = turn.speaker.flatMap { $0 >= 0 ? $0 : nil }
                    HStack(spacing: 7) {
                        Circle().fill(speaker.map { MeetingView.color(for: $0, in: record) } ?? DS.Colors.faint)
                            .frame(width: 7, height: 7)
                        Text(speaker.map { record.name(of: $0) } ?? "").font(.system(size: 12, weight: .semibold))
                        Text(MeetingView.duration(turn.start)).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(DS.Colors.faint)
                    }
                    Text(turn.text)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .lineLimit(10)
                        .textSelection(.enabled)
                        .frame(width: 340, alignment: .leading)
                }
                Button {
                    MeetingPlayer.shared.play(record.id, from: at)
                } label: {
                    Label("Lyssna", systemImage: "play.fill")
                }
                .buttonStyle(.ink)
            }
            .padding(16)
        }
    }
}

/// While the notes are being written.
private struct WritingPlaceholder: View {
    @State private var phase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                Text("Skriver sammanfattningen på din Mac…")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Colors.muted)
            ForEach([0.95, 0.8, 0.9, 0.55], id: \.self) { w in
                RoundedRectangle(cornerRadius: 5).fill(DS.Colors.chip)
                    .frame(maxWidth: .infinity).frame(height: 12)
                    .scaleEffect(x: w, anchor: .leading)
                    .opacity(phase ? 0.45 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

/// Ask anything about the meeting.
private struct AskBar: View {
    let record: MeetingRecord
    @ObservedObject var notes: MeetingNotes
    let asked: () -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    private var busy: Bool { notes.answering.contains(record.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").foregroundStyle(DS.Colors.muted)
            TextField("Fråga något om mötet…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(send)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Colors.onInk)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(DS.Colors.ink))
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(question.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)
                .accessibilityLabel("Fråga")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.10), radius: 14, y: 4))
        .overlay(Capsule().strokeBorder(focused ? DS.Colors.ink.opacity(0.5) : DS.Colors.fieldStroke, lineWidth: 1))
        .padding(.horizontal, DS.Layout.pageHorizontal)
        .padding(.bottom, 20)
        .frame(maxWidth: 900)
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        notes.ask(q, about: record.id)
        question = ""
        asked()
    }
}

/// Playing: pause, where it is, stop.
private struct PlayerChip: View {
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 8) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
            }
            .buttonStyle(.plain)
            Text("\(MeetingView.duration(player.time)) / \(MeetingView.duration(player.duration))")
                .font(.system(size: 12)).monospacedDigit()
            Button { player.stop() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Colors.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(DS.Colors.chip))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
