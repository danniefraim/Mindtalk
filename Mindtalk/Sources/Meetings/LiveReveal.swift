import QuartzCore
import SwiftUI

/// The live text as it's said, word by word: what the transcription hands over a
/// handful at a time (twice a second) comes out in the rhythm it was spoken — quick
/// talk quickly, a pause as a pause — about a second behind the voice, each word
/// fading in from a soft blur. A grey word still being written turns to ink by degrees
/// when it settles, and one written anew changes only in the letters that changed.
/// Only how the text appears: the words, the turns, the speakers and everything done
/// with them are the meeting's own, untouched.
///
/// One for the meeting going on, shared by the window and the panel, so either shows
/// the same words already in place.
@MainActor
final class LiveReveal: ObservableObject {
    static let shared = LiveReveal()

    /// A word as shown: when it was said (meeting seconds), when it came into view
    /// (nil: not yet), when it stopped being written (it then turns from grey to ink),
    /// and when it was last written anew, from which letter on.
    struct Word: Equatable {
        enum Kind: Equatable { case settled, pending, aside }
        var text: String
        var kind: Kind
        var at: Double?
        var born: Double?
        var settled: Double?
        var changed: Double?
        var stem = 0
    }

    /// Seconds a word takes to fade in, to go from grey to ink, and to change letters.
    static let fadeIn = 0.32
    static let settle = 0.5
    static let change = 0.28
    /// How far behind the voice the text runs, in seconds: enough to bring the words
    /// out in their own rhythm, rather than as they're handed over.
    static let lag = 0.9

    private(set) var words: [Int: [Word]] = [:]
    private var order: [Int] = []
    private var meeting: UUID?
    /// Where the text has got to, in meeting seconds: words said before it are shown.
    private var playhead = -Double.infinity
    /// When new words last came: silence after, and the last of them come out too.
    private var lastNews = 0.0
    /// The latest moment (meeting seconds) whose words are on screen: words said
    /// before it that turn up in another turn (a sentence that was someone else's)
    /// were already read, and move rather than being written out again.
    private var shownUntil = -Double.infinity
    private var lastTick = 0.0
    private var link: Timer?
    /// Something is moving: the text draws every frame until it isn't.
    @Published private(set) var animating = false

    #if DEBUG
    /// `--reveal-log`: how the reveal keeps up, every two seconds and at the end.
    private struct Stats { var updates = 0, revealed = 0, moved = 0, rewritten = 0, maxLag = 0.0, maxWaiting = 0, lastPrint = 0.0 }
    private var stats = Stats()
    private static let logging = CommandLine.arguments.contains("--reveal-log")
    private static let off = CommandLine.arguments.contains("--no-reveal")
    private func report(_ now: Double, final: Bool = false) {
        guard Self.logging, final || now - stats.lastPrint >= 2 else { return }
        stats.lastPrint = now
        let all = order.flatMap { words[$0] ?? [] }
        let hiddenCount = all.filter { $0.born == nil }.count
        let latest = all.compactMap(\.at).max() ?? 0
        print(String(format: "[reveal] uppd %d · visade %d · flyttade %d · omskrivna %d · väntar %d (högst %d) · efter %.2f s (högst %.2f) · ord %d",
                     stats.updates, stats.revealed, stats.moved, stats.rewritten, hiddenCount, stats.maxWaiting,
                     latest - max(playhead, latest - 99), stats.maxLag, all.count))
        fflush(stdout)
    }
    #endif

    static var now: Double { Date().timeIntervalSinceReferenceDate }

