import SwiftUI

// MARK: - First run
//
// Seven steps — welcome → language (starts the download) → permissions (while it
// downloads) → try it for real, with your key → a thought, for real → meetings (and
// the voice model, if you want it) → the word list — and then Hem. Each feature gets
// its own step that says what to do and when (OnboardingThoughts/Meetings/
// VocabularyStep.swift). Gemma never here. With Reduce Motion on, it's all calm and still.

struct OnboardingView: View {
    @ObservedObject var dictation: Dictation
    let finish: () -> Void

    enum Step: Int, CaseIterable { case welcome, language, permissions, tryIt, thoughts, meetings, vocabulary }

    @State private var step: Step = OnboardingView.firstStep

    private static var firstStep: Step {
        #if DEBUG
        let names: [String: Step] = ["welcome": .welcome, "language": .language, "permissions": .permissions, "key": .tryIt,
                                     "tryIt": .tryIt, "more": .thoughts,
                                     "thoughts": .thoughts, "meetings": .meetings, "vocabulary": .vocabulary]
        if let name = Demo.onboardingStep, let step = names[name] { return step }
        #endif
        return .welcome
    }
    @State private var chosen: Set<SpeechModel> = [Settings.engine]
    @State private var forward = true
    /// The feature steps (Tankar, Möten, Ordlista): tried — "Fortsätt" rather than "Hoppa över".
    @State private var stepDone = false

