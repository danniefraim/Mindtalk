import AppKit
import SwiftUI

// MARK: - Vem är här? (the introduction round)
//
// "Med presentation" begins the meeting with the room's voices, one at a time: a
// slowly turning sphere of light listens; when someone speaks, Mindtalk compares
// their voice with the ones it knows, and the cloud falls into that voice's own
// figure, in its colour (VoiceFigure.swift), as the name rises out of the blur. A
// voice you've named before is known at once; a new one gets a glass card asking
// who it is — the name already filled in when they said "jag heter Erik". Those
// found gather in the corner, "I rummet". "Alla är här" and the meeting goes on,
// recorded from the first word, everyone named.

struct VoiceScanner: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var memory = VoiceMemory.shared
    @State private var drafts: [Int: String] = [:]
    @State private var later: Set<Int> = []
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
        v.name == nil && memory.enabled && !memory.people.isEmpty && !session.introChecked.contains(v.speaker) && v.speech < 8
    }

    /// The newest voice without a name, waiting for one.
    private var unnamed: Voice? { voices.last { $0.name == nil && !later.contains($0.speaker) } }

    /// The voice in the middle: whoever spoke last.
    private func focus(_ voices: [Voice]) -> Voice? {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--demo-focus"), i + 1 < CommandLine.arguments.count,
           let s = Int(CommandLine.arguments[i + 1]), let v = voices.first(where: { $0.speaker == s }) { return v }
        #endif
        guard let record = session.record else { return nil }
        for w in (record.words + session.pending).suffix(400).reversed() {
            if let s = w.speaker, let v = voices.first(where: { $0.speaker == s }) { return v }
        }
        return voices.last
    }

    var body: some View {
        let voices = self.voices
        let focus = self.focus(voices)
        GeometryReader { geo in
            ZStack {
                Color(red: 0.008, green: 0.008, blue: 0.012)
                Constellation(figure: focus.flatMap(figure(for:)), color: colour(focus), level: roomLevel,
                              searching: focus.map(recognising) ?? false)
            }
            .overlay(alignment: .topLeading) {
                Text("Vem är här?").font(.system(size: 32, weight: .regular, design: .serif))
                    .foregroundStyle(.white.opacity(0.9)).padding(.leading, 40).padding(.top, 34)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 14) {
                    continueButton(voices)
                    consent
                }
                .padding(24)
            }
            .overlay(alignment: .bottom) { identity(focus, width: geo.size.width).padding(.bottom, 40) }
            .overlay(alignment: .bottomLeading) { room(voices).padding(.leading, 40).padding(.bottom, 38) }
            .overlay(alignment: .bottomTrailing) { card(voices).padding(24) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 88)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.55, bounce: 0.2), value: voices)
        .onChange(of: voices.count) { old, new in if new > old { chime("Pop") } }
        .onChange(of: session.record?.recognized ?? [:]) { _, recognized in welcome(recognized) }
    }

    /// The room's level, a little smoothed — the light shouldn't flicker.
    private var roomLevel: Double {
        let levels = LiveMeter.shared.levels.suffix(5)
        return levels.isEmpty ? 0 : min(1, Double(levels.reduce(0, +)) / Double(levels.count) * 1.6)
    }

    // MARK: The voice in the middle

    /// The figure to fall into — none while Mindtalk is still comparing the voice.
    private func figure(for v: Voice) -> VoiceFigure? {
        if recognising(v) { return nil }
        if let name = v.name, let remembered = VoiceFigure.remembered(name) { return remembered }
        return session.introFigure(of: v.speaker)
    }

    private func colour(_ v: Voice?) -> Color {
        v.map { SpeakerMark.fill($0.lane) } ?? Color(red: 0.36, green: 0.79, blue: 0.65)
    }

    /// Below the cloud: what Mindtalk is doing, and the name once it knows it.
    private func identity(_ v: Voice?, width: CGFloat) -> some View {
        let status: LocalizedStringKey
        let name: String?
        switch v {
        case nil: status = "Lyssnar…"; name = nil
        case let v? where v.name == nil && recognising(v): status = "Jämför röstavtryck…"; name = nil
        case let v? where v.name == nil: status = "Vem är det?"; name = String(localized: "Ny röst")
        case let v? where v.known: status = "Känd röst"; name = v.name
        case let v?: status = "Ny röst"; name = v.name
        }
        let accent = Constellation.rgb(colour(v))
        return VStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(Color(red: accent.x, green: accent.y, blue: accent.z)).frame(width: 6, height: 6)
                    .shadow(color: Color(red: accent.x, green: accent.y, blue: accent.z), radius: 6)
                Text(status).textCase(.uppercase).tracking(2.4)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.opacity)
            }
            Text(name ?? " ")
                .font(.system(size: min(96, max(56, width * 0.08)), weight: .regular, design: .serif)).italic()
                .foregroundStyle(.white.opacity(v?.name == nil ? 0.45 : 1))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: max(200, width - 2 * 340))
                .opacity(name == nil ? 0 : 1)
                .blur(radius: name == nil ? 14 : 0)
                .animation(.easeOut(duration: 0.6), value: name)
                .id(v?.speaker)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.4), value: v?.speaker)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// The ones found so far.
    @ViewBuilder private func room(_ voices: [Voice]) -> some View {
        let named = voices.filter { $0.name != nil }
        if !named.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("I rummet").textCase(.uppercase).tracking(2.2)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                ForEach(named) { v in
                    let c = Constellation.rgb(SpeakerMark.fill(v.lane))
                    let tint = Color(red: c.x, green: c.y, blue: c.z)
                    HStack(spacing: 10) {
                        Circle().fill(tint).frame(width: 6, height: 6).shadow(color: tint, radius: 5)
                        Text(v.name ?? "").font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }

    // MARK: Text and cards

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
        if let voice = unnamed, !recognising(voice) {
            let cast = session.record?.cast ?? Cast(words: [], names: [:])
            VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        VoiceFigureMark(figure: figure(for: voice) ?? session.introFigure(of: voice.speaker),
                                        color: SpeakerMark.fill(voice.lane), lineWidth: 1)
                            .frame(width: 16, height: 16)
                        Text("Ny röst – vem är det?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
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
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .id(voice.speaker)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
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

    /// A known voice found: a soft sound, once — the name rises in the middle.
    private func welcome(_ recognized: [String: Float]) {
        for key in recognized.keys {
            guard let s = Int(key), !greeted.contains(s) else { continue }
            greeted.insert(s)
            chime("Glass")
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
