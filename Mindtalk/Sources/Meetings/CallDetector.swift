import AppKit
import UserNotifications

// MARK: - A call begins

/// When Teams, Zoom, FaceTime or another call app starts using the microphone, a quiet
/// question: "Samtal i Zoom. Vill du ta anteckningar?" Pressed, it opens the start card,
/// waiting for your choice; nothing is ever recorded before that press. Read from Core
/// Audio's list of processes using an input (no permission, no window titles, no
/// addresses), every three seconds. Asked once a call: an app that keeps its microphone
/// open (Zoom while muted) isn't asked again until it has let it go for a minute.
/// "Inte för Zoom" stops it for that app; Inställningar → Möten turns it all off.
@MainActor
final class CallDetector {
    static let shared = CallDetector()
    static let category = "call"
    static let takeNotes = "call.take-notes"
    static let notForApp = "call.not-for-app"

    /// The apps known to hold calls, by the start of their bundle id. Browsers too:
    /// Meet and Teams on the web are a page using the microphone.
    static let apps: [(prefix: String, name: String, browser: Bool)] = [
        ("us.zoom.xos", "Zoom", false), ("com.microsoft.teams", "Teams", false), ("com.apple.FaceTime", "FaceTime", false),
        ("com.tinyspeck.slackmacgap", "Slack", false), ("com.cisco.webexmeetingsapp", "Webex", false),
        ("Cisco-Systems.Spark", "Webex", false), ("com.hnc.Discord", "Discord", false), ("net.whatsapp.WhatsApp", "WhatsApp", false),
        ("com.skype.skype", "Skype", false), ("com.google.Chrome", "Chrome", true), ("com.apple.Safari", "Safari", true),
        ("com.apple.WebKit", "Safari", true), ("company.thebrowser", "Arc", true), ("org.mozilla.firefox", "Firefox", true),
        ("com.microsoft.edgemac", "Edge", true), ("com.brave.Browser", "Brave", true), ("com.vivaldi.Vivaldi", "Vivaldi", true),
    ]

    /// When each app began using the microphone, while it does.
    private var since: [String: Date] = [:]
    /// When each app was last asked about; kept a minute after it lets the microphone go.
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
                self?.check()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func check() {
        guard Settings.askOnCalls else { since = [:]; return }
        let listening = Set(MediaControl.listeningProcesses().compactMap { Self.app(for: $0.bundleID)?.name })
        let now = Date()
        since = since.filter { listening.contains($0.key) }
        for app in listening where since[app] == nil { since[app] = now }
        asked = asked.filter { listening.contains($0.key) || now.timeIntervalSince($0.value) < 60 }
        // Already taking notes, or dictating: not now.
        guard MeetingSession.shared.phase == .idle, Dictation.shared.phase == .idle else {
            for app in listening { asked[app] = now }
            return
        }
        let muted = Set(Settings.callAppsMuted)
        // Four seconds of it first: a page asking for the mic a moment isn't a call.
        for (app, began) in since where now.timeIntervalSince(began) >= 4 && asked[app] == nil && !muted.contains(app) {
            asked[app] = now
            ask(app)
            return
        }
    }

    private func ask(_ app: String) {
        let browser = Self.apps.first { $0.name == app }?.browser ?? false
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = browser ? String(localized: "\(app) använder mikrofonen") : String(localized: "Samtal i \(app)")
            content.body = browser ? String(localized: "Är det ett möte? Ta anteckningar med Mindtalk.")
                                   : String(localized: "Vill du ta anteckningar med Mindtalk?")
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
            var muted = Settings.callAppsMuted
            if !muted.contains(app) { muted.append(app) }
            Settings.callAppsMuted = muted
        case UNNotificationDismissActionIdentifier:
            break
        default:
            let meeting = MeetingSession.shared
            guard meeting.phase == .idle else { return }
            MeetingPanel.shared.startedElsewhere = true
            meeting.armed = true
            AppDelegate.showWindow(page: .meetings)
        }
    }

    static func app(for bundleID: String) -> (prefix: String, name: String, browser: Bool)? {
        apps.first { bundleID.hasPrefix($0.prefix) }
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
