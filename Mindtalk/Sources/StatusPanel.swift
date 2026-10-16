import AppKit
import SwiftUI

// MARK: - Menu bar panel
//
// Clicking Mindtalk in the menu bar (left or right) opens this panel. It is
// built like a menu bar menu — rows with a quiet hover, round badges filled
// when chosen, keyboard shortcuts at the trailing edge — but dressed like the
// app: its logo, its keycaps, its serif numbers, and room to breathe.

@MainActor
final class StatusPanel: NSObject, NSWindowDelegate {
    private var panel: KeyPanel?
    private var outsideClick: Any?
    private var insideClick: Any?
    private weak var button: NSStatusBarButton?

    var isShown: Bool { panel?.isVisible == true }

    func toggle(from button: NSStatusBarButton) {
        isShown ? close() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        self.button = button
        if panel == nil {
            let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 400),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: StatusPanelView(dictation: .shared, stats: .shared) { [weak self] in
                self?.close()
            })
            self.panel = panel
        }
        guard let panel, let hosting = panel.contentView as? NSHostingView<StatusPanelView>,
              let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        // Take focus so Esc and the keyboard reach the panel (a menu bar app stays out of the Dock).
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        // Close on any click outside: in other apps…
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            #if DEBUG
            if Demo.on { return }
            #endif
            MainActor.assumeIsolated { self?.close() }
        }
        //… and in Mindtalk's own windows (but not the status item, which toggles).
        insideClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel, event.window !== self.button?.window else { return }
                self.close()
            }
            return event
        }
    }

    /// `immediately`: gone at once, no fade — when a window of Mindtalk's opens next (as
    /// it fades, macOS hands the focus back to the app you were in, over that window).
    func close(immediately: Bool = false) {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let insideClick { NSEvent.removeMonitor(insideClick) }
        outsideClick = nil
        insideClick = nil
        button?.highlight(false)
        guard let panel, panel.isVisible else { return }
        if immediately { panel.orderOut(nil); panel.alphaValue = 0; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        #if DEBUG
        if Demo.on { return }   // screenshots: stay open whatever else takes focus
        #endif
        close()
    }

    /// Keeps the size in step with the content (e.g. when a dictation arrives).
    func refit() {
        guard let panel, panel.isVisible, let hosting = panel.contentView as? NSHostingView<StatusPanelView> else { return }
        let size = hosting.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }
}

/// A borderless panel that can still take keyboard focus (Esc, buttons).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.closeStatusPanel() }
}

// MARK: - Content

enum PanelMetrics {
    static let width: CGFloat = 330
    /// Text starts here; row highlights sit 7 pt in from the edge.
    static let inset: CGFloat = 18
    static let highlightInset: CGFloat = 7
    static let corner: CGFloat = 18
}

struct StatusPanelView: View {
    @ObservedObject var dictation: Dictation
    @ObservedObject var stats: Stats
    @ObservedObject var updates: Updates = .shared
    @ObservedObject var meeting: MeetingSession = .shared
    let close: () -> Void
    /// No glass (ImageRenderer can't draw it) — screenshots only.
    var flat = false
    /// A language that isn't downloaded yet, waiting for a yes before 600+ MB.
    @State private var confirming: SpeechModel?

