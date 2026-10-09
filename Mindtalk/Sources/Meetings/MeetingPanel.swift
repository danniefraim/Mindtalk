import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - The meeting panel
//
// A meeting is shown in one place at a time: this narrow panel at the edge of the
// screen, above whatever you're working in — or Mindtalk's large window. It opens
// where you started it: from the menu bar or ⇧⌘R, the panel; from inside the
// window, the window. Arrows in each take you to the other, and closing the
// window during a meeting brings the panel back, so a running recording is never
// out of sight unless you closed the panel yourself.
//
// The panel never takes the keyboard from the app you're in, and Mindtalk never
// brings itself forward when a meeting is written out: the panel says it's done,
// or a notification does if you had put the panel away.

@MainActor
final class MeetingPanel: ObservableObject {
    static let shared = MeetingPanel()

    /// Where the meeting is shown while it runs.
    enum Home { case panel, window }

    /// Shown in the panel after a meeting: open the notes, or nothing was kept.
    enum Done: Equatable {
        case meeting(id: UUID, title: String)
        case nothingHeard
    }

    @Published private(set) var isVisible = false
    @Published private(set) var done: Done?

    private var panel: NSPanel?
    private var watching: AnyCancellable?
    private var home: Home = .panel
    private var wasRecording = false
    private var wasBusy = false
    /// A meeting was recorded since the last "done" — its end is told even if the
    /// panel was closed meanwhile (by then it's no longer recording, only finishing).
    private var meetingRan = false
    /// The round was opened in the window from the panel: the meeting goes back after it.
    private var returnToPanel = false
    private var watchingRound: AnyCancellable?

    private init() {}

