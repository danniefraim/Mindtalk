import AppKit
import SwiftUI

// MARK: - Möten
//
// The page: start a meeting, and the meetings you've had. A meeting opens in the
// same place — live while it's recorded, then as it was saved.
//
// It follows the rest of the app: serif titles, grey cards on paper, ink for
// what you do. Speakers are told apart by a small monogram in quiet colours —
// names are always written in ink. While recording, the bar at the bottom is the
// same black pill as the dictation indicator.

struct MeetingsPage: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    /// The meeting you were reading, kept while you visit other pages.
    @State private var open: UUID? = MeetingsPage.lastOpen
    private static var lastOpen: UUID?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let record = session.record {
                    MeetingView(record: record, pending: session.pending, session: session, width: geo.size.width,
                                edit: .live(session))
                        .transition(.opacity)
                } else if let id = open, let record = store.meetings.first(where: { $0.id == id }) {
                    MeetingView(record: record, pending: [], session: nil, width: geo.size.width,
                                edit: .saved(store, id),
                                back: { withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = nil } })
                        .id(id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                } else {
                    MeetingList(session: session, store: store, voices: voices, dictation: dictation) { id in
                        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = id }
                    }
                    .transition(.opacity)
                }
            }
        }
        // A meeting that just ended stays on screen, now as saved.
        .onChange(of: session.finished) { _, id in if let id { open = id } }
        .onChange(of: open) { _, id in Self.lastOpen = id }
        #if DEBUG
        .onAppear {   // screenshots: `--open-latest [--summarize]`
            guard CommandLine.arguments.contains("--open-latest"), let id = store.meetings.first?.id else { return }
            open = id
            if CommandLine.arguments.contains("--summarize") { MeetingNotes.shared.summarize(id) }
        }
        #endif
    }
}

/// Where edits to a meeting go: the session while recording, the store after.
enum MeetingEdits {
    case live(MeetingSession)
    case saved(MeetingStore, UUID)

    @MainActor func rename(_ title: String) {
        switch self {
        case .live(let s): s.rename(to: title)
        case .saved(let store, let id): store.rename(id, to: title)
        }
    }

    @MainActor func name(_ speaker: Int, _ name: String) {
        switch self {
        case .live(let s): s.name(speaker: speaker, as: name)
        case .saved(let store, let id): store.name(speaker: speaker, in: id, as: name)
        }
    }

    @MainActor func merge(_ speaker: Int, into other: Int) {
        switch self {
        case .live(let s): s.merge(speaker, into: other)
        case .saved(let store, let id): store.merge(speaker, into: other, in: id)
        }
    }

    @MainActor func move(_ range: Range<Int>, to speaker: Int) {
        switch self {
        case .live(let s): s.move(words: range, to: speaker)
        case .saved(let store, let id): store.move(words: range, to: speaker, in: id)
        }
    }
}

// MARK: - The list

private struct MeetingList: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    @ObservedObject private var notes = MeetingNotes.shared
    let open: (UUID) -> Void
    @State private var confirmDelete: MeetingRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Möten",
                       subtitle: "Spela in ett möte i rummet. Mindtalk skriver ned det som sägs och håller isär vem som pratar – allt stannar på din Mac.")
                .staggered(0)
            StartCard(session: session, voices: voices, dictation: dictation).staggered(1)
            if store.meetings.isEmpty {
                EmptyArchive().staggered(2)
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.title) { n, group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(group.title)
                        VStack(spacing: 0) {
                            ForEach(Array(group.meetings.enumerated()), id: \.element.id) { i, record in
                                if i > 0 { CardDivider() }
                                MeetingRow(record: record, writing: notes.writing.contains(record.id)) { open(record.id) }
                                    .contextMenu {
                                        Button("Öppna") { open(record.id) }
                                        Button("Ta bort…", role: .destructive) { confirmDelete = record }
                                    }
                            }
                        }
                        .padding(4)
                        .card()
                    }
                    .staggered(2 + min(n, 3))
                }
            }
        }
        .pageLayout()
        .confirmationDialog("Ta bort mötet?", isPresented: Binding(get: { confirmDelete != nil },
                                                                   set: { if !$0 { confirmDelete = nil } })) {
            Button("Ta bort", role: .destructive) {
                if let id = confirmDelete?.id { withAnimation(.snappy) { store.delete(id) } }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Inspelningen, texten och sammanfattningen tas bort från din Mac och går inte att få tillbaka.")
        }
    }

    /// "I dag", "I går", "Tidigare i veckan", then by month.
    private var groups: [(title: String, meetings: [MeetingRecord])] {
        let calendar = Calendar.current
        var out: [(title: String, meetings: [MeetingRecord])] = []
        for record in store.meetings where record.id != session.record?.id {
            let title: String
            if calendar.isDateInToday(record.date) { title = String(localized: "I dag") }
            else if calendar.isDateInYesterday(record.date) { title = String(localized: "I går") }
            else if let days = calendar.dateComponents([.day], from: record.date, to: Date()).day, days < 7 {
                title = String(localized: "Tidigare i veckan")
            } else {
                let month = record.date.formatted(Date.FormatStyle().month(.wide).year().locale(AppLanguage.locale))
                title = month.prefix(1).uppercased() + month.dropFirst()
            }
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].meetings.append(record) }
            else { out.append((title, [record])) }
        }
        return out
    }
}

