import QuartzCore
import SwiftUI

/// The live text as it's said, word by word: what the transcription hands over in a
/// handful at a time (twice a second) comes out one word after another, at the pace of
/// speech, each fading in from a soft blur — and a grey word still being written turns
/// to ink by degrees when it settles. Only how the text appears: the words, the turns,
/// the speakers and everything done with them are the meeting's own, untouched.
///
/// One for the meeting going on, shared by the window and the panel, so either shows
/// the same words already in place.
@MainActor
final class LiveReveal: ObservableObject {
    static let shared = LiveReveal()

    /// A word as shown: when it came into view (nil: not yet), and when it stopped
    /// being written (it then turns from grey to ink).
    struct Word: Equatable {
        enum Kind: Equatable { case settled, pending, aside }
        var text: String
        var kind: Kind
        var born: Double?
        var settled: Double?
    }

    /// Seconds a word takes to fade in, and to go from grey to ink.
    static let fadeIn = 0.32
    static let settle = 0.5

    private(set) var words: [Int: [Word]] = [:]
    private var order: [Int] = []
    private var meeting: UUID?
    /// Words owed: fractions of one, carried between frames.
    private var credit = 0.0
    private var lastTick = 0.0
    private var link: Timer?
    /// Something is moving: the text draws every frame until it isn't.
    @Published private(set) var animating = false

    static var now: Double { Date().timeIntervalSinceReferenceDate }

    /// The turns as they are now. A meeting newly opened (or the window built anew)
    /// shows what was said at once; only what comes after arrives word by word.
    func update(_ turns: [MeetingTurn], meeting id: UUID?) {
        let now = Self.now
        let fresh = id != meeting
        if fresh { meeting = id; words = [:]; credit = 0 }
        let last = turns.last?.id
        var next: [Int: [Word]] = [:]
        for turn in turns {
            let new = Self.tokens(turn)
            guard let old = words[turn.id] else {
                // A turn not seen before: the newest arrives; one that appears above it
                // (a turn split by a voice) was on screen already.
                let shown = fresh || turn.id != last
                next[turn.id] = new.map { var w = $0; w.born = shown || w.kind == .aside ? -.infinity : nil; return w }
                continue
            }
            var merged: [Word] = []
            for (i, var w) in new.enumerated() {
                if i < old.count {
                    let before = old[i]
                    if before.text == w.text {
                        w.born = before.born
                        w.settled = before.kind == .pending && w.kind == .settled && before.born != nil ? now : before.settled
                    } else if before.born != nil {
                        // A word on screen written anew: a short fade, not a pop.
                        w.born = now - Self.fadeIn * 0.5
                    }
                }
                if w.kind == .aside { w.born = w.born ?? -.infinity }
                merged.append(w)
            }
            next[turn.id] = merged
        }
        words = next
        order = turns.map(\.id)
        objectWillChange.send()
        run()
    }

    /// The meeting is over: nothing left to arrive.
    func reset() {
        link?.invalidate(); link = nil
        words = [:]; order = []; meeting = nil; credit = 0
        animating = false
    }

    private var owed: Int {
        order.reduce(0) { n, id in n + (words[id]?.filter { $0.born == nil }.count ?? 0) }
    }

    private func run() {
        guard link == nil, owed > 0 || moving(at: Self.now) else { return }
        lastTick = CACurrentMediaTime()
        animating = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        link = timer
    }

    private func tick() {
        let t = CACurrentMediaTime()
        let dt = min(0.1, t - lastTick)
        lastTick = t
        let now = Self.now
        let backlog = owed
        if backlog > 0 {
            // The pace of speech, quicker when a lot is waiting: never more than about
            // half a second behind what was handed over.
            let rate = max(9, Double(backlog) / 0.45)
            credit += rate * dt
            var revealed = false
            while credit >= 1, let (id, i) = nextHidden() {
                words[id]?[i].born = now
                credit -= 1
                revealed = true
            }
            if revealed { objectWillChange.send() }
        } else {
            credit = 0
        }
        if backlog == 0, !moving(at: now) {
            link?.invalidate(); link = nil
            animating = false
        }
    }

