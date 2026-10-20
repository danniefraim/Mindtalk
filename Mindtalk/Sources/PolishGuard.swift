import Foundation

// MARK: - The AI polish guard
//
// The on-device model may tidy a dictation, never change what was said. Its
// answer is accepted only if, word by word, it can be read back onto the
// original with nothing but:
//   • words kept (any case),
//   • words split or joined ("köpmjöl" → "köp mjöl"),
//   • deletions of hesitation sounds, words said twice, spoken punctuation
//     ("punkt", "comma") where its symbol now stands, or what a self-correction
//     (followed by the correction) replaces ("tisdag, nej jag
//     menar onsdag" → "onsdag").
// Nothing may be added, no question mark may go, and a negation (inte, aldrig,
// not, don't…) is never dropped — "jag godkänner inte" can't become "jag godkänner". Only ordinary
// punctuation may appear; control and bidi characters are refused.
// Self-contained, so it can be tested on its own.

enum PolishGuard {
    static func accepts(_ polished: String, as original: String) -> Bool {
        guard onlyOrdinaryCharacters(polished), !gluesWords(polished, original) else { return false }
        // A question stays a question: "Blir det fel? Eller är det jag?" can't become one statement.
        guard polished.filter({ $0 == "?" }).count >= original.filter({ $0 == "?" }).count else { return false }
        let before = words(original), (after, gaps) = wordsAndGaps(polished)
        guard !after.isEmpty, Double(after.count) >= Double(before.count) * 0.5 else { return false }

        var i = 0, j = 0
        while j < after.count {
            if i < before.count, let step = match(before, i, after, j) {
                i += step.before; j += step.after
                continue
            }
            // Not the next original word: the words up to its next occurrence were dropped
            // — right where the polished text has `gaps[j]` between its words.
            guard let k = (i..<min(before.count, i + 9)).first(where: { match(before, $0, after, j) != nil }),
                  deletable(before, i..<k, gap: gaps[j]) else { return false }
            i = k
        }
        return i == before.count || deletable(before, i..<before.count, gap: gaps[after.count])
    }

    // MARK: Words

    static func words(_ text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let pattern = #"[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = normalized as NSString
        return regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// The words, and what stands between them: `gaps[j]` is the text before word j,
    /// the last one what follows the last word.
    static func wordsAndGaps(_ text: String) -> (words: [String], gaps: [String]) {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let pattern = #"[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], [""]) }
        let ns = normalized as NSString
        var words: [String] = [], gaps: [String] = []
        var end = 0
        for m in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            gaps.append(ns.substring(with: NSRange(location: end, length: m.range.location - end)))
            words.append(ns.substring(with: m.range))
            end = m.range.location + m.range.length
        }
        gaps.append(ns.substring(from: end))
        return (words, gaps)
    }

    /// The same word, its form corrected ("tryck" → "trycker"), or one split into
    /// two/three, or two/three joined into one.
    private static func match(_ before: [String], _ i: Int, _ after: [String], _ j: Int) -> (before: Int, after: Int)? {
        if before[i] == after[j] { return (1, 1) }
        if sameWordOtherForm(before[i], after[j]) { return (1, 1) }
        // Numbers are never joined or split: "1 2" isn't "12".
        if before[i].contains(where: \.isNumber) || after[j].contains(where: \.isNumber) { return nil }
        for n in 2...3 {
            if j + n <= after.count, after[j..<j + n].joined() == before[i] { return (1, n) }
            if i + n <= before.count, before[i..<i + n].joined() == after[j] { return (n, 1) }
        }
        return nil
    }

    /// One is the other plus an ending of at most three letters, the shorter at least
    /// four letters long — a corrected form ("tryck"/"trycker", "hund"/"hunden"),
    /// never another word. Never for numbers ("tjugo"/"tjugofem", "1000"/"10000") or a
    /// negation, nor a past tense made passive ("skickade"/"skickades": who did it changes).
    static func sameWordOtherForm(_ a: String, _ b: String) -> Bool {
        if a.contains(where: \.isNumber) || b.contains(where: \.isNumber) { return false }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 4, long.count - short.count <= 3, long.hasPrefix(short) else { return false }
        if negations.contains(short) || negations.contains(long) { return false }
        if long == short + "s", short.hasSuffix("de") || short.hasSuffix("te") { return false }
        return !numberWords.contains { short.hasPrefix($0) || long.hasPrefix($0) }
    }

    /// Beginnings of number words (four letters or more — shorter ones never pass the length rule).
    private static let numberWords = ["noll", "fyra", "åtta", "elva", "tolv", "tret", "fjor", "femt", "sext", "sjut",
                                      "arto", "nitt", "tjug", "fyrt", "åtti", "hundra", "tuse", "milj",
                                      "zero", "four", "five", "seve", "eigh", "nine", "elev", "twel", "thir", "fift",
                                      "twen", "fort", "hundred", "thou", "mill"]

    // MARK: What may be dropped

