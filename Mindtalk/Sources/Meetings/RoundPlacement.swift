import Foundation

// MARK: - Who said which name (the round's names onto the voices)
//
// The round knows which turn a name was said in; the live voices know who spoke when.
// Putting the two together is this file, and nothing in it touches audio, the disk or
// the clock: the same evidence gives the same names, so it is tested on made-up words
// (`Mindtalk --round-test`) and called again, from scratch, whenever the evidence gets
// better — the words settling after the round, the final pass after the meeting.
//
// The model, in plain words:
//
// 1. A name goes to the voice that said it. The word that is the name (and the phrase
//    just around it, "jag heter …") decides — not whoever talked most in the turn. A
//    name word whose voice isn't known yet waits for it. The turn's own print (made by
//    the round from its audio) outweighs the word's label when it clearly sounds like
//    another voice in the room. Only a turn whose name was never heard said (typed in the
//    card, or a voice recognised by its print) goes by the whole turn, and then only when
//    one voice clearly had it. The final pass keeps where the live words put a name
//    unless its own words point to another voice.
// 2. A voice that talks through the round is no turn's owner. Heard in two turns or more,
//    or talking from before a turn into it, it is background: a radio, a TV, the next
//    table, or someone talking over. It gets a turn's name only by saying the name word
//    itself as an introduction ("jag heter …", "… här", the name alone), and not when it
//    was talking right up to it (then the word is likelier someone else's, said over it,
//    or a name mentioned in passing). Everyone at the table speaks on their own turn; so
//    does someone on a speakerphone.
// 3. A name you've named before is checked against the voice. A voice whose print is
//    clearly not that person's (from ten seconds of its speech: shorter prints can't
//    tell, see the measurements below) never gets the name; a voice in the room that
//    surely is them does. With neither, the turn waits — at the end of the meeting it stays
//    unplaced (the voice reads "Talare N" and can be named by hand), as a wrong name is
//    worse than none: it would be learned, shown and written into the summary.
// 4. A sure voice match moves a name. A voice that is surely someone you know, whose
//    name sits on another voice that clearly isn't them, takes it; the other voice is
//    unnamed again. Never a name you typed or gave by hand, never onto a voice you said
//    isn't them.
//
// And as before: each name on one voice at most, and two turns heard as one voice — the
// first keeps it.

enum RoundPlacement {
    // MARK: Thresholds (seconds of speech, cosine scores of ReDimNet2+ prints)

    /// A voice is heard in a turn from this much of its speech inside it — a name said
    /// on its own ("Anna") is half a second, a whole introduction three or four.
    static let heardInTurn = 1.0
    /// Heard in this many turns of the round: background. A participant talks in their
    /// own turn (and now and then into the next one, which "first keeps it" covers).
    static let backgroundTurns = 2
    /// Talking within this long before a turn began, and on into it: background for
    /// that turn (still talking when the next person's turn began).
    static let beforeTurn = 1.5
    /// Talking this much during the round outside every turn (while the round waited for
    /// someone, asked for a name, counted down): background. Someone at the table speaks
    /// on their turn; a TV doesn't wait for one.
    static let outsideTurns = 4.0
    /// "Hej, jag heter …": the run of speech a name ends takes at most this long. A
    /// background voice whose run (no pause of `pause` in it) began earlier was talking
    /// right up to the name: the name word under its label is likelier someone else's,
    /// said over it — a TV reads on; a person starts afresh after the turn's prompt.
    static let phraseLength = 2.0
    static let pause = 0.5
    /// The speech model stretches a last word over the quiet after it ("ekonomin." 4.4–
    /// 8.3 s): a word counts as speech for at most this long.
    static let longestWord = 1.0
    /// The speech around a name word that counts when the word itself has no clear
    /// voice (two voices at once): this long before it and after it…
    static let aroundBefore = 1.5
    static let aroundAfter = 1.0
    /// …where the voice must have this much of it, and twice the next voice's.
    static let minimumVote = 0.3
    static let voteMargin = 2.0
    /// A turn without a name word (typed, or recognised): one voice must have this much
    /// speech in it, and this share of all of it (the unknown "two at once" included).
    static let dominantSpeech = 1.0
    static let dominance = 0.7
    // Measured with `Mindtalk --print-length-test` on 49 named voices in 87 meetings
    // (11 people you know; clips of each voice against that person's prints from other
    // meetings, and against everyone else's):
    //
    //   speech   same person: min   p5   median  |  someone else: median  p99   max
    //   2 s                   0.07  0.21  0.66   |                0.19   0.42  0.54
    //   4 s                   0.15  0.39  0.75   |                0.23   0.45  0.56
    //   6 s                   0.23  0.55  0.78   |                0.23   0.46  0.55
    //   10 s                  0.57  0.61  0.80   |                0.24   0.46  0.51
    //
    // So a short print can be someone else's at 0.56, and the right person's at 0.07 (a
    // cough, a laugh, a word over someone else's): it can say "surely them" (others never
    // reached 0.60, or 0.65 under four seconds), but never "clearly not them". From ten
    // seconds the same person never scored under 0.57, and others 0.46 at the 99th
    // percentile: under 0.50 is clearly someone else.

