import ServiceManagement
import SwiftUI
import Carbon.HIToolbox

// MARK: - Main window
//
// A floating tab bar (TabBar.swift) and six pages:
//   • Hem — your day on an ink tile, the latest meetings and thoughts (Home.swift)
//   • Diktering — statistics, a box to try it in, and the last dictations, to copy again
//   • Möten — meetings in the room, written out live (Meetings/)
//   • Tankar — what you said with the thought key (Thoughts.swift)
//   • Ordlista — names and words spelled your way (VocabularyPage.swift)
//   • Inställningar — shortcuts, text, app, sound, appearance, languages, about

enum Page: String, CaseIterable, Identifiable {
    case dictation, recent, meetings, thoughts, vocabulary, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return String(localized: "Hem")
        case .meetings: return String(localized: "Möten")
        case .thoughts: return String(localized: "Tankar")
        case .recent: return String(localized: "Diktering")
        case .vocabulary: return String(localized: "Ordlista")
        case .settings: return String(localized: "Inställningar")
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "house"
        case .meetings: return "person.2.wave.2"
        case .thoughts: return "lightbulb"
        case .recent: return "mic"
        case .vocabulary: return "character.book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject var prefs: AppPrefs
    @State private var page: Page = MainView.startPage
    @State private var introduction = false
    /// Where the window opens (Settings after a language switch).
    static var startPage: Page = .dictation
    /// The page on screen (an import done elsewhere notifies).
    static var currentPage: Page = .dictation

    var body: some View {
        // The page gets the whole window; a tab bar floats at the leading edge.
        ZStack(alignment: .leading) {
            ZStack(alignment: .top) {
                // A soft wash of the brand's warm light behind the page headers.
                WarmGlow(intensity: 0.32)
                    .frame(height: 300)
                    .allowsHitTesting(false)
                ZStack {
                    switch page {
                    case .dictation: DictationPage(dictation: dictation, page: $page)
                    case .meetings: MeetingsPage(session: .shared, store: .shared, voices: .shared, dictation: dictation)
                    case .thoughts: ThoughtsPage(dictation: dictation)
                    case .recent: RecentPage(dictation: dictation)
                    case .vocabulary: VocabularyPage(vocabulary: .shared)
                    case .settings: SettingsPage(dictation: dictation, prefs: prefs)
                    }
                }
                .id(page)
                .transition(.page)
                .onAppear { MainView.currentPage = page }
                .onChange(of: page) { _, now in MainView.currentPage = now }
            }
            .padding(.leading, 236)         // clear of the tab bar (16 + 212 + a little air)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.Colors.paper)

            FloatingTabBar(page: $page, dictation: dictation)
                .padding(.leading, 16)
        }
        .ignoresSafeArea()
        // Minska rörelse: no springs, slides or scaling anywhere in the window.
        .transaction { t in if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { t.animation = nil } }
        .frame(minWidth: 940, minHeight: 580)
        .onAppear { dictation.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dictation.refreshPermissions()
        }
        .overlay {
            if introduction {
                IntroductionOverlay(dictation: dictation) {
                    withAnimation(.easeOut(duration: 0.25)) { introduction = false }
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showIntroduction)) { _ in
            withAnimation(.easeOut(duration: 0.3)) { introduction = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPage)) { note in
            if let target = note.object as? Page { withAnimation(.spring(duration: 0.45)) { page = target } }
        }
    }
}

extension Notification.Name {
    /// Files were queued for import: the Möten page shows its list, where they are.
    static let importAdded = Notification.Name("ai.mindact.mindtalk.importAdded")
    /// Switch the main window to a page (object: Page).
    static let showPage = Notification.Name("MindtalkShowPage")
    /// Play the introduction inside the main window.
    static let showIntroduction = Notification.Name("MindtalkShowIntroduction")
    /// Scroll Settings to "Om Mindtalk".
    static let showAbout = Notification.Name("MindtalkShowAbout")
    /// A shortcut field in Settings stops waiting for keys (another one starts, or you left the app).
    static let stopChordPicking = Notification.Name("MindtalkStopChordPicking")
}

/// The introduction over the whole main window, with a way out in the corner.
private struct IntroductionOverlay: View {
    @ObservedObject var dictation: Dictation
    let close: () -> Void

    var body: some View {
        OnboardingView(dictation: dictation) { done() }
            .background(DS.Colors.paper)
            .overlay(alignment: .topTrailing) {
                Button(action: done) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.muted)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.Colors.chip))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Stäng introduktionen")
                .accessibilityLabel("Stäng introduktionen")
                .padding(16)
            }
    }

    private func done() {
        dictation.stopPickingKey()
        Settings.didOnboard = true
        close()
    }
}

// MARK: - Diktering

