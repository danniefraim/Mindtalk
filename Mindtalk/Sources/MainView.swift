import ServiceManagement
import SwiftUI
import os
import Carbon.HIToolbox

// MARK: - Main window
//
// A floating tab bar (TabBar.swift) and six pages:
//   • Hem — your day on an ink tile, the latest meetings and thoughts (Home.swift)
//   • Diktering — statistics, a box to try it in, and the last dictations, to copy again
//   • Möten — meetings in the room, written out live (Meetings/)
//   • Tankar — what you said with the thought key (Thoughts.swift)
//   • Ordlista — names and words spelled your way (VocabularyPage.swift)
//   • Inställningar — one section at a time: Allmänt, Mikrofon och språk, Diktering,
//     Tankar, Möten, Modeller, Integrationer, Om Mindtalk

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

/// Inställningar, one section at a time: the sections in the tab bar, the section as the page.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, language, dictation, meetings, integrations

    /// Where the section last shown is kept (SettingsPage and the tab bar).
    static let storageKey = "settings.section"
    /// Renders: this section, whatever was shown last.
    static var preview: SettingsSection?

    var id: String { rawValue }

    /// The section kept under `storageKey`; one from an older Mindtalk is read as the
    /// nearest one now (Mikrofon och språk and Modeller as Språk; Tankar and Om
    /// Mindtalk, which are elsewhere now, as Allmänt).
    init(stored raw: String) {
        switch raw {
        case "microphone", "models": self = .language
        case "thoughts", "about": self = .general
        default: self = SettingsSection(rawValue: raw) ?? .general
        }
    }

    var title: String {
        switch self {
        case .general: return String(localized: "Allmänt")
        case .language: return String(localized: "Språk")
        case .dictation: return String(localized: "Diktering")
        case .meetings: return String(localized: "Möten")
        case .integrations: return String(localized: "Integrationer")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .language: return "globe"
        case .dictation: return "text.cursor"
        case .meetings: return "person.2.wave.2"
        case .integrations: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct MainView: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject var prefs: AppPrefs
    @State private var page: Page = MainView.startPage
    /// The page before Inställningar, where its "Tillbaka" leads.
    @State private var returnPage: Page = .dictation
    @State private var introduction = false
    /// Where the window opens (Settings after a language switch).
    static var startPage: Page = .dictation
    /// The page on screen (an import done elsewhere notifies).
    static var currentPage: Page = .dictation
    /// The introduction is playing over the window — it counts as the introduction
    /// for the dictation key, too (AppDelegate.isOnboarding).
    static var introductionShown = false
    /// The tab bar's top: its first row level with the pages' top line, clear of the
    /// traffic lights.
    static let barTop: CGFloat = DS.Layout.pageTop - 8
    /// Renders: the window drawn without asking macOS about permissions.
    static var rendering = false

    var body: some View {
        // The page gets the whole window; a tab bar floats at the leading edge, at the top.
        ZStack(alignment: .topLeading) {
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

            FloatingTabBar(page: $page, returnPage: returnPage, dictation: dictation)
                .padding(.leading, 16)
                .padding(.top, Self.barTop)
        }
        .onChange(of: page) { old, new in
            if new == .settings, old != .settings { returnPage = old }
        }
        .ignoresSafeArea()
        // Minska rörelse: no springs, slides or scaling anywhere in the window.
        .transaction { t in if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { t.animation = nil } }
        .frame(minWidth: 940, minHeight: 580)
        .onAppear { if !Self.rendering { dictation.refreshPermissions() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !Self.rendering { dictation.refreshPermissions() }
        }
        .overlay {
            if introduction {
                IntroductionOverlay(dictation: dictation) { finished in
                    MainView.introductionShown = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        introduction = false
                        // All the way through: on to Hem, where it all starts.
                        if finished { page = .dictation }
                    }
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showIntroduction)) { _ in
            MainView.introductionShown = true
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
}

/// The introduction over the whole main window, with a way out in the corner.
private struct IntroductionOverlay: View {
    @ObservedObject var dictation: Dictation
    /// True when it was gone through to the end ("Öppna Mindtalk").
    let close: (_ finished: Bool) -> Void

    var body: some View {
        OnboardingView(dictation: dictation) { done(finished: true) }
            .background(DS.Colors.paper)
            .overlay(alignment: .topTrailing) {
                Button { done(finished: false) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.muted)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.Colors.chip))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // No Esc: "Prova" uses it to stop a dictation, and one press too
                // many shouldn't end the whole introduction.
                .help("Stäng introduktionen")
                .accessibilityLabel("Stäng introduktionen")
                .padding(16)
            }
    }

    private func done(finished: Bool) {
        dictation.stopPickingKey(reason: "introduction closed")
        VocabularyStep.commitPending?()     // a word typed but not added
        VocabularyStep.commitPending = nil
        Settings.didOnboard = true
        close(finished)
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
                CardRow(title: "Mikrofon", detail: "Mindtalk lyssnar bara när du dikterar, säger en tanke eller spelar in ett möte.") {
                    if dictation.micGranted { GrantedLabel(text: "Tillåten") }
                    else { Button("Tillåt") { dictation.requestMicrophone() }.buttonStyle(.ink) }
                }
                CardDivider()
                // The one place Hjälpmedel is asked for. The tip once Tillåt has been
                // pressed and it's still off: macOS sometimes needs it switched off and on.
                CardRow(title: "Hjälpmedel", detail: dictation.accessibilityAsked && !dictation.accessibilityGranted
                        ? String(localized: "Utan Hjälpmedel fungerar inga genvägar.") + " "
                            + String(localized: "Står Mindtalk redan på under Integritet och säkerhet → Hjälpmedel? Slå av och på den igen.")
                        : String(localized: "Utan Hjälpmedel fungerar inga genvägar.")) {
                    if dictation.accessibilityGranted { GrantedLabel() }
                    else { Button("Tillåt") { dictation.requestAccessibility() }.buttonStyle(.ink) }
                }
                CardDivider()
                CardRow(title: dictation.engine == .swedish ? String(localized: "Talmodellen för svenska")
                                                            : String(localized: "Den flerspråkiga talmodellen"),
                        detail: modelDetail(dictation.model, dictation.engine)) {
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
    case .downloading(let p) where p >= 0.9: return String(localized: "Förbereder talmodellen för din Mac…")
    case .downloading: return String(localized: "Laddar ned \(engine.modelName), bara den här gången.")
    case .loading: return String(localized: "Startar. Första gången tar det ungefär en halv minut.")
    // Downloaded but wouldn't start: said plainly, not as the system's error.
    case .failed(let message): return engine.isInstalled ? String(localized: "Talmodellen startade inte.") : message
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
            Button(LocalizedStringKey(dictation.model == .missing ? "Ladda ned" : "Försök igen")) {
                // A failed one is started again if it's here, downloaded again if not.
                if dictation.model == .missing { dictation.downloadModel() } else { dictation.retryModel() }
            }
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
    /// Screenshots: without the scroll view.
    var plain = false
    /// Screenshots: this section, whatever was shown last.
    var fixedSection: SettingsSection? = nil
    @ObservedObject private var mics = Microphones.shared
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var voices = VoiceModels.shared
    @State private var loginStatus = SMAppService.mainApp.status
    /// Why "Starta vid inloggning" couldn't be switched, from macOS.
    @State private var loginError: String?
    @ObservedObject private var meeting = MeetingSession.shared
    @ObservedObject private var importer = MeetingImport.shared
    @State private var showMicPicker = false
    @State private var appLanguage = AppLanguage.chosen
    @State private var meetingShortcut = Settings.meetingShortcut
    /// The thought key, so the meeting shortcut never takes the same keys.
    @State private var thoughtShortcut = Settings.thoughtShortcut
    @State private var pickingMeetingKey = false
    @State private var pickingThoughtKey = false
    /// Why the thought key just picked wasn't taken (the dictation key has it).
    @State private var thoughtKeyRefusal: String?

    // MARK: Sections

    /// The section on screen, kept across launches (the menu bar's Inställningar… opens it
    /// again). The sections themselves are listed in the tab bar.
    @AppStorage(SettingsSection.storageKey) private var sectionRaw = SettingsSection.general.rawValue

    private var section: SettingsSection {
        fixedSection ?? SettingsSection.preview ?? SettingsSection(stored: sectionRaw)
    }

    /// Settings on that section, also when Settings is already on screen.
    static func open(_ section: SettingsSection) {
        UserDefaults.standard.set(section.rawValue, forKey: SettingsSection.storageKey)
        AppDelegate.showWindow(page: .settings)
    }

    /// Settings → Integrationer, where MCP is (mindtalk://settings/mcp).
    static func openMCP() { open(.integrations) }

    /// Om Mindtalk: the popover from the version line in the tab bar.
    static func showAbout() {
        AppDelegate.showWindow(page: .settings)
        NotificationCenter.default.post(name: .showAbout, object: nil)
    }

    var body: some View {
        Group {
            if plain {
                sectionContent.padding(28)
            } else {
                // The same column as every other page, so the left edge stays put;
                // a new section starts at its top.
                sectionContent
                    .pageLayout()
                    .id(section)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: plain ? nil : .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: section)
        // A new dictation key moves the thought key's default (left ⌥ unless dictation has it).
        .onChange(of: dictation.hotkey) { _, _ in thoughtShortcut = Settings.thoughtShortcut }
        .onAppear { loginStatus = SMAppService.mainApp.status; updates.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
            updates.refresh()
        }
        .sheet(isPresented: $showMicPicker) {
            MicrophonePicker(mics: mics) { showMicPicker = false }
        }
    }

    // MARK: The section

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: section.title)
                .font(DS.pageTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)

            switch section {
            case .general: generalSection
            case .language: languageSection
            case .dictation: dictationSection
            case .meetings: meetingsSection
            case .integrations: ClaudeSettingsCard(sharing: .shared)
            }
        }
    }

    // MARK: Allmänt

    @ViewBuilder private var generalSection: some View {
        if !AppMover.isInApplications {
            // Outside Applications Mindtalk can't update itself or open at login reliably.
            CardRow(title: "Flytta till Program",
                    detail: "Mindtalk behöver ligga i Program för att kunna uppdatera sig själv och starta vid inloggning.") {
                Button("Flytta") { AppMover.moveNow() }.buttonStyle(.ink)
                    .disabled(dictation.phase != .idle || meeting.isBusy || importer.busy)
            }
            .card()
        }

        shortcutsCard

        // The Mac: what Mindtalk hears with, where it lives and how it looks.
        VStack(spacing: 0) {
            microphoneRow
            CardDivider()
            loginRow
            CardDivider()
            CardRow(title: "Visa i Dock", detail: "Annars finns Mindtalk bara i menyraden när fönstret är stängt.") {
                InkToggle(label: "Visa i Dock", isOn: $prefs.showInDock)
            }
            CardDivider()
            CardRow(title: "Utseende") {
                PillPicker(options: Appearance.allCases.map { ($0, $0.title) }, selection: $prefs.appearance)
            }
        }
        .card()

        // Updates in one row: the text says whether Mindtalk looks on its own.
        VStack(spacing: 0) {
            CardRow(title: "Uppdateringar", detail: updatesDetail) {
                HStack(spacing: 12) {
                    Button("Sök nu") { Updates.shared.checkNow() }.buttonStyle(.soft)
                    InkToggle(label: "Sök efter uppdateringar automatiskt", isOn: $updates.automatic)
                        .help("Sök efter uppdateringar automatiskt")
                }
                .disabled(!Updates.isAvailable || !AppMover.isInApplications)
            }
            CardDivider()
            ModelsFootprintRow()
        }
        .card()
    }

    // MARK: Genvägar

    /// All three keys heard in every app, in one place: the same fields as on Diktering,
    /// Tankar and Möten, so two can never share keys. Without Hjälpmedel none of them
    /// work, and the card says so where you read it. ⌃⌥V and Esc last, to know, not change.
    private var shortcutsCard: some View {
        VStack(spacing: 0) {
            CardRow(title: "Genvägar",
                    detail: dictation.accessibilityGranted ? "Genvägarna fungerar överallt när Mindtalk har Hjälpmedel."
                        : "Genvägarna behöver Hjälpmedel. Tillåt det på Hem.") { EmptyView() }
            CardDivider()
            CardRow(title: "Diktering", detail: dictationKeyDetail) {
                DictationKeyField(dictation: dictation)
                    .disabled(!dictation.accessibilityGranted)
            }
            CardDivider()
            CardRow(title: "Tanke", detail: thoughtKeyDetail) {
                ThoughtShortcutField(shortcut: $thoughtShortcut, picking: $pickingThoughtKey, refusal: $thoughtKeyRefusal,
                                     meeting: meetingShortcut)
                    .disabled(!dictation.accessibilityGranted)
            }
            CardDivider()
            meetingKeyRow(title: "Möte")
            CardDivider()
            // Not to be changed, only known: the chip where the others have their field.
            CardRow(title: "Klistra in senaste",
                    detail: "Klistrar in den senaste dikteringen där markören står. Esc avbryter en diktering.") {
                HStack(spacing: 8) {
                    KeyChip(text: "⌃⌥V")
                        .padding(.leading, 8)
                        .frame(width: 244, alignment: .leading)
                    Color.clear.frame(width: 28, height: 1).accessibilityHidden(true)
                }
            }
        }
        .card()
        .onDisappear { dictation.stopPickingKey(reason: "Allmänt left") }
    }

    private var dictationKeyDetail: String {
        if dictation.pickingKey {
            return String(localized: "Håll in en eller flera tangenter, som ⌥ och ⌘, och släpp. Du kan också trycka på en vanlig tangent. Esc avbryter.")
        }
        if let why = dictation.keyRefusal { return why }
        return dictation.mode == .toggle ? String(localized: "Tryck och prata.") : String(localized: "Håll in och prata.")
    }

    private var thoughtKeyDetail: String {
        if pickingThoughtKey {
            return String(localized: "Håll in en tangent, som vänster ⌥, och släpp. Du kan också trycka på en kombination, som ⌃⌥T. Esc avbryter.")
        }
        if let why = thoughtKeyRefusal { return why }
        return thoughtShortcut == nil ? String(localized: "Av. På Tankar kan du ändå säga en tanke.")
                                      : String(localized: "Håll in och tänk högt.")
    }

    /// The meeting's shortcut: in Genvägar, and first under Möten. One setting, one field.
    private func meetingKeyRow(title: String) -> some View {
        CardRow(title: title, detail: pickingMeetingKey
                ? String(localized: "Tryck på en tangent tillsammans med ⌘, ⌃ eller ⌥. Esc avbryter.")
                : meetingShortcut == nil
                    ? String(localized: "Ingen genväg. I Mindtalk fungerar ⇧⌘R.")
                    : meetingShortcut?.warning ?? String(localized: "Startar och avslutar ett möte, var du än är.")) {
            MeetingShortcutField(chord: $meetingShortcut, picking: $pickingMeetingKey, taken: [thoughtShortcut?.chord])
                .disabled(!dictation.accessibilityGranted)
                .help(dictation.accessibilityGranted ? Text(verbatim: "") : Text("Slå på Hjälpmedel för Mindtalk först."))
        }
    }

    /// What both dictation and meetings hear with.
    private var microphoneRow: some View {
        CardRow(title: "Mikrofon", detail: !dictation.micGranted ? "Mindtalk behöver få använda mikrofonen."
                : meeting.isBusy ? String(localized: "\(mics.selectionName). Går att byta när mötet är klart.") : mics.selectionName) {
            if dictation.micGranted {
                Button("Ändra") { showMicPicker = true }.buttonStyle(.soft)
                    .disabled(meeting.isBusy || dictation.phase == .recording || dictation.phase == .transcribing)
            }
            else { Button("Tillåt") { dictation.requestMicrophone() }.buttonStyle(.ink) }
        }
    }

    private var loginRow: some View {
        CardRow(title: "Starta vid inloggning",
                detail: loginError ?? (loginStatus == .requiresApproval ? String(localized: "Godkänn Mindtalk under Allmänt → Inloggningsobjekt och tillägg i Systeminställningar.") : nil)) {
            HStack(spacing: 10) {
                if loginStatus == .requiresApproval {
                    Button("Öppna") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.soft)
                }
                InkToggle(label: "Starta vid inloggning", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            NSLog("Mindtalk: launch at login: \(error.localizedDescription)")
                            // Said in the row: usually that Mindtalk isn't in Applications.
                            loginError = AppMover.isInApplications
                                ? String(localized: "Det gick inte just nu: \(error.localizedDescription)")
                                : String(localized: "Mindtalk behöver ligga i Program för att starta vid inloggning.")
                        }
                        loginStatus = SMAppService.mainApp.status
                    }))
            }
        }
    }

    private var updatesDetail: String {
        #if DEBUG
        return String(localized: "Avstängt i utvecklingsbygget.")
        #else
        if !AppMover.isInApplications { return String(localized: "Mindtalk behöver ligga i Program för att uppdateras.") }
        return updates.automatic ? String(localized: "Mindtalk söker själv en gång om dagen.")
                                 : String(localized: "Mindtalk söker bara när du trycker på Sök nu.")
        #endif
    }

    /// The app's language; "Starta om" once another one is chosen.
    private var languageRow: some View {
        CardRow(title: "Appens språk",
                detail: appLanguage.resolved == AppLanguage.running ? nil
                    : meeting.isBusy ? "Mindtalk behöver startas om för att byta språk. Det går när mötet är klart."
                    : importer.busy ? "Mindtalk behöver startas om för att byta språk. Det går när inspelningen är nedskriven."
                    : dictation.phase != .idle ? "Mindtalk behöver startas om för att byta språk. Det går när dikteringen är klar."
                    : "Mindtalk behöver startas om för att byta språk.") {
            HStack(spacing: 10) {
                if appLanguage.resolved != AppLanguage.running {
                    Button("Starta om") { AppDelegate.relaunch(showing: .settings) }
                        .buttonStyle(.ink)
                        .fixedSize()
                        .disabled(dictation.phase != .idle || meeting.isBusy || importer.busy)
                }
                MenuPicker(options: AppLanguage.allCases.map { ($0, $0.title) }, selection: $appLanguage)
                    .onChange(of: appLanguage) { _, new in AppLanguage.chosen = new }
            }
        }
    }

    // MARK: Språk — the app's, and what both dictation and meetings hear in

    @ViewBuilder private var languageSection: some View {
        languageRow.card()
        SpeechLanguagesCard(dictation: dictation)
    }

    // MARK: Diktering
    //
    // The key is on the Diktering page's card, and ⌃⌥V under its list.

    @ViewBuilder private var dictationSection: some View {
        VStack(spacing: 0) {
            CardRow(title: "Hur du dikterar", detail: dictation.mode.explanation(key: dictation.hotkey.inlineName)) {
                MenuPicker(options: DictationMode.allCases.map { ($0, $0.title) },
                           selection: Binding(get: { dictation.mode }, set: { dictation.setMode($0) }))
            }
            CardDivider()
            CardRow(title: "Musik medan du dikterar", detail: prefs.mediaMode.explanation) {
                MenuPicker(options: MediaMode.allCases.map { ($0, $0.title) }, selection: $prefs.mediaMode)
            }
            CardDivider()
            // The same cues start a meeting and its introduction round: switched off here, all of them.
            CardRow(title: "Ljud vid diktering", detail: "Ett kort ljud när Mindtalk börjar och slutar lyssna. Gäller också möten.") {
                InkToggle(label: "Ljud vid diktering", isOn: $prefs.sounds)
            }
        }
        .card()
        TextCleanupCard(prefs: prefs)
    }

    // MARK: Möten

    @ViewBuilder private var meetingsSection: some View {
        // Meetings can't be recorded without it: first, until it's here.
        if voices.state != .ready { VoiceModelSettingsCard() }
        meetingKeyRow(title: "Starta ett möte").card()
        MeetingStorageCard()
        VoiceMemoryCard(memory: .shared)
        SummaryWritersCard()
    }
}

