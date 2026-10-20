import AppKit
import ApplicationServices
import Combine
import CoreAudio
import SwiftUI
import os

// MARK: - Dictation
//
// Hold the dictation key, speak, let go — the text is pasted where the cursor is.
// A quick tap instead starts hands-free dictation: tap again to finish. Esc cancels.
// Audio stays in memory and is thrown away right after transcription.
//
// Modifier keys double as shortcut keys (right ⌥ is "Alt Gr" on Swedish keyboards:
// @ £ $ [ ] { } |), so a press where another key joins in counts as a shortcut and
// is dropped silently.

@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
        /// Nowhere to type it: it's in the clipboard instead.
        case copied
        /// A thought, kept in Tankar.
        case saved
        /// Something worth knowing that isn't a problem (a text that came late).
        case notice(String)
    }

    enum ModelState: Equatable {
        case missing
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Dictation")

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { Self.log.info("phase \(String(describing: self.phase), privacy: .public)") } }
    }
    @Published private(set) var handsFree = false {
        didSet { if handsFree && !oldValue { Self.log.info("locked (hands-free)") } }
    }
    /// This recording is a thought (Tankar): kept there, not typed where you are.
    @Published private(set) var forThought = false
    /// The latest mic level — not published: thirty buffers a second would redraw
    /// every view that watches the dictation.
    private(set) var level: Float = 0
    /// The last second or two of mic levels, oldest first — the HUD's waveform. In
    /// `meter`, so only the views that draw it redraw with it.
    let meter = LevelMeter()
    var levels: [Float] { meter.levels }
    static let levelCount = 24
    private var lastLevelPush = Date.distantPast

    #if DEBUG
    /// The HUD mid-sentence, for screenshots: a recording with a speaking waveform.
    func demoRecording() {
        phase = .recording
        recordingStarted = Date().addingTimeInterval(-7)
        let voice: [Float] = [0.05, 0.12, 0.30, 0.52, 0.41, 0.66, 0.35, 0.22, 0.48, 0.71, 0.58, 0.33,
                              0.18, 0.40, 0.62, 0.50, 0.28, 0.45, 0.69, 0.54, 0.31, 0.47, 0.60, 0.38]
        meter.levels = voice
        handsFree = CommandLine.arguments.contains("--demo-locked")
        showsLanguage = CommandLine.arguments.contains("--demo-language")
        if CommandLine.arguments.contains("--demo-transcribing") { phase = .transcribing }
        hud.show()
    }
    #endif

    private func push(level value: Float) {
        // Late buffers after stop() mustn't refill the wave.
        guard phase == .recording else { return }
        peakLevel = max(peakLevel, value)
        level = value
        guard Date().timeIntervalSince(lastLevelPush) > 0.05 else { return }
        lastLevelPush = Date()
        var wave = meter.levels
        wave.removeFirst()
        wave.append(value)
        meter.levels = wave
    }
    @Published private(set) var engine = Settings.engine
    @Published private(set) var model: ModelState = Settings.engine.isInstalled ? .loading : .missing
    /// When the speech model began getting ready — the first time on a Mac (the Neural
    /// Engine compiling it) can take several minutes; the waiting card counts them.
    @Published private(set) var loadingSince = Date()

    /// The current language has never been made ready on this Mac — the long first
    /// start (the Neural Engine compiling it). Later starts take seconds.
    var firstPreparation: Bool { !UserDefaults.standard.bool(forKey: "modelPrepared.\(engine.rawValue)") }
    @Published private(set) var installed = Set(SpeechModel.allCases.filter(\.isInstalled))
    /// Models downloading right now, with progress 0…1.
    @Published private(set) var downloads: [SpeechModel: Double] = [:]
    /// When each running download started — for "about 2 min left".
    private(set) var downloadStarted: [SpeechModel: Date] = [:]
    @Published private(set) var downloadErrors: [SpeechModel: String] = [:]
    private var downloadTasks: [SpeechModel: Task<Void, Never>] = [:]
    private var loadGeneration = 0
    @Published private(set) var hotkey = Settings.hotkey
    @Published private(set) var pickingKey = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var micGranted = Recorder.micAuthorized
    /// Tillåt for Hjälpmedel was pressed this session: if it's still off, Kom igång
    /// says how to switch it off and on again.
    @Published private(set) var accessibilityAsked = false
    /// The last dictations, kept on this Mac (Application Support, readable only by you)
    /// so a paste that landed nowhere can be copied — never a password field's.
    @Published private(set) var recent: [Entry] = Dictation.loadRecent() {
        didSet { saveRecent() }
    }
    /// When the current recording started (for the HUD's timer).
    @Published private(set) var recordingStarted: Date?
    /// A dictation has been typed or copied at least once (a thought isn't one): the
    /// first step on Hem's first-day card. Never reset.
    @Published private(set) var dictatedOnce = UserDefaults.standard.bool(forKey: "dictatedOnce") {
        didSet { UserDefaults.standard.set(dictatedOnce, forKey: "dictatedOnce") }
    }

    struct Entry: Identifiable, Equatable, Codable {
        var id = UUID()
        let text: String
        let date: Date
    }

    // MARK: Recent, kept on this Mac

    /// The last dictations, in Application Support — so a paste that landed in the
    /// wrong place can be copied again, even after a restart. Never leaves the Mac.
    private static var recentFile: URL {
        SpeechModel.rootDirectory.deletingLastPathComponent().appendingPathComponent("Recent.json")
    }
    private static let recentLimit = 50
    private static let saveQueue = DispatchQueue(label: "ai.mindact.mindtalk.recent", qos: .utility)

    private static func loadRecent() -> [Entry] {
        #if DEBUG
        if Demo.on { return Demo.recent }
        #endif
        guard let data = try? Data(contentsOf: recentFile),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(entries.prefix(recentLimit))
    }

    private func saveRecent() {
        #if DEBUG
        if Demo.on { return }
        #endif
        let file = Self.recentFile
        let entries = recent
        // One write at a time, in order — a "Rensa" right after a dictation stays cleared.
        Self.saveQueue.async {
            let fm = FileManager.default
            if entries.isEmpty { try? fm.removeItem(at: file); return }
            let folder = file.deletingLastPathComponent()
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? JSONEncoder().encode(entries).write(to: file, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)   // only you
        }
    }

    var isReady: Bool {
        #if DEBUG
        // Screenshots of the panel from an unsigned build, which has no permissions.
        if Demo.on { return true }
        #endif
        return model == .ready && accessibilityGranted && micGranted
    }

    /// Something the user has to do or wait out: a permission, a download, a
    /// failure. A model that's merely starting (e.g. after switching language)
    /// isn't — it's ready in a moment.
    var needsSetup: Bool {
        #if DEBUG
        if Demo.on { return false }
        #endif
        guard accessibilityGranted && micGranted else { return true }
        switch model {
        case .ready, .loading: return false
        case .missing, .downloading, .failed: return true
        }
    }

    /// What stands between you and dictating right now, most important first —
    /// said plainly, with one action that fixes it.
    enum SetupIssue: Equatable {
        case accessibility, microphone, modelMissing, modelDownloading(Double), modelFailed

        @MainActor var title: String {
            let engine = Dictation.shared.engine
            let model = engine.inlineTitle
            switch self {
            case .accessibility: return String(localized: "Slå på Hjälpmedel för Mindtalk")
            case .microphone: return String(localized: "Tillåt mikrofonen")
            case .modelMissing: return String(localized: "Ladda ned talmodellen (\(model))")
            case .modelDownloading(let p):
                // The last tenth is checking and compiling, not fetching.
                return SpeechModel.isPreparing(p) ? String(localized: "Förbereder talmodellen…")
                                                  : String(localized: "Laddar ned talmodellen (\(Int(min(1, p / 0.9) * 100)) %)")
            case .modelFailed:
                return engine.isInstalled ? String(localized: "Starta talmodellen igen")
                                          : String(localized: "Ladda ned talmodellen igen")
            }
        }

        /// Why it's needed, for a tooltip.
        var why: String {
            switch self {
            case .accessibility:
                return String(localized: "Behövs för att känna av tangenten och skriva in texten. Står Mindtalk redan under Integritet och säkerhet → Hjälpmedel? Slå av och på den igen.")
            case .microphone: return String(localized: "Behövs för att höra vad du säger.")
            case .modelMissing, .modelDownloading, .modelFailed:
                return String(localized: "Taligenkänningen behöver talmodellen. Den laddas ned en gång.")
            }
        }
    }

    var setupIssue: SetupIssue? {
        if !accessibilityGranted { return .accessibility }
        if !micGranted { return .microphone }
        switch model {
        case .missing: return .modelMissing
        case .downloading(let p): return .modelDownloading(p)
        case .failed: return .modelFailed
        case .ready, .loading: return nil
        }
    }

    /// Does what the issue says.
    func fix(_ issue: SetupIssue) {
        switch issue {
        case .accessibility: requestAccessibility()
        case .microphone: requestMicrophone()
        case .modelMissing: downloadModel()
        case .modelFailed: retryModel()
        case .modelDownloading: SettingsPage.open(.language)     // the download's progress, in its language row
        }
    }

    @Published private(set) var mode = Settings.mode

    /// A press shorter than this is a tap, not a hold.
    private let tapThreshold: TimeInterval = 0.3
    /// How long after a tap a second one counts as a double-tap.
    private let doubleTapWindow: TimeInterval = 0.35
    private var awaitingSecondTap = false
    private var doubleTapTimer: DispatchWorkItem?
    private var keyIsDown = false
    private var secondTapDown = false
    private var startCuePlayed = false
    private let recorder = Recorder()
    private let hud = HUD()
    private var pressedAt: Date?
    private var ignoreNextRelease = false
    /// The thought key (held alone) went down during a hands-free thought: it ends the
    /// thought when it's let go — unless it turns out to be ⌘C.
    private var thoughtStopPending = false
    private var permissionPoll: Timer?
    /// The language a recording was started in — it's transcribed in that one,
    /// even if you switch meanwhile (the switch waits until it's done).
    private var recordingEngine: SpeechModel?
    private var engineSwitchPending = false
    /// Loudest level heard this recording, to tell "silence" from "nothing understood".
    private var peakLevel: Float = 0
    /// A problem to report (model missing, no mic…) once the press is clearly
    /// meant — never for ⌥2 → @ or a stray tap.
    private var pendingProblem: (() -> Void)?
    private var watchdog: Timer?
    private var lastReport: Date?
    /// A forgotten hands-free dictation finishes on its own.
    private static let maxRecording: TimeInterval = 10 * 60
    /// No audio at all for this long means the mic is gone — AirPods take about a
    /// second to switch to their headset mode, so not sooner.
    private static let deadMic: TimeInterval = 2.5
    /// Writing never takes this long: the speech model is stuck (busy with another
    /// language, say). The HUD and the key are let go of. A long recording takes
    /// longer to write, so it gets more time.
    private static func maxWriting(for samples: Int) -> TimeInterval {
        90 + 0.3 * Double(samples) / 16_000
    }
    /// The dictation let go of for taking too long: its text, if it comes, is kept
    /// on Diktering all the same.
    private var lateJob: Int?
    /// The sound of the last dictation that couldn't be written, kept in memory (never
    /// on disk) for one more try — never a password field's.
    private var failedTake: Take?
    /// "Försök igen" is there for the last dictation.
    @Published private(set) var canRetry = false

    /// Which press the delayed confirm belongs to — a stale one never confirms the next.
    private var pressGeneration = 0
    /// The thought was started with its key held alone (left ⌥), not a click or a chord.
    private var thoughtByKey = false
    /// The key went down again while the last one was being written: once that's done,
    /// and if it's still held, a new recording starts.
    private var pressWhileWriting = false
    private var thoughtPressWhileWriting = false
    /// When that press went down: the new recording counts from it.
    private var heldSince: Date?
    /// Said in the HUD once the text is in: why the recording ended by itself.
    private enum ClosingNote { case micWentQuiet, micChanged, timeUp }
    private var closingNote: ClosingNote?
    /// The transcription going on; one let go of (Esc, too slow) has its result dropped.
    private var transcription = 0
    /// The screen is locked, or another user is on the Mac: nothing is typed.
    private(set) var away = false

    /// The mic is opened and closed on a queue of its own, never on the main thread:
    /// a Bluetooth headset can take a moment, and the key tap lives on the main run
    /// loop — every key on the Mac would wait meanwhile. One queue, so a stop never
    /// overtakes the start before it.
    private static let micQueue = DispatchQueue(label: "ai.mindact.mindtalk.mic", qos: .userInitiated)
    private var micGeneration = 0
    /// A Bluetooth mic is opened only once the press is confirmed: opening it switches
    /// AirPods to their headset mode (and the music with them), which ⌥2 for @ mustn't.
    private var micWaiting = false
    private var micChoice: AudioDeviceID?
    /// This recording's mic or the Mac's sound is a Bluetooth headset: no sound is
    /// played while it records, it can cost the headset its mic.
    private var headsetInUse = false

    private init() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.push(level: value) }
        }
        let keys = KeyListener.shared
        keys.onPress = { [weak self] in self?.keyPressed() }
        keys.onRelease = { [weak self] in self?.keyReleased() }
        keys.onChord = { [weak self] in
            guard let self else { return }
            self.pendingProblem = nil
            self.pressWhileWriting = false
            guard self.phase == .recording, !self.handsFree, !self.forThought else { return }
            self.cancel()
        }
        recorder.onInterrupted = { [weak self] in
            // The mic went away (AirPods off or connecting, device switched): keep what
            // was said, and the HUD says why it ended.
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.closingNote = .micChanged
                self.finish()
            }
        }
        recorder.onSignalLost = { [weak self] in
            // A headset whose link was taken by another device sends nothing but
            // zeros: what was said before that is kept, and the HUD says why it ended.
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.closingNote = .micWentQuiet
                self.finish()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.leaving() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.back() }
        }
        // The screen locked, or another user took over the Mac (fast user switching):
        // nothing is typed where you can't see it.
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.leaving(locking: true) }
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.back() }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.leaving(locking: true) }
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.back() }
        }
        keys.onSpaceWhileHeld = { [weak self] in self?.spaceWhileHeld() ?? false }
        keys.onThoughtPress = { [weak self] in self?.thoughtPressed() }
        keys.onThoughtRelease = { [weak self] in self?.thoughtReleased() }
        keys.onThoughtChord = { [weak self] in self?.thoughtJoined() }
        keys.onPasteLast = { [weak self] in self?.pasteLast() }
        keys.onEscape = { [weak self] in
            guard let self else { return false }
            if self.phase == .recording {
                self.cancel()
                return true
            }
            // Writing takes longer than it should (the speech model busy elsewhere):
            // Esc lets go of it. A thought is still written down, in Tankar.
            if self.phase == .transcribing {
                self.abandonTranscription(saying: nil)
                return true
            }
            // Esc also closes the menu bar panel.
            return AppDelegate.closeStatusPanelIfShown()
        }
    }

    // MARK: Startup & permissions

    func start() {
        refreshPermissions()
        loadModel()
        // Hjälpmedel can be switched off while Mindtalk runs, and macOS doesn't say:
        // looked at again whenever Mindtalk comes to the front, and every half minute,
        // so Kom igång and the menu bar ask for it in time.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dictation.shared.refreshPermissions() }
        }
        permissionCheck?.invalidate()
        permissionCheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Dictation.shared.refreshPermissions() }
        }
    }

    private var permissionCheck: Timer?

    func refreshPermissions() {
        let hadAccessibility = accessibilityGranted
        micGranted = Recorder.micAuthorized
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted { UserDefaults.standard.set(true, forKey: Self.everTrustedKey) }
        // Accessibility taken away and given back while running: the old tap is deaf
        // for good, so a new one. Otherwise one that macOS switched off is switched on.
        if accessibilityGranted { KeyListener.shared.ensureTap(recreate: !hadAccessibility) }
        if accessibilityGranted, KeyListener.shared.start(), micGranted {
            permissionPoll?.invalidate(); permissionPoll = nil; return
        }
        // macOS doesn't announce newly granted permissions — check once a second until
        // it does, as long as something shows them (the window, the introduction, the
        // panel); with all of them closed the poll stops, and starts again from here
        // when one opens.
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let d = Dictation.shared
                guard AppDelegate.mainWindowVisible || AppDelegate.isOnboarding || AppDelegate.statusPanelShown else {
                    d.permissionPoll?.invalidate(); d.permissionPoll = nil; return
                }
                d.refreshPermissions()
            }
        }
    }

    #if DEBUG
    /// Renders (--render-window): permissions and the model as given, nothing asked of macOS.
    func preview(mic: Bool, accessibility: Bool, asked: Bool, model: ModelState? = nil) {
        micGranted = mic
        accessibilityGranted = accessibility
        accessibilityAsked = asked
        if let model { self.model = model }
    }
    #endif

    /// Mindtalk has been trusted under Hjälpmedel at some point on this Mac.
    private static let everTrustedKey = "accessibilityEverTrusted"

    func requestMicrophone() {
        Task {
            _ = await Recorder.requestMicrophone()
            refreshPermissions()
            if !micGranted { openPrivacySettings("Privacy_Microphone") }
        }
    }

    func requestAccessibility() {
        accessibilityAsked = true
        // Value of kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refreshPermissions()
        // macOS only asks the first time; its own dialog then opens the list. If Mindtalk
        // was trusted before (an update with a new signature, or switched off) nothing
        // appears — so open the list itself. Never both at once.
        guard UserDefaults.standard.bool(forKey: Self.everTrustedKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.accessibilityGranted else { return }
            self.openPrivacySettings("Privacy_Accessibility")
        }
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Models
    //
    // `engine` is the language you dictate in; `model` is how that engine is doing.
    // Any model can be downloading in the background while you use another.

    func setEngine(_ newEngine: SpeechModel) {
        guard newEngine != engine else { return }
        engine = newEngine
        Settings.engine = newEngine
        // Mid-dictation — or mid-meeting — the old model finishes the job first.
        if phase == .recording || phase == .transcribing || MeetingSession.shared.isBusy {
            engineSwitchPending = true; return
        }
        if newEngine.isInstalled { loadModel() } else { refreshModels() }
    }

    /// A meeting has let go of the speech model: a language picked meanwhile takes over.
    func meetingEnded() {
        guard engineSwitchPending, phase == .idle else { return }
        engineSwitchPending = false
        if engine.isInstalled { loadModel() } else { refreshModels() }
    }

    /// Recomputes what's installed and the active engine's state.
    func refreshModels() {
        installed = Set(SpeechModel.allCases.filter(\.isInstalled))
        if let p = downloads[engine] { model = .downloading(p); return }
        if !installed.contains(engine) {
            model = downloadErrors[engine].map { .failed($0) } ?? .missing
        } else if case .missing = model {
            loadModel()
        } else if case .downloading = model {
            loadModel()
        }
    }

    private func loadModel() {
        installed = Set(SpeechModel.allCases.filter(\.isInstalled))
        #if DEBUG
        if Demo.on { model = .ready; return }   // screenshots: no model needed
        #endif
        guard engine.isInstalled else { return refreshModels() }
        model = .loading
        loadingSince = Date()
        loadGeneration += 1
        let generation = loadGeneration
        let target = engine
        Task {
            do {
                try await SpeechEngine.shared.load(target)
                Self.log.info("speech model ready in \(Int(Date().timeIntervalSince(self.loadingSince))) s")
                UserDefaults.standard.set(true, forKey: "modelPrepared.\(target.rawValue)")
                if generation == loadGeneration { model = .ready }
            } catch {
                Self.log.error("speech model failed after \(Int(Date().timeIntervalSince(self.loadingSince))) s: \(error.localizedDescription, privacy: .public)")
                if generation == loadGeneration { model = .failed(error.localizedDescription) }
            }
        }
    }

    /// Languages to switch to once their download is done (asked for from the menu bar).
    private var useWhenReady: Set<SpeechModel> = []

    /// "Försök igen" on a speech model that failed: downloaded again if it isn't
    /// here, started again if it is (the first Neural Engine compile can fail).
    func retryModel() {
        if engine.isInstalled { loadModel() } else { downloadModel() }
    }

    func downloadModel(_ which: SpeechModel? = nil, thenUse: Bool = false) {
        let m = which ?? engine
        guard downloadTasks[m] == nil, !m.isInstalled else { return }
        // Room for the download and for preparing it for this Mac, with some to spare.
        guard BetterNotes.freeBytes > m.downloadBytes * 2 + 500_000_000 else {
            downloadErrors[m] = String(localized: "Det behövs drygt \(BetterNotes.gigabytes(m.downloadBytes * 2)) ledigt på disken.")
            refreshModels()
            return
        }
        if thenUse { useWhenReady.insert(m) }
        downloads[m] = 0
        downloadStarted[m] = Date()
        downloadErrors[m] = nil
        refreshModels()
        downloadTasks[m] = Task {
            do {
                try await m.install { p in
                    Task { @MainActor in
                        let d = Dictation.shared
                        guard let sofar = d.downloads[m] else { return }
                        // Parts land out of order: the number never ticks backwards.
                        let p = max(sofar, p)
                        d.downloads[m] = p
                        if d.engine == m { d.model = .downloading(p) }
                    }
                }
                downloadTasks[m] = nil
                downloads[m] = nil
                downloadStarted[m] = nil
                if useWhenReady.remove(m) != nil, m != engine { setEngine(m) }
                else if m == engine { loadModel() } else { refreshModels() }
            } catch {
                downloadTasks[m] = nil
                downloads[m] = nil
                downloadStarted[m] = nil
                useWhenReady.remove(m)
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled { downloadErrors[m] = Self.plainWords(for: error) }
                refreshModels()
            }
        }
    }

    /// A download error in words anyone understands.
    static func plainWords(for error: Error) -> String {
        switch DownloadTrouble(error) {
        case .offline: return String(localized: "Internetanslutningen bröts. Kontrollera nätverket och försök igen.")
        case .unreachable: return String(localized: "Kunde inte nå servern just nu. Försök igen om en stund.")
        case .diskFull: return String(localized: "Det finns inte tillräckligt med ledigt utrymme på din Mac.")
        case .serverRefused(let code): return String(localized: "Modellen kunde inte hämtas just nu (fel \(code)). Försök igen senare.")
        case .other: return String(localized: "Något gick fel under nedladdningen. Försök igen.")
        }
    }

    /// What went wrong with a download, roughly — also when a library wraps the
    /// system's error in its own (the voice models' does).
    enum DownloadTrouble {
        case offline, unreachable, diskFull, other
        /// The server said no (403, 404), asked for a pause (429) or was down (5xx).
        case serverRefused(Int)

        init(_ error: Error) {
            var next: Error? = error
            for _ in 0..<5 {
                guard let error = next else { break }
                if case ModelError.badResponse(_, let code, _) = error, [403, 404, 429].contains(code) || code >= 500 {
                    self = .serverRefused(code); return
                }
                if let url = error as? URLError {
                    switch url.code {
                    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                        self = .offline; return
                    case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                        self = .unreachable; return
                    default: break
                    }
                }
                let ns = error as NSError
                if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                    || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
                    self = .diskFull; return
                }
                next = ns.userInfo[NSUnderlyingErrorKey] as? Error
            }
            self = .other
        }
    }

    func cancelDownload(_ which: SpeechModel? = nil) {
        downloadTasks[which ?? engine]?.cancel()
    }

    /// Deletes Mindtalk's copy of a model to free up space.
    func removeModel(_ m: SpeechModel) {
        // Not during a meeting, or while recordings are being written out: the model
        // in use, or the one it will switch to, stays.
        guard m.isOwnInstall, !MeetingSession.shared.isBusy, !MeetingImport.shared.busy else { return }
        Task {
            await SpeechEngine.shared.unload(m)
            try? m.uninstall()
            // What macOS and Mindtalk remembered about this copy goes with it: the next
            // one is prepared afresh.
            UserDefaults.standard.removeObject(forKey: "neuralEngineReady.\(m.rawValue)")
            UserDefaults.standard.removeObject(forKey: "modelPrepared.\(m.rawValue)")
            refreshModels()
        }
    }

    // MARK: Picking the key

    func pickKey() {
        ShortcutLog.log.notice("dictation key: picking started (accessibility \(self.accessibilityGranted, privacy: .public), tap running \(KeyListener.shared.isRunning, privacy: .public))")
        pickingKey = true
        keyRefusal = nil
        KeyListener.shared.capture = { [weak self] key in
            guard let self else { return }
            self.pickingKey = false
            // The thought key's: one press can't be both. The old key stays. A thought key
            // you chose counts; the default (left ⌥) just moves out of the way.
            if let why = ThoughtShortcut.refusal(dictation: key, besides: Settings.thoughtShortcut(in: .standard, besides: key)) {
                ShortcutLog.log.notice("dictation key: refused \(key.keyCode, privacy: .public)/\(String(key.modifierMask, radix: 16), privacy: .public) (the thought key has it)")
                return self.refuse(why)
            }
            ShortcutLog.log.notice("dictation key: picked \(key.keyCode, privacy: .public)/\(String(key.modifierMask, radix: 16), privacy: .public)")
            self.hotkey = key
            Settings.hotkey = key
            KeyListener.shared.hotkey = key
            // The thought key's default depends on the dictation key (left ⌥ unless
            // that's taken): the listener gets the one that goes with the new key.
            KeyListener.shared.thoughtShortcut = Settings.thoughtShortcut
            KeyListener.shared.reset()
        }
    }

    /// The dictation key's field (or Ändra on Diktering) was pressed.
    func togglePickingKey() {
        ShortcutLog.log.notice("dictation key: field tapped (picking \(self.pickingKey, privacy: .public), accessibility \(self.accessibilityGranted, privacy: .public))")
        if pickingKey { return stopPickingKey(reason: "pressed again") }
        ShortcutPicking.stopOthers("dictation")
        pickKey()
    }

    func stopPickingKey(reason: String = "stopped") {
        if pickingKey { ShortcutLog.log.notice("dictation key: picking stopped (\(reason, privacy: .public))") }
        pickingKey = false
        KeyListener.shared.capture = nil
    }

    /// Why the key just picked wasn't taken — said where you picked it, for a while.
    @Published private(set) var keyRefusal: String?

    private func refuse(_ why: String) {
        keyRefusal = why
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.keyRefusal == why { self?.keyRefusal = nil }
        }
    }

    // MARK: Key handling
    //
    // Hold mode: press starts the mic at once (so the first word isn't clipped),
    // release finishes. A quick tap is either the first half of a double-tap
    // (→ locked, hands-free) or, if no second tap follows, dropped silently.

    func setMode(_ newMode: DictationMode) {
        mode = newMode
        Settings.mode = newMode
    }

    private func keyPressed() {
        keyIsDown = true
        switch phase {
        case .recording where handsFree:
            ignoreNextRelease = true
            finish()
        case .recording where awaitingSecondTap:
            // Second tap of a double-tap — it locks on release, so ⌥ then ⌥2 (a
            // shortcut) still cancels instead.
            doubleTapTimer?.cancel()
            awaitingSecondTap = false
            secondTapDown = true
        case .idle, .failed, .copied, .saved, .notice:
            freshStart()
            begin()
        case .transcribing:
            // Still writing the last one: this press starts the next once that's in,
            // if the key is still held by then.
            pressWhileWriting = true
            heldSince = Date()
        default:
            break
        }
    }

    private func keyReleased() {
        keyIsDown = false
        pressWhileWriting = false
        if !forThought, let problem = pendingProblem {
            pendingProblem = nil
            if mode == .toggle { problem() }   // a tap is a real press in this mode
            return
        }
        if ignoreNextRelease { ignoreNextRelease = false; return }
        // A thought is going on: its own key is the one that counts.
        if forThought { secondTapDown = false; return }
        guard phase == .recording, !handsFree else { secondTapDown = false; return }
        // A key typed with it that the tap never saw (a password field hides keys from
        // it): ⌥2 for @, typed slowly. A shortcut, dropped without a sound.
        if KeyListener.shared.keyTypedSincePress { return cancel() }
        if secondTapDown { secondTapDown = false; return lock() }
        guard let pressedAt else { return }
        let wasTap = Date().timeIntervalSince(pressedAt) < tapThreshold
        switch mode {
        case .toggle:
            lock()
        case .hold:
            wasTap ? cancel() : finish()
        case .holdOrDoubleTap:
            guard wasTap else { return finish() }
            // Keep listening a moment in case this is a double-tap.
            awaitingSecondTap = true
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.awaitingSecondTap else { return }
                self.cancel()
            }
            doubleTapTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: timer)
        }
    }

    /// Space while holding the key locks the dictation (like Wispr Flow) — once the
    /// hold is confirmed: ⌥ and Space typed together is a character of its own.
    private func spaceWhileHeld() -> Bool {
        guard phase == .recording, !forThought, startCuePlayed || handsFree else { return false }
        if !handsFree, mode != .hold {
            ignoreNextRelease = true
            lock()
        }
        return handsFree
    }

    // MARK: Thoughts

    /// The thought shortcut down: listening begins — or, already listening hands-free
    /// for a thought, it ends and is kept.
    private func thoughtPressed() {
        switch phase {
        case .recording where forThought && handsFree:
            // A key held alone (left ⌥) is also the start of ⌥2 for @: it ends the thought
            // when it's let go with nothing else pressed.
            if KeyListener.shared.thoughtShortcut?.isModifier == true {
                thoughtStopPending = true
                return
            }
            ignoreNextRelease = true
            finish()
        case .idle, .failed, .copied, .saved, .notice:
            freshStart()
            forThought = true
            thoughtByKey = KeyListener.shared.thoughtShortcut?.isModifier == true
            keyIsDown = true
            begin()
            if phase != .recording, pendingProblem == nil { forThought = false; thoughtByKey = false }
        case .transcribing:
            thoughtPressWhileWriting = true
            heldSince = Date()
            keyIsDown = true
        default:
            break           // a dictation is going on: it's left alone
        }
    }

    /// Let go: held, the thought is kept; a quick tap keeps listening until the next
    /// tap (or ✓ in the bubble).
    private func thoughtReleased() {
        keyIsDown = false
        thoughtPressWhileWriting = false
        if thoughtStopPending {
            thoughtStopPending = false
            if phase == .recording, forThought, handsFree { finish() }
            return
        }
        if let problem = pendingProblem {
            pendingProblem = nil
            problem()                // said as a thought's problem, then it's no thought
            forThought = false
            thoughtByKey = false
            return
        }
        if ignoreNextRelease { ignoreNextRelease = false; return }
        guard phase == .recording, forThought, !handsFree, let pressedAt else { return }
        // ⌘ and a key the tap never saw (secure input): a shortcut, not a thought.
        if thoughtByKey, KeyListener.shared.keyTypedSinceThoughtPress { return cancel() }
        if Date().timeIntervalSince(pressedAt) < tapThreshold { lock() } else { finish() }
    }

    /// Another key (or a click) joined the thought key held alone: ⌘C, ⌘Tab, a ⌘-click.
    /// A shortcut, not a thought — dropped silently, like the dictation key's ⌥2 → @.
    private func thoughtJoined() {
        thoughtStopPending = false
        thoughtPressWhileWriting = false
        // A problem waiting to be said (the model starting) — it was never a thought.
        if pendingProblem != nil, phase != .recording, phase != .transcribing { forThought = false; thoughtByKey = false }
        pendingProblem = nil
        guard phase == .recording, forThought, !handsFree else { return }
        cancel()
    }

    /// "Säg en tanke" (the Tankar page, the menu bar): listening hands-free until ✓.
    func startThought() {
        switch phase {
        case .idle, .failed, .copied, .saved, .notice:
            freshStart()
            forThought = true
            // A click is clearly meant: a problem (the model starting, no mic) is said
            // at once, not held for a key release that never comes.
            lastReport = Date()
            begin()
            lastReport = nil
            if phase == .recording { lock() } else {
                forThought = false
                pendingProblem = nil
            }
        default:
            beep()
        }
    }

    // MARK: The HUD's buttons

    /// ✕ on the locked HUD: stop without typing anything.
    func cancelFromHUD() {
        guard phase == .recording else { return }
        cancel()
    }

    /// ✓ on the locked HUD: type what you said.
    func finishFromHUD() {
        guard phase == .recording else { return }
        finish()
    }

    /// "Sparad i Tankar." clicked: the thought, where it went. During the introduction
    /// the step itself shows where: the main window stays out of the way.
    func openThoughtsFromHUD() {
        guard phase == .saved else { return }
        reset()
        if AppDelegate.isOnboarding { return }
        AppDelegate.showWindow(page: .thoughts)
    }

    /// The language, shown for a moment in the HUD when it differs from last time.
    @Published private(set) var showsLanguage = false
    private var lastLanguage: SpeechModel?

    private func lock() {
        awaitingSecondTap = false
        doubleTapTimer?.cancel()
        handsFree = true
        confirmStart()
    }

    /// The press is a real dictation (held, or locked) — show the HUD, play the cue.
    private func confirmStart() {
        guard phase == .recording else { return }
        // A Bluetooth mic waited for this moment.
        if micWaiting {
            micWaiting = false
            recordingStarted = Date()
            openMic(micChoice)
        }
        if !startCuePlayed, installed.count > 1, let last = lastLanguage, last != engine {
            showsLanguage = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.showsLanguage = false }
        }
        if !startCuePlayed {
            lastLanguage = engine
            // Only now — a quick tap or a shortcut like ⌥2 → @ never touches your music.
            if !TextInserter.dryRun { MediaControl.shared.begin() }
        }
        hud.show()
        if !startCuePlayed {
            startCuePlayed = true
            // Not into a Bluetooth headset (MeetingSession.start says why).
            if !(headsetInUse || Recorder.outputIsBluetooth) { Cue.start() }
        }
    }

    /// A new press while the last one's message is still up (copied, saved, failed):
    /// nothing of that recording carries over — not that it was a thought, not that
    /// its cue was played (which is also when the music is paused). The HUD stays up
    /// for the new one.
    private func freshStart() {
        if engineSwitchPending {
            engineSwitchPending = false
            if engine.isInstalled { loadModel() } else { refreshModels() }
        }
        recordingEngine = nil
        handsFree = false
        forThought = false
        thoughtByKey = false
        thoughtStopPending = false
        startCuePlayed = false
        awaitingSecondTap = false
        secondTapDown = false
        doubleTapTimer?.cancel()
        closingNote = nil
        pressedAt = nil
        recordingStarted = nil
    }

    private func begin() {
        // One microphone, one model: a meeting being recorded has both.
        if MeetingSession.shared.isRecording {
            return report {
                $0.fail($0.forThought ? String(localized: "Ett möte spelas in, så tankar får vänta.")
                                      : String(localized: "Ett möte spelas in, så dikteringen är pausad."))
            }
        }
        // One speech model at a time: an import writing in the other language has it.
        if MeetingImport.shared.jobs.contains(where: { ($0.stage == .reading || $0.stage == .writing) && $0.language != engine }) {
            return report { $0.fail(String(localized: "Vänta tills importen är klar.")) }
        }
        switch model {
        case .ready: break
        case .loading:
            // Still not ready after a few seconds: the first time on this Mac, which takes
            // minutes — said the same way as in the introduction.
            let long = firstPreparation && Date().timeIntervalSince(loadingSince) > 5
            return report {
                $0.fail(long ? String(localized: "Talmodellen görs redo för din Mac, bara första gången.")
                             : String(localized: "Talmodellen startar…"))
            }
        case .downloading: return report { $0.fail(String(localized: "Talmodellen laddas fortfarande ned.")) }
        case .missing, .failed:
            return report {
                if AppDelegate.isOnboarding {
                    $0.fail($0.engine.isInstalled ? String(localized: "Talmodellen startade inte.")
                                                   : String(localized: "Talmodellen är inte nedladdad än."))
                }
                else { $0.openingWindow(String(localized: "Talmodellen är inte redo. Öppnar Mindtalk.")) }
            }
        }
        // Asked afresh: the microphone can be taken away in System Settings while
        // Mindtalk runs, and then the message is about the permission, not the mic.
        let mic = Recorder.micAuthorized
        if mic != micGranted { micGranted = mic }
        guard mic else {
            return report {
                if AppDelegate.isOnboarding { $0.fail(String(localized: "Mindtalk behöver tillgång till mikrofonen.")) }
                else { $0.openingWindow(String(localized: "Mindtalk behöver mikrofonen. Öppnar Mindtalk.")) }
            }
        }
        let chosen = Microphones.shared.selectedDeviceID
        let system = Recorder.defaultInput()
        let bluetooth = (chosen ?? system).map(Recorder.isBluetooth) ?? false
        // The system input is the fallback if the chosen mic won't open: counted too.
        headsetInUse = bluetooth || (system.map(Recorder.isBluetooth) ?? false)
        phase = .recording
        // A key heard means you're at the Mac, unlocked (in case a notice went missing).
        away = false
        recordingEngine = engine
        peakLevel = 0
        micChoice = chosen
        // The built-in mic opens at once, so the first word isn't clipped. A Bluetooth
        // one waits for the press to be confirmed: AirPods take a second to switch
        // anyway, and ⌥2 for @ mustn't switch them at all.
        if bluetooth { micWaiting = true } else { micWaiting = false; openMic(chosen) }
        startWatchdog()
        if Settings.aiPolish { Task { await Polisher.shared.prepare() } }
        handsFree = false
        pressedAt = Date()
        recordingStarted = pressedAt
        // Show the HUD once the press is clearly a hold (or it got locked) — a
        // quick tap or a shortcut like ⌥2 → @ shouldn't flash it. A thought waits a
        // little longer: its key is ⌘, held a moment before ⌘C more often than ⌥.
        pressGeneration += 1
        let press = pressGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (forThought ? 0.4 : 0.2)) { [weak self] in
            guard let self, press == self.pressGeneration, self.phase == .recording,
                  self.keyIsDown || self.handsFree || self.mode == .toggle else { return }
            // A key typed with it that the tap never saw (secure input): a shortcut.
            if !self.handsFree, self.typedSincePress { return self.cancel() }
            self.confirmStart()
        }
    }

    /// A key went down after this press, by the keyboard's own account.
    private var typedSincePress: Bool {
        forThought ? thoughtByKey && KeyListener.shared.keyTypedSinceThoughtPress
                   : KeyListener.shared.keyTypedSincePress
    }

    /// Opens the mic on its own queue; a failure comes back here.
    private func openMic(_ chosen: AudioDeviceID?) {
        micGeneration += 1
        let generation = micGeneration
        let recorder = recorder
        let log = Self.log
        Self.micQueue.async {
            do {
                do {
                    try recorder.start(device: chosen)
                } catch where chosen != nil {
                    // The chosen mic won't open (just unplugged, reconnecting) — the
                    // system input will do rather than nothing.
                    log.error("chosen microphone failed, using the system input")
                    try recorder.start(device: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Dictation.shared.micFailed(error, generation: generation) }
                }
            }
        }
    }

    /// Stops the mic on its own queue — after a start still on its way — and hands
    /// what it heard back here. The key tap lives on this thread: it never waits for
    /// the last buffers (a Bluetooth headset can take a moment to let go).
    private func stopMic(then done: (@MainActor ([Float]) -> Void)? = nil) {
        micGeneration += 1
        micWaiting = false
        let recorder = recorder
        Self.micQueue.async {
            let samples = recorder.stop()
            guard let done else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(samples) } }
        }
    }

    private func micFailed(_ error: Error, generation: Int) {
        guard generation == micGeneration, phase == .recording else { return }
        Self.log.error("microphone did not open: \(String(describing: error), privacy: .public)")
        let locked = handsFree
        let message = error.localizedDescription
        cancel()
        if locked { fail(message) } else { report { $0.fail(message) } }
    }

    /// No sound while a Bluetooth headset records (the dictation's or a meeting's):
    /// it can cost the headset its mic.
    private func beep() {
        let dictating = phase == .recording && (headsetInUse || Recorder.outputIsBluetooth)
        let meeting = MeetingSession.shared.isRecording && MeetingSession.shared.soundsReachBluetooth
        if !dictating && !meeting { NSSound.beep() }
    }

    /// After the introduction, a problem that needs the window: said first, then the
    /// window opens.
    private func openingWindow(_ message: String) {
        fail(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppDelegate.showWindow() }
    }

    /// Reports a problem only if the press is held a moment (or in toggle mode, on
    /// release) — a shortcut like ⌥2 → @ or a stray tap stays silent.
    private func report(_ problem: @escaping (Dictation) -> Void) {
        // Two presses in quick succession (a double-tap) are clearly meant too.
        if let last = lastReport, Date().timeIntervalSince(last) < 0.6 {
            lastReport = nil
            pendingProblem = nil
            return problem(self)
        }
        lastReport = Date()
        pendingProblem = { [weak self] in if let self { problem(self) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.keyIsDown, let problem = self.pendingProblem else { return }
            self.pendingProblem = nil
            problem()
            // It never became a recording: not a thought any more either.
            if self.phase != .recording { self.forThought = false; self.thoughtByKey = false }
        }
    }

    /// While recording: catch a missed key release, and end a forgotten dictation.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let d = Dictation.shared
                guard d.phase == .recording else { d.watchdog?.invalidate(); d.watchdog = nil; return }
                if let start = d.recordingStarted, Date().timeIntervalSince(start) > Self.maxRecording {
                    d.closingNote = .timeUp
                    return d.finish()
                }
                // A mic that went quiet without saying so (unplugged, Bluetooth dropped):
                // finish with what was heard instead of recording nothing.
                if d.recorder.silentFor > Self.deadMic {
                    d.closingNote = .micWentQuiet
                    return d.finish()
                }
                // A thought is held whatever the dictation mode.
                if d.keyIsDown, !d.handsFree, d.mode != .toggle || d.forThought { KeyListener.shared.resync() }
            }
        }
    }

    private func finish() {
        let lasted = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
        watchdog?.invalidate(); watchdog = nil
        MediaControl.shared.end()
        let locked = handsFree
        handsFree = false
        awaitingSecondTap = false
        secondTapDown = false
        doubleTapTimer?.cancel()
        pressedAt = nil
        let note = closingNote
        closingNote = nil
        // Writing from here on: the last buffers come in while the HUD says so, and a
        // press meanwhile waits for the text like any other.
        phase = .transcribing
        transcription += 1
        let job = transcription
        let language = recordingEngine ?? engine
        let thought = forThought
        let byKey = thoughtByKey
        let heard = peakLevel
        // Where you are when you stop talking is where the text goes — or
        // nowhere, if you switch app while it's being written.
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // A password field now, or by the time the text is in: secret.
        let secret = !TextInserter.dryRun && SecureInput.isActive
        stopMic { [weak self] samples in
            // Let go of meanwhile (Esc): nothing more to do.
            guard let self, job == self.transcription, self.phase == .transcribing else { return }
            // Held a while and not a sound: the mic never delivered — say so.
            if samples.isEmpty, lasted > 1 {
                self.fail(String(localized: "Hittar ingen fungerande mikrofon."))
                return self.resumeHeldPress()
            }
            // Under a quarter second holds no words.
            guard samples.count > 4_000 else { self.reset(); return self.resumeHeldPress() }
            self.transcribe(Take(samples: samples, job: job, language: language, heard: heard, thought: thought,
                                 byKey: byKey, locked: locked, pending: nil, target: target, secret: secret, note: note))
        }
    }

    /// The recording's sound is in: on its way to text.
    private func transcribe(_ recorded: Take) {
        hud.show()
        let job = recorded.job
        var held = recorded
        // A thought is on the page at once, its sound kept until the text is there —
        // a failed transcription is "Försök igen", not a lost thought.
        held.pending = held.thought && !TextInserter.dryRun ? Thoughts.shared.hold(held.samples, language: held.language) : nil
        writingThought = held.pending
        let take = held
        // Writing never takes this long: the model is stuck. Let go of it — the text
        // is still kept if it comes, and the sound for one more try.
        let limit = Self.maxWriting(for: take.samples.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, self.phase == .transcribing, self.transcription == job else { return }
            Self.log.error("transcription still going after \(Int(limit)) s: let go of")
            self.lateJob = job
            self.keepForRetry(take)
            self.abandonTranscription(saying: Self.couldNotWrite)
        }
        Task {
            await write(take)
            if job == transcription { resumeHeldPress() }
        }
    }

    /// One recording on its way to text.
    private struct Take {
        let samples: [Float]
        var job: Int
        let language: SpeechModel
        let heard: Float
        let thought: Bool
        let byKey: Bool
        /// Listening hands-free (a tap, or the button): ended on purpose, so not a
        /// word heard is worth saying.
        let locked: Bool
        var pending: UUID?
        var target: pid_t?
        var secret: Bool
        var note: ClosingNote?
    }

    /// The thought being written right now, in Tankar.
    private var writingThought: UUID?

    private func write(_ take: Take) async {
        let selfTest = TextInserter.dryRun
        let raw: String
        do {
            // A password field gets what was said, not your Ordlista's words.
            let terms = take.secret && !take.thought ? [] : VocabularyBoost.terms(from: Vocabulary.shared.entries.map(\.word))
            let result = try await SpeechEngine.shared.transcribe(samples: take.samples, with: take.language, listeningFor: terms)
            raw = result.text
            // The debug self-test leaves your vocabulary counts, stats and history alone.
            if !selfTest { Vocabulary.shared.noteHeard(result.fixed) }
        } catch {
            Self.log.error("transcription failed: \(String(describing: error), privacy: .public)")
            if let pending = take.pending { Thoughts.shared.failWriting(pending) }
            guard take.job == transcription else { return }
            if take.pending != nil { return fail(Self.thoughtWithoutText) }
            keepForRetry(take)
            return canRetry ? fail(Self.clickToRetry, for: 8) : fail(Self.couldNotWrite)
        }
        // A password field: typed, never kept or polished.
        let secret = !selfTest && (take.secret || SecureInput.isActive)
        // There it's typed just as the speech model heard it: no rules, no capital
        // letter or full stop of ours, no Ordlista, no space after.
        let verbatim = secret && !take.thought
        // Rules, then your vocabulary, then (if on) the on-device polish —
        // with the vocabulary once more so your spellings win.
        let cleaned = verbatim ? raw : TextCleanup.apply(raw, fillers: Settings.removeFillers, commands: Settings.voiceCommands)
        var text = selfTest || verbatim ? cleaned : Vocabulary.shared.apply(cleaned)
        if Settings.aiPolish, !secret, let polished = await Polisher.shared.polish(text) {
            let fixed = Vocabulary.shared.reapply(polished)
            // A name from your list split by the polish: the text before it is kept.
            if Vocabulary.shared.keepsWords(of: text, in: fixed) { text = fixed }
        }
        // Let go of meanwhile (Esc, or it took too long): a thought is still written
        // down in Tankar, a dictation is dropped.
        let current = take.job == transcription
        // Only "ny rad" or "nytt stycke", said on its own: the break itself is typed.
        let onlyBreak = !take.thought && !text.isEmpty && text.allSatisfy(\.isNewline)
        guard onlyBreak || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let pending = take.pending { Thoughts.shared.discard(pending) }
            guard current else { return }
            // The thought key held alone and not a word: ⌘ held for something else.
            if take.thought && take.byKey && !take.locked { return reset() }
            return fail(take.heard < 0.03 ? String(localized: "Hörde inget. Kontrollera mikrofonen.")
                                          : String(localized: "Uppfattade inga ord. Försök igen."))
        }
        // A thought: kept in Tankar — nothing typed anywhere.
        if take.thought {
            if !selfTest { Stats.shared.record(text: text, seconds: Double(take.samples.count) / 16_000) }
            if let pending = take.pending { Thoughts.shared.fill(pending, text: text) } else { Thoughts.shared.add(text) }
            guard current else { return }
            Cue.done()
            if take.note == .micWentQuiet { return fail(Self.micWentQuiet) }
            if take.note == .micChanged { return fail(Self.micChanged) }
            return saved()
        }
        if !selfTest && !secret && !onlyBreak && (current || lateJob == take.job) {
            Stats.shared.record(text: text, seconds: Double(take.samples.count) / 16_000)
            var updated = recent
            updated.insert(Entry(text: text, date: Date()), at: 0)
            recent = Array(updated.prefix(Self.recentLimit))
        }
        // Written at last: no need to try again.
        if current || lateJob == take.job { forgetRetry() }
        // Let go of for taking too long, and here after all: on Diktering, one ⌃⌥V away
        // — said only if nothing else has started since.
        if !current, lateJob == take.job {
            lateJob = nil
            guard !selfTest, !secret, !onlyBreak else { return }
            switch phase {
            case .idle, .failed, .copied, .notice: notice(String(localized: "Klar. Klistra in med ⌃⌥V."))
            default: break
            }
            return
        }
        guard current else { return }
        if !selfTest, !onlyBreak { dictatedOnce = true }
        // The screen locked or another user took over meanwhile: typed nowhere. It's
        // on Diktering, one ⌃⌥V away.
        if !selfTest, away { return reset() }
        // You switched app while it was being written: don't type into the
        // wrong one. It's on Diktering, one ⌃⌥V away. A bare line break isn't
        // worth a word.
        if !selfTest, let target = take.target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target {
            if onlyBreak { return reset() }
            return fail(secret ? String(localized: "Du bytte app, så texten skrevs inte in.")
                               : String(localized: "Du bytte app. Klistra in med ⌃⌥V."))
        }
        // Hjälpmedel switched off meanwhile: nothing can be typed. The text goes to the
        // clipboard instead (never a password), and Kom igång asks for Hjälpmedel again.
        if !selfTest, !AXIsProcessTrusted() {
            refreshPermissions()
            if onlyBreak { return reset() }
            if secret { return fail(Self.accessibilityOffNotTyped) }
            return copied(text, because: Self.accessibilityOffCopied)
        }
        if !selfTest, !secret, let target = take.target, FocusedField.kind(in: target) == .none {
            // A line break in the clipboard is no use to anyone.
            if onlyBreak { return reset() }
            return copied(text)
        }
        // A spoken line break at the end is the separator; otherwise a space.
        // Never a password in the clipboard, whatever the setting, nor a bare break.
        TextInserter.insert(verbatim || text.hasSuffix("\n") ? text : text + " ",
                            keeping: Settings.keepInClipboard && !secret && !onlyBreak ? text : nil)
        Cue.done()
        switch take.note {
        case .micWentQuiet: fail(Self.micWentQuiet)
        case .micChanged: fail(Self.micChanged)
        case .timeUp: fail(String(localized: "Stannade efter tio minuter. Texten är inskriven."))
        case nil: reset()
        }
    }

    private static var accessibilityOffCopied: String {
        String(localized: "Hjälpmedel är avstängt för Mindtalk. Texten är kopierad, klistra in med ⌘V.")
    }
    private static var accessibilityOffNotTyped: String {
        String(localized: "Hjälpmedel är avstängt för Mindtalk, så texten skrevs inte in.")
    }
    private static var micWentQuiet: String { String(localized: "Mikrofonen tystnade. Det du hann säga är kvar.") }
    private static var micChanged: String { String(localized: "Mikrofonen byttes, så dikteringen stannade. Det du hann säga är kvar.") }
    static var couldNotWrite: String { String(localized: "Det gick inte att göra text av det. Försök igen.") }
    /// Said when the sound is kept: a click on the HUD tries again.
    static var clickToRetry: String { String(localized: "Det gick inte att göra text av det. Klicka för att försöka igen.") }

    /// A dictation that couldn't be written: its sound is kept for "Försök igen" —
    /// not a thought's (Tankar keeps those) and never a password field's.
    private func keepForRetry(_ take: Take) {
        guard !take.thought, !take.secret, !TextInserter.dryRun else { return }
        failedTake = take
        canRetry = true
    }

    private func forgetRetry() {
        failedTake = nil
        canRetry = false
    }

    /// "Försök igen" on the HUD: the last dictation that couldn't be written, once
    /// more, typed where you are now.
    func retryLast() {
        guard var take = failedTake else { return }
        switch phase {
        case .idle, .failed, .copied, .saved, .notice: break
        default: return
        }
        guard model == .ready else { return beep() }
        forgetRetry()
        reset()
        phase = .transcribing
        transcription += 1
        take.job = transcription
        take.target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        take.secret = SecureInput.isActive
        take.note = nil
        transcribe(take)
    }
    private static var thoughtWithoutText: String { String(localized: "Tanken kunde inte skrivas ned. Försök igen i Tankar.") }

    /// Esc while writing, or writing that never ends: the HUD and the key are free
    /// again. A thought gets its text if it comes, or "Försök igen" in Tankar.
    private func abandonTranscription(saying message: String?) {
        guard phase == .transcribing else { return }
        transcription += 1
        if message != nil, let pending = writingThought {
            Thoughts.shared.failWriting(pending)
            fail(Self.thoughtWithoutText)
        } else if let message {
            fail(canRetry ? Self.clickToRetry : message, for: canRetry ? 8 : nil)
        } else {
            reset()
        }
        resumeHeldPress()
    }

    /// The key went down while the last one was being written and is still held:
    /// the next recording starts now, counted from that press.
    private func resumeHeldPress() {
        writingThought = nil
        let since = heldSince
        heldSince = nil
        if pressWhileWriting {
            pressWhileWriting = false
            guard keyIsDown, KeyListener.shared.keyPhysicallyDown else { return }
            keyPressed()
        } else if thoughtPressWhileWriting {
            thoughtPressWhileWriting = false
            guard keyIsDown else { return }
            thoughtPressed()
        } else {
            return
        }
        if phase == .recording, let since { pressedAt = since }
    }

    /// Sleep, the screen locking, another user taking over: a hands-free recording is
    /// finished (kept, but typed nowhere), a held one or a very short one cancelled.
    private func leaving(locking: Bool = false) {
        away = true
        if phase == .recording {
            let lasted = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
            if handsFree, lasted >= 1 { finish() } else { cancel() }
        }
        if locking { KeyListener.shared.reset() }
    }

    /// Back at the Mac (awake and unlocked, or the session yours again).
    private func back() {
        away = Self.screenLocked
        KeyListener.shared.ensureTap()
        KeyListener.shared.resync()
    }

    /// The lock screen is up.
    static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func cancel() {
        stopMic()
        ignoreNextRelease = false
        reset()
    }

    private func reset() {
        MediaControl.shared.end()
        watchdog?.invalidate(); watchdog = nil
        recordingEngine = nil
        phase = .idle
        if engineSwitchPending {
            engineSwitchPending = false
            if engine.isInstalled { loadModel() } else { refreshModels() }
        }
        handsFree = false
        forThought = false
        thoughtByKey = false
        thoughtStopPending = false
        startCuePlayed = false
        awaitingSecondTap = false
        secondTapDown = false
        doubleTapTimer?.cancel()
        closingNote = nil
        micWaiting = false
        headsetInUse = false
        pressedAt = nil
        recordingStarted = nil
        level = 0
        meter.levels = [Float](repeating: 0, count: Self.levelCount)
        hud.hide()
    }

    /// Which message is up — a newer one isn't taken down by an older one's timer.
    private var messageShown = 0

    /// Shown until `seconds` have passed, unless something else has come since.
    private func showUntilReset(after seconds: Double, while still: @escaping (Phase) -> Bool) {
        hud.show()
        messageShown += 1
        let shown = messageShown
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, shown == self.messageShown, still(self.phase) else { return }
            self.reset()
        }
    }

    private func fail(_ message: String, for seconds: Double? = nil) {
        phase = .failed(message)
        // Two lines take longer to read.
        showUntilReset(after: seconds ?? (message.count > 34 ? 4.5 : 3)) { if case .failed = $0 { return true }; return false }
    }

    /// Not a problem, just worth knowing: said for a moment.
    private func notice(_ message: String) {
        phase = .notice(message)
        showUntilReset(after: 3.5) { if case .notice = $0 { return true }; return false }
    }

    /// A thought kept: the bubble says where it went, for a moment.
    private func saved() {
        phase = .saved
        showUntilReset(after: 2) { $0 == .saved }
    }

    /// No text field where you are (the desktop, a web page): the text goes to the
    /// clipboard, and the HUD says so.
    /// With `why`, it's said why instead (Hjälpmedel switched off).
    private func copied(_ text: String, because why: String? = nil) {
        TextInserter.copy(text)
        Cue.done()
        if let why { return fail(why) }
        phase = .copied
        showUntilReset(after: 3.5) { $0 == .copied }
    }

    /// ⌃⌥V: the last dictation, typed again where the cursor is now — for when
    /// it landed in the wrong place. Waits for ⌃ and ⌥ to be let go, so the
    /// paste isn't read as ⌃⌥⌘V.
    func pasteLast() {
        switch phase {
        case .recording where handsFree || forThought:
            // Never in the middle of one, it would be lost: a beep (not into a headset).
            return beep()
        case .transcribing:
            return beep()
        case .recording:
            cancel()               // the key held as part of ⌃⌥V: not a dictation
        case .failed, .copied, .saved, .notice:
            reset()
        case .idle:
            break
        }
        guard let last = recent.first else { return fail(String(localized: "Inget att klistra in än.")) }
        Task { @MainActor in
            for _ in 0..<40 {
                let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate])
                if held.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            if !AXIsProcessTrusted() {
                refreshPermissions()
                return copied(last.text, because: Self.accessibilityOffCopied)
            }
            if let app = NSWorkspace.shared.frontmostApplication, FocusedField.kind(in: app.processIdentifier) == .none {
                return copied(last.text)
            }
            TextInserter.insert(last.text.hasSuffix("\n") ? last.text : last.text + " ", keeping: Settings.keepInClipboard ? last.text : nil)
        }
    }

    func copy(_ entry: Entry) {
        TextInserter.copy(entry.text)
    }

    func clearRecent() { recent = [] }

    func removeRecent(_ entry: Entry) { recent.removeAll { $0.id == entry.id } }

    /// "Ångra": back where it was.
    func restoreRecent(_ entry: Entry, at index: Int) {
        guard !recent.contains(where: { $0.id == entry.id }) else { return }
        var updated = recent
        updated.insert(entry, at: min(index, updated.count))
        recent = Array(updated.prefix(Self.recentLimit))
    }
}

/// The mic levels of the dictation going on, apart from everything else it publishes.
@MainActor
final class LevelMeter: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: Dictation.levelCount)
}

/// Reads the mic levels in a view of its own, so only it redraws with every level.
struct MeterReader<Content: View>: View {
    @ObservedObject var meter: LevelMeter
    @ViewBuilder let content: ([Float]) -> Content
    var body: some View { content(meter.levels) }
}
