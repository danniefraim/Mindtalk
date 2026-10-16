import AppKit

// MARK: - Ordlista
//
// Names and words Mindtalk should spell your way — fixed in the text after
// transcription. How matching works is in VocabularyMatcher.swift.

struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var heardAs: [String] = []
    /// How many times it has corrected something.
    var fixes = 0

    init(id: UUID = UUID(), word: String, heardAs: [String] = [], fixes: Int = 0) {
        self.id = id
        self.word = word
        self.heardAs = heardAs
        self.fixes = fixes
    }

    // Every field but the word may be missing — so adding a field later never
    // wipes anyone's list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        heardAs = try c.decodeIfPresent([String].self, forKey: .heardAs) ?? []
        fixes = try c.decodeIfPresent(Int.self, forKey: .fixes) ?? 0
    }
}

@MainActor
final class Vocabulary: ObservableObject {
    static let shared = Vocabulary()

    @Published private(set) var entries: [VocabularyEntry] {
        didSet {
            save()
            if entries.map(\.word) != oldValue.map(\.word) || entries.map(\.heardAs) != oldValue.map(\.heardAs) {
                matcher = Self.matcher(for: entries)
                MeetingText.forget()
            }
            if !Self.hasOwnWords(oldValue), Self.hasOwnWords(entries) { prepareListener() }
        }
    }
    /// Built once per change of the list, not per dictation.
    private var matcher: VocabularyMatcher

    private static let key = "vocabulary"

    private init() {
        let defaults = UserDefaults.standard
        var loaded: [VocabularyEntry]
        #if DEBUG
        if Demo.on {   // screenshots: example words, yours untouched
            loaded = Demo.vocabulary
            matcher = Self.matcher(for: loaded)
            entries = loaded
            return
        }
        #endif
        if let data = defaults.data(forKey: Self.key) {
            if let saved = try? JSONDecoder().decode([Lenient].self, from: data) {
                // One entry that can't be read is skipped, not the whole list.
                loaded = saved.compactMap(\.entry)
                if loaded.count < saved.count { defaults.set(data, forKey: Self.key + ".unreadable-\(Int(Date().timeIntervalSince1970))") }
            } else {
                // Unreadable: keep a copy (one per time, never written over) rather than lose it.
                defaults.set(data, forKey: Self.key + ".unreadable-\(Int(Date().timeIntervalSince1970))")
                loaded = []
            }
        } else {
            loaded = [VocabularyEntry(word: "Mindtalk")]
        }
        matcher = Self.matcher(for: loaded)
        entries = loaded
    }

    /// An entry, or nothing if it can't be read.
    private struct Lenient: Decodable {
        let entry: VocabularyEntry?
        init(from decoder: Decoder) throws { entry = try? VocabularyEntry(from: decoder) }
    }

    private static func matcher(for entries: [VocabularyEntry]) -> VocabularyMatcher {
        VocabularyMatcher(entries: entries.map { (word: $0.word, heardAs: $0.heardAs) })
    }