    private static let fillers: Set<String> = ["eh", "ehm", "eeh", "öh", "öhm", "äh", "ähm", "um", "umm", "uh", "uhm",
                                               "hm", "hmm", "mm", "erm"]
    /// Punctuation said as a word, and the symbol it becomes. It may go only where
    /// the symbol now stands: "Jag kan inte komma i morgon" is not "Jag kan inte, i morgon".
    private static let spokenPunctuation: [String: String] = [
        "punkt": ".", "komma": ",", "frågetecken": "?", "utropstecken": "!", "kolon": ":", "semikolon": ";",
        "tankstreck": "-–—", "period": ".", "comma": ",", "colon": ":", "semicolon": ";", "dash": "-–—",
    ]
    /// Said in two words ("question mark", "full stop"): both go, the symbol stands.
    private static let spokenPunctuationPairs: [[String]: String] = [
        ["question", "mark"]: "?", ["exclamation", "mark"]: "!", ["exclamation", "point"]: "!", ["full", "stop"]: ".",
    ]
    /// Never dropped: they flip the meaning.
    private static let negations: Set<String> = ["inte", "ej", "icke", "aldrig", "ingen", "inget", "inga", "ingenting",
                                                 "not", "never", "nothing", "nobody", "none", "neither", "nor", "cannot"]
    /// "nej"/"no" may go only as part of a correction ("nej jag menar").
    private static let softNo: Set<String> = ["nej", "no", "nä", "nope"]
    private static let correctionCues: [[String]] = [["jag", "menar"], ["menar", "jag"], ["förlåt"], ["ursäkta"],
                                                     ["rättelse"], ["i", "mean"], ["sorry"], ["correction"],
                                                     ["or", "rather"], ["eller", "snarare"]]

    private static func deletable(_ before: [String], _ run: Range<Int>, gap: String) -> Bool {
        guard !run.isEmpty else { return true }
        let dropped = Array(before[run])
        if dropped.contains(where: { negations.contains($0) || $0.hasSuffix("n't") }) { return false }
        // A self-correction: what's replaced and the cue go, the correction stays —
        // "tisdag, nej jag menar | onsdag". The cue must end the dropped run, or be
        // followed only by the words just before the run said again ("till Per,
        // förlåt, till | Anna"). And a correction must follow it: "säg förlåt" at the
        // end of the line is what was said, not a correction.
        if dropped.count <= 8, run.upperBound < before.count,
           correctionCues.contains(where: { cue in endsCorrection(dropped, cue, before, run) }) { return true }
        // Spoken punctuation, each one matched by its symbol where the words were.
        var spoken = Set<Int>()
        for idx in run {
            if let symbol = spokenPunctuation[before[idx]], gap.contains(where: { symbol.contains($0) }) {
                spoken.insert(idx)
            } else if idx + 1 < run.upperBound, let symbol = spokenPunctuationPairs[[before[idx], before[idx + 1]]],
                      gap.contains(where: { symbol.contains($0) }) {
                spoken.insert(idx); spoken.insert(idx + 1)
            }
        }
        return run.allSatisfy { idx in
            let w = before[idx]
            if fillers.contains(w) || spoken.contains(idx) { return true }
            // Said twice in a row — one copy may go, never both.
            return (idx > 0 && !run.contains(idx - 1) && before[idx - 1] == w)
                || (idx + 1 < before.count && !run.contains(idx + 1) && before[idx + 1] == w)
        }
    }

    private static func endsCorrection(_ dropped: [String], _ cue: [String], _ before: [String], _ run: Range<Int>) -> Bool {
        guard dropped.count >= cue.count else { return false }
        for start in 0...(dropped.count - cue.count) where Array(dropped[start..<start + cue.count]) == cue {
            // Something said before the cue is what it replaces: "Ursäkta, kan du…" or
            // "Nej, jag menar att…" at the start replaces nothing.
            guard dropped[..<start].contains(where: { !softNo.contains($0) && !fillers.contains($0) }) else { continue }
            let after = Array(dropped[(start + cue.count)...])
            if after.isEmpty { return true }
            // What follows the cue repeats the words right before the run.
            let lead = run.lowerBound - after.count
            if lead >= 0, Array(before[lead..<run.lowerBound]) == after { return true }
        }
        return false
    }

    /// Punctuation squeezed between two letters ("mind.act") that wasn't in the original.
    private static func gluesWords(_ polished: String, _ original: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\p{L}[.,;:!?/&+@#*]\p{L}"#) else { return false }
        func count(_ s: String) -> Int { regex.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) }
        return count(polished) > count(original)
    }

    // MARK: Characters

    private static let allowedPunctuation = CharacterSet(charactersIn: ".,;:!?'\"’‘“”«»()-–—…%/&+@#*")

    private static func onlyOrdinaryCharacters(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { c in
            if c == "\n" || c == " " { return true }
            if CharacterSet.letters.contains(c) || CharacterSet.decimalDigits.contains(c) { return true }
            if CharacterSet.nonBaseCharacters.contains(c) { return true }      // accents
            return allowedPunctuation.contains(c)
        }
    }
}