    /// The turns as they are now, and when each word of the meeting was said (its
    /// settled words, then those still being written: what the turns' ids count in).
    /// A meeting newly opened (or the window built anew) shows what was said at once;
    /// only what comes after arrives word by word.
    func update(_ turns: [MeetingTurn], meeting id: UUID?, times: [Double]) {
        #if DEBUG
        if Self.off { return }                      // `--no-reveal`: as before, to compare
        #endif
        let now = Self.now
        let fresh = id != meeting
        if fresh { meeting = id; words = [:]; playhead = -.infinity; shownUntil = -.infinity }
        let last = turns.last?.id
        var next: [Int: [Word]] = [:]
        var news = false
        for (k, turn) in turns.enumerated() {
            let end = k + 1 < turns.count ? turns[k + 1].id : times.count
            var new = Self.tokens(turn)
            Self.time(&new, span: times.indices.contains(turn.id) ? Array(times[turn.id..<max(turn.id, min(end, times.count))]) : [])
            guard let old = words[turn.id] else {
                // A turn not seen before: the newest arrives; one that appears above it
                // (a turn split by a voice) was on screen already.
                let shown = fresh || turn.id != last
                next[turn.id] = new.map { var w = $0
                    if shown || w.kind == .aside || Self.seen(w, until: shownUntil) { w.born = -.infinity }
                    return w
                }
                if !shown { news = true }
                continue
            }
            var merged: [Word] = []
            for (i, var w) in new.enumerated() {
                if i < old.count {
                    let before = old[i]
                    w.born = before.born
                    if before.text == w.text {
                        w.settled = before.kind == .pending && w.kind == .settled && before.born != nil ? now : before.settled
                        if w.settled == now { stillUntil = max(stillUntil, now + Self.settle) }
                        w.changed = before.changed
                        w.stem = before.stem
                    } else if before.born != nil {
                        // A word on screen written anew: only the letters from where it
                        // differs change ("intresserad" to "intresserade": the "e").
                        w.stem = Self.commonPrefix(before.text, w.text)
                        w.changed = now
                        stillUntil = max(stillUntil, now + Self.change)
                        #if DEBUG
                        stats.rewritten += 1
                        #endif
                    }
                } else if Self.seen(w, until: shownUntil) {
                    w.born = -.infinity                         // moved here from the turn above
                    #if DEBUG
                    stats.moved += 1
                    #endif
                } else {
                    news = true
                }
                if w.kind == .aside { w.born = w.born ?? -.infinity }
                merged.append(w)
            }
            next[turn.id] = merged
        }
        words = next
        order = turns.map(\.id)
        // What is on screen from the start (a meeting opened mid-way) counts as read.
        for list in next.values { for w in list where w.born != nil { if let at = w.at { shownUntil = max(shownUntil, at) } } }
        if news { lastNews = now }
        #if DEBUG
        stats.updates += 1
        #endif
        objectWillChange.send()
        run()
    }

    /// The meeting is over: nothing left to arrive.
    func reset() {
        link?.invalidate(); link = nil
        words = [:]; order = []; meeting = nil; playhead = -.infinity
        animating = false
    }

    /// When each word was said: the turn's words spread over the times of the words it
    /// was made from (the cleanup may have dropped an "eh", so not one to one).
    private static func time(_ words: inout [Word], span: [Double]) {
        let spoken = words.indices.filter { words[$0].kind != .aside }
        guard !span.isEmpty, !spoken.isEmpty else { return }
        for (j, i) in spoken.enumerated() {
            words[i].at = span[min(span.count - 1, j * span.count / spoken.count)]
        }
    }

