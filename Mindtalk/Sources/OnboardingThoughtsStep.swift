import SwiftUI

// MARK: - Step 5: A thought, for real
//
// What to do and when, ticked off from what really happens: the thought key down,
// your voice heard, the thought saved. Then what you said flies into a small Tankar
// list, so you see where it went — never typed where you are.
//
// A quick tap listens hands-free instead: said plainly, with Klar to finish. Without
// the key (no shortcut, or no Hjälpmedel) a button you hold does the same. Until the
// speech model is ready, the list says what it's waiting for. With Reduce Motion on,
// nothing flies or pulses: the thought simply appears in the list.

struct ThoughtsStep: View {
    @ObservedObject var dictation: Dictation
    @Binding var done: Bool
    @ObservedObject private var thoughts = Thoughts.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shortcut = Settings.thoughtShortcut
    /// 0: hold the key · 1: say it · 2: let go · 3: saved.
    @State private var progress = 0
    /// A thought is under way: from the key going down until it's saved (or not).
    @State private var attempt = false
    @State private var note: Note?
    /// Nothing has happened for a while: the key glows a little brighter and says how.
    @State private var nudge = false
    @State private var holdingButton = false
    @State private var buttonDown: Date?
    /// The press reached the microphone — if not, a release says why rather than "too short".
    @State private var pressRecorded = false
    /// Down on the button right now; resets by itself if the gesture is torn down.
    @GestureState private var pressing = false
    /// The flight and the light, so leaving the step stops them.
    @State private var tasks: [Task<Void, Never>] = []

    // The list, and the thought on its way into it.
    @State private var earlier: [Thought] = []
    @State private var arrivals: [Thought] = []
    @State private var landed: Set<UUID> = []
    @State private var lit: Set<UUID> = []
    @State private var panelLit = false
    @State private var incoming: Thought?
    @State private var appear: CGFloat = 0
    @State private var flight: CGFloat = 0
    @State private var source: CGRect = .zero
    @State private var slot: CGRect = .zero

    init(dictation: Dictation, done: Binding<Bool>) {
        self.dictation = dictation
        _done = done
        // A couple of yours beneath, dimmed — the list it lands in is the real one.
        _earlier = State(initialValue: Array(Thoughts.shared.all.filter(\.isOpen).sorted { $0.date > $1.date }.prefix(2)))
        #if DEBUG
        if let demo = Self.demo { seed(demo) }
        #endif
    }