/// Start a meeting — or what's needed first, with the way to fix it.
private struct StartCard: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().fill(DS.Colors.ink)
                Circle().fill(DS.Colors.recording).frame(width: 12, height: 12)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Nytt möte").font(.system(size: 17, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Label(note, systemImage: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.muted)
                }
                if let error = session.lastError {
                    Text(error).font(.system(size: 12)).foregroundStyle(DS.Colors.warning)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(24)
        .raised(cornerRadius: 20)
    }

    private var detail: String {
        switch voices.state {
        case .ready:
            return String(localized: "Texten skrivs medan ni pratar, och upp till åtta röster hålls isär. Berätta för de andra att du spelar in.")
        case .downloading:
            return String(localized: "Laddar ned Nemotron 3 från NVIDIA, som håller isär rösterna…")
        case .missing, .failed:
            return String(localized: "För att hålla isär vem som pratar behövs Nemotron 3 från NVIDIA (\(VoiceModels.sizeText)). Laddas ned en gång och fungerar sedan offline.")
        }
    }

    private var note: String? {
        guard voices.state == .ready else { return nil }
        if !MeetingNotes.isAvailable {
            return String(localized: "På din Mac · utan Apple Intelligence blir det text men ingen sammanfattning")
        }
        return String(localized: "På din Mac · \(dictation.engine.modelName) och Apple Intelligence")
    }

    @ViewBuilder private var control: some View {
        switch voices.state {
        case .ready:
            if !dictation.micGranted {
                Button("Tillåt mikrofonen") { dictation.fix(.microphone) }.buttonStyle(.ink)
            } else if !dictation.engine.isInstalled {
                Button("Ladda ned \(dictation.engine.title)") {
                    NotificationCenter.default.post(name: .showPage, object: Page.settings)
                }
                .buttonStyle(.soft)
            } else {
                Button {
                    session.start()
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(DS.Colors.recording).frame(width: 8, height: 8)
                        Text("Starta möte")
                    }
                }
                .buttonStyle(.ink)
                .disabled(dictation.phase != .idle)
                .help("Starta möte (⇧⌘R)")
            }
        case .downloading(let p):
            VStack(alignment: .trailing, spacing: 6) {
                ProgressView(value: p).tint(DS.Colors.ink).frame(width: 140)
                    .accessibilityLabel("Laddar ned Nemotron 3")
                Text(p, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            }
        case .missing:
            Button("Ladda ned \(VoiceModels.sizeText)") { voices.download() }.buttonStyle(.ink)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Button("Försök igen") { voices.download() }.buttonStyle(.soft)
                Text(message).font(.system(size: 11)).foregroundStyle(DS.Colors.warning)
                    .lineLimit(2).frame(maxWidth: 200, alignment: .trailing)
            }
        }
    }
}

/// No meetings yet: a glimpse of what one looks like.
private struct EmptyArchive: View {
    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ghost(width: 220, mark: 0)
                ghost(width: 160, mark: 1).padding(.leading, 34)
                ghost(width: 250, mark: 0)
            }
            .opacity(0.55)
            .accessibilityHidden(true)
            Text("Dina möten hamnar här.")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func ghost(width: CGFloat, mark: Int) -> some View {
        HStack(spacing: 10) {
            Circle().fill(SpeakerMark.fill(mark).opacity(0.5)).frame(width: 22, height: 22)
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.chip).frame(width: width, height: 30)
        }
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let writing: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let cast = record.cast
        Button(action: open) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(record.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                        if !record.finished {
                            Text("Inte klart").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.warning)
                        }
                    }
                    if let lede {
                        Text(lede).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).lineLimit(1)
                    }
                    Text(meta).font(.system(size: 12)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                }
                Spacer(minLength: 12)
                SpeakerStack(cast: cast)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.faint)
                    .opacity(hovering ? 1 : 0.5)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.chip.opacity(hovering ? 0.6 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(record.title)
    }

    /// The first sentence of the notes — what the meeting was about.
    private var lede: String? {
        if writing { return String(localized: "Skriver anteckningarna…") }
        guard let overview = record.summary?.overview, !overview.isEmpty else { return nil }
        var first = overview
        overview.enumerateSubstrings(in: overview.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s { first = s.trimmingCharacters(in: .whitespaces) }
            stop = true
        }
        return first
    }

    private var meta: String {
        [MeetingRecord.when(record.date), MeetingView.duration(record.duration)].joined(separator: " · ")
    }
}

// MARK: - Speakers

/// A speaker's mark: their initial — or number, until named — on a quiet colour.
/// Colour is only ever this fill: names are written in ink.
struct SpeakerMark: View {
    let speaker: Int?
    let cast: Cast
    var size: CGFloat = 22

