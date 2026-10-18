import SwiftUI

// MARK: - First run
//
// Eight steps — welcome → language (starts the download) → permissions (while it
// downloads) → try it for real, with your key → a thought, for real → meetings (and
// the voice model, if you want it) → the word list → what you have now, with Gemma
// offered if it fits (OnboardingReadyStep.swift) — and then Hem. Each feature gets its
// own step that says what to do and when. With Reduce Motion on, it's all calm and still.

struct OnboardingView: View {
    @ObservedObject var dictation: Dictation
    let finish: () -> Void

    /// Past "Prova": the introduction counts as done even if its window is closed now
    /// (closing earlier brings it back at the next launch).
    static var pastTry = false

    enum Step: Int, CaseIterable { case welcome, language, permissions, tryIt, thoughts, meetings, vocabulary, ready }

    @State private var step: Step = OnboardingView.firstStep

    private static var firstStep: Step {
        #if DEBUG
        let names: [String: Step] = ["welcome": .welcome, "language": .language, "permissions": .permissions, "key": .tryIt,
                                     "tryIt": .tryIt, "more": .thoughts,
                                     "thoughts": .thoughts, "meetings": .meetings, "vocabulary": .vocabulary,
                                     "ready": .ready]
        if let name = Demo.onboardingStep, let step = names[name] { return step }
        #endif
        return .welcome
    }
    @State private var chosen: Set<SpeechModel> = [Settings.engine]
    /// The listener for the word list (100 MB), fetched along with the speech model —
    /// ticked from the start; it's small and makes names right as you speak.
    @State private var listener = OnboardingView.defaultListener
    /// The voice model for meetings (400 MB): ticked — small, and needed for meetings.
    @State private var voices = OnboardingView.defaultVoices
    /// Gemma: not ticked — big, and Apple Intelligence writes summaries without it.
    @State private var gemma = false
    /// Which Gemma, when the Mac runs both: the recommended one if it fits next to the
    /// rest, else the one that does.
    @State private var gemmaPick: NotesModel? = LanguageStep.defaultGemma(
        besides: LanguageStep.others(chosen: [Settings.engine], listener: OnboardingView.defaultListener, voices: OnboardingView.defaultVoices))