/// The white field the meeting and thought shortcuts are shown and picked in.
private struct PickerFieldLabel<Content: View>: View {
    let picking: Bool
    let wide: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
            Spacer(minLength: 16)
            Image(systemName: "pencil").foregroundStyle(DS.Colors.muted)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(width: wide ? 280 : 244)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(picking ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// The dictation key in a white field, as the other two: click, then hold the keys and
/// let go. The same picking as Ändra on Diktering; never off, so no ✕.
private struct DictationKeyField: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        HStack(spacing: 8) {
            Button { dictation.togglePickingKey() } label: {
                PickerFieldLabel(picking: dictation.pickingKey, wide: false) {
                    if dictation.pickingKey {
                        Text("Tryck på en tangent…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    } else {
                        KeyChip(text: dictation.hotkey.chip)
                    }
                }
            }
            .buttonStyle(.plain)
            // Where the others have ✕: the fields start in one line.
            Color.clear.frame(width: 28, height: 38).accessibilityHidden(true)
        }
        .help(LocalizedStringKey(dictation.accessibilityGranted ? "Klicka och håll in tangenterna du vill använda. Släpp för att spara. Du kan också trycka på en vanlig tangent. Esc avbryter."
                                                                : "Slå på Hjälpmedel för Mindtalk först."))
        .accessibilityLabel(dictation.pickingKey ? Text("Avbryt") : Text("Ändra genvägen"))
    }
}

/// ✕ beside a shortcut field: the shortcut off.
private struct ShortcutOffButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(DS.Colors.faint)
                .frame(width: 28, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stäng av genvägen")
        .accessibilityLabel("Stäng av genvägen")
    }
}