    /// Muted pigments, in the order people first speak; lighter in dark mode.
    private static let pigments: [(light: UInt32, dark: UInt32)] = [
        (0x5B7896, 0x7F9DBB), (0xA6705A, 0xC48F79), (0x6E8F78, 0x8FB09A), (0x86708F, 0xA892B0),
        (0x9C8646, 0xBBA466), (0x5A8A8C, 0x7CAAAC), (0x76706A, 0x98928C), (0x6A6F86, 0x8C91A8),
    ]

    static func fill(_ position: Int) -> Color {
        let p = pigments[position % pigments.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.dark : p.light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    var body: some View {
        ZStack {
            if let speaker, speaker >= 0 {
                Circle().fill(Self.fill(cast.number(of: speaker) - 1))
                Text(label(speaker))
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.onInk)
            } else {
                Circle().strokeBorder(DS.Colors.faint, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
                Text("?").font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.faint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func label(_ speaker: Int) -> String {
        guard cast.isNamed(speaker), let c = cast.name(of: speaker).first else { return "\(cast.number(of: speaker))" }
        return String(c).uppercased()
    }
}

/// Overlapping marks: who took part.
private struct SpeakerStack: View {
    let cast: Cast

    var body: some View {
        HStack(spacing: -6) {
            ForEach(cast.order.prefix(5), id: \.self) { s in
                SpeakerMark(speaker: s, cast: cast, size: 20)
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 2))
            }
            if cast.order.count > 5 {
                Text("+\(cast.order.count - 5)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.muted)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DS.Colors.chip))
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cast.order.map { cast.name(of: $0) }.joined(separator: ", "))
    }
}

/// A speaker's name; click to name them, or to say they're someone else.
private struct SpeakerChip: View {
    let speaker: Int
    let cast: Cast
    let rename: (String) -> Void
    let merge: (Int) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            draft = cast.isNamed(speaker) ? cast.name(of: speaker) : ""
            editing = true
        } label: {
            HStack(spacing: 6) {
                SpeakerMark(speaker: speaker, cast: cast, size: 18)
                Text(cast.name(of: speaker)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading).fixedSize()
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(DS.Colors.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ge talaren ett namn")
        .accessibilityHint("Ge talaren ett namn")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vem är det här?").font(.system(size: 13, weight: .semibold))
                TextField(cast.name(of: speaker), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($focused)
                    .onSubmit(save)
                let others = cast.order.filter { $0 != speaker }
                if !others.isEmpty {
                    Menu("Samma person som…") {
                        ForEach(others, id: \.self) { other in
                            Button(cast.name(of: other)) { editing = false; merge(other) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Två röster som är samma person slås ihop")
                }
                HStack {
                    Spacer()
                    Button("Avbryt") { editing = false }.buttonStyle(.soft)
                    Button("Spara", action: save).buttonStyle(.ink).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .onAppear { focused = true }
        }
    }

    private func save() {
        rename(draft)
        editing = false
    }
}

// MARK: - One meeting

struct MeetingView: View {
    let record: MeetingRecord
    let pending: [MeetingWord]
    /// Set while the meeting is being recorded or finished.
    let session: MeetingSession?
    let width: CGFloat
    let edit: MeetingEdits
    var back: (() -> Void)? = nil

    @ObservedObject private var notes = MeetingNotes.shared
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var tab: Tab = .summary
    /// "Visa i texten" from a source: the turn to scroll to.
    @State private var focusTurn: Int?
    @FocusState private var editingTitle: Bool

    enum Tab: Hashable { case summary, transcript }

    private var live: Bool { session != nil }

    var body: some View {
        let cast = record.cast
        let turns = MeetingText.turns(record.words, pending: pending)
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header(cast)
                ZStack {
                    if live || tab == .transcript {
                        TranscriptView(record: record, turns: turns, cast: cast, session: session, width: width,
                                       edit: edit, focusTurn: $focusTurn)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    } else {
                        SummaryView(record: record, turns: turns, cast: cast, notes: notes, width: width) { at in
                            focusTurn = turns.last { $0.start <= at + 0.05 }?.id
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = .transcript }
                        }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { if MeetingPlayer.shared.meeting == record.id { MeetingPlayer.shared.stop() } }
        .onAppear {
            title = record.title
            #if DEBUG
            if CommandLine.arguments.contains("--meeting-text") { tab = .transcript }
            #endif
        }
        .onChange(of: record.title) { _, t in if !editingTitle { title = t } }
        .confirmationDialog("Ta bort mötet?", isPresented: $confirmDelete) {
            Button("Ta bort", role: .destructive) {
                if case .saved(let store, let id) = edit { back?(); store.delete(id) }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Inspelningen, texten och sammanfattningen tas bort från din Mac och går inte att få tillbaka.")
        }
    }

    // MARK: Header

    private func header(_ cast: Cast) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let back {
                    Button(action: back) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                            Text("Möten").font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(DS.Colors.chip))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Alla möten (⌘[)")
                } else if session?.isRecording == true {
                    HStack(spacing: 7) {
                        Circle().fill(DS.Colors.recording).frame(width: 7, height: 7)
                        Text("Spelar in").font(.system(size: 12.5, weight: .semibold))
                    }
                    .frame(height: 28)
                }
                Spacer()
                actions
            }
            .frame(height: 30)
            TextField("Namnlöst möte", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.pageTitle)
                .lineLimit(1...2)
                .focused($editingTitle)
                .onSubmit(commitTitle)
                .onChange(of: editingTitle) { _, editing in if !editing { commitTitle() } }
                .help("Byt namn på mötet")
            HStack(alignment: .center, spacing: 12) {
                FlowLayout(spacing: 8) {
                    Text(meta).font(.system(size: 13)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                        .padding(.trailing, 4)
                    ForEach(cast.order, id: \.self) { s in
                        SpeakerChip(speaker: s, cast: cast,
                                    rename: { edit.name(s, $0) },
                                    merge: { other in withAnimation(.snappy) { edit.merge(s, into: other) } })
                    }
                }
                Spacer(minLength: 12)
                if !live {
                    PillPicker(options: [(Tab.summary, "Sammanfattning"), (Tab.transcript, "Text")], selection: $tab)
                }
            }
            banner
        }
        .padding(.top, DS.Layout.pageTop - 10)
        .padding(.bottom, 12)
        .pageColumn(width)
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { title = record.title } else { edit.rename(t) }
    }

    private var meta: String {
        let when = MeetingRecord.when(record.date)
        return live ? when : "\(when) · \(Self.duration(record.duration))"
    }

    /// A meeting that didn't get its final pass: say so, and offer it.
    @ViewBuilder private var banner: some View {
        if !live, MeetingSession.shared.phase == .idle, !record.finished || !record.refined, !record.words.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: record.finished ? "text.badge.checkmark" : "exclamationmark.circle")
                    .foregroundStyle(record.finished ? DS.Colors.muted : DS.Colors.warning)
                Text(record.finished
                     ? String(localized: "Texten är den som skrevs live. Lyssna igenom mötet igen för en mer exakt text.")
                     : String(localized: "Mötet avbröts innan det blev klart. Inspelningen finns kvar."))
                    .font(.system(size: 13))
                Spacer()
                Button(record.finished ? "Lyssna igenom" : "Gör klart") {
                    MeetingSession.shared.finishInterrupted(record.id)
                }
                .buttonStyle(.soft)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .card()
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.chip))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(record.words.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help(copyHelp)
            .accessibilityLabel(copyHelp)
            if !live {
                Menu {
                    Button("Kopiera sammanfattningen") { put(MeetingNotes.markdown(record)) }
                        .disabled(record.summary == nil)
                    Button("Kopiera texten") { put(MeetingText.plain(record)) }
                    Button("Spara som…") { export() }
                    Divider()
                    Button("Sammanfatta igen") { notes.summarize(record.id) }
                        .disabled(!MeetingNotes.isAvailable || notes.writing.contains(record.id))
                    Button("Lyssna igenom mötet igen") { MeetingSession.shared.finishInterrupted(record.id) }
                        .disabled(MeetingSession.shared.phase != .idle)
                    Button("Visa inspelningen i Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.audioURL(for: record.id)])
                    }
                    Divider()
                    Button("Ta bort mötet…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.Colors.chip))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mer")
                .accessibilityLabel("Mer")
            }
        }
    }

    private var copyHelp: String {
        !live && tab == .summary && record.summary != nil
            ? String(localized: "Kopiera sammanfattningen (⇧⌘C)") : String(localized: "Kopiera texten (⇧⌘C)")
    }

    private func copy() {
        put(!live && tab == .summary && record.summary != nil ? MeetingNotes.markdown(record) : MeetingText.plain(record))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The notes and the text as a Markdown file.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = MeetingNotes.markdown(record)
        if record.summary != nil { text += "\n---\n\n" + MeetingText.plain(record) + "\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        if let session {
            LiveBar(session: session)
        } else if !record.words.isEmpty {
            ReviewBar(record: record, notes: notes, width: width) {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = .summary }
            }
        }
    }

    // MARK: Shared

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "1 minut 12 sekunder" — for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Paper fading out under a floating bar, so text slides under it rather than being cut.
private struct BottomScrim: View {
    var body: some View {
        LinearGradient(colors: [DS.Colors.paper.opacity(0), DS.Colors.paper], startPoint: .top, endPoint: .bottom)
            .frame(height: 70)
            .allowsHitTesting(false)
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    let record: MeetingRecord
    let turns: [MeetingTurn]
    let cast: Cast
    let session: MeetingSession?
    let width: CGFloat
    let edit: MeetingEdits
    @Binding var focusTurn: Int?
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var atBottom = true
    @State private var consent = true

    private var live: Bool { session != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if live, consent, session?.isRecording == true {
                        Label("Berätta för de andra att mötet spelas in.", systemImage: "person.2.wave.2")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.bottom, 18)
                            .transition(.opacity)
                    }
                    if turns.isEmpty { empty }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        let newSpeaker = i == 0 || turns[i - 1].speaker != turn.speaker
                        let end = i + 1 < turns.count ? turns[i + 1].id : record.words.count
                        TurnRow(turn: turn, cast: cast, showName: newSpeaker, live: live,
                                isLast: i == turns.count - 1,
                                playing: isPlaying(turn, next: i + 1 < turns.count ? turns[i + 1].start : .infinity),
                                focused: focusTurn == turn.id,
                                play: live ? nil : { player.play(record.id, from: turn.start) },
                                move: turn.id < end && turn.pending.isEmpty
                                    ? { speaker in withAnimation(.snappy) { edit.move(turn.id..<end, to: speaker) } } : nil)
                            .padding(.top, i == 0 ? 0 : newSpeaker ? 22 : 6)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .pageColumn(width)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, 120, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
            }
            // Follow the conversation — unless you've scrolled up to read.
            .onChange(of: record.words.count + (turns.last?.pending.count ?? 0)) { _, _ in
                guard live, atBottom else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: focusTurn, initial: true) { _, id in
                guard let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(id, anchor: .center) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if focusTurn == id { focusTurn = nil } }
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    BottomScrim()
                    if live, !atBottom, !turns.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
                        } label: {
                            Label("Till nu", systemImage: "arrow.down")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(DS.Colors.onInk)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(Capsule().fill(DS.Colors.ink))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.15), value: atBottom)
            }
        }
        .onAppear {
            guard live else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { withAnimation(.easeOut(duration: 0.4)) { consent = false } }
        }
    }

    private func isPlaying(_ turn: MeetingTurn, next: Double) -> Bool {
        player.meeting == record.id && player.isPlaying && player.time >= turn.start - 0.4 && player.time < next - 0.4
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(DS.Colors.faint)
            if session?.phase == .starting {
                Text("Förbereder…").font(.system(size: 15, weight: .semibold))
                Text("Inspelningen är redan igång – inget går förlorat.")
            } else if live {
                Text("Lyssnar").font(.system(size: 15, weight: .semibold))
                Text("Börja prata, så dyker texten upp här.")
            } else {
                Text("Inget hördes").font(.system(size: 15, weight: .semibold))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DS.Colors.muted)
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

/// One turn: the speaker's mark in the margin, their name, and what they said —
/// what's still being written in grey, ending in Mindtalk's cursor.
private struct TurnRow: View {
    let turn: MeetingTurn
    let cast: Cast
    let showName: Bool
    let live: Bool
    let isLast: Bool
    let playing: Bool
    let focused: Bool
    let play: (() -> Void)?
    let move: ((Int) -> Void)?

    private var speaker: Int? { turn.speaker.flatMap { $0 >= 0 ? $0 : nil } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if showName { SpeakerMark(speaker: speaker, cast: cast, size: 24) } else { Color.clear }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                if showName { nameRow }
                bubble
            }
        }
        .contextMenu {
            Button("Kopiera") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.text, forType: .string)
            }
            if let play { Button("Lyssna härifrån", action: play) }
            if let move, cast.order.count > 1 {
                Menu("Fel talare? Flytta till…") {
                    ForEach(cast.order.filter { $0 != speaker }, id: \.self) { s in
                        Button(cast.name(of: s)) { move(s) }
                    }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var nameRow: some View {
        HStack(spacing: 8) {
            Text(speaker.map { cast.name(of: $0) }
                 ?? (live ? String(localized: "Känner igen rösten…") : String(localized: "Okänd talare")))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(speaker == nil ? DS.Colors.muted : .primary)
            if let play {
                Button(action: play) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 7.5))
                        Text(MeetingView.duration(turn.start)).monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lyssna härifrån")
                .accessibilityLabel("Lyssna från \(MeetingView.spoken(turn.start))")
            } else {
                Text(MeetingView.duration(turn.start))
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DS.Colors.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bubble: some View {
        Group {
            if live && isLast && !turn.pending.isEmpty {
                // The words still arriving, and the cursor blinking after them.
                TimelineView(.periodic(from: .now, by: 0.45)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
                    text(cursor: on)
                }
            } else {
                text(cursor: nil)
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.card))
        .overlay {
            if playing || focused {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(DS.Gradients.accent, lineWidth: 1.5)
                    .shadow(color: DS.Colors.accent.opacity(0.12), radius: 14, y: 6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: playing || focused)
    }

    private func text(cursor: Bool?) -> Text {
        var out = Text(turn.text)
        if !turn.pending.isEmpty {
            let pending = Text(turn.text.isEmpty ? turn.pending : " " + turn.pending).foregroundStyle(DS.Colors.muted)
            out = Text("\(out)\(pending)")
        }
        if let cursor {
            let glyph = Text(" \(Image(nsImage: Self.cursor))")
                .foregroundStyle(DS.Colors.ink.opacity(cursor ? 0.9 : 0.15))
            out = Text("\(out)\(glyph)")
        }
        return out
    }

    /// Mindtalk's I-beam (as in the icon and the HUD), as an image text can hold.
    private static let cursor: NSImage = {
        let image = NSImage(size: NSSize(width: 7, height: 15), flipped: false) { r in
            let stem: CGFloat = 1.6
            NSColor.black.setFill()
            for bar in [NSRect(x: (r.width - stem) / 2, y: 0, width: stem, height: r.height),
                        NSRect(x: 0, y: 0, width: r.width, height: stem),
                        NSRect(x: 0, y: r.height - stem, width: r.width, height: stem)] {
                NSBezierPath(roundedRect: bar, xRadius: stem / 2, yRadius: stem / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

// MARK: - Sammanfattning

/// The notes as a document: what it was about, decisions, tasks to tick off, what's
/// worth remembering — and your questions. Everything with a time you can hear.
private struct SummaryView: View {
    let record: MeetingRecord
    let turns: [MeetingTurn]
    let cast: Cast
    @ObservedObject var notes: MeetingNotes
    let width: CGFloat
    let showInText: (Double) -> Void

    private var writing: Bool { notes.writing.contains(record.id) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    notesSection
                    if let error = notes.failed[record.id] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundStyle(DS.Colors.warning)
                    }
                    if !record.answers.isEmpty || notes.answering.contains(record.id) { answers }
                    Color.clear.frame(height: 1).id("end")
                }
                .pageColumn(width)
                .padding(.top, 14)
            }
            .contentMargins(.bottom, 150, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .bottom) { BottomScrim() }
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
            VStack(alignment: .leading, spacing: 32) {
                Text(summary.overview)
                    .font(.system(size: 20, weight: .regular, design: .serif))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: 620, alignment: .leading)
                    .staggered(0)
                if !summary.decisions.isEmpty {
                    NotesList(title: "Beslut", kind: .decision, items: summary.decisions, record: record, cast: cast,
                              turns: turns, showInText: showInText).staggered(1)
                }
                if !summary.tasks.isEmpty {
                    NotesList(title: "Att göra", kind: .task, items: summary.tasks, record: record, cast: cast,
                              turns: turns, showInText: showInText).staggered(2)
                }
                if !summary.points.isEmpty {
                    NotesList(title: "Värt att komma ihåg", kind: .point, items: summary.points, record: record, cast: cast,
                              turns: turns, showInText: showInText).staggered(3)
                }
                HStack(spacing: 7) {
                    Image(systemName: writing ? "hourglass" : "apple.intelligence").font(.system(size: 12))
                    Text(writing
                         ? String(localized: "Skriver om sammanfattningen…")
                         : String(localized: "Skrivet av Apple Intelligence på din Mac och kan bli fel. Klicka på en tid för att se och höra vad som sades."))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colors.muted)
                .staggered(4)
            }
            .id(summary.created)
        } else if writing {
            WritingPlaceholder()
        } else {
            HStack(spacing: 14) {
                Image(systemName: "apple.intelligence").font(.system(size: 18)).foregroundStyle(DS.Colors.muted)
                Text("Ingen sammanfattning än.").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    notes.summarize(record.id)
                } label: {
                    Label("Sammanfatta", systemImage: "apple.intelligence")
                }
                .buttonStyle(.ink)
                .disabled(record.words.isEmpty)
            }
            .padding(20)
            .card()
        }
    }

    private var unavailable: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.intelligence").font(.system(size: 18)).foregroundStyle(DS.Colors.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sammanfattningar kräver Apple Intelligence").font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(unavailableDetail))
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

    private var unavailableDetail: String {
        switch Polisher.status {
        case .notEnabled: return String(localized: "Slå på Apple Intelligence för att få en sammanfattning. Texten finns under fliken Text.")
        case .notReady: return String(localized: "Apple Intelligence laddas ned. Sammanfatta när den är klar.")
        default: return String(localized: "Den här Macen kan inte köra Apple Intelligence. Texten finns under fliken Text.")
        }
    }

    /// Your questions in ink, the answers on paper — with their sources.
    private var answers: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle("Frågor")
            ForEach(record.answers) { a in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer(minLength: 80)
                        Text(a.question)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(DS.Colors.onInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.ink))
                            .frame(maxWidth: 420, alignment: .trailing)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "apple.intelligence").font(.system(size: 13)).foregroundStyle(DS.Colors.faint)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(a.answer).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                            if !a.sources.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(a.sources, id: \.self) { at in
                                        Receipt(at: at, record: record, cast: cast, turns: turns, showInText: showInText)
                                    }
                                }
                            }
                        }
                    }
                }
                .contextMenu {
                    Button("Kopiera svaret") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(a.answer, forType: .string)
                    }
                    Button("Ta bort frågan", role: .destructive) { notes.forget(a, in: record.id) }
                }
            }
            if notes.answering.contains(record.id) {
                HStack(spacing: 10) {
                    SettlingLine(color: DS.Colors.ink).scaleEffect(0.8)
                    Text("Letar i mötet…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                }
            }
        }
    }
}