    /// Ticked from the start on the first run only: shown again, something you removed
    /// under Modeller stays removed unless you tick it yourself.
    static var defaultListener: Bool { !Settings.didOnboard && !VocabularyBoost.isInstalled }
    static var defaultVoices: Bool { !Settings.didOnboard && !VoiceModels.isInstalled }
    @State private var forward = true
    /// The feature steps (Tankar, Möten, Ordlista) you've tried — "Fortsätt" rather than
    /// "Hoppa över". Kept per step, so one stays done when you go back to it.
    @State private var completed: Set<Step> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            DS.Colors.paper
            VStack(spacing: 0) {
                ProgressSegments(count: Step.allCases.count, current: step.rawValue)
                    .padding(.top, 20)

                ZStack {
                    // Every step hangs from the same line, so the title stays put between
                    // them; only the welcome sits in the middle.
                    stepView
                        .padding(.top, step == .welcome ? 0 : 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: step == .welcome ? .center : .top)
                        .id(step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 60)

                footer
                    .padding(.leading, 24)   // "Tillbaka" brings 8 pt of its own hit area
                    .padding(.trailing, 32)
                    .padding(.bottom, 26)
            }
            .frame(width: 760, height: 640)
        }
        #if DEBUG
        .task { if Demo.autoDownload { await autoDownload() } }
        #endif
        // The steps keep their size; the paper fills whatever holds them —
        // its own window at first launch, the main window when shown again.
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
    }

    /// Slide and focus; with Reduce Motion just a quick fade.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: StepShift(offset: forward ? 40 : -40), identity: StepShift(offset: 0)),
            removal: .modifier(active: StepShift(offset: forward ? -40 : 40), identity: StepShift(offset: 0)))
    }

    #if DEBUG
    /// Walks the download test: both models, then on to "Prova", logging as it goes.
    private func autoDownload() async {
        try? await Task.sleep(for: .seconds(1.5))
        chosen = Set(SpeechModel.allCases)
        primary()
        try? await Task.sleep(for: .seconds(20))
        go(1)
    }
    #endif

    @ViewBuilder private var stepView: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .language: LanguageStep(chosen: $chosen, listener: $listener, voices: $voices, gemma: $gemma, gemmaPick: $gemmaPick)
        case .permissions: PermissionsStep(dictation: dictation)
        case .tryIt: TryStep(dictation: dictation)
        case .thoughts: ThoughtsStep(dictation: dictation, done: tried(.thoughts))
        case .meetings: MeetingsStep(done: tried(.meetings))
        case .vocabulary: VocabularyStep(dictation: dictation, done: tried(.vocabulary))
        case .ready: ReadyStep(dictation: dictation)
        }
    }

    /// One step's "tried it" — once set, it stays.
    private func tried(_ s: Step) -> Binding<Bool> {
        Binding(get: { completed.contains(s) },
                set: { if $0 { completed.insert(s) } })
    }

    // MARK: Footer

    /// Tankar and Möten before you've tried them: a quiet way past, not a call to action.
    private var skipping: Bool {
        (step == .thoughts || step == .meetings) && !completed.contains(step)
    }

    /// "Prova" while the speech model gets ready: going on is possible, but waiting is
    /// what's asked for — the next steps need it too.
    private var waitingForModel: Bool {
        step == .tryIt && dictation.model != .ready && permitted
    }

    private var permitted: Bool { dictation.micGranted && dictation.accessibilityGranted }

    private var footer: some View {
        HStack(spacing: 14) {
            if step != .welcome {
                Button { go(-1) } label: {
                    Label("Tillbaka", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.muted)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            // While you go through the steps; "Prova" shows it in the box itself — unless the
            // box is asking for a permission. From "Prova" on just a ring and a number, so
            // the footer keeps to one line.
            if step == .permissions || step.rawValue >= Step.thoughts.rawValue || (step == .tryIt && !permitted) {
                DownloadStatus(dictation: dictation, compact: step.rawValue >= Step.tryIt.rawValue)
            }
            Spacer(minLength: 8)
            if step.rawValue >= Step.thoughts.rawValue, step != .ready {
                Button { done() } label: {
                    Text("Avsluta introduktionen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.muted)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Du hittar allt i appen sen")
                .transition(.opacity)
            }
            if skipping || waitingForModel {
                // The same shape as the ink button, in chip grey: a quiet way past.
                Button(action: primary) {
                    Text(waitingForModel ? "Fortsätt ändå" : "Hoppa över")
                        .contentTransition(.opacity)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 22)
                        .frame(height: 42)
                        .background(Capsule().fill(DS.Colors.chip))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .transition(.opacity)
            } else {
                // Return only where there's nothing to type or say into.
                GlowButton(title: primaryTitle, action: primary)
                    .keyboardShortcut(step.rawValue <= Step.permissions.rawValue || step == .ready ? .defaultAction : nil)
                    .transition(.opacity)
            }
        }
        .lineLimit(1)
        .frame(height: 44)
        .animation(.snappy(duration: 0.25), value: step)
        .animation(.snappy(duration: 0.3), value: skipping)
        .animation(.snappy(duration: 0.3), value: waitingForModel)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return String(localized: "Kom igång")
        case .language:
            // Already on its way (the introduction shown again): nothing more to fetch.
            let missing = SpeechModel.allCases.filter { chosen.contains($0) && !$0.isInstalled && dictation.downloads[$0] == nil }
            let extra = Self.extras(listener: listener, voices: voices, gemma: gemma ? gemmaPick : nil)
            if missing.isEmpty, extra == 0 { return String(localized: "Fortsätt") }
            let bytes = missing.reduce(Int64(0)) { $0 + $1.downloadBytes } + extra
            return String(localized: "Ladda ned \(RecommendedDownloads.size(bytes)) och fortsätt")
        case .ready: return String(localized: "Sätt igång")
        default: return String(localized: "Fortsätt")
        }
    }

    /// What the ticked extras still have to fetch, in bytes.
    private static func extras(listener: Bool, voices: Bool, gemma: NotesModel?) -> Int64 {
        var bytes: Int64 = 0
        if listener, !VocabularyBoost.isInstalled, VocabularyBoostStatus.shared.state == .missing { bytes += 100_000_000 }
        if voices, VoiceModels.shared.state == .missing { bytes += 400_000_000 }
        if let m = gemma, case .missing = BetterNotes.shared.state(m) { bytes += m.remainingBytes }
        return bytes
    }

    private func primary() {
        switch step {
        case .language:
            // The language you already use stays if it's among those chosen — the
            // introduction shown again shouldn't switch it. Otherwise Swedish first.
            let order = SpeechModel.allCases.filter(chosen.contains)
            if !chosen.contains(dictation.engine), let first = order.first { dictation.setEngine(first) }
            // Back here with other choices: what's no longer chosen stops before the rest starts.
            for m in SpeechModel.allCases where !chosen.contains(m) { dictation.cancelDownload(m) }
            for m in order where !m.isInstalled { dictation.downloadModel(m) }
            if listener { Vocabulary.shared.fetchListener() }
            if voices, VoiceModels.shared.state == .missing { VoiceModels.shared.download() }
            // Gemma only if it fits next to everything else on its way, with room to spare.
            let others = LanguageStep.others(chosen: chosen, listener: listener, voices: voices)
            if gemma, let m = gemmaPick, LanguageStep.fits(m, besides: others), case .missing = BetterNotes.shared.state(m) {
                BetterNotes.shared.download(m)
            }
            go(1)
        case .vocabulary:
            VocabularyStep.commitPending?()   // a word typed but not added
            go(1)
        case .ready:
            done()
        default:
            go(1)
        }
    }

    private func done() {
        dictation.stopPickingKey()
        finish()
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        // On from "Prova": closing the window now counts as done.
        // Past "Prova": done, even if Mindtalk is quit before the last step — and the
        // day the first-day card on Hem counts from.
        if step == .tryIt, delta > 0 {
            // Only the first time through: shown again later, the first day stays the first day.
            let firstRun = !Settings.didOnboard
            OnboardingView.pastTry = true
            Settings.didOnboard = true
            if firstRun, UserDefaults.standard.object(forKey: "introFinishedAt") == nil {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "introFinishedAt")
            }
        }
        forward = delta > 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.12)) { step = next }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 26) {
            // The sphere of light that listens in meetings — breathing on its night tile,
            // like the app's icon. On dark paper a faint edge keeps the tile from melting in.
            Constellation(figure: nil, color: .white, level: 0.3)
                .frame(width: 210, height: 210)
                .offset(y: 18)
                .frame(width: 168, height: 168)
                .background(RoundedRectangle(cornerRadius: 38, style: .continuous).fill(DS.Colors.night))
                .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.1 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
                .staggered(0)
                .accessibilityHidden(true)
            // Dictation, thoughts, meetings — one line each, back to where it began.
            Typewriter(text: String(localized: "Prata. Vi skriver."),
                       font: .system(size: 50, weight: .regular, design: .serif),
                       delay: 0.7,
                       then: [String(localized: "Prata. Vi sparar tanken."),
                              String(localized: "Prata. Vi vet vem som sa vad."),
                              String(localized: "Prata. Vi skriver.")],
                       repeats: true,
                       cursorHeight: 44)
            Text("Diktera i alla appar, spara tankar och spela in möten. Allt stannar på din Mac.")
                .font(.system(size: 15.5)).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .staggered(2)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Step 2: Language

private struct LanguageStep: View {
    @Binding var chosen: Set<SpeechModel>
    @Binding var listener: Bool
    @Binding var voices: Bool
    @Binding var gemma: Bool
    @Binding var gemmaPick: NotesModel?
    @ObservedObject private var notes = BetterNotes.shared

    /// The Gemmas this Mac runs, largest first — none once one is in use, and none if
    /// not even the smallest fits.
    static var gemmaOptions: [NotesModel] {
        guard BetterNotes.shared.active == nil else { return [] }
        let options = NotesModel.allCases.reversed().filter(\.supported)
        return options.contains(where: \.hasRoom) ? Array(options) : []
    }

    /// The best one that fits next to the rest: the recommended one when there's room for it.
    static func defaultGemma(besides others: Int64) -> NotesModel? {
        gemmaOptions.first { fits($0, besides: others) }
    }

    /// Room for a Gemma next to everything else that's ticked, with 2 GB to spare —
    /// as Modeller counts (RecommendedDownloads).
    static func fits(_ m: NotesModel, besides others: Int64) -> Bool {
        m.remainingBytes + others + 2_000_000_000 <= BetterNotes.freeBytes
    }

    /// What the speech models and the small extras still have to fetch.
    static func others(chosen: Set<SpeechModel>, listener: Bool, voices: Bool) -> Int64 {
        var bytes = SpeechModel.allCases.filter { chosen.contains($0) && !$0.isInstalled }.reduce(Int64(0)) { $0 + $1.downloadBytes }
        if listener, !VocabularyBoost.isInstalled { bytes += VocabularyBoost.bytes }
        if voices, !VoiceModels.isInstalled { bytes += 400_000_000 }
        return bytes
    }

    private var others: Int64 { Self.others(chosen: chosen, listener: listener, voices: voices) }

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Vilket språk pratar du?",
                       subtitle: "Välj ett eller båda. Du byter med ett klick i menyraden. Allt hämtas en gång och körs på din Mac.")
                .staggered(0)
            HStack(spacing: 16) {
                ForEach(Array(SpeechModel.allCases.enumerated()), id: \.element) { i, m in
                    LanguageCard(model: m, selected: chosen.contains(m)) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
                            if chosen.contains(m) { if chosen.count > 1 { chosen.remove(m) } } else { chosen.insert(m) }
                        }
                    }
                    .staggered(i + 1)
                }
            }
            // Everything else worth having, fetched in the same go — so it's there by the
            // time the steps about meetings and the word list come.
            recommended.staggered(3)
        }
        // More ticked, less room: a Gemma that no longer fits next to the rest is unticked.
        .onChange(of: others) { _, now in
            if gemma, let m = gemmaPick, !Self.fits(m, besides: now) { gemma = false }
        }
    }
}