private struct DictationPage: View {
    @ObservedObject var dictation: Dictation
    @Binding var page: Page
    @State private var wide = true
    /// A new day (midnight, or the Mac waking on one): "i dag", the week and
    /// "I går 14:02" on the cards are all drawn afresh.
    @ObservedObject private var stats = Stats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HomeHero(dictation: dictation, page: $page, wide: wide).staggered(0)

            if dictation.needsSetup { setupCard.staggered(1) }

            HomeShelves(page: $page, wide: wide).staggered(2)
        }
        .id(stats.day)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 690 } action: { wide = $0 }
        .pageLayout()
    }

    private func howTo<Trailing: View>(icon: String, title: String, detail: String,
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(DS.Colors.muted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    /// Only what's still missing, each with one button.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Kom igång")
            VStack(spacing: 0) {
                CardRow(title: "Mikrofon", detail: "Hör dig bara när du dikterar eller spelar in ett möte.") {
                    if dictation.micGranted { GrantedLabel(text: "Tillåten") }
                    else { Button("Tillåt") { dictation.requestMicrophone() }.buttonStyle(.ink) }
                }
                CardDivider()
                CardRow(title: "Hjälpmedel", detail: "Behövs för att märka när du håller in tangenten och för att skriva texten där markören står.") {
                    if dictation.accessibilityGranted { GrantedLabel() }
                    else { Button("Tillåt") { dictation.requestAccessibility() }.buttonStyle(.ink) }
                }
                CardDivider()
                CardRow(title: String(localized: "Talmodell – \(dictation.engine.title.lowercased())"), detail: modelDetail(dictation.model, dictation.engine)) {
                    ModelControl(dictation: dictation)
                }
            }
            .card()
        }
    }
}

private func modelDetail(_ model: Dictation.ModelState, _ engine: SpeechModel) -> String {
    switch model {
    case .missing: return String(localized: "\(engine.modelName), \(engine.sizeText). Laddas ned en gång och fungerar sedan utan internet.")
    case .downloading(let p) where p >= 0.9: return String(localized: "Förbereder modellen för din Mac…")
    case .downloading: return String(localized: "Laddar ned \(engine.modelName) – bara den här gången.")
    case .loading: return String(localized: "Startar – första gången kan det ta några minuter.")
    case .failed(let message): return message
    case .ready: return String(localized: "Redo att diktera.")
    }
}

private struct ModelControl: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        switch dictation.model {
        case .ready:
            VStack(alignment: .trailing, spacing: 3) {
                Text(dictation.engine.modelName).font(.system(size: 14, weight: .semibold))
            }
        case .missing, .failed:
            Button(LocalizedStringKey(dictation.model == .missing ? "Ladda ned" : "Försök igen")) { dictation.downloadModel() }
                .buttonStyle(.ink)
        case .downloading(let p):
            HStack(spacing: 10) {
                ProgressView(value: p).frame(width: 110).tint(DS.Colors.ink)
                Text(p, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.muted)
                Button("Avbryt") { dictation.cancelDownload() }.buttonStyle(.soft)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Startar…").foregroundStyle(DS.Colors.muted)
            }
        }
    }
}

// MARK: - Inställningar