/// A section of the notes: its items, each with what kind it is and its source.
private struct NotesList: View {
    enum Kind { case decision, task, point }

    let title: String
    let kind: Kind
    let items: [MeetingSummary.Item]
    let record: MeetingRecord
    let cast: Cast
    let turns: [MeetingTurn]
    let showInText: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .semibold))
                Text("\(items.count)").font(.system(size: 13)).foregroundStyle(DS.Colors.faint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { CardDivider() }
                    row(item)
                }
            }
            .card()
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
    }

    private func row(_ item: MeetingSummary.Item) -> some View {
        let done = item.done == true
        return HStack(alignment: .center, spacing: 12) {
            marker(item, done: done)
            Text(item.text)
                .font(.system(size: 15))
                .strikethrough(done, color: DS.Colors.muted)
                .foregroundStyle(done ? DS.Colors.muted : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let owner = item.owner { OwnerTag(name: owner, cast: cast) }
            if let at = item.at {
                Receipt(at: at, record: record, cast: cast, turns: turns, showInText: showInText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .animation(.easeOut(duration: 0.25), value: done)
    }

    @ViewBuilder private func marker(_ item: MeetingSummary.Item, done: Bool) -> some View {
        switch kind {
        case .decision:
            Image(systemName: "checkmark.circle").font(.system(size: 15)).foregroundStyle(DS.Colors.muted)
                .accessibilityHidden(true)
        case .task:
            Button {
                MeetingStore.shared.setDone(item.id, !done, in: record.id)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(done ? AnyShapeStyle(DS.Colors.ink) : AnyShapeStyle(DS.Colors.faint))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Klar" : "Inte klar")
            .help(done ? "Markera som inte klar" : "Markera som klar")
        case .point:
            Circle().fill(DS.Colors.muted).frame(width: 5, height: 5).frame(width: 16).accessibilityHidden(true)
        }
    }
}

/// Who does it — their mark and name, if they're one of the speakers.
private struct OwnerTag: View {
    let name: String
    let cast: Cast

    var body: some View {
        let speaker = cast.order.first { cast.name(of: $0).caseInsensitiveCompare(name) == .orderedSame }
        HStack(spacing: 5) {
            if let speaker { SpeakerMark(speaker: speaker, cast: cast, size: 18) }
            Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                .lineLimit(1).frame(maxWidth: 120, alignment: .trailing).fixedSize()
        }
    }
}

/// The source: when it was said — play from there. Click for the words.
private struct Receipt: View {
    let at: Double
    let record: MeetingRecord
    let cast: Cast
    let turns: [MeetingTurn]
    let showInText: (Double) -> Void
    @State private var open = false
    @State private var hovering = false

    private var turn: MeetingTurn? { turns.last { $0.start <= at + 0.05 } ?? turns.first }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 7.5))
                Text(MeetingView.duration(at)).monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(hovering ? DS.Colors.onInk : DS.Colors.muted)
            .frame(minWidth: 48)
            .frame(height: 22)
            .padding(.horizontal, 6)
            .background(Capsule().fill(hovering ? DS.Colors.ink : DS.Colors.control))
            .overlay(Capsule().strokeBorder(hovering ? Color.clear : DS.Colors.fieldStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Visa var det sades")
        .accessibilityLabel("Källa, \(MeetingView.spoken(at))")
        .accessibilityHint("Visar och spelar upp det som sades")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                if let turn {
                    let speaker = turn.speaker.flatMap { $0 >= 0 ? $0 : nil }
                    HStack(spacing: 8) {
                        SpeakerMark(speaker: speaker, cast: cast, size: 20)
                        Text(speaker.map { cast.name(of: $0) } ?? String(localized: "Okänd talare"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(MeetingView.duration(turn.start)).font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(DS.Colors.muted)
                    }
                    Text("”\(turn.text)”")
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(3)
                        .lineLimit(10)
                        .textSelection(.enabled)
                        .frame(width: 360, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button {
                        MeetingPlayer.shared.play(record.id, from: at)
                    } label: {
                        Label("Lyssna", systemImage: "play.fill")
                    }
                    .buttonStyle(.ink)
                    Button("Visa i texten") {
                        open = false
                        showInText(at)
                    }
                    .buttonStyle(.soft)
                }
            }
            .padding(18)
        }
    }
}

/// While the notes are being written: the shape of what's coming.
private struct WritingPlaceholder: View {
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 8) {
                SettlingLine(color: DS.Colors.ink).scaleEffect(0.8)
                Text("Skriver sammanfattningen på din Mac…")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Colors.muted)
            VStack(alignment: .leading, spacing: 10) {
                bar(0.95); bar(0.88); bar(0.6)
            }
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 5).fill(DS.Colors.chip).frame(width: 90, height: 12)
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.card).frame(height: 96)
                }
            }
        }
        .opacity(reduceMotion ? 0.7 : sweep ? 0.45 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
        .onAppear { sweep = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skriver sammanfattningen…")
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(DS.Colors.chip)
            .frame(maxWidth: .infinity).frame(height: 16)
            .scaleEffect(x: width, anchor: .leading)
    }
}

