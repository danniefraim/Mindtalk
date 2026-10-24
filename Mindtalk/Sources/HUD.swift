import AppKit
import SwiftUI

// MARK: - Dictation pill
//
// A small black pill at the bottom of the screen while you dictate — just the
// waveform. Locked (hands-free), it grows a ✕ to cancel and a ✓ — our text
// cursor — to type it in, both clickable. When you finish, the wave settles
// into a line and ends in a blinking cursor: speech becoming text, as in the icon.
// Once it's in, a quiet ✓ for a moment.

@MainActor
final class HUD {
    private var panel: NSPanel?
    /// The panel is a fixed stage; the pill animates inside it, centred at the bottom.
    /// Wide enough for a message on two lines.
    private static let stage = NSSize(width: 320, height: 64)

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.stage),
                                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.contentView = ClickThroughHostingView(rootView: HUDView(dictation: .shared))
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }
        guard let panel else { return }
        // Clickable only while locked, when it has buttons, and while "Sparad i Tankar."
        // is up (a click opens Tankar); otherwise it never gets in the way.
        let dictation = Dictation.shared
        panel.ignoresMouseEvents = !((dictation.handsFree && dictation.phase == .recording) || dictation.phase == .saved
                                     || dictation.phase == .waitingForModel
                                     || dictation.phase == .failed(Dictation.clickToRetry)
                                     || dictation.phase == .failed(Dictation.thoughtWithoutText))
        place(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Bottom centre of the screen you're on: just above the Dock, or near the
    /// bottom edge when the Dock is hidden or on the side.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let full = screen.frame, visible = screen.visibleFrame
        let dockBelow = visible.minY > full.minY + 1
        let pillBottom = dockBelow ? visible.minY + 10 : full.minY + 14
        let origin = NSPoint(x: full.midX - Self.stage.width / 2, y: pillBottom - HUDView.stagePadding)
        panel.setFrame(NSRect(origin: origin, size: Self.stage), display: true)
    }
}

