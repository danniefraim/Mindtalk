import Accessibility
import AppKit
import SwiftUI
import UserNotifications
import os

// MARK: - A call begins

/// When Teams, Zoom, FaceTime or another call app starts using the microphone, a small
/// box at the top right of the screen: "Samtal i Teams. Vill du anteckna mötet?" with
/// Starta direkt (recording at once, the meeting in its panel over the call) and Med
/// namnrunda (Mindtalk's window, the round). Its own box rather than a notification, as
/// Granola, Wispr Flow and MacWhisper do: the buttons are seen at once, one click starts,
/// and it shows with notifications off or a Focus on. Nothing is ever recorded without
/// that press. Read from Core Audio's list of processes using an input (no permission,
/// no window titles, no addresses), every three seconds. Asked once a call: an app that
/// keeps its microphone open (Zoom while muted) isn't asked again until it has let it go
/// for ten seconds. "Fråga inte för Teams" stops it for that app; Inställningar → Möten
/// turns it all off.
@MainActor
final class CallDetector {
    static let shared = CallDetector()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Calls")
    /// Notifications from earlier versions of the question, still in Notification Center.
    static let category = "call"

    enum Answer { case startDirect, startRound, openCard, notForApp, notNow }

    /// When each app began using the microphone, while it does (and ten seconds after,
    /// so a moment's drop, AirPods switching, is the same call).
    private var since: [String: Date] = [:]
    /// When each app was last seen using it.
    private var seen: [String: Date] = [:]
    /// The name a listening process got when first seen: a call in new Teams' web view
    /// stays "Teams" when you turn to another app.
    private var named: [String: String] = [:]
    /// When each app was last asked about; kept ten seconds after it lets the microphone go.
    private var asked: [String: Date] = [:]
    private var watching: Task<Void, Never>?

    func start() {
        guard !Settings.previewing, watching == nil else { return }
        // Questions from the version that asked in notifications: taken back.
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: CallApps.all.map { "call-\($0.name)" })
        center.setNotificationCategories([])
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

    /// Off: nothing remembered, and a question on screen taken back.
    private func forget() {
        guard !since.isEmpty || !asked.isEmpty else { return }
        CallPrompt.shared.withdraw(Array(since.keys))
        since = [:]
        seen = [:]
        asked = [:]
        named = [:]
    }

