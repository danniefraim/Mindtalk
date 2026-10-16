import AppKit
import Carbon.HIToolbox
import os

// MARK: - The dictation key
//
// A single key or a combination of modifiers can be the dictation shortcut.
// Modifiers (⌥ ⌘ ⌃ ⇧ fn) pass through untouched; a regular key (F5, §,…) is swallowed
// so it doesn't also type into the app — except with ⌘/⌃/⌥ held, so shortcuts
// that use it keep working.

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    /// Required device-specific modifier bits (tells right ⌥ from left ⌥); 0 for regular keys.
    /// Keeping the original fields also preserves saved single-key shortcuts.
    var modifierMask: UInt64
    var isModifier: Bool { modifierMask != 0 }

    static let `default` = Hotkey(keyCode: UInt16(kVK_RightOption), modifierMask: 0x40)

    /// Modifier key codes → their device-specific bit in the event flags.
    static let modifierMasks: [UInt16: UInt64] = [
        UInt16(kVK_RightOption): 0x40,       // NX_DEVICERALTKEYMASK
        UInt16(kVK_Option): 0x20,            // NX_DEVICELALTKEYMASK
        UInt16(kVK_RightCommand): 0x10,      // NX_DEVICERCMDKEYMASK
        UInt16(kVK_Command): 0x08,           // NX_DEVICELCMDKEYMASK
        UInt16(kVK_RightControl): 0x2000,    // NX_DEVICERCTLKEYMASK
        UInt16(kVK_Control): 0x01,           // NX_DEVICELCTLKEYMASK
        UInt16(kVK_RightShift): 0x04,        // NX_DEVICERSHIFTKEYMASK
        UInt16(kVK_Shift): 0x02,             // NX_DEVICELSHIFTKEYMASK
        UInt16(kVK_Function): CGEventFlags.maskSecondaryFn.rawValue,
    ]

    private static let modifierOrder = [
        kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption,
        kVK_Shift, kVK_RightShift, kVK_Command, kVK_RightCommand, kVK_Function,
    ].map { UInt16($0) }

    static let allModifierMasks = modifierMasks.values.reduce(UInt64(0), |)

    var modifierKeys: [Hotkey] {
        Self.modifierOrder.compactMap { code in
            guard let mask = Self.modifierMasks[code], modifierMask & mask != 0 else { return nil }
            return Hotkey(keyCode: code, modifierMask: mask)
        }
    }

    static func modifierCombination(mask: UInt64) -> Hotkey? {
        let mask = mask & allModifierMasks
        guard let code = modifierOrder.first(where: { mask & modifierMasks[$0]! != 0 }) else { return nil }
        return Hotkey(keyCode: code, modifierMask: mask)
    }

    func containsModifier(_ code: UInt16) -> Bool {
        guard let mask = Self.modifierMasks[code] else { return false }
        return modifierMask & mask != 0
    }

    func modifiersAreDown(in flags: CGEventFlags) -> Bool {
        isModifier && flags.rawValue & modifierMask == modifierMask
    }

    /// Some hardware sources omit sided bits. Fall back only if neither side of
    /// that modifier family is reported, so left ⌘ cannot satisfy right ⌘.
    func modifiersPhysicallyDown(in flags: CGEventFlags) -> Bool {
        let keys = modifierKeys
        guard isModifier, !keys.isEmpty else { return false }
        return keys.allSatisfy { key in
            if flags.rawValue & key.modifierMask != 0 { return true }
            let family: CGEventFlags
            let sides: UInt64
            switch Int(key.keyCode) {
            case kVK_Option, kVK_RightOption: family = .maskAlternate; sides = 0x60
            case kVK_Command, kVK_RightCommand: family = .maskCommand; sides = 0x18
            case kVK_Control, kVK_RightControl: family = .maskControl; sides = 0x2001
            case kVK_Shift, kVK_RightShift: family = .maskShift; sides = 0x06
            default: return false // fn has no separate sided bits.
            }
            return flags.contains(family) && flags.rawValue & sides == 0
        }
    }

    var name: String {
        if modifierKeys.count > 1 { return modifierKeys.map(\.name).joined(separator: " + ") }
        switch Int(keyCode) {
        case kVK_RightOption: return String(localized: "Höger ⌥ Option")
        case kVK_Option: return String(localized: "Vänster ⌥ Option")
        case kVK_RightCommand: return String(localized: "Höger ⌘ Command")
        case kVK_Command: return String(localized: "Vänster ⌘ Command")
        case kVK_RightControl: return String(localized: "Höger ⌃ Control")
        case kVK_Control: return String(localized: "Vänster ⌃ Control")
        case kVK_RightShift: return String(localized: "Höger ⇧ Shift")
        case kVK_Shift: return String(localized: "Vänster ⇧ Shift")
        case kVK_Function: return "fn / 🌐"
        case kVK_Space: return String(localized: "Mellanslag")
        case kVK_Return: return String(localized: "Retur")
        case kVK_Tab: return String(localized: "Tabb")
        case kVK_Delete: return String(localized: "Backsteg")
        case kVK_ForwardDelete: return "Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return String(localized: "←")
        case kVK_RightArrow: return String(localized: "→")
        case kVK_UpArrow: return String(localized: "↑")
        case kVK_DownArrow: return String(localized: "↓")
        case kVK_CapsLock: return "Caps Lock"
        default: break
        }
        if let f = Self.functionKeys[Int(keyCode)] { return "F\(f)" }
        return Self.character(for: keyCode).map { $0.uppercased() } ?? String(localized: "Tangent \(Int(keyCode))")
    }

    /// Short form for a key chip: "⌥ Opt →" (arrow = which side).
    var chip: String {
        if modifierKeys.count > 1 { return modifierKeys.map(\.chip).joined(separator: " + ") }
        switch Int(keyCode) {
        case kVK_RightOption: return "⌥ Opt →"
        case kVK_Option: return "⌥ Opt ←"
        case kVK_RightCommand: return "⌘ Cmd →"
        case kVK_Command: return "⌘ Cmd ←"
        case kVK_RightControl: return "⌃ Ctrl →"
        case kVK_Control: return "⌃ Ctrl ←"
        case kVK_RightShift: return "⇧ Shift →"
        case kVK_Shift: return "⇧ Shift ←"
        case kVK_Function: return "fn"
        default: return name
        }
    }

    /// For use mid-sentence ("Håll in höger ⌥ Option…").
    var inlineName: String {
        if modifierKeys.count > 1 { return modifierKeys.map(\.inlineName).joined(separator: " + ") }
        // Modifier names and Space are ordinary words mid-sentence: "höger ⌥ Option", "right ⌥ Option".
        let n = name
        return (isModifier && Int(keyCode) != kVK_Function) || Int(keyCode) == kVK_Space
            ? n.prefix(1).lowercased() + n.dropFirst() : n
    }

    /// A modifier key's symbol, what's printed under it, and its side.
    private var printed: (symbol: String, word: String, right: Bool)? {
        switch Int(keyCode) {
        case kVK_RightCommand: return ("⌘", "command", true)
        case kVK_Command: return ("⌘", "command", false)
        case kVK_RightOption: return ("⌥", "option", true)
        case kVK_Option: return ("⌥", "option", false)
        case kVK_RightControl: return ("⌃", "control", true)
        case kVK_Control: return ("⌃", "control", false)
        case kVK_RightShift: return ("⇧", "shift", true)
        case kVK_Shift: return ("⇧", "shift", false)
        default: return nil
        }
    }

    /// Short, mid-sentence: "höger ⌘", "vänster ⌥" ("Håll in höger ⌘").
    var shortName: String {
        if modifierKeys.count > 1 { return modifierKeys.map(\.shortName).joined(separator: " + ") }
        guard let p = printed else { return inlineName }
        return p.right ? String(localized: "höger \(p.symbol)") : String(localized: "vänster \(p.symbol)")
    }

    /// On a big keycap: the symbol, and below it what's printed on the key ("höger command").
    var keycap: (symbol: String, caption: String) {
        guard let p = printed else { return (Int(keyCode) == kVK_Function ? "fn" : name, "") }
        return (p.symbol, p.right ? String(localized: "höger \(p.word)") : String(localized: "vänster \(p.word)"))
    }

    /// Something worth knowing about this key.
    var note: String {
        if modifierKeys.count > 1 {
            let instructions = String(localized: "Håll in alla valda modifieringstangenter samtidigt. Kortkommandon fungerar som vanligt.")
            if containsModifier(UInt16(kVK_Function)) {
                return instructions + " " + String(localized: "Ställ in ”Tryck på 🌐 för att” till ”Gör ingenting” under Tangentbord i Systeminställningar.")
            }
            return instructions
        }
        if Int(keyCode) == kVK_Function {
            return String(localized: "Ställ in ”Tryck på 🌐 för att” till ”Gör ingenting” under Tangentbord i Systeminställningar.")
        }
        switch Int(keyCode) {
        case kVK_Option, kVK_RightOption:
            return String(localized: "Kortkommandon som ⌥2 för @ fungerar som vanligt.")
        case kVK_Command, kVK_RightCommand:
            return String(localized: "Kortkommandon som ⌘C fungerar som vanligt.")
        case kVK_Control, kVK_RightControl, kVK_Shift, kVK_RightShift:
            return String(localized: "Kortkommandon och versaler fungerar som vanligt.")
        default: break
        }
        return String(localized: "Tangenten skriver inget medan Mindtalk är igång.")
    }

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
        kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
        kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]

    /// What the key types on the current keyboard layout (so "§" shows as §, not a code).
    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }
}