/// A shortcut heard in every app (the meeting): click, then press it — a key with
/// ⌘, ⌃ or ⌥. `taken`: the others, so two never share keys.
struct MeetingShortcutField: View {
    @Binding var chord: KeyChord?
    @Binding var picking: Bool
    var taken: [KeyChord?] = []
    var apply: (KeyChord?) -> Void = { new in
        Settings.meetingShortcut = new
        KeyListener.shared.meetingChord = new
    }
    @State private var monitor: Any?
    /// Who this field is, to the others (and to itself: its own "stop" isn't for it).
    @State private var token = "meeting " + UUID().uuidString.prefix(8)

    var body: some View {
        HStack(spacing: 8) {
            Button { tapped() } label: {
                PickerFieldLabel(picking: picking, wide: chord == nil || picking) {
                    if picking {
                        Text("Tryck på kombinationen…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    } else if let chord {
                        KeyChip(text: chord.chip)
                    } else {
                        Text("Ingen genväg").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Klicka och tryck på en tangent tillsammans med ⌘, ⌃ eller ⌥. Esc avbryter.")
            if chord != nil, !picking {
                ShortcutOffButton {
                    ShortcutLog.log.notice("meeting shortcut: turned off")
                    set(nil)
                }
            }
        }
        .onDisappear { if picking { stop(because: "field gone") } }
        .onReceive(NotificationCenter.default.publisher(for: .stopChordPicking)) { note in
            if picking, ShortcutPicking.concerns(note, token: token) { stop(because: ShortcutPicking.reason(note)) }
        }
    }

    private func tapped() {
        ShortcutLog.log.notice("meeting shortcut: field tapped (picking \(picking, privacy: .public), accessibility \(Dictation.shared.accessibilityGranted, privacy: .public))")
        picking ? stop(because: "pressed again") : start()
    }

    private func start() {
        // One picker at a time: the other field, or the dictation key, stops first.
        ShortcutPicking.stopOthers(token)
        Dictation.shared.stopPickingKey(reason: "another field started")
        picking = true
        ShortcutPicking.hold(token)
        ShortcutLog.log.notice("meeting shortcut: picking started")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(because: "Esc"); return nil }
            let new = KeyChord(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue))
            guard Self.acceptable(new, taken: taken) else {
                ShortcutLog.log.notice("meeting shortcut: refused \(new.keyCode, privacy: .public) with \(String(new.modifiers, radix: 16), privacy: .public)")
                NSSound.beep()
                return nil
            }
            ShortcutLog.log.notice("meeting shortcut: picked \(new.keyCode, privacy: .public) with \(String(new.modifiers, radix: 16), privacy: .public)")
            set(new)
            stop(because: "picked")
            return nil
        }
    }

    /// A chord that can be a shortcut in every app: with ⌘, ⌃ or ⌥, not one the Mac
    /// or Mindtalk needs, and not one of the others.
    static func acceptable(_ new: KeyChord, taken: [KeyChord?]) -> Bool {
        // ⌃⌥V is "klistra in senaste igen"; a key on its own would stop typing it.
        let pasteLast = KeyChord(keyCode: UInt16(kVK_ANSI_V), modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
        return new.isValid && !new.isReserved && new != pasteLast && !taken.contains(new)
    }

    private func stop(because reason: String) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if picking { ShortcutLog.log.notice("meeting shortcut: picking stopped (\(reason, privacy: .public))") }
        picking = false
        ShortcutPicking.release(token)
    }

    private func set(_ new: KeyChord?) {
        chord = new
        apply(new)
    }
}

/// The thought shortcut: a key held on its own (left ⌥), like the dictation key — or a
/// chord like ⌃⌥T. Click, then hold the key alone and let go, or press the combination.
/// Never the dictation key: that's refused, and said why. In Inställningar a white
/// field (`.field`, with ✕ to turn it off); on Tankar flat tile buttons, Ändra and
/// Stäng av (`.button`), in the key card.
struct ThoughtShortcutField: View {
    enum Style { case field, button }