    private static let space = "thoughtsStep"
    private static let columnWidth: CGFloat = 360
    private static let panelWidth: CGFloat = 256
    private static let columnHeight: CGFloat = 286
    private static let triggerHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Spara en tanke",
                       subtitle: "Kommer du på något mitt i något annat? Säg det, så hamnar det i Tankar, inte i texten.")
                .staggered(0)
            HStack(alignment: .top, spacing: DS.Layout.stepGap) {
                VStack(spacing: DS.Layout.stepGap) {
                    trigger
                        // The keys' top in line with the panel's.
                        .frame(height: Self.triggerHeight, alignment: .top)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { source = $0 }
                    if live.ready {
                        checklist.transition(.opacity)
                    } else {
                        ModelState(dictation: dictation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .raised(cornerRadius: DS.Radius.panel)
                            .transition(.opacity)
                    }
                    anywhere
                }
                .frame(width: Self.columnWidth, height: Self.columnHeight, alignment: .top)
                .staggered(1)
                panel
                    .staggered(2)
            }
            .animation(.smooth(duration: 0.4), value: live.ready)
            hintLine
                .frame(height: 54)
                .staggered(3)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { flyingCard }
        .onAppear(perform: appeared)
        .onDisappear {
            // Navigated away mid-press: keep what was said rather than leave it listening.
            // A hands-free thought keeps listening — it's yours to finish, here or in the bubble.
            releaseButton()
            tasks.forEach { $0.cancel() }
            tasks = []
        }
        // The button gone or switched off under your finger, or another app in front:
        // no press left hanging.
        .onChange(of: live.useButton) { _, _ in releaseButton() }
        .onChange(of: usable) { _, now in if !now { releaseButton() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in releaseButton() }
        .onChange(of: dictation.phase) { old, new in phaseChanged(from: old, to: new) }
        .onChange(of: thoughts.fresh) { _, id in arrived(id) }
        .onReceive(dictation.meter.$levels) { levels in
            // Your voice, not the room: the same bar as "Vi hör dig!" in the step before.
            guard progress == 1, live.held || live.locked, (levels.suffix(6).max() ?? 0) > 0.08 else { return }
            withAnimation(.snappy(duration: 0.3)) { progress = 2 }
        }
        .task(id: waiting) {
            #if DEBUG
            if Self.demo != nil { return }
            #endif
            nudge = false
            guard waiting else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.6)) { nudge = true }
        }
    }

    // MARK: What's going on

    private struct Live {
        var ready = true
        /// The thought key (or the button) is down and it's listening.
        var held = false
        /// A quick tap: listening hands-free until Klar.
        var locked = false
        var writing = false
        /// The dictation key instead of the thought key.
        var otherDictation = false
        var useButton = false
        var micGranted = true
    }

    private var live: Live {
        #if DEBUG
        if let demo = Self.demo { return Self.demoLive(demo) }
        #endif
        let recording = dictation.phase == .recording
        let thought = recording && dictation.forThought
        return Live(ready: dictation.model == .ready,
                    held: thought && (!dictation.handsFree || holdingButton),
                    locked: thought && dictation.handsFree && !holdingButton,
                    writing: dictation.phase == .transcribing && dictation.forThought,
                    otherDictation: recording && !dictation.forThought,
                    useButton: shortcut == nil || !dictation.accessibilityGranted,
                    micGranted: dictation.micGranted)
    }

    /// Ready, and nothing has happened yet.
    private var waiting: Bool {
        let l = live
        return l.ready && l.micGranted && progress == 0 && !l.held && !l.locked && !l.writing && arrivals.isEmpty && incoming == nil
    }

    /// "vänster ⌥", "⌃⌥T"
    private var keysInline: String { shortcut?.inlineName ?? "" }

    /// One key held on its own (left ⌥), not keys pressed together.
    private var oneKey: Bool { shortcut?.isModifier == true }

    private enum Note: Equatable {
        case noWords, tooShort, failed(String)
    }

    private static var micText: String { String(localized: "Mindtalk behöver mikrofonen. Tillåt den under Behörigheter.") }

    /// Why a press didn't start listening, in Dictation's own words where it has them.
    private var whyNotListening: String? {
        if MeetingSession.shared.isRecording { return String(localized: "Ett möte spelas in, så dikteringen är pausad.") }
        if !dictation.micGranted { return Self.micText }
        return nil
    }

    // MARK: The key — or a button to hold

    @ViewBuilder private var trigger: some View {
        if live.useButton { holdButton } else { keys }
    }

    private var keys: some View {
        let parts = shortcut?.keycaps ?? []
        let gap: CGFloat = 10
        let n = CGFloat(max(1, parts.count))
        let width = min(112, (Self.columnWidth - gap * (n - 1)) / n)
        let scale = width / 190
        return HStack(spacing: gap) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                VStack(spacing: 7) {
                    Keycap(text: part.symbol, pressed: live.held, isCombination: false)
                        .scaleEffect(scale)
                        .frame(width: width, height: 96 * scale)
                    // What's printed on the key, for those who don't know ⌃ from ⌥ — and
                    // which side, for a key held on its own ("vänster option").
                    Text(verbatim: part.caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.muted)
                        .frame(height: 13)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(live.ready ? 1 : 0.45)
        .background { WaitingHalo(active: waiting, strong: nudge) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Håll in \(keysInline)"))
    }

    private var holdButton: some View {
        let held = live.held
        return HStack(spacing: 10) {
            ZStack {
                Image(systemName: "mic.fill").opacity(held ? 0 : 1)
                Circle().fill(DS.Colors.recording).frame(width: 9, height: 9).opacity(held ? 1 : 0)
            }
            .frame(width: 16)
            Text("Håll in och prata")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(DS.Colors.onInk)
        .frame(width: 300, height: 56)
        .background(Capsule().fill(DS.Colors.ink))
        .shadow(color: .black.opacity(held ? 0.1 : 0.2), radius: held ? 6 : 14, y: held ? 2 : 7)
        .scaleEffect(holdingButton ? 0.97 : 1)
        .animation(.snappy(duration: 0.2), value: holdingButton)
        .animation(.snappy(duration: 0.2), value: held)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, down, _ in down = true })
        .onChange(of: pressing) { _, down in down ? pressButton() : releaseButton() }
        .opacity(usable ? 1 : 0.4)
        .allowsHitTesting(usable)
        .background { WaitingHalo(active: waiting, strong: nudge) }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        // VoiceOver can't hold: once to start, once to keep it.
        .accessibilityLabel(held || live.locked ? Text("Klar") : Text("Börja prata"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard usable else { return }
            if dictation.phase == .recording { dictation.finishFromHUD() } else { dictation.startThought() }
        }
    }

    /// The button can start listening: the model is ready and the mic allowed.
    private var usable: Bool { live.ready && live.micGranted }

    private func pressButton() {
        guard !holdingButton, usable else { return }
        holdingButton = true
        buttonDown = Date()
        note = nil
        // Busy writing the last one down: nothing starts, and that's not your press's fault.
        let busy = dictation.phase == .transcribing
        dictation.startThought()
        pressRecorded = dictation.phase == .recording && dictation.forThought
        if !pressRecorded, !busy, let why = whyNotListening { note = .failed(why) }
    }

    private func releaseButton() {
        guard holdingButton else { return }
        holdingButton = false
        let quick = buttonDown.map { Date().timeIntervalSince($0) < 0.6 } ?? false
        buttonDown = nil
        // Never started (busy, a meeting, no mic): already said why, or nothing to say.
        guard pressRecorded else { return }
        pressRecorded = false
        if quick { note = .tooShort }
        if dictation.phase == .recording, dictation.forThought { dictation.finishFromHUD() }
    }

    // MARK: Three things to do

    private var checklist: some View {
        let l = live
        return VStack(spacing: 2) {
            ChecklistRow(number: 1,
                         // The keys are right above: no need to spell them out again. One
                         // key is said by name — "tangenten" alone wouldn't say which side.
                         text: l.useButton ? String(localized: "Håll in knappen")
                             : oneKey ? String(localized: "Håll in \(keysInline)") : String(localized: "Håll in tangenterna"),
                         state: state(0)) { EmptyView() }
            ChecklistRow(number: 2, text: String(localized: "Säg det du vill komma ihåg"), state: state(1)) {
                if l.held || l.locked {
                    MeterReader(meter: dictation.meter) { levels in
                        Waveform(levels: Array(levels.suffix(12)), gap: 2.5, color: DS.Colors.ink)
                    }
                    .frame(width: 54, height: 20)
                    .transition(.opacity)
                }
            }
            ChecklistRow(number: 3, text: String(localized: "Släpp"), state: state(2)) {
                if l.writing {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Skriver ned…").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: l.held || l.locked)
        .animation(.smooth(duration: 0.3), value: l.writing)
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .raised(cornerRadius: DS.Radius.panel)
    }

    /// The shortcut works in every app, not only here — said once, under the list.
    @ViewBuilder private var anywhere: some View {
        if let shortcut {
            let keys = shortcut.chip
            HStack(alignment: .center, spacing: 8) {
                KeyChip(text: keys)
                    .accessibilityHidden(true)
                Text("sparar en tanke, var du än är.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(keys) sparar en tanke, var du än är."))
        }
    }

    private func state(_ i: Int) -> ItemState {
        i < progress ? .done : i == progress ? .current : .pending
    }

    // MARK: Where it lands

    private enum PanelItem: Identifiable {
        case slot, arrival(Thought), earlier(Thought), blank(Int)
        var id: String {
            switch self {
            case .slot: return "slot"
            case .arrival(let t), .earlier(let t): return t.id.uuidString
            case .blank(let i): return "blank\(i)"
            }
        }
    }

    private var items: [PanelItem] {
        var list: [PanelItem] = arrivals.isEmpty ? [.slot] : []
        list += arrivals.prefix(3).map { .arrival($0) }
        let ids = Set(arrivals.map(\.id))
        let room = max(0, 3 - list.count)
        let older = earlier.filter { !ids.contains($0.id) }.prefix(room)
        list += older.map { .earlier($0) }
        // An empty list still looks like one: two faint lines where thoughts go.
        if earlier.isEmpty { list += (0..<max(0, 3 - list.count)).map { .blank($0) } }
        return list
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CapsLabel(String(localized: "Tankar"))
                Spacer()
                Image(systemName: "lightbulb")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            VStack(spacing: 4) {
                ForEach(items) { item in row(item) }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.3) : .smooth(duration: 0.45), value: arrivals.map(\.id))
            Spacer(minLength: 0)
        }
        .padding(12)
        .padding(.top, 4)
        .frame(width: Self.panelWidth, height: Self.columnHeight, alignment: .top)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .black.opacity(0.2), location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .raised(cornerRadius: DS.Radius.panel, selected: panelLit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tankar"))
    }

    @ViewBuilder private func row(_ item: PanelItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        switch item {
        case .slot:
            Text("Din tanke hamnar här")
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colors.muted)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(shape.strokeBorder(DS.Colors.ink.opacity(nudge ? 0.4 : 0.2),
                                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])))
                .animation(.smooth(duration: 0.6), value: nudge)
                .transition(.opacity)
        case .arrival(let t):
            let isLanded = landed.contains(t.id)
            NoteRow(thought: t)
                .opacity(isLanded ? 1 : 0)
                .background(shape.fill(DS.Colors.chip).opacity(lit.contains(t.id) ? 1 : 0))
                // Until it's here: the place it's going, kept open.
                .overlay(shape.strokeBorder(DS.Colors.ink.opacity(isLanded ? 0 : 0.3),
                                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])))
                .keyframeAnimator(initialValue: 1.0, trigger: isLanded) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    // The landing: in a touch big, as it arrives — then one bouncy spring.
                    KeyframeTrack {
                        if isLanded && !reduceMotion {
                            LinearKeyframe(1.03, duration: 0.001)
                            SpringKeyframe(1.0, duration: 0.6, spring: .init(duration: 0.5, bounce: 0.45))
                        } else {
                            LinearKeyframe(1.0, duration: 0.001)
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                    if incoming?.id == t.id { slot = frame }
                }
                .transition(.opacity)
                .accessibilityHidden(!isLanded)
        case .earlier(let t):
            NoteRow(thought: t).opacity(0.6).transition(.opacity)
        case .blank(let i):
            HStack(spacing: 8) {
                Capsule().fill(DS.Colors.chip).frame(width: i == 0 ? 132 : 96, height: 7)
                Spacer()
                Capsule().fill(DS.Colors.chip).frame(width: 30, height: 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .opacity(0.8 - Double(i) * 0.3)
            .accessibilityHidden(true)
        }
    }

    // MARK: Under it all

    private enum Hint: Equatable {
        case locked, saved, info(String)
        var id: String {
            switch self {
            case .locked: return "locked"
            case .saved: return "saved"
            case .info(let s): return s
            }
        }
    }

    private var hint: Hint? {
        let l = live
        if !l.ready { return .info(String(localized: "Du kan prova så fort talmodellen är klar.")) }
        if !l.micGranted { return .info(Self.micText) }
        if l.locked { return .locked }
        if l.otherDictation {
            return .info(l.useButton ? String(localized: "Det är genvägen för diktering. För en tanke håller du in knappen.")
                                     : String(localized: "Det är genvägen för diktering. För en tanke håller du in \(keysInline)."))
        }
        if l.held || l.writing { return nil }
        if let note {
            switch note {
            case .noWords: return .info(String(localized: "Det blev inga ord den gången. Prova igen."))
            case .tooShort: return .info(String(localized: "Håll in knappen medan du pratar."))
            case .failed(let message): return .info(message)
            }
        }
        if !landed.isEmpty, incoming == nil { return .saved }
        if nudge {
            return .info(l.useButton ? String(localized: "Håll in knappen och prata. Släpp när du är klar.")
                         : oneKey ? String(localized: "Håll in \(keysInline) och prata. Släpp när du är klar.")
                         : String(localized: "Håll in tangenterna samtidigt och prata. Släpp när du är klar."))
        }
        return nil
    }

    private var hintLine: some View {
        ZStack {
            switch hint {
            case .locked:
                HStack(spacing: 16) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Colors.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DS.Colors.chip))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Det går bra att släppa").font(.system(size: 13.5, weight: .semibold))
                        Text("Mindtalk lyssnar tills du trycker på Klar.")
                            .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    }
                    Spacer(minLength: 8)
                    Button("Klar") { dictation.finishFromHUD() }
                        .buttonStyle(.ink)
                }
                .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
                .frame(width: Self.columnWidth + DS.Layout.stepGap + Self.panelWidth)
                .raised(cornerRadius: DS.Radius.panel)
                .transition(.opacity.combined(with: .offset(y: 6)))
            case .saved:
                Label {
                    Text("Sparad i Tankar.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(DS.Colors.ink)
                .transition(.opacity.combined(with: .offset(y: 6)))
            case .info(let text):
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .id(text)
            case nil:
                Color.clear
            }
        }
        .animation(.smooth(duration: 0.35), value: hint?.id)
    }

    // MARK: In flight

    @ViewBuilder private var flyingCard: some View {
        if let t = incoming, slot.width > 0, source.width > 0 {
            NoteRow(thought: t)
                .frame(width: slot.width)
                .modifier(Flight(progress: flight, appear: appear,
                                 from: CGPoint(x: source.midX, y: source.midY),
                                 to: CGPoint(x: slot.midX, y: slot.midY)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Happenings

    private func appeared() {
        #if DEBUG
        if let demo = Self.demo { return setUpDemo(demo) }
        #endif
        // Back to the step while a thought is still listening (hands-free) or being
        // written down: pick it up where it is.
        guard dictation.forThought else { return }
        switch dictation.phase {
        case .recording:
            attempt = true
            progress = (dictation.meter.levels.suffix(6).max() ?? 0) > 0.08 ? 2 : 1
        case .transcribing:
            attempt = true
            progress = 2
        default:
            break
        }
    }

    private func phaseChanged(from old: Dictation.Phase, to new: Dictation.Phase) {
        switch new {
        case .recording where dictation.forThought:
            attempt = true
            note = nil
            withAnimation(.snappy(duration: 0.3)) { progress = 1 }
        case .failed(let message) where attempt || dictation.forThought,
             .notice(let message) where attempt || dictation.forThought:
            attempt = false
            note = .failed(message)
            withAnimation(.smooth(duration: 0.4)) { progress = 0 }
        case .idle where attempt:
            // Esc, a press too short, or not a word understood: back to the start.
            attempt = false
            if old == .transcribing { note = .noWords }
            withAnimation(.smooth(duration: 0.4)) { progress = 0 }
        default:
            break
        }
    }

    /// A thought just saved: it opens a place at the top of the list, rises out of
    /// the key and flies there.
    private func arrived(_ id: UUID?) {
        guard let id, !arrivals.contains(where: { $0.id == id }),
              let t = thoughts.all.first(where: { $0.id == id }), t.writing == nil, !t.text.isEmpty else { return }
        // Saved: the step is done now, whatever the flight is up to.
        done = true
        if let previous = incoming { land(previous.id) }
        attempt = false
        note = nil
        withAnimation(.snappy(duration: 0.3)) { progress = 3 }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.35)) {
                arrivals.insert(t, at: 0)
                landed.insert(t.id)
            }
            light(t.id)
            return
        }
        slot = .zero
        appear = 0
        flight = 0
        arrivals.insert(t, at: 0)       // animated by the list
        incoming = t
        withAnimation(.smooth(duration: 0.35)) { appear = 1 }
        tasks.append(Task { @MainActor in
            // A moment to read what you said, then off it goes.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, incoming?.id == t.id else { return }
            withAnimation(.smooth(duration: 0.8)) { flight = 1 } completion: { land(t.id) }
        })
    }

    private func land(_ id: UUID) {
        guard !landed.contains(id) else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if incoming?.id == id { incoming = nil; flight = 0; appear = 0 }
            landed.insert(id)
        }
        light(id)
    }

    /// Lit up a moment where it landed, like the Tankar page does with a new thought.
    private func light(_ id: UUID) {
        lit.insert(id)
        withAnimation(.smooth(duration: 0.3)) { panelLit = true }
        tasks.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.9)) {
                lit.remove(id)
                panelLit = false
            }
        })
    }

    // MARK: Screenshots

    #if DEBUG
    /// `--thoughts-demo waiting|nudge|talking|locked|writing|flying|landed|fallback|nomic|wrongkey|notready`
    private static let demo: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--thoughts-demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    private static func demoLive(_ demo: String) -> Live {
        switch demo {
        case "talking": return Live(held: true)
        case "locked": return Live(locked: true)
        case "writing": return Live(writing: true)
        case "fallback": return Live(useButton: true)
        case "wrongkey": return Live(otherDictation: true)
        case "notready": return Live(ready: false)
        case "nomic": return Live(useButton: true, micGranted: false)
        default: return Live()
        }
    }

    /// Set before the first frame, so a screenshot shows the state itself, not the way into it.
    private mutating func seed(_ demo: String) {
        let now = Date()
        _earlier = State(initialValue: [Thought(text: "Boka tvättstugan till lördag", date: now.addingTimeInterval(-3 * 3600)),
                                        Thought(text: "Kolla om fakturan har gått iväg", date: now.addingTimeInterval(-26 * 3600))])
        let said = Thought(text: "Ring tillbaka om offerten", date: now)
        switch demo {
        case "nudge": _nudge = State(initialValue: true)
        case "talking", "writing": _progress = State(initialValue: 2)
        case "locked": _progress = State(initialValue: 1)
        case "flying":
            _progress = State(initialValue: 3)
            _arrivals = State(initialValue: [said])
            _incoming = State(initialValue: said)
            _appear = State(initialValue: 1)
            _flight = State(initialValue: 0.5)
        case "landed":
            _progress = State(initialValue: 3)
            _arrivals = State(initialValue: [said])
            _landed = State(initialValue: [said.id])
        default: break
        }
    }

    private func setUpDemo(_ demo: String) {
        if demo == "talking" {
            dictation.meter.levels = [0.05, 0.12, 0.30, 0.52, 0.41, 0.66, 0.35, 0.22, 0.48, 0.71, 0.58, 0.33,
                                      0.18, 0.40, 0.62, 0.50, 0.28, 0.45, 0.69, 0.54, 0.31, 0.47, 0.60, 0.38]
        }
        if demo == "landed" { done = true }
    }
    #endif
}

