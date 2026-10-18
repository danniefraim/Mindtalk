import ServiceManagement
import SwiftUI

// MARK: - Din första dag
//
// Right after the introduction, a card on Hem with the three things Mindtalk does,
// each ticked off by what you've actually done — words in the statistics, a thought
// in Tankar, a meeting in Möten. Nothing new is tracked. It goes when all three are
// done (after a short "Allt klart"), a week after it first showed, or when you close
// it. A Mac with words or thoughts from before today never sees it.

struct FirstDayCard: View {
    @ObservedObject var dictation: Dictation
    @Binding var page: Page
    @ObservedObject private var stats = Stats.shared
    @ObservedObject private var thoughts = Thoughts.shared
    @ObservedObject private var store = MeetingStore.shared
    /// When the card first showed (seconds since 1970); 0 = not yet.
    @AppStorage("firstDayShownAt") private var shownAt: Double = 0
    @AppStorage("firstDayCelebrated") private var celebrated = false
    /// Gone for good: closed with ✕, or everything done.
    @AppStorage("firstDayClosed") private var closed = false
    @State private var celebrating = false
    @State private var windowVisible = true
    @State private var startsAtLogin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A week from the first time it showed.
    private static let lasts: TimeInterval = 7 * 86_400

    /// Whether the card is on Hem right now. The hero reads it: while the card teaches
    /// the three steps, the hero welcomes instead of saying the dictation key a third time.
    @MainActor final class Presence: ObservableObject {
        static let shared = Presence()
        @Published fileprivate(set) var showing = false
    }

    private struct Steps: Equatable {
        var dictated: Bool, thought: Bool, meeting: Bool
        var count: Int { [dictated, thought, meeting].filter { $0 }.count }
        var all: Bool { count == 3 }
    }

    private var steps: Steps {
        #if DEBUG
        if HomeDebug.firstDayDone { return Steps(dictated: true, thought: true, meeting: true) }
        if HomeDebug.firstDay { return Steps(dictated: true, thought: false, meeting: false) }
        #endif
        // A dictation typed somewhere (a thought's words count on the tile, not here), a
        // thought with its text in place, a meeting kept.
        return Steps(dictated: dictation.dictatedOnce,
                     thought: thoughts.all.contains { $0.deleted == nil && $0.writing == nil && !$0.text.isEmpty },
                     meeting: !store.meetings.isEmpty)
    }

