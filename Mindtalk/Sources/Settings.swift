import AppKit
import os

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Drawing a picture (`--render-…`), running a self-test (`--…-test`, `--notes`) or
    /// showing made-up data (`--demo`): nothing such a run chooses is kept. The settings that
    /// matter most are written through `keep`, which skips the disk then; and whatever
    /// else gets written is put back as it was when the run ends (PreviewDefaults). So
    /// a render never changes who writes the summaries on this Mac.
    nonisolated static let previewing: Bool = CommandLine.arguments.contains {
        $0.hasPrefix("--render-") || ($0.hasPrefix("--") && $0.hasSuffix("-test")) || $0 == "--demo" || $0 == "--notes"
    }

    /// A setting written: to the disk, unless previewing (then it's left as it is).
    nonisolated static func keep(_ value: Any?, forKey key: String) {
        guard !previewing else { return }
        // To the defaults themselves: never back through keep (that loops forever).
        defaults.set(value, forKey: key)
    }

    /// Your own name among the voices ("Det här är jag" in Settings → Möten): your
    /// tasks in a meeting's notes read "Du". nil: not chosen.
    static var myName: String? {
        get { defaults.string(forKey: "myName").flatMap { $0.isEmpty ? nil : $0 } }
        set { keep(newValue?.isEmpty == false ? newValue : nil, forKey: "myName") }
    }

    static var hotkey: Hotkey {
        get {
            guard let data = defaults.data(forKey: "hotkey"),
                  let key = try? JSONDecoder().decode(Hotkey.self, from: data) else { return .default }
            return key
        }
        set { keep(try? JSONEncoder().encode(newValue), forKey: "hotkey") }
    }

    /// The meeting shortcut, in every app. nil: turned off.
    static var meetingShortcut: KeyChord? {
        get {
            if defaults.bool(forKey: "meetingShortcutOff") { return nil }
            guard let data = defaults.data(forKey: "meetingShortcut"),
                  let chord = try? JSONDecoder().decode(KeyChord.self, from: data), chord.isValid else { return .meetingDefault }
            return chord
        }
        set {
            keep(newValue == nil, forKey: "meetingShortcutOff")
            if let newValue { keep(try? JSONEncoder().encode(newValue), forKey: "meetingShortcut") }
        }
    }

    /// Say a thought (Tankar): held, it listens until you let go; tapped, until you
    /// tap again. Left ⌥ held on its own by default; a chord you chose (⌃⌥T was the
    /// default before) is kept.
    static var thoughtShortcut: ThoughtShortcut? {
        get { thoughtShortcut(in: defaults, besides: hotkey) }
        set { if !previewing { setThoughtShortcut(newValue, in: defaults) } }
    }

    /// A key held alone is under "thoughtKey", a chord under "thoughtShortcut" (where
    /// it always was). Neither saved: the default, left ⌥ (right ⌘ or ⌃⌥T if dictation has it).
    static func thoughtShortcut(in defaults: UserDefaults, besides dictation: Hotkey) -> ThoughtShortcut? {
        if defaults.bool(forKey: "thoughtShortcutOff") { return nil }
        if let data = defaults.data(forKey: "thoughtKey"),
           let key = try? JSONDecoder().decode(Hotkey.self, from: data), key.modifierKeys.count == 1 {
            return .key(key)
        }
        if let data = defaults.data(forKey: "thoughtShortcut"),
           let chord = try? JSONDecoder().decode(KeyChord.self, from: data), chord.isValid {
            return .chord(chord)
        }
        return .standard(besides: dictation)
    }

    static func setThoughtShortcut(_ shortcut: ThoughtShortcut?, in defaults: UserDefaults) {
        defaults.set(shortcut == nil, forKey: "thoughtShortcutOff")
        switch shortcut {
        case .key(let key)?:
            defaults.set(try? JSONEncoder().encode(key), forKey: "thoughtKey")
            defaults.removeObject(forKey: "thoughtShortcut")
        case .chord(let chord)?:
            defaults.set(try? JSONEncoder().encode(chord), forKey: "thoughtShortcut")
            defaults.removeObject(forKey: "thoughtKey")
        case nil:
            break
        }
    }

    /// The language you dictate in. Swedish by default on a Swedish Mac.
    static var engine: SpeechModel {
        get {
            if let raw = defaults.string(forKey: "engine"), let m = SpeechModel(rawValue: raw) { return m }
            return SpeechModel.recommended
        }
        set { keep(newValue.rawValue, forKey: "engine") }
    }

    /// The language you dictate in, never chosen: the suggestion written down at the
    /// first launch. The suggestion follows the app's language, so changing Appens
    /// språk later would otherwise change the speech model too.
    static func settleEngine() {
        if !previewing, defaults.string(forKey: "engine") == nil { engine = SpeechModel.recommended }
    }

    /// Set once the first-run window has been completed.
    static var didOnboard: Bool {
        get { defaults.bool(forKey: "didOnboard") }
        set { keep(newValue, forKey: "didOnboard") }
    }
}