// MARK: - The meeting shortcut

/// A key together with ⌘, ⌃ or ⌥ (and perhaps ⇧), heard in every app — the meeting
/// shortcut. ⇧⌘R stays Mindtalk's own: Chrome and Safari use it to reload.
struct KeyChord: Codable, Equatable {
    var keyCode: UInt16
    /// Only ⌘ ⌃ ⌥ ⇧ — the same bits in CGEventFlags and NSEvent.ModifierFlags.
    var modifiers: UInt64

    static let relevant: UInt64 = CGEventFlags([.maskCommand, .maskControl, .maskAlternate, .maskShift]).rawValue
    /// ⌃⌥⌘M — M for möte, and taken by no common app.
    static let meetingDefault = KeyChord(keyCode: UInt16(kVK_ANSI_M),
                                         modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue)

    /// ⌃⌥T — T for tanke: the thought shortcut before right ⌘, and still the one when the
    /// dictation key is right ⌘. (⌃⌥ + space is macOS's switch of input source.)
    static let thoughtDefault = KeyChord(keyCode: UInt16(kVK_ANSI_T),
                                         modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.relevant
    }

    /// Needs ⌘, ⌃ or ⌥ — with only ⇧ it would be typing.
    var isValid: Bool { modifiers & CGEventFlags([.maskCommand, .maskControl, .maskAlternate]).rawValue != 0 }