    /// Closes the panel and opens the window on `page`.
    private func go(_ page: Page) {
        (NSApp.delegate as? AppDelegate)?.closeStatusPanel(immediately: true)
        AppDelegate.showWindow(page: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelSeparator()
            today
            PanelSeparator()
            if let version = updates.available {
                PanelRow(title: String(localized: "Ny version \(version) – installera…"), icon: "arrow.down.circle") {
                    close()
                    updates.checkNow()
                }
                PanelSeparator()
            }
            // What you do most, right under the figures: the meeting going on, or the
            // ways to start one, a thought, the window.
            if meeting.isBusy {
                PanelRow(title: "Öppna mötet", icon: "person.2.wave.2") {
                    close()
                    if AppDelegate.mainWindowVisible { AppDelegate.showWindow(page: .meetings) } else { MeetingPanel.shared.show() }
                }
                if meeting.isRecording {
                    if meeting.stopping {
                        PanelRow(title: String(localized: "Avslutas strax – ångra"), icon: "arrow.uturn.backward") { meeting.cancelStop() }
                    } else {
                        PanelRow(title: meeting.isPaused ? String(localized: "pause|Fortsätt mötet") : String(localized: "Pausa mötet"),
                                 icon: meeting.isPaused ? "play.fill" : "pause.fill") {
                            if meeting.isPaused { meeting.resume() } else { meeting.pause() }
                        }
                        PanelRow(title: String(localized: "Avsluta mötet"), icon: "stop.fill", shortcut: Self.meetingKeys) {
                            meeting.requestStop()
                            close()
                            if !AppDelegate.mainWindowVisible { MeetingPanel.shared.show() }
                        }
                    }
                }
            } else if VoiceModels.isInstalled {
                PanelRow(title: "Starta möte", dot: true, shortcut: Self.meetingKeys) {
                    // Gone at once (no fade): the window the meeting opens in comes in front.
                    (NSApp.delegate as? AppDelegate)?.closeStatusPanel(immediately: true)
                    AppDelegate.startMeeting()
                }
            }
            // A thought, from wherever you are — kept in Tankar.
            if !meeting.isRecording, dictation.engine.isInstalled {
                PanelRow(title: "Säg en tanke", icon: "lightbulb",
                         shortcut: Settings.thoughtShortcut?.chip) {
                    (NSApp.delegate as? AppDelegate)?.closeStatusPanel(immediately: true)
                    Dictation.shared.startThought()
                }
            }
            PanelRow(title: "Öppna Mindtalk", icon: "house") { go(.dictation) }
            PanelSeparator()
            language
            PanelSeparator()
            PanelRow(title: "Inställningar…", shortcut: "⌘,") { go(.settings) }
            PanelRow(title: "Avsluta Mindtalk", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 8)
        .frame(width: PanelMetrics.width)
        // Nearly solid, so text keeps its contrast whatever is behind the panel.
        .background(DS.Colors.paper.opacity(flat ? 1 : 0.97))
        .modifier(Glass(on: !flat))
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelMetrics.corner, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
        .background(shortcuts)
    }

    private struct Glass: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: PanelMetrics.corner, style: .continuous)) }
            else { content }
        }
    }

    /// The meeting shortcut that works everywhere — or Mindtalk's own ⇧⌘R when it's off.
    static var meetingKeys: String {
        Settings.meetingShortcut.map { $0.chip.replacingOccurrences(of: " ", with: "") } ?? "⇧⌘R"
    }

    /// ⌘1 / ⌘2 switch language, ⌘, opens Settings, ⌘Q quits — as the rows show.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(SpeechModel.allCases.enumerated()), id: \.element) { i, m in
                Button("") { pick(m) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { go(.settings) }.keyboardShortcut(",", modifiers: .command)
            Button("") {
                if meeting.isRecording { meeting.requestStop() } else if meeting.phase == .idle, VoiceModels.isInstalled {
                    close()
                    AppDelegate.startMeeting()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pick(_ m: SpeechModel) {
        if m.isInstalled { confirming = nil; dictation.setEngine(m); return }
        guard dictation.downloads[m] == nil else { return }
        confirming = confirming == m ? nil : m
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // The tile and the name open the window — the top of the menu, not the bottom.
            Button { go(.dictation) } label: {
                MeterReader(meter: dictation.meter) { levels in
                    TimelineView(.animation(paused: dictation.phase != .recording)) { context in
                        LogoTile(size: 36, t: context.date.timeIntervalSinceReferenceDate,
                                 animated: dictation.phase == .recording,
                                 levels: dictation.phase == .recording ? levels : nil)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("Öppna Mindtalk")
            VStack(alignment: .leading, spacing: 5) {
                Button { go(.dictation) } label: {
                    Text("Mindtalk").font(.system(size: 15, weight: .semibold)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Öppna Mindtalk")
                status
            }
            Spacer(minLength: 8)
            if dictation.phase == .recording {
                MeterReader(meter: dictation.meter) { levels in
                    Waveform(levels: Array(levels.suffix(14)), gap: 2)
                }
                .frame(width: 46, height: 16)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, PanelMetrics.inset)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.2), value: dictation.phase)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            if meeting.isRecording, meeting.isPaused {
                Image(systemName: "pause.fill").font(.system(size: 7, weight: .heavy))
                Text("Mötet är pausat · \(MeetingView.duration(meeting.clock(at: Date())))").monospacedDigit()
            } else if meeting.isRecording, let warning = meeting.warning {
                // The recording needs a look: say what, also with the window closed.
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                Text(warning).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else if meeting.isRecording, let start = meeting.startedAt {
                // A meeting has the mic: say so, with the time.
                Circle().fill(DS.Colors.recording).frame(width: 6, height: 6)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("Mötet spelas in · \(MeetingView.duration(meeting.clock(at: context.date)))").monospacedDigit()
                }
            } else if case .finishing(let what) = meeting.phase {
                Text(what)
            } else {
            switch dictation.phase {
            case .recording:
                Circle().fill(DS.Colors.recording).frame(width: 6, height: 6)
                Text(dictation.handsFree ? "Lyssnar – låst" : "Lyssnar…")
            case .transcribing:
                Text("Skriver…")
            default:
                switch dictation.model {
                case .downloading(let p) where SpeechModel.isPreparing(p):
                    // The files are in; a percentage stuck at 95 would only look stuck.
                    Text("Förbereder \(dictation.engine.title.lowercased())")
                case .downloading(let p):
                    Text("Laddar ned \(dictation.engine.title) · \(Int(p * 100)) %").monospacedDigit()
                case .loading:
                    Text("Startar…")
                default:
                    if dictation.isReady {
                        if dictation.hotkey.modifierKeys.count > 1 {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Text(LocalizedStringKey(dictation.mode == .toggle ? "Tryck" : "Håll"))
                                    Text("för att diktera")
                                }
                                KeyChip(text: dictation.hotkey.chip)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(LocalizedStringKey(dictation.mode == .toggle ? "Tryck" : "Håll"))
                            KeyChip(text: dictation.hotkey.chip)
                                .fixedSize()
                                .layoutPriority(1)
                                .padding(.horizontal, 1)
                            Text("för att diktera")
                        }
                    } else {
                        if let issue = dictation.setupIssue {
                            // Says what's missing, and a click fixes it.
                            Button {
                                close()
                                dictation.fix(issue)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                                    Text(issue.title).foregroundStyle(.primary)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .help(issue.why)
                        }
                    }
                }
            }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(DS.Colors.muted)
        .lineLimit(1)
        .frame(minHeight: 24, alignment: .leading)
    }

    // MARK: Today

    private var today: some View {
        let weekSaved = stats.week.reduce(0) { $0 + $1.stat.savedSeconds }
        // The bars step aside when big numbers or a long language need the room.
        return ViewThatFits(in: .horizontal) {
            todayRow(bars: true)
            todayRow(bars: false)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, PanelMetrics.inset)
        .frame(height: 40)
        .help(weekSaved >= 1 ? String(localized: "≈ \(Stats.duration(weekSaved)) sparad tid den här veckan") : "")
    }

    private func todayRow(bars: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if stats.weekWords == 0 {
                Text("Inga ord den här veckan än").foregroundStyle(DS.Colors.muted)
            } else {
                figure(stats.today.words, "ord i dag")
                figure(stats.weekWords, "i veckan")
            }
            if bars {
                Spacer(minLength: 8)
                WeekBars(week: stats.week)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Stats.number(value))
                .font(.system(size: 20, weight: .regular, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(LocalizedStringKey(label)).foregroundStyle(DS.Colors.muted)
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: Language

    private var language: some View {
        let downloading = SpeechModel.allCases.first { dictation.downloads[$0] != nil }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Språk").font(.system(size: 14))
                Spacer(minLength: 8)
                PillPicker(options: SpeechModel.allCases.map { (value: $0, title: $0.title) },
                           selection: Binding(get: { dictation.engine }, set: { pick($0) }))
                    .help("⌘1 och ⌘2 byter språk")
            }
            .padding(.horizontal, PanelMetrics.inset)
            .frame(minHeight: 42)
            // A language that isn't on the Mac yet: say how big, and let a click fetch it.
            if let m = confirming ?? downloading {
                LanguageRow(model: m, index: (SpeechModel.allCases.firstIndex(of: m) ?? 0) + 1, selected: dictation.engine == m,
                            installed: m.isInstalled, download: dictation.downloads[m],
                            confirming: confirming == m,
                            confirm: {
                                confirming = nil
                                // Keeps the language you have until the new one is ready.
                                dictation.downloadModel(m, thenUse: true)
                            }) { pick(m) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: confirming)
    }
}

// MARK: - Rows

/// A menu row: the hover is a soft rounded fill, like the system's menu bar menus.
private struct HoverRow<Content: View>: View {
    var height: CGFloat = 30
    let action: () -> Void
    @ViewBuilder let content: (_ hovering: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content(hovering)
                .padding(.horizontal, PanelMetrics.inset - PanelMetrics.highlightInset)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PanelMetrics.highlightInset)
        .onHover { hovering = $0 }
    }
}

private struct PanelRow: View {
    let title: String
    var icon: String? = nil
    /// The recording dot, for "Starta möte".
    var dot = false
    var shortcut: String? = nil
    var muted = false
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) { _ in
            HStack(spacing: 10) {
                if dot || icon != nil {
                    Group {
                        if dot {
                            Circle().fill(DS.Colors.recording).frame(width: 8, height: 8)
                        } else if let icon {
                            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                        }
                    }
                    .frame(width: 18)
                    .accessibilityHidden(true)
                }
                Text(LocalizedStringKey(title))
                    .foregroundStyle(muted ? AnyShapeStyle(DS.Colors.muted) : AnyShapeStyle(.primary))
                Spacer(minLength: 12)
                if let shortcut { Text(shortcut).font(.system(size: 13)).foregroundStyle(DS.Colors.faint) }
            }
            .font(.system(size: 14))
        }
    }
}

/// A language: its badge in a circle — filled when it's the one in use.
private struct LanguageRow: View {
    let model: SpeechModel
    let index: Int
    let selected: Bool
    let installed: Bool
    let download: Double?
    let confirming: Bool
    let confirm: () -> Void
    let action: () -> Void

    var body: some View {
        HoverRow(height: 42, action: action) { hovering in
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(selected ? DS.Colors.ink : DS.Colors.chip)
                    ModelBadge(model: model, size: 11.5)
                        .foregroundStyle(selected ? DS.Colors.onInk : DS.Colors.ink)
                }
                .frame(width: 30, height: 30)
                .animation(.easeOut(duration: 0.18), value: selected)
                Text(LocalizedStringKey(model.title)).font(.system(size: 14))
                Spacer(minLength: 8)
                trailing(hovering: hovering)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.faint)
            }
        }
        .help(LocalizedStringKey(model.pitch))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func trailing(hovering: Bool) -> some View {
        if confirming {
            Button(action: confirm) {
                Text("Ladda ned \(model.sizeText)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.onInk)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(DS.Colors.ink))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if let download {
            HStack(spacing: 5) {
                Text("\(Int(download * 100)) %").monospacedDigit()
                ProgressRing(progress: download)
            }
        } else if !installed {
            HStack(spacing: 4) {
                Text(model.sizeText)
                Image(systemName: "arrow.down.circle")
            }
            .foregroundStyle(hovering ? DS.Colors.muted : DS.Colors.faint)
        } else {
            Text("⌘\(index)")
        }
    }
}

private struct PanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.divider)
            .frame(height: 1)
            .padding(.horizontal, PanelMetrics.inset)
            .padding(.vertical, 7)
    }
}

/// Monday to Sunday in seven slim bars: today in ink, other days grey,
/// days without words a hairline.
private struct WeekBars: View {
    let week: [Stats.WeekDay]

    var body: some View {
        let peak = max(1, week.map(\.stat.words).max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(week.indices, id: \.self) { i in
                let day = week[i]
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Colors.ink.opacity(day.isToday ? 1 : day.stat.words > 0 ? 0.3 : day.isFuture ? 0.08 : 0.15))
                    .frame(width: 6, height: day.stat.words > 0 ? max(3, CGFloat(day.stat.words) / CGFloat(peak) * 20) : 2)
            }
        }
        .frame(height: 20, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

private struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(DS.Colors.divider, lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(DS.Colors.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}
