import AppKit
import SwiftUI

// MARK: - Vem är här? (the guided round)
//
// One person at a time (IntroRound.swift): "Tur 1 – säg hej, ditt namn och vad du gör
// här." A ring fills around the cloud as they speak; a voice Mindtalk knows is
// greeted in a second or two ("Välkommen tillbaka, Anna") and the round moves on by
// itself; a new one gets a card with the name it said filled in. Those found gather
// in the corner, "I rummet". When nobody new speaks, it counts down and the meeting
// goes on — recorded from the first word, everyone named.

struct VoiceScanner: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var memory = VoiceMemory.shared
    /// The dark coming in (the panel), then what's in it (the cloud, the words).
    @State private var lit = false
    @State private var shown = false
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let round = session.round { Room(scanner: self, round: round, lit: lit, shown: shown) } else { Color.clear }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(lit ? 0.08 : 0), lineWidth: 1))
        .scaleEffect(lit ? 1 : 0.985)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 88)
        .environment(\.colorScheme, .dark)
        .onAppear(perform: enter)
    }

    /// The scene, following the round.
    private struct Room: View {
        let scanner: VoiceScanner
        @ObservedObject var round: IntroRound
        let lit: Bool
        let shown: Bool
        @ObservedObject private var memory = VoiceMemory.shared
        @FocusState private var nameFocused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// The moment a name is settled, shown on the cloud: the voice's figure drawn
        /// clearly, its signature beside the name. It stands there at least three
        /// seconds, and after that until the next person's voice is heard; then it
        /// flies down into "I rummet". Purely a picture over the round, which goes on
        /// underneath as before: the next turn listens from the first moment.
        struct Reveal: Equatable {
            let id = UUID()
            let name: String
            let known: Bool
            /// The capture it is (a new voice), whose print may still be on its way.
            let capture: UUID?
            let figure: VoiceFigure?
            let colour: Int
            /// The turn it was settled in: the next turn's voice sends it down.
            let turn: Int
            /// The signature as it formed from the voice's levels, for as long as
            /// there is no print to draw it from.
            var bars: [Double] = []
            /// A print of its own for the picture (screenshots); otherwise looked up.
            var print: [Float]?
            var flying = false
        }
        @State private var reveal: Reveal?
        /// When the reveal came up: it stands at least this long.
        @State private var shownAt: Date?
        static let hold = 3.0
        /// The ring's single pulse.
        @State private var pulse = false
        @State private var revealTask: Task<Void, Never>?
        /// The large signature is one view from the first bar to the name: this keeps
        /// it so, and changes when it has flown down (the next one is new).
        @State private var signatureKey = UUID()
        /// The width of the name row, so the signature knows where its place in it is.
        @State private var rowWidth: CGFloat?
        /// A still picture (screenshots): nothing in motion, the signature in its row.
        private let still: Bool

        init(scanner: VoiceScanner, round: IntroRound, lit: Bool, shown: Bool, still: Bool = false) {
            self.scanner = scanner
            self.round = round
            self.lit = lit
            self.shown = shown
            self.still = still
            #if DEBUG
            // A still picture of the moment (`--demo-phase reveal`).
            if let d = round.demoReveal {
                _reveal = State(initialValue: Reveal(name: d.name, known: d.known, capture: round.captures.last?.id, figure: round.figure,
                                                     colour: round.captures.count - 1, turn: round.turn - 1, print: d.print))
            }
            #endif
        }

        /// The reveal while it stands on the cloud (not yet flying down).
        private var revealing: Reveal? { reveal.flatMap { $0.flying ? nil : $0 } }

        /// The signature forming beside the cloud: while someone talks (the ring
        /// filling) and while a new voice is asked its name.
        private var forming: Bool {
            guard revealing == nil else { return false }
            switch round.phase {
            case .listening: return round.progress > 0
            case .new: return true
            default: return false
            }
        }

        /// The forming signature's bars: from a print of the turn so far once there is
        /// one, before that from how the voice has risen and fallen.
        private var formingBars: [Double] {
            round.formingPrint.map { VoiceSignature.bars(of: $0, count: VoiceSignature.Size.large.bars) } ?? Self.bars(fromLevels: round.levels)
        }

        private static func bars(fromLevels levels: [Float]) -> [Double] {
            VoiceSignature.bars(fromLevels: levels, span: IntroRound.levelsInRing, count: VoiceSignature.Size.large.bars)
        }

        var body: some View {
            GeometryReader { geo in
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let colour = SpeakerMark.fill(revealing?.colour ?? round.captures.count)
                    Constellation(figure: revealing?.figure ?? round.figure, color: colour, level: scanner.roomLevel,
                                  searching: round.phase == .listening && round.progress > 0, defined: revealing != nil)
                    .overlay { ring(in: geo.size, colour: colour) }
                    .overlay(alignment: .topLeading) { heading.padding(.leading, 40).padding(.top, 34) }
                    .overlay(alignment: .topTrailing) { scanner.continueButton(round).padding(24) }
                    .overlay(alignment: .bottom) { prompt(width: geo.size.width).padding(.bottom, 40) }
                    // Over the words' gradient: the name stands where the big line was.
                    .overlay { revealView(in: geo.size) }
                    .overlay { signature(in: geo.size) }
                    .overlay(alignment: .bottomLeading) { room.padding(.leading, 40).padding(.bottom, 38) }
                    .overlay(alignment: .bottomTrailing) { card.padding(24) }
                    .opacity(shown ? 1 : 0)
                    .background(Self.night.opacity(lit ? 1 : 0))
                }
            }
            .animation(.spring(duration: 0.5, bounce: 0.2), value: round.captures)
            .animation(.easeOut(duration: 0.35), value: round.phase)
            .onChange(of: round.phase) { _, phase in
                switch phase {
                case .known(let name):
                    scanner.chime("Glass")
                    AccessibilityNotification.Announcement(String(localized: "Känd röst: \(name)")).post()
                    show(Reveal(name: name, known: true, capture: nil, figure: round.figure, colour: round.captures.count,
                                turn: round.turn, bars: Self.bars(fromLevels: round.levels)))
                case .new:
                    scanner.chime("Pop")
                    nameFocused = true
                default: break
                }
                moveOn()
            }
            .onChange(of: round.captures.count) { old, new in
                guard new > old else { return }
                scanner.chime("Pop")
                // A new voice named: its print is made. (A known one was shown when greeted.)
                // The round has already begun the next turn: the capture was the one before.
                if let c = round.captures.last, !c.known {
                    AccessibilityNotification.Announcement(String(localized: "Röstavtryck sparat för \(c.name)")).post()
                    show(Reveal(name: c.name, known: false, capture: c.id, figure: c.figure, colour: c.colour,
                                turn: round.turn - 1, bars: Self.bars(fromLevels: c.levels)))
                }
            }
            // The next person's voice: the reveal has had its time, down it goes.
            .onChange(of: round.progress) { _, _ in moveOn() }
            .onChange(of: round.wantsToEnd) { _, end in if end { scanner.leave() } }
        }

        // MARK: The moment

        /// All of it over the round going on: the ring closes and pulses once, the
        /// signature glides in from beside the cloud and settles into the print, and
        /// the name stands under the cloud. It stays at least three seconds, and then
        /// until the next person is heard (`moveOn`). With Reduce Motion it fades in
        /// and out instead.
        private func show(_ r: Reveal) {
            revealTask?.cancel()
            pulse = false
            shownAt = Date()
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.3)) { reveal = r }
            } else {
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) { reveal = r }
                withAnimation(.easeOut(duration: 0.7)) { pulse = true }
            }
            revealTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.hold))
                guard !Task.isCancelled, reveal?.id == r.id else { return }
                moveOn()
            }
        }

        /// The reveal flies down into "I rummet" once it has stood its time and the
        /// next person has begun to talk (a third of a second of speech in the next
        /// turn), or the round is closing. Until then it stays: the room gets to see it.
        private func moveOn() {
            guard let r = reveal, !r.flying, let at = shownAt, Date().timeIntervalSince(at) >= Self.hold else { return }
            let nextVoice = round.turn > r.turn && round.progress >= 0.1
            let closing = { if case .closing = round.phase { return true }; return round.wantsToEnd }()
            guard nextVoice || closing else { return }
            fly(r)
        }

        private func fly(_ r: Reveal) {
            revealTask?.cancel()
            // The row takes the signature with it; the one that glided in is done.
            signatureKey = UUID()
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.4)) { reveal = nil }
                return
            }
            withAnimation(.easeIn(duration: 0.5)) { reveal?.flying = true }
            revealTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.55))
                guard !Task.isCancelled, reveal?.id == r.id else { return }
                reveal = nil
            }
        }

        /// The print a capture's signature is drawn from: for a voice Mindtalk knows,
        /// the one it knows them by (the same signature every time); otherwise this
        /// round's print of them.
        private func signaturePrint(of c: IntroRound.Capture) -> [Float]? {
            (c.known ? memory.signaturePrint(of: c.name) : nil) ?? c.print
        }

        private func signaturePrint(of r: Reveal) -> [Float]? {
            if let print = r.print { return print }
            if r.known, let print = memory.signaturePrint(of: r.name) { return print }
            return round.captures.first { $0.id == r.capture }?.print
        }

        /// The bars of a reveal's signature: from its print when there is one (it can
        /// still be on its way), otherwise as it formed from the voice.
        private func bars(of r: Reveal) -> [Double]? {
            if let print = signaturePrint(of: r) { return VoiceSignature.bars(of: print, count: VoiceSignature.Size.large.bars) }
            return r.bars.contains { $0 > 0 } ? r.bars : nil
        }

        /// Where things stand: the cloud's centre, and the row under it.
        private func cloudCentre(in size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.42) }
        private func rowY(in size: CGSize) -> CGFloat { size.height * 0.42 + min(size.width, size.height) * 0.28 * 1.16 + 58 }

        /// The large signature, one view the whole way: forming beside the cloud while
        /// the person talks (bar by bar, with the ring), then gliding down into its place
        /// beside the name and settling into the print. With Reduce Motion, or in a
        /// still picture, the row draws its own and this one fades.
        @ViewBuilder private func signature(in size: CGSize) -> some View {
            let standing = revealing != nil && !reduceMotion && !still
            if standing || forming {
                let colour = revealing?.colour ?? round.captures.count
                let rgb = Constellation.rgb(SpeakerMark.fill(colour))
                let tint = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
                let bars = revealing.map { bars(of: $0) ?? [] } ?? formingBars
                let centre = cloudCentre(in: size)
                let R = min(size.width, size.height) * 0.28 * 1.16
                // Beside the cloud, to the right of the ring; in the row, the row's left end.
                let at = revealing.map { r in
                    let width = rowWidth ?? 74 + CGFloat(r.name.count) * 19
                    return CGPoint(x: size.width / 2 - width / 2 + VoiceSignature.Size.large.points / 2, y: rowY(in: size))
                } ?? CGPoint(x: centre.x + R + 84, y: centre.y)
                // Half as large again while it forms, seen from across the room; its row's
                // size once it is in the row.
                VoiceSignature(bars: bars, color: tint, size: .large, progress: revealing != nil ? 1 : round.progress)
                    .animation(.easeOut(duration: 0.25), value: round.progress)
                    .animation(.easeOut(duration: 0.6), value: bars)
                    .scaleEffect(revealing != nil ? 1 : 1.5)
                    .position(at)
                    .animation(.spring(duration: 0.55, bounce: 0.15), value: at)
                    // Gone the moment it flies: the row's own takes over in its place.
                    .transition(.asymmetric(insertion: .opacity, removal: reduceMotion ? .opacity : .identity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .id(signatureKey)
            }
        }

        /// The name and its signature under the cloud — and, flying, down in the corner.
        @ViewBuilder private func revealView(in size: CGSize) -> some View {
            if let reveal {
                let rgb = Constellation.rgb(SpeakerMark.fill(reveal.colour))
                let tint = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
                let flying = reveal.flying
                let points = VoiceSignature.Size.large.points
                HStack(spacing: 18) {
                    if let bars = bars(of: reveal) {
                        // Standing, the signature that glided in draws itself here (`signature`);
                        // the row holds its place. Flying, the row takes it along.
                        if flying || reduceMotion || still {
                            VoiceSignature(bars: bars, color: tint, size: .large)
                        } else {
                            Color.clear.frame(width: points, height: points)
                        }
                    } else {
                        VoiceFigureMark(figure: reveal.figure ?? VoiceFigure.from(seed: reveal.name), color: tint, lineWidth: 1.3)
                            .frame(width: points, height: points)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(reveal.known ? "Känd röst" : "Röstavtryck sparat").textCase(.uppercase).tracking(2.4)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(reveal.name).font(.system(size: 34, weight: .regular, design: .serif))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                .scaleEffect(flying ? 0.28 : 1)
                .opacity(flying ? 0 : 1)
                .position(x: flying ? 40 + 70 : size.width / 2,
                          y: flying ? size.height - 38 - 11 : rowY(in: size))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .id(reveal.id)
            }
        }

        /// The ring around the cloud: fills as the person speaks (Face ID–like), and
        /// closes with one pulse the moment the name is settled.
        @ViewBuilder private func ring(in size: CGSize, colour: Color) -> some View {
            let r = min(size.width, size.height) * 0.28 * 1.16
            let c = Constellation.rgb(colour)
            let tint = Color(red: c.x, green: c.y, blue: c.z)
            if let reveal, !reveal.flying {
                ZStack {
                    Circle().stroke(tint, lineWidth: 2)
                    if !reduceMotion {
                        Circle().stroke(tint.opacity(pulse ? 0 : 0.9), lineWidth: 2)
                            .scaleEffect(pulse ? 1.14 : 1)
                    }
                }
                .frame(width: r * 2, height: r * 2)
                .position(x: size.width / 2, y: size.height * 0.42)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
                .id(reveal.id)
            } else if round.phase == .listening {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1.5)
                    Circle().trim(from: 0, to: round.progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: round.progress)
                }
                .frame(width: r * 2, height: r * 2)
                .position(x: size.width / 2, y: size.height * 0.42)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }

        private var heading: some View {
            VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Vem är här?").font(.system(size: 32, weight: .regular, design: .serif))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityAddTraits(.isHeader)
                // One dot per person: found, and the one whose turn it is.
                HStack(spacing: 6) {
                    ForEach(0..<max(round.turn, round.captures.count), id: \.self) { i in
                        Circle().fill(i < round.captures.count ? .white.opacity(0.85) : .white.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
                // Where the round is: "Person 2", "Ny röst", "Känd röst".
                let accent = Constellation.rgb(SpeakerMark.fill(round.captures.count))
                let tint = Color(red: accent.x, green: accent.y, blue: accent.z)
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 6, height: 6).shadow(color: tint, radius: 6)
                    Text(words.status).textCase(.uppercase).tracking(2.4)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                }
                .padding(.leading, 10)
            }
                Text("Inspelningen är igång. Namnen gör att texten visar vem som säger vad.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
        }

        /// Below the cloud: the turn, what Mindtalk is doing, and the name once it knows it.
        private var words: (status: String, big: String?, line: String) {
            {
                // The speech model still loading (it can take a minute after a macOS
                // update): recording already, but nothing to listen with yet.
                if scanner.session.phase == .starting {
                    return (String(localized: "Förbereder"), String(localized: "Strax klart"),
                            String(localized: "Talmodellen förbereds. Det händer bara första gången. Inspelningen är igång och inget går förlorat."))
                }
                switch round.phase {
                // Asked until someone starts talking — not only for the moment the turn opens.
                // Right after someone was added, thanked first: "Tack, Anna! Nästa person…" —
                // and for as long as their name stands on the cloud, so the room knows it
                // can go on.
                case .ready, .listening where round.progress == 0:
                    if let last = round.captures.last,
                       revealing != nil || round.thankedAt.map({ Date().timeIntervalSince($0) < 2.5 }) == true {
                        return (String(localized: "Person \(round.turn)"), String(localized: "Tack, \(last.name)"),
                                String(localized: "Nästa person, säg hej och vad du heter."))
                    }
                    return round.turn == 1
                        ? (String(localized: "Person 1"), String(localized: "Vem vill börja?"), String(localized: "Säg hej och ditt namn, en i taget."))
                        : (String(localized: "Person \(round.turn)"), String(localized: "Nästa, säg ditt namn"), String(localized: "Det räcker med hej och ditt namn."))
                case .listening:
                    return round.quiet
                        ? (String(localized: "Hör inget"), String(localized: "Kom lite närmare"), String(localized: "Mikrofonen hör dig knappt."))
                        : (String(localized: "Person \(round.turn)"), String(localized: "Jag lyssnar…"), String(localized: "Säg ditt namn, så går vi vidare."))
                case .known(let name):
                    return (String(localized: "Känd röst"), String(localized: "Välkommen tillbaka, \(name)"), String(localized: "Jag känner igen rösten."))
                case .new:
                    let name = round.draft.trimmingCharacters(in: .whitespaces)
                    return (String(localized: "Ny röst"), name.isEmpty ? String(localized: "Vad heter du?") : name,
                            name.isEmpty ? String(localized: "Säg ditt namn, eller skriv det i rutan.") : String(localized: "Stämmer det? Annars kan du ändra i rutan."))
                case .same(let name):
                    return (String(localized: "Samma röst"), String(localized: "Det är \(name) igen"), String(localized: "Nästa person, varsågod."))
                case .closing:
                    return (String(localized: "Alla här?"), String(localized: "\(round.captures.count) i rummet"),
                            String(localized: "Vi går vidare om \(round.secondsLeft ?? 0)…"))
                }
            }()
        }

        private func prompt(width: CGFloat) -> some View {
            let (_, big, line) = words
            let accent = Constellation.rgb(SpeakerMark.fill(round.captures.count))
            let tint = Color(red: accent.x, green: accent.y, blue: accent.z)

            // The name stands over the cloud for a moment (the reveal): the big line
            // waits until it has flown down.
            let hidden = big == nil || revealing != nil
            return VStack(spacing: 12) {
                Text(big ?? " ")
                    .font(.system(size: min(88, max(52, width * 0.075)), weight: .regular, design: .serif)).italic()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: max(200, width - 2 * 340))
                    .opacity(hidden ? 0 : 1)
                    .blur(radius: hidden ? 14 : 0)
                    .animation(.easeOut(duration: 0.35), value: hidden)
                    .contentTransition(.opacity)
                Text(line).font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
                if round.phase == .listening || { if case .known = round.phase { return true }; return false }() {
                    Button { round.next() } label: {
                        Text("Nästa").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.defaultAction)
                    .disabled(round.phase == .listening && round.progress < 0.5)
                    .help("Nästa person (↩)")
                }
            }
            .padding(.top, 70)
            .frame(maxWidth: .infinity)
            // The cloud fades out behind the words, so they read over it.
            .background(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Self.night.opacity(0.92), location: 0.45),
                                       .init(color: Self.night, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -40)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .combine)
        }

        static let night = DS.Colors.night

        /// The ones found so far.
        @ViewBuilder private var room: some View {
            if !round.captures.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("I rummet").textCase(.uppercase).tracking(2.2)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    // The one just named takes its row once it has flown down.
                    ForEach(round.captures.filter { $0.id != revealing?.capture }) { c in
                        let rgb = Constellation.rgb(SpeakerMark.fill(c.colour))
                        let tint = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
                        HStack(spacing: 10) {
                            // Their signature, drawn from the voiceprint; the figure
                            // until there is one.
                            if let print = signaturePrint(of: c) {
                                VoiceSignature(print: print, color: tint, size: .compact)
                            } else {
                                VoiceFigureMark(figure: c.figure, color: tint, lineWidth: 1).frame(width: 16, height: 16)
                            }
                            Text(c.name).font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                            if c.known { Image(systemName: "checkmark.seal.fill").font(.system(size: 10.5)).foregroundStyle(tint) }
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
        }

        /// A new voice: who is it? The name said is filled in and saves by itself.
        @ViewBuilder private var card: some View {
            if case .new = round.phase {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ny röst. Säg namnet eller skriv det här").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    // Not "Namn": macOS would offer your contacts in a box over the card.
                    TextField("Vem är det?", text: $round.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold))
                        .textContentType(nil)
                        .autocorrectionDisabled(true)
                        .focused($nameFocused)
                        .onSubmit { round.save() }
                    if let at = round.autoSaveAt {
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            Text("Sparas om \(max(0, Int(ceil(at.timeIntervalSinceNow)))) s. Blev det fel? Skriv rätt namn.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Spara") { round.save() }.buttonStyle(.glassProminent).fixedSize()
                            .disabled(round.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer(minLength: 0)
                        Button("Hoppa över") { round.skipName() }.buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(16)
                .frame(width: 300, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                .onChange(of: round.draft) { _, _ in round.typing() }
            }
        }
    }

    #if DEBUG
    /// Screenshots: the room as it stands for a round (`--render-round`), lit and shown.
    static func still(round: IntroRound, size: CGSize) -> some View {
        Room(scanner: VoiceScanner(session: .shared), round: round, lit: true, shown: true, still: true)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
    #endif

    /// The room's level, a little smoothed — the light shouldn't flicker.
    var roomLevel: Double {
        let levels = LiveMeter.shared.levels.suffix(5)
        return levels.isEmpty ? 0 : min(1, Double(levels.reduce(0, +)) / Double(levels.count) * 1.6)
    }

    // MARK: Text and cards

    func continueButton(_ round: IntroRound) -> some View {
        Button(action: leave) {
            (round.captures.isEmpty ? Text("Hoppa över namnrundan") : Text("Alla är här"))
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Alla är här (⌘↩)")
    }

    // MARK: Actions

    /// The lights going down, like a cinema's: the dark first, then the room in it.
    private func enter() {
        #if DEBUG
        // `--demo-leave`: "Alla är här" pressed by itself after four seconds (screenshots).
        if CommandLine.arguments.contains("--demo-leave") {
            let after = MeetingSession.argSeconds("--demo-leave") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { print("[runda] Alla är här trycks"); leave() }
        }
        #endif
        guard !reduceMotion else { lit = true; shown = true; return }
        withAnimation(.easeInOut(duration: 0.9)) { lit = true }
        withAnimation(.easeOut(duration: 0.8).delay(0.45)) { shown = true }
    }

    /// "Alla är här": the room fades, the lights come up, and the meeting is there.
    func leave() {
        guard !reduceMotion else { session.endIntroduction(); return }
        withAnimation(.easeIn(duration: 0.3)) { shown = false }
        withAnimation(.easeInOut(duration: 0.6).delay(0.2)) { lit = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            withAnimation(.easeOut(duration: 0.3)) { session.endIntroduction() }
        }
    }

    /// A soft sound — never into a Bluetooth headset (its mic can go when a sound there ends).
    func chime(_ name: String) {
        guard Settings.sounds, !session.soundsReachBluetooth, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = 0.12
        sound.play()
    }

    // MARK: "Jag heter Anna"

    /// The name someone gave: "jag heter Anna", "det är Erik", "I'm Sara" — capitalised,
    /// and not an ordinary word that happens to start a sentence.
    static func spokenName(in text: String) -> String? {
        // The lead-in in any case ("Jag heter", "jag heter"), the name with its capital.
        // "Jag heter …" takes any name; "det är …" only a first name people have —
        // "det är Volvo" is no introduction.
        let said = #"[ ,]+(\p{Lu}[\p{L}\-]+(?: \p{Lu}[\p{L}\-]+)?)"#
        let strong = #"(?i:jag heter|jag är|mitt namn är|i'm|i’m|i am|my name is|my name's|my name’s)"# + said
        let weak = #"(?i:det här är|det här var|det är|här är|this is)"# + said
        let range = NSRange(location: 0, length: (text as NSString).length)
        var found: NSTextCheckingResult?
        if let regex = try? NSRegularExpression(pattern: strong), let m = regex.firstMatch(in: text, range: range) {
            found = m
        } else if let regex = try? NSRegularExpression(pattern: weak), let m = regex.firstMatch(in: text, range: range),
                  let first = (text as NSString).substring(with: m.range(at: 1)).split(separator: " ").first,
                  FirstNames.isName(String(first)) {
            found = m
        }
        guard let m = found else { return nil }
        var name = (text as NSString).substring(with: m.range(at: 1))
        guard name.first?.isUppercase == true,
              !["Jag", "Det", "Du", "Vi", "Ni", "Bra", "Okej", "Nu", "Här", "The", "It"].contains(name) else { return nil }
        // "Matilda Hej": the next person's greeting, not a surname.
        let parts = name.split(separator: " ").map(String.init)
        if parts.count == 2, greetings.contains(parts[1].lowercased()) {
            name = parts[0]
        }
        return name
    }

    /// What people say before or between names — never a name.
    static let greetings: Set<String> = ["hej", "hejsan", "hallå", "tjena", "tja", "tjenare", "morsning", "god", "hi", "hello", "hey", "ja", "nej", "okej", "ok", "tack"]
}

/// "Spara rösterna?" — once, under a meeting whose people were named, while voice
/// memory is off: the moment it's easiest to see what it's for (and to ask the room).
struct RememberVoicesOffer: View {
    let record: MeetingRecord
    let live: Bool
    var preview = false
    @ObservedObject private var memory = VoiceMemory.shared
    @AppStorage("voiceMemoryAsked") private var asked = false

    var body: some View {
        let names = VoiceMemory.namesToRemember(in: record)
        if preview || (!memory.enabled && !asked && !names.isEmpty) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "person.wave.2").font(.system(size: 16)).foregroundStyle(DS.Colors.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spara rösterna så att Mindtalk känner igen \(Self.list(names)) nästa gång?")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Bara ett röstavtryck sparas på din Mac, aldrig ljud. Fråga de andra i rummet först.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Inte nu") { withAnimation(.snappy) { asked = true } }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                Button("Spara") {
                    withAnimation(.snappy) { asked = true }
                    memory.turnOn(learningFrom: live ? nil : record)
                }
                .buttonStyle(.ink)
            }
            .padding(16)
            .card()
            .transition(.opacity)
        }
    }

    /// "Anna", "Anna och Erik", "Anna, Erik och Sara" — and past three, "alla fyra".
    static func list(_ names: [String]) -> String {
        guard names.count <= 3 else { return String(localized: "alla \(names.count)") }
        return ListFormatter.localizedString(byJoining: names)
    }
}