    @Binding var shortcut: ThoughtShortcut?
    @Binding var picking: Bool
    @Binding var refusal: String?
    var meeting: KeyChord?
    var style: Style = .field
    /// Hjälpmedel is on: without it the key can't be felt, so `.button` can't pick one.
    var granted = true
    var apply: (ThoughtShortcut?) -> Void = { new in
        Settings.thoughtShortcut = new
        KeyListener.shared.thoughtShortcut = new
    }
    @State private var monitor: Any?
    /// The modifiers held together so far, at their most — one alone is the choice.
    @State private var most: UInt64 = 0
    /// A key went down meanwhile: a chord, not a key held alone.
    @State private var typed = false
    /// Modifiers already down when picking began (⇧ held while clicking the field):
    /// not part of the choice, as for the dictation key.
    @State private var heldOver: UInt64 = 0
    /// Who this field is, to the others (and to itself: its own "stop" isn't for it).
    @State private var token = "thought " + UUID().uuidString.prefix(8)

    var body: some View {
        Group {
            switch style {
            case .field:
                HStack(spacing: 8) {
                    Button { tapped() } label: {
                        PickerFieldLabel(picking: picking, wide: shortcut == nil || picking) {
                            if picking {
                                Text("Tryck på en tangent…").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                            } else if let shortcut {
                                KeyChip(text: shortcut.chip)
                            } else {
                                Text("Ingen genväg").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Klicka och håll in en tangent ensam, som vänster ⌥, och släpp. Eller tryck på en kombination. Esc avbryter.")
                    if shortcut != nil, !picking {
                        ShortcutOffButton {
                            ShortcutLog.log.notice("thought key: turned off")
                            set(nil)
                        }
                    }
                }
            case .button:
                HStack(spacing: 8) {
                    Button { tapped() } label: { picking ? Text("Avbryt") : shortcut == nil ? Text("Välj") : Text("Ändra") }
                        .buttonStyle(TileButtonStyle())
                        .disabled(!granted)
                        .help(!granted ? Text("Slå på Hjälpmedel för Mindtalk först.")
                              : picking ? Text("Esc avbryter.")
                              : Text("Klicka och håll in en tangent ensam, som vänster ⌥, och släpp. Eller tryck på en kombination. Esc avbryter."))
                        .accessibilityLabel(picking ? Text("Avbryt") : shortcut == nil ? Text("Välj en genväg") : Text("Ändra genvägen"))
                    // The key off, as ✕ does beside the field in Inställningar.
                    if shortcut != nil, !picking {
                        Button("Stäng av") {
                            ShortcutLog.log.notice("thought key: turned off")
                            set(nil)
                        }
                        .buttonStyle(TileButtonStyle())
                        .help("Stäng av genvägen")
                        .accessibilityLabel(Text("Stäng av genvägen"))
                    }
                }
            }
        }
        .onDisappear { if picking { stop(because: "field gone") } }
        .onReceive(NotificationCenter.default.publisher(for: .stopChordPicking)) { note in
            if picking, ShortcutPicking.concerns(note, token: token) { stop(because: ShortcutPicking.reason(note)) }
        }
    }

    private func tapped() {
        ShortcutLog.log.notice("thought key: field tapped (picking \(picking, privacy: .public), accessibility \(Dictation.shared.accessibilityGranted, privacy: .public))")
        picking ? stop(because: "pressed again") : start()
    }

    private func start() {
        // One picker at a time: the other field, or the dictation key, stops first.
        ShortcutPicking.stopOthers(token)
        Dictation.shared.stopPickingKey(reason: "another field started")
        picking = true
        refusal = nil
        most = 0
        typed = false
        heldOver = KeyListener.shared.modifiersHeldNow() & Hotkey.allModifierMasks
        ShortcutPicking.hold(token)
        ShortcutLog.log.notice("thought key: picking started (held over \(String(heldOver, radix: 16), privacy: .public))")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                modifiersChanged(event)
                return event
            }
            if event.keyCode == UInt16(kVK_Escape) { stop(because: "Esc"); return nil }
            typed = true
            let new = KeyChord(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue))
            guard MeetingShortcutField.acceptable(new, taken: [meeting]) else {
                ShortcutLog.log.notice("thought key: refused chord \(new.keyCode, privacy: .public) with \(String(new.modifiers, radix: 16), privacy: .public)")
                NSSound.beep()
                return nil
            }
            pick(.chord(new))
            return nil
        }
    }