/// How the dictation key starts and stops a dictation.
enum DictationMode: String, CaseIterable, Identifiable {
    /// Hold to talk; double-tap to lock (like Wispr Flow).
    case holdOrDoubleTap
    /// Only while the key is held.
    case hold
    /// One press starts, the next one stops.
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdOrDoubleTap: return String(localized: "Håll in eller dubbeltryck")
        case .hold: return String(localized: "Bara håll in")
        case .toggle: return String(localized: "Tryck för att starta och stoppa")
        }
    }

    func explanation(key: String) -> String {
        switch self {
        // The key named, so the choice reads with the key you use (now also in Genvägar).
        case .holdOrDoubleTap:
            return String(localized: "Håll in \(key) medan du pratar. Dubbeltryck så slipper du hålla in.")
        case .hold:
            return String(localized: "Mindtalk lyssnar så länge du håller in \(key).")
        case .toggle:
            return String(localized: "Tryck på \(key) för att börja och tryck igen när du är klar.")
        }
    }
}

extension Settings {
    static var mode: DictationMode {
        get { UserDefaults.standard.string(forKey: "mode").flatMap(DictationMode.init) ?? .holdOrDoubleTap }
        set { Settings.keep(newValue.rawValue, forKey: "mode") }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return String(localized: "Ljust")
        case .dark: return String(localized: "Mörkt")
        case .system: return String(localized: "Automatiskt")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

extension Settings {
    /// Light by default — the warm paper look.
    static var appearance: Appearance {
        get { UserDefaults.standard.string(forKey: "appearance").flatMap(Appearance.init) ?? .light }
        set { Settings.keep(newValue.rawValue, forKey: "appearance") }
    }

    /// Keep the Dock icon even when the window is closed. On until you choose otherwise:
    /// a new user who closes the window would otherwise think Mindtalk quit.
    static var showInDock: Bool {
        get { (UserDefaults.standard.object(forKey: "showInDock") as? Bool) ?? true }
        set { Settings.keep(newValue, forKey: "showInDock") }
    }

    /// Drop hesitation sounds (eh, öh, um).
    /// You said yes to the word list's listener (100 MB).
    static var listenerAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: "listenerAllowed") }
        set { Settings.keep(newValue, forKey: "listenerAllowed") }
    }

    static var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { Settings.keep(newValue, forKey: "removeFillers") }
    }

    /// "Ny rad" and "nytt stycke" become line breaks.
    static var voiceCommands: Bool {
        get { UserDefaults.standard.object(forKey: "voiceCommands") as? Bool ?? true }
        set { Settings.keep(newValue, forKey: "voiceCommands") }
    }

    /// Polish with Apple's on-device model. Off until you turn it on: it adds
    /// a moment, and it needs Apple Intelligence.
    static var aiPolish: Bool {
        get { UserDefaults.standard.bool(forKey: "aiPolish") }
        set { Settings.keep(newValue, forKey: "aiPolish") }
    }

    /// Leave the dictation in the clipboard after pasting it, instead of putting
    /// back what was there.
    static var keepInClipboard: Bool {
        get { UserDefaults.standard.bool(forKey: "keepInClipboard") }
        set { Settings.keep(newValue, forKey: "keepInClipboard") }
    }

    /// What happens to music and other sound while you dictate.
    static var mediaMode: MediaMode {
        get { UserDefaults.standard.string(forKey: "mediaMode").flatMap(MediaMode.init) ?? .pause }
        set { Settings.keep(newValue.rawValue, forKey: "mediaMode") }
    }

    /// When a meeting takes the Mac's own sound too (a call in Teams, Zoom, Meet):
    /// with headphones unless chosen otherwise.
    static var callAudio: CallAudioMode {
        get { UserDefaults.standard.string(forKey: "callAudio").flatMap(CallAudioMode.init) ?? .headphones }
        set { Settings.keep(newValue.rawValue, forKey: "callAudio") }
    }

    /// A call app starting to use the microphone: asked whether to take notes. On
    /// unless turned off; apps answered "Fråga inte" are left out.
    static var askOnCalls: Bool {
        get { UserDefaults.standard.object(forKey: "askOnCalls") as? Bool ?? true }
        set { Settings.keep(newValue, forKey: "askOnCalls") }
    }
    static var callAppsMuted: [String] {
        get { UserDefaults.standard.stringArray(forKey: "callAppsMuted") ?? [] }
        set { Settings.keep(newValue, forKey: "callAppsMuted") }
    }

    /// During a meeting, the panel comes over your work when you turn to another app,
    /// and goes again when you come back. On unless turned off.
    static var panelWhenAway: Bool {
        get { UserDefaults.standard.object(forKey: "meetingPanelWhenAway") as? Bool ?? true }
        set { Settings.keep(newValue, forKey: "meetingPanelWhenAway") }
    }

    /// A soft sound when dictation starts and when the text is pasted.
    static var sounds: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { Settings.keep(newValue, forKey: "sounds") }
    }
}

