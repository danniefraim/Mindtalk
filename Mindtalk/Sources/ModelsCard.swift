import AppKit
import SwiftUI

// MARK: - Inställningar → Modeller
//
// Every model Mindtalk uses, by what it does: speech (dictation, meetings and
// thoughts), the voices in meetings, the summaries, and the word list's listener.
// Each says how big it is and what it needs, and can be shown in Finder or removed;
// at the foot, what they take together. For the summaries you choose which writes:
// Apple Intelligence, built in, or a Gemma 4 you've downloaded — the one that suits
// this Mac's memory is marked.

struct ModelsCard: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var meeting = MeetingSession.shared
    /// What each folder takes on disk — counted when the card shows.
    @State private var onDisk: [URL: Int64] = [:]
    @State private var total: Int64?
    @State private var confirmDownload: NotesModel?
    @State private var confirmRemove: Removal?

    private enum Removal: Identifiable {
        case speech(SpeechModel), voices, notes(NotesModel)
        var id: String {
            switch self {
            case .speech(let m): return "speech-\(m.rawValue)"
            case .voices: return "voices"
            case .notes(let m): return "notes-\(m.rawValue)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Tal", "Skriver ned det du säger – när du dikterar, i möten och för tankar.") {
                ForEach(Array(SpeechModel.allCases.enumerated()), id: \.element) { i, m in
                    if i > 0 { CardDivider() }
                    speechRow(m)
                }
            }
            group("Röster i möten", "Håller isär vem som pratar och känner igen röster till nästa gång.") {
                voicesRow
                CardDivider()
                row(name: "ReDimNet", detail: String(localized: "Känner igen röster mellan möten · följer med appen")) {
                    Text("Inbyggd").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                }
            }
            group("Sammanfattningar", "Skriver sammanfattningen av ett möte och svarar på dina frågor. Välj vilken som skriver.") {
                appleRow
                ForEach(NotesModel.allCases) { m in
                    CardDivider()
                    notesRow(m)
                }
            }
            group("Ordlistan", nil) {
                row(name: "Parakeet CTC",
                    detail: VocabularyBoost.isInstalled
                        ? String(localized: "Hör orden i din ordlista · \(size(VocabularyBoost.directory, fallback: VocabularyBoost.sizeText))")
                        : String(localized: "Hör orden i din ordlista · laddas ned (\(VocabularyBoost.sizeText)) när du lägger till ett eget ord")) {
                    if VocabularyBoost.isInstalled { finderMenu(VocabularyBoost.directory) }
                }
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
        .confirmationDialog(confirmDownload.map { String(localized: "Ladda ned \($0.name) (\($0.sizeText))?") } ?? "",
                            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
                            presenting: confirmDownload) { m in
            Button("Ladda ned") { notes.download(m) }
            Button("Avbryt", role: .cancel) {}
        } message: { m in
            Text("Den laddas ned i bakgrunden – du kan använda Mindtalk under tiden – och fungerar sedan utan internet. Du har \(BetterNotes.freeBytes / 1_000_000_000) GB ledigt.")
                + Text(verbatim: m.page.host.map { " " + String(localized: "Från \($0).") } ?? "")
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { what in
            Button("Ta bort", role: .destructive) { remove(what) }
            Button("Avbryt", role: .cancel) {}
        } message: { what in
            switch what {
            case .speech: Text("Den kan laddas ned igen senare.")
            case .voices: Text("Möten kan inte spelas in förrän den laddats ned igen.")
            case .notes: Text("Den kan laddas ned igen senare. Apple Intelligence skriver sammanfattningarna så länge.")
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
        return row(name: m.modelName,
                   detail: language + " · " + (m.isInstalled ? size(m.ownDirectory, fallback: m.sizeText) : m.sizeText),
                   badge: inUse ? String(localized: "Används") : nil) {
            if let p = dictation.downloads[m] {
                progress(p)
            } else if m.isInstalled {
                Menu {
                    Button("Visa i Finder") { reveal(m.ownDirectory) }
                    if !inUse, m.isOwnInstall {
                        Divider()
                        Button("Ta bort…", role: .destructive) { confirmRemove = .speech(m) }
                    }
                } label: { moreLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(inUse ? "Den som används kan inte tas bort – byt språk under Inspelning först." : "Mer")
            } else {
                Button("Ladda ned") { dictation.downloadModel(m) }.buttonStyle(.soft)
            }
        }
    }

    // MARK: Voices

    private var voicesRow: some View {
        row(name: "Nemotron 3",
            detail: String(localized: "Från NVIDIA · ") + (VoiceModels.isInstalled ? size(VoiceModels.directory, fallback: VoiceModels.sizeText) : VoiceModels.sizeText)) {
            switch voices.state {
            case .downloading(let p):
                progress(p)
            case .ready:
                Menu {
                    Button("Visa i Finder") { reveal(VoiceModels.directory) }
                    Divider()
                    Button("Ta bort…", role: .destructive) { confirmRemove = .voices }.disabled(meeting.isBusy)
                } label: { moreLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mer")
            case .missing, .failed:
                Button("Ladda ned") { voices.download() }.buttonStyle(.soft)
            }
        }
    }

    // MARK: Summaries

    private var appleRow: some View {
        let status = Polisher.status
        let detail: String = {
            switch status {
            case .available: return String(localized: "Inbyggd i macOS · alla Macar med Apple Intelligence")
            case .notEnabled: return String(localized: "Slå på Apple Intelligence i Systeminställningar för att använda den.")
            case .notReady: return String(localized: "macOS laddar fortfarande ned den.")
            case .unsupported: return String(localized: "Finns inte på den här Macen.")
            }
        }()
        return row(name: "Apple Intelligence", detail: detail, chooser: (notes.active == nil, status == .available, { notes.chosen = nil })) {
            EmptyView()
        }
    }

    private func notesRow(_ m: NotesModel) -> some View {
        let state = notes.state(m)
        let recommended = NotesModel.recommended == m
        let detail: String = {
            switch state {
            case .unsupported:
                return String(localized: "Kräver minst \(m.minimumMemoryGB) GB minne – den här Macen har \(BetterNotes.memoryGB) GB.")
            case .ready:
                return String(localized: "Från Google · \(size(m.directory, fallback: m.sizeText)) · från \(m.minimumMemoryGB) GB minne")
            case .failed(let message):
                return message
            case .missing, .downloading:
                var text = String(localized: "Från Google · \(m.sizeText) · från \(m.minimumMemoryGB) GB minne")
                if !m.hasRoom { text += " · " + String(localized: "det behövs mer ledigt utrymme") }
                return text
            }
        }()
        return row(name: m.name, detail: detail, badge: recommended && state != .unsupported ? String(localized: "Rekommenderas för din Mac") : nil,
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
                Button(partly ? String(localized: "Fortsätt – \(BetterNotes.gigabytes(m.remainingBytes)) kvar") : String(localized: "Ladda ned")) {
                    if partly { notes.download(m) } else { confirmDownload = m }
                }
                .buttonStyle(.soft)
                .disabled(!m.hasRoom || notes.downloading != nil)
            }
        }
    }

    // MARK: Parts

    private func group<C: View>(_ title: LocalizedStringKey, _ detail: LocalizedStringKey?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
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
        HStack(alignment: .center, spacing: 14) {
            if let chooser {
                Button(action: chooser.pick) {
                    Image(systemName: chooser.on ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(chooser.on ? DS.Colors.ink : DS.Colors.muted)
                }
                .buttonStyle(.plain)
                .disabled(!chooser.enabled)
                .opacity(chooser.enabled ? 1 : 0.35)
                .help(chooser.enabled ? "Använd för sammanfattningarna" : "Ladda ned den först")
                .accessibilityLabel(Text("Använd \(name)"))
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
                Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func progress(_ p: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: p).tint(DS.Colors.ink).frame(width: 90)
            Text(p, format: .percent.precision(.fractionLength(0))).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
        }
    }

    private var moreLabel: some View {
        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            .frame(width: 28, height: 26).contentShape(Rectangle())
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
        case nil: return ""
        }
    }

    private func remove(_ what: Removal) {
        switch what {
        case .speech(let m): dictation.removeModel(m)
        case .voices: voices.remove()
        case .notes(let m): notes.remove(m)
        }
        confirmRemove = nil
    }
}

/// Which writes a meeting's summary — in Settings → Möten, beside the rest.
struct SummaryWriterRow: View {
    @ObservedObject private var notes = BetterNotes.shared

    var body: some View {
        let ready = NotesModel.allCases.filter { notes.state($0) == .ready }
        CardRow(title: "Sammanfattningarna skrivs av",
                detail: ready.isEmpty
                    ? (NotesModel.recommended.map { String(localized: "Apple Intelligence. \($0.name) skriver mer träffsäkert – den laddar du ned under Modeller.") }
                       ?? String(localized: "Apple Intelligence."))
                    : String(localized: "Fler val under Modeller.")) {
            if !ready.isEmpty {
                MenuPicker(options: [(value: Optional<NotesModel>.none, title: "Apple Intelligence")] + ready.map { (value: Optional($0), title: $0.name) },
                           selection: Binding(get: { notes.active }, set: { notes.chosen = $0 }))
            }
        }
        .card()
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
