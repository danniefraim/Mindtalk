import SwiftUI

// MARK: - Step 6: Meetings, in the room and in calls
//
// Shows a meeting instead of describing one. On a night tile three speakers plan a
// launch: each line is written as it's said, each new voice is first "Känner igen
// rösten…" and then gets its number and colour — the sphere falling into that voice's
// figure, as in a real meeting — and afterwards the summary writes itself. Beside it,
// the voice model, benefit first: why it's needed, what it is, how big, where it runs,
// and what waiting means. It plays each time the step comes into view, then stops
// ("Spela igen" to see it again); with Reduce Motion, and in the DEBUG render, the
// finished meeting stands still.

struct MeetingsStep: View {
    @Binding var done: Bool
    @ObservedObject private var voices = VoiceModels.shared

    private static let tileWidth: CGFloat = 360
    private static let cardWidth: CGFloat = 264
    private static let height: CGFloat = 352

    var body: some View {
        VStack(spacing: 24) {
            // A summary is promised only where one can be written (Apple Intelligence, or a
            // Gemma here or on its way).
            StepHeader(title: "Möten, i rummet och i samtal",
                       subtitle: MeetingNotes.isAvailable || BetterNotes.shared.downloading != nil || OnboardingView.pendingGemma != nil
                           ? "Mindtalk hör vem som säger vad, skriver ned det medan ni pratar och sammanfattar efteråt."
                           : "Mindtalk hör vem som säger vad och skriver ned det medan ni pratar. Sammanfattningarna skriver Apple Intelligence eller Gemma. Du väljer vilken under Inställningar.")
                .staggered(0)
            HStack(alignment: .top, spacing: DS.Layout.stepGap) {
                DemoMeeting()
                    .frame(width: Self.tileWidth, height: Self.height)
                    .staggered(1)
                VoiceModelCard(done: $done)
                    .frame(width: Self.cardWidth, height: Self.height)
                    .staggered(2)
            }
            // Once the voices are here the card says how both kinds start, so only the
            // consent is left; before that, calls are said here in one sentence.
            Text(VoiceModelCard.isReady ? String(localized: "Säg till alla att mötet spelas in.")
                 : String(localized: "När ett samtal i Teams, Zoom eller Meet börjar frågar Mindtalk först. Säg till alla att mötet spelas in."))
                .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.tileWidth + DS.Layout.stepGap + Self.cardWidth)
                .staggered(3)
        }
    }
}

/// How to start one later: the shortcut that works in every app — or, when it's
/// turned off, where the button is.
private struct MeetingShortcutLine: View {
    var body: some View {
        if let chord = Settings.meetingShortcut {
            let keys = chord.chip.replacingOccurrences(of: " ", with: "")
            HStack(alignment: .center, spacing: 8) {
                KeyChip(text: keys)
                    .accessibilityHidden(true)
                Text("öppnar ett nytt möte, var du än är.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(keys) öppnar ett nytt möte, var du än är."))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .accessibilityHidden(true)
                Text("Starta ett möte under Möten.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DS.Colors.muted)
        }
    }
}

// MARK: - The demo meeting

/// A pre-written meeting, played on a night tile: no audio, no real pipeline.
private struct DemoMeeting: View {
    struct Turn {
        let speaker: Int
        let text: String
        var words: [String] { text.split(separator: " ").map(String.init) }
    }

    static let turns: [Turn] = [
        Turn(speaker: 0, text: String(localized: "Håller vi lanseringen den fjärde november?")),
        Turn(speaker: 1, text: String(localized: "Ja, om testerna är klara på fredag. Annars blir det veckan efter.")),
        Turn(speaker: 2, text: String(localized: "Jag tar testerna och ger besked på torsdag.")),
        Turn(speaker: 0, text: String(localized: "Bra. Då säger vi fjärde november.")),
    ]
    static let overview = String(localized: "Ni stämde av lanseringen och vem som kör testerna.")
    static let decision = String(localized: "Lanseringen blir den fjärde november.")
    static let task = String(localized: "Kör klart testerna och ge besked på torsdag.")
    /// Who the task is for — the third voice — and the turn it was said in.
    static let owner = 2
    static let ownerTurn = 2