    /// Like the dictation key: the choice is made when everything is let go — one
    /// modifier, held with nothing else, is the key.
    private func modifiersChanged(_ event: NSEvent) {
        let raw = UInt64(event.modifierFlags.rawValue)
        ShortcutLog.log.notice("thought key picker: flagsChanged \(event.keyCode, privacy: .public) flags \(String(raw, radix: 16), privacy: .public) heldOver \(String(heldOver, radix: 16), privacy: .public)")
        guard Hotkey.modifierMasks[event.keyCode] != nil else { return }
        // NSEvent's flags carry the same sided bits as the event tap's. One let go
        // since picking began stops being held over.
        heldOver &= raw
        let held = raw & Hotkey.allModifierMasks & ~heldOver
        if held.nonzeroBitCount > most.nonzeroBitCount { most = held }
        guard held == 0 else { return }
        defer { most = 0; typed = false }
        guard !typed, let key = Hotkey.modifierCombination(mask: most) else { return }
        // Several held together: a key held alone is one key.
        guard key.modifierKeys.count == 1 else {
            ShortcutLog.log.notice("thought key: refused \(key.modifierKeys.count, privacy: .public) keys held together")
            NSSound.beep()
            return
        }
        pick(.key(key))
    }

    private func pick(_ new: ThoughtShortcut) {
        stop(because: "picked")
        let what = new.key.map { "key \($0.keyCode)/\(String($0.modifierMask, radix: 16))" }
            ?? new.chord.map { "chord \($0.keyCode) with \(String($0.modifiers, radix: 16))" } ?? ""
        if let why = new.refusal(besides: Settings.hotkey) {
            ShortcutLog.log.notice("thought key: refused \(what, privacy: .public) (the dictation key has it)")
            NSSound.beep()
            refusal = why
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if refusal == why { refusal = nil } }
            return
        }
        ShortcutLog.log.notice("thought key: picked \(what, privacy: .public)")
        set(new)
    }

