import AppKit
import SwiftUI

// A quiet black-and-white look: white paper, soft grey cards without borders,
// serif page titles, ink controls — black in light mode, white in dark. Every color is
// dynamic, so it follows the Ljust / Mörkt / System choice in Settings.
// Liquid Glass is reserved for the HUD.

enum DS {
    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let chip: CGFloat = 7
        /// The introduction's tiles and panels.
        static let panel: CGFloat = 20
        /// The big tiles at the top of a page (Hem's day, Möten's start).
        static let tile: CGFloat = 22
    }

    enum Layout {
        /// The page column: comfortable to read, a little roomier on big windows.
        static let readingWidth: CGFloat = 720
        static let wideReadingWidth: CGFloat = 860
        static let pageHorizontal: CGFloat = 48
        static let pageTop: CGFloat = 44
        /// Between the columns and blocks of an introduction step.
        static let stepGap: CGFloat = 16
        /// The sphere's column on a tile (InkSphere): the cloud itself is about two thirds of it.
        static let sphere: CGFloat = 200
    }

    enum Colors {
        /// Page background.
        static let paper = dynamic(light: 0xFBFBFB, dark: 0x0E0E0E)
        /// Cards and grouped rows.
        static let card = dynamic(light: 0xF0F0F0, dark: 0x1E1E1E)
        /// Key chips, soft buttons, hover under tab bar rows.
        static let chip = dynamic(light: 0xE5E5E5, dark: 0x303030)
        /// Text fields and the shortcut box.
        static let field = dynamic(light: 0xFFFFFF, dark: 0x171717)
        static let fieldStroke = dynamic(light: 0xD4D4D4, dark: 0x3C3C3C)
        /// The raised, chosen option in a pill picker.
        static let pill = dynamic(light: 0xFFFFFF, dark: 0x585858)
        /// Dividers inside cards.
        static let divider = dynamic(light: 0xE0E0E0, dark: 0x303030)
        /// The week's charts (Hem, the menu bar panel): a day before today with words, and
        /// the baseline the bars stand on. Today is ink, a day to come `divider`, a day
        /// gone by without words `fieldStroke`.
        static let barPast = dynamic(light: 0xADADAD, dark: 0x5E5E5E)
        static let barBase = dynamic(light: 0xC8C8C8, dark: 0x444444)
        /// Secondary text: explanations, labels, timestamps. Darker than the system's
        /// secondary grey, so it keeps at least 6:1 contrast on paper and cards.
        static let muted = dynamic(light: 0x5C5C5C, dark: 0xA9A9A9)
        /// Deliberately quiet text (days still to come, version number).
        static let faint = dynamic(light: 0x6B6B6B, dark: 0x8A8A8A)     // ≥ 4.5:1 on paper and cards
        /// Soft buttons and key chips: raised off the card, with an edge.
        static let control = dynamic(light: 0xFFFFFF, dark: 0x383838)
        /// Primary buttons and switches.
        static let ink = dynamic(light: 0x111111, dark: 0xF2F2F2)
        /// Switches when on: ink.
        static let switchOn = dynamic(light: 0x111111, dark: 0xF2F2F2)
        /// Switches when off: a soft track and a knob that stands out on it.
        static let switchOff = dynamic(light: 0xE3E3E3, dark: 0x3A3A3A)
        static let switchKnob = dynamic(light: 0xFFFFFF, dark: 0x9A9A9A)
        /// Text on ink.
        static let onInk = dynamic(light: 0xFFFFFF, dark: 0x0E0E0E)
        /// Mindtalk's accent is ink: black in light mode, white in dark. What's chosen,
        /// the main button, switches, links, highlights. The app stays black and white.
        static let accent = dynamic(light: 0x111111, dark: 0xF2F2F2)
        /// The lighter end of the accent sheen.
        static let accentSoft = dynamic(light: 0x5A5A5A, dark: 0xFFFFFF)
        /// A faint grey: key chips in running text.
        static let accentTone = dynamic(light: 0xEFEFEF, dark: 0x2A2A2A)
        static let recording = Color.red
        /// The dark room of the introduction round and the "Nytt möte" card, in both modes.
        static let night = Color(red: 0.008, green: 0.008, blue: 0.012)
        /// Something needs attention (not an error you caused): readable on paper and cards.
        static let warning = dynamic(light: 0xA34A00, dark: 0xFF9F0A)
        static let good = Color(red: 0.20, green: 0.62, blue: 0.36)
        /// What you marked in a meeting, each kind its own quiet colour — only on icons
        /// and small labels, so the app stays black and white.
        static let markDecision = dynamic(light: 0x0F6E56, dark: 0x5DCAA5)
        static let markTask = dynamic(light: 0x534AB7, dark: 0xAFA9EC)
        static let markImportant = dynamic(light: 0x9A5B0C, dark: 0xEF9F27)

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    enum Gradients {
        /// The accent (ink) with a soft sheen — selection rings, progress, the typing cursor.
        static let accent = LinearGradient(colors: [Colors.accentSoft, Colors.accent],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
        /// The app icon's tile: deep black with a little light at the top.
        static let tile = LinearGradient(colors: [Color(white: 0.24), Color(white: 0.04)],
                                         startPoint: .top, endPoint: .bottom)
    }

    /// Page titles: large, light serif.
    static let pageTitle = Font.system(size: 38, weight: .regular, design: .serif)
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Page building blocks

extension View {
    /// Standard page: a centred column (so a zoomed or full-screen window stays
    /// balanced), generous padding, scrolls.
    func pageLayout() -> some View {
        GeometryReader { geo in
            ScrollView {
                self
                    .frame(maxWidth: geo.size.width > 1200 ? DS.Layout.wideReadingWidth : DS.Layout.readingWidth,
                           alignment: .leading)
                    .padding(.horizontal, DS.Layout.pageHorizontal)
                    .padding(.top, DS.Layout.pageTop)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// The page's reading column, for pages that manage their own scrolling —
    /// the same width and margins as `pageLayout()`.
    func pageColumn(_ windowWidth: CGFloat) -> some View {
        self
            .frame(maxWidth: windowWidth > 1200 ? DS.Layout.wideReadingWidth : DS.Layout.readingWidth, alignment: .leading)
            .padding(.horizontal, DS.Layout.pageHorizontal)
            .frame(maxWidth: .infinity)
    }

    /// A raised surface: paper-white with a clear edge and a soft shadow, so it
    /// stands off the page in light mode as well as dark.
    func raised(cornerRadius: CGFloat = 20, selected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(DS.Colors.field)
                .shadow(color: .black.opacity(selected ? 0.14 : 0.06), radius: selected ? 18 : 8, y: selected ? 8 : 3))
            .overlay(shape.strokeBorder(selected ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: selected ? 2 : 1))
    }

    /// A soft grey card holding rows.
    func card() -> some View {
        self.background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.card))
    }

    /// A page's big tile: the soft grey card with a hairline edge, clipped so what
    /// bleeds over its corner (the sphere) ends at the edge.
    func tile() -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
        return self
            .background(shape.fill(DS.Colors.card))
            .clipShape(shape)
            .overlay(shape.strokeBorder(DS.Colors.divider, lineWidth: 1))
    }
}

// Components take plain Strings and look them up in the string catalog, so a
// literal like CardRow(title: "Mikrofon") is translated, and a String that is
// already localized simply isn't found and shows as is.

/// Serif page title, with a label in small capitals above it (what the page holds:
/// "12 MÖTEN") and an optional line under it — as the day over the greeting on Hem.
struct PageHeader: View {
    let title: String
    /// Already localized; set in small capitals here.
    var eyebrow: String? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eyebrow {
                Text(verbatim: eyebrow.uppercased())
                    .font(.system(size: 11.5, weight: .semibold)).tracking(1.8).monospacedDigit()
                    .foregroundStyle(DS.Colors.muted)
                    .padding(.bottom, -2)
            }
            Text(LocalizedStringKey(title)).font(DS.pageTitle)
            if let subtitle {
                Text(LocalizedStringKey(subtitle))
                    .font(.title3)
                    .foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "App-inställningar", "Ljud"… above a card.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 15, weight: .semibold))
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row in a card: title, optional explanation, control on the right.
struct CardRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

/// Divider inset like the card's content.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.horizontal, 22)
    }
}