    /// Each voice's own figure, as the sphere draws it once it knows who's speaking.
    static let figures = [
        VoiceFigure(a: 3, b: 2, phase: 0.7, depth: 0.35),
        VoiceFigure(a: 5, b: 4, phase: 1.9, depth: -0.3),
        VoiceFigure(a: 2, b: 3, phase: 0.3, depth: 0.45),
    ]

    /// A speaker's colour, as the meeting's text shows it on a dark page — the night
    /// tile is dark in light mode too. (The sphere makes it vivid itself.)
    static func tint(_ speaker: Int) -> Color {
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        return Color(SpeakerMark.fill(speaker).resolve(in: dark))
    }

    /// The still picture: the render, and Reduce Motion.
    #if DEBUG
    static let rendering = CommandLine.arguments.contains("--render-onboarding")
    #else
    static let rendering = false
    #endif

    enum Phase { case waiting, recording, summing, done }

    @State private var phase: Phase = .waiting
    @State private var turnsShown = 0
    /// Words written so far in the newest turn.
    @State private var words = 0
    @State private var known: Set<Int> = []
    /// The voice the sphere shows; nil while it listens.
    @State private var speaking: Int?
    @State private var level = 0.2
    @State private var starts: [Int] = []
    @State private var started: Date?
    @State private var length = 0
    @State private var summaryShown = false
    @State private var summaryWords = [0, 0, 0]
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: Bool { reduceMotion || Self.rendering }
    private var seconds: Int { started.map { Int(Date.now.timeIntervalSince($0)) } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusBar
            // The whole meeting is seen to its end; then it goes up and away and the
            // summary takes its place, never lying over what was said.
            ZStack(alignment: .topLeading) {
                if summaryShown {
                    summary
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 24)), removal: .opacity))
                } else {
                    transcript
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Exempel på ett möte: vem som säger vad, och en sammanfattning efteråt."))
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: -24))))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topTrailing) { sphere }
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Colors.night))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        .environment(\.colorScheme, .dark)
        // Cancelled when the step goes away: nothing keeps running behind the next one.
        .task(id: run) { await play() }
    }

    // MARK: Pieces

    /// The listening sphere in the corner: it turns faster while it compares voices,
    /// and falls into the speaker's figure once it knows them.
    private var sphere: some View {
        Constellation(figure: speaking.map { Self.figures[$0] },
                      color: speaking.map(Self.tint) ?? .white,
                      level: level,
                      searching: (phase == .recording && speaking == nil) || phase == .summing)
            .frame(width: 112, height: 112)
            .offset(x: 10, y: -8)
            .opacity(0.8)
            .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("Exempel")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(.white.opacity(0.12)))
            HStack(spacing: 6) {
                glyph
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .contentTransition(.opacity)
                if phase == .recording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: Self.clock(seconds))
                    }
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
                } else if phase == .done {
                    Text(verbatim: Self.clock(length))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
        .frame(height: 20)
    }

    @ViewBuilder private var glyph: some View {
        switch phase {
        case .waiting:
            Circle().fill(.white.opacity(0.35)).frame(width: 7, height: 7)
        case .recording:
            RecordingPulse()
        case .summing:
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .symbolEffect(.pulse, options: .repeating)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var statusText: String {
        switch phase {
        case .waiting: return String(localized: "Lyssnar…")
        case .recording: return String(localized: "Spelar in")
        case .summing: return String(localized: "Skriver sammanfattningen…")
        case .done: return MeetingSession.endedSentence(summarizing: false)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(0..<turnsShown, id: \.self) { i in
                let turn = Self.turns[i]
                DemoTurnRow(turn: turn,
                            known: known.contains(turn.speaker),
                            words: i == turnsShown - 1 ? words : turn.words.count,
                            live: i == turnsShown - 1 && phase == .recording,
                            start: i < starts.count ? starts[i] : 0)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
        }
    }

    /// After the meeting: what was decided and who does what — written as you watch.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text("Sammanfattning")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if phase == .done, !still {
                    Button { run += 1 } label: {
                        Label("Spela igen", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Visa exemplet en gång till")
                    .transition(.opacity)
                }
            }
            .frame(height: 22)
            words(Self.overview, shown: summaryWords[0])
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            item(icon: "checkmark.circle", label: "Beslut", text: Self.decision, shown: summaryWords[1], owner: nil)
            item(icon: "circle", label: "Att göra", text: Self.task, shown: summaryWords[2], owner: Self.owner)
            source.opacity(summaryWords[2] == Self.task.split(separator: " ").count ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the task came from: what the third voice said, and when — as a real
    /// meeting's points lead back to their moment.
    private var source: some View {
        let turn = Self.turns[Self.ownerTurn]
        let at = Self.ownerTurn < starts.count ? starts[Self.ownerTurn] : 8
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Rectangle().fill(Self.tint(turn.speaker).opacity(0.7)).frame(width: 2, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(verbatim: "\u{201D}\(turn.text)\u{201D}  \(Self.clock(at))")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 21)
        .accessibilityHidden(true)
    }

    /// A sentence written word by word, its full length kept from the start so nothing moves.
    private func words(_ text: String, shown: Int) -> some View {
        let all = text.split(separator: " ").map(String.init)
        return ZStack(alignment: .topLeading) {
            Text(verbatim: text).opacity(0)
            Text(verbatim: all.prefix(shown).joined(separator: " "))
                .contentTransition(.interpolate)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item(icon: String, label: LocalizedStringKey, text: String, shown: Int, owner: Int?) -> some View {
        let all = text.split(separator: " ").map(String.init)
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.62))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                ZStack(alignment: .topLeading) {
                    Text(verbatim: text).opacity(0)
                    Text(verbatim: all.prefix(shown).joined(separator: " "))
                        .contentTransition(.interpolate)
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let owner {
                HStack(spacing: 5) {
                    Circle().fill(Self.tint(owner)).frame(width: 7, height: 7)
                    Text("Talare \(owner + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.08)))
                .opacity(shown > 0 ? 1 : 0)
                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
            }
        }
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    // MARK: The play

    private func play() async {
        #if DEBUG
        // `--onboarding-demo live`: the render stops mid-meeting, the third voice talking.
        if Self.rendering, let i = CommandLine.arguments.firstIndex(of: "--onboarding-demo"),
           CommandLine.arguments.dropFirst(i + 1).first == "live" { midway(); return }
        // `--onboarding-demo end`: the whole meeting written, just before the summary.
        if Self.rendering, let i = CommandLine.arguments.firstIndex(of: "--onboarding-demo"),
           CommandLine.arguments.dropFirst(i + 1).first == "end" { finish(); summaryShown = false; phase = .summing; return }
        #endif
        if still { finish(); return }
        if run > 0 {
            withAnimation(.smooth(duration: 0.35)) { reset() }
            guard await wait(0.6) else { return }
        } else {
            reset()
            // Let the step come into place first.
            guard await wait(1.0) else { return }
        }
        started = .now
        withAnimation(.smooth(duration: 0.3)) { phase = .recording }

        for (i, turn) in Self.turns.enumerated() {
            let new = !known.contains(turn.speaker)
            starts.append(seconds)
            withAnimation(.smooth(duration: 0.45)) {
                turnsShown = i + 1
                words = 0
                if new { speaking = nil }
            }
            if new {
                // Someone it hasn't heard: a moment comparing, then their number and colour.
                level = 0.55
                guard await wait(0.85) else { return }
                withAnimation(.smooth(duration: 0.4)) { known.insert(turn.speaker) }
            }
            speaking = turn.speaker
            for (k, word) in turn.words.enumerated() {
                withAnimation(.smooth(duration: 0.22)) { words = k + 1 }
                level = .random(in: 0.5...1)
                // A breath after a full stop or a question, as people speak.
                let pause = word.last.map { ".?!,".contains($0) } == true ? 0.3 : 0.12
                guard await wait(pause) else { return }
            }
            level = 0.15
            guard await wait(0.55) else { return }
        }

        length = seconds
        withAnimation(.smooth(duration: 0.4)) { phase = .summing; speaking = nil }
        level = 0.3
        guard await wait(1.6) else { return }
        withAnimation(.smooth(duration: 0.6)) { summaryShown = true }
        guard await wait(0.45) else { return }
        for (k, text) in [Self.overview, Self.decision, Self.task].enumerated() {
            let count = text.split(separator: " ").count
            for w in 0..<count {
                withAnimation(.smooth(duration: 0.2)) { summaryWords[k] = w + 1 }
                guard await wait(0.08) else { return }
            }
            guard await wait(0.3) else { return }
        }
        withAnimation(.smooth(duration: 0.4)) { phase = .done }
        level = 0.2
    }

    private func reset() {
        phase = .waiting
        turnsShown = 0
        words = 0
        known = []
        speaking = nil
        starts = []
        started = nil
        summaryShown = false
        summaryWords = [0, 0, 0]
        level = 0.2
    }

    /// The whole meeting, at once.
    private func finish() {
        turnsShown = Self.turns.count
        words = Self.turns.last?.words.count ?? 0
        known = Set(Self.turns.map(\.speaker))
        starts = [0, 3, 8, 11]
        length = 14
        speaking = nil
        phase = .done
        summaryShown = true
        summaryWords = [Self.overview, Self.decision, Self.task].map { $0.split(separator: " ").count }
    }

    #if DEBUG
    private func midway() {
        turnsShown = 3
        words = 5
        known = [0, 1, 2]
        starts = [0, 3, 8]
        started = Date.now.addingTimeInterval(-9)
        speaking = 2
        level = 0.8
        phase = .recording
    }
    #endif

    private func wait(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// One turn, as the meeting's text shows it: a thin line in the speaker's colour, their
/// mark and name above what they said — "Känner igen rösten…" until it knows them.
private struct DemoTurnRow: View {
    let turn: DemoMeeting.Turn
    let known: Bool
    let words: Int
    let live: Bool
    let start: Int

    private var tint: Color { DemoMeeting.tint(turn.speaker) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                mark
                Text(known ? String(localized: "Talare \(turn.speaker + 1)") : String(localized: "Känner igen rösten…"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(known ? tint : .white.opacity(0.62))
                    .contentTransition(.opacity)
                Text(verbatim: DemoMeeting.clock(start))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
            }
            // The whole line, invisible, holds the row's size while it's being written.
            ZStack(alignment: .topLeading) {
                Text(verbatim: turn.text).opacity(0)
                line.contentTransition(.interpolate)
            }
            .font(.system(size: 13.5))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            Capsule().fill(known ? tint : .white.opacity(0.22)).frame(width: 2.5)
        }
    }

    /// The speaker's number in their colour — or a dashed ring while it listens.
    private var mark: some View {
        ZStack {
            if known {
                Circle().fill(tint)
                Text(verbatim: "\(turn.speaker + 1)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.8))
            } else {
                Circle().strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    /// Said so far in white; the newest word still settling, in grey.
    private var line: Text {
        let all = turn.words
        let n = min(words, all.count)
        guard n > 0 else { return Text(verbatim: "") }
        let settled = all.prefix(live ? n - 1 : n).joined(separator: " ")
        let base = Text(verbatim: settled).foregroundStyle(.white.opacity(0.92))
        guard live else { return base }
        let newest = Text(verbatim: (n > 1 ? " " : "") + all[n - 1]).foregroundStyle(.white.opacity(0.62))
        let cursor = Text(verbatim: " ▏").foregroundStyle(.white.opacity(0.55))
        return Text("\(base)\(newest)\(cursor)")
    }
}

/// The red dot of a recording, breathing.
private struct RecordingPulse: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(DS.Colors.recording)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.45)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - The voice model

/// ⓘ: which model hears the voices, and who made it, as under Tack till.
private struct VoiceModelInfo: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Vilken modell är det?")
        .accessibilityLabel("Vilken modell är det?")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nemotron 3").font(.system(size: 12.5, weight: .semibold))
                Text("Av NVIDIA, Core ML av FluidInference. OpenMDW 1.1.")
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
                Text("Står också under Tack till i Inställningar.")
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }
}

/// Why it's needed, what it is, how big and where it runs — then one button, and what
/// waiting means. While it downloads: how far, and that you can go on. Then: done.
private struct VoiceModelCard: View {
    @Binding var done: Bool
    @ObservedObject private var voices = VoiceModels.shared
    /// The download was going while you watched: when it's done, the check comes in
    /// with a bounce. Set before the ready view exists, so it's built with it.
    @State private var celebrate = false
    /// On screen and not leaving: the outgoing step mustn't touch the next one's button.
    @State private var alive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Kind: Equatable { case offer, downloading, ready }
    /// The model's state without its progress — changes once per step, not every tick.
    private enum Phase: Equatable { case missing, downloading, failed, ready }

    private var phase: Phase {
        switch voices.state {
        case .missing: return .missing
        case .downloading: return .downloading
        case .failed: return .failed
        case .ready: return .ready
        }
    }

    private var state: VoiceModels.State {
        #if DEBUG
        if let preview = Self.preview { return preview }
        #endif
        return voices.state
    }

    private var kind: Kind {
        switch state {
        case .missing, .failed: return .offer
        case .downloading: return .downloading
        case .ready: return .ready
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch state {
                case .missing: offer(failure: nil)
                case .failed(let message): offer(failure: message)
                case .downloading(let p): downloading(p)
                case .ready: ready
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // How to start one later; once ready, the card says it itself.
            if kind != .ready {
                MeetingShortcutLine()
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .raised(cornerRadius: DS.Radius.panel)
        .animation(.smooth(duration: 0.4), value: kind)
        .onAppear {
            alive = true
            if kind != .offer { done = true }
            if phase == .downloading { celebrate = !reduceMotion }
        }
        .onDisappear { alive = false }
        .onChange(of: phase) { _, new in
            guard alive else { return }
            if new == .downloading {
                celebrate = !reduceMotion
                done = true
            }
            if new == .ready { done = true }
        }
    }

    private var eyebrow: some View { CapsLabel(String(localized: "Talare")) }

    // MARK: Not here yet

    private func offer(failure: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Text(failure == nil ? String(localized: "För att hålla isär vem som pratar behövs en modell till.")
                                : String(localized: "Röstmodellen laddades inte ned"))
                .font(.system(size: 15.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 7) {
                // What it does and what it costs; which model it is sits behind the ⓘ.
                // After a failed download the reason takes its place.
                if failure == nil { fact("person.wave.2", Text("Hämta röstmodellen (\(VoiceModels.sizeText)). Utan den går det inte att starta ett möte.")) }
                fact("lock", Text("Körs på din Mac, ljudet lämnar den aldrig"))
                fact("internaldrive", Text("Du har \(BetterNotes.gigabytes(BetterNotes.freeBytes)) ledigt"),
                     warn: BetterNotes.freeBytes < 2_000_000_000)
            }
            .padding(.top, 12)
            Spacer(minLength: 10)
            Button { start() } label: {
                HStack(spacing: 7) {
                    Image(systemName: failure == nil ? "arrow.down" : "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .bold))
                    Text(failure == nil ? String(localized: "Ladda ned \(VoiceModels.sizeText)") : String(localized: "intro|Försök igen"))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            }
            .buttonStyle(.ink)
            .help("Laddas ned i bakgrunden medan du fortsätter")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("**Senare?** Du hittar den under Möten.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                VoiceModelInfo()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(DS.Colors.muted)
            .padding(.top, 10)
        }
        .transition(.opacity)
    }

    private func fact(_ icon: String, _ text: Text, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11.5))
                .frame(width: 15)
                .foregroundStyle(warn ? DS.Colors.warning : DS.Colors.muted)
                .accessibilityHidden(true)
            text
                .font(.system(size: 12.5))
                .foregroundStyle(warn ? DS.Colors.warning : DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() {
        #if DEBUG
        if Self.preview != nil { return }
        #endif
        celebrate = !reduceMotion
        voices.download()
        if alive { done = true }
    }

    // MARK: On its way

    private func downloading(_ p: Double) -> some View {
        let total = Int(VoiceModels.sizeText.prefix { $0.isNumber }) ?? 400
        return VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Text("Laddar ned röstmodellen")
                .font(.system(size: 15.5, weight: .semibold))
                .padding(.top, 8)
            Spacer(minLength: 12)
            Text(p, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 40, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: Int(p * 100))
            InkProgressBar(progress: p)
                .padding(.top, 8)
                .accessibilityLabel(Text("Laddar ned röstmodellen"))
            // Between the bundles the files are in and it's being made ready for this Mac.
            Text(voices.preparing ? String(localized: "Förbereder…") : "\(Int((p * Double(total)).rounded())) av \(VoiceModels.sizeText)")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(DS.Colors.muted)
                .padding(.top, 8)
            Spacer(minLength: 12)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.ink)
                    .accessibilityHidden(true)
                Text("Du kan fortsätta medan den laddas ned i bakgrunden.")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.card))
        }
        .transition(.opacity)
    }

    // MARK: Here

    /// Ready: the title's two halves, in the room and in a call — how each one starts —
    /// and at the foot that what it needs is here.
    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsLabel(String(localized: "Så börjar ett möte"))
            way(icon: "person.2.wave.2", title: "I rummet") { MeetingShortcutLine() }
                .padding(.top, 16)
            way(icon: "phone", title: "I samtal") {
                Text("När ett samtal i Teams, Zoom eller Meet börjar frågar Mindtalk först. Inget spelas in förrän du trycker.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
            Spacer(minLength: 12)
            HStack(spacing: 9) {
                DoneCheck(animate: celebrate, size: 22)
                Text("Röstmodellen finns på din Mac.")
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private func way<Detail: View>(icon: String, title: LocalizedStringKey, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
            detail()
        }
        .accessibilityElement(children: .combine)
    }

    /// Ready, as this card shows it (the render's `--voices-state` too).
    static var isReady: Bool {
        #if DEBUG
        if let preview { if case .ready = preview { return true } else { return false } }
        #endif
        if case .ready = VoiceModels.shared.state { return true }
        return false
    }

    #if DEBUG
    /// `--voices-state missing|downloading|failed|ready`: how the card looks in each, for
    /// the render — never downloads.
    static let preview: VoiceModels.State? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--voices-state"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "missing": return .missing
        case "downloading": return .downloading(0.42)
        case "failed": return .failed("Internetanslutningen verkar vara bruten.")
        case "ready": return .ready
        default: return nil
        }
    }()
    #endif
}

/// The check when the model is in place: the disc springs in (the step's one bounce)
/// and the tick draws itself. Already there when you arrive: simply there.
private struct DoneCheck: View {
    let animate: Bool
    var size: CGFloat = 52
    @State private var disc = false
    @State private var tick = false

    var body: some View {
        // The same disc as a granted permission's (52, a 20 pt check), drawn so it can animate.
        ZStack {
            Circle().fill(DS.Colors.ink)
            CheckShape()
                .trim(from: 0, to: tick ? 1 : 0)
                .stroke(DS.Colors.onInk, style: StrokeStyle(lineWidth: 2.5 * max(0.6, size / 52), lineCap: .round, lineJoin: .round))
                .frame(width: 20 * size / 52, height: 16 * size / 52)
        }
        .frame(width: size, height: size)
        .scaleEffect(disc ? 1 : 0.5)
        .opacity(disc ? 1 : 0)
        .shadow(color: .black.opacity(size > 30 ? 0.18 : 0), radius: 10, y: 4)
        .accessibilityHidden(true)
        .onAppear {
            guard animate else { disc = true; tick = true; return }
            withAnimation(.spring(duration: 0.6, bounce: 0.4)) { disc = true }
            withAnimation(.smooth(duration: 0.45).delay(0.2)) { tick = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.02))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY - r.height * 0.12))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        return p
    }
}
