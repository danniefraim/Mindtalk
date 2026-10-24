import AppKit
import SwiftUI
import UserNotifications
import os

// MARK: - A call begins

/// When Teams, Zoom, FaceTime or another call app starts using the microphone, a quiet
/// question: "Samtal i Zoom. Vill du ta anteckningar?" Pressed, it opens the start card,
/// waiting for your choice; nothing is ever recorded before that press. Read from Core
/// Audio's list of processes using an input (no permission, no window titles, no
/// addresses), every three seconds. Asked once a call: an app that keeps its microphone
/// open (Zoom while muted) isn't asked again until it has let it go for ten seconds.
/// "Inte för Zoom" stops it for that app; Inställningar → Möten turns it all off.
@MainActor
final class CallDetector {
    static let shared = CallDetector()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Calls")
    static let category = "call"
    static let takeNotes = "call.take-notes"
    static let notForApp = "call.not-for-app"

    /// When each app began using the microphone, while it does.
    private var since: [String: Date] = [:]
    /// When each app was last asked about; kept ten seconds after it lets the microphone go.
    private var asked: [String: Date] = [:]
    private var watching: Task<Void, Never>?

    func start() {
        guard !Settings.previewing, watching == nil else { return }
        let take = UNNotificationAction(identifier: Self.takeNotes, title: String(localized: "Ta anteckningar"), options: [.foreground])
        let mute = UNNotificationAction(identifier: Self.notForApp, title: String(localized: "Fråga inte för den här appen"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [take, mute], intentIdentifiers: [], options: []),
        ])
        watching = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if Settings.askOnCalls {
                    // Core Audio asked off the main thread: it can stall while devices change.
                    let bundles = await Task.detached(priority: .utility) {
                        MediaControl.listeningProcesses().map(\.bundleID)
                    }.value
                    self?.check(bundles, front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                } else {
                    self?.forget()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Off: nothing remembered, and a question still in Notification Center taken back.
    private func forget() {
        guard !since.isEmpty || !asked.isEmpty else { return }
        withdraw(Array(Set(since.keys).union(asked.keys)))
        since = [:]
        asked = [:]
    }

    private func check(_ bundles: [String], front: String?) {
        let listening = Set(bundles.compactMap { name(for: $0, front: front) })
        let now = Date()
        // A call over: its question in Notification Center goes with it.
        withdraw(since.keys.filter { !listening.contains($0) })
        since = since.filter { listening.contains($0.key) }
        for app in listening where since[app] == nil {
            since[app] = now
            Self.log.notice("calls: \(app, privacy: .public) is using the microphone")
        }
        // Asked once a call: the mark is kept while the app listens, and ten seconds
        // after it lets the microphone go (a moment's drop, AirPods switching, isn't a
        // new call; a call right after the last one is).
        for app in listening where asked[app] != nil { asked[app] = now }
        asked = asked.filter { listening.contains($0.key) || now.timeIntervalSince($0.value) < 10 }
        // Recording or dictating: this call is in hand, not asked about. (Writing out
        // the last meeting isn't: a call that starts meanwhile is still asked about.)
        if MeetingSession.shared.isRecording || Dictation.shared.phase != .idle {
            for app in listening { asked[app] = now }
            return
        }
        guard MeetingSession.shared.phase == .idle else { return }
        let muted = Set(Settings.callAppsMuted)
        // Four seconds of it first: a page asking for the mic a moment isn't a call.
        for (app, began) in since where now.timeIntervalSince(began) >= 4 && asked[app] == nil && !muted.contains(app) {
            asked[app] = now
            ask(app)
            return
        }
    }

    /// A WebKit process (Safari's, or an app's own web view, as in new Teams) is named
    /// by the app in front when that's a known one: the call is most likely there.
    private func name(for bundle: String, front: String?) -> String? {
        guard let known = Self.app(for: bundle) else { return nil }
        if bundle.hasPrefix("com.apple.WebKit"), let front, let app = Self.app(for: front), app.prefix != known.prefix {
            return app.name
        }
        return known.name
    }

    private func withdraw(_ apps: [String]) {
        guard !apps.isEmpty else { return }
        CallPrompt.shared.withdraw(apps)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: apps.map { "call-\($0)" })
    }

    static func title(_ app: String) -> String {
        CallApps.all.first { $0.name == app }?.browser == true
            ? String(localized: "\(app) använder mikrofonen") : String(localized: "Samtal i \(app)")
    }

    static func question(_ app: String) -> String {
        CallApps.all.first { $0.name == app }?.browser == true
            ? String(localized: "Är det ett möte? Ta anteckningar med Mindtalk.")
            : String(localized: "Vill du ta anteckningar med Mindtalk?")
    }

    /// As a notification when they're allowed; otherwise (turned off, or never allowed)
    /// in a small box of Mindtalk's own at the top of the screen, so it's never lost.
    private func ask(_ app: String) {
        let center = UNUserNotificationCenter.current()
        Self.log.notice("calls: asking about \(app, privacy: .public)")
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                Self.log.notice("calls: notifications not allowed, asking in Mindtalk's own box")
                Task { @MainActor in CallPrompt.shared.show(app) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = Self.title(app)
            content.body = Self.question(app)
            content.categoryIdentifier = Self.category
            content.userInfo = ["callApp": app]
            center.add(UNNotificationRequest(identifier: "call-\(app)", content: content, trigger: nil))
        }
    }

    /// The question answered. "Ta anteckningar" (or a click on it): the start card,
    /// waiting, and afterwards back over the call. Never a start of its own.
    func answer(_ action: String, userInfo: [AnyHashable: Any]) {
        guard let app = userInfo["callApp"] as? String else { return }
        switch action {
        case Self.notForApp:
            // Through the settings page's copy, so its "Frågar inte för …" row shows at once.
            let prefs = AppPrefs.shared
            if !prefs.callAppsMuted.contains(app) { prefs.callAppsMuted.append(app) }
        case UNNotificationDismissActionIdentifier:
            break
        default:
            let meeting = MeetingSession.shared
            // Only for a call still going, and with meetings set up to start.
            guard meeting.phase == .idle, since[app] != nil,
                  VoiceModels.shared.state == .ready, Dictation.shared.engine.isInstalled else { return }
            MeetingPanel.shared.startedElsewhere = true
            meeting.armed = true
            AppDelegate.showWindow(page: .meetings)
        }
    }

    static func app(for bundleID: String) -> (prefix: String, name: String, browser: Bool)? {
        CallApps.app(for: bundleID)
    }

    #if DEBUG
    /// `Mindtalk --call-detect-test`: the apps are told apart by their bundle ids, and
    /// what uses a microphone right now is read (nothing is asked or changed).
    static func selfTest() -> Int32 {
        let cases: [(String, String?)] = [
            ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("com.apple.FaceTime", "FaceTime"),
            ("com.google.Chrome.helper", "Chrome"), ("com.apple.WebKit.GPU", "Safari"), ("com.spotify.client", nil),
            ("ai.mindact.mindtalk", nil),
        ]
        var failures = 0
        for (bundle, want) in cases {
            let got = app(for: bundle)?.name
            print((got == want ? "ok   " : "FEL  ") + "\(bundle) → \(got ?? "inget")")
            if got != want { failures += 1 }
        }
        let now = MediaControl.listeningProcesses().map(\.bundleID)
        print("Använder mikrofonen nu: " + (now.isEmpty ? "inget" : now.joined(separator: ", ")))
        print(failures == 0 ? "Call detect self-test passed." : "Call detect self-test: \(failures) FEL")
        return failures == 0 ? 0 : 1
    }
    #endif
}

// MARK: - The question in Mindtalk's own box

/// "Samtal i Teams. Vill du ta anteckningar?" at the top right of the screen, over
/// every window and space, when notifications aren't allowed: Ta anteckningar, Inte
/// nu, Fråga inte för Teams. It takes no focus from the call, goes by itself after half
/// a minute, and when the call ends.
@MainActor
final class CallPrompt {
    static let shared = CallPrompt()
    private var panel: NSPanel?
    private var app: String?
    private var hiding: Task<Void, Never>?

