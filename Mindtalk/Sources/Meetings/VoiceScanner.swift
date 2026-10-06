import SwiftUI

// MARK: - Vem är här? (the introduction round)
//
// "Starta med presentation" begins the meeting with a scanner: a radar that sweeps
// the room while everyone says hello and their name, one at a time. Each new voice
// appears as a blip in its colour; a card asks who it is — the name already filled
// in when they said "jag heter Anna". A voice you've named before is greeted
// instead: "Välkommen tillbaka, Anna" (VoiceMemory, when switched on). "Alla är här"
// and the meeting goes on — recording since the first word, everyone named.

struct VoiceScanner: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var memory = VoiceMemory.shared
    @State private var drafts: [Int: String] = [:]
    @State private var later: Set<Int> = []
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
        let now = session.elapsed
        return now - last.end < 1.4 ? s : nil
    }

    /// The newest voice without a name, waiting for one.
    private var unnamed: Voice? { voices.last { $0.name == nil && !later.contains($0.speaker) } }

    var body: some View {
        let voices = self.voices
        HStack(alignment: .center, spacing: 28) {
            radar(voices)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 520)
            VStack(alignment: .leading, spacing: 16) {
                status(voices)
                if let voice = unnamed { newVoiceCard(voice, voices: voices).id(voice.speaker) }
                inRoom(voices)
                ConsentCard(session: session, compact: true)
                Button { withAnimation(.spring(duration: 0.4, bounce: 0.15)) { session.endIntroduction() } } label: {
                    Text(voices.isEmpty ? "Hoppa över" : "Alla är här – fortsätt")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.ink)
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: 290)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: voices)
    }

    // MARK: The radar

    private func radar(_ voices: [Voice]) -> some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = Double(LiveMeter.shared.levels.last ?? 0)
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let green = Color(red: 0.36, green: 0.79, blue: 0.65)
                // The rings breathe with the room.
                for k in 1...4 {
                    let rr = r * CGFloat(k) / 4.4
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(green.opacity(0.12 + 0.25 * level * Double(5 - k) / 4)), lineWidth: 1)
                }
                var cross = Path()
                cross.move(to: CGPoint(x: c.x, y: c.y - r * 0.92)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.92))
                cross.move(to: CGPoint(x: c.x - r * 0.92, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r * 0.92, y: c.y))
                ctx.stroke(cross, with: .color(green.opacity(0.1)), lineWidth: 1)
                // The sweep.
                if !reduceMotion {
                    let angle = Angle.degrees((t * 110).truncatingRemainder(dividingBy: 360) - 90)
                    var wedge = Path()
                    wedge.move(to: c)
                    wedge.addArc(center: c, radius: r * 0.92, startAngle: angle - .degrees(38), endAngle: angle, clockwise: false)
                    wedge.closeSubpath()
                    ctx.fill(wedge, with: .linearGradient(Gradient(colors: [green.opacity(0), green.opacity(0.28)]),
                                                          startPoint: point(c, r * 0.6, angle - .degrees(38)),
                                                          endPoint: point(c, r * 0.6, angle)))
                    var beam = Path(); beam.move(to: c); beam.addLine(to: point(c, r * 0.92, angle))
                    ctx.stroke(beam, with: .color(green.opacity(0.9)), lineWidth: 1.5)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(green))
                // The voices.
                for (n, v) in voices.enumerated() {
                    let a = Angle.radians(Double(n) * 2.39996 - 1.2)
                    let p = point(c, r * (0.42 + 0.12 * CGFloat(n % 3)), a)
                    let colour = SpeakerMark.fill(v.lane)
                    if activeSpeaker == v.speaker && !reduceMotion {
                        for k in 0..<2 {
                            let phase = (t * 0.9 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                            let pr = 8 + 26 * phase
                            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)),
                                       with: .color(colour.opacity(0.7 * (1 - phase))), lineWidth: 2)
                        }
                    }
                    let br: CGFloat = activeSpeaker == v.speaker ? 11 : 8
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - br, y: p.y - br, width: br * 2, height: br * 2)), with: .color(colour))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - br, y: p.y - br, width: br * 2, height: br * 2)),
                               with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                    let label = Text(v.name ?? String(localized: "Ny röst"))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(v.name == nil ? 0.6 : 0.95))
                    ctx.draw(label, at: CGPoint(x: p.x, y: p.y + br + 12), anchor: .top)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color(red: 0.36, green: 0.79, blue: 0.65).opacity(0.22), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voices.isEmpty ? "Lyssnar efter röster" : "\(voices.count) röster hittade")
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Angle) -> CGPoint {
        CGPoint(x: c.x + r * cos(a.radians), y: c.y + r * sin(a.radians))
    }

    // MARK: Beside it

    @ViewBuilder private func status(_ voices: [Voice]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vem är här?").font(.system(size: 26, weight: .regular, design: .serif))
            Group {
                if let greeted = voices.last(where: { $0.known }), activeSpeaker == greeted.speaker {
                    Text("Välkommen tillbaka, \(greeted.name ?? "")")
                } else if unnamed != nil {
                    Text("En ny röst – vem är det?")
                } else if voices.isEmpty {
                    Text("Säg hej och ditt namn – en i taget.")
                } else {
                    Text("Fler i rummet? Säg hej.")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(DS.Colors.muted)
            .contentTransition(.opacity)
        }
    }

    private func newVoiceCard(_ voice: Voice, voices: [Voice]) -> some View {
        let cast = session.record?.cast ?? Cast(words: [], names: [:])
        return VStack(alignment: .leading, spacing: 10) {
            Text("Ny röst hittad").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            HStack(spacing: 10) {
                SpeakerMark(speaker: voice.speaker, cast: cast, size: 26)
                // Not "Namn": macOS would offer your contacts in a box over the card.
                TextField("Vem är det?", text: Binding(get: { drafts[voice.speaker] ?? Self.spokenName(in: voice.said) ?? "" },
                                                       set: { drafts[voice.speaker] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(nil)
                    .autocorrectionDisabled(true)
                    .focused($nameFocused)
                    .onSubmit { save(voice) }
            }
            if !voice.said.isEmpty {
                Text("Hörde: ”\(String(voice.said.prefix(90)))\(voice.said.count > 90 ? "…" : "")”")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Spara") { save(voice) }.buttonStyle(.ink).fixedSize()
                let others = voices.filter { $0.speaker != voice.speaker }
                if !others.isEmpty {
                    Menu("Samma som…") {
                        ForEach(others) { o in
                            Button(o.name ?? cast.name(of: o.speaker)) {
                                withAnimation(.snappy) { session.merge(voice.speaker, into: o.speaker) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Två röster som är samma person slås ihop")
                }
                Spacer()
                Button("Senare") { later.insert(voice.speaker) }.buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.card))
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        .onAppear { nameFocused = true }
    }

    private func save(_ voice: Voice) {
        let name = (drafts[voice.speaker] ?? Self.spokenName(in: voice.said) ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { session.name(speaker: voice.speaker, as: name) }
        drafts[voice.speaker] = nil
    }

    @ViewBuilder private func inRoom(_ voices: [Voice]) -> some View {
        let named = voices.filter { $0.name != nil }
        if !named.isEmpty {
            let cast = session.record?.cast ?? Cast(words: [], names: [:])
            VStack(alignment: .leading, spacing: 10) {
                Text("Här i rummet").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                ForEach(named) { v in
                    HStack(spacing: 10) {
                        SpeakerMark(speaker: v.speaker, cast: cast, size: 22)
                        Text(v.name ?? "").font(.system(size: 13.5, weight: .medium))
                        if v.known {
                            Label("Känd röst", systemImage: "person.wave.2").font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
                        }
                        Spacer()
                        if activeSpeaker == v.speaker {
                            Waveform(levels: Array(LiveMeter.shared.levels.suffix(10)), gap: 2, color: SpeakerMark.fill(v.lane))
                                .frame(width: 44, height: 16)
                                .transition(.opacity)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.card))
        }
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
