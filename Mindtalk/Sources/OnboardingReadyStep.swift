import ServiceManagement
import SwiftUI

// MARK: - Step 8: Det här har du nu
//
// The last step says what you have: each thing with a tick when it works, its key,
// or how far its download has come — and what still stands in the way, with the one
// button that fixes it. Where the summaries come from, with the one thing worth
// adding (Gemma) offered here, once, if it fits. Then where Mindtalk lives: in the
// menu bar, started at login if it is.

struct ReadyStep: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var listener = VocabularyBoostStatus.shared

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Det här har du nu.",
                       subtitle: "Diktering och tankar fungerar i vilken app som helst. Resten finns i Mindtalk.")
                .staggered(0)
            VStack(spacing: 0) {
                dictationRow
                divider
                thoughtsRow
                divider
                meetingsRow
                divider
                wordsRow
                divider
                summariesRow
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .raised(cornerRadius: DS.Radius.panel)
            .staggered(1)
            HStack(spacing: 10) {
                MenuBarChip()
                // Registered when the introduction ends, so said here already.
                Text(SMAppService.mainApp.status == .enabled
                     || (AppMover.runsFromApplications && !UserDefaults.standard.bool(forKey: "loginItemRegistered"))
                     ? "Mindtalk finns i menyraden och startar när du loggar in."
                                                             : "Mindtalk finns i menyraden.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .staggered(2)
        }
    }

    /// Between the rows, from the text's left edge: the mark stands clear of it.
    private var divider: some View {
        Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.leading, 44)
    }

    // MARK: Diktering and Tankar

    /// What stands between you and dictating, if anything: a permission first, then the model.
    private enum Blocker {
        case accessibility, microphone, modelFailed, modelMissing, downloading(Double), loading
    }

    private var blocker: Blocker? {
        if !dictation.accessibilityGranted { return .accessibility }
        if !dictation.micGranted { return .microphone }
        switch dictation.model {
        case .ready: return nil
        case .loading: return .loading
        case .failed: return .modelFailed
        case .missing: return .modelMissing
        case .downloading(let p): return .downloading(p)
        }
    }

    @ViewBuilder private var dictationRow: some View {
        let keys = dictation.hotkey.chip
        let works = dictation.mode == .toggle ? String(localized: "Tryck på tangenten och prata, så hamnar texten där markören står.")
                                              : String(localized: "Håll in tangenten och prata, så hamnar texten där markören står.")
        switch blocker {
        case nil:
            ReadyRow(icon: "mic", state: .ready, title: "Diktering", keys: keys, detail: works)
        case .loading:
            ReadyRow(icon: "mic", state: .waiting, title: "Diktering", keys: keys,
                     detail: String(localized: "Talmodellen görs redo för din Mac. Sedan fungerar det så här: \(works)"))
        case .downloading(let p):
            ReadyRow(icon: "mic", state: .progress(min(1, p / 0.9)), title: "Diktering", keys: keys,
                     detail: SpeechModel.isPreparing(p) ? String(localized: "Talmodellen förbereds för din Mac.")
                                                        : String(localized: "Talmodellen laddas ned (\(Int(min(1, p / 0.9) * 100)) %)."))
        case .accessibility:
            ReadyRow(icon: "mic", state: .optional, title: "Diktering", keys: keys,
                     detail: String(localized: "Behöver Hjälpmedel för att känna av tangenten och skriva in texten.")) {
                Button("Öppna") { dictation.requestAccessibility() }.buttonStyle(SoftButtonStyle(small: true))
            }
        case .microphone:
            ReadyRow(icon: "mic", state: .optional, title: "Diktering", keys: keys,
                     detail: String(localized: "Behöver mikrofonen för att höra dig.")) {
                Button("Tillåt") { dictation.requestMicrophone() }.buttonStyle(SoftButtonStyle(small: true))
            }
        case .modelFailed:
            ReadyRow(icon: "mic", state: .optional, title: "Diktering", keys: keys,
                     detail: dictation.engine.isInstalled ? String(localized: "Talmodellen startade inte.")
                                                          : String(localized: "Talmodellen laddades inte ned.")) {
                Button("intro|Försök igen") { dictation.retryModel() }.buttonStyle(SoftButtonStyle(small: true))
            }
        case .modelMissing:
            ReadyRow(icon: "mic", state: .optional, title: "Diktering", keys: keys,
                     detail: String(localized: "Talmodellen är inte nedladdad (\(dictation.engine.sizeText)).")) {
                Button("Ladda ned") { dictation.downloadModel() }.buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    @ViewBuilder private var thoughtsRow: some View {
        let keys = Settings.thoughtShortcut?.chip
        let works = Settings.thoughtShortcut == nil ? String(localized: "Säg en tanke på sidan Tankar.")
                                                    : String(localized: "Det du kommer på hamnar i Tankar.")
        switch blocker {
        case nil:
            ReadyRow(icon: "lightbulb", state: .ready, title: "Tankar", keys: keys, detail: works)
        case .loading, .downloading:
            ReadyRow(icon: "lightbulb", state: .waiting, title: "Tankar", keys: keys, detail: works)
        default:
            // The same thing stands in the way; the button is on the row above.
            ReadyRow(icon: "lightbulb", state: .optional, title: "Tankar", keys: keys,
                     detail: String(localized: "Fungerar så fort dikteringen gör det."))
        }
    }

    // MARK: Möten

    @ViewBuilder private var meetingsRow: some View {
        let keys = Settings.meetingShortcut?.chip.replacingOccurrences(of: " ", with: "")
        switch voices.state {
        case .ready:
            ReadyRow(icon: "person.2.wave.2", state: .ready, title: "Möten", keys: keys,
                     detail: String(localized: "Spelar in möten i rummet och samtal på datorn, och håller isär vem som säger vad."))
        case .downloading(let p):
            ReadyRow(icon: "person.2.wave.2", state: .progress(p), title: "Möten", keys: keys,
                     detail: voices.preparing ? String(localized: "Röstmodellen förbereds. Sedan kan du starta ett möte.")
                                              : String(localized: "Röstmodellen laddas ned (\(Int(p * 100)) %). Sedan kan du starta ett möte."))
        case .missing, .failed:
            ReadyRow(icon: "person.2.wave.2", state: .optional, title: "Möten", keys: nil,
                     detail: String(localized: "Behöver röstmodellen för att hålla isär vem som pratar.")) {
                Button("Ladda ned \(VoiceModels.sizeText)") { VoiceModels.shared.download() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    // MARK: Ordlista

    @ViewBuilder private var wordsRow: some View {
        switch listener.state {
        case .ready:
            ReadyRow(icon: "character.book.closed", state: .ready, title: "Ordlista", keys: nil,
                     detail: String(localized: "Lyssnaren hör dina ord, så de stavas rätt redan när du pratar."))
        case .downloading:
            ReadyRow(icon: "character.book.closed", state: .waiting, title: "Ordlista", keys: nil,
                     detail: String(localized: "Lyssnaren laddas ned. Sedan stavas dina ord rätt redan när du pratar."))
        case .missing, .failed:
            ReadyRow(icon: "character.book.closed", state: .optional, title: "Ordlista", keys: nil,
                     detail: String(localized: "Med lyssnaren stavas namn och ord rätt redan när du pratar.")) {
                Button("Ladda ned \(VocabularyBoost.sizeText)") { Vocabulary.shared.fetchListener() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    // MARK: Sammanfattningar

    @ViewBuilder private var summariesRow: some View {
        if notes.isActive {
            ReadyRow(icon: "sparkle", state: .ready, title: "Sammanfattningar", keys: nil,
                     detail: String(localized: "Skrivs av \(notes.writerName) på din Mac.")) { EmptyView() }
        } else if let m = notes.downloading, case .downloading(let p) = notes.state(m) {
            ReadyRow(icon: "sparkle", state: .progress(p), title: "Sammanfattningar", keys: nil,
                     detail: Polisher.status == .available
                        ? String(localized: "\(m.name) laddas ned (\(Int(p * 100)) %). Till dess skriver Apple Intelligence.")
                        : String(localized: "\(m.name) laddas ned (\(Int(p * 100)) %). Sedan skrivs sammanfattningarna.")) { EmptyView() }
        } else if let m = OnboardingView.pendingGemma {
            ReadyRow(icon: "sparkle", state: .waiting, title: "Sammanfattningar", keys: nil,
                     detail: Polisher.status == .available
                        ? String(localized: "\(m.name) laddas ned när talmodellen är klar. Till dess skriver Apple Intelligence.")
                        : String(localized: "\(m.name) laddas ned när talmodellen är klar. Sedan skrivs sammanfattningarna.")) { EmptyView() }
        } else {
            // Apple Intelligence writes them; what a Gemma adds is said on the Möten page and in
            // Settings, not here. Off: the one button that mends it.
            switch Polisher.status {
            case .available:
                ReadyRow(icon: "sparkle", state: .ready, title: "Sammanfattningar", keys: nil,
                         detail: String(localized: "Skrivs av \("Apple Intelligence") på din Mac.")) { EmptyView() }
            case .notEnabled:
                ReadyRow(icon: "sparkle", state: .optional, title: "Sammanfattningar", keys: nil,
                         detail: String(localized: "Slå på Apple Intelligence, så skrivs de på din Mac.")) {
                    Button("Slå på") { SummaryWritersCard.openAppleIntelligenceSettings() }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
            case .notReady:
                ReadyRow(icon: "sparkle", state: .waiting, title: "Sammanfattningar", keys: nil,
                         detail: String(localized: "macOS laddar fortfarande ned Apple Intelligence. Det brukar ta några minuter.")) { EmptyView() }
            case .unsupported:
                ReadyRow(icon: "sparkle", state: .optional, title: "Sammanfattningar", keys: nil,
                         detail: NotesModel.recommended != nil
                             ? String(localized: "Den här Macen kan inte köra Apple Intelligence. Du kan ladda ned Gemma 4 under Inställningar → Möten.")
                             : String(localized: "Den här Macen kan inte köra Apple Intelligence.")) { EmptyView() }
            }
        }
    }
}

/// One thing you have: a tick (or a ring while it downloads), its name and key, a line.
private struct ReadyRow<Action: View>: View {
    enum State: Equatable { case ready, waiting, optional, progress(Double) }

    let icon: String
    let state: State
    let title: LocalizedStringKey
    let keys: String?
    let detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            mark
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let keys {
                        KeyChip(text: keys, small: true)
                            .accessibilityLabel(Text(verbatim: keys))
                    }
                }
                Text(detail).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Colors.onInk)
                .frame(width: 26, height: 26).background(Circle().fill(DS.Colors.accent))
                .accessibilityLabel(Text("Klart"))
        case .waiting:
            ProgressView().controlSize(.small)
        case .optional:
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .frame(width: 26, height: 26).background(Circle().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
        case .progress(let p):
            ZStack {
                Circle().stroke(DS.Colors.chip, lineWidth: 3)
                Circle().trim(from: 0, to: p).stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            .animation(.smooth(duration: 0.3), value: p)
        }
    }
}

extension ReadyRow where Action == EmptyView {
    init(icon: String, state: State, title: LocalizedStringKey, keys: String?, detail: String) {
        self.init(icon: icon, state: state, title: title, keys: keys, detail: detail) { EmptyView() }
    }
}
