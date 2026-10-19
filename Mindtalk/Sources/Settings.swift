import AppKit

enum Settings {
    private static let defaults = UserDefaults.standard

    static var hotkey: Hotkey {
        get {
            guard let data = defaults.data(forKey: "hotkey"),
                  let key = try? JSONDecoder().decode(Hotkey.self, from: data) else { return .default }
            return key
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkey") }
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
            defaults.set(newValue == nil, forKey: "meetingShortcutOff")
            if let newValue { defaults.set(try? JSONEncoder().encode(newValue), forKey: "meetingShortcut") }
        }
    }

    /// Say a thought (Tankar): held, it listens until you let go; tapped, until you
    /// tap again. Left ⌥ held on its own by default; a chord you chose (⌃⌥T was the
    /// default before) is kept.
    static var thoughtShortcut: ThoughtShortcut? {
        get { thoughtShortcut(in: defaults, besides: hotkey) }
        set { setThoughtShortcut(newValue, in: defaults) }
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
        set { defaults.set(newValue.rawValue, forKey: "engine") }
    }

    /// The language you dictate in, never chosen: the suggestion written down at the
    /// first launch. The suggestion follows the app's language, so changing Appens
    /// språk later would otherwise change the speech model too.
    static func settleEngine() {
        if defaults.string(forKey: "engine") == nil { engine = SpeechModel.recommended }
    }

    /// Set once the first-run window has been completed.
    static var didOnboard: Bool {
        get { defaults.bool(forKey: "didOnboard") }
        set { defaults.set(newValue, forKey: "didOnboard") }
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
            return String(localized: "Håll in \(key) för korta meddelanden. Dubbeltryck för att låsa och prata fritt.")
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
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mode") }
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
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance") }
    }

    /// Keep the Dock icon even when the window is closed.
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock") }
    }

    /// Drop hesitation sounds (eh, öh, um).
    /// You said yes to the word list's listener (100 MB).
    static var listenerAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: "listenerAllowed") }
        set { UserDefaults.standard.set(newValue, forKey: "listenerAllowed") }
    }

    static var removeFillers: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillers") }
    }

    /// "Ny rad" and "nytt stycke" become line breaks.
    static var voiceCommands: Bool {
        get { UserDefaults.standard.object(forKey: "voiceCommands") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceCommands") }
    }

    /// Polish with Apple's on-device model. Off until you turn it on: it adds
    /// a moment, and it needs Apple Intelligence.
    static var aiPolish: Bool {
        get { UserDefaults.standard.bool(forKey: "aiPolish") }
        set { UserDefaults.standard.set(newValue, forKey: "aiPolish") }
    }

    /// Leave the dictation in the clipboard after pasting it, instead of putting
    /// back what was there.
    static var keepInClipboard: Bool {
        get { UserDefaults.standard.bool(forKey: "keepInClipboard") }
        set { UserDefaults.standard.set(newValue, forKey: "keepInClipboard") }
    }

    /// What happens to music and other sound while you dictate.
    static var mediaMode: MediaMode {
        get { UserDefaults.standard.string(forKey: "mediaMode").flatMap(MediaMode.init) ?? .pause }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mediaMode") }
    }

    /// A soft sound when dictation starts and when the text is pasted.
    static var sounds: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
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
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
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
