#if DEBUG
import AppKit
import Carbon.HIToolbox

/// Drives the listener with local CGEvents. Nothing is posted to the keyboard,
/// no event tap is installed, and settings are never changed.
@MainActor
enum HotkeySelfTest {
    private static let option = UInt16(kVK_RightOption)
    private static let command = UInt16(kVK_RightCommand)
    private static let comboMask: UInt64 = 0x50
    private static let optionFlags = flags(0x40, [.maskAlternate])
    private static let commandFlags = flags(0x10, [.maskCommand])
    private static let comboFlags = flags(comboMask, [.maskAlternate, .maskCommand])

    static func run() async -> Int32 {
        do {
            try modelAndFlags()
            try await modifierTransitions()
            try await shortcutsAndRollover()
            try await lockAndCancel()
            try await regularKeys()
            try await capture()
            try await reset()
            try await fnCombination()
            try await meetingChord()
            try await thoughtChord()
            try await thoughtKeyAlone()
            try await thoughtLeftOption()
            try await thoughtModifierCombinations()
            try thoughtKeyConflicts()
            try await thoughtSettings()
            print("Hotkey self-test passed (model, modifier combinations, shortcuts, capture, reset, fn, meeting and thought shortcuts, thought key held alone, left ⌥ for thoughts, thought modifier combinations).")
            return 0
        } catch {
            print("Hotkey self-test failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func modelAndFlags() throws {
        let legacy = Data(#"{"keyCode":61,"modifierMask":64}"#.utf8)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: legacy)
        try require(decoded == .default, "Legacy right Option setting changed")
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(Hotkey.self, from: reencoded)
        try require(roundTrip == decoded, "Legacy setting did not round-trip")

        let combo = try combination(comboMask)
        let combinedRoundTrip = try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(combo))
        try require(combinedRoundTrip == combo, "Modifier combination did not round-trip")
        try require(combo.keyCode == option && combo.isModifier, "Combination has no canonical modifier key")
        try require(combo.modifierKeys.map(\.keyCode) == [option, command], "Combination omitted or reordered members")
        try require(combo.name.contains("⌥") && combo.name.contains("⌘"), "Combination name omitted a modifier")
        try require(combo.chip.contains("⌥") && combo.chip.contains("⌘"), "Combination chip omitted a modifier")
        try require(!combo.inlineName.isEmpty && !combo.note.isEmpty, "Combination explanatory labels are empty")
        try require(Hotkey.modifierCombination(mask: 0) == nil, "Empty modifier combination was accepted")
        try require(Hotkey.modifierCombination(mask: 0x8000) == nil, "Unknown modifier bit was accepted")
        for (keyCode, mask) in Hotkey.modifierMasks {
            try require(Hotkey.modifierCombination(mask: mask) == Hotkey(keyCode: keyCode, modifierMask: mask),
                        "Single modifier \(keyCode) changed representation")
        }

        try require(combo.modifiersAreDown(in: comboFlags), "Complete combination was not down")
        try require(!combo.modifiersAreDown(in: optionFlags), "Option alone activated the combination")
        try require(!combo.modifiersAreDown(in: commandFlags), "Command alone activated the combination")
        let wrongOption = flags(0x30, [.maskAlternate, .maskCommand])
        let wrongCommand = flags(0x48, [.maskAlternate, .maskCommand])
        try require(!combo.modifiersAreDown(in: wrongOption), "Left Option substituted for right Option")
        try require(!combo.modifiersAreDown(in: wrongCommand), "Left Command substituted for right Command")
        let sideless: CGEventFlags = [.maskAlternate, .maskCommand]
        try require(!combo.modifiersAreDown(in: sideless), "Side-less event flags activated a sided hotkey")
        try require(combo.modifiersPhysicallyDown(in: comboFlags), "Physical complete combination was not down")
        try require(combo.modifiersPhysicallyDown(in: sideless), "Side-less hardware fallback lost the combination")
        try require(combo.modifiersPhysicallyDown(in: flags(0x40, [.maskAlternate, .maskCommand])),
                    "Hardware fallback did not operate per modifier family")
        try require(!combo.modifiersPhysicallyDown(in: wrongOption), "Hardware fallback accepted known wrong Option side")
        try require(!combo.modifiersPhysicallyDown(in: wrongCommand), "Hardware fallback accepted known wrong Command side")
        try require(!combo.modifiersPhysicallyDown(in: optionFlags), "Hardware fallback accepted a missing family")
        print("Passed hotkey model and sided flags")
    }

    private static func modifierTransitions() async throws {
        let combo = try combination(comboMask)
        for firstIsOption in [true, false] {
            let probe = Probe(hotkey: combo)
            let first = firstIsOption ? option : command
            let second = firstIsOption ? command : option
            let firstFlags = firstIsOption ? optionFlags : commandFlags
            let remainingFlags = firstIsOption ? commandFlags : optionFlags
            try require(probe.send(.flagsChanged, first, firstFlags), "First modifier was swallowed")
            await drainCallbacks()
            try require(probe.calls.isEmpty, "First modifier activated the combination")
            try require(probe.send(.flagsChanged, second, comboFlags), "Completed combination was swallowed")
            _ = try probe.send(.flagsChanged, second, comboFlags)
            await drainCallbacks()
            try require(probe.calls == ["press"], "Completion did not press exactly once")
            _ = try probe.send(.flagsChanged, first, remainingFlags)
            await drainCallbacks()
            try require(probe.calls == ["press", "release"], "First member release did not end exactly once")
            // Re-completing while the other member remains down is another tap.
            _ = try probe.send(.flagsChanged, first, comboFlags)
            _ = try probe.send(.flagsChanged, second, firstFlags)
            _ = try probe.send(.flagsChanged, first, [])
            await drainCallbacks()
            try require(probe.calls == ["press", "release", "press", "release"],
                        "Re-completion or member releases produced extra callbacks")
        }

        let single = Probe(hotkey: .default)
        _ = try single.send(.flagsChanged, UInt16(kVK_Option), flags(0x20, [.maskAlternate]))
        _ = try single.send(.flagsChanged, option, flags(0x60, [.maskAlternate]))
        _ = try single.send(.flagsChanged, option, flags(0x20, [.maskAlternate]))
        await drainCallbacks()
        try require(single.calls == ["press", "release"], "Single right Option lost sided behavior")
        let singleChord = Probe(hotkey: .default)
        _ = try singleChord.send(.flagsChanged, option, optionFlags)
        _ = try singleChord.send(.flagsChanged, UInt16(kVK_Shift), flags(0x42, [.maskAlternate, .maskShift]))
        _ = try singleChord.send(.flagsChanged, UInt16(kVK_Shift), optionFlags)
        _ = try singleChord.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(singleChord.calls == ["press", "chord", "chord", "release"],
                    "Single modifier no longer chords on unrelated modifier releases")
        print("Passed modifier press orders, release and re-completion")
    }

    private static func shortcutsAndRollover() async throws {
        let combo = try combination(comboMask)
        let probe = Probe(hotkey: combo)
        _ = try probe.send(.flagsChanged, option, optionFlags)
        _ = try probe.send(.flagsChanged, command, comboFlags)
        try require(probe.send(.keyDown, UInt16(kVK_ANSI_C), comboFlags), "Command shortcut was swallowed")
        _ = try probe.send(.keyUp, UInt16(kVK_ANSI_C), comboFlags)
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), flags(0x52, [.maskAlternate, .maskCommand, .maskShift]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), comboFlags)
        _ = try probe.send(.flagsChanged, option, commandFlags)
        _ = try probe.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(probe.calls == ["press", "chord", "chord", "release"],
                    "Extra key/modifier presses or modifier releases did not chord correctly")

        for useModifier in [false, true] {
            let rollover = Probe(hotkey: combo)
            _ = try rollover.send(.flagsChanged, option, optionFlags)
            if useModifier {
                _ = try rollover.send(.flagsChanged, UInt16(kVK_Shift), flags(0x42, [.maskAlternate, .maskShift]))
                _ = try rollover.send(.flagsChanged, UInt16(kVK_Shift), optionFlags)
            } else {
                try require(rollover.send(.keyDown, UInt16(kVK_ANSI_2), optionFlags), "Option typing shortcut was swallowed")
                _ = try rollover.send(.keyUp, UInt16(kVK_ANSI_2), optionFlags)
            }
            _ = try rollover.send(.flagsChanged, command, comboFlags)
            _ = try rollover.send(.flagsChanged, command, optionFlags)
            _ = try rollover.send(.flagsChanged, command, comboFlags)
            await drainCallbacks()
            try require(rollover.calls.isEmpty, "Typing/modifier rollover activated a combination")
            _ = try rollover.send(.flagsChanged, option, commandFlags)
            _ = try rollover.send(.flagsChanged, command, [])
            _ = try rollover.send(.flagsChanged, command, commandFlags)
            _ = try rollover.send(.flagsChanged, option, comboFlags)
            _ = try rollover.send(.flagsChanged, command, optionFlags)
            _ = try rollover.send(.flagsChanged, option, [])
            await drainCallbacks()
            try require(rollover.calls == ["press", "release"], "Rollover gate did not clear after all members released")
        }
        let paste = Probe(hotkey: combo)
        _ = try paste.send(.flagsChanged, UInt16(kVK_Control), flags(0x01, [.maskControl]))
        _ = try paste.send(.flagsChanged, option, flags(0x41, [.maskControl, .maskAlternate]))
        try require(!paste.send(.keyDown, UInt16(kVK_ANSI_V), flags(0x41, [.maskControl, .maskAlternate])),
                    "Paste-last shortcut was not swallowed")
        _ = try paste.send(.keyUp, UInt16(kVK_ANSI_V), flags(0x41, [.maskControl, .maskAlternate]))
        _ = try paste.send(.flagsChanged, UInt16(kVK_Control), optionFlags)
        _ = try paste.send(.flagsChanged, command, comboFlags)
        _ = try paste.send(.flagsChanged, command, optionFlags)
        _ = try paste.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(paste.calls == ["paste"], "Paste-last shortcut rollover also started dictation")
        print("Passed shortcut passthrough and home-row rollover")
    }