/// Buttons answer the first click, even though the panel never becomes active —
/// so the app you're typing in keeps focus and receives the text.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct HUDView: View {
    @ObservedObject var dictation: Dictation
    /// Space under the pill inside the stage, for its shadow.
    static let stagePadding: CGFloat = 10

    private static let ink = Color(white: 0.07)
    /// A message's widest line: the stage, less the pill's padding, the icon and the shadow.
    static let textWidth: CGFloat = 250

    /// The speech model's download as it stands this moment; preparing is its last tenth.
    private var waitingText: String {
        switch dictation.model {
        case .downloading(let p) where SpeechModel.isPreparing(p):
            return String(localized: "Talmodellen görs redo för din Mac, bara första gången.")
        case .downloading(let p):
            return String(localized: "Talmodellen laddas ned, \(Int(min(1, p / 0.9) * 100)) %. Öppna Mindtalk för att se.")
        default:
            return String(localized: "Talmodellen startar…")
        }
    }

    private var showsMessage: Bool {
        switch dictation.phase {
        case .failed, .copied, .notice, .waitingForModel: return true
        default: return false
        }
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
                .padding(.bottom, Self.stagePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            switch dictation.phase {
            case .recording:
                if dictation.handsFree {
                    RoundButton(help: "Avbryt (Esc)", filled: false) { dictation.cancelFromHUD() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                // A thought: said so, so you know it won't be typed where you are.
                if dictation.forThought {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.leading, dictation.handsFree ? 0 : 2)
                        .transition(.opacity)
                }
                MeterReader(meter: dictation.meter) { levels in
                    Waveform(levels: Array(levels.suffix(14)), gap: 2.5, color: .white)
                }
                .frame(width: 52, height: 16)
                if dictation.showsLanguage {
                    ModelBadge(model: dictation.engine, size: 10)
                        .foregroundStyle(.white.opacity(0.85))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                if dictation.handsFree {
                    // A thought is kept, not typed: a check, not the text cursor.
                    RoundButton(help: dictation.forThought ? "Spara tanken" : "Skriv in", filled: true) { dictation.finishFromHUD() } label: {
                        if dictation.forThought {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        } else {
                            CursorGlyph().frame(width: 8, height: 13)
                        }
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            case .transcribing:
                SettlingLine()
                    .frame(width: 60, height: 16)
            // Orange only for what's really wrong: no mic, Hjälpmedel off, a speech model
            // that failed. Everything else is a .notice.
            case .failed(let message) where message == Dictation.clickToRetry && dictation.canRetry:
                // The sound is kept: a click writes it once more.
                Button { dictation.retryLast() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warningOnNight)
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Self.textWidth, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Försök igen")
                .accessibilityHint(Text("Försöker igen"))
            case .failed(let message) where message == Dictation.thoughtWithoutText:
                // Kept in Tankar with Försök igen: a click goes there.
                Button { dictation.openThoughtsFromHUD() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warningOnNight)
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Self.textWidth, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Öppna Tankar")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warningOnNight)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.textWidth, alignment: .leading)
            case .notice(let message):
                // Nothing wrong: the words alone, no sign.
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.textWidth, alignment: .leading)
            case .waitingForModel:
                // How far the speech model has come, live; a click opens Hem to see it.
                Button { dictation.openHomeFromHUD() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.white.opacity(0.85))
                        Text(verbatim: waitingText)
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Self.textWidth, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Öppna Mindtalk")
                .accessibilityHint(Text("Öppnar Mindtalk"))
            case .copied:
                Image(systemName: "doc.on.clipboard").foregroundStyle(.white.opacity(0.85))
                Text("Inget textfält här. Texten är kopierad, klistra in med ⌘V.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.textWidth, alignment: .leading)
            case .saved:
                // A click: to Tankar, where it went.
                Button { dictation.openThoughtsFromHUD() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.white.opacity(0.85))
                        Text("Sparad i Tankar.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Öppna Tankar")
                .accessibilityHint(Text("Öppnar Tankar"))
            case .typed:
                // In: a quiet ✓, gone in a moment.
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(Text("Inskrivet"))
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, dictation.handsFree && dictation.phase == .recording ? 5 : 14)
        // A message on two lines grows the pill (the stage has room).
        .padding(.vertical, showsMessage ? 6 : 0)
        .frame(minHeight: 32)
        .fixedSize()
        .background(Capsule().fill(Self.ink))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .animation(.spring(duration: 0.32, bounce: 0.18), value: dictation.handsFree)
        .animation(.spring(duration: 0.32, bounce: 0.1), value: dictation.showsLanguage)
        .animation(.easeOut(duration: 0.25), value: dictation.phase)
    }
}

/// A 24-pt round button in the pill: ✕ on smoked glass, ✓ as a white disc.
private struct RoundButton<Label: View>: View {
    let help: String
    let filled: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(filled ? Color.black : .white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(filled ? Color.white.opacity(hovering ? 1 : 0.92)
                                                 : Color.white.opacity(hovering ? 0.28 : 0.18)))
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(LocalizedStringKey(help))
        .accessibilityLabel(LocalizedStringKey(help))
    }
}

/// Mindtalk's text cursor — the I-beam from the icon.
struct CursorGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let stem: CGFloat = 1.8, w = size.width, h = size.height
            var p = Path()
            p.addRoundedRect(in: CGRect(x: (w - stem) / 2, y: 0, width: stem, height: h), cornerSize: CGSize(width: stem / 2, height: stem / 2))
            p.addRoundedRect(in: CGRect(x: 0, y: 0, width: w, height: stem), cornerSize: CGSize(width: stem / 2, height: stem / 2))
            p.addRoundedRect(in: CGRect(x: 0, y: h - stem, width: w, height: stem), cornerSize: CGSize(width: stem / 2, height: stem / 2))
            ctx.fill(p, with: .foreground)
        }
    }
}

/// While the text is typed: the wave has settled into a line of text that ends
/// in a blinking cursor — the icon, in motion.
struct SettlingLine: View {
    var color: Color = .white
    @State private var drawn = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
            HStack(spacing: 4) {
                Capsule()
                    .fill(color.opacity(0.75))
                    .frame(width: drawn ? 44 : 8, height: 2)
                CursorGlyph()
                    .foregroundStyle(color)
                    .frame(width: 7, height: 14)
                    .opacity(on ? 1 : 0.25)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { drawn = true } }
        .accessibilityLabel(Text("Skriver…"))
    }
}