    /// A print from less speech than this says nothing either way (as when the meeting
    /// runs: voices are first compared from two seconds of speech).
    static let shortestPrint = 2.0
    /// Under this much speech a print is "short": a sure match needs a higher score.
    static let shortPrint = 4.0
    /// A sure match from a short print: as when the meeting runs (recogniseIntroduced).
    static let shortSameVoice: Float = 0.65
    /// "Clearly not them" only from this much speech (below VoiceMemory.notThem, 0.50).
    static let notThemSpeech = 10.0

    // The turn's own print (the round makes one from the turn's audio) against the voices
    // of the same meeting, measured with `--print-length-test` on 22 meetings with two
    // voices or more (a clip of a voice against the rest of that voice's speech, and
    // against the other voices in the room):
    //
    //   speech   same voice: min   p5   median  |  another voice: median  p99   max
    //   1.5 s                0.11  0.20  0.67   |                 0.22   0.40  0.41
    //   3 s                  0.15  0.41  0.79   |                 0.28   0.39  0.40
    //   6 s                  0.35  0.50  0.86   |                 0.30   0.37  0.39
    //
    // A low score says nothing (the same voice went down to 0.11), but no other voice in
    // the room ever reached 0.43: a turn scoring 0.50 against a voice is that voice's.
    /// A turn that scores this against a voice (and the margin over every other voice)
    /// sounds like it — evidence that outweighs the label on the name word (a radio's
    /// label on someone's "Hej, jag heter Karin", said over it).
    static let turnThisVoice: Float = 0.50

    // MARK: Inputs

    /// One turn of the round, as the round heard it (seconds into the meeting).
    struct Turn: Equatable {
        var name: String
        /// The turn: from its first sound to when it was done.
        var from: Double
        var to: Double
        /// Where the name itself was said (the word, and a surname with it). nil when it
        /// wasn't heard said: typed in the card, or the voice recognised.
        var said: ClosedRange<Double>?
        /// Recognised in the round by its print: someone you know.
        var known = false
        var score: Float?
        /// Typed by hand in the name card: never moved by a voice match.
        var typed = false
        /// A print of the turn's own audio (made by the round from a second and a half of
        /// speech), when there is one.
        var print: [Float]? = nil
    }

    /// A voice of the meeting, as heard so far: its print, and from how much speech.
    struct Voice: Equatable {
        var print: [Float]
        var seconds: Double
    }

    /// Someone you've named before, and their prints.
    struct Known: Equatable {
        var name: String
        var prints: [[Float]]
    }

    /// How a voice compares with someone you know.
    enum Verdict: Equatable {
        case surely(Float)          // a sure match (and it beats everyone else by the margin)
        case plausible(Float)       // neither: could be them
        case notThem(Float)         // clearly someone else
        case unknown                // no print, or too short to say
    }