    private func save() {
        #if DEBUG
        if Demo.on { return }
        #endif
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    // MARK: Editing

    /// "Mind Talk", "mind-talk" and "Mindtalk" are the same entry.
    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isValidWord(_ word: String) -> Bool {
        word.contains(where: { $0.isLetter || $0.isNumber }) && word.count <= 60
    }

    /// As typed or pasted: å/ä/ö in one form (a PDF or Finder may give "a" + ring),
    /// any run of spaces, tabs or no-break spaces as one space, curly apostrophes straight.
    static func tidy(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Adds a word, or more "heard as" variants to the same word. `heardAs` is comma-separated.
    /// Returns the entry's id (to highlight it).
    @discardableResult
    func add(word: String, heardAs: String) -> UUID? {
        let word = Self.tidy(word)
        guard Self.isValidWord(word) else { return nil }
        let variants = heardAs.split(separator: ",")
            .map { Self.tidy(String($0)) }
            .filter { Self.isValidWord($0) && Self.key($0) != Self.key(word) }
        // The word itself is no longer a mishearing of another entry ("Mathilda" heard as
        // "Matilda", then the other way round, would swap the two in every text).
        for i in entries.indices where Self.key(entries[i].word) != Self.key(word)
            && entries[i].heardAs.contains(where: { Self.key($0) == Self.key(word) }) {
            entries[i].heardAs.removeAll { Self.key($0) == Self.key(word) }
        }
        if let i = entries.firstIndex(where: { Self.key($0.word) == Self.key(word) }) {
            entries[i].word = word
            for v in variants where !entries[i].heardAs.contains(where: { Self.key($0) == Self.key(v) }) {
                entries[i].heardAs.append(v)
            }
            return entries[i].id
        }
        let entry = VocabularyEntry(word: word, heardAs: variants)
        entries.insert(entry, at: 0)
        return entry.id
    }

    func addVariant(_ variant: String, to entry: VocabularyEntry) {
        let v = Self.tidy(variant)
        guard Self.isValidWord(v), let i = entries.firstIndex(where: { $0.id == entry.id }),
              Self.key(v) != Self.key(entries[i].word),
              !entries[i].heardAs.contains(where: { Self.key($0) == Self.key(v) }) else { return }
        entries[i].heardAs.append(v)
    }

    /// Fixes a typo in a word, keeping its variants and count.
    func rename(_ entry: VocabularyEntry, to word: String) {
        let word = Self.tidy(word)
        guard Self.isValidWord(word), let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        // Renaming onto another entry merges the two.
        if let j = entries.firstIndex(where: { $0.id != entry.id && Self.key($0.word) == Self.key(word) }) {
            for v in entries[i].heardAs where !entries[j].heardAs.contains(where: { Self.key($0) == Self.key(v) }) {
                entries[j].heardAs.append(v)
            }
            entries[j].fixes += entries[i].fixes
            entries[j].word = word
            entries.remove(at: i)
        } else {
            entries[i].word = word
        }
    }

    /// Removes an entry; ⌘Z puts it back where it was.
    func remove(_ entry: VocabularyEntry, undo: UndoManager?) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let removed = entries.remove(at: i)
        undo?.registerUndo(withTarget: self) { vocabulary in
            MainActor.assumeIsolated {
                let at = min(i, vocabulary.entries.count)
                vocabulary.entries.insert(removed, at: at)
            }
        }
        undo?.setActionName(String(localized: "Ta bort \(removed.word)"))
    }

    func removeVariant(_ variant: String, from entry: VocabularyEntry, undo: UndoManager?) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }),
              let v = entries[i].heardAs.firstIndex(of: variant) else { return }
        entries[i].heardAs.remove(at: v)
        let id = entry.id
        undo?.registerUndo(withTarget: self) { vocabulary in
            MainActor.assumeIsolated {
                guard let i = vocabulary.entries.firstIndex(where: { $0.id == id }) else { return }
                vocabulary.entries[i].heardAs.insert(variant, at: min(v, vocabulary.entries[i].heardAs.count))
            }
        }
        undo?.setActionName(String(localized: "Ta bort \(variant)"))
    }

    // MARK: Fixing text

    /// Terms the speech model was made to hear (VocabularyBoost): counted as fixes too.
    func noteHeard(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        var updated = entries
        for term in terms {
            if let i = updated.firstIndex(where: { Self.key($0.word) == Self.key(term) }) { updated[i].fixes += 1 }
        }
        entries = updated
    }

    /// A word you added yourself — the preset "Mindtalk" is fixed by the rules
    /// above and doesn't need the listener.
    private static func hasOwnWords(_ entries: [VocabularyEntry]) -> Bool {
        entries.contains { key($0.word) != "mindtalk" }
    }

    /// With your own words on the list, the listener is fetched and loaded ahead
    /// of need — never during a dictation.
    func prepareListener() {
        guard Self.hasOwnWords(entries) else { return }
        // 100 MB: fetched when you said yes (or already here) — never on its own.
        guard VocabularyBoost.isInstalled || Settings.listenerAllowed else { return }
        Task { await VocabularyBoost.shared.prepare() }
    }

    /// "Ladda ned" on the word list.
    func allowListener() {
        Settings.listenerAllowed = true
        prepareListener()
    }

    var hasOwnWords: Bool { Self.hasOwnWords(entries) }

    /// The polish may split a name ("Mindact" → "Mind act") in a way the list can't
    /// join again: then the text before the polish is kept. True if every word on the
    /// list that was in `before` is still whole in `after`.
    func keepsWords(of before: String, in after: String) -> Bool {
        func count(_ word: String, in text: String) -> Int {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
            return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }
        return entries.allSatisfy { count($0.word, in: after) >= count($0.word, in: before) }
    }

    /// Fixes the text and counts what it fixed.
    func apply(_ text: String) -> String {
        let result = matcher.apply(to: text, isWord: Self.isDictionaryWord)
        if !result.counts.isEmpty {
            var updated = entries
            for (i, n) in result.counts where updated.indices.contains(i) { updated[i].fixes += n }
            entries = updated
        }
        return result.text
    }

    /// Fixes the text again without counting — after the polish, which may
    /// have undone a spelling.
    func reapply(_ text: String) -> String {
        matcher.apply(to: text, isWord: Self.isDictionaryWord).text
    }

    /// For the page's preview: the fixed text and where the fixes are.
    func preview(_ text: String) -> (text: String, ranges: [NSRange]) {
        let result = matcher.apply(to: text, isWord: Self.isDictionaryWord)
        return (result.text, result.ranges)
    }

    // MARK: Dictionary

    private static var dictionaryCache: [String: Bool] = [:]

    /// An ordinary Swedish or English word — then it isn't recased or "fixed".
    static func isDictionaryWord(_ word: String) -> Bool {
        if let known = dictionaryCache[word] { return known }
        let checker = NSSpellChecker.shared
        let known = ["sv", "en"].contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        if dictionaryCache.count > 5_000 { dictionaryCache.removeAll() }
        dictionaryCache[word] = known
        return known
    }
}