    private func nextHidden() -> (Int, Int)? {
        for id in order {
            if let i = words[id]?.firstIndex(where: { $0.born == nil }) { return (id, i) }
        }
        return nil
    }

    private func moving(at now: Double) -> Bool {
        words.values.contains { list in
            list.contains { w in
                (w.born.map { now - $0 < Self.fadeIn } ?? false) || (w.settled.map { now - $0 < Self.settle } ?? false)
            }
        }
    }

    /// The words of a turn in order: its settled text (with someone else's "Mm" where
    /// it was said), then what is still being written.
    static func tokens(_ turn: MeetingTurn) -> [Word] {
        var out: [Word] = []
        let text = turn.text
        var from = text.startIndex
        func settled(_ s: Substring) {
            for w in s.split(whereSeparator: \.isWhitespace) { out.append(Word(text: String(w), kind: .settled)) }
        }
        for aside in turn.asides {
            let cut = text.index(text.startIndex, offsetBy: min(aside.at, text.count))
            if cut > from { settled(text[from..<cut]) }
            out.append(Word(text: "\(aside.speaker)\u{1F}\(aside.text)", kind: .aside))
            from = max(from, cut)
        }
        settled(text[from...])
        for w in turn.pending.split(whereSeparator: \.isWhitespace) { out.append(Word(text: String(w), kind: .pending)) }
        return out
    }

    /// The turn as shown now, or nil when this isn't the meeting being revealed (then
    /// it's drawn as it always was).
    func text(_ turn: MeetingTurn, cast: Cast, asideFont: Font, cursor: Text? = nil) -> Text? {
        guard let list = words[turn.id] else { return nil }
        var out = Text("")
        var first = true
        for w in list {
            guard let born = w.born else { break }          // in order: the rest is still to come
            switch w.kind {
            case .aside:
                let parts = w.text.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                let name = parts.first.flatMap(Int.init).map { cast.name(of: $0) } ?? ""
                let tag = Text(" (\(name): \(parts.count > 1 ? parts[1] : ""))").font(asideFont).foregroundStyle(DS.Colors.muted)
                out = Text("\(out)\(tag)")
            case .settled, .pending:
                let word = Text((first ? "" : " ") + w.text)
                    .customAttribute(LiveWord(born: born, settled: w.settled, pending: w.kind == .pending))
                out = Text("\(out)\(word)")
            }
            first = false
        }
        if let cursor { out = Text("\(out)\(cursor)") }
        return out
    }

    /// How many words of the turn are in view: what the text's growth animates on.
    func shown(_ id: Int) -> Int { words[id]?.filter { $0.born != nil }.count ?? 0 }
}

/// A word in the live text: when it appeared, and when it settled.
struct LiveWord: TextAttribute {
    let born: Double
    let settled: Double?
    let pending: Bool
}

/// Draws the live text: each word fading in, rising a little out of a soft blur; a
/// word still being written in grey, going to ink when it settles.
struct LiveTextRenderer: TextRenderer {
    let now: Double
    /// How grey a word still being written is (the muted colour, as an ink's strength).
    static let pendingStrength = 0.48

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let word = run[LiveWord.self] else { context.draw(run); continue }
                let p = min(1, max(0, (now - word.born) / LiveReveal.fadeIn))
                let appear = 1 - pow(1 - p, 3)
                let strength: Double = if word.pending { Self.pendingStrength }
                    else if let s = word.settled { Self.pendingStrength + (1 - Self.pendingStrength) * min(1, max(0, (now - s) / LiveReveal.settle)) }
                    else { 1 }
                var c = context
                c.opacity = appear * strength
                if appear < 1 {
                    c.translateBy(x: 0, y: (1 - appear) * 3)
                    c.addFilter(.blur(radius: (1 - appear) * 2.5))
                }
                c.draw(run)
            }
        }
    }
}