/// A key as a small keycap: "⌥ Opt →". A raised cap, so it reads on paper and on
/// a grey card alike; `small` for a key mid-sentence in a hint.
struct KeyChip: View {
    let text: String
    var small = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 6 : DS.Radius.chip, style: .continuous)
        Text(text)
            .font(.system(size: small ? 11.5 : 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, small ? 6 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(shape.fill(DS.Colors.control).shadow(color: .black.opacity(0.08), radius: 0, y: 1))
            .overlay(shape.strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
    }
}

/// "✓ Tillåtet" — ink text, with green only in the check itself.
struct GrantedLabel: View {
    var text = "Tillåtet"
    var body: some View {
        Label {
            Text(LocalizedStringKey(text))
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.good)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
    }
}

// MARK: - Buttons & switches

/// Soft button ("Ändra"): a raised control with a clear edge.
struct SoftButtonStyle: ButtonStyle {
    /// A smaller button, for a secondary action inside a popover or a row.
    var small = false

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, small: small) }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, small ? 10 : 16)
                .padding(.vertical, small ? 4 : 7)
                .background(shape.fill(DS.Colors.control.opacity(configuration.isPressed ? 0.7 : 1))
                    .shadow(color: .black.opacity(enabled ? 0.06 : 0), radius: 2, y: 1))
                .overlay(shape.strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// The button on a light tile, as "Starta direkt" and Hem's: chip grey with no edge or
/// shadow, or `primary` in ink with paper text, as tall as the tile's other buttons.
struct TileButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, primary: primary) }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary ? AnyShapeStyle(DS.Colors.onInk) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background(shape.fill((primary ? DS.Colors.ink : DS.Colors.chip).opacity(configuration.isPressed ? (primary ? 0.8 : 0.7) : 1)))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(shape)
        }
    }
}