    /// ⌘ alone (with or without ⇧) and a letter or digit: what most apps use for their own menus.
    var isCommandOnly: Bool {
        let f = CGEventFlags(rawValue: modifiers)
        guard f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskAlternate) else { return false }
        return Hotkey(keyCode: keyCode, modifierMask: 0).name.count == 1
    }

    /// ⌘Q, ⌘Tab and ⌘Space would take quitting, app switching or Spotlight from the whole
    /// Mac; ⇧⌘R and ⌘, are Mindtalk's own (start a meeting, Settings) inside the app.
    var isReserved: Bool {
        let f = CGEventFlags(rawValue: modifiers)
        guard f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskAlternate) else { return false }
        if [kVK_ANSI_Q, kVK_Tab, kVK_Space].contains(Int(keyCode)) { return true }
        if Int(keyCode) == kVK_ANSI_R, f.contains(.maskShift) { return true }
        return Int(keyCode) == kVK_ANSI_Comma && !f.contains(.maskShift)
    }

    /// What ⌘ + this letter means in most apps — so a choice like ⌘T comes with a word of warning.
    static let commonMeanings: [Int: String] = [
        kVK_ANSI_N: "Nytt", kVK_ANSI_T: "Ny flik", kVK_ANSI_W: "Stäng", kVK_ANSI_S: "Spara", kVK_ANSI_P: "Skriv ut",
        kVK_ANSI_Z: "Ångra", kVK_ANSI_A: "Markera allt", kVK_ANSI_C: "Kopiera", kVK_ANSI_V: "Klistra in", kVK_ANSI_X: "Klipp ut",
        kVK_ANSI_F: "Sök", kVK_ANSI_R: "Ladda om", kVK_ANSI_O: "Öppna", kVK_ANSI_M: "Minimera", kVK_ANSI_H: "Göm",
        kVK_ANSI_Comma: "Inställningar",
    ]

    /// A word of warning for a chord other apps count on — nil when there's nothing to say.
    var warning: String? {
        guard isCommandOnly else { return nil }
        let f = CGEventFlags(rawValue: modifiers)
        if !f.contains(.maskShift), let meaning = Self.commonMeanings[Int(keyCode)] {
            return String(localized: "\(chip.replacingOccurrences(of: " ", with: "")) betyder \(String(localized: String.LocalizationValue(meaning))) i de flesta appar. Mindtalk tar över den överallt medan appen är igång – ⌃⌥ och en bokstav är ett säkrare val.")
        }
        return String(localized: "En genväg med bara ⌘ krockar ofta med andra appars kortkommandon. Mindtalk tar över den överallt medan appen är igång – ⌃⌥ och en bokstav är ett säkrare val.")
    }

    func matches(_ keyCode: UInt16, _ flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.rawValue & Self.relevant == modifiers
    }

    /// "⌃ ⌥ ⌘ M", in the order macOS writes them.
    var chip: String {
        var parts: [String] = []
        let f = CGEventFlags(rawValue: modifiers)
        if f.contains(.maskControl) { parts.append("⌃") }
        if f.contains(.maskAlternate) { parts.append("⌥") }
        if f.contains(.maskShift) { parts.append("⇧") }
        if f.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Hotkey(keyCode: keyCode, modifierMask: 0).name)
        return parts.joined(separator: " ")
    }
}