    func show(_ app: String) {
        close()
        self.app = app
        let view = CallPromptView(app: app) { [weak self] action in
            self?.close()
            CallDetector.shared.answer(action, userInfo: ["callApp": app])
        }
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - host.fittingSize.width - 12, y: screen.maxY - host.fittingSize.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        self.panel = panel
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func withdraw(_ apps: [String]) {
        if let app, apps.contains(app) { close() }
    }

    private func close() {
        hiding?.cancel()
        hiding = nil
        panel?.orderOut(nil)
        panel = nil
        app = nil
    }
}

private struct CallPromptView: View {
    let app: String
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2").font(.system(size: 15, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: CallDetector.title(app)).font(.system(size: 13.5, weight: .semibold))
                    Text(verbatim: CallDetector.question(app)).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                }
                Spacer(minLength: 8)
                Button { answer(UNNotificationDismissActionIdentifier) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.muted)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Inte nu")
                .accessibilityLabel("Inte nu")
            }
            HStack(spacing: 8) {
                Button("Ta anteckningar") { answer(CallDetector.takeNotes) }.buttonStyle(.ink)
                Button("Inte för \(app)") { answer(CallDetector.notForApp) }.buttonStyle(SoftButtonStyle(small: true))
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Colors.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(16)
    }
}
