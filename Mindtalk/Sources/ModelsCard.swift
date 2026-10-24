import AppKit
import SwiftUI

// MARK: - The models, where they're used
//
// No page of models of their own: each sits with what it does. Under Inställningar →
// Språk, the two speech models, one language each (use, download, size, Finder,
// removal). Under Möten, one Sammanfattningar card: who writes them, as round buttons
// (Apple Intelligence, built in, or a Gemma 4 it downloads, the one that suits this
// Mac's memory marked), the summary's language, and folded under them a model of your
// own in Ollama or LM Studio; and Nemotron 3, which tells the voices apart, while it
// isn't here. The word list's listener is on Ordlista. Under Allmänt, what they take
// together.

/// "450 MB", "1,2 GB": one way to say a size everywhere.
enum DiskSize {
    static func text(_ bytes: Int64) -> String {
        bytes < 1_000_000_000 ? "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB" : BetterNotes.gigabytes(bytes)
    }

    /// What a folder takes, counted off the main thread.
    static func measure(_ folders: [URL]) async -> [URL: Int64] {
        await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: folders.map { ($0, ModelDownload.allocatedBytes(in: $0)) })
        }.value
    }

    static func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: - Språk

/// The two speech models, one row per language: use it, download it, how big it is,
/// and ⋯ for Finder and removal. On top, that the choice counts for meetings too.
struct SpeechLanguagesCard: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject private var meeting = MeetingSession.shared
    /// Recordings being written out use the speech model too: not removed meanwhile.
    @ObservedObject private var importing = MeetingImport.shared
    @State private var onDisk: [URL: Int64] = [:]
    @State private var confirmRemove: SpeechModel?

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Språket du pratar", detail: "Gäller både diktering och möten. Byt snabbt i menyraden.") { EmptyView() }
            ForEach(SpeechModel.allCases) { m in
                CardDivider()
                row(m)
            }
        }
        .card()
        .task(id: SpeechModel.allCases.map { "\($0.isInstalled)" }.joined()) {
            onDisk = await DiskSize.measure(SpeechModel.allCases.map(\.ownDirectory))
        }
        .confirmationDialog(confirmRemove.map { String(localized: "Ta bort \($0.modelName)?") } ?? "",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { m in
            Button("Ta bort", role: .destructive) { dictation.removeModel(m); confirmRemove = nil }
            Button("Avbryt", role: .cancel) {}
        } message: { _ in
            Text("Den kan laddas ned igen senare.")
        }
    }

    private func size(_ m: SpeechModel) -> String {
        guard m.isInstalled, let bytes = onDisk[m.ownDirectory], bytes > 0 else { return m.sizeText }
        return DiskSize.text(bytes)
    }

    private func row(_ m: SpeechModel) -> some View {
        let active = dictation.engine == m
        return HStack(spacing: 16) {
            ModelBadge(model: m, size: 13)
                .foregroundStyle(active ? DS.Colors.accent : .secondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(active ? DS.Colors.accent.opacity(0.12) : DS.Colors.chip))
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(.system(size: 14, weight: .semibold))
                Text(detail(m)).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: String(localized: "\(m.modelName) av \(m.credit), \(size(m))."))
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control(m, active: active).fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func detail(_ m: SpeechModel) -> String {
        if let why = dictation.downloadErrors[m] { return why }
        // Mid-meeting the model in use stays: said where the choice is.
        if meeting.isBusy, dictation.engine != m, dictation.installed.contains(m) {
            return m.pitch + " " + String(localized: "Går att byta när mötet är klart.")
        }
        return m.pitch
    }

    @ViewBuilder private func control(_ m: SpeechModel, active: Bool) -> some View {
        if let p = dictation.downloads[m] {
            HStack(spacing: 10) {
                // The last tenth is checking and compiling, not fetching.
                if SpeechModel.isPreparing(p) { ModelParts.preparing } else { ModelParts.progress(min(1, p / 0.9)) }
                Button("Avbryt") { dictation.cancelDownload(m) }.buttonStyle(.soft)
            }
        } else if !dictation.installed.contains(m) {
            Button(LocalizedStringKey(dictation.downloadErrors[m] == nil ? "Ladda ned" : "Försök igen")) {
                dictation.downloadModel(m)
            }
            .buttonStyle(.ink)
        } else {
            HStack(spacing: 10) {
                if active {
                    if dictation.model == .loading { ProgressView().controlSize(.small) }
                    Label("Används", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colors.accent)
                } else {
                    Button("Använd") { dictation.setEngine(m) }.buttonStyle(.soft)
                        .disabled(meeting.isBusy)
                }
                Menu {
                    Button("Visa i Finder") { DiskSize.reveal(m.ownDirectory) }
                    if !active, m.isOwnInstall {
                        Divider()
                        // Not while a meeting, or a recording being written out, may need it:
                        // the model is let go when they're done.
                        Button("Ta bort…", role: .destructive) { confirmRemove = m }.disabled(meeting.isBusy || importing.busy)
                    }
                } label: { ModelParts.more }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(active ? "Den som används kan inte tas bort. Byt språk först." : "Mer")
                .accessibilityLabel(Text("Mer om \(m.title)"))
            }
        }
    }
}