    var body: some View {
        ZStack {
            DS.Colors.paper
            VStack(spacing: 0) {
                ProgressSegments(count: Step.allCases.count, current: step.rawValue)
                    .padding(.top, 20)

                ZStack {
                    stepView
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .modifier(active: StepShift(offset: forward ? 40 : -40), identity: StepShift(offset: 0)),
                            removal: .modifier(active: StepShift(offset: forward ? -40 : 40), identity: StepShift(offset: 0))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 60)

                footer
                    .padding(.horizontal, 32)
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
        case .language: LanguageStep(chosen: $chosen)
        case .permissions: PermissionsStep(dictation: dictation)
        case .tryIt: TryStep(dictation: dictation)
        case .thoughts: ThoughtsStep(dictation: dictation, done: $stepDone)
        case .meetings: MeetingsStep(done: $stepDone)
        case .vocabulary: VocabularyStep(dictation: dictation, done: $stepDone)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if step != .welcome {
                Button { go(-1) } label: {
                    Label("Tillbaka", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.muted)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            // While you go through the steps; "Prova" shows it in the box itself.
            if step == .permissions || step.rawValue >= Step.thoughts.rawValue { DownloadStatus(dictation: dictation) }
            Spacer()
            if step.rawValue >= Step.thoughts.rawValue, step != .vocabulary {
                Button("Avsluta introduktionen") { done() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .help("Allt finns kvar i appen när du vill")
            }
            GlowButton(title: primaryTitle, action: primary)
                .keyboardShortcut(step == .tryIt || step == .vocabulary ? nil : .defaultAction)
        }
        .frame(height: 44)
        .animation(.snappy(duration: 0.25), value: step)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return String(localized: "Kom igång")
        case .language:
            let missing = SpeechModel.allCases.filter { chosen.contains($0) && !$0.isInstalled }
            if missing.isEmpty { return String(localized: "Fortsätt") }
            let bytes = missing.reduce(Int64(0)) { $0 + $1.downloadBytes }
            return String(localized: "Ladda ned \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) och fortsätt")
        case .vocabulary: return String(localized: "Öppna Mindtalk")
        case .thoughts, .meetings: return stepDone ? String(localized: "Fortsätt") : String(localized: "Hoppa över")
        default: return String(localized: "Fortsätt")
        }
    }

    private func primary() {
        switch step {
        case .language:
            // Swedish first if chosen — it becomes the active language.
            let order = SpeechModel.allCases.filter(chosen.contains)
            if let first = order.first { dictation.setEngine(first) }
            for m in order where !m.isInstalled { dictation.downloadModel(m) }
            go(1)
        case .vocabulary:
            VocabularyStep.commitPending?()   // a word typed but not added
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
        forward = delta > 0
        stepDone = false
        withAnimation(.spring(duration: 0.55, bounce: 0.12)) { step = next }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            // The sphere of light that listens in meetings — breathing on its night tile,
            // like the app's icon.
            Constellation(figure: nil, color: .white, level: 0.3)
                .frame(width: 210, height: 210)
                .offset(y: 18)
                .frame(width: 168, height: 168)
                .background(RoundedRectangle(cornerRadius: 38, style: .continuous).fill(DS.Colors.night))
                .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
                .staggered(0)
                .accessibilityHidden(true)
            Typewriter(text: String(localized: "Prata. Vi skriver."),
                       font: .system(size: 54, weight: .regular, design: .serif),
                       delay: 0.7)
            Text("Allt stannar på din Mac. Också ljudet.")
                .font(.system(size: 16)).foregroundStyle(DS.Colors.muted)
                .staggered(2)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Step 2: Language

private struct LanguageStep: View {
    @Binding var chosen: Set<SpeechModel>

    var body: some View {
        VStack(spacing: 26) {
            StepHeader(title: "Vilket språk pratar du?",
                       subtitle: "Välj ett eller båda. Hämtas en gång – sedan klarar du dig utan internet.")
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
            Text("Du byter språk med ett klick i menyraden.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .staggered(3)
        }
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
                    ModelBadge(model: model, size: 26, serif: true)
                        .foregroundStyle(selected ? DS.Colors.onInk : DS.Colors.accent)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(selected ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.chip)))
                        .shadow(color: DS.Colors.accent.opacity(selected ? 0.35 : 0), radius: 12, y: 5)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(DS.Colors.muted))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: selected)
                }
                Spacer(minLength: 18)
                HStack(spacing: 8) {
                    Text(model.title).font(.system(size: 19, weight: .semibold))
                    if recommended {
                        Text("Rekommenderas")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DS.Colors.accent)
                            .padding(.horizontal, 7).padding(.vertical, 2.5)
                            .background(Capsule().fill(DS.Colors.accent.opacity(0.12)))
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
            .frame(height: 232)
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
        VStack(spacing: 26) {
            StepHeader(title: "Två behörigheter, en gång",
                       subtitle: "Samma mikrofon används för diktering, tankar och möten – du frågas inte igen.")
                .staggered(0)
            HStack(spacing: 16) {
                PermissionCard(icon: "hand.point.up.left.fill", title: "Hjälpmedel",
                               text: "Så att Mindtalk märker dina genvägar och skriver där markören står.",
                               granted: dictation.accessibilityGranted, button: "Öppna") { dictation.requestAccessibility() }
                    .staggered(1)
                PermissionCard(icon: "mic.fill", title: "Mikrofon",
                               text: "Hör dig bara när du dikterar, säger en tanke eller spelar in ett möte. Ljudet lämnar aldrig din Mac.",
                               granted: dictation.micGranted, button: "Tillåt") { dictation.requestMicrophone() }
                    .staggered(2)
            }
            Group {
                if dictation.micGranted && dictation.accessibilityGranted {
                    GrantedLabel(text: "Allt klart – fortsätt när du vill.")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else if !dictation.accessibilityGranted {
                    Label("Slå på Mindtalk under Integritet och säkerhet → Hjälpmedel. Kortet bockas av när det är klart.",
                          systemImage: "info.circle")
                        .foregroundStyle(DS.Colors.muted)
                        .transition(.opacity)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .multilineTextAlignment(.center)
            .staggered(3)
        }
        .animation(.spring(duration: 0.45, bounce: 0.3), value: dictation.micGranted)
        .animation(.spring(duration: 0.45, bounce: 0.3), value: dictation.accessibilityGranted)
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

    private var ready: Bool { dictation.model == .ready }
    private var recording: Bool { dictation.phase == .recording }
    private var hearing: Bool { recording && (meter.levels.suffix(8).max() ?? 0) > 0.08 }

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                StepHeader(title: celebrated ? String(localized: "Snyggt.") : String(localized: "Prova på riktigt"),
                           subtitle: celebrated ? String(localized: "Din första text – utan att röra tangentbordet. Det fungerar i alla appar.")
                                                : ready ? String(localized: "Klicka i rutan, håll in \(dictation.hotkey.inlineName) och säg något.")
                                                        : String(localized: "Snart kan du prova – när talmodellen är klar."))
                    .staggered(0)
                    .animation(.easeOut(duration: 0.3), value: celebrated)
                VStack(spacing: 10) {
                    Keycap(text: dictation.pickingKey ? "…" : dictation.hotkey.chip, pressed: recording,
                           isCombination: !dictation.pickingKey && dictation.hotkey.modifierKeys.count > 1)
                        .scaleEffect(0.8)
                        .frame(height: 84)
                    Group {
                        if dictation.pickingKey {
                            Text("Håll in en eller flera modifieringstangenter tillsammans och släpp för att spara. Esc avbryter.")
                        } else if hearing {
                            Text("Vi hör dig!").foregroundStyle(DS.Colors.ink)
                        } else if dictation.phase == .transcribing {
                            Text("Skriver…")
                        } else {
                            Button(dictation.pickingKey ? String(localized: "Tryck på en tangent…") : String(localized: "Välj en annan genväg")) {
                                dictation.pickKey()
                            }
                            .buttonStyle(.plain)
                            .underline()
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
                        .padding(16)
                        .frame(height: celebrated ? 96 : 130)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.field))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(practice.isEmpty ? AnyShapeStyle(DS.Colors.fieldStroke) : AnyShapeStyle(DS.Colors.ink),
                                          lineWidth: practice.isEmpty ? 1 : 2))
                        .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
                    if practice.isEmpty && ready {
                        Text("”Hej! Det här är min första diktering.”")
                            .font(.system(size: 19))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, 21).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(!ready)
                .overlay {
                    if !ready {
                        ModelState(dictation: dictation)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: ready)
                .staggered(2)
                // After the first words: the rest of the key, as a reward rather than a lesson.
                if celebrated {
                    HStack(spacing: 12) {
                        KeyHint(icon: "hand.tap.fill", title: "Håll in", text: "för korta meddelanden")
                        KeyHint(icon: "lock.fill", title: "Dubbeltryck", text: "för att prata fritt")
                        KeyHint(icon: "escape", title: "Esc", text: "avbryter")
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            Confetti(trigger: confetti)
                .allowsHitTesting(false)
        }
        .animation(.spring(duration: 0.55, bounce: 0.2), value: celebrated)
        .onChange(of: practice) { _, text in
            guard !celebrated, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            celebrated = true
            confetti += 1
            Cue.celebrate()
        }
        .onDisappear { dictation.stopPickingKey() }
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
        .shadow(color: pressed ? DS.Colors.accent.opacity(0.35) : .black.opacity(0.12), radius: pressed ? 22 : 14, y: pressed ? 4 : 10)
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
                case .downloading(let p):
                    Text(SpeechModel.isPreparing(p) ? String(localized: "Förbereder \(dictation.engine.title.lowercased())")
                                                    : String(localized: "\(dictation.engine.title) laddas ned"))
                        .font(.system(size: 16, weight: .semibold))
                    ProgressView(value: min(1, p / 0.9))
                        .progressViewStyle(.linear)
                        .tint(DS.Colors.ink)
                        .frame(width: 300)
                    Text(dictation.engine.progressText(p, started: dictation.downloadStarted[dictation.engine]))
                        .font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                case .loading:
                    ProgressView().controlSize(.regular)
                    Text("Gör \(dictation.engine.title.lowercased()) redo för din Mac").font(.system(size: 16, weight: .semibold))
                    // The first time on a Mac the Neural Engine compiles the model — measured
                    // at about six minutes; after that it starts in seconds.
                    let minutes = Int(Date().timeIntervalSince(dictation.loadingSince) / 60)
                    Text(minutes < 1 ? String(localized: "Bara första gången – det kan ta några minuter.")
                                     : String(localized: "Bara första gången – det kan ta några minuter. \(minutes) min hittills."))
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    Text("Du kan gå vidare under tiden.")
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
                    Text("\(dictation.engine.title) laddades inte ned").font(.system(size: 16, weight: .semibold))
                    Text(message).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Button("Försök igen") { dictation.downloadModel() }.buttonStyle(.ink)
                case .missing:
                    Text("\(dictation.engine.title) är inte nedladdad").font(.system(size: 16, weight: .semibold))
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

// MARK: - Shared pieces

struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 38, weight: .regular, design: .serif))
                .contentTransition(.opacity)
            Text(LocalizedStringKey(subtitle))
                .font(.system(size: 15.5))
                .foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: 560)
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
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .offset(x: hovering ? 3 : 0)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.Colors.onInk)
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(Capsule().fill(DS.Colors.ink))
            .shadow(color: DS.Colors.accent.opacity(hovering ? 0.45 : 0.2), radius: hovering ? 18 : 10, y: 6)
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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                // Done: half ink. Now: full ink, wider. Still to come: faint but visible.
                Capsule()
                    .fill(DS.Colors.ink.opacity(i == current ? 1 : i < current ? 0.45 : 0.16))
                    .frame(width: i == current ? 34 : 18, height: 4)
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Steg \(current + 1) av \(count)"))
    }
}

/// Downloads in progress, bottom-left in the footer.
/// The downloads, next to the Back button: a ring, the model, MB and time left —
/// or what went wrong, with a way to try again.
struct DownloadStatus: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 18) {
                ForEach(SpeechModel.allCases) { m in
                    if let p = dictation.downloads[m] {
                        HStack(spacing: 9) {
                            ProgressRing(progress: p).frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title).font(.system(size: 12.5, weight: .semibold))
                                Text(m.progressText(p, started: dictation.downloadStarted[m]))
                                    .font(.system(size: 11.5)).monospacedDigit()
                                    .foregroundStyle(DS.Colors.muted)
                            }
                        }
                    } else if dictation.downloadErrors[m] != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(m.title) laddades inte ned").font(.system(size: 12.5, weight: .semibold))
                                Button("Försök igen") { dictation.downloadModel(m) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(DS.Colors.accent)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 10)
        }
        .animation(.easeOut(duration: 0.25), value: dictation.downloads.keys.sorted { $0.rawValue < $1.rawValue })
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
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            // The full line, invisible, keeps the layout still while typing.
            Text(text).font(font).opacity(0)
            HStack(spacing: 3) {
                Text(String(text.prefix(shown))).font(font)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let on = shown < text.count || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DS.Gradients.accent)
                        .frame(width: 3, height: 46)
                        .opacity(on ? 1 : 0)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(text)
        .task {
            if reduceMotion { shown = text.count; return }
            try? await Task.sleep(for: .seconds(delay))
            let chars = Array(text)
            for i in chars.indices {
                shown = i + 1
                // A small pause after a full stop, like someone speaking.
                try? await Task.sleep(for: .milliseconds(chars[i] == "." ? 260 : Int.random(in: 45...85)))
            }
        }
    }
}

// MARK: - Step transitions & entrances

/// Steps slide a little and come into focus.
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