/// Ink-black primary button ("Klar").
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.onInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Colors.accent.opacity(configuration.isPressed ? 0.8 : 1)))
                // Disabled: a quiet grey, clearly not clickable.
                .opacity(enabled ? 1 : 0.3)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}

/// Mindtalk's switch: an ink track when on — black in light mode, white in dark,
/// with a knob in the opposite colour — so on and off are told apart at a glance
/// in both appearances.
struct InkToggle: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(LocalizedStringKey(label), isOn: $isOn)
            .toggleStyle(InkSwitchStyle())
            .labelsHidden()
            .accessibilityLabel(LocalizedStringKey(label))
    }
}

/// A checkbox in ink, not the system's blue: a small rounded square, filled with a
/// check when on, a light control with an edge when off.
struct InkCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                ZStack {
                    shape.fill(configuration.isOn ? DS.Colors.ink : DS.Colors.control)
                    shape.strokeBorder(DS.Colors.fieldStroke, lineWidth: configuration.isOn ? 0 : 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.onInk)
                    }
                }
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A label in small capitals over what it names — "NYTT MÖTE", "I DAG" — as on Hem.
struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 11.5, weight: .semibold)).tracking(1.8)
            .foregroundStyle(DS.Colors.muted)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

struct InkSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? DS.Colors.switchOn : DS.Colors.switchOff)
                    .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke.opacity(configuration.isOn ? 0 : 1), lineWidth: 1))
                Circle()
                    .fill(configuration.isOn ? DS.Colors.onInk : DS.Colors.switchKnob)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2.5)
            }
            .frame(width: 38, height: 22)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? Text("På") : Text("Av"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Waveform

/// Bars scrolling right-to-left — the last moments of the mic, newest brightest.
/// Used in the mic picker and the dictation HUD.
struct Waveform: View {
    let levels: [Float]
    var gap: CGFloat = 3
    var dimmed = false
    var color: Color = DS.Colors.accent

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let width = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(levels.indices, id: \.self) { i in
                    // Square root lifts quiet speech so the wave reads at a distance too.
                    let v = CGFloat(min(1, levels[i].squareRoot() * 1.15))
                    let fade = 0.35 + 0.65 * Double(i) / Double(max(1, count - 1))
                    Capsule()
                        .fill(color.opacity(dimmed ? fade * 0.4 : fade))
                        .frame(width: width, height: max(width, v * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.linear(duration: 0.06), value: levels)
        .animation(.easeOut(duration: 0.3), value: dimmed)
        .accessibilityHidden(true)
    }
}

// MARK: - Pill picker

/// Mindtalk's segmented control: a warm track with the chosen option lifted out
/// as a paper pill that slides between options. Replaces the system's blue one.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var compact = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { selection = option.value }
                } label: {
                    Text(LocalizedStringKey(option.title))
                        .font(.system(size: compact ? 12 : 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Colors.muted))
                        .padding(.horizontal, compact ? 10 : 13)
                        .frame(height: compact ? 24 : 28)
                        .frame(maxWidth: compact ? .infinity : nil)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(DS.Colors.pill)
                                    .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                                    .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke.opacity(0.6), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(DS.Colors.chip))
        .fixedSize(horizontal: !compact, vertical: true)
    }
}