struct SettingsPage: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject var prefs: AppPrefs
    @ObservedObject private var mics = Microphones.shared
    @ObservedObject private var updates = Updates.shared
    @State private var loginStatus = SMAppService.mainApp.status
    @ObservedObject private var meeting = MeetingSession.shared
    @ObservedObject private var importer = MeetingImport.shared
    @State private var showMicPicker = false
    @State private var appLanguage = AppLanguage.chosen
    @State private var meetingShortcut = Settings.meetingShortcut
    @State private var thoughtShortcut = Settings.thoughtShortcut
    @State private var pickingThoughtKey = false
    @State private var pickingMeetingKey = false

    /// Set before opening Settings to land on "Om Mindtalk".
    static var jumpToAbout = false

    var body: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Inställningar")
                .staggered(0)
                .padding(.bottom, 12)

            // Without Hjälpmedel no shortcut works anywhere: said first, not at the bottom.
            if !dictation.accessibilityGranted {
                CardRow(title: "Slå på Hjälpmedel för Mindtalk",
                        detail: "Utan det fungerar inga genvägar. Står Mindtalk redan under Integritet och säkerhet → Hjälpmedel? Slå av och på – ibland kräver macOS det efter en uppdatering.") {
                    Button("Tillåt") { dictation.requestAccessibility() }.buttonStyle(.ink)
                }
                .card()
                .staggered(1)
            }

            // MARK: Inspelning — what both dictation and meetings hear with

            SectionTitle("Inspelning")
            .staggered(1)
            CardRow(title: "Mikrofon", detail: !dictation.micGranted ? "Mindtalk behöver få använda mikrofonen."
                    : meeting.isBusy ? String(localized: "\(mics.selectionName) · går att byta när mötet är klart") : mics.selectionName) {
                if dictation.micGranted {
                    Button("Ändra") { showMicPicker = true }.buttonStyle(.soft)
                        .disabled(meeting.isBusy || dictation.phase == .recording || dictation.phase == .transcribing)
                }
                else { Button("Tillåt") { dictation.requestMicrophone() }.buttonStyle(.ink) }
            }
            .card()
            .staggered(1)
            VStack(spacing: 0) {
                ForEach(Array(SpeechModel.allCases.enumerated()), id: \.element) { i, m in
                    if i > 0 { CardDivider() }
                    LanguageRow(model: m, dictation: dictation)
                }
            }
            .card()
            .staggered(1)
            Text("Språket du pratar, när du dikterar och i möten. Byt snabbt i menyraden – eller med ⌘1 och ⌘2 när menyn är öppen.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)

            // MARK: Diktering

            SectionTitle("Diktering")
            .staggered(2)
            VStack(spacing: 0) {
                CardRow(title: "Genväg", detail: dictation.pickingKey
                        ? String(localized: "Håll in en eller flera modifieringstangenter tillsammans och släpp för att spara. Du kan också trycka på en vanlig tangent. Esc avbryter.")
                        : dictation.hotkey.note) { ShortcutField(dictation: dictation) }
                CardDivider()
                CardRow(title: "Hur du dikterar", detail: dictation.mode.explanation(key: dictation.hotkey.inlineName)) {
                    MenuPicker(options: DictationMode.allCases.map { ($0, $0.title) },
                               selection: Binding(get: { dictation.mode }, set: { dictation.setMode($0) }))
                }
                CardDivider()
                CardRow(title: "Ljud vid diktering", detail: "Ett diskret ljud när Mindtalk börjar lyssna och när texten klistras in.") {
                    InkToggle(label: "Ljud vid diktering", isOn: $prefs.sounds)
                }
                CardDivider()
                CardRow(title: "Musik medan du dikterar", detail: prefs.mediaMode.explanation) {
                    MenuPicker(options: MediaMode.allCases.map { ($0, $0.title) }, selection: $prefs.mediaMode)
                }
                CardDivider()
                CardRow(title: "Klistra in igen", detail: "Om texten hamnade fel – ställ markören rätt och tryck.") {
                    KeyChip(text: "⌃ ⌥ V")
                }
            }
            .card()
            .staggered(2)
            TextCleanupCard(prefs: prefs)
                .staggered(2)

            // MARK: Möten

            SectionTitle("Möten")
                .staggered(3)
            CardRow(title: "Genväg", detail: pickingMeetingKey
                    ? String(localized: "Tryck på en tangent tillsammans med ⌘, ⌃ eller ⌥. Esc avbryter.")
                    : meetingShortcut == nil
                        ? String(localized: "Av. Inne i Mindtalk fungerar ⇧⌘R.")
                        : meetingShortcut?.warning ?? String(localized: "Startar och avslutar ett möte i alla appar. Inne i Mindtalk fungerar även ⇧⌘R.")) {
                MeetingShortcutField(chord: $meetingShortcut, picking: $pickingMeetingKey, taken: [thoughtShortcut])
                    .disabled(!dictation.accessibilityGranted)
            }
            .card()
            .staggered(3)
            SummaryWriterRow()
                .staggered(3)
            VoiceMemoryCard(memory: .shared)
                .staggered(3)
            MeetingPrivacyCard()
                .staggered(3)

            // MARK: Tankar

            SectionTitle("Tankar")
                .staggered(4)
            CardRow(title: "Genväg", detail: pickingThoughtKey
                    ? String(localized: "Tryck på en tangent tillsammans med ⌘, ⌃ eller ⌥. Esc avbryter.")
                    : thoughtShortcut == nil
                        ? String(localized: "Av. Du kan fortfarande säga en tanke på sidan Tankar.")
                        : thoughtShortcut?.warning ?? String(localized: "Håll in och säg det du kommer på – det hamnar i Tankar. Tryck snabbt, så lyssnar Mindtalk tills du trycker igen.")) {
                MeetingShortcutField(chord: $thoughtShortcut, picking: $pickingThoughtKey, taken: [meetingShortcut]) { new in
                    Settings.thoughtShortcut = new
                    KeyListener.shared.thoughtChord = new
                }
                .disabled(!dictation.accessibilityGranted)
            }
            .card()
            .staggered(4)

            // MARK: Modeller

            SectionTitle("Modeller")
                .staggered(4)
            ModelsCard(dictation: dictation)
                .staggered(4)

            // MARK: Allmänt

            SectionTitle("Allmänt")
            .staggered(4)
            VStack(spacing: 0) {
                CardRow(title: "Starta vid inloggning",
                        detail: loginStatus == .requiresApproval ? "Godkänn Mindtalk under Allmänt → Inloggningsobjekt i Systeminställningar." : nil) {
                    HStack(spacing: 10) {
                        if loginStatus == .requiresApproval {
                            Button("Öppna") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.soft)
                        }
                        InkToggle(label: "Starta vid inloggning", isOn: Binding(
                            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                            set: { on in
                                do {
                                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    NSLog("Mindtalk: launch at login: \(error.localizedDescription)")
                                }
                                loginStatus = SMAppService.mainApp.status
                            }))
                    }
                }
                CardDivider()
                CardRow(title: "Visa i Dock", detail: "Annars finns Mindtalk bara i menyraden när fönstret är stängt.") {
                    InkToggle(label: "Visa i Dock", isOn: $prefs.showInDock)
                }
                CardDivider()
                CardRow(title: "Utseende") {
                    PillPicker(options: Appearance.allCases.map { ($0, $0.title) }, selection: $prefs.appearance)
                }
                CardDivider()
                CardRow(title: "Appens språk",
                        detail: appLanguage.resolved == AppLanguage.running ? nil
                            : meeting.isBusy ? "Mindtalk behöver startas om för att byta språk – det går när mötet är klart."
                            : importer.busy ? "Mindtalk behöver startas om för att byta språk – det går när inspelningen är nedskriven."
                            : "Mindtalk behöver startas om för att byta språk.") {
                    HStack(spacing: 10) {
                        if appLanguage.resolved != AppLanguage.running {
                            Button("Starta om") { AppDelegate.relaunch(showing: .settings) }
                                .buttonStyle(.ink)
                                .fixedSize()
                                .disabled(dictation.phase != .idle || meeting.isBusy || importer.busy)
                        }
                        PillPicker(options: AppLanguage.allCases.map { ($0, $0.title) }, selection: $appLanguage)
                            .onChange(of: appLanguage) { _, new in AppLanguage.chosen = new }
                    }
                }
                CardDivider()
                CardRow(title: "Uppdateringar", detail: "Sök efter nya versioner automatiskt, en gång om dagen.") {
                    HStack(spacing: 12) {
                        Button("Sök nu") { Updates.shared.checkNow() }.buttonStyle(.soft)
                        InkToggle(label: "Sök automatiskt", isOn: $updates.automatic)
                    }
                    .disabled(!Updates.isAvailable)
                }
                if dictation.accessibilityGranted {
                    CardDivider()
                    CardRow(title: "Hjälpmedel", detail: "Låter Mindtalk känna av genvägarna och skriva in texten där markören står.") {
                        GrantedLabel()
                    }
                }
            }
            .card()
            .staggered(4)

            SectionTitle("Om Mindtalk")
            .staggered(5)
            AboutCard()
                .id("about")
                .staggered(5)
        }
        .onAppear { if Self.jumpToAbout { showAbout(proxy, after: 0.45) } }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in showAbout(proxy, after: 0.1) }
        }
        .pageLayout()
        .onAppear { loginStatus = SMAppService.mainApp.status; updates.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
            updates.refresh()
        }
        .onDisappear { dictation.stopPickingKey() }
        .sheet(isPresented: $showMicPicker) {
            MicrophonePicker(mics: mics) { showMicPicker = false }
        }
    }
}