// MARK: - The thought shortcut

/// Say a thought (Tankar): a modifier held on its own, like the dictation key — right ⌘
/// by default — or a chord like ⌃⌥T, the default before. On its own means on its own:
/// ⌘C, ⌘Tab or a ⌘-click with right ⌘ stay what they always were.
enum ThoughtShortcut: Equatable {
    case key(Hotkey)
    case chord(KeyChord)

    static let rightCommand = ThoughtShortcut.key(Hotkey(keyCode: UInt16(kVK_RightCommand), modifierMask: 0x10))

    /// Right ⌘ — unless the dictation key already uses it: then ⌃⌥T, as before.
    static func standard(besides dictation: Hotkey) -> ThoughtShortcut {
        rightCommand.collides(with: dictation) ? .chord(.thoughtDefault) : rightCommand
    }

    var key: Hotkey? { if case .key(let key) = self { return key } else { return nil } }
    var chord: KeyChord? { if case .chord(let chord) = self { return chord } else { return nil } }
    var isModifier: Bool { key != nil }

    /// Shares a key with the dictation key — never allowed: one press can't be both.
    func collides(with dictation: Hotkey) -> Bool {
        guard let key, dictation.isModifier else { return false }
        return dictation.containsModifier(key.keyCode)
    }

    /// For a chip: "⌘ Cmd →", "⌃⌥T".
    var chip: String {
        switch self {
        case .key(let key): return key.chip
        case .chord(let chord): return chord.chip.replacingOccurrences(of: " ", with: "")
        }
    }