    /// Follows the meeting: the panel comes with it and says when it's done.
    func watch() {
        #if DEBUG
        // Screenshots of the large window keep the meeting there; `--demo-panel` shows this one.
        if CommandLine.arguments.contains("--demo-meeting"), !CommandLine.arguments.contains("--demo-panel") { return }
        #endif
        watching = MeetingSession.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.phaseChanged() }
        watchingRound = MeetingSession.shared.$introducing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.roundChanged(on) }
    }

    /// "Presentationsrunda" from the panel: the round needs the room's screen.
    func roundInWindow() {
        let session = MeetingSession.shared
        guard session.isRecording else { return }
        returnToPanel = true
        session.introduce()
        expand()
    }

    private func roundChanged(_ on: Bool) {
        guard !on, returnToPanel else { return }
        returnToPanel = false
        // Back where the meeting was, and the keyboard to the app you were in.
        collapse(closingWindow: true)
        NSApp.deactivate()
    }

    private func phaseChanged() {
        let session = MeetingSession.shared
        let recording = session.isRecording, busy = session.isBusy
        defer { wasRecording = recording; wasBusy = busy }
        if recording, !wasRecording {
            // A meeting starts — where you started it. ("Gör klart" on an interrupted
            // meeting is busy without recording and stays in the window.)
            done = nil
            meetingRan = true
            home = AppDelegate.mainWindowIsKey ? .window : .panel
            if home == .panel, session.introducing {
                // Started from elsewhere (the menu bar, the shortcut): the round in the
                // window, the meeting in the panel after it.
                returnToPanel = true
                expand()
            } else if home == .panel {
                if AppDelegate.mainWindowVisible { AppDelegate.hideMainWindow() }   // behind your work anyway
                show()
            }
        } else if !busy, wasBusy, meetingRan || wasRecording || isVisible {
            meetingRan = false
            finished(session.finished)
        }
    }

    /// Written out. Nothing comes forward on its own: the window stays if that's
    /// where the meeting was; the panel says it's done; put away, a notification does.
    private func finished(_ id: UUID?) {
        guard !AppDelegate.isQuitting else { return }
        if home == .window, AppDelegate.mainWindowVisible { return }
        let record = id.flatMap { id in MeetingStore.shared.meetings.first { $0.id == id } }
        done = record.map { .meeting(id: $0.id, title: $0.title) } ?? .nothingHeard
        if isVisible { return }
        guard let record else { return }
        Self.notify(record)
    }

    // MARK: Showing and hiding

    func show() {
        guard MeetingSession.shared.isBusy || done != nil else { return }
        let panel = self.panel ?? make()
        self.panel = panel
        if !panel.isVisible { place(panel) }
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Put away: the recording goes on, the menu bar shows it.
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        if done != nil { done = nil }
    }

    /// The meeting in the large window instead, with the timeline and all of it.
    func expand() {
        let id: UUID?
        if case .meeting(let doneID, _) = done { id = doneID } else { id = nil }
        hide()
        home = .window
        if let id { MeetingsPage.lastOpen = id }
        AppDelegate.showWindow(page: .meetings)
    }

    /// Set once the panel has been used: the window stops explaining it.
    static let tipSeenKey = "meetingPanelTipSeen"

    /// Back from the window to the panel — "Visa som panel" in the window, or closing it.
    func collapse(closingWindow: Bool = true) {
        guard MeetingSession.shared.isBusy else { return }
        if MeetingSession.shared.introducing { returnToPanel = false; MeetingSession.shared.endIntroduction() }
        UserDefaults.standard.set(true, forKey: Self.tipSeenKey)
        home = .panel
        if closingWindow, AppDelegate.mainWindowVisible { AppDelegate.hideMainWindow() }
        show()
    }

    /// The large window was closed while a meeting runs: the panel takes over.
    func mainWindowClosed() {
        // The round lives in the window: closing it ends the round, the meeting goes on.
        if MeetingSession.shared.introducing { returnToPanel = false; MeetingSession.shared.endIntroduction() }
        guard MeetingSession.shared.isBusy, home == .window else { return }
        UserDefaults.standard.set(true, forKey: Self.tipSeenKey)
        home = .panel
        show()
    }

    // MARK: The window itself

    private func make() -> NSPanel {
        let size = NSSize(width: 380, height: 600)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 480)     // the header, a card and the island fit
        panel.maxSize = NSSize(width: 560, height: 1400)
        // Buttons answer the first click although the panel never becomes active.
        let host = ClickThroughHostingView(
            rootView: MeetingPanelView(session: .shared, panel: self,
                                       expand: { [weak self] in self?.expand() },
                                       close: { [weak self] in self?.hide() }))
        // The panel's size is yours (and fits the screen); a long transcript scrolls
        // inside it rather than stretching the panel past the bottom of the screen.
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(size)
        panel.setFrameAutosaveName("MindtalkMeetingPanel")
        return panel
    }

    /// At the right edge of the screen the mouse is on, as tall as fits — or where
    /// you last put it, if that is still on a screen.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if panel.setFrameUsingName("MindtalkMeetingPanel"),
           let home = NSScreen.screens.max(by: { a, b in
               let x = a.visibleFrame.intersection(panel.frame), y = b.visibleFrame.intersection(panel.frame)
               return x.width * x.height < y.width * y.height
           }), home.visibleFrame.intersects(panel.frame.insetBy(dx: 40, dy: 40)) {
            // Where you put it — but whole on the screen it's mostly on.
            let room = home.visibleFrame
            var frame = panel.frame
            frame.size.width = min(frame.width, room.width)
            frame.size.height = min(frame.height, room.height)
            frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
            if frame != panel.frame { panel.setFrame(frame, display: false) }
            return
        }
        let size = NSSize(width: 380, height: min(720, visible.height - 48))
        panel.setFrame(NSRect(x: visible.maxX - size.width - 20, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
    }

    /// "Mötet är klart" — when the panel was put away. Asks to notify the first time.
    private static func notify(_ record: MeetingRecord) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Mötet är klart")
            content.body = record.title
            content.userInfo = ["meeting": record.id.uuidString]
            center.add(UNNotificationRequest(identifier: "meeting-\(record.id.uuidString)", content: content, trigger: nil))
        }
    }

    /// The notification was clicked: the notes.
    func openFromNotification(_ userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["meeting"] as? String, let id = UUID(uuidString: raw) else { return }
        MeetingsPage.lastOpen = id
        AppDelegate.showWindow(page: .meetings)
    }
}

/// Floats beside your work. It takes the keyboard only when you click into your
/// notes (becomesKeyOnlyIfNeeded), and even then Mindtalk doesn't become the
/// active app — the one you were in stays in front.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - What it shows

struct MeetingPanelView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var panel: MeetingPanel
    let expand: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if let done = panel.done, !session.isBusy {
                DonePanel(done: done, expand: expand, close: close)
            } else if panel.isVisible {
                // Each meeting starts the panel afresh: the reminder, following the text.
                LivePanel(session: session, expand: expand, close: close)
                    .id(session.startedAt)
            } else {
                Color.clear          // put away: nothing to lay out
            }
        }
        .background(DS.Colors.paper)
        .ignoresSafeArea()          // no title bar: the header is the top
    }
}