    private static func lockAndCancel() async throws {
        // Right ⌥ + right ⇧: Space locks.
        let shiftMask: UInt64 = 0x44
        let shiftFlags = flags(shiftMask, [.maskAlternate, .maskShift])
        let probe = Probe(hotkey: try combination(shiftMask))
        probe.listener.onSpaceWhileHeld = { [weak probe] in probe?.calls.append("space"); return true }
        probe.listener.onEscape = { [weak probe] in probe?.calls.append("escape"); return true }
        _ = try probe.send(.flagsChanged, option, optionFlags)
        _ = try probe.send(.flagsChanged, UInt16(kVK_RightShift), shiftFlags)
        await drainCallbacks()
        try require(!probe.send(.keyDown, UInt16(kVK_Space), shiftFlags), "Space lock was not swallowed")
        _ = try probe.send(.keyUp, UInt16(kVK_Space), shiftFlags)
        await drainCallbacks()
        try require(probe.calls == ["press", "space"], "Space lock did not run once without chording: \(probe.calls)")
        try require(!probe.send(.keyDown, UInt16(kVK_Escape), shiftFlags), "Escape cancellation was not swallowed")
        _ = try probe.send(.keyUp, UInt16(kVK_Escape), shiftFlags)
        await drainCallbacks()
        try require(probe.calls.filter { $0 == "escape" }.count == 1, "Escape cancellation did not run exactly once")
        _ = try probe.send(.flagsChanged, option, flags(0x04, [.maskShift]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_RightShift), [])
        await drainCallbacks()
        try require(probe.calls.last == "release", "Lock/cancel prevented the modifier release callback")

        // With ⌘ in the key, Space is ⌘Space (Spotlight): passed on, a shortcut, never a lock.
        let spotlight = Probe(hotkey: try combination(comboMask))
        spotlight.listener.onSpaceWhileHeld = { [weak spotlight] in spotlight?.calls.append("space"); return true }
        _ = try spotlight.send(.flagsChanged, option, optionFlags)
        _ = try spotlight.send(.flagsChanged, command, comboFlags)
        try require(try spotlight.send(.keyDown, UInt16(kVK_Space), comboFlags), "⌘Space was swallowed")
        _ = try spotlight.send(.keyUp, UInt16(kVK_Space), comboFlags)
        await drainCallbacks()
        try require(spotlight.calls == ["press", "chord"], "⌘Space with a ⌘ key: \(spotlight.calls)")

        // A click with right ⌥ held (⌥-click) is a shortcut; scrolling while you talk isn't.
        let click = Probe(hotkey: .default)
        _ = try click.send(.flagsChanged, option, optionFlags)
        click.listener.clicked(scroll: true)
        await drainCallbacks()
        try require(click.calls == ["press"], "Scrolling with right ⌥ held: \(click.calls)")
        click.listener.clicked()
        _ = try click.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(click.calls == ["press", "chord", "release"], "⌥-click: \(click.calls)")
        print("Passed Space lock (not with ⌘), ⌥-click and Escape cancellation")
    }

    private static func regularKeys() async throws {
        let key = UInt16(kVK_F5)
        let probe = Probe(hotkey: Hotkey(keyCode: key, modifierMask: 0))
        try require(!probe.send(.keyDown, key), "Regular dictation key-down was not swallowed")
        try require(!probe.send(.keyDown, key, repeatKey: true), "Regular key repeat was not swallowed")
        try require(!probe.send(.keyUp, key), "Regular dictation key-up was not swallowed")
        await drainCallbacks()
        try require(probe.calls == ["press", "release"], "Regular key repeat produced extra callbacks")
        try require(probe.send(.keyDown, key, [.maskCommand]), "Command + regular dictation key was swallowed")
        _ = try probe.send(.keyUp, key, [.maskCommand])
        await drainCallbacks()
        try require(probe.calls == ["press", "release"], "Regular-key shortcut activated dictation")
        print("Passed regular dictation keys and shortcuts")
    }