    /// On one big key: "⌘ Cmd →", "⌃ ⌥ T".
    var keycap: String {
        switch self {
        case .key(let key): return key.chip
        case .chord(let chord): return chord.chip
        }
    }

    /// Mid-sentence: "höger ⌘", "⌃⌥T" ("Håll in höger ⌘ och prata").
    var inlineName: String { key?.shortName ?? chip }

    /// One big key each, with what's printed on it: ⌘ over "höger command" — or ⌃ ⌥ T.
    var keycaps: [(symbol: String, caption: String)] {
        switch self {
        case .key(let key): return [key.keycap]
        case .chord(let chord):
            let f = CGEventFlags(rawValue: chord.modifiers)
            var keys: [(symbol: String, caption: String)] = []
            if f.contains(.maskControl) { keys.append(("⌃", "control")) }
            if f.contains(.maskAlternate) { keys.append(("⌥", "option")) }
            if f.contains(.maskShift) { keys.append(("⇧", "shift")) }
            if f.contains(.maskCommand) { keys.append(("⌘", "command")) }
            keys.append((Hotkey(keyCode: chord.keyCode, modifierMask: 0).name, ""))
            return keys
        }
    }

    /// Why this can't be the thought key next to that dictation key — nil when it can.
    func refusal(besides dictation: Hotkey) -> String? {
        guard let key, collides(with: dictation) else { return nil }
        return String(localized: "\(key.name) används redan för diktering – välj en annan tangent.")
    }

    /// Why a newly picked dictation key can't be taken next to this thought key — nil when it can.
    static func refusal(dictation: Hotkey, besides thought: ThoughtShortcut?) -> String? {
        guard let thought, let key = thought.key, thought.collides(with: dictation) else { return nil }
        return String(localized: "\(key.name) används redan för Tankar – välj en annan tangent.")
    }
}

// MARK: - Global key listener

/// Listens to every key press system-wide through a CGEvent tap (needs Accessibility).
@MainActor
final class KeyListener {
    static let shared = KeyListener()