    enum Outcome: Equatable {
        case placed(Int)            // the name goes on this voice
        case there(Int)             // the name is already on this voice (recognised, or given)
        case waiting                // not yet: words to settle, or a voice to be heard
        case unplaced               // the meeting is over and no voice clearly said it
    }

    struct Decision: Equatable {
        let turn: Int               // 1-based, as in the round ("Tur 2")
        let outcome: Outcome
        let why: String             // for the log: what decided it, no names
    }

    // MARK: Part 1–3: the round's names

    /// Where each turn's name goes. `fixed`: names on voices that aren't the round's to
    /// change (given by hand, recognised); `final`: the last time this is asked (nothing
    /// waits any more). Turns in the order they were held — "first keeps it".
    static func place(_ turns: [Turn], words: [MeetingWord], voices: [Int: Voice], people: [Known],
                      fixed: [Int: String], rejected: [Int: Set<String>] = [:], round: ClosedRange<Double>? = nil,
                      previous: [Int: Int] = [:], final: Bool) -> [Decision] {
        let words = words.map { w -> MeetingWord in var w = w; w.end = min(w.end, w.start + longestWord); return w }
        let voiced = words.filter { ($0.speaker ?? -1) >= 0 }
        func speech(_ v: Int, _ a: Double, _ b: Double) -> Double {
            voiced.reduce(0) { $1.speaker == v ? $0 + overlap($1, a, b) : $0 }
        }
        let all = Set(voiced.compactMap(\.speaker))
        // How much each voice is heard in each turn, and in how many turns.
        let presence = turns.map { t in Dictionary(uniqueKeysWithValues: all.map { ($0, speech($0, t.from, t.to)) }) }
        var turnsHeard: [Int: Int] = [:]
        for p in presence { for (v, s) in p where s >= heardInTurn { turnsHeard[v, default: 0] += 1 } }
        // How much each voice talked during the round but outside every turn.
        var outside: [Int: Double] = [:]
        if let round {
            let inTurns = turns.map { max(round.lowerBound, $0.from)...max(round.lowerBound, min(round.upperBound, max($0.from, $0.to))) }
            for w in voiced {
                guard let s = w.speaker else { continue }
                var o = overlap(w, round.lowerBound, round.upperBound)
                for t in inTurns { o -= overlap(w, t.lowerBound, t.upperBound) }
                if o > 0 { outside[s, default: 0] += o }
            }
        }
        func background(_ v: Int, _ i: Int) -> Bool {
            if turnsHeard[v, default: 0] >= backgroundTurns || outside[v, default: 0] >= outsideTurns { return true }
            let t = turns[i]
            return presence[i][v, default: 0] >= heardInTurn && speech(v, t.from - beforeTurn, t.from) >= minimumVote
        }

        var owner: [Int: Int] = [:]                 // voice → the turn placed on it in this pass
        var placedNames = Set<String>()
        var out: [Decision] = []
        for (i, t) in turns.enumerated() {
            let n = i + 1
            let key = Self.key(t.name)
            // Already on a voice — recognised, or given by hand — or said twice.
            if let there = fixed.first(where: { Self.key($0.value) == key })?.key {
                out.append(Decision(turn: n, outcome: .there(there), why: "already on voice \(there)"))
                continue
            }
            if placedNames.contains(key) {
                out.append(Decision(turn: n, outcome: final ? .unplaced : .waiting, why: "the same name as an earlier turn"))
                continue
            }
            let person = people.first { Self.key($0.name) == key && !$0.prints.isEmpty }
            // Not a voice for this name: one with a name of its own, one that kept an
            // earlier turn's, one you said isn't them, or one clearly not them.
            func excluded(_ v: Int) -> String? {
                if let other = fixed[v], !other.isEmpty { return "voice \(v) has another name" }
                if let earlier = owner[v] { return "voice \(v) has turn \(earlier)'s name" }
                if rejected[v]?.contains(where: { Self.key($0) == key }) == true { return "voice \(v) was said not to be them" }
                if let person, case .notThem(let s) = verdict(voices[v], person, among: people) {
                    return "voice \(v) is clearly not them (\(fmt(s)) from \(Int(voices[v]?.seconds ?? 0)) s)"
                }
                return nil
            }
            var notes: [String] = []
            var against = Set<Int>()        // voices the evidence speaks against for this turn
            var choice: (voice: Int, why: String)?
            // How the turn itself sounds next to a voice (its own print against the voice's).
            func likeness(_ v: Int) -> Float? {
                guard let tp = t.print, let vp = voices[v]?.print else { return nil }
                return VoiceMemory.cosine(tp, vp)
            }
            // The voice the turn sounds like: at least `turnThisVoice`, clearly ahead of every
            // other voice, and one that could own the turn.
            func soundsLike() -> (Int, Float)? {
                let ranked = voices.keys.compactMap { v -> (Int, Float)? in likeness(v).map { (v, $0) } }.sorted { $0.1 > $1.1 }
                guard let (v, like) = ranked.first, like >= turnThisVoice,
                      like - (ranked.dropFirst().first?.1 ?? -1) >= VoiceMemory.margin,
                      excluded(v) == nil, !background(v, i), all.contains(v) else { return nil }
                return (v, like)
            }
            var waitFor: String?
            var located = false             // the name word found in the words

            if let said = t.said {
                // The name word: the word that is the name, where the round heard it (the final
                // pass writes the words anew, a little earlier or later) — else whatever
                // was said in that place.
                let first = t.name.split(separator: " ").first.map(String.init) ?? t.name
                let near = words.filter { overlap($0, said.lowerBound - 1, said.upperBound + 1) > 0 && isNameWord($0.text, first) }
                let nameWords = near.min(by: { abs($0.start - said.lowerBound) < abs($1.start - said.lowerBound) }).map { [$0] }
                    ?? words.filter { overlap($0, said.lowerBound, said.upperBound) >= 0.4 * min($0.end - $0.start, said.upperBound - said.lowerBound) }
                located = !nameWords.isEmpty
                if nameWords.contains(where: { $0.speaker == nil }) {
                    waitFor = "the name word has no voice yet"
                } else if !nameWords.isEmpty {
                    var byVoice: [Int: Double] = [:]
                    for w in nameWords { if let s = w.speaker, s >= 0 { byVoice[s, default: 0] += w.end - w.start } }
                    if let s = byVoice.max(by: { $0.value < $1.value })?.key {
                        if let why = excluded(s) {
                            notes.append(why); against.insert(s)
                        } else if background(s, i), said.lowerBound - runStart(words, at: said.lowerBound, voice: s) > phraseLength {
                            notes.append("voice \(s) talks through the round and right up to the name"); against.insert(s)
                        } else if background(s, i), !introduces(words, name: nameWords[0], voice: s) {
                            notes.append("voice \(s) talks through the round and mentions the name, no introduction"); against.insert(s)
                        } else if let (v, like) = soundsLike(), v != s, like - (likeness(s) ?? -1) >= VoiceMemory.margin {
                            notes.append("the name word is voice \(s)'s, but the turn sounds like voice \(v) (\(fmt(like)))"); against.insert(s)
                        } else {
                            choice = (s, "said the name")
                        }
                    } else {
                        notes.append("the name word is two voices at once")
                    }
                    // The speech around the name, without the voices that can't be it.
                    if choice == nil {
                        let a = max(t.from - 0.3, said.lowerBound - aroundBefore), b = min(t.to + 0.3, said.upperBound + aroundAfter)
                        let around = words.filter { overlap($0, a, b) > 0 }
                        if around.contains(where: { $0.speaker == nil }) {
                            waitFor = "the words around the name have no voice yet"
                        } else {
                            // (Nor a voice that was talking long before the name, through it.)
                            var votes: [Int: Double] = [:]
                            for w in around {
                                guard let s = w.speaker, s >= 0, excluded(s) == nil, !background(s, i), !against.contains(s),
                                      said.lowerBound - runStart(words, at: said.lowerBound, voice: s) <= phraseLength else { continue }
                                votes[s, default: 0] += overlap(w, a, b)
                            }
                            let ranked = votes.sorted { $0.value > $1.value }
                            if let top = ranked.first, top.value >= minimumVote,
                               top.value >= voteMargin * (ranked.dropFirst().first?.value ?? 0) {
                                choice = (top.key, "spoke around the name (\(fmt(top.value)) s)")
                            } else {
                                notes.append("no voice clearly said it")
                            }
                        }
                    }
                }
            }
            // Recognised in the round by its print: the voice in the turn that surely is them.
            if choice == nil, waitFor == nil, t.said == nil, t.known, let person {
                let mine = presence[i].filter { $0.value > 0 }.keys.sorted().filter { excluded($0) == nil }
                if let v = mine.first(where: { if case .surely = verdict(voices[$0], person, among: people) { return true }; return false }) {
                    choice = (v, "the voice in the turn that is them")
                }
            }
            // No name word to go by (typed, recognised, or not found where it was heard):
            // the whole turn, when one voice clearly had it.
            if choice == nil, waitFor == nil, !located {
                let span = words.filter { overlap($0, t.from, t.to) > 0 }
                if span.contains(where: { $0.speaker == nil }) {
                    waitFor = "the turn's words have no voice yet"
                } else {
                    var total = 0.0
                    var share: [Int: Double] = [:]
                    for w in span {
                        let s = w.speaker ?? -1
                        if s >= 0, background(s, i) { continue }
                        let o = overlap(w, t.from, t.to)
                        total += o
                        if s >= 0, excluded(s) == nil { share[s, default: 0] += o }
                    }
                    if let top = share.max(by: { $0.value < $1.value }), top.value >= dominantSpeech, top.value >= dominance * total {
                        choice = (top.key, "most of the turn (\(fmt(top.value)) of \(fmt(total)) s)")
                    } else {
                        notes.append("no voice had most of the turn")
                    }
                }
            }
            // Not found by the words: the voice in the room the turn itself sounds like — by
            // its own print, clearly ahead of every other voice; never one that talks through
            // the round (a loud TV would make the turn sound like it).
            if choice == nil, waitFor == nil, let (v, like) = soundsLike(), !against.contains(v) {
                choice = (v, "the voice the turn sounds like (\(fmt(like)))")
            }
            // Someone you know, not found in the turn: the voice in the room that surely is them.
            if choice == nil, waitFor == nil, let person {
                let sure = voices.keys.sorted().filter { excluded($0) == nil && fixed[$0] == nil }.compactMap { v -> (Int, Float)? in
                    if case .surely(let s) = verdict(voices[v], person, among: people) { return (v, s) }
                    return nil
                }.max { $0.1 < $1.1 }
                if let (v, s) = sure { choice = (v, "the voice in the room that is them (\(fmt(s)))") }
            }

            // The final pass, with nothing new to say: the voice it was placed on while the
            // meeting ran stays (the final words can make a clear name word "two at once").
            if choice == nil, final, let v = previous[i], all.contains(v), excluded(v) == nil, !against.contains(v) {
                choice = (v, "kept where the live words put it")
            }

            if let choice {
                owner[choice.voice] = n
                placedNames.insert(key)
                let why = ([choice.why] + notes.map { "not " + $0 }).joined(separator: "; ")
                out.append(Decision(turn: n, outcome: .placed(choice.voice), why: why))
            } else {
                let why = ([waitFor].compactMap { $0 } + notes).joined(separator: "; ")
                out.append(Decision(turn: n, outcome: final ? .unplaced : .waiting, why: why.isEmpty ? "no voice heard in it" : why))
            }
        }
        return out
    }

