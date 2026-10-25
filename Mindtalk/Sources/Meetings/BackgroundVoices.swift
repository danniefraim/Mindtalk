import Foundation

#if DEBUG
// Measures only, for now (`--background-features`): on real meetings a TV and a quiet
// participant measured alike, so nothing is decided from them yet. A voice is marked as
// background by hand (MeetingRecord.background).

/// A voice in the room that isn't taking part: a TV, a radio, the next table. Told
/// apart from the people after the meeting, from the recording and who spoke when —
/// never by itself hidden when it could be someone at the far end of the table.
enum BackgroundVoices {
    /// What sets a voice apart, per speaker.
    struct Features: Equatable {
        let speaker: Int
        let words: Int
        /// Seconds of its words.
        let seconds: Double
        /// Its share of all that was said.
        let share: Double
        /// How loud it is (median of its words, dB), and against the loudest voice.
        let level: Double
        let relativeLevel: Double
        /// How bright (high frequencies against the whole), against the median voice:
        /// sound from a TV's or a phone's small speaker is duller.
        let relativeBrightness: Double
        /// What the room gives back just after its words (dB against the words): a voice
        /// far off, in a room, rings on longer than one near the microphone.
        let tail: Double
        /// Of its turns, how many start just after someone else's ended (answering), and
        /// how many are followed by someone else just after (being answered).
        let answers: Double
        let answered: Double
        /// Named in the round, typed in, or a voice recognised: a person, whatever it sounds like.
        let named: Bool
    }

    /// The features of every voice with enough words to judge.
    static func features(words: [MeetingWord], samples: [Float], named: Set<Int>, rate: Double = 16_000) -> [Features] {
        let spoken = words.filter { ($0.speaker ?? -1) >= 0 && $0.end > $0.start }
        let speakers = Set(spoken.compactMap(\.speaker))
        guard speakers.count > 1, !samples.isEmpty else { return [] }
        func span(_ from: Double, _ to: Double) -> ArraySlice<Float> {
            let a = max(0, min(samples.count, Int(from * rate))), b = max(a, min(samples.count, Int(to * rate)))
            return samples[a..<b]
        }
        func rms(_ x: ArraySlice<Float>) -> Double {
            guard !x.isEmpty else { return 0 }
            var s = 0.0
            for v in x { s += Double(v) * Double(v) }
            return (s / Double(x.count)).squareRoot()
        }
        func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-7)) }
        func brightness(_ x: ArraySlice<Float>) -> Double {
            guard x.count > 2 else { return 0 }
            var e = 0.0, d = 0.0
            var prev = x.first!
            for v in x.dropFirst() { e += Double(v) * Double(v); let q = Double(v - prev); d += q * q; prev = v }
            return e > 0 ? d / e : 0
        }
        func median(_ v: [Double]) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }

        // Turns: a speaker's words with less than a second and a half between them.
        struct Turn { let speaker: Int; let start: Double; var end: Double }
        var turns: [Turn] = []
        for w in spoken {
            if var last = turns.last, last.speaker == w.speaker, w.start - last.end < 1.5 {
                last.end = max(last.end, w.end); turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: w.speaker!, start: w.start, end: w.end))
            }
        }

        let total = spoken.reduce(0) { $0 + ($1.end - $1.start) }
        var out: [Features] = []
        var levels: [Int: Double] = [:], brights: [Int: Double] = [:]
        var raw: [Int: (words: Int, seconds: Double, tail: Double, answers: Double, answered: Double)] = [:]
        for s in speakers {
            let mine = spoken.enumerated().filter { $0.element.speaker == s }
            guard mine.count >= 8 else { continue }
            var wordLevels: [Double] = [], wordBright: [Double] = [], tails: [Double] = []
            for (i, w) in mine {
                guard w.end - w.start >= 0.12 else { continue }
                let x = span(w.start, w.end)
                let level = rms(x)
                wordLevels.append(db(level))
                wordBright.append(brightness(x))
                // A pause after it (nobody speaking for a third of a second): the room's answer.
                let next = i + 1 < spoken.count ? spoken[i + 1].start : w.end + 1
                if next - w.end >= 0.35, level > 0 {
                    tails.append(db(rms(span(w.end + 0.06, w.end + 0.26))) - db(level))
                }
            }
            guard let level = median(wordLevels), let bright = median(wordBright) else { continue }
            levels[s] = level
            brights[s] = bright
            let own = turns.indices.filter { turns[$0].speaker == s }
            let answers = own.filter { k in k > 0 && turns[k - 1].speaker != s && turns[k].start - turns[k - 1].end < 1.2 }.count
            let answered = own.filter { k in k + 1 < turns.count && turns[k + 1].speaker != s && turns[k + 1].start - turns[k].end < 1.2 }.count
            raw[s] = (mine.count, mine.reduce(0) { $0 + ($1.element.end - $1.element.start) }, median(tails) ?? 0,
                      own.isEmpty ? 0 : Double(answers) / Double(own.count), own.isEmpty ? 0 : Double(answered) / Double(own.count))
        }
        guard let loudest = levels.values.max(), let typicalBright = median(Array(brights.values)) else { return [] }
        for s in levels.keys.sorted() {
            let r = raw[s]!
            out.append(Features(speaker: s, words: r.words, seconds: r.seconds, share: total > 0 ? r.seconds / total : 0,
                                level: levels[s]!, relativeLevel: levels[s]! - loudest,
                                relativeBrightness: typicalBright > 0 ? brights[s]! / typicalBright : 1,
                                tail: r.tail, answers: r.answers, answered: r.answered, named: named.contains(s)))
        }
        return out
    }
}
#endif