    private static func capture() async throws {
        let combo = try combination(comboMask)
        let probe = Probe(hotkey: .default)
        var captured: [Hotkey] = []
        probe.listener.capture = { captured.append($0) }
        try require(probe.send(.flagsChanged, option, optionFlags), "Captured modifier was swallowed")
        _ = try probe.send(.flagsChanged, command, comboFlags)
        try require(!probe.send(.keyDown, UInt16(kVK_ANSI_C), comboFlags), "Key during modifier capture was not swallowed")
        _ = try probe.send(.keyUp, UInt16(kVK_ANSI_C), comboFlags)
        await drainCallbacks()
        try require(captured.isEmpty, "Modifier capture committed before release")
        _ = try probe.send(.flagsChanged, option, commandFlags)
        try require(captured.isEmpty, "Modifier capture committed on first member release")
        _ = try probe.send(.flagsChanged, command, [])
        _ = try probe.send(.flagsChanged, option, [])
        try require(captured == [combo] && probe.listener.capture == nil, "Modifier capture did not commit once at full release")
        await drainCallbacks()
        try require(probe.calls.isEmpty, "Capture triggered normal dictation callbacks")

        captured = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, option, optionFlags)
        try require(captured.isEmpty, "Single modifier capture committed before release")
        _ = try probe.send(.flagsChanged, option, [])
        try require(captured == [.default], "Single modifier capture changed representation")
        captured = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, UInt16(kVK_Function), [.maskSecondaryFn])
        _ = try probe.send(.flagsChanged, option, flags(0x40, [.maskAlternate, .maskSecondaryFn]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_Function), optionFlags)
        try require(captured.isEmpty, "Fn combination capture committed before all members released")
        _ = try probe.send(.flagsChanged, option, [])
        try require(captured == [try combination(0x40 | CGEventFlags.maskSecondaryFn.rawValue)],
                    "Fn combination capture omitted a modifier")

        captured = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, UInt16(kVK_Option), flags(0x20, [.maskAlternate]))
        _ = try probe.send(.flagsChanged, command, flags(0x30, [.maskAlternate, .maskCommand]))
        _ = try probe.send(.flagsChanged, command, flags(0x20, [.maskAlternate]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), flags(0x22, [.maskAlternate, .maskShift]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), flags(0x20, [.maskAlternate]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_Option), [])
        try require(captured == [try combination(0x30)], "Capture lost sides or combined non-simultaneous modifiers")

        captured = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, option, optionFlags)
        try require(!probe.send(.keyDown, UInt16(kVK_Escape), optionFlags), "Capture Escape was not swallowed")
        _ = try probe.send(.flagsChanged, option, [])
        try require(captured == [.default] && probe.listener.capture == nil, "Escape did not preserve the old hotkey")
        captured = []
        probe.listener.capture = { captured.append($0) }
        let regular = Hotkey(keyCode: UInt16(kVK_F5), modifierMask: 0)
        try require(!probe.send(.keyDown, regular.keyCode), "Captured regular key was not swallowed")
        try require(captured == [regular], "Regular-key capture was changed")

        // ⇧ already down when picking starts isn't part of the choice…
        let shift: UInt64 = 0x02
        captured = []
        probe.listener.modifiersHeldNow = { shift }
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, option, flags(0x40 | shift, [.maskAlternate, .maskShift]))
        _ = try probe.send(.flagsChanged, option, flags(shift, [.maskShift]))
        try require(captured == [.default], "A modifier held before picking was captured: \(captured)")
        // …but once let go and pressed again, it is.
        captured = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), [])
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), flags(shift, [.maskShift]))
        _ = try probe.send(.flagsChanged, option, flags(0x40 | shift, [.maskAlternate, .maskShift]))
        _ = try probe.send(.flagsChanged, option, flags(shift, [.maskShift]))
        _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), [])
        try require(captured == [try combination(0x40 | shift)], "A modifier pressed again while picking was ignored: \(captured)")
        probe.listener.modifiersHeldNow = { 0 }
        print("Passed modifier capture, side preservation and Escape")
    }

    private static func reset() async throws {
        let combo = try combination(comboMask)
        let probe = Probe(hotkey: combo)
        _ = try probe.send(.flagsChanged, option, optionFlags)
        _ = try probe.send(.flagsChanged, command, comboFlags)
        await drainCallbacks()
        probe.listener.reset()
        _ = try probe.send(.flagsChanged, option, commandFlags)
        _ = try probe.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(probe.calls == ["press"], "Reset retained a stale logical press")
        var captured: [Hotkey] = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, option, optionFlags)
        probe.listener.reset()
        _ = try probe.send(.flagsChanged, command, commandFlags)
        _ = try probe.send(.flagsChanged, command, [])
        try require(captured == [try combination(0x10)], "Reset retained modifiers from an unfinished capture")
        captured = []
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, option, optionFlags)
        probe.listener.capture = nil
        probe.listener.capture = { captured.append($0) }
        _ = try probe.send(.flagsChanged, command, commandFlags)
        _ = try probe.send(.flagsChanged, command, [])
        try require(captured == [try combination(0x10)], "New capture retained cancelled modifiers")
        print("Passed listener and capture reset")
    }

    /// Arrow, function and navigation keys carry the fn flag on their own. Pressing
    /// one must not count as a shortcut typed with fn held — but fn really held does.
    private static func fnCombination() async throws {
        let fn = CGEventFlags.maskSecondaryFn
        let fnKey = UInt16(kVK_Function)
        let combo = try combination(fn.rawValue | 0x40)
        let both = flags(0x40, [.maskAlternate, fn])

        for key in [kVK_LeftArrow, kVK_F5, kVK_Home] {
            let probe = Probe(hotkey: combo)
            let own: CGEventFlags = key == kVK_LeftArrow ? [fn, .maskNumericPad] : fn
            _ = try probe.send(.keyDown, UInt16(key), own)
            _ = try probe.send(.keyUp, UInt16(key), own)
            _ = try probe.send(.flagsChanged, fnKey, fn)
            _ = try probe.send(.flagsChanged, option, both)
            _ = try probe.send(.flagsChanged, option, fn)
            _ = try probe.send(.flagsChanged, fnKey, [])
            await drainCallbacks()
            try require(probe.calls == ["press", "release"],
                        "A key carrying the fn flag (\(key)) blocked fn + Option: \(probe.calls)")
        }

        // fn held, an arrow pressed (fn + ← is Home), then Option: a shortcut was
        // typed mid-combination, so no dictation until everything is released.
        let typed = Probe(hotkey: combo)
        _ = try typed.send(.flagsChanged, fnKey, fn)
        _ = try typed.send(.keyDown, UInt16(kVK_LeftArrow), [fn, .maskNumericPad])
        _ = try typed.send(.keyUp, UInt16(kVK_LeftArrow), [fn, .maskNumericPad])
        _ = try typed.send(.flagsChanged, option, both)
        await drainCallbacks()
        try require(typed.calls.isEmpty, "A shortcut typed with fn held still started dictation: \(typed.calls)")
        _ = try typed.send(.flagsChanged, option, fn)
        _ = try typed.send(.flagsChanged, fnKey, [])
        _ = try typed.send(.flagsChanged, fnKey, fn)
        _ = try typed.send(.flagsChanged, option, both)
        await drainCallbacks()
        try require(typed.calls == ["press"], "fn + Option did not work again after release: \(typed.calls)")
        print("Passed fn combinations with arrow, function and navigation keys")
    }

    /// ⌃⌥⌘M starts or ends a meeting in every app — exactly that combination, once
    /// per press, and never while a new one is being picked.
    private static func meetingChord() async throws {
        let m = UInt16(kVK_ANSI_M)
        let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let probe = Probe(hotkey: .default)
        probe.listener.meetingChord = .meetingDefault
        probe.listener.onMeetingChord = { [weak probe] in probe?.calls.append("meeting") }

        try require(!(try probe.send(.keyDown, m, chord)), "The meeting shortcut reached the app")
        try require(!(try probe.send(.keyDown, m, chord, repeatKey: true)), "A held meeting shortcut reached the app")
        try require(!(try probe.send(.keyUp, m, chord)), "The meeting shortcut's release reached the app")
        await drainCallbacks()
        try require(probe.calls == ["meeting"], "The meeting shortcut did not fire exactly once: \(probe.calls)")

        probe.calls = []
        try require(try probe.send(.keyDown, m, [.maskCommand]), "⌘M was taken")
        try require(try probe.send(.keyDown, m, [.maskControl, .maskAlternate, .maskCommand, .maskShift]), "⌃⌥⇧⌘M was taken")
        try require(try probe.send(.keyDown, m, []), "M was taken")
        probe.listener.pickingChord = true
        try require(try probe.send(.keyDown, m, chord), "The shortcut was taken while picking a new one")
        probe.listener.pickingChord = false
        probe.listener.meetingChord = nil
        try require(try probe.send(.keyDown, m, chord), "The shortcut was taken while turned off")
        await drainCallbacks()
        try require(probe.calls.isEmpty, "Other keys started a meeting: \(probe.calls)")

        // The dictation key (right ⌥) held as part of it: no dictation, a meeting.
        let held = Probe(hotkey: .default)
        held.listener.meetingChord = .meetingDefault
        held.listener.onMeetingChord = { [weak held] in held?.calls.append("meeting") }
        _ = try held.send(.flagsChanged, UInt16(kVK_RightOption), flags(0x40, [.maskAlternate]))
        _ = try held.send(.keyDown, m, flags(0x40, chord))
        await drainCallbacks()
        try require(held.calls == ["press", "chord", "meeting"], "Right ⌥ in the meeting shortcut: \(held.calls)")
        print("Passed meeting shortcut in every app, exact match, picking and off")
    }

    /// ⌃⌥T held: a thought — pressed once, let go once, every press and repeat of T
    /// kept from the app until it's let go (even after ⌃⌥ are).
    private static func thoughtChord() async throws {
        let t = UInt16(kVK_ANSI_T)
        let chord: CGEventFlags = [.maskControl, .maskAlternate]
        let probe = Probe(hotkey: .default)
        probe.listener.thoughtShortcut = .chord(.thoughtDefault)
        probe.listener.onThoughtPress = { [weak probe] in probe?.calls.append("thought") }
        probe.listener.onThoughtRelease = { [weak probe] in probe?.calls.append("kept") }

        try require(!(try probe.send(.keyDown, t, chord)), "The thought shortcut reached the app")
        try require(!(try probe.send(.keyDown, t, chord, repeatKey: true)), "A held thought shortcut reached the app")
        try require(!(try probe.send(.keyDown, t, [], repeatKey: true)), "T repeating after ⌃⌥ were let go reached the app")
        try require(!(try probe.send(.keyUp, t, [])), "The thought shortcut's release reached the app")
        await drainCallbacks()
        try require(probe.calls == ["thought", "kept"], "The thought shortcut: \(probe.calls)")

        probe.calls = []
        try require(try probe.send(.keyDown, t, []), "T on its own was taken")
        try require(try probe.send(.keyUp, t, []), "T's release on its own was taken")
        try require(try probe.send(.keyDown, t, [.maskCommand]), "⌘T was taken")
        probe.listener.thoughtShortcut = nil
        try require(try probe.send(.keyDown, t, chord), "The thought shortcut was taken while turned off")
        await drainCallbacks()
        try require(probe.calls.isEmpty, "Other keys began a thought: \(probe.calls)")

        // The dictation key (right ⌥) held as part of it: no dictation, a thought.
        let held = Probe(hotkey: .default)
        held.listener.thoughtShortcut = .chord(.thoughtDefault)
        held.listener.onThoughtPress = { [weak held] in held?.calls.append("thought") }
        _ = try held.send(.flagsChanged, UInt16(kVK_RightOption), flags(0x40, [.maskAlternate]))
        _ = try held.send(.keyDown, t, flags(0x40, chord))
        await drainCallbacks()
        try require(held.calls == ["press", "chord", "thought"], "Right ⌥ in the thought shortcut: \(held.calls)")
        print("Passed thought shortcut: held, repeats, release after the modifiers, off")
    }

    /// Right ⌘ held on its own: a thought — and nothing is ever swallowed. With another
    /// key (⌘C, ⌘Tab), another modifier or a click, it's a shortcut: the thought is
    /// called off before it's let go, and a modifier held first means no thought at all.
    private static func thoughtKeyAlone() async throws {
        let c = UInt16(kVK_ANSI_C)
        func thoughtProbe() -> Probe {
            let probe = Probe(hotkey: .default)
            probe.listener.thoughtShortcut = .rightCommand
            probe.listener.onThoughtPress = { [weak probe] in probe?.calls.append("thought") }
            probe.listener.onThoughtRelease = { [weak probe] in probe?.calls.append("kept") }
            probe.listener.onThoughtChord = { [weak probe] in probe?.calls.append("shortcut") }
            return probe
        }

        let alone = thoughtProbe()
        try require(try alone.send(.flagsChanged, command, commandFlags), "Right ⌘ going down was swallowed")
        _ = try alone.send(.flagsChanged, command, commandFlags)       // the same state again: no second press
        try require(try alone.send(.flagsChanged, command, []), "Right ⌘ going up was swallowed")
        await drainCallbacks()
        try require(alone.calls == ["thought", "kept"], "Right ⌘ held alone: \(alone.calls)")

        let copy = thoughtProbe()
        _ = try copy.send(.flagsChanged, command, commandFlags)
        try require(try copy.send(.keyDown, c, commandFlags), "⌘C was swallowed")
        try require(try copy.send(.keyUp, c, commandFlags), "⌘C's release was swallowed")
        try require(try copy.send(.keyDown, c, commandFlags), "A second ⌘C was swallowed")
        _ = try copy.send(.keyUp, c, commandFlags)
        _ = try copy.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(copy.calls == ["thought", "shortcut", "kept"], "Right ⌘ + C was not called off once: \(copy.calls)")

        let tab = thoughtProbe()
        _ = try tab.send(.flagsChanged, command, commandFlags)
        try require(try tab.send(.keyDown, UInt16(kVK_Tab), commandFlags), "⌘Tab was swallowed")
        _ = try tab.send(.keyDown, UInt16(kVK_Tab), commandFlags)
        _ = try tab.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(tab.calls == ["thought", "shortcut", "kept"], "⌘Tab: \(tab.calls)")

        let shift = thoughtProbe()
        _ = try shift.send(.flagsChanged, command, commandFlags)
        _ = try shift.send(.flagsChanged, UInt16(kVK_Shift), flags(0x12, [.maskCommand, .maskShift]))
        _ = try shift.send(.flagsChanged, UInt16(kVK_Shift), commandFlags)
        _ = try shift.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(shift.calls == ["thought", "shortcut", "kept"], "⇧ joining right ⌘: \(shift.calls)")

        let click = thoughtProbe()
        _ = try click.send(.flagsChanged, command, commandFlags)
        click.listener.clicked()
        click.listener.clicked()
        _ = try click.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(click.calls == ["thought", "shortcut", "kept"], "⌘-click: \(click.calls)")

        let scroll = thoughtProbe()
        _ = try scroll.send(.flagsChanged, command, commandFlags)
        scroll.listener.clicked(scroll: true, momentum: true)     // still gliding from before
        await drainCallbacks()
        try require(scroll.calls == ["thought"], "A gliding scroll spoiled the thought: \(scroll.calls)")
        scroll.listener.clicked(scroll: true)
        _ = try scroll.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(scroll.calls == ["thought", "shortcut", "kept"], "⌘-scroll: \(scroll.calls)")

        // ⇧ first, then right ⌘: ⇧⌘-something on its way — never a thought, also after ⇧ is let go.
        let shiftFirst = thoughtProbe()
        _ = try shiftFirst.send(.flagsChanged, UInt16(kVK_Shift), flags(0x02, [.maskShift]))
        _ = try shiftFirst.send(.flagsChanged, command, flags(0x12, [.maskCommand, .maskShift]))
        _ = try shiftFirst.send(.flagsChanged, UInt16(kVK_Shift), commandFlags)
        try require(try shiftFirst.send(.keyDown, UInt16(kVK_ANSI_Z), commandFlags), "⌘Z after ⇧ was swallowed")
        _ = try shiftFirst.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(shiftFirst.calls.isEmpty, "Right ⌘ after ⇧ began a thought: \(shiftFirst.calls)")
        // Let go of everything: right ⌘ alone works again.
        _ = try shiftFirst.send(.flagsChanged, command, commandFlags)
        _ = try shiftFirst.send(.flagsChanged, command, [])
        await drainCallbacks()
        try require(shiftFirst.calls == ["thought", "kept"], "Right ⌘ alone after a shortcut: \(shiftFirst.calls)")

        // Left ⌘ is left ⌘: not the thought key.
        let left = thoughtProbe()
        _ = try left.send(.flagsChanged, UInt16(kVK_Command), flags(0x08, [.maskCommand]))
        _ = try left.send(.flagsChanged, UInt16(kVK_Command), [])
        await drainCallbacks()
        try require(left.calls.isEmpty, "Left ⌘ began a thought: \(left.calls)")

        // The dictation key (right ⌥) down first: right ⌘ joins a dictation, no thought.
        let dictating = thoughtProbe()
        _ = try dictating.send(.flagsChanged, option, optionFlags)
        _ = try dictating.send(.flagsChanged, command, comboFlags)
        _ = try dictating.send(.flagsChanged, command, optionFlags)
        _ = try dictating.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(!dictating.calls.contains("thought"), "Right ⌘ during a dictation began a thought: \(dictating.calls)")

        // Picking a shortcut: the keys are the picker's.
        let picking = thoughtProbe()
        picking.listener.pickingChord = true
        _ = try picking.send(.flagsChanged, command, commandFlags)
        _ = try picking.send(.flagsChanged, command, [])
        _ = try picking.send(.flagsChanged, option, optionFlags)
        _ = try picking.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(picking.calls.isEmpty, "A key held while picking a shortcut began something: \(picking.calls)")
        print("Passed thought key held alone: right ⌘ alone, ⌘C, ⌘Tab, ⇧⌘, ⌘-click, ⌘-scroll, left ⌘, picking")
    }

    /// Left ⌥ held alone (the default): a thought. ⌥2 for @, ⌥7 for |, an ⌥-click: a
    /// shortcut, called off quietly, with the key typed as always. Right ⌥ (dictation)
    /// beside it: each works on its own, and together they're neither.
    private static func thoughtLeftOption() async throws {
        let leftOption = UInt16(kVK_Option)
        let leftFlags = flags(0x20, [.maskAlternate])
        func thoughtProbe() -> Probe {
            let probe = Probe(hotkey: .default)
            probe.listener.thoughtShortcut = ThoughtShortcut.standard(besides: .default)
            probe.listener.onThoughtPress = { [weak probe] in probe?.calls.append("thought") }
            probe.listener.onThoughtRelease = { [weak probe] in probe?.calls.append("kept") }
            probe.listener.onThoughtChord = { [weak probe] in probe?.calls.append("shortcut") }
            return probe
        }
        try require(thoughtProbe().listener.thoughtShortcut == .leftOption, "The default next to right ⌥ is not left ⌥")

        let alone = thoughtProbe()
        try require(try alone.send(.flagsChanged, leftOption, leftFlags), "Left ⌥ going down was swallowed")
        try require(try alone.send(.flagsChanged, leftOption, []), "Left ⌥ going up was swallowed")
        await drainCallbacks()
        try require(alone.calls == ["thought", "kept"], "Left ⌥ held alone: \(alone.calls)")

        for key in [kVK_ANSI_2, kVK_ANSI_7] {
            let at = thoughtProbe()
            _ = try at.send(.flagsChanged, leftOption, leftFlags)
            try require(try at.send(.keyDown, UInt16(key), leftFlags), "⌥\(key) was swallowed")
            try require(try at.send(.keyUp, UInt16(key), leftFlags), "⌥\(key)'s release was swallowed")
            _ = try at.send(.flagsChanged, leftOption, [])
            await drainCallbacks()
            try require(at.calls == ["thought", "shortcut", "kept"], "Left ⌥ + \(key) was not called off: \(at.calls)")
        }

        let click = thoughtProbe()
        _ = try click.send(.flagsChanged, leftOption, leftFlags)
        click.listener.clicked()
        _ = try click.send(.flagsChanged, leftOption, [])
        await drainCallbacks()
        try require(click.calls == ["thought", "shortcut", "kept"], "⌥-click: \(click.calls)")

        // ⇧ first, then left ⌥ (⇧⌥2 for a character): never a thought.
        let shiftFirst = thoughtProbe()
        _ = try shiftFirst.send(.flagsChanged, UInt16(kVK_Shift), flags(0x02, [.maskShift]))
        _ = try shiftFirst.send(.flagsChanged, leftOption, flags(0x22, [.maskShift, .maskAlternate]))
        _ = try shiftFirst.send(.keyDown, UInt16(kVK_ANSI_7), flags(0x22, [.maskShift, .maskAlternate]))
        _ = try shiftFirst.send(.flagsChanged, leftOption, flags(0x02, [.maskShift]))
        _ = try shiftFirst.send(.flagsChanged, UInt16(kVK_Shift), [])
        await drainCallbacks()
        try require(shiftFirst.calls.isEmpty, "Left ⌥ after ⇧ began a thought: \(shiftFirst.calls)")

        // Right ⌥ (dictation) and left ⌥ (thoughts), one at a time: each its own.
        let both = thoughtProbe()
        _ = try both.send(.flagsChanged, option, optionFlags)
        _ = try both.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(both.calls == ["press", "release"], "Right ⌥ next to a left ⌥ thought key: \(both.calls)")
        both.calls = []
        _ = try both.send(.flagsChanged, leftOption, leftFlags)
        _ = try both.send(.flagsChanged, leftOption, [])
        await drainCallbacks()
        try require(both.calls == ["thought", "kept"], "Left ⌥ next to right ⌥ dictation: \(both.calls)")
        // Right ⌥ held, then left ⌥: the dictation is called off, and it's no thought.
        both.calls = []
        _ = try both.send(.flagsChanged, option, optionFlags)
        _ = try both.send(.flagsChanged, leftOption, flags(0x60, [.maskAlternate]))
        _ = try both.send(.flagsChanged, leftOption, optionFlags)
        _ = try both.send(.flagsChanged, option, [])
        await drainCallbacks()
        try require(both.calls.contains("chord") && !both.calls.contains("thought"), "Both ⌥ held: \(both.calls)")
        // Left ⌥ held, then right ⌥: no dictation, and the thought is called off.
        both.calls = []
        _ = try both.send(.flagsChanged, leftOption, leftFlags)
        _ = try both.send(.flagsChanged, option, flags(0x60, [.maskAlternate]))
        _ = try both.send(.flagsChanged, option, leftFlags)
        _ = try both.send(.flagsChanged, leftOption, [])
        await drainCallbacks()
        try require(both.calls.first == "thought" && both.calls.contains("shortcut") && both.calls.filter { $0 == "thought" }.count == 1,
                    "Left ⌥, then right ⌥: \(both.calls)")
        print("Passed left ⌥ for thoughts: alone, ⌥2, ⌥7, ⌥-click, ⇧⌥, beside right ⌥ dictation")
    }

    private static func thoughtModifierCombinations() async throws {
        let key = try combination(0x30) // left ⌥ + right ⌘; disjoint from right ⌥ dictation
        let leftOption = UInt16(kVK_Option)
        let leftFlags = flags(0x20, [.maskAlternate])
        let together = flags(0x30, [.maskAlternate, .maskCommand])
        func thoughtProbe(_ hotkey: Hotkey? = nil) -> Probe {
            let probe = Probe(hotkey: Hotkey(keyCode: UInt16(kVK_F5), modifierMask: 0))
            probe.listener.thoughtShortcut = .key(hotkey ?? key)
            probe.listener.meetingChord = nil
            probe.listener.onThoughtPress = { [weak probe] in probe?.calls.append("thought") }
            probe.listener.onThoughtRelease = { [weak probe] in probe?.calls.append("kept") }
            probe.listener.onThoughtChord = { [weak probe] in probe?.calls.append("shortcut") }
            return probe
        }
        func modifierFlags(_ mask: UInt64) -> CGEventFlags {
            var raw = mask
            if mask & 0x60 != 0 { raw |= CGEventFlags.maskAlternate.rawValue }
            if mask & 0x18 != 0 { raw |= CGEventFlags.maskCommand.rawValue }
            if mask & 0x2001 != 0 { raw |= CGEventFlags.maskControl.rawValue }
            if mask & 0x06 != 0 { raw |= CGEventFlags.maskShift.rawValue }
            return CGEventFlags(rawValue: raw)
        }
        // Every member can be first or last; ending on the first release must only fire once.
        for mask in [UInt64(0x30), 0x2014, 0x60, CGEventFlags.maskSecondaryFn.rawValue | 0x20] {
            let combo = try combination(mask)
            let keys = combo.modifierKeys
            for pressOrder in [keys, Array(keys.reversed())] {
                for releaseOrder in [keys, Array(keys.reversed())] {
                    let probe = thoughtProbe(combo)
                    var held: UInt64 = 0
                    for (index, member) in pressOrder.enumerated() {
                        held |= member.modifierMask
                        try require(try probe.send(.flagsChanged, member.keyCode, modifierFlags(held)), "A thought modifier was swallowed")
                        await drainCallbacks()
                        try require(probe.calls == (index == keys.count - 1 ? ["thought"] : []),
                                    "Thought started before all selected keys, or failed to start: \(probe.calls)")
                    }
                    _ = try probe.send(.flagsChanged, pressOrder.last!.keyCode, modifierFlags(held))
                    for member in releaseOrder {
                        held &= ~member.modifierMask
                        try require(try probe.send(.flagsChanged, member.keyCode, modifierFlags(held)), "A thought modifier release was swallowed")
                        await drainCallbacks()
                        try require(probe.calls == ["thought", "kept"], "Thought release was missed or repeated: \(probe.calls)")
                    }
                }
            }
        }
        // Typing, another modifier, a click or a scroll during a partial combination
        // must not become a thought as the remaining member arrives.
        for action in 0..<4 {
            let probe = thoughtProbe()
            _ = try probe.send(.flagsChanged, leftOption, leftFlags)
            switch action {
            case 0:
                try require(try probe.send(.keyDown, UInt16(kVK_ANSI_C), leftFlags), "Typing with a partial thought shortcut was swallowed")
                _ = try probe.send(.keyUp, UInt16(kVK_ANSI_C), leftFlags)
            case 1:
                _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), flags(0x22, [.maskAlternate, .maskShift]))
                _ = try probe.send(.flagsChanged, UInt16(kVK_Shift), leftFlags)
            default: probe.listener.clicked(scroll: action == 3)
            }
            _ = try probe.send(.flagsChanged, command, together)
            _ = try probe.send(.flagsChanged, leftOption, commandFlags)
            // Releasing just one member (and even resuming the full combination) isn't a reset.
            _ = try probe.send(.flagsChanged, leftOption, together)
            _ = try probe.send(.flagsChanged, command, leftFlags)
            _ = try probe.send(.flagsChanged, leftOption, [])
            await drainCallbacks()
            try require(probe.calls.isEmpty, "A partial shortcut became a thought: \(probe.calls)")
            _ = try probe.send(.flagsChanged, command, commandFlags)
            _ = try probe.send(.flagsChanged, leftOption, together)
            _ = try probe.send(.flagsChanged, command, leftFlags)
            _ = try probe.send(.flagsChanged, leftOption, [])
            await drainCallbacks()
            try require(probe.calls == ["thought", "kept"], "The combination stayed blocked after all keys were released")
        }
        let extraFirst = thoughtProbe()
        _ = try extraFirst.send(.flagsChanged, UInt16(kVK_Shift), flags(0x02, [.maskShift]))
        _ = try extraFirst.send(.flagsChanged, leftOption, flags(0x22, [.maskAlternate, .maskShift]))
        _ = try extraFirst.send(.flagsChanged, UInt16(kVK_Shift), leftFlags)
        _ = try extraFirst.send(.flagsChanged, command, together)
        await drainCallbacks()
        try require(extraFirst.calls.isEmpty, "An unrelated modifier held first became a thought")

        for action in 0..<3 {
            let active = thoughtProbe()
            _ = try active.send(.flagsChanged, leftOption, leftFlags)
            _ = try active.send(.flagsChanged, command, together)
            switch action {
            case 0: _ = try active.send(.keyDown, UInt16(kVK_ANSI_C), together)
            case 1: _ = try active.send(.flagsChanged, UInt16(kVK_Shift), flags(0x32, [.maskAlternate, .maskCommand, .maskShift]))
            default: active.listener.clicked()
            }
            _ = try active.send(.flagsChanged, command, leftFlags)
            _ = try active.send(.flagsChanged, leftOption, [])
            await drainCallbacks()
            try require(active.calls == ["thought", "shortcut", "kept"], "Using a complete thought combination as a shortcut did not cancel it: \(active.calls)")
        }
        let wrongSide = thoughtProbe()
        _ = try wrongSide.send(.flagsChanged, leftOption, leftFlags)
        _ = try wrongSide.send(.flagsChanged, UInt16(kVK_Command), flags(0x28, [.maskAlternate, .maskCommand]))
        await drainCallbacks()
        try require(wrongSide.calls.isEmpty, "Left ⌘ satisfied a right ⌘ thought combination")

        let fnKey = try combination(CGEventFlags.maskSecondaryFn.rawValue | 0x20)
        let navigation = thoughtProbe(fnKey)
        _ = try navigation.send(.keyDown, UInt16(kVK_LeftArrow), [.maskSecondaryFn])
        _ = try navigation.send(.keyUp, UInt16(kVK_LeftArrow), [.maskSecondaryFn])
        _ = try navigation.send(.flagsChanged, leftOption, flags(0x20, [.maskAlternate, .maskSecondaryFn]))
        await drainCallbacks()
        try require(navigation.calls.isEmpty, "An arrow key's implied fn started a thought")
        _ = try navigation.send(.flagsChanged, UInt16(kVK_Function), flags(0x20, [.maskAlternate, .maskSecondaryFn]))
        _ = try navigation.send(.flagsChanged, UInt16(kVK_Function), leftFlags)
        _ = try navigation.send(.flagsChanged, leftOption, [])
        await drainCallbacks()
        try require(navigation.calls == ["thought", "kept"], "An arrow key blocked the next physical fn combination")

        let reset = thoughtProbe()
        _ = try reset.send(.flagsChanged, leftOption, leftFlags)
        reset.listener.clicked()
        reset.listener.reset()
        _ = try reset.send(.flagsChanged, leftOption, leftFlags)
        _ = try reset.send(.flagsChanged, command, together)
        await drainCallbacks()
        try require(reset.calls == ["thought"], "Reset left the thought combination blocked")
        reset.listener.resync() // synthetic press, with no physical keys held
        await drainCallbacks()
        try require(reset.calls == ["thought", "kept"], "Resync left the thought combination held")
        print("Passed thought modifier combinations: press/release orders, sides, fn, rollover, clicks, shortcuts, reset and resync")
    }

    /// The thought key and the dictation key never share a key — whichever is picked second is refused.
    private static func thoughtKeyConflicts() throws {
        let rightCommand = Hotkey(keyCode: command, modifierMask: 0x10)
        let leftCommand = ThoughtShortcut.key(Hotkey(keyCode: UInt16(kVK_Command), modifierMask: 0x08))
        try require(ThoughtShortcut.rightCommand.refusal(besides: rightCommand) != nil,
                    "Right ⌘ as thought key was taken while dictation has it")
        try require(ThoughtShortcut.refusal(dictation: rightCommand, besides: .rightCommand) != nil,
                    "Right ⌘ as dictation key was taken while thoughts have it")
        try require(ThoughtShortcut.refusal(dictation: try combination(comboMask), besides: .rightCommand) != nil,
                    "A dictation combination with right ⌘ was taken while thoughts have it")
        try require(ThoughtShortcut.rightCommand.refusal(besides: .default) == nil, "Right ⌘ refused next to right ⌥")
        try require(ThoughtShortcut.refusal(dictation: .default, besides: .rightCommand) == nil, "Right ⌥ refused next to right ⌘")
        try require(leftCommand.refusal(besides: rightCommand) == nil, "Left ⌘ refused next to right ⌘")
        try require(ThoughtShortcut.chord(.thoughtDefault).refusal(besides: rightCommand) == nil, "⌃⌥T refused next to right ⌘")
        try require(ThoughtShortcut.refusal(dictation: rightCommand, besides: nil) == nil, "Refused with thoughts off")
        let combo = ThoughtShortcut.key(try combination(0x30))
        try require(combo.refusal(besides: rightCommand) != nil, "A thought combination sharing its second member with dictation was accepted")
        try require(ThoughtShortcut.refusal(dictation: rightCommand, besides: combo) != nil, "Dictation overlapping a thought combination's second member was accepted")
        try require(combo.refusal(besides: .default) == nil, "Disjoint thought and dictation modifiers were refused")
        try require(combo.keycaps.map(\.symbol) == ["⌥", "⌘"], "Thought combination keycaps lost a modifier")
        try require(combo.chip.contains(" + ") && combo.inlineName.contains(" + ") && combo.spokenName.contains(" + "), "Thought combination labels lost a modifier")
        // The default: left ⌥; dictation on left ⌥, right ⌘; on both, ⌃⌥T.
        let leftOption = Hotkey(keyCode: UInt16(kVK_Option), modifierMask: 0x20)
        try require(ThoughtShortcut.standard(besides: .default) == .leftOption, "Default is not left ⌥")
        try require(ThoughtShortcut.standard(besides: rightCommand) == .leftOption, "Default next to right ⌘ is not left ⌥")
        try require(ThoughtShortcut.standard(besides: leftOption) == .rightCommand, "Default next to left ⌥ dictation is not right ⌘")
        try require(ThoughtShortcut.standard(besides: try combination(0x30)) == .chord(.thoughtDefault),
                    "Default next to left ⌥ + right ⌘ dictation is not ⌃⌥T")
        try require(ThoughtShortcut.leftOption.refusal(besides: leftOption) != nil, "Left ⌥ as thought key was taken while dictation has it")
        try require(ThoughtShortcut.leftOption.refusal(besides: .default) == nil, "Left ⌥ refused next to right ⌥")
        let left = ThoughtShortcut.leftOption
        try require(left.keycaps.count == 1 && left.keycaps[0].symbol == "⌥" && left.keycaps[0].caption.contains("option"),
                    "Left ⌥ keycaps: \(left.keycaps)")
        try require(left.chip == "⌥ Opt ←" && left.inlineName.contains("⌥") && !left.inlineName.contains("Opt"),
                    "Left ⌥ labels: \(left.chip), \(left.inlineName)")

        let one = ThoughtShortcut.rightCommand
        try require(one.chip == Hotkey(keyCode: command, modifierMask: 0x10).chip, "Right ⌘ chip: \(one.chip)")
        try require(one.inlineName.contains("⌘") && !one.inlineName.contains("Cmd"), "Right ⌘ mid-sentence: \(one.inlineName)")
        try require(one.keycaps.count == 1 && one.keycaps[0].symbol == "⌘", "Right ⌘ keycaps: \(one.keycaps)")
        let chord = ThoughtShortcut.chord(.thoughtDefault)
        try require(chord.chip == "⌃⌥T" && chord.inlineName == "⌃⌥T", "⌃⌥T chip: \(chord.chip)")
        try require(chord.keycaps.map(\.symbol) == ["⌃", "⌥", "T"], "⌃⌥T keycaps: \(chord.keycaps)")
        print("Passed thought key and dictation key conflicts, default and labels")
    }

    /// Saved settings, in a scratch domain (never the app's): an old chord is kept,
    /// nothing saved means left ⌥, a saved right ⌘ stays, off stays off.
    private static func thoughtSettings() async throws {
        let name = "ai.mindact.mindtalk.hotkey-self-test"
        guard let defaults = UserDefaults(suiteName: name) else { throw Failure("No scratch settings") }
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == .leftOption, "Nothing saved is not left ⌥")
        try require(Settings.thoughtShortcut(in: defaults, besides: Hotkey(keyCode: UInt16(kVK_Option), modifierMask: 0x20)) == .rightCommand,
                    "Nothing saved next to left ⌥ dictation is not right ⌘")
        // ⌃⌥T saved by an earlier version — the bytes it wrote.
        defaults.set(Data(#"{"keyCode":17,"modifiers":786432}"#.utf8), forKey: "thoughtShortcut")
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == .chord(.thoughtDefault), "A saved ⌃⌥T was lost")
        let custom = KeyChord(keyCode: UInt16(kVK_ANSI_J), modifiers: CGEventFlags([.maskControl, .maskCommand]).rawValue)
        defaults.set(try JSONEncoder().encode(custom), forKey: "thoughtShortcut")
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == .chord(custom), "A saved chord was lost")

        // …and that chord still works in the listener.
        let probe = Probe(hotkey: .default)
        probe.listener.thoughtShortcut = Settings.thoughtShortcut(in: defaults, besides: .default)
        var calls: [String] = []
        probe.listener.onThoughtPress = { calls.append("thought") }
        try require(!(try probe.send(.keyDown, UInt16(kVK_ANSI_J), [.maskControl, .maskCommand])), "The saved chord reached the app")
        try require(try probe.send(.flagsChanged, UInt16(kVK_Option), flags(0x20, [.maskAlternate])), "Left ⌥ was swallowed with a chord saved")
        _ = try probe.send(.flagsChanged, UInt16(kVK_Option), [])
        await drainCallbacks()
        try require(calls == ["thought"], "The saved chord, or left ⌥ beside it: \(calls)")

        Settings.setThoughtShortcut(.rightCommand, in: defaults)
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == .rightCommand, "A saved right ⌘ did not stay")
        let combo = ThoughtShortcut.key(try combination(0x30))
        Settings.setThoughtShortcut(combo, in: defaults)
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == combo, "A saved thought modifier combination was lost")
        // Turned off (✕), then a key picked: on again, with that key.
        Settings.setThoughtShortcut(nil, in: defaults)
        Settings.setThoughtShortcut(.leftOption, in: defaults)
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == .leftOption, "A key picked after off did not come back")
        Settings.setThoughtShortcut(.chord(.thoughtDefault), in: defaults)
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == .chord(.thoughtDefault), "A chord after a key did not come back")
        Settings.setThoughtShortcut(nil, in: defaults)
        try require(Settings.thoughtShortcut(in: defaults, besides: .default) == nil, "Off did not stay off")
        print("Passed thought settings: old chord kept, default left ⌥, saved right ⌘ kept, key and chord saved, off and on again")
    }

    private static func combination(_ mask: UInt64) throws -> Hotkey {
        guard let key = Hotkey.modifierCombination(mask: mask) else { throw Failure("Invalid test modifier mask \(mask)") }
        return key
    }

    private static func flags(_ sided: UInt64, _ families: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: sided | families.rawValue)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    /// The listener schedules callbacks after returning the event. A main-queue
    /// barrier observes those callbacks without sleeping or running an app UI.
    private static func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Probe {
        let listener = KeyListener()
        var calls: [String] = []

        init(hotkey: Hotkey) {
            listener.modifiersHeldNow = { 0 }      // not the real keyboard's state
            listener.hotkey = hotkey
            listener.thoughtShortcut = nil         // not this Mac's setting; the thought tests set their own
            listener.onPress = { [weak self] in self?.calls.append("press") }
            listener.onRelease = { [weak self] in self?.calls.append("release") }
            listener.onChord = { [weak self] in self?.calls.append("chord") }
            listener.onPasteLast = { [weak self] in self?.calls.append("paste") }
        }

        /// Returns true when the synthetic event is passed through.
        @discardableResult
        func send(_ type: CGEventType, _ keyCode: UInt16, _ flags: CGEventFlags = [],
                  repeatKey: Bool = false) throws -> Bool {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: type != .keyUp) else {
                throw Failure("Could not create a synthetic keyboard event")
            }
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            return listener.handleForTesting(type, event) != nil
        }
    }
}
#endif

