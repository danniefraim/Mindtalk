import AppKit
import SwiftUI

/// The same names are available in saved meetings and while a meeting is live.
/// Names remain useful even when remembering voices is switched off.
struct SpeakerNamePicker: View {
    @Binding var name: String
    let cast: Cast
    let placeholder: String
    let submit: (String) -> Void
    let cancel: () -> Void
    @ObservedObject private var memory = VoiceMemory.shared
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpeakerNameField(name: $name, names: names, placeholder: placeholder,
                             submit: submit, cancel: cancel)
                .frame(height: 26)
            Text("Välj en känd talare eller skriv ett nytt namn.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.muted)
        }
        .frame(width: 280)
    }

    private var names: [String] {
        SpeakerNames.choices(memory.people.map(\.name)
            + cast.order.filter { !cast.background.contains($0) }.compactMap { cast.names[String($0)] }
            + store.meetings.flatMap { VoiceMemory.namesToRemember(in: $0) }
            + [Settings.myName ?? ""])
    }
}

enum SpeakerNames {
    /// Prefer the remembered spelling, without merging distinct accented names.
    static func choices(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// An editable native Mac picker: the arrow lists every name, typing completes a
/// name, and the usual arrow keys, Return and Escape work in the list and field.
struct SpeakerNameField: NSViewRepresentable {
    @Binding var name: String
    let names: [String]
    let placeholder: String
    let submit: (String) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.usesDataSource = true
        field.dataSource = context.coordinator
        field.delegate = context.coordinator
        field.completes = true
        field.hasVerticalScroller = true
        field.numberOfVisibleItems = 8
        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel(String(localized: "Ge talaren ett namn"))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let previousNames = context.coordinator.parent.names
        context.coordinator.parent = self
        if previousNames != names { field.reloadData() }
        field.placeholderString = placeholder
        // Don't reset the field editor or its completion selection on each keystroke.
        if field.stringValue != name { field.stringValue = name }
    }

    final class Field: NSComboBox {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: SpeakerNameField
        init(_ parent: SpeakerNameField) { self.parent = parent }

        func numberOfItems(in comboBox: NSComboBox) -> Int { parent.names.count }
        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard parent.names.indices.contains(index) else { return nil }
            let name = parent.names[index]
            let selected = comboBox.indexOfSelectedItem == index
                || (comboBox.indexOfSelectedItem < 0 && comboBox.stringValue == name)
            // AppKit's default white selected text disappears on our white dark-mode
            // accent. Give the list an explicit foreground for its actual highlight.
            return NSAttributedString(string: name, attributes: [
                .foregroundColor: selected ? selectionTextColor(in: comboBox) : NSColor.controlTextColor,
            ])
        }

        private func selectionTextColor(in comboBox: NSComboBox) -> NSColor {
            var result = NSColor.selectedControlTextColor
            comboBox.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let color = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB) else { return }
                func linear(_ value: CGFloat) -> CGFloat {
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(color.redComponent)
                    + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                let blackContrast = (luminance + 0.05) / 0.05
                let whiteContrast = 1.05 / (luminance + 0.05)
                result = blackContrast >= whiteContrast ? .black : .white
            }
            return result
        }
        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            parent.names.firstIndex { $0.caseInsensitiveCompare(string) == .orderedSame } ?? NSNotFound
        }
        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            guard !string.isEmpty else { return nil }
            return parent.names.first {
                $0.range(of: string, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox else { return }
            parent.name = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  parent.names.indices.contains(field.indexOfSelectedItem) else { return }
            // AppKit can notify before stringValue reflects the selected row.
            parent.name = parent.names[field.indexOfSelectedItem]
            field.reloadData()
        }

        func comboBoxSelectionIsChanging(_ notification: Notification) {
            // Recolor both rows as the highlight moves with the mouse or arrow keys.
            (notification.object as? NSComboBox)?.reloadData()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) {
                parent.name = control.stringValue
                parent.submit(control.stringValue)
                return true
            }
            if command == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }
}
