#if DEBUG
import AVFoundation
import Foundation

// MARK: - `Mindtalk --round-test`
//
// The round's names onto the voices (RoundPlacement), on made-up words, turns and
// prints: no audio, no models, nothing read or written. One line per case, and a
// non-zero exit when one fails.

enum RoundPlacementTest {
    typealias Turn = RoundPlacement.Turn
    typealias Voice = RoundPlacement.Voice

    static let names = ["Anna", "Erik", "Karin", "Johan", "Maria", "Lars"]

    /// A print that scores `score` against `base` (and next to nothing against anyone else).
    static func like(_ base: [Float], _ score: Float, seed: String) -> [Float] {
        let other = VoiceMemory.demoPrint(seed)
        let dot = zip(other, base).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        var orth = zip(other, base).map { $0 - dot * $1 }
        let n = orth.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        orth = orth.map { $0 / max(n, 1e-6) }
        let s = max(-1, min(1, score))
        return zip(base, orth).map { s * $0 + (1 - s * s).squareRoot() * $1 }
    }

    static func person(_ name: String) -> RoundPlacement.Known {
        RoundPlacement.Known(name: name, prints: [VoiceMemory.demoPrint("person-" + name.lowercased())])
    }

    /// Words said by one voice from `start`, 0.35 s each with 0.05 s between them.
    static func words(_ text: String, _ speaker: Int?, at start: Double) -> [MeetingWord] {
        text.split(separator: " ").enumerated().map { i, w in
            MeetingWord(text: String(w), start: start + Double(i) * 0.4, end: start + Double(i) * 0.4 + 0.35, speaker: speaker)
        }
    }

    /// A round: person k on turn k, "Hej, jag heter <name>, och jag jobbar här." on voice k
    /// (or `voice(k)`), a turn every six seconds. Returns the words, and the turns as the
    /// round hands them over (the name word's place included).
    static func round(_ n: Int, voice: (Int) -> Int = { $0 }, nameVoice: ((Int) -> Int?)? = nil,
                      start: Double = 1) -> (words: [MeetingWord], turns: [Turn]) {
        var all: [MeetingWord] = [], turns: [Turn] = []
        for k in 0..<n {
            let t0 = start + Double(k) * 6
            var w = words("Hej, jag heter \(names[k]), och jag jobbar här.", voice(k), at: t0)
            if let nameVoice { w[3].speaker = nameVoice(k) }
            all += w
            turns.append(Turn(name: names[k], from: t0 - 0.1, to: w.last!.end + 0.6, said: w[3].start...w[3].end))
        }
        return (all, turns)
    }