// MARK: - Möten

/// Nemotron 3, which tells the voices in a meeting apart: here only while it isn't
/// downloaded (or the download failed), since meetings can't be recorded without it.
struct VoiceModelSettingsCard: View {
    @ObservedObject private var voices = VoiceModels.shared
    @State private var confirmRemove = false

    var body: some View {
        ModelRow(name: String(localized: "Röstmodellen"), badge: nil) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Håller isär vem som pratar i ett möte. Möten kan inte spelas in utan den.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let why) = voices.state {
                    Text(verbatim: why).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: String(localized: "Nemotron 3 från NVIDIA, \(VoiceModels.sizeText)."))
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
            }
        } trailing: {
            switch voices.state {
            case .downloading(let p):
                if voices.preparing { ModelParts.preparing } else { ModelParts.progress(p) }
            case .ready:
                EmptyView()
            case .missing:
                Button("Ladda ned") { voices.download() }.buttonStyle(.ink)
            case .failed:
                // What came in stays for the next try — or goes, if you'd rather start over.
                HStack(spacing: 10) {
                    Button("Försök igen") { voices.download() }.buttonStyle(.ink)
                    Menu {
                        Button("Ta bort det nedladdade…", role: .destructive) { confirmRemove = true }
                    } label: { ModelParts.more }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Mer")
                }
            }
        }
        .card()
        .confirmationDialog("Ta bort Nemotron 3?", isPresented: $confirmRemove) {
            Button("Ta bort", role: .destructive) { voices.remove() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Det som laddats ned hittills tas bort. Du kan börja om senare.")
        }
    }
}

/// Who writes a meeting's summary and answers your questions: the round button in
/// front of a row picks it, and is the only mark of the one chosen. Apple Intelligence
/// and the Gemmas (downloaded here); then the summary's language; then, folded, Ollama
/// and LM Studio in other programs on this Mac.
struct SummaryWritersCard: View {
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var servers = LocalServers.shared
    @State private var onDisk: [URL: Int64] = [:]
    @State private var confirmDownload: NotesModel?
    @State private var confirmRemove: NotesModel?
    /// Where Apple Intelligence stands, asked again when the app comes to the front:
    /// switched on in System Settings, or done downloading, meanwhile.
    @State private var appleStatus = Polisher.status

    /// Where Apple Intelligence stands on this Mac.
    static func appleDetail(_ status: Polisher.Status) -> String {
        switch status {
        case .available: return String(localized: "Inbyggd i macOS. Inget att ladda ned.")
        case .notEnabled: return String(localized: "Slå på Apple Intelligence under Systeminställningar → Apple Intelligence och Siri.")
        case .notReady: return String(localized: "macOS laddar fortfarande ned den. Det brukar ta några minuter. Du kan spela in under tiden.")
        case .unsupported: return String(localized: "Finns inte på den här Macen.")
        }
    }