    /// Said before what's on screen already ends: it was read, wherever it stood.
    private static func seen(_ w: Word, until: Double) -> Bool {
        guard let at = w.at else { return false }
        return at < until - 0.05
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) { if x == y { n += 1 } else { break } }
        // Too little the same to read as one word changing: the whole word anew.
        return n >= 3 ? n : 0
    }

    private var hidden: [(id: Int, i: Int, at: Double?)] {
        order.flatMap { id in (words[id] ?? []).enumerated().compactMap { i, w in w.born == nil ? (id, i, w.at) : nil } }
    }

    private func run() {
        guard link == nil, !hidden.isEmpty || moving(at: Self.now) else { return }
        lastTick = CACurrentMediaTime()
        animating = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
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
        let waiting = hidden
        if !waiting.isEmpty {
            let latest = waiting.compactMap(\.at).max() ?? playhead
            let first = waiting.first?.at ?? latest
            // Starting (or after a pause): from just before the first word waiting.
            if playhead < first - Self.lag * 2 { playhead = first - 0.05 }
            // About a second behind the newest word, in step with the voice; quicker when
            // a lot has piled up, and all the way when nothing new has come for a while.
            let target = now - lastNews > 1.2 ? 0 : Self.lag
            let behind = latest - playhead
            // Far behind (the first seconds of a meeting come all at once, or the
            // transcription caught up after a stall): there in about half a second, a
            // quick ripple, not a slow retelling of what was said long ago.
            let speed = behind > 2.5 ? behind / 0.5 : min(5, max(0.6, 1 + 1.6 * (behind - target)))
            playhead = min(latest, playhead + dt * speed)
            var revealed = false
            for w in waiting {
                guard (w.at ?? -.infinity) <= playhead else { break }      // in order: the rest is still to come
                words[w.id]?[w.i].born = now
                stillUntil = max(stillUntil, now + Self.fadeIn)
                if let at = w.at { shownUntil = max(shownUntil, at) }
                revealed = true
            }
            if revealed { objectWillChange.send() }
            #if DEBUG
            stats.revealed += waiting.count - hidden.count
            stats.maxWaiting = max(stats.maxWaiting, waiting.count)
            if now - lastNews < 1.2 { stats.maxLag = max(stats.maxLag, latest - playhead) }
            #endif
        }
        #if DEBUG
        report(now)
        #endif
        if waiting.isEmpty, !moving(at: now) {
            link?.invalidate(); link = nil
            animating = false
            objectWillChange.send()
        }
    }

    /// When the last fade, settle or change ends: until then the text moves. Kept as
    /// they're set, rather than looking through every word thirty times a second.
    private var stillUntil = 0.0
    private func moving(at now: Double) -> Bool { now < stillUntil }

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
                let space = first ? "" : " "
                let look = LiveWord(born: born, settled: w.settled, pending: w.kind == .pending, changed: nil)
                if let changed = w.changed, w.stem > 0 {
                    // The letters that stayed, still; the rest coming in.
                    let stem = String(w.text.prefix(w.stem)), rest = String(w.text.dropFirst(w.stem))
                    var again = look
                    again.changed = changed
                    out = Text("\(out)\(Text(space + stem).customAttribute(look))\(Text(rest).customAttribute(again))")
                } else if let changed = w.changed {
                    var again = look
                    again.changed = changed
                    out = Text("\(out)\(Text(space + w.text).customAttribute(again))")
                } else {
                    out = Text("\(out)\(Text(space + w.text).customAttribute(look))")
                }
            }
            first = false
        }
        if let cursor { out = Text("\(out)\(cursor)") }
        return out
    }

    /// How many words of the turn are in view: what the text's growth animates on.
    func shown(_ id: Int) -> Int { words[id]?.filter { $0.born != nil }.count ?? 0 }

    /// Something in this turn fading, settling, changing or still to come: only then is
    /// it drawn every frame (a long meeting's other turns stay still, and cost nothing).
    func busy(_ id: Int) -> Bool {
        guard animating, let list = words[id] else { return false }
        let now = Self.now
        return list.contains { w in
            w.born == nil || (w.born.map { now - $0 < Self.fadeIn } ?? false)
                || (w.settled.map { now - $0 < Self.settle } ?? false)
                || (w.changed.map { now - $0 < Self.change } ?? false)
        }
    }
}

/// The cursor after the newest words: it blinks on the half second.
struct LiveCursor: TextAttribute {}

/// A word in the live text: when it appeared, settled, or changed.
struct LiveWord: TextAttribute {
    let born: Double
    let settled: Double?
    let pending: Bool
    var changed: Double?
}

/// Draws the live text: each word fading in, rising a little out of a soft blur (with
/// Reduce Motion: only fading); a word still being written in grey, going to ink when
/// it settles; letters written anew fading in where the old ones were.
struct LiveTextRenderer: TextRenderer {
    let now: Double
    var reduceMotion = false
    /// How grey a word still being written is (the muted colour, as an ink's strength).
    static let pendingStrength = 0.48

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[LiveCursor.self] != nil {
                    var c = context
                    c.opacity = Int(now / 0.5) % 2 == 0 ? 0.9 : 0.15
                    c.draw(run)
                    continue
                }
                guard let word = run[LiveWord.self] else { context.draw(run); continue }
                let p = min(1, max(0, (now - word.born) / LiveReveal.fadeIn))
                let q = word.changed.map { min(1, max(0, (now - $0) / LiveReveal.change)) } ?? 1
                let appear = (1 - pow(1 - p, 3)) * (0.35 + 0.65 * q)
                let strength: Double = if word.pending { Self.pendingStrength }
                    else if let s = word.settled { Self.pendingStrength + (1 - Self.pendingStrength) * min(1, max(0, (now - s) / LiveReveal.settle)) }
                    else { 1 }
                var c = context
                c.opacity = appear * strength
                if !reduceMotion, p < 1 {
                    let rest = 1 - (1 - pow(1 - p, 3))
                    c.translateBy(x: 0, y: rest * 3)
                    c.addFilter(.blur(radius: rest * 2.5))
                }
                c.draw(run)
            }
        }
    }
}
