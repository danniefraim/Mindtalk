import AppKit
import Combine
import Sparkle

// MARK: - Updates
//
// Sparkle checks the appcast on GitHub (SUFeedURL in Info.plist) once a day.
// Every update is signed with Mindtalk's own EdDSA key; the app only installs
// one whose signature matches SUPublicEDKey — and, as always, Apple's
// notarization. The private key lives in the developer's keychain (account
// "mindtalk") and signs each release in scripts/release.sh.

@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updates()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    /// An update waiting to install until the meeting being recorded is over.
    private var postponed: (() -> Void)?

    /// A newer version found by a scheduled check — shown in the menu bar panel,
    /// since Sparkle's window may be behind other apps.
    @Published private(set) var available: String?

    /// Look for updates on its own, once a day.
    @Published var automatic = false {
        didSet { if controller.updater.automaticallyChecksForUpdates != automatic { controller.updater.automaticallyChecksForUpdates = automatic } }
    }

    func start() {
        #if DEBUG
        return   // debug builds never update themselves
        #else
        do {
            try controller.updater.start()
            automatic = controller.updater.automaticallyChecksForUpdates
        } catch {
            NSLog("Mindtalk: updates unavailable: \(error.localizedDescription)")
        }
        #endif
    }

    /// "Sök efter uppdateringar…"
    @objc func checkNow() {
        #if DEBUG
        NSSound.beep()   // debug builds don't update
        #else
        available = nil
        NSApp.activate()
        controller.checkForUpdates(nil)
        #endif
    }

    /// Never restart for an update in the middle of a meeting: it installs when
    /// the meeting is over.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard MeetingSession.shared.isBusy else { return false }
            postponed = installHandler
            return true
        }
    }

    func meetingEnded() {
        let install = postponed
        postponed = nil
        install?()
    }

    // A menu bar app: a scheduled update is shown without taking focus — you may be
    // dictating into another app. Only a check you asked for brings Mindtalk forward.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            if state.userInitiated { NSApp.activate() } else { Updates.shared.available = version }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in Updates.shared.available = nil }
    }
}
