import AppKit
import SwiftUI

// MARK: - Möten
//
// The page: start a meeting, and the meetings you've had. A meeting opens in the
// same place — live while it's recorded, then as it was saved.
//
// It follows the rest of the app: serif titles on paper, ink for what you do. The
// text reads as a document: each speaker a thin line in their own quiet colour,
// their name above in it. While recording, one dark island at the bottom holds the
// time, your note, the marks and stop — dark like the dictation indicator.

struct MeetingsPage: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var voices: VoiceModels
    @ObservedObject var dictation: Dictation
    /// The meeting you were reading, kept while you visit other pages.
    @State private var open: UUID? = MeetingsPage.lastOpen
    static var lastOpen: UUID?
    /// Opened from a search hit or an answer's source: the moment to show.
    static var focusAt: Double?

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
                    MeetingList(session: session, store: store, voices: voices, dictation: dictation) { id, at in
                        MeetingsPage.focusAt = at
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

    @MainActor func notes(_ text: String) {
        switch self {
        case .live(let s): s.setNotes(text)
        case .saved(let store, let id): store.setNotes(text, in: id)
        }
    }

    @MainActor func removeMark(_ mark: UUID) {
        switch self {
        case .live(let s): s.removeMark(mark)
        case .saved(let store, let id): store.removeMark(mark, in: id)
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
    @ObservedObject private var library = MeetingLibrary.shared
    @ObservedObject private var folders = MeetingFolders.shared
    let open: (UUID, Double?) -> Void
    @State private var confirmDelete: MeetingRecord?
    @State private var query = ""
    /// What the search found — a moment after you stop typing.
    @State private var matches: [MeetingMatch] = []

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canAsk: Bool { MeetingNotes.isAvailable && store.meetings.contains { !$0.words.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Möten",
                       subtitle: "Spela in ett möte i rummet. Mindtalk skriver ned det som sägs och håller isär vem som pratar.")
                .staggered(0)
            StartCard(session: session, voices: voices, dictation: dictation).staggered(1)
            if store.meetings.isEmpty {
                EmptyArchive().staggered(2)
            } else {
                LibrarySearchField(query: $query, folder: folders.folder(folders.selected)?.name).staggered(2)
                FolderBar(folders: folders, store: store).staggered(2)
                LibraryAnswers(library: library, open: open)
            }
            if searching {
                SearchResults(matches: matches, query: query, open: open)
            } else if !store.meetings.isEmpty, groups.isEmpty, let folder = folders.folder(folders.selected) {
                // A folder with nothing in it yet: how meetings get there.
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 26, weight: .light)).foregroundStyle(DS.Colors.faint)
                    Text("Inga möten i \(folder.name) än").font(.system(size: 14, weight: .semibold))
                    Text("Dra hit ett möte från Alla, eller starta ett möte medan mappen är vald – då hamnar det här.")
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .transition(.opacity)
            } else if !store.meetings.isEmpty {
                ForEach(Array(groups.enumerated()), id: \.element.title) { n, group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(group.title)
                        VStack(spacing: 0) {
                            ForEach(Array(group.meetings.enumerated()), id: \.element.id) { i, record in
                                if i > 0 { CardDivider() }
                                MeetingRow(record: record, writing: notes.writing.contains(record.id),
                                           folder: folders.selected == nil ? folders.folder(of: record)?.name : nil) {
                                    open(record.id, nil)
                                }
                                // Dragged onto a folder in the row above: into it.
                                .draggable(record.id.uuidString) {
                                    Label(record.title, systemImage: "doc.text")
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.horizontal, 12)
                                        .frame(height: 30)
                                        .background(Capsule().fill(DS.Colors.paper))
                                        .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                                }
                                .contextMenu {
                                    Button("Öppna") { open(record.id, nil) }
                                    MoveToFolderMenu(record: record)
                                    Divider()
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
        .padding(.bottom, canAsk ? 90 : 0)
        .task(id: query + "\(store.meetings.count)" + (folders.selected?.uuidString ?? "")) {
            guard searching else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            matches = MeetingSearch.find(query, in: shown.filter { $0.id != session.record?.id })
        }
        #if DEBUG
        .onAppear {   // screenshots: `--search-query "ord"`, `--ask-query "fråga"`
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--search-query"), i + 1 < args.count { query = args[i + 1] }
            if let i = args.firstIndex(of: "--ask-query"), i + 1 < args.count { library.ask(args[i + 1]) }
        }
        #endif
        .pageLayout()
        .overlay(alignment: .bottom) { if canAsk { LibraryAskBar(library: library) } }
        .animation(.easeOut(duration: 0.2), value: searching)
        .animation(.spring(duration: 0.35, bounce: 0.12), value: folders.selected)
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

    /// The meetings of the folder chosen — all of them under "Alla".
    private var shown: [MeetingRecord] {
        guard let folder = folders.selected else { return store.meetings }
        return store.meetings.filter { $0.folder == folder }
    }

    /// "I dag", "I går", "Tidigare i veckan", then by month.
    private var groups: [(title: String, meetings: [MeetingRecord])] {
        let calendar = Calendar.current
        var out: [(title: String, meetings: [MeetingRecord])] = []
        for record in shown where record.id != session.record?.id {
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
                    Label(note, systemImage: "cpu")
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
            return String(localized: "Texten skrivs medan ni pratar, och rösterna hålls isär – bäst med upp till fem personer nära Macen.")
        case .downloading:
            return String(localized: "Laddar ned Nemotron 3 från NVIDIA, som håller isär rösterna…")
        case .missing, .failed:
            return String(localized: "För att hålla isär vem som pratar behövs Nemotron 3 från NVIDIA (\(VoiceModels.sizeText)). Laddas ned en gång och fungerar sedan offline.")
        }
    }

    private var note: String? {
        guard voices.state == .ready else { return nil }
        if !MeetingNotes.isAvailable {
            return String(localized: "Utan Apple Intelligence blir det text men ingen sammanfattning")
        }
        if BetterNotes.shared.isActive {
            return String(localized: "\(dictation.engine.modelName) och Gemma 4")
        }
        return String(localized: "\(dictation.engine.modelName) och Apple Intelligence")
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
                // One start: the meeting begins with the round ("Vem är här?"), which
                // can be skipped.
                Button {
                    session.start(introducing: true)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(DS.Colors.recording).frame(width: 8, height: 8)
                        Text("Starta möte")
                    }
                }
                .buttonStyle(.ink)
                .help("Starta möte (⇧⌘R) – börjar med en presentationsrunda som går att hoppa över")
                .accessibilityHint("Mötet börjar med en presentationsrunda som går att hoppa över")
                .disabled(dictation.phase != .idle)
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
    /// Under "Alla": the folder it's in, beside its time.
    var folder: String? = nil
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
                if record.words.isEmpty {
                    SpeakerStack(cast: cast)
                } else {
                    MeetingRibbon(record: record, cast: cast, segments: MeetingText.segments(record.words), compact: true)
                        .frame(width: 96)
                }
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
        ([MeetingRecord.when(record.date), MeetingView.duration(record.duration)] + (folder.map { [$0] } ?? []))
            .joined(separator: " · ")
    }
}

// MARK: - Speakers

/// A speaker's mark: their initial — or number, until named — on a quiet colour.
/// The same colour marks them everywhere: the line beside their words, their name,
/// the timeline.
struct SpeakerMark: View {
    let speaker: Int?
    let cast: Cast
    var size: CGFloat = 22

    /// Muted pigments, in the order people first speak; lighter in dark mode.
    private static let pigments: [(light: UInt32, dark: UInt32)] = [
        (0x5B7896, 0x7F9DBB), (0xA6705A, 0xC48F79), (0x6E8F78, 0x8FB09A), (0x86708F, 0xA892B0),
        (0x9C8646, 0xBBA466), (0x5A8A8C, 0x7CAAAC), (0x76706A, 0x98928C), (0x6A6F86, 0x8C91A8),
    ]

    /// A speaker's colour, the same wherever they appear; none known yet: faint.
    static func color(of speaker: Int?, in cast: Cast) -> Color {
        guard let speaker, speaker >= 0 else { return DS.Colors.faint }
        return fill(cast.number(of: speaker) - 1)
    }

    /// Their colour for a name written in it: a shade deeper on light paper, so it
    /// reads as well as the text (4.5:1).
    static func ink(of speaker: Int?, in cast: Cast) -> Color {
        guard let speaker, speaker >= 0 else { return DS.Colors.muted }
        let p = pigments[(cast.number(of: speaker) - 1) % pigments.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = dark ? p.dark : p.light
            let k: CGFloat = dark ? 1 : 0.72
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255 * k, green: CGFloat((hex >> 8) & 0xFF) / 255 * k,
                           blue: CGFloat(hex & 0xFF) / 255 * k, alpha: 1)
        })
    }

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
struct SpeakerChip: View {
    let speaker: Int
    let cast: Cast
    /// Named by Mindtalk from a voice you named before.
    var recognized = false
    /// A capsule in the header, or the name above what they said in the text.
    var style: Style = .chip
    let rename: (String) -> Void
    let merge: (Int) -> Void
    @State private var editing = false

    enum Style { case chip, name }
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            draft = cast.isNamed(speaker) ? cast.name(of: speaker) : ""
            editing = true
        } label: {
            switch style {
            case .chip:
                HStack(spacing: 6) {
                    VoiceBadge(speaker: speaker, cast: cast, size: 18)
                    Text(cast.name(of: speaker)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading).fixedSize()
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.Colors.chip))
                .contentShape(Capsule())
                .accessibilityLabel(recognized ? String(localized: "\(cast.name(of: speaker)), igenkänd röst") : cast.name(of: speaker))
            case .name:
                Text(cast.name(of: speaker))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpeakerMark.ink(of: speaker, in: cast))
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(recognized ? "Mindtalk kände igen rösten – klicka för att ändra" : "Ge talaren ett namn")
        .accessibilityHint("Ge talaren ett namn")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vem är det här?").font(.system(size: 13, weight: .semibold))
                if recognized {
                    // A wrong guess, undone: the name goes, this meeting only — the voice
                    // Mindtalk remembers stays as it is.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mindtalk kände igen rösten.").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        Button { editing = false; rename("") } label: {
                            Label("Fel person? Ta bort namnet", systemImage: "xmark")
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Namnet tas bort i det här mötet. Rösten Mindtalk känner igen ändras inte.")
                    }
                }
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

/// "Vem är här?" while the round lasts, the meeting after — watching the session
/// itself, so the meeting is there the moment the round ends, not at the next word.
private struct IntroductionGate<Meeting: View, Bar: View>: View {
    @ObservedObject var session: MeetingSession
    @ViewBuilder let meeting: () -> Meeting
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        ZStack(alignment: .bottom) {
            if session.introducing {
                // The round fills the room; the recording pill floats at its foot.
                VoiceScanner(session: session)
                    .transition(.opacity)
                bar()
            } else {
                // The meeting: the text above, your notes and the pill below it — the
                // text ends where they begin, nothing slides in behind them.
                VStack(spacing: 0) {
                    meeting().frame(maxHeight: .infinity)
                    bar()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: session.introducing)
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
    @ObservedObject private var epoch = WindowEpoch.shared
    /// For "Fortsätt mötet" on a saved meeting: whether it can, and why not.
    @ObservedObject private var recorder = MeetingSession.shared
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var confirmRemoveAudio = false
    @State private var copied = false
    @State private var tab: Tab = .summary
    /// "Visa i texten" from a source: the turn to scroll to.
    @State private var focusTurn: Int?
    /// Underline what the final pass changed.
    @State private var showChanges = false
    @FocusState private var editingTitle: Bool

    enum Tab: Hashable { case summary, transcript }

    private var live: Bool { session != nil }

    /// The meeting itself: its header, and the transcript or the summary.
    private var meeting: some View {
        let cast = record.cast
        let turns = MeetingText.turns(record.words, pending: pending, paragraphs: true)
        return VStack(spacing: 0) {
            header(cast)
            ZStack {
                if live || tab == .transcript {
                    TranscriptView(record: record, turns: turns, cast: cast, session: session, width: width,
                                   edit: edit, focusTurn: $focusTurn,
                                   changed: showChanges ? Set(record.heal?.changed ?? []) : [])
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    SummaryView(record: record, turns: turns, cast: cast, notes: notes, width: width, edit: edit) { at in
                        focusTurn = turns.last { $0.start <= at + 0.05 }?.id
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { tab = .transcript }
                    }
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .id(epoch.value)   // see WindowEpoch
            .frame(maxHeight: .infinity)
        }
    }

    var body: some View {
        Group {
            if let session {
                IntroductionGate(session: session) { meeting } bar: { LiveBar(session: session) }
                    .id(epoch.value)   // the bar too: built anew when the window comes back (see WindowEpoch)
            } else {
                ZStack(alignment: .bottom) {
                    meeting
                    bottomBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            if MeetingPlayer.shared.meeting == record.id { MeetingPlayer.shared.stop() }
            // A "Fortsätt mötet" that couldn't is said here — not later on another page.
            if !live, recorder.phase == .idle { recorder.lastError = nil }
        }
        .onAppear {
            title = record.title
            if let at = MeetingsPage.focusAt, !live {
                MeetingsPage.focusAt = nil
                tab = .transcript
                focusTurn = MeetingText.turns(record.words, paragraphs: true).last { $0.start <= at + 0.05 }?.id
            }
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
        .confirmationDialog("Ta bort inspelningen?", isPresented: $confirmRemoveAudio) {
            Button("Flytta till papperskorgen", role: .destructive) {
                if case .saved(let store, let id) = edit { store.removeAudio(of: id) }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Ljudet flyttas till papperskorgen. Texten, dina anteckningar och sammanfattningen finns kvar, men det går inte längre att lyssna på mötet.")
        }
    }

    // MARK: Header

    private func header(_ cast: Cast) -> some View {
        let segments = MeetingText.segments(record.words)
        return headerStack(cast, segments)
    }

    private func headerStack(_ cast: Cast, _ segments: [MeetingText.Segment]) -> some View {
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
                    FolderTag(record: record)
                    ForEach(cast.order, id: \.self) { s in
                        SpeakerChip(speaker: s, cast: cast, recognized: record.recognized[String(s)] != nil,
                                    rename: { edit.name(s, $0) },
                                    merge: { other in withAnimation(.snappy) { edit.merge(s, into: other) } })
                    }
                }
                Spacer(minLength: 12)
                if !live {
                    PillPicker(options: [(Tab.summary, "Sammanfattning"), (Tab.transcript, "Text")], selection: $tab)
                }
            }
            if !segments.isEmpty {
                MeetingRibbon(record: record, cast: cast, segments: segments, live: live, now: session?.elapsed)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
            healLine
            banner
            if !live { FolderSuggestion(record: record) }
            // "Fortsätt mötet" couldn't: why, here where you pressed it.
            if !live, let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
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
        guard !live else { return when }
        var parts = [when, Self.duration(record.duration)]
        if record.informed != nil { parts.append(String(localized: "deltagarna informerades")) }
        if !record.hasAudio { parts.append(String(localized: "inspelningen borttagen")) }
        return parts.joined(separator: " · ")
    }

    /// What listening through the whole meeting changed — and a way to see it.
    @ViewBuilder private var healLine: some View {
        if !live, let heal = record.heal, heal.words + heal.speakers > 0 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal").foregroundStyle(DS.Colors.muted)
                Text(Self.healText(heal)).foregroundStyle(DS.Colors.muted)
                if heal.words > 0 {
                    Button(showChanges ? "Dölj ändringar" : "Visa ändringar") {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            showChanges.toggle()
                            if showChanges { tab = .transcript }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                }
            }
            .font(.system(size: 12.5))
        }
    }

    static func healText(_ heal: MeetingRecord.Heal) -> String {
        var parts: [String] = []
        if heal.words > 0 { parts.append(String(localized: "skärpte \(heal.words) ord")) }
        if heal.speakers == 1 { parts.append(String(localized: "rättade 1 talarbyte")) }
        if heal.speakers > 1 { parts.append(String(localized: "rättade \(heal.speakers) talarbyten")) }
        return String(localized: "Genomlyssnat efter mötet: \(parts.joined(separator: String(localized: " och ")))")
    }

    /// A meeting that didn't get its final pass: say so, and offer it.
    @ViewBuilder private var banner: some View {
        if !live, record.hasAudio, MeetingSession.shared.phase == .idle, !record.finished || !record.refined, !record.words.isEmpty {
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
            // The meeting beside your work instead — the same as closing the window.
            if let session, session.isBusy {
                Button { MeetingPanel.shared.collapse() } label: {
                    Label("Visa som panel", systemImage: "pip.enter")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(DS.Colors.chip))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Mötet fortsätter i en liten panel bredvid det du gör")
            }
            // Back in the room after a break: on with the same meeting (from today — an
            // older one has it in the ⋯ menu).
            if !live, record.finished, record.hasAudio, Calendar.current.isDateInToday(record.date) {
                Button { AppDelegate.continueMeeting(record.id) } label: {
                    Label("Fortsätt mötet", systemImage: "record.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(DS.Colors.chip))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(recorder.phase != .idle)
                .help("Spela in mer i samma möte – texten fortsätter där den slutade, och anteckningarna skrivs om för hela mötet")
            }
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
                    Menu("Sammanfatta igen") {
                        ForEach(SummaryLanguage.allCases) { choice in
                            Button(choice.menuTitle) {
                                notes.summarize(record.id, in: choice)
                            }
                        }
                    }
                    .disabled(!MeetingNotes.isAvailable || notes.writing.contains(record.id))
                    if record.hasAudio {
                        Button("Fortsätt mötet") { AppDelegate.continueMeeting(record.id) }
                            .disabled(!record.finished || MeetingSession.shared.phase != .idle)
                        Button("Lyssna igenom mötet igen") { MeetingSession.shared.finishInterrupted(record.id) }
                            .disabled(MeetingSession.shared.phase != .idle)
                        Button("Visa inspelningen i Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([MeetingStore.audioURL(for: record.id)])
                        }
                        Button("Ta bort inspelningen…") { confirmRemoveAudio = true }
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
    var height: CGFloat = 70
    var body: some View {
        LinearGradient(colors: [DS.Colors.paper.opacity(0), DS.Colors.paper], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
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
    var changed: Set<Int> = []
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var atBottom = true
    /// Following the newest text — until you scroll up yourself; back at the bottom
    /// (or "Till nu"), it follows again. Not decided by where the view happens to be
    /// when a burst of text arrives.
    @State private var following = true
    @State private var userScrolling = false

    private var live: Bool { session != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if turns.isEmpty { empty }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        let newSpeaker = i == 0 || turns[i - 1].speaker != turn.speaker
                        let end = i + 1 < turns.count ? turns[i + 1].id : record.words.count
                        let next = i + 1 < turns.count ? turns[i + 1].start : .infinity
                        let playing = isPlaying(turn, next: next)
                        TurnRow(turn: turn, cast: cast, showName: newSpeaker, live: live,
                                isLast: i == turns.count - 1,
                                playing: playing,
                                words: live ? [] : Array(record.words[turn.id..<max(turn.id, end)]),
                                firstIndex: turn.id,
                                changed: changed,
                                karaoke: playing ? player.time : nil,
                                focused: focusTurn == turn.id,
                                play: live || !record.hasAudio ? nil : { player.play(record.id, from: turn.start) },
                                move: turn.id < end && turn.pending.isEmpty
                                    ? { speaker in
                                        // Their own words — someone else's "Mm" inside stays theirs.
                                        withAnimation(.snappy) { for run in turn.own(until: end) { edit.move(run, to: speaker) } }
                                    } : nil,
                                marks: record.marks.filter { $0.at >= (i == 0 ? -.infinity : turn.start) && $0.at < next },
                                removeMark: { id in withAnimation(.snappy) { edit.removeMark(id) } },
                                recognized: turn.speaker.map { record.recognized[String($0)] != nil } ?? false,
                                rename: turn.speaker.flatMap { s in s >= 0 ? { edit.name(s, $0) } : nil },
                                merge: turn.speaker.flatMap { s in
                                    s >= 0 ? { other in withAnimation(.snappy) { edit.merge(s, into: other) } } : nil
                                })
                            .padding(.top, i == 0 ? 0 : newSpeaker ? 26 : 12)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .pageColumn(width)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, live ? 28 : 120, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
                if bottom { following = true }
            }
            // A mouse wheel or the keys move the view without a scroll phase: moved up
            // while the text stayed the same — that's you, reading back.
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentSize.height] } action: { old, new in
                if new[1] == old[1], new[0] < old[0] - 4, !atBottom { following = false }
            }
            // Only your own scrolling stops the following: where it ends decides.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: userScrolling = true
                case .idle:
                    if userScrolling { userScrolling = false; following = atBottom }
                default: break
                }
            }
            // Follow the conversation — unless you've scrolled up to read. On what the
            // text takes up, not on how many words: a new name row, a mark or a line
            // that settles also grows it.
            // (Or when the room for it shrinks: a card below appears, the note grows.)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentSize.height, $0.containerSize.height] } action: { old, new in
                guard live, following, !userScrolling, new != old else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Listening: the text follows the voice.
            .onChange(of: playingTurn) { _, id in
                guard let id, player.isPlaying else { return }
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: focusTurn, initial: true) { _, id in
                guard let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(id, anchor: .center) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if focusTurn == id { focusTurn = nil } }
            }
            // The text slips away under the header rather than being cut off.
            .overlay(alignment: .top) {
                LinearGradient(colors: [DS.Colors.paper, DS.Colors.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    BottomScrim(height: live ? 22 : 70)
                    if live, !following, !turns.isEmpty {
                        Button {
                            following = true
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
                        .padding(.bottom, live ? 14 : 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.15), value: following)
            }
            // Built anew mid-meeting (WindowEpoch): back to where the conversation is.
            .onAppear {
                guard live, !turns.isEmpty else { return }
                following = true
                // Once now, and once more after the layout has settled (after the round).
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if following { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
    }

    private var playingTurn: Int? {
        guard player.meeting == record.id else { return nil }
        return turns.last { $0.start - 0.4 <= player.time }?.id
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

extension MeetingTurn {
    /// What was said, with others' "Mm" in its place — small and muted, named.
    @MainActor func spoken(cast: Cast) -> Text {
        guard !asides.isEmpty else { return Text(text) }
        var out = Text("")
        var from = text.startIndex
        for aside in asides {
            let cut = text.index(text.startIndex, offsetBy: min(aside.at, text.count))
            if cut > from { out = Text("\(out)\(String(text[from..<cut]))") }
            let tag = Text(" (\(cast.name(of: aside.speaker)): \(aside.text))")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            out = Text("\(out)\(tag)")
            from = max(from, cut)
        }
        return Text("\(out)\(String(text[from...]))")
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
    /// The turn's words — for playback in step, and to show what the final pass changed.
    var words: [MeetingWord] = []
    var firstIndex = 0
    var changed: Set<Int> = []
    /// Listening: how far the voice has come.
    var karaoke: Double? = nil
    let focused: Bool
    let play: (() -> Void)?
    let move: ((Int) -> Void)?
    /// The moments you marked during this turn.
    var marks: [MeetingRecord.Mark] = []
    var removeMark: ((UUID) -> Void)? = nil
    /// The name above the text: click it to name or correct them, as in the header.
    var recognized = false
    var rename: ((String) -> Void)? = nil
    var merge: ((Int) -> Void)? = nil

    private var speaker: Int? { turn.speaker.flatMap { $0 >= 0 ? $0 : nil } }
    private var showsChanges: Bool { !changed.isEmpty && (firstIndex..<(firstIndex + words.count)).contains { changed.contains($0) } }

    private var tint: Color { SpeakerMark.color(of: speaker, in: cast) }
    private var lit: Bool { playing || focused }

    /// A document, not a chat: who spoke in a thin line of their colour beside what
    /// they said, their name above it when it's someone new.
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showName { nameRow }
            line
            if !marks.isEmpty {
                markRow
                    .padding(.top, 3)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, lit ? 7 : 0)
        .padding(.trailing, lit ? 12 : 0)
        .background(alignment: .leading) {
            Capsule().fill(tint.opacity(speaker == nil ? 0.6 : 1)).frame(width: lit ? 3.5 : 2.5)
        }
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.09)).transition(.opacity)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: lit)
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

    /// "Beslut 3:12" — what you marked while this was said.
    private var markRow: some View { MarkChips(marks: marks, remove: removeMark) }

    private var nameRow: some View {
        HStack(spacing: 8) {
            if let speaker, let rename, let merge {
                SpeakerChip(speaker: speaker, cast: cast, recognized: recognized, style: .name, rename: rename, merge: merge)
            } else {
                Text(speaker.map { cast.name(of: $0) }
                     ?? (live ? String(localized: "Känner igen rösten…") : String(localized: "Okänd talare")))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpeakerMark.ink(of: speaker, in: cast))
            }
            if let play {
                Button(action: play) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 7.5))
                        Text(MeetingView.duration(turn.start)).monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.faint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lyssna härifrån")
                .accessibilityLabel("Lyssna från \(MeetingView.spoken(turn.start))")
            } else {
                Text(MeetingView.duration(turn.start))
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DS.Colors.faint)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var line: some View {
        Group {
            if live && isLast {
                // The words still arriving, and the cursor blinking after them. One view
                // whether or not words are pending — so settling fades rather than snaps —
                // on a fixed beat that a redraw doesn't restart.
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.5)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                    text(cursor: turn.pending.isEmpty ? nil : on)
                }
            } else if !words.isEmpty, karaoke != nil || showsChanges {
                Text(wordByWord)
            } else {
                text(cursor: nil)
            }
        }
        // Live: words settle from grey into ink rather than switching.
        .contentTransition(.interpolate)
        .font(.system(size: 16))
        .lineSpacing(6)
        .textSelection(.enabled)
        .frame(maxWidth: 640, alignment: .leading)
        // The text grows with its words, rather than snapping to the new size.
        .animation(live ? .smooth(duration: 0.4) : nil, value: turn.text)
    }

    private func text(cursor: Bool?) -> Text {
        var out = turn.spoken(cast: cast)
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

    /// The words one by one: said so far in ink, still to come in grey — and what the
    /// final pass rewrote, underlined.
    private var wordByWord: AttributedString {
        var out = AttributedString()
        // Your spellings and no hesitation sounds, as in the rest of the text — when
        // the cleanup keeps the word count, so each word still has its time.
        let cleaned = MeetingText.clean(words.map(\.text).joined(separator: " ")).split(separator: " ").map(String.init)
        let shown = cleaned.count == words.count ? cleaned : words.map(\.text)
        for (k, w) in words.enumerated() {
            var piece = AttributedString((k == 0 ? "" : " ") + shown[k])
            if let t = karaoke { piece.foregroundColor = w.start <= t ? .primary : DS.Colors.muted }
            if changed.contains(firstIndex + k) {
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: DS.Colors.accent.opacity(0.7))
            }
            out += piece
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
    let edit: MeetingEdits
    let showInText: (Double) -> Void
    @State private var addingNotes = false

    private var writing: Bool { notes.writing.contains(record.id) }
    /// Just written again: say so for a moment.
    @State private var justRewritten = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Color.clear.frame(height: 0).id("top")
                    ownNotes
                    notesSection
                    if record.notes.isEmpty, !addingNotes {
                        Button { withAnimation(.easeOut(duration: 0.2)) { addingNotes = true } } label: {
                            Label("Egna anteckningar", systemImage: "plus")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(DS.Colors.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Skriv det som var viktigt för dig – sammanfattningen bygger på det")
                    }
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
            // Rewriting: up to where it happens; done: a word that it's new.
            .onChange(of: writing) { was, now in
                if now { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) } }
                if was && !now && record.summary != nil {
                    justRewritten = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { justRewritten = false }
                }
            }
        }
    }

    /// What you wrote yourself — first, since it's what mattered to you.
    @ViewBuilder private var ownNotes: some View {
        if !record.notes.isEmpty || addingNotes {
            SavedNotes(record: record, edit: edit, startEditing: addingNotes) { at in
                MeetingPlayer.shared.play(record.id, from: max(0, at - 8))
            }
        }
    }

    @ViewBuilder private var notesSection: some View {
        if !MeetingNotes.isAvailable {
            unavailable
        } else if let summary = record.summary {
            VStack(alignment: .leading, spacing: 32) {
            if writing || justRewritten {
                RewriteBanner(writing: writing).transition(.move(edge: .top).combined(with: .opacity))
            }
            // The old notes stay while the new ones are written — faded, so it's
            // clear they're about to change.
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
                HStack(alignment: .center, spacing: 7) {
                    Image(systemName: summary.writer == nil ? "apple.intelligence" : "sparkle")
                        .font(.system(size: 12))
                    Text(String(localized: "Sammanfattat av \(summary.writer ?? "Apple Intelligence"). Stämmer något inte? Klicka på en tid och lyssna själv."))
                    Spacer(minLength: 16)
                    Button {
                        notes.summarize(record.id)
                    } label: {
                        Label("Sammanfatta igen", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.soft)
                    .disabled(writing)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colors.muted)
                .staggered(4)
            }
            .id(summary.created)
            .opacity(writing ? 0.35 : 1)
            .blur(radius: writing ? 1.2 : 0)
            .allowsHitTesting(!writing)
            .animation(.easeInOut(duration: 0.4), value: writing)
            }
            .animation(.spring(duration: 0.4, bounce: 0.12), value: writing || justRewritten)
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
            if item.marked == true {
                Image(systemName: "flag.fill").font(.system(size: 10.5)).foregroundStyle(markTint)
                    .help("Du markerade det här under mötet")
                    .accessibilityLabel("Markerat av dig")
            }
            if let owner = item.owner { OwnerTag(name: owner, cast: cast) }
            if let at = item.at {
                Receipt(at: at, record: record, cast: cast, turns: turns, showInText: showInText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .animation(.easeOut(duration: 0.25), value: done)
    }

    /// The colour of what you marked: the list's kind.
    private var markTint: Color {
        switch kind {
        case .decision: return MeetingRecord.Mark.Kind.decision.tint
        case .task: return MeetingRecord.Mark.Kind.task.tint
        case .point: return MeetingRecord.Mark.Kind.important.tint
        }
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
                    if record.hasAudio {
                        Button {
                            MeetingPlayer.shared.play(record.id, from: at)
                        } label: {
                            Label("Lyssna", systemImage: "play.fill")
                        }
                        .buttonStyle(.ink)
                    }
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
                Text(BetterNotes.shared.isActive ? String(localized: "Gemma 4 skriver sammanfattningen…")
                                                 : String(localized: "Skriver sammanfattningen…"))
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

/// While recording: the island (time, note, marks, stop); otherwise the dark pill, as
/// when you dictate — time, sound, stop. Above
/// it, a word when something needs attention.
private struct LiveBar: View {
    @ObservedObject var session: MeetingSession
    /// Until the panel has been used once: closing the window doesn't end the meeting.
    @AppStorage(MeetingPanel.tipSeenKey) private var panelTipSeen = false

    var body: some View {
        VStack(spacing: 10) {
            if let caption {
                // A warning carries its sign, not only its colour (as in the panel).
                (caption.warning ? Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(caption.text)") : Text(caption.text))
                    .font(.system(size: 12.5, weight: caption.warning ? .medium : .regular))
                    .foregroundStyle(caption.warning ? DS.Colors.warning : DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.paper.opacity(0.9)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // "Innan ni börjar", while it has something to say: above the island, where
            // your eyes are, and it doesn't scroll away as the text grows.
            if session.isRecording, !session.introducing, session.showsOpening {
                OpeningCard(session: session)
                    .padding(12)
                    .frame(maxWidth: 560)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.paper))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.divider, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Recording: one island — the time, your note, the marks, stop.
            if session.isRecording, !session.introducing, !session.stopping {
                NoteIsland(session: session) { timer } trailing: { MeetingControls(session: session) }
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            } else {
                pill
            }
        }
        .padding(.bottom, 22)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: session.phase)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: session.stopping)
        .animation(.easeOut(duration: 0.25), value: caption?.text)
        // Read out when a warning appears: it may be the only sign something's off.
        .onChange(of: session.warning) { _, w in
            if let w { AccessibilityNotification.Announcement(w).post() }
        }
    }

    private var caption: (text: String, warning: Bool)? {
        if case .finishing = session.phase { return (String(localized: "Texten blir mer exakt när det är klart."), false) }
        if session.stopping {
            return (session.isPaused ? String(localized: "Mötet avslutas om några sekunder.")
                                     : String(localized: "Spelar in tills nedräkningen är klar."), false)
        }
        if session.isPaused { return (String(localized: "Pausat – mikrofonen är av. Det som sagts finns kvar."), false) }
        if let w = session.warning { return (w, true) }
        if !panelTipSeen, session.isRecording {
            return (String(localized: "Stäng fönstret så fortsätter mötet i en liten panel."), false)
        }
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
                timer
                if session.stopping {
                    StopCountdown(session: session, compact: true, onDark: true)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                } else {
                    LiveWave().frame(width: 96, height: 22).accessibilityHidden(true)
                    stopButton
                }
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

    /// One press ends it — with a few seconds to undo, the recording going on meanwhile.
    /// The red dot and how long it has been going.
    private var timer: some View {
        HStack(spacing: 10) {
            RecordingMark(session: session)
            if let start = session.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let time = session.clock(at: context.date)
                    Text(MeetingView.duration(time))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(session.isPaused ? 0.55 : 1))
                        .accessibilityLabel(session.isPaused ? "Pausat, \(MeetingView.spoken(time))" : "Spelar in, \(MeetingView.spoken(time))")
                }
            }
        }
        .fixedSize()
    }

    private var stopButton: some View {
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() }
        } label: {
            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Avsluta mötet – du kan ångra i några sekunder")
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
struct RecordingDot: View {
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

/// Writing the notes again: clearly at the top, with who writes them and for how
/// long — then, for a moment, that it's done.
private struct RewriteBanner: View {
    let writing: Bool
    @State private var started = Date()

    private var writer: String { BetterNotes.shared.isActive ? "Gemma 4" : "Apple Intelligence" }

    var body: some View {
        HStack(spacing: 14) {
            if writing {
                SettlingLine(color: DS.Colors.ink).frame(width: 56)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(DS.Colors.good)
                    .transition(.scale.combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(writing ? String(localized: "\(writer) skriver om sammanfattningen…") : String(localized: "Klar – en ny sammanfattning"))
                    .font(.system(size: 14, weight: .semibold))
                if writing {
                    Text("Det tar några sekunder. Den gamla syns tills den nya är klar.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                }
            }
            Spacer()
            if writing {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(MeetingView.duration(context.date.timeIntervalSince(started)))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .raised(cornerRadius: 16)
        .onAppear { started = Date() }
        .onChange(of: writing) { _, now in if now { started = Date() } }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: writing)
        .accessibilityElement(children: .combine)
    }
}