    static func placed(_ d: [RoundPlacement.Decision]) -> [Int?] {
        d.map { if case .placed(let v) = $0.outcome { return v }; return nil }
    }

    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "  — " + detail()))
            if !ok { failed += 1 }
        }
        check("--round-test is a self-test: nothing it does is kept (Settings.previewing)", Settings.previewing)

        // 1. A quiet room, 2, 4 and 6 people taking turns.
        for n in [2, 4, 6] {
            let r = round(n)
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: false)
            check("quiet room, \(n) people: each name on the voice that said it", placed(d) == Array(0..<n), "\(d)")
        }

        // 2. A voice talking through every turn (a radio, the next table): the people get
        // their names, it gets none — also where it is louder around a name.
        do {
            var r = round(4, nameVoice: { $0 % 2 == 1 ? MeetingWord.unknown : $0 })
            var bg: [MeetingWord] = []
            var t = 0.2
            while t < 26 {
                if !r.words.contains(where: { $0.end > t && $0.start < t + 0.35 }) {
                    bg.append(MeetingWord(text: "väder", start: t, end: t + 0.35, speaker: 9))
                }
                t += 0.4
            }
            r.words = (r.words + bg).sorted { $0.start < $1.start }
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: true)
            check("a voice talking through all turns: never named, everyone else is", placed(d) == [0, 1, 2, 3], "\(d)")
        }

        // 3. A name said over a louder voice that talks through the round.
        // (a) The name word is two voices at once, the louder one has "Hej, jag heter":
        // the person's own words after the name decide.
        do {
            var w = words("men förstärks istället i samband med kallfronten Hej jag heter", 9, at: 0.2)
            w += [MeetingWord(text: "Mathias.", start: w.last!.end + 0.05, end: w.last!.end + 0.6, speaker: MeetingWord.unknown)]
            let nameAt = w.last!.start...w.last!.end
            w += words("och jag jobbar här", 1, at: w.last!.end + 0.1)
            w += words("och västra Svealand den rör sig vidare norrut här upp fram på dagen mot västra Svealand", 9, at: w.last!.end + 0.1)
            let turn2 = words("Hej jag heter Anna", 2, at: w.last!.end + 1.5) + words("mycket gråväder i norr", 9, at: w.last!.end + 3.5)
            let turns = [Turn(name: "Mathias", from: 0.1, to: nameAt.upperBound + 1, said: nameAt),
                         Turn(name: "Anna", from: turn2[0].start - 0.1, to: turn2.last!.end + 0.5, said: turn2[3].start...turn2[3].end)]
            let d = RoundPlacement.place(turns, words: w + turn2, voices: [:], people: [], fixed: [:], final: false)
            check("a name over a louder voice: the person's own words around it decide", placed(d) == [1, 2], "\(d)")
            // (b) Everything under the louder voice's label, the names too (it talks on
            // through both turns): not its names, and nobody else is heard — nobody gets them.
            var loud = words("men förstärks istället i samband med kallfronten Hej jag heter Mathias och västra Svealand den rör sig vidare norrut", 9, at: 0.2)
            loud += words("här upp fram på dagen mot västra Svealand också mycket gråväder Hej jag heter Anna i norr med dimma som kan bli liggande", 9, at: loud.last!.end + 0.05)
            let m = loud.first { $0.text == "Mathias" }!, a = loud.first { $0.text == "Anna" }!
            let loudTurns = [Turn(name: "Mathias", from: 0.1, to: m.end + 1.5, said: m.start...m.end),
                             Turn(name: "Anna", from: a.start - 2, to: a.end + 1.5, said: a.start...a.end)]
            let d2 = RoundPlacement.place(loudTurns, words: loud, voices: [:], people: [], fixed: [:], final: true)
            check("a name over a louder voice heard as it: not given to that voice", placed(d2) == [nil, nil], "\(d2)")
        }

        // The TV test of 21 October: "Hej, jag heter Mathias" over a weather report, the
        // words two voices at once, "Hej" under the TV's label. Mathias is known; the TV
        // is clearly not him. While his own voice hasn't been heard: waits. Once it has
        // (and surely is him): his name goes there.
        do {
            let mathias = person("Mathias"), anna = person("Anna")
            var w = words("men förstärks istället i samband med kallfronten. Hej,", 0, at: 0.3)
            let name = MeetingWord(text: "Mathias.", start: 3.52, end: 4.08, speaker: MeetingWord.unknown)
            w += [MeetingWord(text: "jag", start: 3.2, end: 3.28, speaker: MeetingWord.unknown),
                  MeetingWord(text: "heter", start: 3.28, end: 3.52, speaker: MeetingWord.unknown), name]
            w += words("och västra Svealand. Den rör sig vidare norrut här upp fram på dagen mot västra Svealand också", 0, at: 4.8)
            w += words("mycket gråväder i norr med dimma som kan bli liggande hela dagen och kanske lite regnstänk", 0, at: 12)
            let turn = Turn(name: "Mathias", from: 0.0, to: 4.3, said: name.start...name.end)
            let tv = Voice(print: like(mathias.prints[0], 0.31, seed: "tv"), seconds: 38)
            let d = RoundPlacement.place([turn], words: w, voices: [0: tv], people: [mathias, anna], fixed: [:], final: false)
            check("TV test: not on the TV, waiting for his voice", d.first?.outcome == .waiting, "\(d)")
            let later = w + words("ju fler inblandade i det här mötet du borde känna igen min röst", 1, at: 53)
            let him = Voice(print: like(mathias.prints[0], 0.84, seed: "him"), seconds: 6)
            let d2 = RoundPlacement.place([turn], words: later, voices: [0: tv, 1: him], people: [mathias, anna], fixed: [:], final: false)
            check("TV test: on his own voice once it is heard", placed(d2) == [1], "\(d2)")
            let d3 = RoundPlacement.place([turn], words: w, voices: [0: tv], people: [mathias, anna], fixed: [:], final: true)
            check("TV test: never heard alone, the meeting over: left unplaced (Talare N)", d3.first?.outcome == .unplaced, "\(d3)")
            // Nobody known, and the TV in only this one turn (the round waited through the
            // rest of it): still not the TV's — it talked through the round outside the
            // turn, and was talking long before the name, through it.
            let d4 = RoundPlacement.place([turn], words: w, voices: [:], people: [], fixed: [:], round: 0...40, final: true)
            check("TV test, no voices known: not on the TV (it talks through the round)", d4.first?.outcome == .unplaced, "\(d4)")
            let d5 = RoundPlacement.place([turn], words: w, voices: [:], people: [], fixed: [:], final: true)
            check("…and without the round's time: not on the TV (talking long before the name)", d5.first?.outcome == .unplaced, "\(d5)")
        }

        // The speech model stretches a last word over the quiet after it, into the next
        // turn ("ekonomin." 4.4–8.3 s), and a slow "Hej, … jag heter": still each on their own.
        do {
            var r = round(3)
            let last0 = r.words.lastIndex { $0.speaker == 0 }!
            r.words[last0].end = r.turns[1].from + 1.6
            let hej1 = r.words.firstIndex { $0.speaker == 1 }!
            r.words[hej1].start -= 0.6
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: true)
            check("a last word stretched into the next turn, a slow \"Hej\": each name still on its voice",
                  placed(d) == [0, 1, 2], "\(d)")
        }

        // The final pass writes the words anew: the name word a little later, stretched over
        // the quiet after it, and spelled as the word list doesn't ("Mattias"): still found.
        do {
            var r = round(2)
            r.turns[1].name = "Mathias"
            let i = r.words.firstIndex { $0.text.hasPrefix("Erik") }!
            r.words[i].text = "Mattias."
            r.words[i].start += 0.6
            r.words[i].end += 2.4
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: true)
            check("the final pass's words: the name word found by its sound near where it was heard", placed(d) == [0, 1], "\(d)")
        }

        // A voice talking through the round says a name mid-sentence ("… den amerikanske
        // sändebudet Steve Witkoff"): not an introduction, not its name.
        do {
            var w = words("Tack för det. När vi kommer tillbaka ska vi få en direkt rapport från Ukraina", 2, at: 10)
            w += words("Selenskyj och det amerikanska sändebudet Steve Witkoff dessutom ska vi prata om", 2, at: w.last!.end + 0.6)
            let steve = w.first { $0.text == "Steve" }!
            let turn = Turn(name: "Steve Witkoff", from: steve.start - 1, to: steve.end + 1, said: steve.start...steve.end)
            let d = RoundPlacement.place([turn], words: w, voices: [:], people: [], fixed: [:], round: 0...40, final: true)
            check("a voice talking through the round says a name mid-sentence: not its name", placed(d) == [nil], "\(d)")
        }

        // The final pass keeps where the live words put a name, unless its own words point
        // elsewhere: a name word that has become "two voices at once" changes nothing.
        do {
            let r = round(2)
            let blurred = r.words.map { w -> MeetingWord in var w = w; if w.speaker == 1 { w.speaker = MeetingWord.unknown }; return w }
            let d = RoundPlacement.place(r.turns, words: blurred + words("och så vidare", 1, at: 30), voices: [:], people: [],
                                         fixed: [:], previous: [0: 0, 1: 1], final: true)
            check("final pass, the name word now two voices at once: the live placement stays", placed(d) == [0, 1], "\(d)")
            let moved = r.words.map { w -> MeetingWord in var w = w; if w.speaker == 1 { w.speaker = 2 }; return w }
            let d2 = RoundPlacement.place(r.turns, words: moved, voices: [:], people: [], fixed: [:], previous: [0: 0, 1: 1], final: true)
            check("final pass, the name word now another voice's: it goes there", placed(d2) == [0, 2], "\(d2)")
        }

        // A radio talking through the round, and the speech model hearing Karin's "Hej, jag
        // heter Karin" in the radio's voice: the turn's own print doesn't sound like the
        // radio, it sounds like Karin's voice (heard later): her name goes there.
        do {
            var w = words("i östra delarna mest uppehåll", 9, at: 13.4)
            w += words("Hej, jag heter Karin och jag jobbar med design.", 9, at: 17.2)
            w += words("i morgon väntas ett nytt lågtryck", 9, at: 21.3)
            w += words("jag skickar siffrorna i eftermiddag", 4, at: 40)
            let karin = VoiceMemory.demoPrint("karin-voice"), radio = VoiceMemory.demoPrint("radio-voice")
            let name = w.first { $0.text.hasPrefix("Karin") }!
            let turn = Turn(name: "Karin", from: 17, to: 21.6, said: name.start...name.end, print: like(karin, 0.72, seed: "karin-turn"))
            let voices = [9: Voice(print: radio, seconds: 30), 4: Voice(print: like(karin, 0.95, seed: "karin-later"), seconds: 8)]
            let d = RoundPlacement.place([turn], words: w, voices: voices, people: [], fixed: [:], round: 0...33, final: true)
            check("an intro heard in a background voice: the turn's own print puts it on the voice it sounds like",
                  placed(d) == [4], "\(d)")
            // A TV louder than the person, reading on right up to the name: the turn sounds like
            // the TV — and still the name isn't the TV's.
            var tvTurn = turn
            tvTurn.print = like(radio, 0.85, seed: "tv-turn")
            var glued = words("i östra delarna mest uppehåll med", 9, at: 14.8)
            glued += words("Hej, jag heter Karin och jag jobbar med design.", 9, at: glued.last!.end + 0.1)
            glued += words("i morgon väntas ett nytt lågtryck", 9, at: glued.last!.end + 0.1)
            let k2 = glued.first { $0.text.hasPrefix("Karin") }!
            tvTurn.said = k2.start...k2.end
            let d2 = RoundPlacement.place([tvTurn], words: glued, voices: voices, people: [], fixed: [:], round: 0...33, final: true)
            check("a turn that sounds like a TV reading on through the round: still not the TV's name", placed(d2) == [nil], "\(d2)")
        }

        // 4. The name word's voice not known yet: wait, then place.
        do {
            let r = round(2, nameVoice: { $0 == 1 ? nil : $0 })
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: false)
            check("name word without a voice yet: waits", placed(d) == [0, nil] && d[1].outcome == .waiting, "\(d)")
            let settled = r.words.map { w -> MeetingWord in var w = w; if w.speaker == nil { w.speaker = 1 }; return w }
            let d2 = RoundPlacement.place(r.turns, words: settled, voices: [:], people: [], fixed: [:], final: false)
            check("…and once it has one: placed", placed(d2) == [0, 1], "\(d2)")
        }

        // 5. A known name on a voice that clearly isn't them: a sure match moves it.
        let mathias = person("Mathias"), anna = person("Anna"), sara = person("Sara"), karin = person("Karin")
        let people = [mathias, anna, sara, karin]
        let tv = Voice(print: like(mathias.prints[0], 0.31, seed: "tv"), seconds: 38)
        let him = Voice(print: like(mathias.prints[0], 0.84, seed: "him"), seconds: 10)
        do {
            let (found, _) = RoundPlacement.recognise(unnamed: [1: him], holders: [0: tv], names: [0: "Mathias"],
                                                      movable: [0], people: people)
            check("a known name on a clearly wrong voice: moved to the voice that surely is them",
                  found == [.move(name: "Mathias", from: 0, to: 1, score: RoundPlacement.similarity(him.print, mathias.prints),
                                  holder: RoundPlacement.similarity(tv.print, mathias.prints))], "\(found)")
            // …and what is learned after it: neither voice teaches "Mathias" (the TV is
            // unnamed, his voice was recognised, not named).
            var record = MeetingRecord(title: "t", date: Date(), language: .swedish)
            record.names = ["0": "Mathias", "2": "Anna"]
            RoundPlacement.move("Mathias", from: 0, to: 1, score: 0.84, in: &record)
            let given = record.names.filter { record.recognized[$0.key] == nil }
            check("after the move: learned from Anna's voice only, never the TV's", given == ["2": "Anna"]
                  && record.names["0"] == nil && record.names["1"] == "Mathias", "\(record.names) \(record.recognized)")
            // A holder that could be them (a far microphone, a short print): stays.
            let maybe = Voice(print: like(mathias.prints[0], 0.55, seed: "maybe"), seconds: 12)
            let (kept, _) = RoundPlacement.recognise(unnamed: [1: him], holders: [0: maybe], names: [0: "Mathias"],
                                                     movable: [0], people: people)
            check("a holder that might be them keeps the name", kept.isEmpty, "\(kept)")
        }

        // 6. A name typed (or given by hand) is never moved, whatever the voices say.
        do {
            let (found, _) = RoundPlacement.recognise(unnamed: [1: him], holders: [0: tv], names: [0: "Mathias"],
                                                      movable: [], people: people)
            check("a typed name is never moved", found.isEmpty, "\(found)")
            // A typed turn has no name word: the voice that had the turn takes it.
            var r = round(2)
            r.turns[1].said = nil
            r.turns[1].typed = true
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: false)
            check("a typed name goes on the voice that had the turn", placed(d) == [0, 1], "\(d)")
            // Rejected ("Fel person?"): never put back there.
            let d2 = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:],
                                          rejected: [1: ["Erik"]], final: true)
            check("a name you took off a voice isn't put back there", placed(d2) == [0, nil], "\(d2)")
        }

        // 7. Two people with similar voices: a match without the margin decides nothing.
        do {
            // Anna and Sara's prints are nearly at right angles: 0.68 of one, 0.63 of the
            // other and the rest elsewhere scores about that against each.
            let rest = VoiceMemory.demoPrint("similar")
            let c = (1 - 0.68 * 0.68 - 0.63 * 0.63 as Float).squareRoot()
            let mixed = (0..<192).map { 0.68 * anna.prints[0][$0] + 0.63 * sara.prints[0][$0] + c * rest[$0] }
            let norm = mixed.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            let v = Voice(print: mixed.map { $0 / norm }, seconds: 12)
            let a = RoundPlacement.similarity(v.print, anna.prints), s = RoundPlacement.similarity(v.print, sara.prints)
            let wrongAnna = Voice(print: like(anna.prints[0], 0.2, seed: "wrong-anna"), seconds: 20)
            let (found, _) = RoundPlacement.recognise(unnamed: [1: v], holders: [0: wrongAnna], names: [0: "Anna"],
                                                      movable: [0], people: people)
            check("similar voices (Anna \(RoundPlacement.fmt(a)), Sara \(RoundPlacement.fmt(s))): no move, no name",
                  found.isEmpty && a >= VoiceMemory.sameVoice && abs(a - s) < VoiceMemory.margin, "\(found)")
        }

        // 8. Someone on a speakerphone, heard only on their own turn (and quieter): placed.
        do {
            var r = round(4)
            // Person 3 speaks in the speakerphone's own voice, and only a short phrase.
            r.words.removeAll { $0.speaker == 3 }
            let phone = words("Hej det är Johan", 7, at: 19)
            r.words += phone
            r.turns[3] = Turn(name: "Johan", from: 18.9, to: 21, said: phone[3].start...phone[3].end)
            let d = RoundPlacement.place(r.turns, words: r.words.sorted { $0.start < $1.start }, voices: [:], people: [],
                                         fixed: [:], final: false)
            check("a speakerphone participant, on their own turn: placed", placed(d) == [0, 1, 2, 7], "\(d)")
        }

        // 9. Far from the microphone: a low but plausible score is not "clearly not them".
        do {
            let r = round(3)
            let far = Voice(print: like(karin.prints[0], 0.42, seed: "far"), seconds: 3)
            let r3 = (r.words, r.turns.enumerated().map { i, t -> Turn in var t = t; if i == 2 { t.name = "Karin" }; return t })
            let d = RoundPlacement.place(r3.1, words: r3.0, voices: [2: far], people: people, fixed: [:], final: false)
            check("far from the mic, 0.42 from 3 s: still placed", placed(d) == [0, 1, 2], "\(d)")
            let farLong = Voice(print: like(karin.prints[0], 0.52, seed: "far-long"), seconds: 9)
            let d2 = RoundPlacement.place(r3.1, words: r3.0, voices: [2: farLong], people: people, fixed: [:], final: false)
            check("far from the mic, 0.52 from 9 s: still placed", placed(d2) == [0, 1, 2], "\(d2)")
            let short = Voice(print: like(karin.prints[0], 0.15, seed: "short-karin"), seconds: 4)
            let d0 = RoundPlacement.place(r3.1, words: r3.0, voices: [2: short], people: people, fixed: [:], final: false)
            check("0.15 from 4 s: too short to say it isn't them (the same person has scored 0.15 at 4 s)",
                  placed(d0) == [0, 1, 2], "\(d0)")
            let wrong = Voice(print: like(karin.prints[0], 0.2, seed: "not-karin"), seconds: 12)
            let d3 = RoundPlacement.place(r3.1, words: r3.0, voices: [2: wrong], people: people, fixed: [:], final: true)
            check("…but 0.20 from 12 s is clearly someone else: not placed", placed(d3) == [0, 1, nil], "\(d3)")
            check("\"clearly not them\" only from ten seconds of speech",
                  RoundPlacement.notThemBar(seconds: 9.9) == nil && RoundPlacement.notThemBar(seconds: 10) == VoiceMemory.notThem)
        }

        // 10. A continued meeting: a voice now that is someone from the part before is them
        // (merged into that voice), never a move of a name from the part before.
        do {
            let annaNow = Voice(print: like(anna.prints[0], 0.8, seed: "anna-now"), seconds: 8)
            let (found, _) = RoundPlacement.recognise(unnamed: [5: annaNow], holders: [:], names: [:], movable: [],
                                                      people: people, earlier: [0: "Anna"])
            check("continued meeting: a voice from the part before is merged into it",
                  found.count == 1 && { if case .merge(5, 0, _) = found[0] { return true }; return false }(), "\(found)")
            let r = round(2)
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [0: "Anna"], final: false)
            check("continued meeting: a name already on a voice stays there", d.first?.outcome == .there(0) && placed(d) == [nil, 1], "\(d)")
        }

        // The rules kept from before.
        do {
            let r = round(2, voice: { _ in 0 })
            let d = RoundPlacement.place(r.turns, words: r.words, voices: [:], people: [], fixed: [:], final: true)
            check("two turns heard as one voice: the first keeps it", placed(d) == [0, nil], "\(d)")
            let d2 = RoundPlacement.place(round(2).turns, words: round(2).words, voices: [:], people: [], fixed: [3: "Anna"], final: false)
            check("each name on one voice: already given elsewhere, it stays there", d2.first?.outcome == .there(3) && placed(d2) == [nil, 1], "\(d2)")
            // Someone running the round says "nästa" in each turn: still not background.
            var host = round(4)
            for k in 1..<4 { host.words += words("Tack, nästa", 0, at: 1 + Double(k) * 6 - 0.9) }
            let d3 = RoundPlacement.place(host.turns, words: host.words.sorted { $0.start < $1.start }, voices: [:], people: [],
                                          fixed: [:], final: false)
            check("a host saying \"nästa\" in each turn keeps their own name, takes no one else's", placed(d3) == [0, 1, 2, 3], "\(d3)")
            // Recognised in the round by its print, nothing said: the voice in the turn that is them.
            var known = round(2)
            known.turns[1] = Turn(name: "Karin", from: known.turns[1].from, to: known.turns[1].to, said: nil, known: true, score: 0.8)
            let d4 = RoundPlacement.place(known.turns, words: known.words,
                                          voices: [1: Voice(print: like(karin.prints[0], 0.8, seed: "k"), seconds: 4)],
                                          people: people, fixed: [:], final: false)
            check("recognised in the round: on the voice in the turn that is them", placed(d4) == [0, 1], "\(d4)")
        }

        print(failed == 0 ? "Round placement self-test passed." : "\(failed) fel")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - `Mindtalk --print-length-test`