extension LanguageStep {
    @ViewBuilder fileprivate var recommended: some View {
        let showsVoices = !VoiceModels.isInstalled
        let showsListener = !VocabularyBoost.isInstalled
        let options = Self.gemmaOptions
        if showsVoices || showsListener || !options.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("Rekommenderas också. Laddas ned medan du går vidare.")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                // What each gives, in the same words as under Modeller.
                if showsVoices {
                    extra($voices, name: "Röstmodellen", gives: "hör vem som säger vad i möten", size: VoiceModels.sizeText)
                }
                if showsListener {
                    extra($listener, name: "Lyssnaren", gives: "stavar dina ord rätt redan när du pratar", size: VocabularyBoost.sizeText)
                }
                if options.count == 1, let m = options.first {
                    extra($gemma, name: m.name, gives: "ger mer träffsäkra sammanfattningar", size: m.sizeText)
                } else if !options.isEmpty {
                    // Both sizes: pick one, the recommended one marked.
                    extra($gemma, name: "Gemma 4", gives: "ger mer träffsäkra sammanfattningar", size: nil)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(options) { m in gemmaOption(m, largest: m == options.first) }
                    }
                    .padding(.leading, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .raised(cornerRadius: DS.Radius.panel)
        }
    }

    private func extra(_ on: Binding<Bool>, name: String, gives: LocalizedStringKey, size: String?) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(name)).font(.system(size: 13, weight: .semibold))
                Text(gives).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                Spacer(minLength: 8)
                if let size {
                    Text(verbatim: size).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                }
            }
        }
        .toggleStyle(InkCheckboxStyle())
    }

    /// One size of Gemma: picking it ticks Gemma too. One that doesn't fit says how much
    /// more room it needs.
    private func gemmaOption(_ m: NotesModel, largest: Bool) -> some View {
        let picked = gemmaPick == m
        let fits = Self.fits(m, besides: others)
        // Not ticked: the sizes wait, greyed — nothing here is on its way.
        let active = gemma
        return Button {
            withAnimation(.snappy(duration: 0.2)) { gemmaPick = m; gemma = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16)).foregroundStyle(picked && active ? DS.Colors.accent : DS.Colors.muted)
                Text(verbatim: m.name.replacingOccurrences(of: "Gemma 4 ", with: ""))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: "· \(m.sizeText) ·").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                Group {
                    if !fits {
                        Text("behöver \(BetterNotes.gigabytes(max(100_000_000, m.remainingBytes + others + 2_000_000_000 - BetterNotes.freeBytes))) mer ledigt")
                    } else if largest {
                        Text("mest träffsäker")
                    } else {
                        Text("snabbare, tar mindre plats")
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                if m == NotesModel.recommended {
                    Text("Rekommenderas för din Mac")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.chip))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!fits)
        .opacity(!fits ? 0.4 : active ? 1 : 0.5)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