// MARK: - Menu picker

/// A pop-up menu that looks like the rest of Mindtalk: the choice in a soft
/// capsule with a small chevron.
struct MenuPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(LocalizedStringKey(option.title), systemImage: "checkmark")
                    } else {
                        Text(LocalizedStringKey(option.title))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(LocalizedStringKey(options.first { $0.value == selection }?.title ?? ""))
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(DS.Colors.control).shadow(color: .black.opacity(0.06), radius: 2, y: 1))
            .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - The logo mark

/// The app icon — the mark on its black tile — drawn live. Idle it's the icon;
/// animated, the wave rolls along and the cursor blinks; given `levels` (while
/// dictating) the wave swells with your voice.
struct LogoTile: View {
    let size: CGFloat
    var t: Double = 0
    var animated = false
    var levels: [Float]? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(DS.Gradients.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 118)))
            Canvas { ctx, canvas in
                let transform = Mark.tileTransform(size: canvas.width)
                let line = Mark.strokeWidth * canvas.width / 824
                let wave = Path(Mark.wave(amplitude: amplitude, phase: phase)).applying(transform)
                ctx.stroke(wave, with: .color(.white), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                let on = !animated || Int(t * 1.9) % 2 == 0
                ctx.fill(Path(Mark.cursor).applying(transform), with: .color(.white.opacity(on ? 1 : 0.2)))
            }
            .shadow(color: .black.opacity(0.4), radius: size / 40, y: size / 80)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var amplitude: CGFloat {
        if let levels, let last = levels.last {
            // Follow the voice: quiet is a ripple, speech is a full swell.
            let recent = levels.suffix(4).reduce(0, +) / Float(min(4, levels.count))
            return 0.25 + CGFloat(min(1, (max(last, recent)).squareRoot() * 1.1)) * 0.95
        }
        return animated ? 0.9 + 0.12 * sin(t * 1.7) : 1
    }

    private var phase: CGFloat { animated || levels != nil ? CGFloat(-t * 4) : 0 }
}

// MARK: - Model badge

/// The language model as a small mark: "SV" for Swedish, a globe for the
/// multilingual one (a two-letter code there would suggest a single language).
struct ModelBadge: View {
    let model: SpeechModel
    var size: CGFloat = 13
    var serif = false

    var body: some View {
        switch model {
        case .swedish:
            Text(model.code)
                .font(.system(size: size, weight: serif ? .regular : .bold, design: serif ? .serif : .rounded))
        case .multilingual:
            Image(systemName: "globe")
                .font(.system(size: size * (serif ? 0.95 : 1.05), weight: .medium))
        }
    }
}
