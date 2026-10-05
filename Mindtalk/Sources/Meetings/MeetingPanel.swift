import AppKit
import Combine
import SwiftUI

// MARK: - The meeting panel
//
// While a meeting is recorded it lives in a narrow panel at the right edge of the
// screen, above whatever you're working in: the time, that the room is heard, the
// text as it's written with who is speaking, and stop. The large window is one
// click away, and it's where the finished meeting opens — with the summary.
//
// The panel never takes the keyboard from the app you're in.

@MainActor
final class MeetingPanel {
    static let shared = MeetingPanel()

    private var panel: NSPanel?
    private var watching: AnyCancellable?
    private var wasBusy = false

    private init() {}

    /// Follows the meeting: the panel comes with it and leaves when it's written out.
    func watch() {
        #if DEBUG
        // Screenshots of the large window keep the meeting there; `--demo-panel` shows this one.
        if CommandLine.arguments.contains("--demo-meeting"), !CommandLine.arguments.contains("--demo-panel") { return }
        #endif
        watching = MeetingSession.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.phaseChanged(phase) }
    }

    private func phaseChanged(_ phase: MeetingSession.Phase) {
        let busy = phase != .idle
        defer { wasBusy = busy }
        if busy, !wasBusy {
            // The meeting moves into the panel; the large window steps aside.
            AppDelegate.hideMainWindow()
            show()
        } else if !busy, wasBusy {
            hide()
            // Written out: the large window, on the meeting and its summary.
            if let id = MeetingSession.shared.finished {
                MeetingsPage.lastOpen = id
                AppDelegate.showWindow(page: .meetings)
            }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        guard MeetingSession.shared.isBusy else { return }
        let panel = self.panel ?? make()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// The meeting in the large window instead, with the timeline and all of it.
    func expand() {
        hide()
        AppDelegate.showWindow(page: .meetings)
    }

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
        panel.minSize = NSSize(width: 320, height: 360)
        panel.maxSize = NSSize(width: 560, height: 1400)
        panel.contentViewController = NSHostingController(
            rootView: MeetingPanelView(session: .shared,
                                       expand: { [weak self] in self?.expand() },
                                       close: { [weak self] in self?.hide() }))
        panel.setContentSize(size)
        // At the right edge of the screen you're on, as tall as fits — unless you've
        // put it somewhere yourself before.
        if !panel.setFrameUsingName("MindtalkMeetingPanel") {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let height = min(size.height + 120, screen.height - 48)
            panel.setFrame(NSRect(x: screen.maxX - size.width - 20, y: screen.midY - height / 2,
                                  width: size.width, height: height), display: false)
        }
        panel.setFrameAutosaveName("MindtalkMeetingPanel")
        return panel
    }
}

/// Floats without becoming the app you type in; takes a click on its buttons.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - What it shows

struct MeetingPanelView: View {
    @ObservedObject var session: MeetingSession
    let expand: () -> Void
    let close: () -> Void
    @State private var atBottom = true
    @State private var consent = true

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
        .background(DS.Colors.paper)
        .ignoresSafeArea()          // no title bar: the header is the top
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { withAnimation(.easeOut(duration: 0.4)) { consent = false } }
        }
    }

    // MARK: Header — recording, for how long, and that the room is heard

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
            iconButton("arrow.up.left.and.arrow.down.right", help: "Visa i Mindtalks fönster", action: expand)
            iconButton("xmark", help: "Stäng panelen – inspelningen fortsätter", action: close)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 50)
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
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

    // MARK: The text, as it's written

    private func transcript(_ turns: [MeetingTurn], _ cast: Cast) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if consent, session.isRecording {
                        Label("Berätta för de andra att mötet spelas in.", systemImage: "person.2.wave.2")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DS.Colors.muted)
                            .padding(.bottom, 14)
                            .transition(.opacity)
                    }
                    if turns.isEmpty { empty }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        let newSpeaker = i == 0 || turns[i - 1].speaker != turn.speaker
                        PanelTurn(turn: turn, cast: cast, showName: newSpeaker, isLast: i == turns.count - 1)
                            .padding(.top, i == 0 ? 0 : newSpeaker ? 18 : 5)
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
            }
            // Follow the conversation — unless you've scrolled up to read.
            .onChange(of: (session.record?.words.count ?? 0) + (turns.last?.pending.count ?? 0)) { _, _ in
                guard atBottom else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !atBottom, !turns.isEmpty {
                    Button {
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
            .animation(.spring(duration: 0.35, bounce: 0.15), value: atBottom)
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

    // MARK: Footer — a word when something needs attention, and stop

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
            switch session.phase {
            case .finishing(let what):
                HStack(spacing: 12) {
                    SettlingLine(color: DS.Colors.onInk)
                    Text(what).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.onInk)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(DS.Colors.ink))
                .accessibilityElement(children: .combine)
            default:
                Button { session.requestStop() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill").font(.system(size: 10.5, weight: .bold))
                        Text(session.stopArmed ? "Tryck igen för att avsluta" : "Avsluta mötet")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(DS.Colors.onInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(DS.Colors.ink))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Avsluta mötet (⇧⌘R)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(DS.Colors.paper)
        .overlay(alignment: .top) { Rectangle().fill(DS.Colors.divider).frame(height: 0.5) }
        .animation(.easeOut(duration: 0.2), value: session.warning)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: session.stopArmed)
    }
}

/// One turn in the panel: who, then what they said — what's still being written in grey.
private struct PanelTurn: View {
    let turn: MeetingTurn
    let cast: Cast
    let showName: Bool
    let isLast: Bool

    private var speaker: Int? { turn.speaker.flatMap { $0 >= 0 ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showName {
                HStack(spacing: 7) {
                    SpeakerMark(speaker: speaker, cast: cast, size: 20)
                    Text(speaker.map { cast.name(of: $0) } ?? String(localized: "Känner igen rösten…"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(speaker == nil ? DS.Colors.muted : .primary)
                    Text(MeetingView.duration(turn.start))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.faint)
                }
                .accessibilityElement(children: .combine)
            }
            text
                // Words settle from grey into ink rather than switching.
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.45), value: turn.text)
                .font(.system(size: 14.5))
                .lineSpacing(3.5)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(DS.Colors.card))
        }
    }

    private var text: Text {
        var out = Text(turn.text)
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