private struct LanguageCard: View {
    let model: SpeechModel
    let selected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var recommended: Bool {
        model == SpeechModel.recommended
    }

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ModelBadge(model: model, size: 21, serif: true)
                        .foregroundStyle(selected ? DS.Colors.onInk : DS.Colors.accent)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(selected ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.chip)))
                        .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 10, y: 6)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(DS.Colors.muted))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: selected)
                }
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    Text(model.title).font(.system(size: 19, weight: .semibold))
                    if recommended {
                        // The same chip as the badges under Modeller.
                        Text("Rekommenderas")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(DS.Colors.chip))
                    }
                }
                Text(model.pitch)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                HStack(spacing: 6) {
                    Image(systemName: model.isInstalled ? "checkmark.seal.fill" : "arrow.down.circle")
                    Text(model.isInstalled ? String(localized: "\(model.modelName) · redan installerad")
                                           : String(localized: "\(model.modelName) · \(model.sizeText)"))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colors.muted)
                .padding(.top, 14)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 168)
            .raised(selected: selected)
            .overlay(
                // Hover without choosing: a hint of the ink edge.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(DS.Colors.ink.opacity(hovering && !selected ? 0.25 : 0), lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.012 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.3)) { hovering = h } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Step 3: Permissions

private struct PermissionsStep: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Två behörigheter",
                       subtitle: "Samma tillåtelse gäller diktering, tankar och möten.")
                .staggered(0)
            HStack(spacing: 16) {
                PermissionCard(icon: "hand.point.up.left.fill", title: "Hjälpmedel",
                               text: "Så att Mindtalk märker dina genvägar och skriver där markören står.",
                               granted: dictation.accessibilityGranted, button: "Öppna") { dictation.requestAccessibility() }
                    .staggered(1)
                PermissionCard(icon: "mic.fill", title: "Mikrofon",
                               text: "Hör dig bara när du dikterar, sparar en tanke eller spelar in ett möte. Ljudet lämnar aldrig din Mac.",
                               granted: dictation.micGranted, button: "Tillåt") { dictation.requestMicrophone() }
                    .staggered(2)
            }
            Group {
                if dictation.micGranted && dictation.accessibilityGranted {
                    GrantedLabel(text: "Allt klart. Fortsätt när du vill.")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else if !dictation.accessibilityGranted {
                    Label("Slå på Mindtalk under Integritet och säkerhet → Hjälpmedel. Kortet bockas av när det är klart.",
                          systemImage: "info.circle")
                        .foregroundStyle(DS.Colors.muted)
                        .transition(.opacity)
                } else {
                    Label("Tillåt mikrofonen, annars hör Mindtalk dig inte.", systemImage: "info.circle")
                        .foregroundStyle(DS.Colors.muted)
                        .transition(.opacity)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .multilineTextAlignment(.center)
            .staggered(3)
        }
        // Calm; the check mark's own bounce is the only spring here.
        .animation(.smooth(duration: 0.4), value: dictation.micGranted)
        .animation(.smooth(duration: 0.4), value: dictation.accessibilityGranted)
        .onAppear { dictation.refreshPermissions() }
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let text: String
    let granted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: granted ? "checkmark" : icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(granted ? DS.Colors.onInk : DS.Colors.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52)
                .background(Circle().fill(granted ? AnyShapeStyle(DS.Colors.ink) : AnyShapeStyle(DS.Colors.chip)))
                .shadow(color: .black.opacity(granted ? 0.18 : 0), radius: 10, y: 4)
                .symbolEffect(.bounce, value: granted)
            Text(LocalizedStringKey(title))
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 18)
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            Spacer(minLength: 16)
            if granted {
                GrantedLabel()
                    .frame(height: 34)
                    .transition(.opacity)
            } else {
                Button(LocalizedStringKey(button), action: action)
                    .buttonStyle(.ink)
                    .frame(height: 34)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 236)
        .raised()
    }
}

// MARK: - Step 4: Try it — your key and a box to talk into