    private func stop(because reason: String) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if picking { ShortcutLog.log.notice("thought key: picking stopped (\(reason, privacy: .public))") }
        picking = false
        ShortcutPicking.release(token)
    }

    private func set(_ new: ThoughtShortcut?) {
        shortcut = new
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
    private var picking: Bool { dictation.pickingKey || KeyCardPreview.picking }

    private var title: String {
        dictation.mode == .toggle ? String(localized: "Tryck på \(key) och prata") : String(localized: "Håll in \(key) och prata")
    }

    private var how: String {
        switch dictation.mode {
        case .hold: return String(localized: "Släpp när du är klar, så hamnar texten där markören står. Esc avbryter.")
        case .toggle: return String(localized: "Tryck igen när du är klar, så hamnar texten där markören står. Esc avbryter.")
        case .holdOrDoubleTap: return String(localized: "Släpp när du är klar, så hamnar texten där markören står. Dubbeltryck så slipper du hålla in. Esc avbryter.")
        }
    }

    private var spoken: String {
        if picking { return String(localized: "Tryck på en tangent…") }
        let how = dictation.mode == .toggle ? String(localized: "Tryck och prata.") : String(localized: "Håll in och prata.")
        return String(localized: "Genväg: \(dictation.hotkey.spokenName). \(how)")
    }

    var body: some View {
        KeyCard(keycap: dictation.hotkey.chip,
                picking: picking,
                title: picking ? String(localized: "Tryck på en tangent…") : title,
                detail: dictation.keyRefusal ?? (picking
                    ? String(localized: "Håll in en eller flera tangenter, som ⌥ och ⌘, och släpp. Du kan också trycka på en vanlig tangent. Esc avbryter.")
                    : how),
                refused: dictation.keyRefusal != nil,
                spoken: spoken) {
            // Picked right here, as in Inställningar.
            Button {
                dictation.togglePickingKey()
            } label: {
                picking ? Text("Avbryt") : Text("Ändra")
            }
            .buttonStyle(TileButtonStyle())
            .disabled(!dictation.accessibilityGranted)
            .help(LocalizedStringKey(dictation.accessibilityGranted ? "Klicka och håll in tangenterna du vill använda. Släpp för att spara. Du kan också trycka på en vanlig tangent. Esc avbryter."
                                                                    : "Slå på Hjälpmedel för Mindtalk först."))
            .accessibilityLabel(picking ? Text("Avbryt") : Text("Ändra genvägen"))
        } trailing: {
            if !dictation.needsSetup {
                Button(trying ? "Stäng" : "Prova") {
                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) { trying.toggle() }
                }
                .buttonStyle(TileButtonStyle())
                .accessibilityLabel(trying ? Text("Stäng provrutan") : Text("Prova diktering"))
            }
        } below: {
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
                        // The card's title already says which key, and how.
                        Text("Klicka här och säg något.")
                            .font(.system(size: 17))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.horizontal, 17).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onDisappear { dictation.stopPickingKey(reason: "Diktering left") }
    }
}

/// What it has added up to — the figures Hem doesn't show: everything so far and the
/// time it saved, how fast you talk, your best day, and days in a row. Hem keeps today.
private struct DictationFigures: View {
    @ObservedObject var stats: Stats