    /// Went through the introduction (the day it was done is kept) and has nothing from
    /// before that day: no dictated words, thoughts or meetings. Someone updating from an
    /// earlier version never had the day saved — and never sees the card.
    private var isNewUser: Bool {
        guard let finished = UserDefaults.standard.object(forKey: "introFinishedAt") as? Double else { return false }
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: finished))
        let firstDay = Stats.key(for: start)
        return !stats.days.contains { $0.key < firstDay && $0.value.words > 0 }
            && !thoughts.all.contains { $0.date < start }
            && !store.meetings.contains { $0.date < start }
    }

    private var visible: Bool {
        #if DEBUG
        if HomeDebug.firstDay || HomeDebug.firstDayDone { return true }
        if Demo.on { return false }
        #endif
        // After the setup, and the meetings read, so a meeting from before doesn't flash
        // as not done. The first time, only with the speech model up; once shown it stays
        // through a language switch.
        guard !closed, !dictation.needsSetup, store.loaded else { return false }
        if shownAt == 0, dictation.model != .ready { return false }
        // Celebrated once already (quit during "Allt klart"): not again.
        if celebrated, !celebrating { return false }
        if shownAt > 0 { return celebrating || Date().timeIntervalSince1970 - shownAt < Self.lasts }
        return isNewUser && !steps.all
    }

    var body: some View {
        if visible {
            card
                .onAppear {
                    startsAtLogin = SMAppService.mainApp.status == .enabled
                    windowVisible = AppDelegate.mainWindowVisible
                    #if DEBUG
                    if HomeDebug.firstDay || HomeDebug.firstDayDone { celebrating = HomeDebug.firstDayDone; return }   // screenshots: never saved
                    #endif
                    if shownAt == 0 { shownAt = Date().timeIntervalSince1970 }
                    celebrateIfDone()
                }
                .onAppear { Presence.shared.showing = true }
                .onDisappear { Presence.shared.showing = false }
                .onChange(of: steps) { celebrateIfDone() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                    guard let window = note.object as? NSWindow, window.contentViewController is NSHostingController<MainView> else { return }
                    windowVisible = window.occlusionState.contains(.visible)
                    celebrateIfDone()
                }
                .transition(.opacity)
        }
    }

    /// All three done: "Allt klart" for a few seconds, then the card goes. Only while
    /// you can see it — done with the window closed, it waits for you.
    private func celebrateIfDone() {
        #if DEBUG
        if HomeDebug.firstDay || HomeDebug.firstDayDone { return }
        #endif
        guard steps.all, !celebrating, windowVisible else { return }
        celebrated = true
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) { celebrating = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { closed = true }
        }
    }

    /// A compact card: the name in small capitals and "1/3" on one line, then one line
    /// per step — a numbered ring or an ink check, the step, and how, with the key as
    /// a chip — and a way to the page on the steps still open.
    private var card: some View {
        let s = steps
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: String(localized: "Din första dag").uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(DS.Colors.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if celebrating {
                    Text("Allt klart, nu kör du.").font(.system(size: 13, weight: .medium))
                        .transition(.opacity)
                } else {
                    Text(verbatim: "\(s.count)/3").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                        .accessibilityLabel(Text("\(s.count) av 3 klart"))
                    CloseButton { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { closed = true } }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)

            row(1, done: s.dictated, title: "Diktera", link: nil) {
                Text(verbatim: pressVerb)
                KeyChip(text: dictation.hotkey.chip, small: true)
                Text("i vilken app som helst och prata")
            }
            row(2, done: s.thought, title: "Säg en tanke", link: ("Öppna Tankar →", { page = .thoughts })) {
                if let keys = Settings.thoughtShortcut?.chip {
                    Text("Håll in")
                    KeyChip(text: keys, small: true)
                    Text("och prata, så hamnar den i Tankar")
                } else {
                    Text("Säg den på sidan Tankar")
                }
            }
            row(3, done: s.meeting, title: "Spela in ett möte", link: ("Öppna Möten →", { page = .meetings })) {
                Text("Här eller från menyraden")
            }

            // Where Mindtalk goes when the window closes — said before you close it.
            HStack(alignment: .center, spacing: 10) {
                MenuBarChip()
                Text(verbatim: String(localized: "Mindtalk bor i menyraden och fortsätter när du stänger fönstret.")
                     + (startsAtLogin ? " " + String(localized: "Den startar när du loggar in. Ändra under Inställningar.") : ""))
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 13)
            .background(alignment: .top) { Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.horizontal, 24) }
            .padding(.top, 10)
        }
        .padding(.bottom, 4)
        .tile()
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: s)
    }

    // MARK: Rows

    /// "Håll in" or "Tryck på", as the dictation key works.
    private var pressVerb: String {
        dictation.mode == .toggle ? String(localized: "Tryck på") : String(localized: "Håll in")
    }

    private func row<Hint: View>(_ number: Int, done: Bool, title: LocalizedStringKey,
                                 link: (title: LocalizedStringKey, action: () -> Void)?,
                                 @ViewBuilder hint: () -> Hint) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Tick(number: number, done: done)
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(done ? DS.Colors.muted : .primary)
                    Text(verbatim: "·").foregroundStyle(DS.Colors.faint)
                    hint()
                }
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(done ? Text("Klart") : Text("Inte gjort än"))
            Spacer(minLength: 12)
            if !done, let link {
                Button(link.title, action: link.action).buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 7)
    }

    /// A ring with the step's number, then an ink disc with a check when it's done.
    private struct Tick: View {
        let number: Int
        let done: Bool
        var body: some View {
            ZStack {
                Circle().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1.5).opacity(done ? 0 : 1)
                Text(verbatim: "\(number)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Colors.muted).opacity(done ? 0 : 1)
                Circle().fill(DS.Colors.ink).scaleEffect(done ? 1 : 0.4).opacity(done ? 1 : 0)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.onInk)
                    .scaleEffect(done ? 1 : 0.4).opacity(done ? 1 : 0)
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
        }
    }

    /// ✕ — "Dölj".
    private struct CloseButton: View {
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Colors.muted)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(hovering ? DS.Colors.chip : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Dölj")
            .accessibilityLabel("Dölj")
        }
    }
}

/// Mindtalk's menu-bar icon in a sliver of menu bar — "it's up there".
struct MenuBarChip: View {
    var body: some View {
        Image(nsImage: Mark.menuBarImage)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 12)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.Colors.chip))
            .accessibilityHidden(true)
    }
}

// MARK: - Screenshots (debug builds)

/// Hem in states this Mac isn't in, for `--render-home`: `--first-day` (one of three
/// done), `--fresh` (with it: nothing said yet, the hero welcomes), `--first-day-done`
/// (Allt klart), `--model-loading` (the speech model being made ready, three minutes
/// in), `--model-preparing` (the download's last step) and `--menubar-hint` (the bubble
/// from the menu bar, under the page). Nothing is saved.
enum HomeDebug {
    #if DEBUG
    nonisolated static let firstDay = CommandLine.arguments.contains("--first-day")
    nonisolated static let fresh = CommandLine.arguments.contains("--fresh")
    nonisolated static let firstDayDone = CommandLine.arguments.contains("--first-day-done")
    nonisolated static let modelLoading = CommandLine.arguments.contains("--model-loading")
    nonisolated static let modelPreparing = CommandLine.arguments.contains("--model-preparing")
    nonisolated static let menuBarHint = CommandLine.arguments.contains("--menubar-hint")
    /// Past the setup: an unsigned build has no permissions to show the rest with.
    nonisolated static var ready: Bool { firstDay || firstDayDone || modelLoading }
    #endif
}