private struct TryStep: View {
    @ObservedObject var dictation: Dictation
    /// The key sinks and "Vi hör dig" follows every level — this step is about the voice.
    @ObservedObject private var meter = Dictation.shared.meter
    @State private var practice = ""
    @State private var celebrated = false
    @State private var confetti = 0
    /// Words came out of a dictation (not typed): only then is there something to celebrate.
    @State private var dictated = false
    /// "Klart, prova nu!" for a moment when the speech model becomes ready while you wait.
    @State private var justReady = false
    /// The box gets the cursor by itself once there's something to talk into.
    @FocusState private var boxFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ready: Bool { dictation.model == .ready }
    /// Both permissions — without them talking into the box would do nothing.
    private var permitted: Bool { dictation.accessibilityGranted && dictation.micGranted }
    private var recording: Bool { dictation.phase == .recording }
    private var hearing: Bool { recording && (meter.levels.suffix(8).max() ?? 0) > 0.08 }

    private var subtitle: LocalizedStringResource {
        if celebrated { return "Din första text, utan att skriva ett ord. Det fungerar i alla appar." }
        if !permitted { return "Snart kan du prova. Först behövs din tillåtelse." }
        if ready { return "Klicka i rutan, håll in \(dictation.hotkey.inlineName) och säg något." }
        return "Du kan prova så fort talmodellen är klar."
    }

    var body: some View {
        // Top: the confetti fills the step, the rest hangs from the title line.
        ZStack(alignment: .top) {
            VStack(spacing: 24) {
                StepHeader(title: celebrated ? "Snyggt." : "Prova på riktigt",
                           subtitle: subtitle)
                    .staggered(0)
                    .animation(.easeOut(duration: 0.3), value: celebrated)
                    .overlay(alignment: .bottom) {
                        if justReady {
                            Label("Klart, prova nu!", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Colors.onInk)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(DS.Colors.ink))
                                .offset(y: 8)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                VStack(spacing: 10) {
                    Keycap(text: dictation.pickingKey ? "…" : dictation.hotkey.chip, pressed: recording,
                           isCombination: !dictation.pickingKey && dictation.hotkey.modifierKeys.count > 1)
                        .scaleEffect(0.8)
                        .frame(height: 84)
                    Group {
                        if dictation.pickingKey {
                            Text("Håll in tangenterna du vill ha (⌃ ⌥ ⇧ ⌘) och släpp. Esc avbryter.")
                        } else if hearing {
                            Text("Vi hör dig!").foregroundStyle(DS.Colors.ink)
                        } else if dictation.phase == .transcribing {
                            Text("Skriver…")
                        } else if let refusal = dictation.keyRefusal {
                            // The thought key's: said for a moment, then the link is back.
                            Text(verbatim: refusal).foregroundStyle(DS.Colors.ink)
                        } else {
                            Button {
                                dictation.pickKey()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Välj en annan genväg")
                                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!dictation.accessibilityGranted)
                            .help(dictation.accessibilityGranted ? String(localized: "Klicka och håll in tangenterna du vill använda. Släpp för att spara.")
                                                                  : String(localized: "Tillåt Hjälpmedel i förra steget för att välja genväg."))
                        }
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520, minHeight: 18)
                }
                .staggered(1)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $practice)
                        .font(.system(size: 19))
                        .scrollContentBackground(.hidden)
                        .focused($boxFocused)
                        .padding(16)
                        .frame(height: celebrated ? 96 : 130)
                        .raised(cornerRadius: DS.Radius.panel, selected: !practice.isEmpty)
                    if practice.isEmpty && ready && permitted {
                        Text("”Hej! Det här är min första diktering.”")
                            .font(.system(size: 19))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, 21).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(!ready || !permitted)
                .overlay {
                    // What stands in the way first: a permission, then the model.
                    if !dictation.accessibilityGranted {
                        Blocker(title: String(localized: "Slå på Hjälpmedel först"), button: String(localized: "Öppna")) {
                            dictation.requestAccessibility()
                        }
                        .transition(.opacity)
                    } else if !dictation.micGranted {
                        Blocker(title: String(localized: "Tillåt mikrofonen för att prova"), button: String(localized: "Tillåt")) {
                            dictation.requestMicrophone()
                        }
                        .transition(.opacity)
                    } else if !ready {
                        ModelState(dictation: dictation)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: ready)
                .animation(.easeOut(duration: 0.3), value: permitted)
                .staggered(2)
                // After the first words: the rest of the key, as a reward rather than a lesson.
                if celebrated {
                    HStack(spacing: 12) {
                        KeyHint(icon: "hand.tap.fill", title: "Håll in", text: "prata, släpp, klart")
                        KeyHint(icon: "lock.fill", title: "Dubbeltryck", text: "prata utan att hålla")
                        KeyHint(icon: "escape", title: "Esc", text: "avbryter")
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            Confetti(trigger: confetti)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.2), value: celebrated)
        .onAppear { dictation.refreshPermissions() }
        // The cursor in the box once there's something to talk into — after the entrance,
        // and again when the model becomes ready while you wait.
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            if ready && permitted { boxFocused = true }
        }
        .onChange(of: ready && permitted) { _, now in
            guard now else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { boxFocused = true }
        }
        // Typing into the box is no dictation: the words have to come from a press.
        .onChange(of: practice) { _, _ in celebrateIfDictated() }
        .onChange(of: dictation.phase) { old, _ in
            if old == .transcribing, !dictation.forThought {
                dictated = true
                celebrateIfDictated()
            }
        }
        // Waited for it: a sound and a moment's "Klart, prova nu!", so you notice even
        // if you looked away.
        .onChange(of: dictation.model) { old, new in
            guard new == .ready, old != .ready, !celebrated else { return }
            Cue.done()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.25)) { justReady = true }
            AccessibilityNotification.Announcement(String(localized: "Klart, prova nu!")).post()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                withAnimation(.easeOut(duration: 0.3)) { justReady = false }
            }
        }
        .onDisappear { dictation.stopPickingKey() }
    }

    /// Words in the box, and they were dictated: the first text, celebrated once.
    private func celebrateIfDictated() {
        guard !celebrated, dictated, !practice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        celebrated = true
        confetti += 1
        Cue.celebrate()
    }
}