// MARK: - A line of the checklist

private enum ItemState { case pending, current, done }

private struct ChecklistRow<Trailing: View>: View {
    let number: Int
    let text: String
    let state: ItemState
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Tick(number: number, state: state)
            Text(text)
                .font(.system(size: 14, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .current ? AnyShapeStyle(Color.primary)
                                 : state == .done ? AnyShapeStyle(DS.Colors.muted) : AnyShapeStyle(DS.Colors.faint))
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(state == .current ? DS.Colors.chip : .clear))
        .animation(.smooth(duration: 0.35), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? Text("Klart") : Text(verbatim: ""))
    }
}

/// The number in its ring — filled with ink and ticked once it's done.
private struct Tick: View {
    let number: Int
    let state: ItemState

    var body: some View {
        let done = state == .done
        ZStack {
            Circle()
                .strokeBorder(state == .pending ? DS.Colors.fieldStroke : DS.Colors.accent, lineWidth: 1.5)
            Circle()
                .fill(DS.Colors.accent)
                .scaleEffect(done ? 1 : 0.4)
                .opacity(done ? 1 : 0)
                .animation(.snappy(duration: 0.28), value: done)
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(state == .pending ? DS.Colors.faint : DS.Colors.accent)
                .opacity(done ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: done)
            CheckShape()
                .trim(from: 0, to: done ? 1 : 0)
                .stroke(DS.Colors.onInk, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 8)
                // Drawn a beat after the ink fills the ring.
                .animation(done ? .smooth(duration: 0.3).delay(0.12) : .easeOut(duration: 0.1), value: done)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - A thought in the list

private struct NoteRow: View {
    let thought: Thought

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(thought.text)
                .font(.system(size: 15, design: .serif))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: when)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }

    private var when: String {
        Calendar.current.isDateInToday(thought.date)
            ? thought.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
            : MeetingRecord.when(thought.date)
    }
}

// MARK: - The flight

/// Out of the key and along an arc into its place in the list: it grows as it
/// rises, tilts a little in the air and arrives a touch big — the row it becomes
/// settles from there.
private struct Flight: ViewModifier, Animatable {
    var progress: CGFloat
    var appear: CGFloat
    let from: CGPoint
    let to: CGPoint

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, appear) }
        set { progress = newValue.first; appear = newValue.second }
    }

    func body(content: Content) -> some View {
        let t = progress
        let u = 1 - t
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 90)
        let point = CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
        let air = sin(.pi * t)
        let scale = (1.15 + (1.03 - 1.15) * t) * (0.85 + 0.15 * appear)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content
            .background(shape.fill(DS.Colors.field).overlay(shape.fill(DS.Colors.chip).opacity(t * t)))
            .overlay(shape.strokeBorder(DS.Colors.fieldStroke, lineWidth: 1).opacity(1 - t))
            .shadow(color: .black.opacity(0.16 * (1 - t * t)), radius: 10 + 12 * air, y: 6 + 8 * air)
            .scaleEffect(scale)
            .rotationEffect(.degrees(2.5 * air))
            .opacity(appear)
            .position(point)
    }
}

// MARK: - Waiting

/// A soft light under the key while it waits for you — it breathes, and a little
/// brighter and quicker when nothing has happened for a while. Still with Reduce Motion.
private struct WaitingHalo: View {
    let active: Bool
    let strong: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active {
            Group {
                if reduceMotion {
                    glow(0.5)
                } else {
                    glow(0)
                        .phaseAnimator([0.0, 1.0]) { content, phase in
                            content.opacity(0.35 + 0.65 * phase)
                        } animation: { _ in .easeInOut(duration: strong ? 0.9 : 1.6) }
                }
            }
            .transition(.opacity)
        }
    }

    private func glow(_ base: Double) -> some View {
        Capsule()
            .fill(DS.Colors.ink.opacity(strong ? 0.16 : 0.08))
            .padding(.horizontal, -18)
            .padding(.vertical, -12)
            .blur(radius: 18)
            .opacity(base == 0 ? 1 : base)
            .allowsHitTesting(false)
    }
}