    var body: some View {
        let best = stats.bestDay
        // The numbers on one baseline, each with its label right under it.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            figure(Stats.number(stats.totalWords), stats.totalWords == 1 ? "one|ord totalt" : "ord totalt",
                   detail: stats.totalSaved >= 60 ? Stats.saved(stats.totalSaved, .total) : nil)
            if let wpm = stats.wordsPerMinute {
                figure(Stats.number(wpm), "ord i minuten",
                       detail: String(localized: "Du skriver runt \(Int(Stats.typingWordsPerMinute))"))
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
        // The figure first and large, as Hem's; what it counts quietly under it.
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.system(size: 34, weight: .regular, design: .serif)).tracking(-0.6).monospacedDigit()
                .lineLimit(1).fixedSize()
            Text(label).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            if let detail {
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(DS.Colors.faint).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
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
                        // The same ink capsule as Tankar's.
                        HStack(spacing: 12) {
                            Text("Dikteringen är borttagen").font(.system(size: 13, weight: .medium))
                            Button("Ångra") { undoRemove() }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(DS.Colors.onInk)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(Capsule().fill(DS.Colors.ink))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .padding(.bottom, 24)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                // Whatever waited here has been seen: the dot in the tab bar goes.
                .onAppear { dictation.sawWaiting() }
                .onDisappear { dictation.sawWaiting() }
                .confirmationDialog("Rensa historiken?", isPresented: $confirmClear) {
                    Button("Rensa", role: .destructive) { withAnimation(.snappy) { dictation.clearRecent() } }
                    Button("Avbryt", role: .cancel) {}
                } message: {
                    Text("Dina senaste dikteringar tas bort från din Mac och går inte att få tillbaka. ⌃⌥V har då inget att klistra in.")
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeader(title: "Diktering",
                           eyebrow: stats.today.words > 0 ? (stats.today.words == 1 ? String(localized: "1 ord i dag") : String(localized: "\(Stats.number(stats.today.words)) ord i dag"))
                               : stats.totalWords > 0 ? String(localized: "Inget dikterat i dag än") : nil)
                    .staggered(0)
                Spacer(minLength: 16)
                if !dictation.recent.isEmpty {
                    // As Tankar's: what's done to the whole page, behind ….
                    Menu {
                        Button("Rensa historiken…") { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(DS.Colors.muted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.top, 14)
                    .help("Mer")
                    .accessibilityLabel("Mer")
                }
            }
            DictationKeyCard(dictation: dictation).staggered(1)
            if stats.totalWords > 0 {
                DictationFigures(stats: stats).staggered(1)
            }
            if !dictation.recent.isEmpty {
                // As Hem's shelves: the title 12 points over what it names.
                SectionTitle("Det du dikterat").staggered(2)
                    .padding(.bottom, -8)
                ForEach(Self.days(dictation.recent), id: \.title) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        // In small capitals, as the days in the meeting archive.
                        CapsLabel(day.title)
                        VStack(spacing: 0) {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { i, entry in
                                if i > 0 { CardDivider() }
                                RecentRow(entry: entry, paste: { dictation.paste(entry) }, copy: { dictation.copy(entry) },
                                          remove: { remove(entry) })
                            }
                        }
                        .card()
                    }
                    .staggered(2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("De 50 senaste sparas.")
                    KeyChip(text: "⌃⌥V", small: true)
                    Text("klistrar in den senaste igen.")
                }
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.muted)
                .accessibilityElement(children: .combine)
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

/// One dictation: the time on the left, the words, a copy button, and ⋯ (on hover,
/// or reached with the keyboard) with the same three things as a right-click.
private struct RecentRow: View {
    let entry: Dictation.Entry
    /// Into the app you were in before Mindtalk, as ⌃⌥V would.
    let paste: () -> Void
    let copy: () -> Void
    let remove: () -> Void
    @State private var copied = false
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var menuFocused: Bool
    /// The words marked in the text, for "Lägg till i Ordlista…".
    @State private var selection = ""

    private var addable: String? { Self.addable(selection) }

    /// Marked words short enough to be a word in Ordlista.
    private static func addable(_ marked: String) -> String? {
        marked.isEmpty || marked.count > 60 || !marked.contains(where: { $0.isLetter || $0.isNumber }) ? nil : marked
    }

    private var long: Bool { entry.text.count > 280 || entry.text.filter { $0 == "\n" }.count > 3 }

    private static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
    }

    /// 12:58: two digits for the hour on a 12-hour clock as on a 24-hour one.
    private static let widest = Calendar.current.date(bySettingHour: 12, minute: 58, second: 0, of: Date()) ?? Date()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            // On one line, "7:15 AM" too: as wide as the widest time this clock writes,
            // so every row's words start in one line.
            ZStack(alignment: .leading) {
                Text(verbatim: Self.time(Self.widest)).hidden()
                Text(verbatim: Self.time(min(entry.date, Date())))
            }
            .font(.system(size: 12.5)).monospacedDigit()
            .foregroundStyle(DS.Colors.muted)
            .lineLimit(1)
            .fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                // Selectable, and a right-click on a word marks it: "Lägg till i Ordlista…".
                EntryText(text: entry.text, lineLimit: expanded ? nil : 4, selection: $selection) { menuItems($0) }
                    // SwiftUI doesn't see an AppKit view's baseline: the first line's, so
                    // the time beside it lines up with the words.
                    .alignmentGuide(.firstTextBaseline) { _ in EntryText.baseline }
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
            Menu { actions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.muted)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focused($menuFocused)
            // Quiet until the row is pointed at; always there for the keyboard and VoiceOver.
            .opacity(hovering || menuFocused ? 1 : 0)
            .help("Mer")
            .accessibilityLabel(Text("Mer"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { actions }
        // VoiceOver has them as actions on the row, whatever the pointer does.
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button("Klistra in", action: paste)
            Button("Kopiera", action: copy)
            Button("Ta bort", action: remove)
        }
    }

    /// The row's actions, the same behind ⋯ and a right-click.
    @ViewBuilder private var actions: some View {
        if let word = addable {
            Button(String(localized: "Lägg till ”\(word)” i Ordlista…")) { Self.addToVocabulary(word) }
            Divider()
        }
        Button("Klistra in", action: paste)
        Button("Kopiera", action: copy)
        Divider()
        Button("Ta bort", role: .destructive, action: remove)
    }

    /// The same, for a right-click on the text itself (AppKit's menu there), with what's
    /// marked at that moment.
    private func menuItems(_ marked: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let word = Self.addable(marked) {
            items.append(MenuAction(String(localized: "Lägg till ”\(word)” i Ordlista…")) { Self.addToVocabulary(word) })
            items.append(.separator())
        }
        items.append(MenuAction(String(localized: "Klistra in"), paste))
        items.append(MenuAction(String(localized: "Kopiera"), copy))
        items.append(.separator())
        items.append(MenuAction(String(localized: "Ta bort"), remove))
        return items
    }

    /// To Ordlista, the marked words as how it was heard: you write how it's spelled.
    private static func addToVocabulary(_ heard: String) {
        VocabularyPage.pendingHeard = heard
        NotificationCenter.default.post(name: .showPage, object: Page.vocabulary)
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// A dictation's words in a text view of AppKit's: selectable as anywhere, and a
/// right-click on a word outside the selection marks that word — so a word that came
/// out wrong is one click from Ordlista. Four lines until "Visa hela".
private struct EntryText: NSViewRepresentable {
    let text: String
    let lineLimit: Int?
    @Binding var selection: String
    let menu: (_ marked: String) -> [NSMenuItem]

    static let font = NSFont.systemFont(ofSize: 14)
    static let baseline = NSLayoutManager().defaultBaselineOffset(for: font)

    /// What's marked, without the spaces and punctuation around it.
    static func marked(in view: NSTextView) -> String {
        (view.string as NSString).substring(with: view.selectedRange())
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    func makeNSView(context: Context) -> EntryTextView {
        let view = EntryTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: EntryTextView, context: Context) {
        context.coordinator.selection = $selection
        view.menuItems = menu
        if view.string != text { view.string = text }
        view.font = Self.font
        view.textColor = .labelColor
        view.textContainer?.maximumNumberOfLines = lineLimit ?? 0
        view.textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: EntryTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposal.width == nil ? ceil(used.width) : width, height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            let marked = EntryText.marked(in: view)
            // Not while SwiftUI draws: the next turn of the run loop.
            DispatchQueue.main.async { [selection] in
                if selection.wrappedValue != marked { selection.wrappedValue = marked }
            }
        }
    }
}

private final class EntryTextView: NSTextView {
    var menuItems: ((String) -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        // A right-click outside the selection marks the word under it.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let current = selectedRange()
        if index < (string as NSString).length, current.length == 0 || !NSLocationInRange(index, current) {
            setSelectedRange(selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord))
        }
        let menu = NSMenu()
        for item in menuItems?(EntryText.marked(in: self)) ?? [] { menu.addItem(item) }
        return menu
    }

}

// MARK: - Text

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
            CardRow(title: "Röstkommandon", detail: "Säg ”ny rad” eller ”nytt stycke”.") {
                InkToggle(label: "Röstkommandon", isOn: $prefs.voiceCommands)
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
            CardDivider()
            CardRow(title: "Behåll texten i urklipp", detail: "Texten skrivs in som vanligt och ligger sedan kvar i urklipp. Lösenord hamnar aldrig där.") {
                InkToggle(label: "Behåll texten i urklipp", isOn: $prefs.keepInClipboard)
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
            return String(localized: "Sätter skiljetecken och rättar när du ändrar dig mitt i en mening. Använder Apple Intelligence.")
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
struct LicensesSheet: View {
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

/// "Tack till": every model and library Mindtalk is built on, with where to find
/// it and under what licence — what CC BY 4.0 asks of us, said plainly.
struct CreditsSheet: View {
    let close: () -> Void
    /// Screenshots: the rows alone, without the window's frame.
    var plain = false
    @State private var showsLicenses = false
    private static let ccBy = URL(string: "https://creativecommons.org/licenses/by/4.0/deed.sv")!
    private static let parakeet = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!
    private static let fluidAudio = URL(string: "https://github.com/FluidInference/FluidAudio")!
    private static let apache = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    private static let mit = URL(string: "https://opensource.org/license/mit")!
    private static let redimnet = URL(string: "https://huggingface.co/lab260/redimnet2-plus")!
    private static let nemotron = URL(string: "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml")!
    private static let openMDW = URL(string: "https://openmdw.ai/license/")!
    private static let parakeetCTC = URL(string: "https://huggingface.co/nvidia/parakeet-tdt_ctc-110m")!
    private static let parakeetCTCCoreML = URL(string: "https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml")!
    private static let scbNames = URL(string: "https://doi.org/10.5878/fc4h-rp11")!
    private static let sparkle = URL(string: "https://github.com/sparkle-project/Sparkle")!
    private static let mlxSwift = URL(string: "https://github.com/ml-explore/mlx-swift")!
    private static let mlxSwiftLM = URL(string: "https://github.com/ml-explore/mlx-swift-lm")!
    private static let swiftTransformers = URL(string: "https://github.com/huggingface/swift-transformers")!

    var body: some View {
        if plain {
            rows.padding(28).background(DS.Colors.paper)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tack till").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button("Klar", action: close)
                        .buttonStyle(.ink)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                CardDivider()
                ScrollView {
                    rows.padding(20)
                }
            }
            .frame(width: 680, height: 600)
            .background(DS.Colors.paper)
            .sheet(isPresented: $showsLicenses) { LicensesSheet { showsLicenses = false } }
            #if DEBUG
            .task {   // screenshots
                if CommandLine.arguments.contains("--show-licenses") { try? await Task.sleep(for: .seconds(1)); showsLicenses = true }
            }
            #endif
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(SpeechModel.allCases.enumerated()), id: \.element) { i, m in
                if i > 0 { CardDivider() }
                row(title: m.modelName,
                    detail: String(localized: "Av \(m.credit), byggd på NVIDIA Parakeet. CC BY 4.0.")) {
                    links([("Modell", m.modelPage), ("Core ML", m.conversionPage), ("Licens", Self.ccBy)])
                }
            }
            CardDivider()
            row(title: "NVIDIA Parakeet TDT 0.6B v3",
                detail: "Grundmodellen som båda talmodellerna bygger på. Av NVIDIA. CC BY 4.0.") {
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
            row(title: "Lyssnaren (Parakeet TDT-CTC 110M)", detail: "Lyssnar en gång till efter orden i Ordlistan. Av NVIDIA, Core ML av FluidInference. CC BY 4.0.") {
                links([("Modell", Self.parakeetCTC), ("Core ML", Self.parakeetCTCCoreML), ("Licens", Self.ccBy)])
            }
            CardDivider()
            row(title: "Gemma 4", detail: "Skriver sammanfattningar och svar, om du väljer den. Av Google DeepMind, MLX-versioner av lmstudio-community. Apache 2.0.") {
                links([("26B-A4B-it", NotesModel.large.page), ("E4B-it", NotesModel.small.page), ("Licens", Self.apache)])
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
            row(title: "MLX Swift och mlx-swift-lm", detail: "Kör Gemma på din Mac. Av Apple. MIT-licens.") {
                links([("MLX Swift", Self.mlxSwift), ("mlx-swift-lm", Self.mlxSwiftLM), ("Licens", Self.mit)])
            }
            CardDivider()
            row(title: "swift-transformers", detail: "Läser modellernas ordförråd. Av Hugging Face. Apache 2.0.") {
                links([("Källkod", Self.swiftTransformers), ("Licens", Self.apache)])
            }
            CardDivider()
            row(title: "Sparkle", detail: "Håller Mindtalk uppdaterad. Öppen källkod, MIT-licens.") {
                links([("Källkod", Self.sparkle)])
            }
            CardDivider()
            row(title: "Licenser", detail: "Licenstexterna och länkarna som följer med Mindtalk.") {
                Button("Visa licenser…") { showsLicenses = true }
                    .buttonStyle(.soft)
            }
        }
        .card()
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
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Link(destination: item.1) {
                    HStack(spacing: 2) {
                        Text(LocalizedStringKey(item.0))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
            }
        }
        .fixedSize()
    }
}
