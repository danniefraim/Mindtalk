#if DEBUG
import AppKit
import SwiftUI

// MARK: - `Mindtalk --render-window out.png --page settings [--section language] [--dark] [--size 1000x620]`
//
// The whole main window's content, the tab bar and the page, as the window draws it
// (scroll views and all), with the traffic lights where macOS puts them, so the
// layout can be judged. Pages: home, dictation, meetings, thoughts, vocabulary,
// settings. Nothing is saved, no permission is asked for and no store is loaded; the
// window is never on screen.
//   --setup        Hem as before anything is allowed (microphone, Hjälpmedel)
//   --asked        … and Tillåt for Hjälpmedel already pressed
//   --ready        everything allowed and the speech model ready

@MainActor
enum WindowRender {
    static func run(out: String, args: [String]) async {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let dark = args.contains("--dark")
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var size = CGSize(width: 1000, height: 620)
        if let text = value("--size") {
            let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        let pages: [String: Page] = ["home": .dictation, "dictation": .recent, "meetings": .meetings,
                                     "thoughts": .thoughts, "vocabulary": .vocabulary, "settings": .settings]
        MainView.startPage = value("--page").flatMap { pages[$0] } ?? .dictation
        MainView.rendering = true
        SettingsSection.preview = value("--section").flatMap(SettingsSection.init(rawValue:)) ?? .general
        if args.contains("--setup") || args.contains("--asked") {
            Dictation.shared.preview(mic: false, accessibility: false, asked: args.contains("--asked"))
        } else if args.contains("--ready") {
            Dictation.shared.preview(mic: true, accessibility: true, asked: false, model: .ready)
        }

        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -40_000, y: -40_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainView(dictation: .shared, prefs: .shared)
            .environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        // The page's entrance and the model sizes being counted.
        try? await Task.sleep(for: .seconds(2.5))
        host.layoutSubtreeIfNeeded()

        // The frame view: the content and the window's own buttons.
        let view = window.contentView?.superview ?? host
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { print("Misslyckades"); return }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            print("Ritad: \(out)")
        }
        window.close()
    }
}
#endif