/// A dictation shortcut in a white field — choose a key or hold modifiers together.
private struct ShortcutField: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        Button {
            if dictation.pickingKey { dictation.stopPickingKey() } else {
                NotificationCenter.default.post(name: .stopChordPicking, object: nil)
                dictation.pickKey()
            }
        } label: {
            HStack(spacing: 10) {
                if dictation.pickingKey {
                    Text("Tryck på en tangent…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                } else {
                    KeyChip(text: dictation.hotkey.chip)
                }
                Spacer(minLength: 16)
                Image(systemName: "pencil").foregroundStyle(DS.Colors.muted)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(width: 280)
            .frame(minHeight: 38)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(dictation.pickingKey ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!dictation.accessibilityGranted)
        .help(LocalizedStringKey(dictation.accessibilityGranted ? "Klicka och håll in tangenterna du vill använda. Släpp för att spara. Du kan också trycka på en vanlig tangent. Esc avbryter."
                                             : "Slå på Hjälpmedel för Mindtalk först."))
    }
}

/// A shortcut heard in every app (the meeting, a thought): click, then press it — a
/// key with ⌘, ⌃ or ⌥. `taken`: the others, so two never share keys.
private struct MeetingShortcutField: View {
    @Binding var chord: KeyChord?
    @Binding var picking: Bool
    var taken: [KeyChord?] = []
    var apply: (KeyChord?) -> Void = { new in
        Settings.meetingShortcut = new
        KeyListener.shared.meetingChord = new
    }
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button { picking ? stop() : start() } label: {
                HStack(spacing: 10) {
                    if picking {
                        Text("Tryck på kombinationen…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    } else if let chord {
                        KeyChip(text: chord.chip)
                    } else {
                        Text("Ingen genväg").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    }
                    Spacer(minLength: 16)
                    Image(systemName: "pencil").foregroundStyle(DS.Colors.muted)
                }
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .frame(width: chord == nil || picking ? 280 : 244)
                .frame(minHeight: 38)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(picking ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Klicka och tryck på en tangent tillsammans med ⌘, ⌃ eller ⌥. Esc avbryter.")
            if chord != nil, !picking {
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(DS.Colors.faint)
                        .frame(width: 28, height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stäng av genvägen")
                .accessibilityLabel("Stäng av genvägen")
            }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: .stopChordPicking)) { _ in if picking { stop() } }
    }

    private func start() {
        // One picker at a time: the other field, or the dictation key, stops first.
        NotificationCenter.default.post(name: .stopChordPicking, object: nil)
        Dictation.shared.stopPickingKey()
        picking = true
        KeyListener.shared.pickingChord = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let new = KeyChord(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue))
            // ⌃⌥V is "klistra in senaste igen"; a key on its own would stop typing it.
            let pasteLast = KeyChord(keyCode: UInt16(kVK_ANSI_V), modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
            guard new.isValid, !new.isReserved, new != pasteLast, !taken.contains(new) else { NSSound.beep(); return nil }
            set(new)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        picking = false
        KeyListener.shared.pickingChord = false
    }

    private func set(_ new: KeyChord?) {
        chord = new
        apply(new)
    }
}

// MARK: - Diktering
//
// Everything about dictating, on one page: your key and how it works (with a box to
// try it in), what talking instead of typing has added up to — the figures Hem
// doesn't show — and the last fifty dictations by day, to copy again.

/// Your key, how it works, and a place to try it.
private struct DictationKeyCard: View {
    @ObservedObject var dictation: Dictation
    /// The box to try it in: open for someone who hasn't dictated yet.
    @State private var trying: Bool
    @State private var practice = ""

    init(dictation: Dictation) {
        self.dictation = dictation
        _trying = State(initialValue: dictation.recent.isEmpty && !dictation.needsSetup)
    }

    private var key: String { dictation.hotkey.inlineName }

    private var title: String {
        dictation.mode == .toggle ? String(localized: "Tryck på \(key) och prata") : String(localized: "Håll in \(key) och prata")
    }

    private var how: String {
        switch dictation.mode {
        case .hold: return String(localized: "Släpp när du är klar, så skrivs texten där markören står. Esc avbryter.")
        case .toggle: return String(localized: "Tryck igen när du är klar, så skrivs texten där markören står. Esc avbryter.")
        case .holdOrDoubleTap: return String(localized: "Släpp när du är klar, så skrivs texten där markören står. Dubbeltryck för att låsa och prata fritt. Esc avbryter.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                Text(verbatim: dictation.hotkey.chip)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16)
                    .frame(minWidth: 64, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.field))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.fieldStroke).offset(y: 3))
                    .fixedSize()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: title).font(.system(size: 17, weight: .semibold))
                    Text(verbatim: how).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NotificationCenter.default.post(name: .showPage, object: Page.settings)
                    } label: {
                        Text("Ändra tangent och sätt i Inställningar")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted).underline()
                            .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 12)
                if !dictation.needsSetup {
                    Button(trying ? "Stäng" : "Prova") {
                        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { trying.toggle() }
                    }
                    .buttonStyle(.soft)
                }
            }
            if trying && !dictation.needsSetup {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $practice)
                        .font(.system(size: 17))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.field))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(practice.isEmpty ? AnyShapeStyle(DS.Colors.fieldStroke) : AnyShapeStyle(DS.Gradients.accent),
                                          lineWidth: practice.isEmpty ? 1 : 1.5))
                        .accessibilityLabel("Prova diktering här")
                    if practice.isEmpty {
                        Text("Klicka här, håll in \(key) och säg något.")
                            .font(.system(size: 17))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, 17).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(22)
        .card()
    }
}