/// The settings the window edits, published so the UI follows along.
@MainActor
final class AppPrefs: ObservableObject {
    static let shared = AppPrefs()

    @Published var appearance = Settings.appearance {
        didSet { Settings.appearance = appearance; apply() }
    }
    @Published var showInDock = Settings.showInDock {
        didSet { Settings.showInDock = showInDock; AppDelegate.updateDockPolicy() }
    }
    @Published var sounds = Settings.sounds {
        didSet { Settings.sounds = sounds }
    }
    @Published var mediaMode = Settings.mediaMode {
        didSet { Settings.mediaMode = mediaMode }
    }
    @Published var removeFillers = Settings.removeFillers {
        didSet { Settings.removeFillers = removeFillers; MeetingText.forget() }
    }
    @Published var voiceCommands = Settings.voiceCommands {
        didSet { Settings.voiceCommands = voiceCommands }
    }
    @Published var keepInClipboard = Settings.keepInClipboard {
        didSet { Settings.keepInClipboard = keepInClipboard }
    }
    @Published var panelWhenAway = Settings.panelWhenAway {
        didSet { Settings.panelWhenAway = panelWhenAway }
    }
    @Published var callAudio = Settings.callAudio {
        didSet { Settings.callAudio = callAudio }
    }
    @Published var askOnCalls = Settings.askOnCalls {
        didSet { Settings.askOnCalls = askOnCalls }
    }
    @Published var callAppsMuted = Settings.callAppsMuted {
        didSet { Settings.callAppsMuted = callAppsMuted }
    }
    @Published var aiPolish = Settings.aiPolish {
        didSet {
            Settings.aiPolish = aiPolish
            if aiPolish { Task { await Polisher.shared.prepare() } }
        }
    }

    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }
}

/// Soft start/done cues.
enum Cue {
    @MainActor static func start() { play("Tink") }
    @MainActor static func done() { play("Pop") }
    /// The first dictation during onboarding.
    @MainActor static func celebrate() { play("Glass") }

    @MainActor private static func play(_ name: String) {
        guard Settings.sounds, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}

/// The app's own language. "System" follows the Mac (English for anything but
/// Swedish); a choice here is stored as the app's AppleLanguages, the same
/// setting as System Settings → Language & Region → Applications, and takes
/// effect on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case swedish = "sv"
    case english = "en"

    var id: String { rawValue }

    /// Each language in its own words, so you can always find yours.
    var title: String {
        switch self {
        case .system: return String(localized: "Samma som Macen")
        case .swedish: return "Svenska"
        case .english: return "English"
        }
    }