    /// System Settings on Apple Intelligence & Siri, where it is switched on: the "Slå på"
    /// here, on a meeting without a summary and on the introduction's last step.
    static func openAppleIntelligenceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }

    /// What the card says on top: Apple Intelligence is on, and what a Gemma adds; or,
    /// while it isn't, only that the writer is chosen here.
    static func headline(_ status: Polisher.Status) -> String {
        status == .available
            ? String(localized: "Apple Intelligence är redan på. Vill du ha fylligare sammanfattningar kan du ladda ned Gemma 4 från Google, som också körs på din Mac.")
            : String(localized: "Välj vem som skriver dem.")
    }

    /// The one Gemma shown with Apple Intelligence: the one you chose, else the one that
    /// suits this Mac, or the smaller when neither runs here (its row says why). The
    /// chosen one first: with the disk nearly full the larger one is "recommended" though
    /// it doesn't fit, and yours would sit folded away under it.
    @MainActor static var primaryGemma: NotesModel { BetterNotes.shared.chosen ?? NotesModel.recommended ?? .small }

    @State private var summaryLanguage = SummaryLanguage.chosen
    /// "Fler alternativ": the other Gemma and the writers in other programs, folded unless
    /// one of them writes now.
    @State private var more: Bool
    /// Settled when the card appears: choosing the other Gemma doesn't move the rows.
    @State private var primary: NotesModel
    /// The rest, under "Fler alternativ".
    private var otherGemmas: [NotesModel] { NotesModel.allCases.filter { $0 != primary } }

    init() {
        let notes = BetterNotes.shared
        let primary = Self.primaryGemma
        _primary = State(initialValue: primary)
        _more = State(initialValue: notes.server != nil || (notes.chosen != nil && notes.chosen != primary))
    }

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Sammanfattningar", detail: Self.headline(appleStatus)) { EmptyView() }
            CardDivider()
            appleRow
            CardDivider()
            notesRow(primary, primary: true)
            CardDivider()
            // The language they're written in, whoever writes them.
            CardRow(title: "Språk", detail: "Sammanfattningen skrivs på mötets språk om du inte väljer ett annat.") {
                MenuPicker(options: SummaryLanguage.allCases.map { ($0, $0.title) }, selection: $summaryLanguage)
                    .onChange(of: summaryLanguage) { _, new in SummaryLanguage.chosen = new }
            }
            CardDivider()
            FoldRow(title: String(localized: "Fler alternativ"),
                    detail: primary == .small
                        ? String(localized: "En större Gemma, eller en modell du redan kör i Ollama eller LM Studio.")
                        : String(localized: "En mindre Gemma, eller en modell du redan kör i Ollama eller LM Studio."),
                    open: $more)
            if more {
                ForEach(otherGemmas) { m in
                    CardDivider()
                    notesRow(m, primary: false)
                }
                CardDivider()
                ServerWriterRows(folded: false)
            }
        }
        .card()
        // Chosen elsewhere meanwhile (the menu bar, a test): shown where it is.
        .onChange(of: notes.choice) { _, now in
            if notes.server != nil || otherGemmas.contains(where: { now == .gemma($0) }) { more = true }
        }
        .task(id: NotesModel.allCases.map { "\($0.isInstalled)" }.joined()) {
            onDisk = await DiskSize.measure(NotesModel.allCases.map(\.directory))
        }
        .task { await servers.refresh() }     // Ollama and LM Studio: here, running, and their models
        // A Gemma moved to the Trash in Finder (or put back) shows as it is.
        .onAppear { notes.refresh(); appleStatus = Polisher.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notes.refresh()
            appleStatus = Polisher.status
        }
        .confirmationDialog(confirmDownload.map { String(localized: "Ladda ned \($0.name) (\($0.sizeText))?") } ?? "",
                            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
                            presenting: confirmDownload) { m in
            Button("Ladda ned") { notes.download(m) }
            Button("Avbryt", role: .cancel) {}
        } message: { m in
            Text("Den laddas ned i bakgrunden medan du använder Mindtalk och fungerar sedan utan internet. Du har \(BetterNotes.gigabytes(BetterNotes.freeBytes)) ledigt.")
                + Text(verbatim: m.page.host.map { " " + String(localized: "Från \($0).") } ?? "")
        }
        .confirmationDialog(confirmRemove.map { String(localized: "Ta bort \($0.name)?") } ?? "",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { m in
            Button("Ta bort", role: .destructive) { notes.remove(m); confirmRemove = nil }
            Button("Avbryt", role: .cancel) {}
        } message: { m in
            if m.isInstalled {
                // Who writes next, as removing will leave it: said only when this one writes now.
                if notes.chosen != m {
                    Text("Den kan laddas ned igen senare.")
                } else if let next = notes.successor(of: m) {
                    Text("Den kan laddas ned igen senare. \(next.name) skriver sammanfattningarna så länge.")
                } else if Polisher.status == .available {
                    Text("Den kan laddas ned igen senare. Apple Intelligence skriver sammanfattningarna så länge.")
                } else {
                    Text("Den kan laddas ned igen senare.")
                }
            } else {
                Text("Det som laddats ned hittills tas bort. Du kan börja om senare.")
            }
        }
    }

    private var appleRow: some View {
        let status = appleStatus
        // Not here or not on: never shown as the one chosen, greyed out.
        return ModelRow(name: "Apple Intelligence", chooser: (!notes.isActive && status == .available, status == .available, { notes.choice = .apple }),
                        whenDisabled: Self.appleDetail(status)) {
            ModelParts.detail(Self.appleDetail(status))
        } trailing: {
            // Off: the one button that mends it, straight into System Settings.
            if status == .notEnabled {
                Button("Slå på") { Self.openAppleIntelligenceSettings() }.buttonStyle(.soft)
            }
        }
    }

    private func size(_ m: NotesModel) -> String {
        guard let bytes = onDisk[m.directory], bytes > 0 else { return m.sizeText }
        return DiskSize.text(bytes)
    }

    /// A Gemma's row. The primary one (shown with Apple Intelligence) says what it gives
    /// before what it costs; the other, under Fler alternativ, only what it costs.
    private func notesRow(_ m: NotesModel, primary: Bool) -> some View {
        let state = notes.state(m)
        let recommended = NotesModel.recommended == m
        let detail: String = {
            switch state {
            case .unsupported:
                return String(localized: "Kräver minst \(m.minimumMemoryGB) GB minne. Den här Macen har \(BetterNotes.memoryGB) GB.")
            case .ready:
                return String(localized: "Nedladdad. Tar \(size(m)).")
            case .failed(let message):
                return message
            case .missing, .downloading:
                var text = primary
                    ? String(localized: "Hittar fler beslut och uppgifter. \(m.sizeText), laddas ned en gång, kräver \(m.minimumMemoryGB) GB minne.")
                    : String(localized: "\(m.sizeText). Kräver minst \(m.minimumMemoryGB) GB minne.")
                // Not room for it: say how much more, so you can tell whether emptying
                // the Trash will do.
                if !m.hasRoom {
                    let short = max(100_000_000, m.remainingBytes + 2_000_000_000 - BetterNotes.freeBytes)
                    text += "\n" + String(localized: "Det får inte plats. Frigör \(BetterNotes.gigabytes(short)) till.")
                }
                return text
            }
        }()
        // The one that suits this Mac (NotesModel.recommended weighs the memory and the disk).
        // Shown as chosen while it is, even gone from the disk: then its row says so
        // and offers the download, and a summary says why it wasn't written.
        return ModelRow(name: m.name, badge: recommended ? String(localized: "Rekommenderas för din Mac") : nil,
                        chooser: (notes.chosen == m, state == .ready || notes.chosen == m, { notes.chosen = m })) {
            ModelParts.detail(detail)
        } trailing: {
            switch state {
            case .unsupported:
                EmptyView()
            case .downloading(let p):
                HStack(spacing: 10) {
                    ModelParts.progress(p)
                    Button("Avbryt") { notes.cancel() }.buttonStyle(.soft)
                }
            case .ready:
                // Downloaded says the detail line; the round button says whether it writes.
                Menu {
                    Button("Visa i Finder") { DiskSize.reveal(m.directory) }
                    Divider()
                    // Not while it may be writing a summary (a meeting ending, an import).
                    if MeetingSession.shared.isBusy || MeetingImport.shared.busy {
                        Button("Ta bort… (går när mötet eller importen är klar)") {}.disabled(true)
                    } else {
                        Button("Ta bort…", role: .destructive) { confirmRemove = m }
                    }
                } label: { ModelParts.more }
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
                            Button("Ta bort det nedladdade…", role: .destructive) { confirmRemove = m }
                        } label: { ModelParts.more }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Mer")
                    }
                }
            }
        }
    }
}