/// What it has added up to — the figures Hem doesn't show: everything so far, how
/// fast you talk, your best day, and days in a row.
private struct DictationFigures: View {
    @ObservedObject var stats: Stats

    var body: some View {
        let best = stats.bestDay
        HStack(alignment: .top, spacing: 0) {
            figure(Stats.number(stats.totalWords), "ord totalt",
                   detail: stats.totalSaved >= 60 ? String(localized: "Du har sluppit skriva i ungefär \(Stats.prose(stats.totalSaved, round: true)).") : nil)
            if let wpm = stats.wordsPerMinute {
                figure(Stats.number(wpm), "ord i minuten",
                       detail: String(localized: "När du skriver: runt \(Int(Stats.typingWordsPerMinute))"))
            }
            if let best {
                figure(Stats.number(best.words), "bästa dagen",
                       detail: best.date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.locale)))
            }
            figure(Stats.number(stats.streak), stats.streak == 1 ? "dag i rad" : "dagar i rad", detail: nil)
        }
        .padding(.vertical, 20)
        .card()
    }

    private func figure(_ value: String, _ label: LocalizedStringKey, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value).font(.system(size: 30, weight: .regular, design: .serif)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 13, weight: .medium))
            if let detail {
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(DS.Colors.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct RecentPage: View {
    @ObservedObject var dictation: Dictation
    /// Without the page's scroll view (screenshots).
    var plain = false
    @ObservedObject private var stats = Stats.shared
    @State private var confirmClear = false
    /// A dictation just removed, and where it was — "Ångra" for a few seconds.
    @State private var removed: (entry: Dictation.Entry, index: Int)?
    @State private var removedTask: Task<Void, Never>?

    var body: some View {
        if plain { content } else {
            content
                .pageLayout()
                .overlay(alignment: .bottom) {
                    if removed != nil {
                        HStack(spacing: 14) {
                            Text("Dikteringen är borttagen").font(.system(size: 13))
                            Button("Ångra") { undoRemove() }.buttonStyle(.soft)
                        }
                        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
                        .background(Capsule().fill(DS.Colors.card).shadow(color: .black.opacity(0.15), radius: 10, y: 4))
                        .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 0.5))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .confirmationDialog("Rensa historiken?", isPresented: $confirmClear) {
                    Button("Rensa", role: .destructive) { withAnimation(.snappy) { dictation.clearRecent() } }
                    Button("Avbryt", role: .cancel) {}
                } message: {
                    Text("De tas bort från din Mac och kan inte återställas. ⌃⌥V har då inget att klistra in.")
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                PageHeader(title: "Diktering").staggered(0)
                Spacer()
                if !dictation.recent.isEmpty {
                    Button("Rensa…") { confirmClear = true }.buttonStyle(.soft)
                }
            }
            DictationKeyCard(dictation: dictation).staggered(1)
            if stats.totalWords > 0 {
                DictationFigures(stats: stats).staggered(1)
            }
            if !dictation.recent.isEmpty {
                SectionTitle("Det du dikterat").staggered(2)
                ForEach(Self.days(dictation.recent), id: \.title) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: day.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { i, entry in
                                if i > 0 { CardDivider() }
                                RecentRow(entry: entry, copy: { dictation.copy(entry) }, remove: { remove(entry) })
                            }
                        }
                        .card()
                    }
                    .staggered(2)
                }
                Text("De 50 senaste sparas. ⌃⌥V klistrar in den senaste igen.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.muted)
            }
        }
    }

    /// "I dag", "I går", then the day — like Tankar.
    static func days(_ entries: [Dictation.Entry]) -> [(title: String, items: [Dictation.Entry])] {
        let calendar = Calendar.current
        var out: [(title: String, items: [Dictation.Entry])] = []
        for e in entries {
            let date = min(e.date, Date())
            let title: String
            if calendar.isDateInToday(date) { title = String(localized: "I dag") }
            else if calendar.isDateInYesterday(date) { title = String(localized: "I går") }
            else {
                let day = date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
                title = day.prefix(1).uppercased() + day.dropFirst()
            }
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].items.append(e) } else { out.append((title, [e])) }
        }
        return out
    }

    /// One dictation away — back with "Ångra" for a few seconds.
    private func remove(_ entry: Dictation.Entry) {
        let index = dictation.recent.firstIndex(where: { $0.id == entry.id }) ?? 0
        withAnimation(.snappy) {
            dictation.removeRecent(entry)
            removed = (entry, index)
        }
        removedTask?.cancel()
        removedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { removed = nil }
        }
    }

    private func undoRemove() {
        guard let removed else { return }
        removedTask?.cancel()
        withAnimation(.snappy) {
            dictation.restoreRecent(removed.entry, at: removed.index)
            self.removed = nil
        }
    }
}