// MARK: - Bars

/// While recording: the black pill, as when you dictate — time, sound, stop. Above
/// it, a word when something needs attention.
private struct LiveBar: View {
    @ObservedObject var session: MeetingSession
    @State private var armed = false

    var body: some View {
        VStack(spacing: 10) {
            if let caption {
                Text(caption.text)
                    .font(.system(size: 12.5, weight: caption.warning ? .medium : .regular))
                    .foregroundStyle(caption.warning ? DS.Colors.warning : DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.paper.opacity(0.9)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            pill
        }
        .padding(.bottom, 22)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: session.phase)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: armed)
        .animation(.easeOut(duration: 0.25), value: caption?.text)
    }

    private var caption: (text: String, warning: Bool)? {
        if case .finishing = session.phase { return (String(localized: "Texten blir mer exakt när det är klart."), false) }
        if let w = session.warning { return (w, true) }
        return nil
    }

    private var pill: some View {
        HStack(spacing: 14) {
            switch session.phase {
            case .finishing(let what):
                SettlingLine()
                Text(what).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .accessibilityLabel(what)
            default:
                RecordingDot()
                if let start = session.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(MeetingView.duration(context.date.timeIntervalSince(start)))
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white)
                            .accessibilityLabel("Spelar in, \(MeetingView.spoken(context.date.timeIntervalSince(start)))")
                    }
                }
                LiveWave().frame(width: 96, height: 22).accessibilityHidden(true)
                stopButton
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, session.isRecording ? 7 : 18)
        .frame(height: 46)
        .background(Capsule().fill(Color(white: 0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .fixedSize()
    }

    /// Past the first minute, stopping asks once — a meeting can't be resumed.
    private var stopButton: some View {
        Button {
            let long = Date().timeIntervalSince(session.startedAt ?? Date()) > 60
            if armed || !long {
                session.stop()
            } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                if armed { Text("Avsluta mötet").font(.system(size: 13, weight: .semibold)).fixedSize() }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, armed ? 14 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Avsluta mötet (⇧⌘R)")
        .accessibilityLabel("Avsluta mötet")
    }
}

/// The waveform — observing only the sound level, so nothing else redraws with it.
private struct LiveWave: View {
    @ObservedObject private var meter = LiveMeter.shared
    var body: some View {
        Waveform(levels: meter.levels, gap: 2.5, color: .white)
    }
}

/// A red dot that breathes while recording.
private struct RecordingDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(DS.Colors.recording)
            .frame(width: 9, height: 9)
            .opacity(on || reduceMotion ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Reviewing a saved meeting: playback when listening, and a question field.
private struct ReviewBar: View {
    let record: MeetingRecord
    @ObservedObject var notes: MeetingNotes
    let width: CGFloat
    let asked: () -> Void
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var question = ""
    @FocusState private var focused: Bool

    private var busy: Bool { notes.answering.contains(record.id) }
    private var empty: Bool { question.trimmingCharacters(in: .whitespaces).isEmpty }
    private static let suggestions: [LocalizedStringResource] = ["Vad bestämdes?", "Vem gör vad?", "Vad var det viktigaste?"]

    var body: some View {
        VStack(spacing: 10) {
            if player.meeting == record.id {
                PlayerBar(player: player).transition(.move(edge: .bottom).combined(with: .opacity))
            } else if MeetingNotes.isAvailable, record.answers.isEmpty, empty, !busy {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.key) { s in
                        Button { ask(String(localized: s)) } label: {
                            Text(s)
                                .font(.system(size: 12.5, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Capsule().fill(DS.Colors.field))
                                .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
            if MeetingNotes.isAvailable { field }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: player.meeting)
        .padding(.bottom, 20)
        .pageColumn(width)
    }

    private var field: some View {
        HStack(spacing: 10) {
            TextField("Fråga något om mötet…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { ask(question) }
                .accessibilityLabel("Fråga om mötet")
            if busy {
                SettlingLine(color: DS.Colors.ink).scaleEffect(0.7).frame(width: 40)
            } else {
                Button { ask(question) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(empty ? DS.Colors.faint : DS.Colors.onInk)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(empty ? DS.Colors.chip : DS.Colors.ink))
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .animation(.spring(duration: 0.25, bounce: 0.2), value: empty)
                .help("Skicka frågan (↩)")
                .accessibilityLabel("Skicka frågan")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.08), radius: 12, y: 4))
        .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.fieldStroke),
                                        lineWidth: focused ? 1.5 : 1))
    }

    private func ask(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        notes.ask(q, about: record.id)
        question = ""
        asked()
    }
}

/// Listening: play/pause, ±15 s, where it is (drag to move), speed, close.
private struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.plain).help("15 sekunder bakåt").accessibilityLabel("15 sekunder bakåt")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Colors.onInk)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pausa" : "Spela upp")
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.plain).help("15 sekunder framåt").accessibilityLabel("15 sekunder framåt")
            Text(MeetingView.duration(player.time)).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            GeometryReader { geo in
                let progress = player.duration > 0 ? player.time / player.duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.chip)
                    Capsule().fill(DS.Colors.ink).frame(width: max(4, geo.size.width * progress))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(to: max(0, min(1, v.location.x / geo.size.width)) * player.duration)
                })
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            Text(MeetingView.duration(player.duration)).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : player.rate == 1.5 ? "1,5×" : "2×")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(width: 36, height: 24)
                    .background(Capsule().fill(DS.Colors.chip))
            }
            .buttonStyle(.plain)
            .help("Uppspelningshastighet")
            Button { player.stop() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.muted)
            .help("Sluta lyssna")
            .accessibilityLabel("Sluta lyssna")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.08), radius: 12, y: 4))
        .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
    }
}