    static var chosen: AppLanguage {
        get {
            let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            guard let first = (domain["AppleLanguages"] as? [String])?.first else { return .system }
            return first.hasPrefix("sv") ? .swedish : first.hasPrefix("en") ? .english : .system
        }
        set {
            if newValue == .system {
                if Settings.previewing { return }
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                Settings.keep([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// What a choice means on this Mac ("System" resolves to Swedish or English).
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        // The first of the Mac's languages that Mindtalk speaks; English otherwise.
        for code in global {
            if code.hasPrefix("sv") { return .swedish }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// The language the app is running in right now.
    static let running: AppLanguage = Bundle.main.preferredLocalizations.first?.hasPrefix("sv") == true ? .swedish : .english

    /// For dates and weekday names in the running language.
    static var locale: Locale { Locale(identifier: running == .swedish ? "sv_SE" : "en_US") }
}


// MARK: - Nothing kept from a render or a self-test

/// `Mindtalk --render-… / --…-test / --demo`: the app's settings as they were before the
/// run, and the same again when it ends. Armed first thing at launch; whatever such a
/// run wrote (a setting read back from the arguments, a shortcut a test tried) is put
/// back at exit, so the owner's settings are byte for byte what they were. (A fresh
/// HOME doesn't move UserDefaults: cfprefsd keeps them by user, not by HOME.)
enum PreviewDefaults {
    nonisolated(unsafe) private static var snapshot: [String: Any]?
    nonisolated(unsafe) private static var armed = false
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "PreviewDefaults")
    nonisolated static var domain: String { Bundle.main.bundleIdentifier ?? "ai.mindact.mindtalk" }

    /// At launch, before anything reads or writes a setting: a copy of them all, and the
    /// promise to put it back at exit. Does nothing unless previewing.
    nonisolated static func arm() {
        guard Settings.previewing, !armed else { return }
        armed = true
        snapshot = UserDefaults.standard.persistentDomain(forName: domain)
        atexit { _ = PreviewDefaults.restore() }
    }

    /// The settings as they were at launch, back on the disk. Called at exit by itself
    /// (and once more, harmlessly, by whoever finishes a render). True when nothing
    /// had changed.
    @discardableResult nonisolated static func restore() -> Bool {
        guard armed else { return true }
        let changed = !restore(UserDefaults.standard, domain: domain, to: snapshot)
        if changed { log.notice("settings put back as they were before the run") }
        return !changed
    }

    /// Nothing has been written to the settings since launch.
    nonisolated static func unchanged() -> Bool {
        same(UserDefaults.standard.persistentDomain(forName: domain), snapshot)
    }

    /// `domain` in `defaults` set to `snapshot` (removed, when that is nil), unless it
    /// already is. True when nothing had to be done.
    nonisolated private static func restore(_ defaults: UserDefaults, domain: String, to snapshot: [String: Any]?) -> Bool {
        let now = defaults.persistentDomain(forName: domain)
        guard !same(now, snapshot) else { return true }
        if let snapshot { defaults.setPersistentDomain(snapshot, forName: domain) } else { defaults.removePersistentDomain(forName: domain) }
        defaults.synchronize()
        return false
    }

    /// Byte for byte the same settings. (A domain removed reads back as an empty
    /// dictionary, not as nothing: the two count as the same.)
    nonisolated private static func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        switch (a?.isEmpty == true ? nil : a, b?.isEmpty == true ? nil : b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as NSDictionary).isEqual(to: b)
        default: return false
        }
    }

    #if DEBUG
    /// `Mindtalk --defaults-test`: the writers that matter skip the disk while
    /// previewing, and a domain put back from its copy is the copy, byte for byte.
    /// The app's own settings are read and compared only; what's written goes to a
    /// scratch domain.
    @MainActor static func selfTest() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FEL  \(what)") } }
        check(Settings.previewing, "--defaults-test räknas inte som en provkörning")
        check(armed, "ingen kopia av inställningarna togs vid starten")
        check(unchanged(), "inställningarna är inte som vid starten redan innan något skrivits")
        let before = UserDefaults.standard.persistentDomain(forName: domain)

        // The central writers, while previewing: nothing reaches the disk.
        let choice = BetterNotes.shared.choice
        BetterNotes.shared.choice = choice == .gemma(.small) ? .gemma(.large) : .gemma(.small)
        check(BetterNotes.shared.choice != choice, "valet av skribent ändrades inte i minnet")
        BetterNotes.shared.choice = choice
        Settings.appearance = Settings.appearance == .dark ? .light : .dark
        Settings.didOnboard = !Settings.didOnboard
        Settings.hotkey = .default
        Settings.meetingShortcut = nil
        Settings.thoughtShortcut = nil
        SummaryLanguage.chosen = .english
        MeetingSession.startMode = .direct
        Settings.keep("x", forKey: "defaultsTest.scratch")
        check(unchanged(), "en skrivning nådde disken under provkörningen")
        check(same(before, UserDefaults.standard.persistentDomain(forName: domain)), "inställningarna på disken är inte desamma som före")

        // A domain written to, then put back from its copy: the copy, byte for byte.
        let scratch = "ai.mindact.mindtalk.defaults-self-test"
        guard let defaults = UserDefaults(suiteName: scratch) else { print("FEL  ingen provdomän"); return 1 }
        defaults.removePersistentDomain(forName: scratch)
        defer { defaults.removePersistentDomain(forName: scratch) }
        defaults.set("apple", forKey: "summaryWriter")
        defaults.set(["a": 1, "b": [1, 2]], forKey: "nested")
        defaults.set(Data([1, 2, 3]), forKey: "bytes")
        let copy = defaults.persistentDomain(forName: scratch)
        check(copy?.count == 3, "provdomänen har inte tre nycklar: \(copy?.count ?? -1)")
        defaults.set("gemma:e4b", forKey: "summaryWriter")
        defaults.set(true, forKey: "added")
        defaults.removeObject(forKey: "bytes")
        check(!same(defaults.persistentDomain(forName: scratch), copy), "ändringar i provdomänen märktes inte")
        check(!restore(defaults, domain: scratch, to: copy), "återställningen sa att inget ändrats")
        check(same(defaults.persistentDomain(forName: scratch), copy), "provdomänen är inte som kopian efter återställningen")
        check(defaults.string(forKey: "summaryWriter") == "apple", "summaryWriter är inte apple igen")
        check(defaults.object(forKey: "added") == nil, "en tillagd nyckel är kvar")
        check(defaults.data(forKey: "bytes") == Data([1, 2, 3]), "en borttagen nyckel kom inte tillbaka")
        check(restore(defaults, domain: scratch, to: copy), "en andra återställning sa att något ändrats")
        // "Kom ihåg rösterna": off when never chosen, and asked before the first meeting;
        // a stored choice is kept as it is, and an answer is never asked again.
        defaults.removeObject(forKey: "voiceMemory")
        defaults.removeObject(forKey: "voiceMemoryAsked")
        check(!VoiceMemory.initialEnabled(in: defaults), "Kom ihåg rösterna är inte av när inget är valt")
        check(defaults.object(forKey: "voiceMemory") == nil, "Kom ihåg rösterna skrevs ned utan att ha valts")
        check(MeetingSession.asksAboutVoices(in: defaults), "frågan om rösterna ställs inte när inget är valt")
        defaults.set(true, forKey: "voiceMemory")
        check(VoiceMemory.initialEnabled(in: defaults), "ett sparat ja till rösterna lästes inte som på")
        check(!MeetingSession.asksAboutVoices(in: defaults), "frågan om rösterna ställs trots ett sparat val")
        defaults.set(false, forKey: "voiceMemory")
        check(!VoiceMemory.initialEnabled(in: defaults), "ett sparat nej till rösterna lästes inte som av")
        defaults.removeObject(forKey: "voiceMemory")
        defaults.set(true, forKey: "voiceMemoryAsked")
        check(!MeetingSession.asksAboutVoices(in: defaults), "frågan om rösterna ställs igen efter ett svar")
        check(!restore(defaults, domain: scratch, to: copy), "återställningen efter rösterna sa att inget ändrats")
        // A copy that was nothing (first launch): the domain is removed again.
        check(!restore(defaults, domain: scratch, to: nil), "tom kopia: återställningen sa att inget ändrats")
        check(defaults.persistentDomain(forName: scratch)?.isEmpty != false, "tom kopia: domänen togs inte bort")

        check(unchanged(), "appens inställningar ändrades av provet")
        print(failed == 0 ? "Defaults self-test passed (previewing, central writers, restore)." : "\(failed) fel")
        return failed == 0 ? 0 : 1
    }
    #endif
}