/// One dictation: the time on the left, the words, and a copy button.
private struct RecentRow: View {
    let entry: Dictation.Entry
    let copy: () -> Void
    let remove: () -> Void
    @State private var copied = false
    @State private var expanded = false

    private var long: Bool { entry.text.count > 280 || entry.text.filter { $0 == "\n" }.count > 3 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(verbatim: min(entry.date, Date()).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale)))
                .font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(DS.Colors.muted)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.text)
                    .font(.system(size: 14))
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Button(expanded ? "Visa mindre" : "Visa hela") { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.accent)
                }
            }
            Button {
                copy()
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(.easeOut(duration: 0.2)) { copied = false } }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                    if copied { Text("Kopierad").font(.system(size: 12, weight: .medium)).transition(.opacity) }
                }
                .frame(minWidth: 18, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Kopiera")
            .accessibilityLabel(Text("Kopiera"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .contextMenu {
            Button("Kopiera", action: copy)
            Button("Ta bort", role: .destructive, action: remove)
        }
    }
}

// MARK: - Språk

/// One language: use it, download it, or remove it.
private struct LanguageRow: View {
    let model: SpeechModel
    @ObservedObject var dictation: Dictation
    @State private var confirmRemove = false

    private var active: Bool { dictation.engine == model }

    var body: some View {
        HStack(spacing: 16) {
            ModelBadge(model: model, size: 13)
                .foregroundStyle(active ? DS.Colors.accent : .secondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(active ? DS.Colors.accent.opacity(0.12) : DS.Colors.chip))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if dictation.downloadErrors[model] == nil {
                    Text(String(localized: "\(model.modelName) av \(model.credit) · \(model.sizeText)"))
                        .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var detail: String {
        dictation.downloadErrors[model] ?? model.pitch
    }

    @ViewBuilder private var control: some View {
        if let p = dictation.downloads[model] {
            HStack(spacing: 10) {
                ProgressView(value: p).frame(width: 90).tint(DS.Colors.accent)
                Text(p, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.muted)
                Button("Avbryt") { dictation.cancelDownload(model) }.buttonStyle(.soft)
            }
        } else if !dictation.installed.contains(model) {
            Button(LocalizedStringKey(dictation.downloadErrors[model] == nil ? "Ladda ned" : "Försök igen")) {
                dictation.downloadModel(model)
            }
            .buttonStyle(.ink)
        } else if active {
            HStack(spacing: 8) {
                if dictation.model == .loading { ProgressView().controlSize(.small) }
                Label("Används", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
            }
        } else {
            HStack(spacing: 8) {
                if model.isOwnInstall {
                    Button {
                        confirmRemove = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .confirmationDialog(String(localized: "Ta bort \(model.modelName) (\(model.sizeText))?"), isPresented: $confirmRemove) {
                        Button("Ta bort", role: .destructive) { dictation.removeModel(model) }
                        Button("Avbryt", role: .cancel) {}
                    } message: {
                        Text("Den kan laddas ned igen senare.")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Colors.muted)
                    .help("Ta bort \(model.modelName) (\(model.sizeText)) från din Mac")
                    .accessibilityLabel("Ta bort \(model.modelName)")
                }
                Button("Använd") { dictation.setEngine(model) }.buttonStyle(.soft)
            }
        }
    }
}

// MARK: - Om

/// Credits and licenses — what CC BY 4.0 asks of us, said plainly.
/// What happens to the text between the model and your cursor.
private struct TextCleanupCard: View {
    @ObservedObject var prefs: AppPrefs
    @State private var status = Polisher.status

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Ta bort tvekljud", detail: "Eh, öh och um försvinner ur texten.") {
                InkToggle(label: "Ta bort tvekljud", isOn: $prefs.removeFillers)
            }
            CardDivider()
            CardRow(title: "Röstkommandon", detail: "Säg ”ny rad” eller ”nytt stycke” – på engelska ”new line” och ”new paragraph”.") {
                InkToggle(label: "Röstkommandon", isOn: $prefs.voiceCommands)
            }
            CardDivider()
            CardRow(title: "Lämna texten i urklipp", detail: "Texten skrivs in som vanligt och ligger sedan kvar i urklipp. Står markören inte i ett textfält hamnar den bara där.") {
                InkToggle(label: "Lämna texten i urklipp", isOn: $prefs.keepInClipboard)
            }
            CardDivider()
            CardRow(title: "Putsa med AI", detail: polishDetail) {
                if status == .notEnabled {
                    Button("Slå på") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                    .buttonStyle(.soft)
                } else {
                    InkToggle(label: "Putsa med AI", isOn: $prefs.aiPolish)
                        .disabled(status != .available)
                        .opacity(status == .available ? 1 : 0.4)
                }
            }
        }
        .card()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = Polisher.status
        }
    }

    private var polishDetail: String {
        switch status {
        case .available:
            return String(localized: "Rättar skiljetecken, upprepningar och självrättelser som ”nej, jag menar…”. Körs med Apple Intelligence.")
        case .notEnabled:
            return String(localized: "Kräver Apple Intelligence, som är avstängt på den här Macen.")
        case .notReady:
            return String(localized: "Apple Intelligence laddas ned. Det går att slå på när det är klart.")
        case .unsupported:
            return String(localized: "Kräver Apple Intelligence, som inte finns på den här Macen.")
        }
    }
}

/// The licence texts bundled with the app (Resources/Acknowledgements.txt).
private struct LicensesSheet: View {
    let close: () -> Void

    private var text: String {
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Licenser").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Klar", action: close)
                    .buttonStyle(.ink)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            CardDivider()
            ScrollView {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: 680, height: 560)
        .background(DS.Colors.paper)
    }
}

extension SettingsPage {
    fileprivate func showAbout(_ proxy: ScrollViewProxy, after delay: Double) {
        Self.jumpToAbout = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.spring(duration: 0.6)) { proxy.scrollTo("about", anchor: .top) }
        }
    }
}

