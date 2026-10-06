import AppKit
import SwiftUI

// MARK: - Vem är här? (the introduction round)
//
// "Med presentation" begins the meeting with the room's voices finding their place:
// a slow aurora that wakes when someone speaks and takes on each voice's colour,
// and for every voice a ring of its own — its shape drawn from the voiceprint, so
// no two are alike (VoiceSigil.swift). Whoever is speaking makes their ring breathe
// and ripple. A voice you've named before is greeted — "Välkommen tillbaka, Anna";
// a new one gets a glass card asking who it is, the name already filled in when
// they said "jag heter Erik". "Alla är här" and the meeting goes on, recorded from
// the first word, everyone named.

struct VoiceScanner: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var memory = VoiceMemory.shared
    @State private var drafts: [Int: String] = [:]
    @State private var later: Set<Int> = []
    @State private var greeting: String?
    @State private var greeted: Set<Int> = []
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A voice in the room once it has said something real — a second and a half.
    struct Voice: Identifiable, Equatable {
        let speaker: Int
        let lane: Int
        let speech: Double
        let name: String?
        let known: Bool
        let said: String
        var id: Int { speaker }
    }

    private var voices: [Voice] {
        guard let record = session.record else { return [] }
        let cast = record.cast
        var speech: [Int: Double] = [:]
        var words: [Int: [String]] = [:]
        for w in record.words + session.pending {
            guard let s = w.speaker, s >= 0 else { continue }
            speech[s, default: 0] += w.end - w.start
            words[s, default: []].append(w.text)
        }
        return cast.order.enumerated().compactMap { lane, s in
            guard (speech[s] ?? 0) >= 1.5 else { return nil }
            let name = record.names[String(s)].flatMap { $0.isEmpty ? nil : $0 }
            let said = MeetingText.clean((words[s] ?? []).prefix(40).joined(separator: " "))
            return Voice(speaker: s, lane: lane, speech: speech[s] ?? 0, name: name,
                         known: record.recognized[String(s)] != nil, said: said)
        }
    }

    /// Who is talking right now: the speaker of the last word, if it was just said.
    private var activeSpeaker: Int? {
        guard let last = (session.pending.last ?? session.record?.words.last), let s = last.speaker, s >= 0 else { return nil }
        return session.elapsed - last.end < 1.4 ? s : nil
    }

    /// Recognition is on and still listening to this voice: don't ask for a name yet.
    private func recognising(_ v: Voice) -> Bool {
        memory.enabled && !memory.people.isEmpty && !session.introChecked.contains(v.speaker) && v.speech < 8
    }

    /// The newest voice without a name, waiting for one.
    private var unnamed: Voice? { voices.last { $0.name == nil && !later.contains($0.speaker) } }

    var body: some View {
        let voices = self.voices
        GeometryReader { geo in
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let level = roomLevel
                ZStack {
                    aurora(voices, time: t, level: level)
                    orbs(voices, in: geo.size, time: t, level: level)
                }
            }
            .overlay(alignment: .topLeading) { heading(voices).padding(32) }
            .overlay(alignment: .topTrailing) { consent.padding(24) }
            .overlay(alignment: .bottomTrailing) { card(voices).padding(24) }
            .overlay(alignment: .bottomLeading) { continueButton(voices).padding(24) }
            .overlay(alignment: .top) { greetingToast.padding(.top, 28) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 88)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.55, bounce: 0.25), value: voices)
        .onChange(of: voices.count) { old, new in if new > old { chime("Pop") } }
        .onChange(of: session.record?.recognized ?? [:]) { _, recognized in welcome(recognized) }
    }

    /// The room's level, a little smoothed — the light shouldn't flicker.
    private var roomLevel: Double {
        let levels = LiveMeter.shared.levels.suffix(5)
        return levels.isEmpty ? 0 : min(1, Double(levels.reduce(0, +)) / Double(levels.count) * 1.6)
    }

    // MARK: Light

    private func aurora(_ voices: [Voice], time: Double, level: Double) -> some View {
        let clock = Float(reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 10_000))
        return GeometryReader { geo in
            let layout = Layout(size: geo.size)
            let data: [Float] = voices.prefix(8).enumerated().flatMap { i, v -> [Float] in
                let p = layout.position(i, of: voices.count)
                let glow = activeSpeaker == v.speaker ? 0.35 + 0.65 * level : 0.12
                return [Float(p.x / max(geo.size.width, 1)), Float(p.y / max(geo.size.height, 1)), Float(glow)]
                    + Self.rgb(SpeakerMark.fill(v.lane))
            }
            Rectangle()
                .colorEffect(ShaderLibrary.aurora(.float2(geo.size), .float(clock), .float(Float(level)), .floatArray(data)))
        }
        .accessibilityHidden(true)
    }

    /// A speaker's colour, made vivid for a dark room: light comes in colour, not grey.
    static func rgb(_ color: Color) -> [Float] {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let vivid = NSColor(hue: h, saturation: max(s, 0.62), brightness: 0.92, alpha: 1).usingColorSpace(.sRGB) ?? c
        return [vivid.redComponent, vivid.greenComponent, vivid.blueComponent].map(Float.init)
    }

    /// Where the voices sit: around an ellipse in the middle of the room.
    struct Layout {
        let size: CGSize
        var center: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.5) }
        func position(_ i: Int, of n: Int) -> CGPoint {
            guard n > 1 else { return center }
            let rx = size.width * 0.27, ry = size.height * 0.23
            let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi
            return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
        }
    }

    // MARK: Voices

    private func orbs(_ voices: [Voice], in size: CGSize, time: Double, level: Double) -> some View {
        let layout = Layout(size: size)
        let n = voices.count
        return ZStack {
            // The ripples of whoever is speaking.
            Canvas { ctx, _ in
                guard !reduceMotion, let active = activeSpeaker, let i = voices.firstIndex(where: { $0.speaker == active }) else { return }
                let p = layout.position(i, of: n)
                let colour = SpeakerMark.fill(voices[i].lane)
                for k in 0..<3 {
                    let phase = (time * 0.7 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let r = 56 + 150 * phase
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(colour.opacity(0.45 * (1 - phase))), lineWidth: 1.5)
                }
            }
            ForEach(Array(voices.enumerated()), id: \.element.id) { i, v in
                orb(v, time: time, level: activeSpeaker == v.speaker ? level : 0.05)
                    .position(layout.position(i, of: n))
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            if voices.isEmpty { listening(time: time, level: level).position(layout.center) }
        }
    }

    private func shape(for v: Voice) -> [Double] {
        if let name = v.name, let remembered = VoiceShape.remembered(name) { return remembered }
        if let print = session.introPrints[v.speaker] { return VoiceShape.from(print: print) }
        return VoiceShape.from(seed: "\(session.record?.id.uuidString ?? "")-\(v.speaker)")
    }

    private func orb(_ v: Voice, time: Double, level: Double) -> some View {
        let colour = Color(nsColor: NSColor(SpeakerMark.fill(v.lane)).blended(withFraction: 0.18, of: .white) ?? .white)
        // The ring sits exactly on its place; the name hangs just beneath it.
        return ZStack {
            Circle().fill(RadialGradient(colors: [colour.opacity(0.28 + 0.4 * level), .clear],
                                         center: .center, startRadius: 2, endRadius: 64))
            VoiceSigil(shape: shape(for: v), color: colour, level: level, lineWidth: 2.6, time: reduceMotion ? 0 : time)
                .frame(width: 118, height: 118)
            Circle().fill(.white).frame(width: 11, height: 11)
                .shadow(color: colour, radius: 10)
        }
        .frame(width: 150, height: 150)
        .overlay(alignment: .bottom) { label(v, colour: colour).fixedSize().offset(y: 12) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(v.name ?? String(localized: "Ny röst"))
    }

    @ViewBuilder private func label(_ v: Voice, colour: Color) -> some View {
        Group {
            if let name = v.name {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    if v.known { Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(colour) }
                }
                .shadow(color: .black.opacity(0.5), radius: 6)
            } else if recognising(v) {
                Text("Känner igen…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            } else {
                Text("Ny röst").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .contentTransition(.opacity)
    }

    /// Before the first voice: a quiet ring that listens.
    private func listening(time: Double, level: Double) -> some View {
        VoiceSigil(shape: VoiceShape.from(seed: "listening"), color: .white.opacity(0.55), level: 0.2 + level,
                   lineWidth: 1.4, time: reduceMotion ? 0 : time)
            .frame(width: 130, height: 130)
            .opacity(0.5 + 0.5 * level)
    }

    // MARK: Text and cards

    private func heading(_ voices: [Voice]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vem är här?").font(.system(size: 30, weight: .regular, design: .serif)).foregroundStyle(.white)
            Group {
                if let v = unnamed, recognising(v) { Text("Lyssnar på rösten…") }
                else if unnamed != nil { Text("En ny röst – vem är det?") }
                else if voices.isEmpty { Text("Säg hej och ditt namn – en i taget.") }
                else { Text("Fler i rummet? Säg hej.") }
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.6))
            .contentTransition(.opacity)
        }
    }

    @ViewBuilder private var consent: some View {
        if session.record?.informed == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Berätta att mötet spelas in").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("”\(MeetingConsent.text)”")
                    .font(.system(size: 12.5, design: .serif)).italic().foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Button { withAnimation(.snappy) { session.informed() } } label: {
                    Label("Jag har berättat", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glass)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
        }
    }

    @ViewBuilder private func card(_ voices: [Voice]) -> some View {
        if let voice = unnamed {
            let cast = session.record?.cast ?? Cast(words: [], names: [:])
            VStack(alignment: .leading, spacing: 10) {
                if recognising(voice) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Känner igen rösten…").font(.system(size: 13.5, weight: .medium))
                    }
                } else {
                    Text("Ny röst – vem är det?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    // Not "Namn": macOS would offer your contacts in a box over the card.
                    TextField("Vem är det?", text: Binding(get: { drafts[voice.speaker] ?? Self.spokenName(in: voice.said) ?? "" },
                                                           set: { drafts[voice.speaker] = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold))
                        .textContentType(nil)
                        .autocorrectionDisabled(true)
                        .focused($nameFocused)
                        .onSubmit { save(voice) }
                        .onAppear { nameFocused = true }
                    if !voice.said.isEmpty {
                        Text("”\(String(voice.said.prefix(80)))\(voice.said.count > 80 ? "…" : "")”")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Button("Spara") { save(voice) }.buttonStyle(.glassProminent).fixedSize()
                        let others = voices.filter { $0.speaker != voice.speaker }
                        if !others.isEmpty {
                            Menu("Samma som…") {
                                ForEach(others) { o in
                                    Button(o.name ?? cast.name(of: o.speaker)) {
                                        withAnimation(.snappy) { session.merge(voice.speaker, into: o.speaker) }
                                    }
                                }
                            }
                            .menuStyle(.button).buttonStyle(.glass).fixedSize()
                        }
                        Spacer(minLength: 0)
                        Button("Senare") { later.insert(voice.speaker) }.buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .id(voice.speaker)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        }
    }

    @ViewBuilder private var greetingToast: some View {
        if let greeting {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                Text("Välkommen tillbaka, \(greeting)").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .glassEffect(.regular, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func continueButton(_ voices: [Voice]) -> some View {
        Button { withAnimation(.spring(duration: 0.5, bounce: 0.15)) { session.endIntroduction() } } label: {
            Text(voices.isEmpty ? "Hoppa över" : "Alla är här – fortsätt")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: Actions

    private func save(_ voice: Voice) {
        let name = (drafts[voice.speaker] ?? Self.spokenName(in: voice.said) ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { session.name(speaker: voice.speaker, as: name) }
        drafts[voice.speaker] = nil
    }

    /// A known voice found: greeted, once.
    private func welcome(_ recognized: [String: Float]) {
        guard let record = session.record else { return }
        for key in recognized.keys {
            guard let s = Int(key), !greeted.contains(s), let name = record.names[key], !name.isEmpty else { continue }
            greeted.insert(s)
            chime("Glass")
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { greeting = name }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if greeting == name { withAnimation(.easeOut(duration: 0.4)) { greeting = nil } }
            }
        }
    }

    /// A soft sound — never into a Bluetooth headset (its mic can go when a sound there ends).
    private func chime(_ name: String) {
        guard Settings.sounds, !session.usesBluetooth, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = 0.12
        sound.play()
    }

    // MARK: "Jag heter Anna"

    /// The name someone gave: "jag heter Anna", "det är Erik", "I'm Sara" — capitalised,
    /// and not an ordinary word that happens to start a sentence.
    static func spokenName(in text: String) -> String? {
        // The lead-in in any case ("Jag heter", "jag heter"), the name with its capital.
        let pattern = #"(?i:jag heter|jag är|mitt namn är|det är|här är|i'm|i am|my name is|this is)[ ,]+(\p{Lu}[\p{L}\-]+(?: \p{Lu}[\p{L}\-]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let name = (text as NSString).substring(with: m.range(at: 1))
        guard name.first?.isUppercase == true,
              !["Jag", "Det", "Du", "Vi", "Ni", "Bra", "Okej", "Nu", "Här", "The", "It"].contains(name) else { return nil }
        return name
    }
}