#if DEBUG
import SwiftUI

/// `--shortcut-field-test`: the thought and meeting fields in a real (borderless,
/// off-screen) window, clicked and keyed with events posted to Mindtalk's own queue —
/// as they're used in Inställningar and on Tankar. Nothing is saved.
@MainActor
enum ShortcutFieldSelfTest {
    final class Model: ObservableObject {
        @Published var shortcut: ThoughtShortcut?
        @Published var picking = false
        @Published var refusal: String?
        @Published var meeting: KeyChord? = .meetingDefault
        @Published var pickingMeeting = false
        @Published var control = 0
        var applied: [ThoughtShortcut?] = []
        var appliedMeeting: [KeyChord?] = []
    }

    /// The thought field on top, the meeting field under it, a plain button at the bottom.
    private struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ThoughtShortcutField(shortcut: $model.shortcut, picking: $model.picking, refusal: $model.refusal,
                                     meeting: model.meeting, dictation: .default, apply: { model.applied.append($0) })
                    .frame(height: 38)
                MeetingShortcutField(chord: $model.meeting, picking: $model.pickingMeeting, taken: [model.shortcut?.chord],
                                     apply: { model.appliedMeeting.append($0) })
                    .frame(height: 38)
                Button { model.control += 1 } label: { Color.gray.frame(width: 400, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
            .frame(width: 400, height: 100, alignment: .topLeading)
        }
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static var window: NSWindow!
    private static let thoughtField = NSPoint(x: 120, y: 100 - 19)
    private static let meetingField = NSPoint(x: 120, y: 100 - 57)

    static func run() async -> Int32 {
        let model = Model()
        let window = KeyWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 100),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Harness(model: model))
        window.makeKeyAndOrderFront(nil)
        Self.window = window
        KeyListener.shared.modifiersHeldNow = { 0 }
        do {
            try await settle()
            // The clicks themselves reach SwiftUI buttons.
            try await click(NSPoint(x: 200, y: 12))
            try require(model.control == 1, "Posted clicks don't reach the window")
            // Off (✕ pressed): "Ingen genväg". Click, hold left ⌥ alone, let go.
            try await click(thoughtField)
            try require(model.picking && KeyListener.shared.pickingChord,
                        "Clicking the empty thought field did not start picking (it stopped itself)")
            try await flags(UInt16(kVK_Option), 0x80120)
            try await flags(UInt16(kVK_Option), 0x100)
            try require(model.applied.last == .key(Hotkey(keyCode: UInt16(kVK_Option), modifierMask: 0x20)),
                        "Left ⌥ held alone was not picked (applied \(model.applied), picking \(model.picking))")
            try require(!model.picking && model.shortcut == model.applied.last! && !KeyListener.shared.pickingChord,
                        "Picking did not end with the key shown")
            // Left ⌥ with 2 types @: never a shortcut, and never taken as left ⌥ held
            // alone either. Refused, picking goes on, Esc ends it.
            try await click(thoughtField)
            try await flags(UInt16(kVK_Option), 0x80120)
            try await key(UInt16(kVK_ANSI_2), 0x80120)
            try require(model.applied.count == 1, "⌥2 was taken as a shortcut")
            try await flags(UInt16(kVK_Option), 0x100)
            try require(model.applied.count == 1, "Letting go of ⌥ after ⌥2 picked left ⌥")
            try await key(UInt16(kVK_Escape), 0x100)
            try require(!model.picking, "Esc did not end picking")
            // With a key: click, then ⌃⌥T.
            try await click(thoughtField)
            try require(model.picking, "Clicking the thought field with a key did not start picking")
            try await flags(UInt16(kVK_Control), 0x40101)
            try await flags(UInt16(kVK_Option), 0xC0121)
            try await key(UInt16(kVK_ANSI_T), 0xC0121)
            try require(model.shortcut == .chord(.thoughtDefault), "⌃⌥T was not picked (\(String(describing: model.shortcut)))")
            try await flags(UInt16(kVK_Option), 0x40101)
            try await flags(UInt16(kVK_Control), 0x100)
            try require(model.shortcut == .chord(.thoughtDefault), "Letting go of ⌃⌥ changed the chord")
            // The dictation key is refused, said why, and nothing is saved.
            let count = model.applied.count
            let dictation = Hotkey.default
            if dictation.isModifier, dictation.modifierKeys.count == 1 {
                try await click(thoughtField)
                try await flags(dictation.keyCode, 0x80100 | dictation.modifierMask)
                try await flags(dictation.keyCode, 0x100)
                try require(model.applied.count == count && model.refusal != nil && !model.picking,
                            "The dictation key was not refused")
            }
            // Esc ends picking and keeps what was there.
            try await click(thoughtField)
            try await key(UInt16(kVK_Escape), 0x100)
            try require(!model.picking && model.shortcut == .chord(.thoughtDefault) && !KeyListener.shared.pickingChord,
                        "Esc did not end picking")
            // A modifier group is saved only on final release, in either press order.
            let combo = ThoughtShortcut.key(Hotkey.modifierCombination(mask: 0x30)!)
            for reversed in [false, true] {
                let first = UInt16(reversed ? kVK_RightCommand : kVK_Option)
                let second = UInt16(reversed ? kVK_Option : kVK_RightCommand)
                let firstFlags: UInt64 = reversed ? 0x100110 : 0x80120
                let before = model.applied.count
                try await click(thoughtField)
                try await flags(first, firstFlags)
                try await flags(second, 0x180130)
                try require(model.picking && model.applied.count == before, "A modifier combination was saved before release")
                try await flags(second, firstFlags)
                try require(model.picking && model.applied.count == before, "The first release saved an incomplete combination")
                try await flags(first, 0x100)
                try require(model.shortcut == combo && model.applied.count == before + 1 && !model.picking,
                            "The complete modifier combination was not picked")
            }
            // A modifier held while clicking is not part of the captured group.
            KeyListener.shared.modifiersHeldNow = { 0x02 }
            try await click(thoughtField)
            try await flags(UInt16(kVK_Option), 0xA0122)
            try await flags(UInt16(kVK_RightCommand), 0x1A0132)
            try await flags(UInt16(kVK_Option), 0x120112)
            try await flags(UInt16(kVK_RightCommand), 0x20102)
            try require(model.shortcut == combo && !model.picking, "A held-over modifier was included in the thought combination")
            KeyListener.shared.modifiersHeldNow = { 0 }
            try await flags(UInt16(kVK_Shift), 0x100)
            // Sharing only the second member with dictation is still refused.
            let beforeConflict = model.applied.count
            try await click(thoughtField)
            try await flags(UInt16(kVK_Option), 0x80120)
            try await flags(UInt16(kVK_RightOption), 0x80160)
            try await flags(UInt16(kVK_RightOption), 0x80120)
            try await flags(UInt16(kVK_Option), 0x100)
            try require(model.applied.count == beforeConflict && model.refusal != nil && model.shortcut == combo,
                        "A thought combination overlapping the dictation key was saved")
            // The meeting field: click, ⌃⌥⌘K.
            try await click(meetingField)
            try require(model.pickingMeeting && KeyListener.shared.pickingChord, "Clicking the meeting field did not start picking")
            try await key(UInt16(kVK_ANSI_K), 0x1C0000)
            let k = KeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue)
            try require(model.meeting == k && model.appliedMeeting == [k] && !model.pickingMeeting, "The meeting chord was not picked")
            // One at a time: the meeting field starting stops the thought field, and the
            // listener stays held for the one still waiting.
            try await click(thoughtField)
            try await click(meetingField)
            try require(!model.picking && model.pickingMeeting && KeyListener.shared.pickingChord,
                        "Starting the meeting field did not hand over from the thought field")
            // Leaving Mindtalk stops every field.
            ShortcutPicking.stopAll(reason: "test")
            try await settle()
            try require(!model.pickingMeeting && !KeyListener.shared.pickingChord, "stopAll did not end picking")
            print("Shortcut field self-test passed (empty field, held modifiers, combinations, held-over modifiers, ⌥2, chord, refusal, Esc, meeting, one at a time, stop).")
            return 0
        } catch {
            print("Shortcut field self-test failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private static var clicks = 0

    /// A mouse down and up at `at` (window coordinates).
    private static func click(_ at: NSPoint) async throws {
        clicks += 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: clicks,
                                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(e, atStart: false)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await settle()
    }

    private static func flags(_ code: UInt16, _ raw: UInt64) async throws {
        let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(raw)),
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        NSApp.postEvent(e, atStart: false)
        try await settle()
    }

    private static func key(_ code: UInt16, _ raw: UInt64) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(raw)),
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                     characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: code)!
            NSApp.postEvent(e, atStart: false)
        }
        try await settle()
    }

    private static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw NSError(domain: "ShortcutFieldSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
#endif
