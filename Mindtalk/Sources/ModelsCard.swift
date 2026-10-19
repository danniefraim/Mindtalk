import AppKit
import SwiftUI

// MARK: - Inställningar → Modeller
//
// Every model Mindtalk uses, by what it does: speech (dictation, meetings and
// thoughts), the voices in meetings, the summaries, and the word list's listener.
// Each says how big it is and what it needs, and can be shown in Finder or removed;
// at the foot, what they take together. For the summaries you choose which writes:
// in Mindtalk, Apple Intelligence (built in) or a Gemma 4 it downloads (the one that
// suits this Mac's memory is marked); or, in another app on this Mac, a model of your
// own in Ollama or LM Studio.

struct ModelsCard: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var servers = LocalServers.shared
    @ObservedObject private var meeting = MeetingSession.shared
    @ObservedObject private var listener = VocabularyBoostStatus.shared
    @ObservedObject private var vocabulary = Vocabulary.shared
    /// Recordings being written out use the speech model too: not removed meanwhile.
    @ObservedObject private var importing = MeetingImport.shared
    /// What each folder takes on disk — counted when the card shows.
    @State private var onDisk: [URL: Int64] = [:]
    @State private var total: Int64?
    @State private var confirmDownload: NotesModel?
    @State private var confirmRemove: Removal?

    private enum Removal: Identifiable {
        case speech(SpeechModel), voices, notes(NotesModel), listener
        var id: String {
            switch self {
            case .speech(let m): return "speech-\(m.rawValue)"
            case .voices: return "voices"
            case .notes(let m): return "notes-\(m.rawValue)"
            case .listener: return "listener"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecommendedDownloads()
            group(String(localized: "Tal"), "Skriver ned det du säger när du dikterar, i möten och för tankar.") {
                ForEach(Array(SpeechModel.allCases.enumerated()), id: \.element) { i, m in
                    if i > 0 { CardDivider() }
                    speechRow(m)
                }
            }
            group(String(localized: "Röster i möten"), "Håller isär vem som pratar och känner igen röster till nästa gång.") {
                voicesRow
                CardDivider()
                row(name: "ReDimNet2+", detail: String(localized: "Känner igen röster mellan möten · följer med appen")) {
                    Text("Inbyggd").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                }
            }
            // Two halves: the writers Mindtalk fetches itself, and the ones that live in
            // Ollama or LM Studio.
            group(String(localized: "Sammanfattningar"), "Skriver sammanfattningen av ett möte och svarar på dina frågor. Välj vilken som skriver.") {
                SubLabel(String(localized: "I Mindtalk"))
                appleRow
                ForEach(NotesModel.allCases) { m in
                    CardDivider()
                    notesRow(m)
                }
                CardDivider()
                SubLabel(String(localized: "I andra program på din Mac"))
                ServerWriterRows()
            }
            group(String(localized: "Ordlista"), nil) {
                listenerRow
            }
            HStack(spacing: 10) {
                Text(verbatim: total.map { String(localized: "Modellerna tar \(BetterNotes.gigabytes($0)) på den här Macen.") }
                     ?? String(localized: "Räknar ihop…"))
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                Spacer()
                Button("Visa i Finder") { reveal(SpeechModel.rootDirectory) }.buttonStyle(.soft)
            }
            .padding(.top, 2)
        }
        .task(id: refreshKey) { await measure() }
        .task { await servers.refresh() }     // Ollama and LM Studio: here, running, and their models
        .onAppear { listener.refresh() }      // the listener's folder deleted in Finder, or put back
        .confirmationDialog(confirmDownload.map { String(localized: "Ladda ned \($0.name) (\($0.sizeText))?") } ?? "",
                            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
                            presenting: confirmDownload) { m in
            Button("Ladda ned") { notes.download(m) }
            Button("Avbryt", role: .cancel) {}
        } message: { m in
            Text("Den laddas ned i bakgrunden medan du använder Mindtalk och fungerar sedan utan internet. Du har \(BetterNotes.gigabytes(BetterNotes.freeBytes)) ledigt.")
                + Text(verbatim: m.page.host.map { " " + String(localized: "Från \($0).") } ?? "")
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { what in
            Button("Ta bort", role: .destructive) { remove(what) }
            Button("Avbryt", role: .cancel) {}
        } message: { what in
            switch what {
            case .speech: Text("Den kan laddas ned igen senare.")
            case .voices where VoiceModels.isInstalled: Text("Möten kan inte spelas in förrän den laddats ned igen.")
            case .voices: Text("Det som laddats ned hittills tas bort. Du kan börja om senare.")
            case .notes(let m) where m.isInstalled: Text("Den kan laddas ned igen senare. Apple Intelligence skriver sammanfattningarna så länge.")
            case .notes: Text("Det som laddats ned hittills tas bort. Du kan börja om senare.")
            case .listener: Text("Dina ord rättas ändå i texten. Den kan laddas ned igen senare.")
            }
        }
    }

    /// Recounted when something is installed or removed.
    private var refreshKey: String {
        SpeechModel.allCases.map { "\($0.isInstalled)" }.joined()
            + "\(VoiceModels.isInstalled)\(VocabularyBoost.isInstalled)"
            + NotesModel.allCases.map { "\($0.isInstalled)" }.joined()
    }

    private func measure() async {
        let folders = SpeechModel.allCases.map(\.ownDirectory) + [VoiceModels.directory, VocabularyBoost.directory]
            + NotesModel.allCases.map(\.directory)
        let root = SpeechModel.rootDirectory
        let (sizes, all) = await Task.detached(priority: .utility) {
            (Dictionary(uniqueKeysWithValues: folders.map { ($0, ModelDownload.allocatedBytes(in: $0)) }),
             ModelDownload.allocatedBytes(in: root))
        }.value
        onDisk = sizes
        total = all
    }

    private func size(_ folder: URL, fallback: String) -> String {
        guard let bytes = onDisk[folder], bytes > 0 else { return fallback }
        return bytes >= 1_000_000_000 ? BetterNotes.gigabytes(bytes) : "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    // MARK: Speech

    private func speechRow(_ m: SpeechModel) -> some View {
        let inUse = dictation.engine == m && m.isInstalled
        let language = m == .swedish ? String(localized: "Svenska") : String(localized: "Flerspråkig")
        var detail = language + " · " + (m.isInstalled ? size(m.ownDirectory, fallback: m.sizeText) : m.sizeText)
        // A download that failed says why, in plain words (Dictation.plainWords).
        if let why = dictation.downloadErrors[m] { detail += "\n" + why }
        else if meeting.isBusy, m.isInstalled, !inUse { detail += "\n" + String(localized: "Går att byta när mötet är klart.") }
        return row(name: m.modelName, detail: detail, badge: inUse ? String(localized: "Används") : nil) {
            if let p = dictation.downloads[m] {
                // The last tenth is checking and compiling, not fetching.
                if SpeechModel.isPreparing(p) { preparingLabel } else { progress(min(1, p / 0.9)) }
            } else if m.isInstalled {
                Menu {
                    Button("Visa i Finder") { reveal(m.ownDirectory) }
                    if !inUse, m.isOwnInstall {
                        Divider()
                        // Not while a meeting, or a recording being written out, may need it:
                        // the model is let go when they're done.
                        Button("Ta bort…", role: .destructive) { confirmRemove = .speech(m) }.disabled(meeting.isBusy || importing.busy)
                    }
                } label: { moreLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(inUse ? "Den som används kan inte tas bort. Byt språk under Inspelning först." : "Mer")
            } else {
                Button(dictation.downloadErrors[m] == nil ? String(localized: "Ladda ned") : String(localized: "Försök igen")) { dictation.downloadModel(m) }.buttonStyle(.soft)
            }
        }
    }

    // MARK: The listener

    private var listenerRow: some View {
        let detail: String = {
            switch listener.state {
            case .failed(let why):
                return why
            case .downloading:
                return String(localized: "Laddar ned lyssnaren (\(VocabularyBoost.sizeText)). Det sker bara en gång, sedan fungerar den utan internet.")
            case .ready, .missing:
                return VocabularyBoost.isInstalled
                    ? String(localized: "Hör orden i din ordlista · \(size(VocabularyBoost.directory, fallback: VocabularyBoost.sizeText))")
                    : String(localized: "Hör orden i din ordlista, så att de stavas rätt redan när du pratar · \(VocabularyBoost.sizeText)")
            }
        }()
        return row(name: String(localized: "Lyssnaren (Parakeet CTC)"), detail: detail) {
            if case .downloading = listener.state {
                ProgressView().controlSize(.small)
            } else if case .failed = listener.state {
                // Here but wouldn't start: fetched afresh. Not here: fetched again.
                if VocabularyBoost.isInstalled {
                    Button("Ladda ned igen") { vocabulary.refetchListener() }.buttonStyle(.soft)
                } else {
                    Button("Försök igen") { vocabulary.fetchListener() }.buttonStyle(.soft)
                }
            } else if VocabularyBoost.isInstalled {
                Menu {
                    Button("Visa i Finder") { reveal(VocabularyBoost.directory) }
                    Divider()
                    Button("Ta bort…", role: .destructive) { confirmRemove = .listener }
                } label: { moreLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mer")
            } else {
                Button("Ladda ned") { vocabulary.fetchListener() }.buttonStyle(.soft)
            }
        }
    }

    // MARK: Voices

    private var voicesRow: some View {
        var detail = String(localized: "Från NVIDIA · ") + (VoiceModels.isInstalled ? size(VoiceModels.directory, fallback: VoiceModels.sizeText) : VoiceModels.sizeText)
        if case .failed(let why) = voices.state { detail += "\n" + why }
        return row(name: "Nemotron 3", detail: detail) {
            switch voices.state {
            case .downloading(let p):
                if voices.preparing { preparingLabel } else { progress(p) }
            case .ready:
                Menu {
                    Button("Visa i Finder") { reveal(VoiceModels.directory) }
                    Divider()
                    Button("Ta bort…", role: .destructive) { confirmRemove = .voices }.disabled(meeting.isBusy)
                } label: { moreLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mer")
            case .missing:
                Button("Ladda ned") { voices.download() }.buttonStyle(.soft)
            case .failed:
                // What came in stays for the next try — or goes, if you'd rather start over.
                HStack(spacing: 10) {
                    Button("Försök igen") { voices.download() }.buttonStyle(.soft)
                    Menu {
                        Button("Ta bort det nedladdade…", role: .destructive) { confirmRemove = .voices }
                    } label: { moreLabel(ticked: false) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Mer")
                }
            }
        }
    }

    // MARK: Summaries

    /// Where Apple Intelligence stands on this Mac — here, and under Möten.
    static func appleDetail(_ status: Polisher.Status) -> String {
        switch status {
        case .available: return String(localized: "Inbyggd i macOS · alla Macar med Apple Intelligence")
        case .notEnabled: return String(localized: "Slå på Apple Intelligence i Systeminställningar för att använda den.")
        case .notReady: return String(localized: "macOS laddar fortfarande ned den.")
        case .unsupported: return String(localized: "Finns inte på den här Macen.")
        }
    }

    private var appleRow: some View {
        let status = Polisher.status
        let detail = Self.appleDetail(status)
        return row(name: "Apple Intelligence", detail: detail, chooser: (!notes.isActive, status == .available, { notes.choice = .apple })) {
            EmptyView()
        }
    }

    private func notesRow(_ m: NotesModel) -> some View {
        let state = notes.state(m)
        let recommended = NotesModel.recommended == m
        let detail: String = {
            switch state {
            case .unsupported:
                return String(localized: "Kräver minst \(m.minimumMemoryGB) GB minne. Den här Macen har \(BetterNotes.memoryGB) GB.")
            case .ready:
                return String(localized: "Laddas ned av Mindtalk · tar \(size(m.directory, fallback: m.sizeText)) på disken")
            case .failed(let message):
                return message
            case .missing, .downloading:
                var text = String(localized: "Laddas ned av Mindtalk · \(m.sizeText) · för Macar med minst \(m.minimumMemoryGB) GB minne")
                // Not room for it: say how much more, so you can tell whether emptying
                // the Trash will do.
                if !m.hasRoom {
                    let short = max(100_000_000, m.remainingBytes + 2_000_000_000 - BetterNotes.freeBytes)
                    text += "\n" + String(localized: "Får inte plats just nu. Frigör \(BetterNotes.gigabytes(short)) till för att ladda ned den.")
                }
                return text
            }
        }()
        // Recommended, but not while it wouldn't fit: a badge next to "Får inte plats" would argue with it.
        let fits = state == .ready || m.hasRoom
        return row(name: m.name, detail: detail, badge: recommended && state != .unsupported && fits ? String(localized: "Rekommenderas för din Mac") : nil,
                   chooser: (notes.active == m, state == .ready, { notes.chosen = m })) {
            switch state {
            case .unsupported:
                EmptyView()
            case .downloading(let p):
                HStack(spacing: 10) {
                    progress(p)
                    Button("Avbryt") { notes.cancel() }.buttonStyle(.soft)
                }
            case .ready:
                Menu {
                    Button("Visa i Finder") { reveal(m.directory) }
                    Divider()
                    Button("Ta bort…", role: .destructive) { confirmRemove = .notes(m) }
                } label: { moreLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mer")
            case .missing, .failed:
                let partly = m.remainingBytes < m.bytes - 50_000_000
                HStack(spacing: 10) {
                    Button(partly ? String(localized: "Fortsätt (\(BetterNotes.gigabytes(m.remainingBytes)) kvar)") : String(localized: "Ladda ned")) {
                        if partly { notes.download(m) } else { confirmDownload = m }
                    }
                    .buttonStyle(.soft)
                    .disabled(!m.hasRoom || notes.downloading != nil)
                    // Something of it is on disk (a cancelled or failed download): it can go.
                    if m.remainingBytes < m.bytes {
                        Menu {
                            Button("Ta bort det nedladdade…", role: .destructive) { confirmRemove = .notes(m) }
                        } label: { moreLabel(ticked: false) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Mer")
                    }
                }
            }
        }
    }

    // MARK: Parts

    /// A group of models under a label in small capitals, as on Hem, and a line on what they do.
    private func group<C: View>(_ title: String, _ detail: LocalizedStringKey?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(title)
                if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted) }
            }
            .padding(.leading, 4)
            VStack(spacing: 0) { content() }.card()
        }
    }

    /// A model: its name (and a mark), what it is, and what can be done with it. With
    /// a chooser, a round button in front picks it.
    private func row<T: View>(name: String, detail: String, badge: String? = nil,
                              chooser: (on: Bool, enabled: Bool, pick: () -> Void)? = nil,
                              @ViewBuilder trailing: () -> T) -> some View {
        ModelRow(name: name, badge: badge, chooser: chooser) {
            Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            trailing()
        }
    }

    private func progress(_ p: Double) -> some View {
        HStack(spacing: 8) {
            InkProgressBar(progress: p).frame(width: 90)
            Text(p, format: .percent.precision(.fractionLength(0))).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
        }
    }

    /// The files are in; now it's checked and made ready for this Mac.
    private var preparingLabel: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Förbereder…").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
        }
    }

    /// On a model that's here: a green tick that says so, and ⋯ for Finder and removing.
    private var moreLabel: some View { moreLabel(ticked: true) }

    /// ⋯ in a small chip disc — with the green tick in front when the model is here.
    private func moreLabel(ticked: Bool) -> some View {
        HStack(spacing: 10) {
            if ticked {
                Label("Nedladdad", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.good)
            }
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(DS.Colors.chip))
        }
        .contentShape(Rectangle())
    }

    private func finderMenu(_ folder: URL) -> some View {
        Menu { Button("Visa i Finder") { reveal(folder) } } label: { moreLabel }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Mer")
    }

    private func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private var removalTitle: String {
        switch confirmRemove {
        case .speech(let m): return String(localized: "Ta bort \(m.modelName)?")
        case .voices: return String(localized: "Ta bort Nemotron 3?")
        case .notes(let m): return String(localized: "Ta bort \(m.name)?")
        case .listener: return String(localized: "Ta bort lyssnaren?")
        case nil: return ""
        }
    }

    private func remove(_ what: Removal) {
        switch what {
        case .speech(let m): dictation.removeModel(m)
        case .voices: voices.remove()
        case .notes(let m): notes.remove(m)
        case .listener: vocabulary.removeListener()
        }
        confirmRemove = nil
    }
}

/// Which writes a meeting's summary — in Settings → Möten, beside the rest.
struct SummaryWriterRow: View {
    @ObservedObject private var notes = BetterNotes.shared

    /// Apple, the Gemmas that are here, and the server model chosen, if one is.
    private var options: [(value: String, title: String)] {
        let ready = NotesModel.allCases.filter { notes.state($0) == .ready }
        var options: [(value: String, title: String)] = [("apple", "Apple Intelligence")] + ready.map { ("gemma:\($0.rawValue)", $0.name) }
        if let server = notes.server {
            options.append((SummaryWriterChoice.server(server.backend, server.model).stored, notes.writerName))
        }
        return options
    }

    var body: some View {
        let status = Polisher.status
        // Apple Intelligence off or missing: said as under Modeller, not as if it wrote them.
        let apple = status == .available ? String(localized: "Apple Intelligence.")
            : String(localized: "Apple Intelligence: ") + ModelsCard.appleDetail(status)
        let options = options
        CardRow(title: "Sammanfattningarna skrivs av",
                detail: options.count == 1
                    ? (NotesModel.recommended.map { apple + " " + String(localized: "\($0.name) skriver mer träffsäkert och laddas ned under Modeller.") }
                       ?? apple)
                    : String(localized: "Fler val under Modeller.")) {
            if options.count > 1 {
                WriterPicker(options: options, selection: Binding(
                    get: { notes.isActive ? notes.choice.stored : "apple" },
                    set: { if let c = SummaryWriterChoice(stored: $0) { notes.choice = c } }))
            }
        }
        .card()
    }
}

/// The pop-up over the writers, their names as they are ("Ollama · qwen3.5:9b" isn't a
/// string to translate).
private struct WriterPicker: View {
    let options: [(value: String, title: String)]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    if option.value == selection {
                        Label { Text(verbatim: option.title) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(verbatim: options.first { $0.value == selection }?.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(DS.Colors.control).shadow(color: .black.opacity(0.06), radius: 2, y: 1))
            .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Rows

/// A model: its name (and a mark), what it is, and what can be done with it. With a
/// chooser, a round button in front picks it; `whenDisabled` says why it can't be picked.
private struct ModelRow<Detail: View, Trailing: View>: View {
    let name: String
    var badge: String? = nil
    var chooser: (on: Bool, enabled: Bool, pick: () -> Void)? = nil
    var whenDisabled = String(localized: "Ladda ned den först")
    let detail: Detail
    let trailing: Trailing

    init(name: String, badge: String? = nil, chooser: (on: Bool, enabled: Bool, pick: () -> Void)? = nil,
         whenDisabled: String = String(localized: "Ladda ned den först"),
         @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.badge = badge
        self.chooser = chooser
        self.whenDisabled = whenDisabled
        self.detail = detail()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let chooser {
                Button(action: chooser.pick) {
                    Image(systemName: chooser.on ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(chooser.on ? DS.Colors.accent : DS.Colors.muted)
                }
                .buttonStyle(.plain)
                .disabled(!chooser.enabled)
                .opacity(chooser.enabled ? 1 : 0.35)
                .help(chooser.enabled ? String(localized: "Använd för sammanfattningarna") : whenDisabled)
                .accessibilityLabel(Text("Använd \(name) för sammanfattningarna"))
                .accessibilityAddTraits(chooser.on ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: name).font(.system(size: 14, weight: .semibold))
                    if let badge {
                        Text(verbatim: badge).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(DS.Colors.chip))
                    }
                }
                detail
            }
            // The only part that stretches: the text gets all the room the controls
            // don't need, so it wraps or yields only when the row is truly tight.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 26)
            trailing.fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// Content lined up with a row's text: past the card's edge and the room a chooser takes.
private struct RowInset<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "circle").font(.system(size: 16)).hidden().accessibilityHidden(true)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }
}

/// A heading between a card's rows, smaller than the CapsLabel over the card: "I MINDTALK".
private struct SubLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        RowInset {
            Text(verbatim: text.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(1.4)
                .foregroundStyle(DS.Colors.muted)
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 18)
        .padding(.bottom, -4)
    }
}

// MARK: - Ollama and LM Studio

/// The writers in other apps on this Mac, one row each: running or not, its models to
/// pick from and a Testa button; beneath both, where the models come from, what Testa
/// gave, and the ports under Avancerat.
struct ServerWriterRows: View {
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var servers = LocalServers.shared
    @State private var advanced = false
    /// The ports as typed: taken on Return, not at every keystroke.
    @State private var portText: [ServerBackend: String] = [:]

    /// Either of them is on this Mac.
    private var anyInstalled: Bool { ServerBackend.allCases.contains { servers.state($0) != .notInstalled } }

    /// The model this backend's picker shows: the chosen one, or the one picked last time.
    private func picked(_ backend: ServerBackend) -> String? {
        if let server = notes.server, server.backend == backend { return server.model }
        #if DEBUG
        if LocalServers.demo != nil { return servers.models[backend]?.first?.id }
        #endif
        let remembered = UserDefaults.standard.string(forKey: "serverModel.\(backend.rawValue)")
        let models = servers.models[backend] ?? []
        if let remembered, models.contains(where: { $0.id == remembered }) { return remembered }
        return nil
    }

    var body: some View {
        ForEach(Array(ServerBackend.allCases.enumerated()), id: \.element) { i, backend in
            if i > 0 { CardDivider() }
            row(backend)
        }
        RowInset {
            VStack(alignment: .leading, spacing: 12) {
                Text(anyInstalled
                     ? "Modellerna laddar du ned i Ollama eller LM Studio. Mindtalk pratar bara med den här datorn, och Ollamas molnmodeller visas inte."
                     : "Valfritt. För dig som redan kör Ollama eller LM Studio.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                // A plain disclosure group only opens on its chevron: here the word opens it too.
                Button { withAnimation(.easeOut(duration: 0.2)) { advanced.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(advanced ? 90 : 0))
                        Text("Avancerat").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(DS.Colors.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Avancerat"))
                .accessibilityAddTraits(advanced ? [.isButton, .isSelected] : .isButton)
                if advanced {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Portarna Mindtalk pratar med. Ändra bara om du ändrat dem i Ollama eller LM Studio. Tryck på retur för att prova.")
                            .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            ForEach(ServerBackend.allCases) { backend in
                                HStack(spacing: 6) {
                                    Text(verbatim: backend.name).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                                    TextField("", text: Binding(get: { portText[backend] ?? String(servers.ports[backend] ?? backend.defaultPort) },
                                                                set: { portText[backend] = $0 }))
                                        .textFieldStyle(.roundedBorder).frame(width: 66)
                                        .font(.system(size: 12.5)).monospacedDigit()
                                        .accessibilityLabel(Text("Port för \(backend.name)"))
                                        .onSubmit { take(backend) }
                                }
                            }
                            Button("Återställ portarna") { servers.resetPorts(); portText = [:]; Task { await servers.refresh() } }
                                .buttonStyle(.soft)
                                .disabled(ServerBackend.allCases.allSatisfy { servers.ports[$0] == $0.defaultPort })
                            Spacer()
                        }
                        if let note = servers.portNote {
                            Text(verbatim: note).font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(.bottom, 16)
        // Another model or backend: the test answer was about the one before.
        .onChange(of: notes.choice) { servers.clearTest() }
    }

    /// Return in a port field: the number taken (kept within range, never the other's),
    /// shown as taken, and the backend looked for there.
    private func take(_ backend: ServerBackend) {
        if let typed = portText[backend].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            servers.ports[backend] = typed
        }
        portText[backend] = nil
        Task { await servers.probe(backend) }
    }

    /// "( ) Ollama  ● Igång  [ qwen3.5:9b ⌄ ]  Bra på svenska        [ Testa ]"
    private func row(_ backend: ServerBackend) -> some View {
        let state = servers.state(backend)
        let models = servers.models[backend] ?? []
        let model = picked(backend)
        let on = notes.server?.backend == backend
        let ready = state == .running && model != nil
        return ModelRow(name: backend.name, badge: on ? String(localized: "Används") : nil,
                        chooser: (on, ready || on, { if let model { notes.choice = .server(backend, model) } }),
                        whenDisabled: String(localized: "Kräver att \(backend.name) är igång med en modell.")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Circle().fill(state == .running ? DS.Colors.ink : Color.clear)
                        .overlay(Circle().strokeBorder(state == .running ? Color.clear : DS.Colors.muted, lineWidth: 1.2))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    // The status gives way first when the line is tight.
                    Text(verbatim: state.title).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                        .lineLimit(1).layoutPriority(-1)
                        .frame(minWidth: 30, alignment: .leading)
                    if state == .running, !models.isEmpty {
                        ServerModelPicker(models: models, selection: Binding(
                            get: { model },
                            set: { if let id = $0 { notes.choice = .server(backend, id) } }))
                        if let model, let m = models.first(where: { $0.id == model }), m.goodAtSwedish {
                            Text("Bra på svenska").font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(DS.Colors.chip))
                        }
                    }
                }
                if let note = servers.notes[backend] {
                    Text(verbatim: note).font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state == .running, !models.isEmpty, model == nil {
                    Text("Välj en modell, så kan du testa den.").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                }
                // LM Studio's list can't tell a model on another computer (LM Link) from one here.
                if backend == .lmStudio, state != .notInstalled {
                    Text("Har du kopplat LM Studio till en annan dator (LM Link) kan den skicka mötet dit. Koppla bort den för möten som ska stanna här.")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // What Testa gave, under the row that was tested.
                if let test = servers.test, test.backend == backend { testView(test).padding(.top, 4) }
            }
        } trailing: {
            switch state {
            case .running:
                if servers.testing == backend {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Button("Avbryt") { servers.cancelTest() }.buttonStyle(.soft)
                    }
                } else if let model {
                    Button("Testa") { servers.runTest(backend, model) }.buttonStyle(.soft)
                }
            case .installedNotRunning:
                if servers.probing.contains(backend) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(backend.openTitle) { servers.open(backend) }.buttonStyle(.soft)
                }
            case .notInstalled:
                Button("Läs mer") { NSWorkspace.shared.open(backend.site) }.buttonStyle(.soft)
            }
        }
    }

    /// What Testa gave: the question, the answer, how long it took and how much the model
    /// reads; or which model failed, and how.
    private func testView(_ test: LocalServers.TestResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let answer = test.answer {
                Text("Provfråga om ett påhittat möte: \(LocalServers.testQuestion)")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                Text(verbatim: "“\(answer)”").font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Text("Svarade på \(test.seconds.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale))) s. Orkar ungefär \(ServerModel.words(test.context)) ord åt gången.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
            } else {
                Text(verbatim: "\(test.backend.name) · \(test.model)").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                Text(verbatim: test.error ?? "").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.paper.opacity(0.6)))
    }
}

/// The models one backend has: name, size and how much each reads; the ones good at
/// Swedish say so. Names as they are, never translated.
private struct ServerModelPicker: View {
    let models: [ServerModel]
    @Binding var selection: String?

    var body: some View {
        Menu {
            ForEach(models) { m in
                Button { selection = m.id } label: {
                    let title = m.title + (m.goodAtSwedish ? " · " + String(localized: "Bra på svenska") : "")
                    if m.id == selection {
                        Label { Text(verbatim: title) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(verbatim: selection ?? String(localized: "Välj modell"))
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(DS.Colors.control).shadow(color: .black.opacity(0.06), radius: 2, y: 1))
            .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Modell"))
    }
}

// MARK: - Old versions

enum ModelHousekeeping {
    /// After an update to a model, its older version is left behind: moved to the
    /// Trash at launch (never deleted outright), so the disk isn't filled twice.
    static func tidy() {
        let root = SpeechModel.rootDirectory
        let current = Set(SpeechModel.allCases.map { $0.ownDirectory.lastPathComponent })
        let notesCurrent = Set(NotesModel.allCases.map(\.folderName))
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let old = { (folder: URL, prefixes: [String], keep: Set<String>) -> [URL] in
                ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { url in
                    let name = url.lastPathComponent
                    return prefixes.contains { name.hasPrefix($0) } && !keep.contains(name)
                }
            }
            let stale = old(root, ["pianissimo-sv-", "parakeet-ultra-"], current)
                + old(root.appendingPathComponent("Notes"), ["gemma-4-"], notesCurrent)
            for url in stale {
                try? fm.trashItem(at: url, resultingItemURL: nil)
                NSLog("Mindtalk: moved an old model version to the Trash: \(url.lastPathComponent)")
            }
        }
    }
}

/// Under a meeting's summary, once: the Gemma that suits this Mac, for summaries
/// that catch more — its size said, nothing fetched until you say so. Not offered
/// again once you've answered.
struct NotesModelOffer: View {
    @ObservedObject private var notes = BetterNotes.shared
    @AppStorage("notesOfferAnswered") private var answered = false

    var body: some View {
        if let m = NotesModel.recommended, !notes.isActive {
            switch notes.state(m) {
            case .downloading(let p):
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                    Text("Laddar ned \(m.name)…").font(.system(size: 13, weight: .medium))
                    InkProgressBar(progress: p).frame(width: 140)
                    Text(p, format: .percent.precision(.fractionLength(0))).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .card()
            case .missing where !answered && m.hasRoom:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkle").font(.system(size: 15)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mer träffsäkra sammanfattningar").font(.system(size: 14, weight: .semibold))
                            Text("\(m.name) från Google hittar fler beslut och uppgifter och skriver dem på din Mac. Den laddas ned en gång (\(m.sizeText)) och fungerar sedan utan internet. Du har \(BetterNotes.gigabytes(BetterNotes.freeBytes)) ledigt.")
                                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        Button("Inte nu") { withAnimation(.snappy) { answered = true } }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                        Button("Ladda ned \(m.sizeText)") {
                            answered = true
                            notes.download(m)
                        }
                        .buttonStyle(.ink)
                        .disabled(notes.downloading != nil)
                    }
                }
                .padding(18)
                .card()
                .transition(.opacity)
            // Doesn't fit: said anyway, once — what it would give, and how much room it needs.
            case .missing where !answered:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkle").font(.system(size: 15)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mer träffsäkra sammanfattningar").font(.system(size: 14, weight: .semibold))
                            Text("\(m.name) från Google hittar fler beslut och uppgifter och skriver dem på din Mac. Den behöver \(BetterNotes.gigabytes(m.remainingBytes + 2_000_000_000)) ledigt. Du har \(BetterNotes.gigabytes(BetterNotes.freeBytes)).")
                                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        Button("Inte nu") { withAnimation(.snappy) { answered = true } }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                        Button("Visa modeller") { SettingsPage.openModels() }
                            .buttonStyle(.ink)
                    }
                }
                .padding(18)
                .card()
                .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }
}