    private func check(_ bundles: [String], front: String?) {
        // Not before the introduction is done: meetings may not be set up yet.
        guard Settings.didOnboard, !AppDelegate.isOnboarding else { return }
        named = named.filter { bundles.contains($0.key) }
        for bundle in bundles where named[bundle] == nil { named[bundle] = name(for: bundle, front: front) }
        let listening = Set(bundles.compactMap { named[$0] })
        let now = Date()
        for app in listening { seen[app] = now }
        // A call over (its app has let the microphone go for ten seconds): its question
        // goes with it.
        let over = seen.filter { now.timeIntervalSince($0.value) >= 10 }.map(\.key)
        CallPrompt.shared.withdraw(over)
        for app in over { since[app] = nil; seen[app] = nil }
        for app in listening where since[app] == nil {
            since[app] = now
            Self.log.notice("calls: \(app, privacy: .public) is using the microphone")
        }
        // Asked once a call: the mark is kept while the app listens, and ten seconds
        // after it lets the microphone go (a moment's drop, AirPods switching, isn't a
        // new call; a call right after the last one is).
        for app in listening where asked[app] != nil { asked[app] = now }
        asked = asked.filter { listening.contains($0.key) || now.timeIntervalSince($0.value) < 10 }
        // Recording: this call is in hand, not asked about (and a question still up goes:
        // the meeting was started another way). Dictating, or writing out the last
        // meeting: not now, but a call that started meanwhile is asked about after.
        if MeetingSession.shared.isRecording {
            for app in listening { asked[app] = now }
            CallPrompt.shared.withdraw(Array(listening))
            return
        }
        guard MeetingSession.shared.phase == .idle,
              Dictation.shared.phase != .recording, Dictation.shared.phase != .transcribing else { return }
        let muted = Set(Settings.callAppsMuted)
        // Four seconds of it first: a page asking for the mic a moment isn't a call.
        for (app, began) in since where listening.contains(app) && now.timeIntervalSince(began) >= 4 && asked[app] == nil && !muted.contains(app) {
            asked[app] = now
            Self.log.notice("calls: asking about \(app, privacy: .public)")
            CallPrompt.shared.show(app)
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

    static func title(_ app: String) -> String {
        CallApps.all.first { $0.name == app }?.browser == true
            ? String(localized: "\(app) använder mikrofonen") : String(localized: "Samtal i \(app)")
    }

    static func question(_ app: String) -> String {
        CallApps.all.first { $0.name == app }?.browser == true
            ? String(localized: "Är det ett möte? Anteckna det med Mindtalk.")
            : String(localized: "Vill du anteckna mötet?")
    }

    /// The question answered.
    /// - Starta direkt: recording now, the meeting in its panel, you stay in the call.
    ///   The very first meeting (the question about remembering voices), or meetings
    ///   not ready yet: the start card instead, where that is said.
    /// - Med namnrunda: the round in Mindtalk's window, back to the panel after it.
    /// - A click on the box itself (or an old notification): the start card, waiting.
    func answer(_ answer: Answer, app: String) {
        switch answer {
        case .notForApp:
            // Through the settings page's copy, so its "Frågar inte för …" row shows at once.
            let prefs = AppPrefs.shared
            if !prefs.callAppsMuted.contains(app) { prefs.callAppsMuted.append(app) }
            return
        case .notNow:
            return
        default:
            break
        }
        let meeting = MeetingSession.shared
        // Only for a call still going (an old question isn't a start), and only once.
        guard meeting.phase == .idle, since[app] != nil else { return }
        let ready = VoiceModels.shared.state == .ready && Dictation.shared.engine.isInstalled
        let mode: MeetingSession.StartMode = answer == .startRound ? .round : .direct
        if answer == .openCard || !ready || MeetingSession.preparing(mode) {
            openCard()
            return
        }
        // The very first meeting: the card, with the question about remembering voices
        // already asked for the start that was pressed (nothing records until it's answered).
        if MeetingSession.asksAboutVoices {
            openCard()
            meeting.startFromCard(mode)
            return
        }
        // In no folder (a call isn't the page's), and noted as told: the box says to tell everyone.
        MeetingPanel.shared.startedElsewhere = true
        meeting.start(introducing: mode == .round, folder: nil, informed: true)
        Self.log.notice("calls: started from the question (\(mode == .round ? "round" : "direct", privacy: .public))")
        // It couldn't (the dictation has the mic, say): the card, where it's said why.
        if !meeting.isRecording { openCard() }
    }

    /// From an old notification: a click or its action opens the card.
    func answer(_ action: String, userInfo: [AnyHashable: Any]) {
        guard let app = userInfo["callApp"] as? String, action != UNNotificationDismissActionIdentifier else { return }
        answer(.openCard, app: app)
    }

    private func openCard() {
        MeetingPanel.shared.startedElsewhere = true
        MeetingSession.shared.armed = true
        AppDelegate.showWindow(page: .meetings)
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

// MARK: - The question on screen

/// The box at the top right, under the menu bar, over every window, space and full
/// screen: it takes no focus from the call. A minute, then it goes by itself (the
/// pointer resting on it holds it), and at once when the call ends.
@MainActor
final class CallPrompt {
    static let shared = CallPrompt()
    private var panel: NSPanel?
    private(set) var app: String?
    private var hiding: Task<Void, Never>?
    private var shownAt = Date.distantPast
    /// When it goes by itself.
    private var deadline = Date.distantPast

    func show(_ app: String) {
        close()
        self.app = app
        let view = CallPromptView(app: app, answer: { [weak self] answer in
            // A click meant for the call (its controls are up here in full screen) the
            // moment the box comes doesn't count.
            guard let self, Date().timeIntervalSince(self.shownAt) > 0.7 else { return }
            self.close()
            CallDetector.shared.answer(answer, app: app)
        }, hovering: { [weak self] inside in
            guard let self else { return }
            inside ? self.hold() : self.countDown(seconds: max(20, self.deadline.timeIntervalSinceNow))
        })
        // Takes the first click without becoming key, as the meeting panel does.
        let host = ClickThroughHostingView(rootView: view)
        let size = host.fittingSize
        host.frame.size = size
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // On the screen you're on (the one with the pointer), under its menu bar.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let room = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: room.maxX - size.width - 4, y: room.maxY - size.height - 2))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 1 }
        self.panel = panel
        shownAt = Date()
        AccessibilityNotification.Announcement(CallDetector.title(app) + ". " + CallDetector.question(app)).post()
        countDown(seconds: 60)
    }

    func withdraw(_ apps: [String]) {
        if let app, apps.contains(app) { close() }
    }

    #if DEBUG
    static func preview(_ app: String) -> some View { CallPromptView(app: app, answer: { _ in }, hovering: { _ in }) }
    #endif

    private func hold() {
        hiding?.cancel()
        hiding = nil
    }

    private func countDown(seconds: Double) {
        deadline = Date().addingTimeInterval(seconds)
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        hiding?.cancel()
        hiding = nil
        if let panel {
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        panel = nil
        app = nil
    }
}

/// "Samtal i Teams / Vill du anteckna mötet?" beside the turning sphere, then
/// Starta direkt (ink, with the red dot) and Med namnrunda; ⋯ for Fråga inte för Teams,
/// × for not now. A click elsewhere on it opens the start card.
private struct CallPromptView: View {
    let app: String
    let answer: (CallDetector.Answer) -> Void
    let hovering: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                DotSphere(small: true)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: CallDetector.title(app)).font(.system(size: 13.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: CallDetector.question(app)).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The words take the room there is before ⋯ and ×.
                .layoutPriority(1)
                Spacer(minLength: 6)
                Menu {
                    Button("Fråga inte för \(app)") { answer(.notForApp) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Colors.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Fler val")
                .accessibilityLabel("Fler val")
                Button { answer(.notNow) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(DS.Colors.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Inte nu")
                .accessibilityLabel("Inte nu")
            }
            .contentShape(Rectangle())
            .onTapGesture { answer(.openCard) }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("Öppna startkortet")) { answer(.openCard) }
            HStack(spacing: 8) {
                Button { answer(.startDirect) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(DS.Colors.recording).frame(width: 7, height: 7)
                        Text("Starta direkt")
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(.ink)
                .help("Spelar in nu. Mötet syns i en liten panel ovanpå samtalet.")
                Button { answer(.startRound) } label: { Text("Med namnrunda").lineLimit(1).fixedSize() }
                    .buttonStyle(.soft)
                    .help("Öppnar Mindtalk, där alla säger sitt namn.")
            }
            // Said where you press, as on the start card: the others should know.
            Text("Säg till alla att mötet spelas in.")
                .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Colors.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Colors.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(18)
        .onHover(perform: hovering)
        .accessibilityElement(children: .contain)
    }
}