struct KeyHint: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(DS.Colors.chip))
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey(text)).font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 180)
        .raised(cornerRadius: 14)
    }
}

/// A big physical-looking key that sinks while you hold it.
struct Keycap: View {
    let text: String
    let pressed: Bool
    let isCombination: Bool

    var body: some View {
        ZStack {
            // The key's side, visible below the top face.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DS.Colors.fieldStroke)
                .offset(y: 7)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [DS.Colors.field, DS.Colors.card], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(pressed ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.fieldStroke), lineWidth: 1.5))
                .overlay(
                    Text(text)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .foregroundStyle(pressed ? DS.Colors.accent : .primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 18)
                )
                .offset(y: pressed ? 6 : 0)
        }
        .frame(width: isCombination ? 480 : 190, height: 96)
        .shadow(color: .black.opacity(pressed ? 0.18 : 0.12), radius: pressed ? 10 : 14, y: pressed ? 6 : 10)
        .animation(.spring(duration: 0.2, bounce: 0.35), value: pressed)
        .accessibilityLabel(String(localized: "Din genväg: \(text)"))
    }
}

/// Until the model is ready, the box says what's happening — downloading (with
/// MB and time left), getting ready, or what went wrong — instead of inviting
/// you to talk when nothing would happen yet.
struct ModelState: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 12) {
                switch dictation.model {
                // "Talmodellen" rather than the language's name — "Flerspråkig" isn't a
                // thing you can make ready.
                case .downloading(let p):
                    Text(SpeechModel.isPreparing(p) ? String(localized: "Talmodellen förbereds")
                                                    : String(localized: "Talmodellen laddas ned"))
                        .font(.system(size: 16, weight: .semibold))
                    InkProgressBar(progress: min(1, p / 0.9))
                        .frame(width: 300)
                    Text(dictation.engine.progressText(p, started: dictation.downloadStarted[dictation.engine]))
                        .font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                case .loading:
                    ProgressView().controlSize(.regular)
                    Text("Talmodellen görs redo för din Mac").font(.system(size: 16, weight: .semibold))
                    // The first time on a Mac it starts on the GPU — about half a minute
                    // (measured 29 s); the Neural Engine is prepared later, unseen.
                    let minutes = Int(Date().timeIntervalSince(dictation.loadingSince) / 60)
                    Text(minutes < 1 ? String(localized: "Det tar ungefär en halv minut, bara första gången.")
                                     : String(localized: "Det tar en liten stund, bara första gången. \(minutes) min hittills."))
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    // Wait here: the next steps try things out, and they need it too.
                    Text("Vänta gärna här. Sedan provar du direkt.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(DS.Colors.warning)
                    // Downloaded but wouldn't start, or never arrived — retryModel() knows which.
                    Text(dictation.engine.isInstalled ? String(localized: "Talmodellen startade inte")
                                                      : String(localized: "Talmodellen laddades inte ned"))
                        .font(.system(size: 16, weight: .semibold))
                    // A model that wouldn't start gets no system error text — just a retry.
                    if !dictation.engine.isInstalled {
                        Text(message).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                    Button("intro|Försök igen") { dictation.retryModel() }.buttonStyle(.ink)
                case .missing:
                    Text("Talmodellen är inte nedladdad").font(.system(size: 16, weight: .semibold))
                    Button("Ladda ned \(dictation.engine.sizeText)") { dictation.downloadModel() }.buttonStyle(.ink)
                case .ready:
                    EmptyView()
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
    }
}

/// A permission still missing, in the box where you'd talk — with the way to fix it.
private struct Blocker: View {
    let title: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Button(button, action: action).buttonStyle(.ink)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
}

// MARK: - Shared pieces

/// A step's title and what to do. Always the same height — room for two lines of
/// subtitle — so the title sits on the same line on every step. VoiceOver reads the
/// new step out when it comes in, wherever you are (on "Fortsätt", usually).
/// An announcement rather than moving focus: `accessibilityFocused` turns the title
/// into something ImageRenderer can't draw.
struct StepHeader: View {
    /// Resources, not strings: every title and line is then found by the string
    /// extractor, so none can go stale in the catalog.
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(DS.pageTitle)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 15.5))
                .foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: 640)
        .frame(height: 104, alignment: .top)
        // After the step has slid in, so it isn't cut off by the one leaving.
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            let heading = String(localized: title)
            let stop = heading.last.map { ".?!".contains($0) } == true ? " " : ". "
            AccessibilityNotification.Announcement(heading + stop + String(localized: subtitle)).post()
        }
    }
}