//
// How short prints behave, measured on the meetings in this run's store (a copy of
// yours, in a temporary HOME with --models-dir): for each voice named after someone you
// know, clips of 1.5–10 s of its speech, each compared with that person's prints from
// other meetings ("same") and with everyone else's ("other") — voices whose whole print
// doesn't sound like the person they're named after are left out. The thresholds in
// RoundPlacement come from these numbers. Nothing is written.

@MainActor
enum PrintLengthTest {
    static func run() async -> Int32 {
        MeetingStore.shared.loadNow()
        let url = MeetingStore.root.appendingPathComponent("People.json")
        await VoiceMemory.shared.test(people: url)
        let people = VoiceMemory.shared.people.filter { !$0.prints.isEmpty }
        guard !people.isEmpty else { print("Inga kända röster i \(url.path)"); return 1 }
        let lengths = [1.5, 2, 3, 4, 6, 10]
        var same: [Double: [Float]] = [:], other: [Double: [Float]] = [:]
        var voices = 0, mislabelled = 0
        for record in MeetingStore.shared.meetings where record.hasAudio {
            let source = record.id.uuidString
            let audio = MeetingStore.audioURL(for: record.id)
            guard let file = try? AVAudioFile(forReading: audio) else { continue }
            for (key, name) in record.names where !name.isEmpty {
                guard let speaker = Int(key), let person = people.first(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
                // Their prints from other meetings only.
                let sources = person.sources ?? []
                let rest = person.prints.enumerated().filter { $0.offset >= sources.count || sources[$0.offset] != source }.map(\.element)
                guard !rest.isEmpty else { continue }
                var samples: [Float] = []
                for s in VoicePrints.stretches(of: speaker, in: record.words) { samples += read(file, from: s.start, to: s.end) }
                guard samples.count >= 6 * 16_000 else { continue }
                // A voice named wrongly in that meeting (the TV named Mathias) would count
                // as "the same person scoring low": only voices whose whole print is them.
                guard let whole = await VoicePrints.shared.print(of: speaker, in: record.words, audio: audio),
                      RoundPlacement.similarity(whole, rest) >= VoiceMemory.sameVoice else { mislabelled += 1; continue }
                voices += 1
                for L in lengths {
                    let n = Int(L * 16_000)
                    var offset = 0, clips = 0
                    while offset + n <= samples.count, clips < 6 {
                        if let print = await VoicePrints.shared.print(raw: Array(samples[offset..<offset + n])) {
                            same[L, default: []].append(RoundPlacement.similarity(print, rest))
                            for q in people where q.id != person.id {
                                let qs = q.sources ?? []
                                let qRest = q.prints.enumerated().filter { $0.offset >= qs.count || qs[$0.offset] != source }.map(\.element)
                                if !qRest.isEmpty { other[L, default: []].append(RoundPlacement.similarity(print, qRest)) }
                            }
                        }
                        offset += n
                        clips += 1
                    }
                }
            }
        }
        func q(_ xs: [Float], _ p: Double) -> String {
            guard !xs.isEmpty else { return "  –  " }
            let s = xs.sorted()
            return String(format: "%.2f", s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))])
        }
        print("\(voices) namngivna röster (\(mislabelled) till som hela inte låter som personen: utelämnade), \(people.count) kända personer")
        print("längd   samma: n  min   p5   p50  |  andra: n   p50  p95  p99  max")
        for L in lengths {
            let a = same[L] ?? [], b = other[L] ?? []
            print(String(format: "%4.1f s  %8d  ", L, a.count) + "\(q(a, 0)) \(q(a, 0.05)) \(q(a, 0.5))  |  "
                  + String(format: "%6d  ", b.count) + "\(q(b, 0.5)) \(q(b, 0.95)) \(q(b, 0.99)) \(q(b, 1))")
        }
        // Within one meeting (a round's turn against the voices in the same room): a clip
        // of a voice against the print of the rest of that voice's speech ("same"), and
        // against the other voices of the meeting ("other"). Every voice the separation
        // heard, named or not.
        var inSame: [Double: [Float]] = [:], inOther: [Double: [Float]] = [:]
        var meetings = 0
        for record in MeetingStore.shared.meetings where record.hasAudio {
            let audio = MeetingStore.audioURL(for: record.id)
            guard let file = try? AVAudioFile(forReading: audio) else { continue }
            var speech: [Int: [Float]] = [:], whole: [Int: [Float]] = [:]
            for speaker in Set(record.words.compactMap(\.speaker).filter { $0 >= 0 }).sorted() {
                var samples: [Float] = []
                for st in VoicePrints.stretches(of: speaker, in: record.words) { samples += read(file, from: st.start, to: st.end) }
                guard samples.count >= 12 * 16_000, let p = await VoicePrints.shared.print(raw: samples) else { continue }
                speech[speaker] = samples
                whole[speaker] = p
            }
            guard whole.count >= 2 else { continue }
            meetings += 1
            for (speaker, samples) in speech {
                for L in lengths where L <= 6 {
                    let n = Int(L * 16_000)
                    for k in 0..<2 {
                        let at = (samples.count - n) * (k + 1) / 3
                        let rest = Array(samples[..<at]) + Array(samples[(at + n)...])
                        guard let clip = await VoicePrints.shared.print(raw: Array(samples[at..<at + n])),
                              let restPrint = await VoicePrints.shared.print(raw: rest) else { continue }
                        inSame[L, default: []].append(VoiceMemory.cosine(clip, restPrint))
                        for (other, p) in whole where other != speaker { inOther[L, default: []].append(VoiceMemory.cosine(clip, p)) }
                    }
                }
            }
        }
        print("\nInom samma möte (\(meetings) möten med två röster eller fler):")
        print("längd   samma röst: n  min   p1   p5  p50  |  annan röst: n  p50  p95  p99  max")
        for L in lengths where L <= 6 {
            let a = inSame[L] ?? [], b = inOther[L] ?? []
            print(String(format: "%4.1f s  %8d  ", L, a.count) + "\(q(a, 0)) \(q(a, 0.01)) \(q(a, 0.05)) \(q(a, 0.5))  |  "
                  + String(format: "%6d  ", b.count) + "\(q(b, 0.5)) \(q(b, 0.95)) \(q(b, 0.99)) \(q(b, 1))")
        }
        return 0
    }

    /// 16 kHz samples between two times (the stretches are trimmed already).
    private static func read(_ file: AVAudioFile, from start: Double, to end: Double) -> [Float] {
        let first = AVAudioFramePosition(max(0, start) * 16_000)
        let count = AVAudioFrameCount(max(0, (end - start) * 16_000))
        guard first < file.length, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: min(count, AVAudioFrameCount(file.length - first)))) != nil,
              let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
#endif