/// The meeting as it's recorded: recording, how long, the room heard, the text, stop.
private struct LivePanel: View {
    @ObservedObject var session: MeetingSession
    let expand: () -> Void
    let close: () -> Void
    @State private var atBottom = true
    /// As in the window: following the newest text until you scroll up yourself —
    /// not decided by where the view happens to be when the panel's room changes.
    @State private var following = true
    @State private var userScrolling = false

    var body: some View {
        let record = session.record
        let cast = record?.cast ?? Cast(words: [], names: [:])
        let turns = MeetingText.turns(record?.words ?? [], pending: session.pending, paragraphs: true)
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.Colors.divider).frame(height: 0.5)
            transcript(turns, cast)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if session.isRecording {
                RecordingDot()
                if let start = session.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(MeetingView.duration(context.date.timeIntervalSince(start)))
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                            .accessibilityLabel("Spelar in, \(MeetingView.spoken(context.date.timeIntervalSince(start)))")
                    }
                }
                PanelWave().frame(width: 84, height: 18).accessibilityHidden(true)
            } else {
                Text(session.record?.title ?? "").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 8)
            PanelIconButton(symbol: "pip.exit", help: "Visa i Mindtalks fönster", action: expand)
            PanelIconButton(symbol: "xmark", help: "Stäng panelen – inspelningen fortsätter", action: close)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 50)
    }

    private func transcript(_ turns: [MeetingTurn], _ cast: Cast) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if turns.isEmpty { empty }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        let newSpeaker = i == 0 || turns[i - 1].speaker != turn.speaker
                        let next = i + 1 < turns.count ? turns[i + 1].start : .infinity
                        PanelTurn(turn: turn, cast: cast, showName: newSpeaker,
                                  marks: (session.record?.marks ?? []).filter { $0.at >= (i == 0 ? -.infinity : turn.start) && $0.at < next },
                                  removeMark: { id in session.removeMark(id) },
                                  recognized: turn.speaker.map { session.record?.recognized[String($0)] != nil } ?? false,
                                  rename: { s, name in session.name(speaker: s, as: name) },
                                  merge: { s, other in withAnimation(.snappy) { session.merge(s, into: other) } })
                            .padding(.top, i == 0 ? 0 : newSpeaker ? 20 : 10)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 16).id("end")      // air under the last words
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            // Opened mid-meeting (from the menu bar): at the latest words.
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, bottom in
                atBottom = bottom
                if bottom { following = true }
            }
            // A mouse wheel or the keys: moved up with the text unchanged — reading back.
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentSize.height] } action: { old, new in
                if new[1] == old[1], new[0] < old[0] - 4, !atBottom { following = false }
            }
            // Only your own scrolling stops the following: where it ends decides.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: userScrolling = true
                case .idle:
                    if userScrolling { userScrolling = false; following = atBottom }
                default: break
                }
            }
            // Follow the conversation — when the text grows (words, a name row, a mark)
            // or the room for it shrinks (a card below appears).
            .onScrollGeometryChange(for: [CGFloat].self) { geo in [geo.contentSize.height, geo.containerSize.height] } action: { old, new in
                guard following, !userScrolling, new != old else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !following, !turns.isEmpty {
                    Button {
                        following = true
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Label("Till nu", systemImage: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Colors.onInk)
                            .padding(.horizontal, 13)
                            .frame(height: 28)
                            .background(Capsule().fill(DS.Colors.ink))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: following)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(DS.Colors.faint)
            if session.phase == .starting {
                Text("Förbereder…").font(.system(size: 14, weight: .semibold))
                Text("Inspelningen är redan igång – inget går förlorat.")
            } else {
                Text("Lyssnar").font(.system(size: 14, weight: .semibold))
                Text("Börja prata, så dyker texten upp här.")
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(DS.Colors.muted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let warning = session.warning, session.isRecording {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            if session.isRecording {
                OpeningCard(session: session, compact: true) { MeetingPanel.shared.roundInWindow() }
            }
            switch session.phase {
            case .finishing(let what):
                HStack(spacing: 12) {
                    SettlingLine(color: .white)
                    Text(what).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(Color(white: 0.07)))
                .accessibilityElement(children: .combine)
            default:
                if session.stopping {
                    Text("Spelar in tills nedräkningen är klar.")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.muted)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                    StopCountdown(session: session, onDark: true)
                        .padding(.leading, 18)
                        .padding(.trailing, 7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Color(white: 0.07)))
                        .transition(.opacity)
                } else if session.isRecording {
                    // As in the window: one island — your note, the marks, stop. (The
                    // time is at the top of the panel.)
                    NoteIsland(session: session, compact: true) { EmptyView() } trailing: {
                        Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold))
                                Text("Avsluta").font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(.white))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Avsluta mötet – du kan ångra i några sekunder")
                        .accessibilityLabel("Avsluta mötet")
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(DS.Colors.divider).frame(height: 0.5) }
        .animation(.easeOut(duration: 0.2), value: session.warning)
        // Read out when a warning appears, as in the window.
        .onChange(of: session.warning) { _, w in
            if let w, session.isRecording { AccessibilityNotification.Announcement(w).post() }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: session.stopping)
    }
}