/// The ink primary button, with an arrow that leans forward on hover.
struct GlowButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .contentTransition(.opacity)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .offset(x: hovering ? 3 : 0)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.Colors.onInk)
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(Capsule().fill(DS.Colors.ink))
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: 10, y: 6)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(duration: 0.3)) { hovering = h } }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Thin segments across the top: done, current, still to come.
private struct ProgressSegments: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                // Done: the grey of a past day's bar. Now: ink, wider. Still to come: a divider's grey.
                Capsule()
                    .fill(i == current ? DS.Colors.ink : i < current ? DS.Colors.barPast : DS.Colors.divider)
                    .frame(width: i == current ? 34 : 18, height: 4)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Steg \(current + 1) av \(count)"))
    }
}

/// The downloads, next to the Back button: a ring, the model, MB and time left —
/// or what went wrong, with a way to try again. The speech models and, once Möten
/// has asked for it, the voice model. `compact` (from "Prova" on, where the footer
/// also holds "Avsluta introduktionen"): only a ring and a percentage each — the
/// whole sentence is in the tooltip and for VoiceOver — plus the name when there's
/// just one.
struct DownloadStatus: View {
    @ObservedObject var dictation: Dictation
    var compact = false
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var listener = VocabularyBoostStatus.shared

    /// One thing on its way, or one that went wrong.
    private struct Item: Identifiable {
        let id: String
        let name: String
        /// nil: it failed.
        let progress: Double?
        /// A speech model spends its last tenth preparing for this Mac; the others don't.
        var speech = false
        /// The files are in and it's being made ready (the voice model, between its bundles).
        var preparing = false
        let detail: String
        let retry: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        for m in SpeechModel.allCases {
            if let p = dictation.downloads[m] {
                items.append(Item(id: m.rawValue, name: m.title, progress: p, speech: true,
                                  detail: m.progressText(p, started: dictation.downloadStarted[m]), retry: {}))
            } else if dictation.downloadErrors[m] != nil {
                items.append(Item(id: m.rawValue, name: m.title, progress: nil, speech: true,
                                  detail: String(localized: "\(m.title) laddades inte ned"),
                                  retry: { dictation.downloadModel(m) }))
            }
        }
        switch voices.state {
        case .downloading(let p):
            items.append(Item(id: "voices", name: String(localized: "Röstmodellen"), progress: p, preparing: voices.preparing,
                              detail: String(localized: "\(Self.percent(p)) %"), retry: {}))
        case .failed:
            items.append(Item(id: "voices", name: String(localized: "Röstmodellen"), progress: nil,
                              detail: String(localized: "Röstmodellen laddades inte ned"),
                              retry: { VoiceModels.shared.download() }))
        default: break
        }
        switch listener.state {
        case .downloading:
            items.append(Item(id: "listener", name: String(localized: "Lyssnaren"), progress: 0, preparing: true,
                              detail: String(localized: "Lyssnaren laddas ned"), retry: {}))
        case .failed:
            items.append(Item(id: "listener", name: String(localized: "Lyssnaren"), progress: nil,
                              detail: String(localized: "Lyssnaren laddades inte ned"),
                              retry: { Vocabulary.shared.fetchListener() }))
        default: break
        }
        for m in NotesModel.allCases {
            switch notes.state(m) {
            case .downloading(let p):
                items.append(Item(id: "notes", name: m.name, progress: p, detail: String(localized: "\(Self.percent(p)) %"), retry: {}))
            case .failed:
                items.append(Item(id: "notes", name: m.name, progress: nil,
                                  detail: String(localized: "\(m.name) laddades inte ned"),
                                  retry: { BetterNotes.shared.download(m) }))
            default: break
            }
        }
        return items
    }

    /// The speech models spend their last tenth preparing for this Mac.
    private static func percent(_ p: Double, model: Bool = false) -> Int {
        Int((model ? min(1, p / 0.9) : p) * 100)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let items = self.items
            HStack(spacing: compact ? 12 : 18) {
                ForEach(items) { item in
                    if compact { compactRow(item, named: items.count == 1) } else { fullRow(item) }
                }
            }
            .padding(.leading, compact ? 4 : 10)
            .animation(.easeOut(duration: 0.25), value: items.map(\.id))
        }
    }

    @ViewBuilder private func fullRow(_ item: Item) -> some View {
        if let p = item.progress {
            HStack(spacing: 9) {
                ProgressRing(progress: p).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12.5, weight: .semibold))
                    Text(item.preparing ? String(localized: "Förbereds") : item.detail)
                        .font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.detail).font(.system(size: 12.5, weight: .semibold))
                    retryButton(item)
                }
            }
        }
    }

    @ViewBuilder private func compactRow(_ item: Item, named: Bool) -> some View {
        let model = item.speech
        Group {
            if let p = item.progress {
                let preparing = item.preparing || (model && SpeechModel.isPreparing(p))
                let amount = String(localized: "\(Self.percent(p, model: model)) %")
                HStack(spacing: 6) {
                    ProgressRing(progress: p).frame(width: 16, height: 16)
                    Text(preparing ? (named ? String(localized: "\(item.name) förbereds") : String(localized: "Förbereds"))
                                   : (named ? "\(item.name) \(amount)" : amount))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "\(item.name) laddas ned, \(Self.percent(p, model: model)) procent"))
                .help(String(localized: "\(item.name) laddas ned · \(item.detail)"))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                    retryButton(item)
                }
                .help(item.detail)
            }
        }
        .fixedSize()
    }

    private func retryButton(_ item: Item) -> some View {
        Button("intro|Försök igen", action: item.retry)
            .buttonStyle(.plain)
            .font(.system(size: compact ? 12 : 11.5, weight: .semibold))
            .foregroundStyle(DS.Colors.accent)
            .accessibilityHint(item.detail)
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.divider, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(DS.Gradients.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
    }
}

