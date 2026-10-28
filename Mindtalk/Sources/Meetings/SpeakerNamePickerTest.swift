#if DEBUG
import AppKit
import SwiftUI

/// Exercises the native field editor and SwiftUI binding with made-up names only.
@MainActor
enum SpeakerNamePickerTest {
    private final class Model: ObservableObject {
        @Published var name = "Existing name"
        @Published var names = SpeakerNames.choices(["Danni Efraim", "Anna", "Åsa", " anna ", "", " \n"])
        var saved: [String] = []
        var cancelled = 0
    }

    private struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vem är det här?")
                SpeakerNameField(name: $model.name, names: model.names, placeholder: "Speaker 1",
                                 submit: { model.saved.append($0) }, cancel: { model.cancelled += 1 })
                    .frame(width: 280, height: 26)
                HStack {
                    Button("Avbryt") { model.cancelled += 1 }.keyboardShortcut(.cancelAction)
                    Button("Spara") { model.saved.append(model.name) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static func run() async -> Int32 {
        let model = Model()
        let window = KeyWindow(contentRect: NSRect(x: -6000, y: -6000, width: 312, height: 140),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Harness(model: model))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        do {
            try await settle()
            try require(model.names.count == 3 && model.names.contains("Anna"), "Names were not trimmed and deduplicated")
            guard let field = findField(in: host) else { throw failure("Native speaker picker is missing") }
            try require(field.numberOfItems == 3, "Known names are missing from the list")
            try require(field.stringValue == "Existing name", "Existing name was not preserved")
            try require(field.currentEditor()?.selectedRange.length == "Existing name".count, "Opening did not focus and select the name")

            // Type over the old name. Completion must reach the Save button's binding,
            // including the remembered spelling, before Return or a mouse click saves.
            try await key("d", code: 2, in: window)
            try require(field.stringValue == "Danni Efraim" && model.name == "Danni Efraim",
                        "Typing did not complete the remembered name: field=\(field.stringValue), binding=\(model.name)")
            try await key("\r", code: 36, in: window)
            try require(model.saved == ["Danni Efraim"], "Return did not save the completed name exactly once")

            // Selecting a row updates the binding even if AppKit notifies before it
            // updates the field editor (the Save button reads the binding directly).
            let anna = model.names.firstIndex(of: "Anna")!
            field.selectItem(at: anna)
            try await settle()
            try require(model.name == "Anna" && field.stringValue == "Anna", "List selection did not update the draft")

            field.selectText(nil)
            try await key("Z", code: 6, in: window)
            try await key("o", code: 31, in: window)
            try await key("e", code: 14, in: window)
            try require(model.name == "Zoe", "A new name could not be entered")
            try await key("\r", code: 36, in: window)
            try require(model.saved.last == "Zoe" && model.saved.count == 2, "Return did not save a new name")

            field.selectText(nil)
            try await key("\u{7f}", code: 51, in: window)
            try require(model.name.isEmpty, "Clearing a name no longer works")
            try await key("\u{1b}", code: 53, in: window)
            try require(model.cancelled == 1 && model.saved.count == 2, "Escape did not cancel without saving")

            model.names = []
            try await settle()
            try require(field.numberOfItems == 0, "The list retained forgotten names")
            field.selectText(nil)
            try await key("Z", code: 6, in: window)
            try require(model.name == "Z", "An empty list prevented free text entry")
            model.names = ["Åsa", "Zara"]
            try await settle()
            try require(field.numberOfItems == 2 && field.stringValue == "Z", "Refreshing names reset the draft")
            field.selectText(nil)
            try await key("a", code: 0, in: window)
            try require(model.name == "Åsa", "Completion did not preserve the accented spelling")
            print("Speaker picker self-test passed (existing name, focus, completion, list selection, Return, new name, clear, Escape, empty list, refreshed names, accents).")
            return 0
        } catch {
            print("Speaker picker self-test failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func findField(in view: NSView) -> NSComboBox? {
        if let field = view as? NSComboBox { return field }
        return view.subviews.lazy.compactMap { findField(in: $0) }.first
    }

    private static func key(_ text: String, code: UInt16, in window: NSWindow) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: code)!
            NSApp.postEvent(event, atStart: false)
        }
        try await settle()
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SpeakerNamePickerTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw failure(message) }
    }
}
#endif
