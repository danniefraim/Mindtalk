import SwiftUI

/// The card at the top of Diktering and Tankar: your key as a big keycap, what to do
/// with it, and Ändra under that (Avbryt while a key is being picked, Välj when there
/// is none). On the right the page's own button: Prova, or Säg en tanke. `below`:
/// anything the page keeps in the same card (Diktering's box to try it in).
struct KeyCard<Change: View, Trailing: View, Below: View>: View {
    /// What's printed on the big key ("⌥ Opt →", "⌃ ⌥ T"). nil: no key, "Ingen genväg".
    let keycap: String?
    /// A key is being picked: the cap gets the ink edge.
    let picking: Bool
    let title: String
    let detail: String
    /// The detail is why a key just picked wasn't taken: in the warning colour.
    var refused = false
    /// The cap and the title, read as one: "Genväg: vänster Option. Håll in och säg det."
    let spoken: String
    @ViewBuilder var change: Change
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                cap
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: title)
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: spoken))
                    Text(verbatim: detail)
                        .font(.system(size: 13))
                        .foregroundStyle(refused ? DS.Colors.warning : DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        // Both pages wrap at the same length.
                        .frame(maxWidth: 480, alignment: .leading)
                    change
                        .padding(.top, 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            below
        }
        .padding(22)
        .card()
        .animation(.snappy(duration: 0.2), value: picking)
    }

    /// A big KeyChip: the same raised control fill, edge and shadow.
    private var cap: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control + 2, style: .continuous)
        return Group {
            if let keycap {
                Text(verbatim: keycap).font(.system(size: 20, weight: .semibold))
            } else {
                Text("Ingen genväg").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.muted)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        // Wide enough for "⌥ Opt ←", so the words beside it stay put for a short chord.
        .frame(minWidth: 112, minHeight: 56)
        .background(shape.fill(DS.Colors.control).shadow(color: .black.opacity(0.08), radius: 0, y: 2))
        .overlay(shape.strokeBorder(picking ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: 1))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Screenshots (`--picking`): both pages' cards drawn while a key is being picked.
enum KeyCardPreview {
    nonisolated(unsafe) static var picking = false
}

extension KeyCard where Below == EmptyView {
    init(keycap: String?, picking: Bool, title: String, detail: String, refused: Bool = false, spoken: String,
         @ViewBuilder change: () -> Change, @ViewBuilder trailing: () -> Trailing) {
        self.init(keycap: keycap, picking: picking, title: title, detail: detail, refused: refused, spoken: spoken,
                  change: change, trailing: trailing, below: { EmptyView() })
    }
}

extension Hotkey {
    /// For VoiceOver: "vänster option", "höger command", or the key's name.
    var spokenName: String {
        if modifierKeys.count > 1 { return modifierKeys.map(\.spokenName).joined(separator: " + ") }
        let caption = keycap.caption
        return caption.isEmpty ? name : caption
    }
}

extension ThoughtShortcut {
    /// For VoiceOver: "vänster option", or the chord ("⌃⌥T").
    var spokenName: String { key?.spokenName ?? chip }
    /// Mid-sentence in a title: "vänster ⌥ Option", or the chord ("⌃⌥T").
    var titleName: String { key?.inlineName ?? chip }
}