// MARK: - Allmänt

/// "Modellerna tar 3,4 GB": everything Mindtalk has downloaded, and where it is.
struct ModelsFootprintRow: View {
    @State private var total: Int64?

    var body: some View {
        CardRow(title: total.map { String(localized: "Modellerna tar \(DiskSize.text($0))") } ?? String(localized: "Modellerna"),
                detail: total == nil ? String(localized: "Räknar ihop…") : String(localized: "Allt Mindtalk har laddat ned för tal, röster och sammanfattningar.")) {
            Button("Visa i Finder") { DiskSize.reveal(SpeechModel.rootDirectory) }.buttonStyle(.soft)
        }
        .task {
            let root = SpeechModel.rootDirectory
            total = await DiskSize.measure([root])[root]
        }
    }
}

// MARK: - Parts

/// What the model rows share.
enum ModelParts {
    static func detail(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func progress(_ p: Double) -> some View {
        HStack(spacing: 8) {
            InkProgressBar(progress: p).frame(width: 90)
            Text(p, format: .percent.precision(.fractionLength(0))).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
        }
    }

    /// The files are in; now it's checked and made ready for this Mac.
    static var preparing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Förbereder…").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
        }
    }

    /// ⋯ in a small chip disc, for Finder and removing.
    static var more: some View {
        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(DS.Colors.chip))
            .contentShape(Rectangle())
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

