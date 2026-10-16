import SwiftUI

// MARK: - Step 8: Nu kör vi
//
// The last step says what you have: each thing with a tick when it works, its key,
// or how far its download has come — and where the summaries come from, with the
// one thing worth adding (Gemma) offered here, once, if it fits. Then where Mindtalk
// lives: in the menu bar, started at login.

struct ReadyStep: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var notes = BetterNotes.shared

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Nu kör vi",
                       subtitle: "Det här fungerar nu – i vilken app som helst.")
                .staggered(0)
            VStack(spacing: 0) {
                ReadyRow(icon: "mic", state: dictation.model == .ready ? .ready : .waiting,
                         title: "Diktering", keys: dictation.hotkey.chip,
                         detail: dictation.mode == .toggle ? String(localized: "Tryck på tangenten och prata – texten hamnar där markören står.")
                                                           : String(localized: "Håll in tangenten och prata – texten hamnar där markören står."))
                CardDivider()
                ReadyRow(icon: "lightbulb", state: dictation.model == .ready ? .ready : .waiting,
                         title: "Tankar", keys: Settings.thoughtShortcut?.chip.replacingOccurrences(of: " ", with: ""),
                         detail: Settings.thoughtShortcut == nil ? String(localized: "Säg en tanke på sidan Tankar.")
                                                                  : String(localized: "Det du kommer på hamnar i Tankar."))
                CardDivider()
                meetingsRow
                CardDivider()
                summariesRow
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .raised(cornerRadius: DS.Radius.panel)
            .staggered(1)
            HStack(spacing: 10) {
                MenuBarChip()
                Text("Mindtalk finns i menyraden och fortsätter när du stänger fönstret. Den startar när du loggar in – ändra under Inställningar.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .staggered(2)
        }
    }

    // MARK: Möten

    @ViewBuilder private var meetingsRow: some View {
        let keys = Settings.meetingShortcut?.chip.replacingOccurrences(of: " ", with: "")
        switch voices.state {
        case .ready:
            ReadyRow(icon: "person.2.wave.2", state: .ready, title: "Möten", keys: keys,
                     detail: String(localized: "Spelar in ett möte i rummet och håller isär vem som säger vad."))
        case .downloading(let p):
            ReadyRow(icon: "person.2.wave.2", state: .progress(p), title: "Möten", keys: keys,
                     detail: String(localized: "Röstmodellen laddas ned – \(Int(p * 100)) %. Du kan börja under tiden."))
        case .missing, .failed:
            ReadyRow(icon: "person.2.wave.2", state: .optional, title: "Möten", keys: nil,
                     detail: String(localized: "Behöver röstmodellen för att hålla isär vem som pratar.")) {
                Button("Ladda ned \(VoiceModels.sizeText)") { VoiceModels.shared.download() }
                    .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    // MARK: Sammanfattningar

    /// The best Gemma this Mac runs that also fits on the disk.
    private var gemma: NotesModel? {
        NotesModel.allCases.reversed().first { $0.supported && $0.hasRoom }
    }

    /// A larger Gemma this Mac runs, but that doesn't fit on the disk now — said, so you
    /// know it's there (Inställningar → Modeller).
    private var larger: NotesModel? {
        guard let best = NotesModel.recommended, best != gemma, !best.hasRoom else { return nil }
        return best
    }

    @ViewBuilder private var summariesRow: some View {
        if let active = notes.active {
            ReadyRow(icon: "sparkle", state: .ready, title: "Sammanfattningar", keys: nil,
                     detail: String(localized: "Skrivs av \(active.name) på din Mac."))
        } else if let m = notes.downloading, case .downloading(let p) = notes.state(m) {
            ReadyRow(icon: "sparkle", state: .progress(p), title: "Sammanfattningar", keys: nil,
                     detail: String(localized: "\(m.name) laddas ned – \(Int(p * 100)) %. Till dess skriver Apple Intelligence."))
        } else {
            let apple = MeetingNotes.isAvailable
            ReadyRow(icon: "sparkle", state: apple ? .ready : .optional, title: "Sammanfattningar", keys: nil,
                     detail: (gemma.map { m in
                         apple ? String(localized: "Skrivs av Apple Intelligence. Vill du ha mer träffsäkra? \(m.name) från Google hittar fler beslut och uppgifter (\(m.sizeText)).")
                               : String(localized: "\(m.name) från Google skriver dem på din Mac (\(m.sizeText)).")
                     } ?? (apple ? String(localized: "Skrivs av Apple Intelligence.")
                                 : String(localized: "Kräver Apple Intelligence – eller Gemma när det finns plats på disken.")))
                     + (larger.map { " " + String(localized: "Den större \($0.name) (\($0.sizeText)) passar också din Mac – frigör \(BetterNotes.gigabytes(max(100_000_000, $0.remainingBytes + 2_000_000_000 - BetterNotes.freeBytes))) till, så går den att välja under Inställningar → Modeller.") } ?? "")) {
                if let m = gemma {
                    Button("Ladda ned") { notes.download(m) }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .disabled(notes.downloading != nil)
                }
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
                        KeyChip(text: keys)
                            .scaleEffect(0.85, anchor: .leading)
                            .accessibilityLabel(Text(verbatim: keys))
                    }
                }
                Text(detail).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Colors.onInk)
                .frame(width: 26, height: 26).background(Circle().fill(DS.Colors.ink))
                .accessibilityLabel(Text("Klart"))
        case .waiting:
            ProgressView().controlSize(.small)
        case .optional:
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .frame(width: 26, height: 26).background(Circle().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
        case .progress(let p):
            ZStack {
                Circle().stroke(DS.Colors.chip, lineWidth: 3)
                Circle().trim(from: 0, to: p).stroke(DS.Colors.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
