import AppKit
import SwiftUI

// MARK: - What the room needs to know while a meeting runs
//
// Small, calm things under the meeting's header, each on its own and each only once:
// ten minutes without a word ("Är mötet slut?"), a voice that came in after the room
// was known ("Ny röst. Vem är det?"), more voices than can be told apart well, and,
// the first time names are given, which of them is you.

struct LiveNotices: View {
    @ObservedObject var session: MeetingSession
    let record: MeetingRecord
    let cast: Cast
    let edit: MeetingEdits
    /// In the small panel: the silence question in its compact form.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.silenceAsked { SilenceQuestion(session: session, compact: compact) }
            if session.askingWhoYouAre { WhoAreYou(session: session, record: record) }
            if let speaker = session.latecomer, cast.order.contains(speaker) {
                HStack(spacing: 6) {
                    SpeakerChip(speaker: speaker, cast: cast, style: .newVoice,
                                rename: { edit.name(speaker, $0) },
                                merge: { other in withAnimation(.snappy) { edit.merge(speaker, into: other) } })
                    Button { withAnimation(.snappy) { session.dismissLatecomer() } } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Colors.faint)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Inte nu")
                    .accessibilityLabel("Inte nu")
                }
                .transition(.opacity)
            }
            if session.manyVoices {
                HStack(spacing: 8) {
                    Image(systemName: "person.3").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                        .accessibilityHidden(true)
                    Text("Ni är många. Med åtta röster eller fler kan namnen bli mindre säkra.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { withAnimation(.snappy) { session.dismissManyVoices() } } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Colors.faint)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dölj")
                    .accessibilityLabel("Dölj")
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: session.silenceAsked)
        .animation(.easeOut(duration: 0.25), value: session.latecomer)
        .animation(.easeOut(duration: 0.25), value: session.manyVoices)
        .animation(.easeOut(duration: 0.25), value: session.askingWhoYouAre)
    }
}

/// Ten minutes without a word: is it over? Calm, with the two answers. (In the panel too.)
struct SilenceQuestion: View {
    @ObservedObject var session: MeetingSession
    var compact = false

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            Text("Ingen har sagt något på tio minuter. Är mötet slut?")
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !compact { Spacer(minLength: 12) }
            HStack(spacing: 8) {
                Button(String(localized: "meeting|Avsluta")) { _ = session.requestStop() }
                    .buttonStyle(.ink)
                Button(String(localized: "pause|Fortsätt")) { withAnimation(.snappy) { session.keepGoing() } }
                    .buttonStyle(.soft)
            }
        }
        .padding(compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }
}

/// "Vem av er är du?" — once, the first time people are named: your tasks then read "Du".
private struct WhoAreYou: View {
    @ObservedObject var session: MeetingSession
    let record: MeetingRecord

    var body: some View {
        let names = VoiceMemory.namesToRemember(in: record)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Vem av er är du?").font(.system(size: 14, weight: .semibold))
                Text("Då visas dina uppgifter som Du i sammanfattningen.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            }
            FlowLayout(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button(name) { withAnimation(.snappy) { session.iAm(name) } }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
                Button("Ingen av dem") { withAnimation(.snappy) { session.iAm(nil) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .padding(.leading, 4)
                    .frame(height: 28)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .transition(.opacity)
    }
}

// MARK: - ⌘F: Sök i mötet

/// Where the words searched for are in a meeting's text: every place, turn by turn.
enum MeetingFind {
    struct Hit: Equatable {
        /// The turn's id (its first word).
        let turn: Int
        /// Which place in that turn.
        let index: Int
    }

    /// Case doesn't matter; å, ä and ö stay letters of their own.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    static func hits(_ query: String, in turns: [MeetingTurn]) -> [Hit] {
        turns.flatMap { turn in ranges(of: query, in: turn.text).indices.map { Hit(turn: turn.id, index: $0) } }
    }
}

extension MeetingTurn {
    /// What was said, as `spoken`, with the places searched for lit: each one softly,
    /// the one you're at in ink.
    @MainActor func spoken(cast: Cast, finding query: String, current: Int?) -> AttributedString {
        let chars = Array(text)
        let hits = MeetingFind.ranges(of: query, in: text).map {
            (text.distance(from: text.startIndex, to: $0.lowerBound), text.distance(from: text.startIndex, to: $0.upperBound))
        }
        var out = AttributedString()
        func add(_ from: Int, _ to: Int) {
            var i = from
            while i < to {
                if let k = hits.firstIndex(where: { $0.0 <= i && i < $0.1 }) {
                    let end = min(to, hits[k].1)
                    var lit = AttributedString(String(chars[i..<end]))
                    if k == current {
                        lit.backgroundColor = DS.Colors.ink
                        lit.foregroundColor = DS.Colors.onInk
                    } else {
                        lit.backgroundColor = DS.Colors.ink.opacity(0.13)
                    }
                    out += lit
                    i = end
                } else {
                    let end = min(to, hits.map(\.0).filter { $0 > i }.min() ?? to)
                    out += AttributedString(String(chars[i..<end]))
                    i = end
                }
            }
        }
        var from = 0
        for aside in asides {
            let cut = min(aside.at, chars.count)
            if cut > from { add(from, cut) }
            var tag = AttributedString(" (\(cast.name(of: aside.speaker)): \(aside.text))")
            tag.font = .system(size: 12.5)
            tag.foregroundColor = DS.Colors.muted
            out += tag
            from = max(from, cut)
        }
        add(from, chars.count)
        return out
    }
}

/// The field: "Sök i mötet", how many and which, back and forth, and away with Esc.
struct MeetingFindBar: View {
    @Binding var query: String
    let count: Int
    let current: Int
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                .accessibilityHidden(true)
            TextField("Sök i mötet", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onSubmit { step(1) }
                .onExitCommand(perform: close)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .accessibilityLabel("Sök i mötet")
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(count == 0 ? String(localized: "Inga träffar") : String(localized: "\(current + 1) av \(count)"))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                    .fixedSize()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 10.5, weight: .bold)) }
                .buttonStyle(.plain).disabled(count == 0)
                .keyboardShortcut(.return, modifiers: .shift)
                .help("Föregående (⇧↩)").accessibilityLabel("Föregående")
            Button { step(1) } label: { Image(systemName: "chevron.down").font(.system(size: 10.5, weight: .bold)) }
                .buttonStyle(.plain).disabled(count == 0)
                .keyboardShortcut("g", modifiers: .command)
                .help("Nästa (↩)").accessibilityLabel("Nästa")
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(DS.Colors.faint)
            }
            .buttonStyle(.plain)
            .help("Stäng (Esc)")
            .accessibilityLabel("Stäng sökningen")
        }
        .foregroundStyle(DS.Colors.ink)
        .padding(.horizontal, 12)
        .frame(width: 360, height: 34)
        .background(Capsule().fill(DS.Colors.field))
        .overlay(Capsule().strokeBorder(focused ? DS.Colors.ink.opacity(0.5) : DS.Colors.fieldStroke, lineWidth: 1))
        .background {
            Button("") { step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onAppear { focused = true }
    }
}