    var hotkey: Hotkey = Settings.hotkey
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key was pressed while the dictation key is down (e.g. ⌥2 for @).
    var onChord: (() -> Void)?
    /// Escape. Return true to swallow it (we're recording and it means "cancel").
    var onEscape: (() -> Bool)?
    /// Space while the dictation key is held. Return true to swallow it (it locks the dictation).
    var onSpaceWhileHeld: (() -> Bool)?
    /// ⌃⌥V: type the last dictation again. Always swallowed.
    var onPasteLast: (() -> Void)?
    /// The meeting shortcut, in every app (nil: off). Swallowed.
    var meetingChord: KeyChord? = Settings.meetingShortcut
    var onMeetingChord: (() -> Void)?
    /// Say a thought: pressed and let go (held while you talk). nil: off.
    var thoughtShortcut: ThoughtShortcut? = Settings.thoughtShortcut {
        didSet { thoughtHeld = false; thoughtKeyDown = false; thoughtKeySpoiled = false }
    }
    var onThoughtPress: (() -> Void)?
    var onThoughtRelease: (() -> Void)?
    /// Another key (or a click) joined the thought key: a shortcut like ⌘C, not a thought.
    var onThoughtChord: (() -> Void)?
    private var thoughtHeld = false
    /// The thought key (a modifier) is down, and it was alone when it went down.
    private var thoughtKeyDown = false
    /// Something joined in while it's down: not a thought until it's let go.
    private var thoughtKeySpoiled = false
    private var mouseMonitors: [Any] = []
    /// A new meeting shortcut is being picked: the keys go to the picker.
    var pickingChord = false
    /// Regular keys are captured on press; modifier combinations on final release.
    var capture: ((Hotkey) -> Void)? {
        didSet {
            capturedModifierMask = 0
            // A modifier already down when picking starts (⇧ held while clicking the
            // field) isn't part of the choice.
            heldOver = capture == nil ? 0 : modifiersHeldNow() & Hotkey.allModifierMasks
        }
    }
    /// The modifiers down right now, as the system reports them.
    var modifiersHeldNow: () -> UInt64 = { CGEventSource.flagsState(.combinedSessionState).rawValue }

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var capturedModifierMask: UInt64 = 0
    /// Modifiers that were down before picking began; each stops counting once let go.
    private var heldOver: UInt64 = 0
    /// A typed shortcut during a partial modifier combination must not turn into
    /// dictation when a home-row modifier arrives a moment later.
    private var modifierShortcutUsed = false
    /// fn is held — known only from the fn key's own events: arrow, function and
    /// navigation keys carry the fn flag whether or not it is.
    private var fnDown = false

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // The tap's run-loop source lives on the main run loop.
                MainActor.assumeIsolated { KeyListener.shared.handle(type, event) }
            },
            userInfo: nil
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // A click with the thought key held (⌘-click) is a shortcut too. Only watched,
        // never held up: the tap stays a keyboard tap.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated { KeyListener.shared.clicked() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { event in
            MainActor.assumeIsolated { KeyListener.shared.clicked() }
            return event
        }) { mouseMonitors.append(local) }
        isRunning = true
        return true
    }

    /// A mouse button went down: with the thought key held, it's a ⌘-click, not a thought.
    func clicked() {
        guard thoughtKeyDown, !thoughtKeySpoiled else { return }
        thoughtKeySpoiled = true
        later { $0.onThoughtChord?() }
    }

    /// The thought key held on its own. Never swallows anything — ⌘ stays ⌘ for every
    /// app — it only notes what happens: down alone, something joining in, let go.
    private func thoughtKeyEvent(_ key: Hotkey, _ type: CGEventType, _ keyCode: UInt16, _ flags: CGEventFlags) {
        if type == .flagsChanged, key.containsModifier(keyCode) {
            if key.modifiersAreDown(in: flags) {
                guard !thoughtKeyDown, !thoughtKeySpoiled else { return }
                // Another modifier already held (⇧, then right ⌘): a shortcut on its way.
                let others = flags.rawValue & Hotkey.allModifierMasks & ~key.modifierMask
                    & ~CGEventFlags.maskSecondaryFn.rawValue
                if others != 0 || (fnDown && Int(keyCode) != kVK_Function) {
                    thoughtKeySpoiled = true
                    return
                }
                thoughtKeyDown = true
                later { $0.onThoughtPress?() }
            } else {
                let wasDown = thoughtKeyDown
                thoughtKeyDown = false
                thoughtKeySpoiled = false
                if wasDown { later { $0.onThoughtRelease?() } }
            }
            return
        }
        // Anything else while it's down — a key (⌘C, ⌘Tab) or another modifier (⇧⌘).
        guard thoughtKeyDown, !thoughtKeySpoiled, type == .keyDown || type == .flagsChanged else { return }
        thoughtKeySpoiled = true
        later { $0.onThoughtChord?() }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events went missing while the tap was off — maybe the release.
            resync()
            return pass
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .flagsChanged, Int(keyCode) == kVK_Function { fnDown = event.flags.contains(.maskSecondaryFn) }

        // Picking a new key or a simultaneously held group of modifiers. Wait
        // until all modifiers are up before saving, so the capture cannot also
        // begin a dictation. Keep the largest snapshot, not a union of presses.
        if let capture {
            if type == .flagsChanged, Hotkey.modifierMasks[keyCode] != nil {
                heldOver &= event.flags.rawValue
                let held = event.flags.rawValue & Hotkey.allModifierMasks & ~heldOver
                if held.nonzeroBitCount > capturedModifierMask.nonzeroBitCount {
                    capturedModifierMask = held
                }
                if held == 0, let key = Hotkey.modifierCombination(mask: capturedModifierMask) {
                    self.capture = nil
                    capture(key)
                }
                return pass
            }
            guard type == .keyDown else { return type == .keyUp ? nil : pass }
            if Int(keyCode) != kVK_Escape, capturedModifierMask != 0 { return nil }
            self.capture = nil
            if Int(keyCode) != kVK_Escape { capture(Hotkey(keyCode: keyCode, modifierMask: 0)) }
            else { capture(hotkey) }                                          // Esc = keep the old one
            return nil
        }

        // While a shortcut is being picked, the keys are the picker's: nothing new starts
        // (holding right ⌥ to pick it mustn't begin a dictation). One already going ends.
        if pickingChord, !isDown { return pass }

        // A thought on a key held alone (right ⌘): noted, never swallowed.
        if let key = thoughtShortcut?.key { thoughtKeyEvent(key, type, keyCode, event.flags) }

        // A thought on a chord: held while you talk. The key's own presses (and repeats)
        // are ours until it's let go — whether or not the modifiers still are.
        if let chord = thoughtShortcut?.chord, !pickingChord {
            if type == .keyDown, !thoughtHeld, chord.matches(keyCode, event.flags) {
                if !isRepeat {
                    thoughtHeld = true
                    if hotkey.modifierKeys.count > 1, event.flags.rawValue & hotkey.modifierMask != 0 {
                        modifierShortcutUsed = true
                    }
                    if isDown { later { $0.onChord?() } }          // not a dictation too
                    later { $0.onThoughtPress?() }
                }
                return nil
            }
            if thoughtHeld, keyCode == chord.keyCode, type == .keyDown || type == .keyUp {
                if type == .keyUp {
                    thoughtHeld = false
                    later { $0.onThoughtRelease?() }
                }
                return nil
            }
        }

        // The meeting shortcut. A dictation key held as part of it is a chord, not a dictation.
        if let chord = meetingChord, !pickingChord, type == .keyDown || type == .keyUp, chord.matches(keyCode, event.flags) {
            if type == .keyDown, !isRepeat {
                if hotkey.modifierKeys.count > 1, event.flags.rawValue & hotkey.modifierMask != 0 {
                    modifierShortcutUsed = true
                }
                if isDown { later { $0.onChord?() } }
                later { $0.onMeetingChord?() }
            }
            return nil
        }

        // ⌃⌥V — "paste the last dictation again". Holding right ⌥ for it also
        // started a dictation; drop that first.
        if type == .keyDown, Int(keyCode) == kVK_ANSI_V, !isRepeat,
           event.flags.contains([.maskControl, .maskAlternate]), !event.flags.contains(.maskCommand) {
            if hotkey.modifierKeys.count > 1, event.flags.rawValue & hotkey.modifierMask != 0 {
                modifierShortcutUsed = true
            }
            if isDown { later { $0.onChord?() } }
            later { $0.onPasteLast?() }
            return nil
        }
        if type == .keyUp, Int(keyCode) == kVK_ANSI_V, event.flags.contains([.maskControl, .maskAlternate]) { return nil }

        if isDown, type == .keyDown, Int(keyCode) == kVK_Space, keyCode != hotkey.keyCode {
            if onSpaceWhileHeld?() == true { return nil }
        }

        if hotkey.isModifier {
            if type == .flagsChanged && hotkey.containsModifier(keyCode) {
                if event.flags.rawValue & hotkey.modifierMask == 0 { modifierShortcutUsed = false }
                if !hotkey.modifiersAreDown(in: event.flags) { setDown(false) }
                else if !modifierShortcutUsed { setDown(true) }
                return pass
            }
            let modifierPressed = type == .flagsChanged
                && Hotkey.modifierMasks[keyCode].map { event.flags.rawValue & $0 != 0 } == true
            // Which of the combination is held while this key goes down. An arrow key
            // on its own says "fn" too — that isn't a shortcut typed with fn held, and
            // must not block the next dictation.
            var members = event.flags.rawValue & hotkey.modifierMask
            if type == .keyDown, !fnDown { members &= ~CGEventFlags.maskSecondaryFn.rawValue }
            if hotkey.modifierKeys.count > 1, members != 0, type == .keyDown || modifierPressed {
                modifierShortcutUsed = true
            }
            if isDown, type == .keyDown || modifierPressed
                || (hotkey.modifierKeys.count == 1 && type == .flagsChanged) {
                later { $0.onChord?() }
            }
        } else if keyCode == hotkey.keyCode, type == .keyDown || type == .keyUp {
            let shortcut = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
            if type == .keyDown, !isDown, !shortcut.isEmpty { return pass }   // ⌘/⌃/⌥ + key: not ours
            if !isRepeat { setDown(type == .keyDown) }
            return nil
        }

        if type == .keyDown, Int(keyCode) == kVK_Escape, !isRepeat, onEscape?() == true { return nil }
        return pass
    }

    private func setDown(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        later { down ? $0.onPress?() : $0.onRelease?() }
    }

    /// Runs work after the tap has handed the event back. Starting the mic can take
    /// a moment (longer with Bluetooth), and every key on the Mac waits while the
    /// tap callback runs — so the callback only records what happened. The main
    /// queue keeps the order.
    private func later(_ work: @escaping @MainActor (KeyListener) -> Void) {
        DispatchQueue.main.async { work(self) }
    }

    /// Is the dictation key held down right now, according to the hardware? Asks the
    /// keyboard and the session both, and says "up" only if both do — ending a
    /// dictation you're holding is worse than one missed release.
    var keyPhysicallyDown: Bool {
        isDown(in: .hidSystemState) || isDown(in: .combinedSessionState)
    }

    private func isDown(in state: CGEventSourceStateID) -> Bool {
        if hotkey.isModifier {
            return hotkey.modifiersPhysicallyDown(in: CGEventSource.flagsState(state))
        }
        return CGEventSource.keyState(state, key: CGKeyCode(hotkey.keyCode))
    }

    /// Brings `isDown` in line with the hardware — after the tap was switched off,
    /// after sleep, or whenever a release may have been missed.
    func resync() {
        if isDown && !keyPhysicallyDown {
            let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
            let hid = CGEventSource.flagsState(.hidSystemState).rawValue
            os_log("resync: key reported up (combined %{public}llx, hid %{public}llx, mask %{public}llx)",
                   log: Self.diagnostics, type: .info, flags, hid, UInt64(hotkey.modifierMask))
            setDown(false)
        }
        // A release that went missing (the tap was off) must not leave a combination
        // blocked, or fn counted as held: the hardware has the last word.
        let hid = CGEventSource.flagsState(.hidSystemState)
        if hid.rawValue & hotkey.modifierMask == 0 { modifierShortcutUsed = false }
        if !hid.contains(.maskSecondaryFn) { fnDown = false }
        // The thought key let go while the tap was off.
        if thoughtHeld, let chord = thoughtShortcut?.chord, !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(chord.keyCode)) {
            thoughtHeld = false
            later { $0.onThoughtRelease?() }
        }
        if thoughtKeyDown || thoughtKeySpoiled, let key = thoughtShortcut?.key,
           !key.modifiersPhysicallyDown(in: hid),
           !key.modifiersPhysicallyDown(in: CGEventSource.flagsState(.combinedSessionState)) {
            let wasDown = thoughtKeyDown
            thoughtKeyDown = false
            thoughtKeySpoiled = false
            if wasDown { later { $0.onThoughtRelease?() } }
        }
    }

    private static let diagnostics = OSLog(subsystem: "ai.mindact.mindtalk", category: "Keys")

    /// Forget a half-finished press (e.g. after changing the key).
    func reset() {
        isDown = false
        thoughtHeld = false
        thoughtKeyDown = false
        thoughtKeySpoiled = false
        modifierShortcutUsed = false
        fnDown = false
        capturedModifierMask = 0
        heldOver = 0
    }

    #if DEBUG
    /// Feed synthetic events through the real routing without installing a tap.
    func handleForTesting(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        handle(type, event)
    }
    #endif
}
