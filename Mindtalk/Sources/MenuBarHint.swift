import AppKit
import SwiftUI

// MARK: - "Mindtalk finns kvar här"
//
// The first time the main window is closed, a small bubble from the menu-bar icon
// says where Mindtalk went. Once, ever. It never takes the focus from the app you
// go back to: a panel that doesn't activate, gone after a few seconds or at a click.

@MainActor
enum MenuBarHint {
    private static let shownKey = "menuBarHintShown"
    private static var panel: NSPanel?
    private static var clickMonitors: [Any] = []
    private static var dismissal: DispatchWorkItem?

    /// Shows the bubble under the status item, the first time only.
    static func showOnce(from button: NSStatusBarButton?) {
        // New users only: someone updating from an earlier version knows where Mindtalk is.
        guard UserDefaults.standard.object(forKey: "introFinishedAt") != nil,
              !UserDefaults.standard.bool(forKey: shownKey), panel == nil,
              let button, let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        UserDefaults.standard.set(true, forKey: shownKey)

        let hosting = NSHostingView(rootView: MenuBarHintBubble(onClick: { dismiss() }))
        let size = hosting.fittingSize
        let panel = HintPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the bubble draws its own
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hosting

        // Its arrow under the icon's middle, kept on the screen.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - size.height - 2, width: size.width, height: size.height)
        hosting.rootView = MenuBarHintBubble(arrowX: anchor.midX - x - 12, onClick: { dismiss() })

        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(still ? frame : frame.offsetBy(dx: 0, dy: 6), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()   // shown, not activated: the focus stays where it is
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = still ? 0.12 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !still { panel.animator().setFrame(frame, display: true) }
        }
        self.panel = panel

        // VoiceOver hears it too.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: String(localized: "Mindtalk finns kvar i menyraden. Klicka där för att diktera, säga en tanke eller starta ett möte."),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])

        // Any click — on the bubble, in another app or in Mindtalk — puts it away.
        let away: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { dismiss() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: away) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { away($0); return $0 }) { clickMonitors.append(local) }
        let later = DispatchWorkItem { MainActor.assumeIsolated { dismiss() } }
        dismissal = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5, execute: later)
    }

    private static func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Never key, never main: clicking it doesn't bring Mindtalk forward.
    private final class HintPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

/// The bubble: ink, like the main button, with a small arrow up at the icon.
struct MenuBarHintBubble: View {
    /// Where the arrow sits, from the bubble's left edge; nil = the middle.
    var arrowX: CGFloat? = nil
    var onClick: () -> Void = {}

    private static let width: CGFloat = 272
    private static let arrow = CGSize(width: 16, height: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(nsImage: Mark.menuBarImage).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 12).accessibilityHidden(true)
                Text("Mindtalk finns kvar här").font(.system(size: 14, weight: .semibold))
            }
            Text("Klicka för att diktera, säga en tanke eller starta ett möte.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.onInk.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DS.Colors.onInk)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.ink))
        .overlay(alignment: .topLeading) {
            Arrow().fill(DS.Colors.ink)
                .frame(width: Self.arrow.width, height: Self.arrow.height)
                .offset(x: min(max(arrowX ?? Self.width / 2, 22), Self.width - 22) - Self.arrow.width / 2, y: -Self.arrow.height + 0.5)
        }
        .padding(.top, Self.arrow.height)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 12).padding(.bottom, 16)   // room for the shadow
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .accessibilityElement(children: .combine)
    }

    /// A small triangle pointing up; `open` draws only its two slanted sides.
    private struct Arrow: Shape {
        var open = false
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            if !open { p.closeSubpath() }
            return p
        }
    }
}