private struct AboutCard: View {
    @State private var showsLicenses = false
    private static let ccBy = URL(string: "https://creativecommons.org/licenses/by/4.0/deed.sv")!
    private static let parakeet = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!
    private static let fluidAudio = URL(string: "https://github.com/FluidInference/FluidAudio")!
    private static let apache = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    private static let redimnet = URL(string: "https://huggingface.co/lab260/redimnet2-plus")!
    private static let nemotron = URL(string: "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml")!
    private static let openMDW = URL(string: "https://openmdw.ai/license/")!
    private static let parakeetCTC = URL(string: "https://huggingface.co/nvidia/parakeet-tdt_ctc-110m")!
    private static let gemma = URL(string: "https://huggingface.co/google/gemma-4-26B-A4B-it")!
    private static let scbNames = URL(string: "https://doi.org/10.5878/fc4h-rp11")!
    private static let sparkle = URL(string: "https://github.com/sparkle-project/Sparkle")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            row(title: "Mindtalk \(version)", detail: "© 2026 Mindact Solutions AB") {
                Button("Visa introduktionen") { AppDelegate.showIntroduction() }
                    .buttonStyle(.soft)
            }
            ForEach(SpeechModel.allCases) { m in
                CardDivider()
                row(title: m.modelName,
                    detail: String(localized: "Av \(m.credit), byggd på NVIDIA Parakeet. CC BY 4.0.")) {
                    links([("Modell", m.modelPage), (String(localized: "Core ML (\(m.conversionCredit))"), m.conversionPage), ("Licens", Self.ccBy)])
                }
            }
            CardDivider()
            row(title: "NVIDIA Parakeet TDT 0.6B v3",
                detail: "Grundmodellen båda bygger på, av NVIDIA. CC BY 4.0.") {
                links([("Modell", Self.parakeet), ("Licens", Self.ccBy)])
            }
            CardDivider()
            row(title: "ReDimNet2+", detail: "Känner igen röster. Av LAB260, byggd på ReDimNet2 av Palabra.ai. Ingår i appen. Apache 2.0.") {
                links([("Modell", Self.redimnet), ("Licens", Self.apache)])
            }
            CardDivider()
            row(title: "Nemotron 3", detail: "Håller isär vem som pratar i möten. Av NVIDIA, Core ML av FluidInference. OpenMDW 1.1.") {
                links([("Modell", Self.nemotron), ("Licens", Self.openMDW)])
            }
            CardDivider()
            row(title: "Parakeet TDT-CTC 110M", detail: "Lyssnar en gång till efter orden i Ordlistan. Av NVIDIA. CC BY 4.0.") {
                links([("Modell", Self.parakeetCTC), ("Licens", Self.ccBy)])
            }
            CardDivider()
            row(title: "Gemma 4", detail: "Skriver sammanfattningar och svar, om du väljer den. Av Google. Apache 2.0.") {
                links([("Modell", Self.gemma), ("Licens", Self.apache)])
            }
            CardDivider()
            row(title: "Förnamn", detail: "Namn som presentationsrundan känner igen. Statistiska centralbyrån (SCB), 2020. CC BY 4.0.") {
                links([("Källa", Self.scbNames), ("Licens", Self.ccBy)])
            }
            CardDivider()
            row(title: "FluidAudio", detail: "Kör modellerna på Neural Engine. Av FluidInference. Apache 2.0.") {
                links([("Källkod", Self.fluidAudio), ("Licens", Self.apache)])
            }
            CardDivider()
            row(title: "Sparkle", detail: "Håller Mindtalk uppdaterad. Öppen källkod, MIT-licens.") {
                links([("Källkod", Self.sparkle)])
            }
            CardDivider()
            row(title: "Licenser", detail: "Alla licenstexter som följer med Mindtalk.") {
                Button("Visa licenser…") { showsLicenses = true }
                    .buttonStyle(.soft)
            }
        }
        .card()
        .sheet(isPresented: $showsLicenses) { LicensesSheet { showsLicenses = false } }
        #if DEBUG
        .task {   // screenshots
            if CommandLine.arguments.contains("--show-licenses") { try? await Task.sleep(for: .seconds(1.5)); showsLicenses = true }
        }
        #endif
    }

    private func row<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func links(_ items: [(String, URL)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { title, url in
                Link(destination: url) {
                    HStack(spacing: 2) {
                        Text(LocalizedStringKey(title))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
            }
        }
    }
}