// MARK: - The living logo

/// The app icon, alive — the wave rolls and the cursor blinks. It floats gently.
/// Types its text one character at a time, with a blinking cursor at the end.
struct Typewriter: View {
    let text: String
    let font: Font
    var delay: Double = 0
    /// Lines it rewrites itself into, one after another: the end is erased back to
    /// what they share ("Prata. Vi ") and the new end typed — the last one stays.
    var then: [String] = []
    /// Goes round again after the last line, for as long as it's on screen.
    var repeats = false
    var cursorHeight: CGFloat = 46
    @State private var line: String?
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: String { line ?? text }

    var body: some View {
        if reduceMotion {
            // Still: the line it ends on, with a cursor that stays lit.
            HStack(spacing: 3) {
                Text(then.last ?? text).font(font)
                cursor
            }
            .lineLimit(1)
            .accessibilityElement()
            .accessibilityLabel(then.last ?? text)
        } else {
            typing
        }
    }

    private var cursor: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(DS.Gradients.accent)
            .frame(width: 3, height: cursorHeight)
    }

    private var typing: some View {
        ZStack(alignment: .leading) {
            // The whole line, invisible, keeps the layout still while typing — and
            // widens smoothly when the next line is longer.
            Text(current).font(font).opacity(0)
            HStack(spacing: 3) {
                Text(String(current.prefix(shown))).font(font)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let on = shown < current.count || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    cursor.opacity(on ? 1 : 0)
                }
            }
        }
        .lineLimit(1)
        .animation(.smooth(duration: 0.45), value: line)
        .accessibilityElement()
        .accessibilityLabel(text)
        .task {
            try? await Task.sleep(for: .seconds(delay))
            await type(text, from: 0)
            repeat {
                for next in then {
                    guard !Task.isCancelled else { return }
                    await rewrite(to: next)
                }
            } while repeats && !Task.isCancelled
        }
    }

    /// Erases back to the last whole word the lines share ("Prata. Vi "), then types the rest.
    private func rewrite(to next: String) async {
        try? await Task.sleep(for: .seconds(2.2))
        guard !Task.isCancelled else { return }
        var keep = zip(current, next).prefix { $0 == $1 }.count
        while keep > 0, Array(current)[keep - 1] != " " { keep -= 1 }
        while shown > keep, !Task.isCancelled {
            shown -= 1
            try? await Task.sleep(for: .milliseconds(32))
        }
        line = next
        try? await Task.sleep(for: .milliseconds(320))   // the line makes room first
        await type(next, from: keep)
    }

    private func type(_ line: String, from start: Int) async {
        let chars = Array(line)
        for i in start..<chars.count {
            guard !Task.isCancelled else { return }
            shown = i + 1
            // A small pause after a full stop, like someone speaking.
            try? await Task.sleep(for: .milliseconds(chars[i] == "." ? 260 : Int.random(in: 45...85)))
        }
    }
}

// MARK: - Step transitions & entrances

/// Steps slide a little and come into focus. Not with Reduce Motion — then the
/// shell fades them instead (see `stepTransition`).
private struct StepShift: ViewModifier {
    let offset: CGFloat
    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(offset == 0 ? 1 : 0)
            .blur(radius: offset == 0 ? 0 : 8)
    }
}

// MARK: - Confetti

/// A short burst of paper in black, white and greys, falling with a little spin.
struct Confetti: View {
    let trigger: Int
    @State private var start: Date?
    @State private var pieces: [Piece] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Piece {
        let x: Double, vx: Double, vy: Double, spin: Double, size: Double, color: Color, round: Bool, delay: Double
    }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { ctx, size in
                guard let start else { return }
                let now = context.date.timeIntervalSince(start)
                for p in pieces {
                    let t = now - p.delay
                    guard t > 0 else { continue }
                    // A little air resistance on the sideways drift, gravity downwards.
                    let x = p.x * size.width + p.vx * (1 - exp(-1.6 * t)) / 1.6
                    let y = size.height + 10 + p.vy * t + 620 * t * t
                    guard y < size.height + 40 else { continue }
                    var c = ctx
                    c.opacity = max(0, min(1, 3.4 - now))
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    let r = CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.round ? p.size : p.size / 2)
                    c.fill(p.round ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: 1.5), with: .color(p.color))
                }
            }
        }
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            let colors: [Color] = [DS.Colors.ink, Color(white: 0.55), Color(white: 0.75), Color(white: 0.35), Color(white: 0.9)]
            // Two cannons in the bottom corners, aimed up and inwards.
            pieces = (0..<160).map { i in
                let left = i % 2 == 0
                return Piece(x: left ? 0.04 : 0.96,
                             vx: (left ? 1 : -1) * Double.random(in: 180...620),
                             vy: Double.random(in: -1060 ... -620),
                             spin: Double.random(in: -10...10), size: Double.random(in: 6...12),
                             color: colors.randomElement()!, round: Bool.random() && Bool.random(),
                             delay: Double.random(in: 0...0.25))
            }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { start = nil }
        }
    }
}
