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
        // Away from the page while the explanation was up: the round goes on as it
        // always has, unseen, and ends by itself.
        .onDisappear { if session.introducing, let round = session.round, round.explaining { round.begin() } }
    }

    /// The scene, following the round.
    private struct Room: View {
        let scanner: VoiceScanner
        @ObservedObject var round: IntroRound
        let lit: Bool
        let shown: Bool
        @ObservedObject private var memory = VoiceMemory.shared
        @FocusState private var nameFocused: Bool

        var body: some View {
            GeometryReader { geo in
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let colour = SpeakerMark.fill(round.captures.count)
                    Constellation(figure: round.figure, color: colour, level: scanner.roomLevel,
                                  searching: round.phase == .listening && round.progress > 0)
                    .overlay { if round.explaining { explanation } else { ring(in: geo.size, colour: colour) } }
                    .overlay(alignment: .topLeading) { if !round.explaining { heading.padding(.leading, 40).padding(.top, 34) } }
                    .overlay(alignment: .topTrailing) {
                        if !round.explaining { scanner.continueButton(round).padding(24) }
                    }
                    .overlay(alignment: .bottom) { if !round.explaining { prompt(width: geo.size.width).padding(.bottom, 40) } }
                    .overlay(alignment: .bottomLeading) { if !round.explaining { room.padding(.leading, 40).padding(.bottom, 38) } }
                    .overlay(alignment: .bottomTrailing) { if !round.explaining { card.padding(24) } }
                    .opacity(shown ? 1 : 0)
                    .background(Self.night.opacity(lit ? 1 : 0))
                }
            }
            .animation(.spring(duration: 0.5, bounce: 0.2), value: round.captures)
            .animation(.easeOut(duration: 0.35), value: round.phase)
            .animation(.easeOut(duration: 0.4), value: round.explaining)
            .onChange(of: round.phase) { _, phase in
                switch phase {
                case .known(let name):
                    scanner.chime("Glass")
                    AccessibilityNotification.Announcement(String(localized: "Känd röst: \(name)")).post()
                case .new:
                    scanner.chime("Pop")
                    nameFocused = true
                default: break
                }
            }
            .onChange(of: round.captures.count) { old, new in if new > old { scanner.chime("Pop") } }
            .onChange(of: round.wantsToEnd) { _, end in if end { scanner.leave() } }
        }

        /// The ring around the cloud: fills as the person speaks (Face ID–like).
        @ViewBuilder private func ring(in size: CGSize, colour: Color) -> some View {
            if round.phase == .listening {
                let r = min(size.width, size.height) * 0.28 * 1.16
                let c = Constellation.rgb(colour)
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1.5)
                    Circle().trim(from: 0, to: round.progress)
                        .stroke(Color(red: c.x, green: c.y, blue: c.z), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: round.progress)
                }
                .frame(width: r * 2, height: r * 2)
                .position(x: size.width / 2, y: size.height * 0.42)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }

        /// The first round ever: what it is and why, before it listens — and a way past it.
        private var explanation: some View {
            RoundExplanation(remembers: $memory.enabled,
                             begin: { round.begin() },
                             skip: { round.declineExplained(); scanner.leave() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
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
                Text("Så att texten visar vem som säger vad. Mötet spelas redan in.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
        }

        /// Below the cloud: the turn, what Mindtalk is doing, and the name once it knows it.
        private var words: (status: String, big: String?, line: String) {
            {
                // The speech model still loading (it can take a minute after a macOS
                // update): recording already, but nothing to listen with yet.
                if scanner.session.phase == .starting {
                    return (String(localized: "Förbereder"), String(localized: "Ett ögonblick…"),
                            String(localized: "Inspelningen är igång. Efter en uppdatering av macOS kan förberedelserna ta upp till en minut."))
                }
                switch round.phase {
                // Asked until someone starts talking — not only for the moment the turn opens.
                // Right after someone was added, thanked first: "Tack, Anna! Nästa person…"
                case .ready, .listening where round.progress == 0:
                    if let last = round.captures.last, let at = round.thankedAt, Date().timeIntervalSince(at) < 2.5 {
                        return (String(localized: "Person \(round.turn)"), String(localized: "Tack, \(last.name)"),
                                String(localized: "Nästa person – säg hej och ditt namn."))
                    }
                    return round.turn == 1
                        ? (String(localized: "Person 1"), String(localized: "Säg ditt namn"), String(localized: "Börja med att säga hej – en i taget."))
                        : (String(localized: "Person \(round.turn)"), String(localized: "Nästa – säg ditt namn"), String(localized: "Samma sak – en i taget."))
                case .listening:
                    return round.quiet
                        ? (String(localized: "Hör ingen"), String(localized: "Prata lite närmare"), String(localized: "Mikrofonen hör dig inte riktigt."))
                        : (String(localized: "Person \(round.turn)"), String(localized: "Jag lyssnar…"), String(localized: "Prata på en stund."))
                case .known(let name):
                    return (String(localized: "Känd röst"), String(localized: "Tack, \(name)"), String(localized: "Välkommen tillbaka."))
                case .new:
                    let name = round.draft.trimmingCharacters(in: .whitespaces)
                    return (String(localized: "Ny röst"), name.isEmpty ? String(localized: "Vad heter du?") : name,
                            name.isEmpty ? String(localized: "Säg ditt namn.") : String(localized: "Stämmer namnet?"))
                case .same(let name):
                    return (String(localized: "Samma röst"), String(localized: "\(name) igen"), String(localized: "Nästa person, tack."))
                case .closing:
                    return (String(localized: "Är alla här?"), String(localized: "\(round.captures.count) i rummet"),
                            String(localized: "Fortsätter om \(round.secondsLeft ?? 0)…"))
                }
            }()
        }

        private func prompt(width: CGFloat) -> some View {
            let (_, big, line) = words
            let accent = Constellation.rgb(SpeakerMark.fill(round.captures.count))
            let tint = Color(red: accent.x, green: accent.y, blue: accent.z)

            return VStack(spacing: 12) {
                Text(big ?? " ")
                    .font(.system(size: min(88, max(52, width * 0.075)), weight: .regular, design: .serif)).italic()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: max(200, width - 2 * 340))
                    .opacity(big == nil ? 0 : 1)
                    .blur(radius: big == nil ? 14 : 0)
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
                    ForEach(round.captures) { c in
                        let rgb = Constellation.rgb(SpeakerMark.fill(c.colour))
                        let tint = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
                        HStack(spacing: 10) {
                            VoiceFigureMark(figure: c.figure, color: tint, lineWidth: 1).frame(width: 16, height: 16)
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
                    Text("Ny röst – säg namnet, eller skriv det").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
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
                            Text("Sparas om \(max(0, Int(ceil(at.timeIntervalSinceNow)))) s – skriv för att ändra")
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

    /// The room's level, a little smoothed — the light shouldn't flicker.
    var roomLevel: Double {
        let levels = LiveMeter.shared.levels.suffix(5)
        return levels.isEmpty ? 0 : min(1, Double(levels.reduce(0, +)) / Double(levels.count) * 1.6)
    }

    // MARK: Text and cards

    func continueButton(_ round: IntroRound) -> some View {
        Button(action: leave) {
            Text(round.captures.isEmpty ? "Hoppa över – börja mötet" : "Alla är här – fortsätt")
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
        guard Settings.sounds, !session.usesBluetooth, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
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

/// "Först: vem är här?" — the first time a meeting starts with the round: what it is,
/// why, what's kept, and a way past it.
struct RoundExplanation: View {
    @Binding var remembers: Bool
    let begin: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Först: vem är här?").font(.system(size: 32, weight: .regular, design: .serif))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Var och en säger hej och sitt namn, en i taget. Då vet Mindtalk vem som säger vad i texten. Det tar en halv minut.")
                .font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
            // A choice, made here and not by default: the voices are other people's.
            Toggle(isOn: $remembers) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Känn igen rösterna i kommande möten").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    Text("Bara ett röstavtryck sparas på din Mac, aldrig ljud. Säg till de andra i rummet.")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
            HStack(spacing: 18) {
                Button(action: begin) {
                    Text("Börja").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).frame(minHeight: 32)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button(action: skip) {
                    Text("Hoppa över – namnge efteråt").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 460, alignment: .leading)
        .padding(32)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(DS.Colors.night.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
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
                    Text("Spara rösterna så att \(Self.list(names)) känns igen nästa gång?")
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