    /// Where the run of speech that ends in the word at `t` began: back through the words
    /// of this voice (or of no clear voice) with no pause between them.
    private static func runStart(_ words: [MeetingWord], at t: Double, voice: Int) -> Double {
        guard var i = words.lastIndex(where: { $0.start <= t + 0.01 }) else { return t }
        var start = words[i].start
        while i > 0 {
            let w = words[i - 1]
            guard start - w.end < pause, w.speaker == voice || w.speaker == MeetingWord.unknown else { break }
            start = w.start
            i -= 1
        }
        return start
    }

    /// "Jag heter Anna", "det är Anna", "Anna här", "my name is Anna" — or the name said
    /// on its own: someone introducing themselves, not a name mentioned in a sentence
    /// (a newsreader's "… sändebudet Steve Witkoff"). Read in the run that ends in the name.
    static func introduces(_ words: [MeetingWord], name: MeetingWord, voice: Int) -> Bool {
        guard let at = words.firstIndex(where: { $0.start == name.start && $0.text == name.text }) else { return true }
        let start = runStart(words, at: name.start, voice: voice)
        let run = words[..<at].filter { $0.start >= start - 0.01 }
            .map { $0.text.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "’" } }
        let next = at + 1 < words.count ? words[at + 1].text.lowercased().filter(\.isLetter) : ""
        if next == "här" || next == "here" { return true }
        let greeting: Set<String> = ["hej", "hejsan", "hallå", "tjena", "tja", "tjenare", "hi", "hello", "hey", "ja", "okej", "och"]
        if run.allSatisfy({ greeting.contains($0) }) { return true }           // "Anna." or "Hej, Anna."
        let lead = run.suffix(3).joined(separator: " ")
        return ["heter", "namn är", "jag är", "det är", "här är", "det här är", "det här var", "name is", "im", "i'm", "i’m", "i am",
                "this is", "called"].contains { lead.hasSuffix($0) }
    }

    /// A word that is a name ("Anna", "Anna,"), spelled another way ("Mattias" for the
    /// "Mathias" the word list made of it), or begun by it ("Annas").
    static func isNameWord(_ text: String, _ name: String) -> Bool {
        let w = text.lowercased().filter { $0.isLetter || $0 == "-" }, n = name.lowercased()
        return !w.isEmpty && (w == n || VoiceMemory.spelledAlike(w, n) || w.hasPrefix(n))
    }

    // MARK: Part 3–4: voices and the people you know

    /// "Clearly not them" below this score, for a print from this much speech (nil: too
    /// little to say): from ten seconds, the bar learning already uses (VoiceMemory.notThem).
    static func notThemBar(seconds: Double) -> Float? {
        seconds < notThemSpeech ? nil : VoiceMemory.notThem
    }

    /// A sure match needs this score (and the margin over everyone else).
    static func sameVoiceBar(seconds: Double) -> Float {
        seconds < shortPrint ? shortSameVoice : VoiceMemory.sameVoice
    }

    /// How a voice compares with a person: their best print, against everyone else's.
    static func verdict(_ voice: Voice?, _ person: Known, among people: [Known]) -> Verdict {
        guard let voice, voice.seconds >= shortestPrint else { return .unknown }
        let score = similarity(voice.print, person.prints)
        if let bar = notThemBar(seconds: voice.seconds), score < bar { return .notThem(score) }
        let next = people.filter { key($0.name) != key(person.name) }.map { similarity(voice.print, $0.prints) }.max() ?? -1
        if score >= sameVoiceBar(seconds: voice.seconds), score - next >= VoiceMemory.margin { return .surely(score) }
        return .plausible(score)
    }

    enum Recognition: Equatable {
        /// An unnamed voice is someone you know.
        case name(speaker: Int, name: String, score: Float)
        /// …whose name sat on a voice that clearly isn't them: moved over.
        case move(name: String, from: Int, to: Int, score: Float, holder: Float)
        /// Continued meeting: the voice is someone named in the part before.
        case merge(speaker: Int, into: Int, score: Float)
    }

    /// Who the unnamed voices are among the people you know — each person once, the
    /// clearest first — with the margin over the next person. A name held by a voice that
    /// isn't the round's or Mindtalk's to change (`movable`: placed by the round or
    /// recognised, and not touched since) stays where it is; one held by a movable voice
    /// that is clearly not that person can move. `earlier`: a continued meeting's names
    /// from the part before (a voice now that is one of them becomes that voice).
    static func recognise(unnamed: [Int: Voice], holders: [Int: Voice], names: [Int: String], movable: Set<Int>,
                          people: [Known], rejected: [Int: Set<String>] = [:],
                          earlier: [Int: String] = [:]) -> (found: [Recognition], notes: [String]) {
        var notes: [String] = []
        var heldBy: [String: Int] = [:]
        for (v, name) in names where !name.isEmpty { heldBy[key(name)] = v }
        // Names on a voice that clearly isn't that person, and free to move: not taken.
        var loose: [String: (holder: Int, score: Float)] = [:]
        for (k, h) in heldBy where movable.contains(h) {
            guard let person = people.first(where: { key($0.name) == k }) else { continue }
            if case .notThem(let s) = verdict(holders[h], person, among: people) { loose[k] = (h, s) }
        }
        let taken = Set(heldBy.keys).subtracting(loose.keys)
        var candidates: [(speaker: Int, name: String, score: Float)] = []
        for (v, voice) in unnamed.sorted(by: { $0.key < $1.key }) {
            let wrong = Set((rejected[v] ?? []).map(key))
            let ranked = people.filter { !taken.contains(key($0.name)) && !wrong.contains(key($0.name)) && !$0.prints.isEmpty }
                .map { ($0.name, similarity(voice.print, $0.prints)) }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { continue }
            let lead = best.1 - (ranked.dropFirst().first?.1 ?? -1)
            guard best.1 >= sameVoiceBar(seconds: voice.seconds), lead >= VoiceMemory.margin else {
                if best.1 >= sameVoiceBar(seconds: voice.seconds) {
                    notes.append("voice \(v): \(fmt(best.1)) but only \(fmt(lead)) ahead of the next, not sure")
                }
                continue
            }
            candidates.append((v, best.0, best.1))
        }
        var found: [Recognition] = []
        var used = Set<String>()
        for c in candidates.sorted(by: { $0.score > $1.score }) where used.insert(key(c.name)).inserted {
            if let e = earlier.first(where: { key($0.value) == key(c.name) })?.key {
                found.append(.merge(speaker: c.speaker, into: e, score: c.score))
            } else if let l = loose[key(c.name)] {
                found.append(.move(name: c.name, from: l.holder, to: c.speaker, score: c.score, holder: l.score))
            } else {
                found.append(.name(speaker: c.speaker, name: c.name, score: c.score))
            }
        }
        return (found, notes)
    }

    /// A name off a voice that clearly isn't that person (it reads "Talare N" again) and
    /// onto the one that surely is — marked as recognised: Mindtalk's own guess, shown as
    /// one, and not learned from as a name you gave.
    static func move(_ name: String, from: Int, to: Int, score: Float, in record: inout MeetingRecord) {
        record.names.removeValue(forKey: String(from))
        record.recognized[String(from)] = nil
        record.names[String(to)] = name
        record.recognized[String(to)] = score
    }

    // MARK: Helpers

    static func key(_ name: String) -> String { name.lowercased().trimmingCharacters(in: .whitespaces) }

    static func similarity(_ print: [Float], _ prints: [[Float]]) -> Float {
        prints.map { VoiceMemory.cosine(print, $0) }.max() ?? -1
    }

    private static func overlap(_ w: MeetingWord, _ a: Double, _ b: Double) -> Double {
        max(0, min(w.end, b) - max(w.start, a))
    }

    static func fmt(_ x: Float) -> String { String(format: "%.2f", x) }
    static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}
