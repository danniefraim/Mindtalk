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
        return Steps(dictated: stats.totalWords > 0, thought: thoughts.all.contains { $0.deleted == nil }, meeting: !store.meetings.isEmpty)
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
        // After the setup, with the speech model up — and the meetings read, so a
        // meeting from before doesn't flash as not done.
        guard !closed, !dictation.needsSetup, dictation.model == .ready, store.loaded else { return false }
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

    private var card: some View {
        let s = steps
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(celebrating ? "Allt klart – nu kör du." : "Din första dag")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !celebrating {
                    Text("\(s.count) av 3").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                        .accessibilityLabel(Text("\(s.count) av 3 klart"))
                    CloseButton { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { closed = true } }
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 8)

            row(done: s.dictated, title: "Diktera", detail: dictateDetail) { EmptyView() }
            CardDivider()
            row(done: s.thought, title: "Säg en tanke", detail: thoughtDetail) {
                Button("Öppna Tankar") { page = .thoughts }.buttonStyle(SoftButtonStyle(small: true))
            }
            CardDivider()
            row(done: s.meeting, title: "Spela in ett möte", detail: String(localized: "Starta här eller från menyraden.")) {
                Button("Öppna Möten") { page = .meetings }.buttonStyle(SoftButtonStyle(small: true))
            }

            // Where Mindtalk goes when the window closes — said before you close it.
            HStack(alignment: .top, spacing: 10) {
                MenuBarChip().padding(.top, -1)
                Text(verbatim: String(localized: "Mindtalk bor i menyraden och fortsätter när du stänger fönstret.")
                     + (startsAtLogin ? " " + String(localized: "Den startar när du loggar in – ändra under Inställningar.") : ""))
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(alignment: .top) { Rectangle().fill(DS.Colors.divider).frame(height: 1) }
            .padding(.top, 6)
        }
        .raised(cornerRadius: 20)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: s)
    }

    // MARK: Rows

    private var dictateDetail: String {
        let key = dictation.hotkey.inlineName
        return dictation.mode == .toggle
            ? String(localized: "Tryck på \(key) i vilken app som helst och prata.")
            : String(localized: "Håll in \(key) i vilken app som helst och prata.")
    }

    private var thoughtDetail: String {
        guard let keys = Settings.thoughtShortcut?.inlineName else {
            return String(localized: "Säg en tanke på sidan Tankar.")
        }
        return String(localized: "Håll in \(keys) och prata – tanken hamnar i Tankar.")
    }

    private func row<A: View>(done: Bool, title: LocalizedStringKey, detail: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Tick(done: done)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(done ? DS.Colors.muted : .primary)
                    Text(verbatim: detail).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(done ? Text("Klart") : Text("Inte gjort än"))
            Spacer(minLength: 12)
            if !done { action() }
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
    }

    /// An empty ring, then an ink disc with a check when it's done.
    private struct Tick: View {
        let done: Bool
        var body: some View {
            ZStack {
                Circle().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1.5).opacity(done ? 0 : 1)
                Circle().fill(DS.Colors.ink).scaleEffect(done ? 1 : 0.4).opacity(done ? 1 : 0)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.onInk)
                    .scaleEffect(done ? 1 : 0.4).opacity(done ? 1 : 0)
            }
            .frame(width: 22, height: 22)
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
/// done), `--first-day-done` (Allt klart), `--model-loading` (the speech model being
/// made ready, three minutes in), `--model-preparing` (the download's last step) and
/// `--menubar-hint` (the bubble from the menu bar, under the page). Nothing is saved.
enum HomeDebug {
    #if DEBUG
    nonisolated static let firstDay = CommandLine.arguments.contains("--first-day")
    nonisolated static let firstDayDone = CommandLine.arguments.contains("--first-day-done")
    nonisolated static let modelLoading = CommandLine.arguments.contains("--model-loading")
    nonisolated static let modelPreparing = CommandLine.arguments.contains("--model-preparing")
    nonisolated static let menuBarHint = CommandLine.arguments.contains("--menubar-hint")
    /// Past the setup: an unsigned build has no permissions to show the rest with.
    nonisolated static var ready: Bool { firstDay || firstDayDone || modelLoading }
    #endif
}