/// A row that folds what's under it: the title and a line, a chevron that turns. The
/// whole row opens it, not only the chevron.
struct FoldRow: View {
    let title: String
    let detail: String
    @Binding var open: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title).font(.system(size: 14, weight: .semibold))
                    Text(verbatim: detail)
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Ollama and LM Studio

/// The writers in other apps on this Mac, folded under "Använd Ollama eller LM Studio":
/// open by itself only when one of them writes now. Inside, one row each (running or
/// not, its models to pick from, Testa), where the models come from, and the ports.
struct ServerWriterRows: View {
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var servers = LocalServers.shared
    /// Behind its own fold; or, inside "Fler alternativ" on the Sammanfattningar card,
    /// always open under a plain heading.
    private let folded: Bool
    @State private var open: Bool
    @State private var ports = false
    /// The ports as typed: taken on Return, not at every keystroke.
    @State private var portText: [ServerBackend: String] = [:]

    init(folded: Bool = true) {
        self.folded = folded
        _open = State(initialValue: !folded || BetterNotes.shared.server != nil)
    }

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
        if folded {
            FoldRow(title: String(localized: "Använd Ollama eller LM Studio"),
                    detail: String(localized: "Kör du redan Ollama eller LM Studio? De kan skriva sammanfattningarna."),
                    open: $open)
                // Chosen elsewhere meanwhile (the menu bar, a test): shown.
                .onChange(of: notes.server?.backend) { _, now in if now != nil { open = true } }
        } else {
            CardRow(title: "Använd Ollama eller LM Studio", detail: "Kör du redan Ollama eller LM Studio? De kan skriva sammanfattningarna.") { EmptyView() }
        }
        if open {
            ForEach(ServerBackend.allCases) { backend in
                CardDivider()
                row(backend)
            }
            RowInset {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hämta modeller i Ollama eller LM Studio. Mindtalk skickar bara till program på den här Macen. Molnmodeller visas inte.")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    // A plain disclosure group only opens on its chevron: here the word opens it too.
                    Button { withAnimation(.easeOut(duration: 0.2)) { ports.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(ports ? 90 : 0))
                            Text("Portar").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(DS.Colors.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Portar"))
                    .accessibilityAddTraits(ports ? [.isButton, .isSelected] : .isButton)
                    if ports {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ändra bara om du har bytt port i Ollama eller LM Studio. Tryck på retur för att prova.")
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
        return ModelRow(name: backend.name,
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
                // LM Studio's list can't tell a model on another computer (LM Link) from one
                // here: said while it writes.
                if backend == .lmStudio, on {
                    Text("Är LM Studio kopplad till en annan dator kan mötet skickas dit. Koppla bort den för möten som ska stanna här.")
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
                        Button("Visa modeller") { SettingsPage.open(.meetings) }
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