/// After the meeting: it's written — open the notes, or put the panel away.
private struct DonePanel: View {
    let done: MeetingPanel.Done
    let expand: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                PanelIconButton(symbol: "xmark", help: "Stäng panelen", action: close)
            }
            .padding(.trailing, 12)
            .frame(height: 50)
            Spacer()
            VStack(spacing: 10) {
                switch done {
                case .meeting(_, let title):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(DS.Colors.good)
                    Text("Mötet är klart").font(.system(size: 16, weight: .semibold))
                    Text(title).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Button(action: expand) {
                        Text("Öppna anteckningarna")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(DS.Colors.onInk)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 40)
                            .background(Capsule().fill(DS.Colors.ink))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                case .nothingHeard:
                    Image(systemName: "waveform.slash").font(.system(size: 28)).foregroundStyle(DS.Colors.faint)
                    Text("Inget hördes").font(.system(size: 16, weight: .semibold))
                    Text("Mötet var för kort för att sparas.").font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DS.Colors.muted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(DS.Colors.card))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One turn in the panel: who, then what they said — what's still being written in grey.
private struct PanelTurn: View {
    let turn: MeetingTurn
    let cast: Cast
    let showName: Bool
    /// What you marked while this was said.
    var marks: [MeetingRecord.Mark] = []
    var removeMark: ((UUID) -> Void)? = nil
    /// Click the name to give or correct it, as in the window.
    var recognized = false
    var rename: ((Int, String) -> Void)? = nil
    var merge: ((Int, Int) -> Void)? = nil

    private var speaker: Int? { turn.speaker.flatMap { $0 >= 0 ? $0 : nil } }

    /// As in the window: a thin line in the speaker's colour beside what they said.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showName {
                HStack(spacing: 7) {
                    if let speaker, let rename, let merge {
                        SpeakerChip(speaker: speaker, cast: cast, recognized: recognized, style: .name,
                                    rename: { rename(speaker, $0) }, merge: { merge(speaker, $0) })
                    } else {
                        Text(speaker.map { cast.name(of: $0) } ?? String(localized: "Känner igen rösten…"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SpeakerMark.ink(of: speaker, in: cast))
                    }
                    Text(MeetingView.duration(turn.start))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.faint)
                }
                .accessibilityElement(children: .combine)
            }
            text
                // Words settle from grey into ink rather than switching.
                .contentTransition(.interpolate)
                .font(.system(size: 14.5))
                .lineSpacing(4.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The text grows with its words, rather than snapping to the new size.
                .animation(.smooth(duration: 0.4), value: turn.text)
            if !marks.isEmpty {
                MarkChips(marks: marks, compact: true, remove: removeMark)
                    .padding(.top, 2)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .padding(.leading, 13)
        .background(alignment: .leading) {
            Capsule().fill(SpeakerMark.color(of: speaker, in: cast).opacity(speaker == nil ? 0.6 : 1)).frame(width: 2.5)
        }
    }

    private var text: Text {
        var out = turn.spoken(cast: cast)
        if !turn.pending.isEmpty {
            let pending = Text(turn.text.isEmpty ? turn.pending : " " + turn.pending).foregroundStyle(DS.Colors.muted)
            out = Text("\(out)\(pending)")
        }
        return out
    }
}

/// The room's sound in ink — observing only the level, so the text doesn't redraw with it.
private struct PanelWave: View {
    @ObservedObject private var meter = LiveMeter.shared
    var body: some View {
        Waveform(levels: meter.levels, gap: 2.5, color: DS.Colors.ink)
    }
}

/// Counts the times the large window is shown again after being closed.
///
/// macOS draws selectable text upside down when it was added or changed while its
/// window was closed — as happens when a meeting goes on in the panel. Views
/// with such text take this as their identity, so they are built anew, right side
/// up, each time the window comes back.
@MainActor
final class WindowEpoch: ObservableObject {
    static let shared = WindowEpoch()
    @Published private(set) var value = 0
    func reopened() { value += 1 }
}
