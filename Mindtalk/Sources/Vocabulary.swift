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
    /// Added from a suggestion — the meeting it came from ("Veckomöte").
    var source: String?
    /// When it was added — for sorting by the newest.
    var added: Date?

    init(id: UUID = UUID(), word: String, heardAs: [String] = [], fixes: Int = 0, source: String? = nil) {
        self.id = id
        self.word = word
        self.heardAs = heardAs
        self.fixes = fixes
        self.source = source
        added = Date()
    }

    // Every field but the word may be missing — so adding a field later never
    // wipes anyone's list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        heardAs = try c.decodeIfPresent([String].self, forKey: .heardAs) ?? []
        fixes = try c.decodeIfPresent(Int.self, forKey: .fixes) ?? 0
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        added = try? c.decodeIfPresent(Date.self, forKey: .added)
    }
}

/// A word Mindtalk thinks you'd want on the list — a name you gave a speaker, or one
/// you corrected. Never added on its own: a wrong word would be spelled wrong everywhere.
struct VocabularySuggestion: Codable, Identifiable, Equatable {
    var id = UUID()
    let word: String
    var heardAs: [String] = []
    /// The meeting it came from.
    let source: String?
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
            // A word added by hand meanwhile isn't suggested any more.
            let pruned = Self.pruned(suggestions, against: entries)
            if pruned != suggestions { suggestions = pruned }
        }
    }
    /// Built once per change of the list, not per dictation.
    private var matcher: VocabularyMatcher

    /// Words to say yes or no to, newest first.
    @Published private(set) var suggestions: [VocabularySuggestion] = Vocabulary.loadSuggestions() {
        didSet { Settings.keep(try? JSONEncoder().encode(suggestions), forKey: "vocabularySuggestions") }
    }
    /// Said no to: not suggested again.
    private var declined = Set(UserDefaults.standard.stringArray(forKey: "vocabularyDeclined") ?? [])

    /// The last change you can take back ("Tog bort ”Mindact”") — with "Ångra" for a few seconds.
    @Published private(set) var toast: String?
    private var undoSnapshot: [VocabularyEntry]?
    private var toastTask: Task<Void, Never>?

    private static func loadSuggestions() -> [VocabularySuggestion] {
        UserDefaults.standard.data(forKey: "vocabularySuggestions")
            .flatMap { try? JSONDecoder().decode([VocabularySuggestion].self, from: $0) } ?? []
    }

    private static let key = "vocabulary"

    /// A read-only self-test (`--ask-test`): the list is read as it is, and nothing is
    /// written back, not even a repaired copy.
    nonisolated static var readOnly: Bool { CommandLine.arguments.contains("--ask-test") || Settings.previewing }

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
        // What's on disk couldn't be read in full: a copy is kept, and what could be
        // read is written back, so the copy isn't made again at every launch.
        var differsFromDisk = false
        if let data = defaults.data(forKey: Self.key) {
            if let saved = try? JSONDecoder().decode([Lenient].self, from: data) {
                // One entry that can't be read is skipped, not the whole list.
                loaded = saved.compactMap(\.entry)
                if loaded.count < saved.count {
                    if !Self.readOnly { defaults.set(data, forKey: Self.key + ".unreadable-\(Int(Date().timeIntervalSince1970))") }
                    differsFromDisk = true
                }
            } else {
                // Unreadable: keep a copy (one per time, never written over) rather than lose it.
                if !Self.readOnly { defaults.set(data, forKey: Self.key + ".unreadable-\(Int(Date().timeIntervalSince1970))") }
                loaded = []
                differsFromDisk = true
            }
        } else {
            loaded = [VocabularyEntry(word: "Mindtalk")]
        }
        // A variant twice on a word ("Claud", "Claud"), from before adding checked it: once.
        let tidied = loaded.map { e in var e = e; e.heardAs = Self.deduplicated(e.heardAs); return e }
        if tidied != loaded { loaded = tidied; differsFromDisk = true }
        matcher = Self.matcher(for: loaded)
        entries = loaded
        if differsFromDisk, !Self.readOnly { save() }
        // Suggestions kept from before a word was added by hand: only what's still new.
        let pruned = Self.pruned(suggestions, against: loaded)
        if pruned != suggestions {
            suggestions = pruned
            if !Self.readOnly { UserDefaults.standard.set(try? JSONEncoder().encode(pruned), forKey: "vocabularySuggestions") }
        }
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
        if Self.readOnly { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    // MARK: Editing

    /// "Mind Talk", "mind-talk" and "Mindtalk" are the same entry.
    static func key(_ word: String) -> String {
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
        let (updated, id) = Self.adding(word: word, heardAs: heardAs, to: entries)
        if updated != entries { entries = updated }
        return id
    }

    /// The list with a word added (or merged into the entry already there) — pure, so it
    /// can be tested without the store. A word already on the list keeps the spelling
    /// it has (rename changes it); only new variants are taken. A variant that is
    /// another entry's word is left out: it would rewrite that word everywhere.
    static func adding(word: String, heardAs: String, to entries: [VocabularyEntry]) -> (entries: [VocabularyEntry], id: UUID?) {
        var entries = entries
        let word = tidy(word)
        guard isValidWord(word) else { return (entries, nil) }
        let variants = deduplicated(heardAs.split(separator: ",")
            .map { tidy(String($0)) }
            .filter { isValidWord($0) && key($0) != key(word) && !isOtherWord($0, than: word, in: entries) })
        // The word itself is no longer a mishearing of another entry ("Mathilda" heard as
        // "Matilda", then the other way round, would swap the two in every text).
        for i in entries.indices where key(entries[i].word) != key(word)
            && entries[i].heardAs.contains(where: { key($0) == key(word) }) {
            entries[i].heardAs.removeAll { key($0) == key(word) }
        }
        if let i = entries.firstIndex(where: { key($0.word) == key(word) }) {
            for v in variants where !entries[i].heardAs.contains(where: { key($0) == key(v) }) {
                entries[i].heardAs.append(v)
            }
            return (entries, entries[i].id)
        }
        let entry = VocabularyEntry(word: word, heardAs: variants)
        entries.insert(entry, at: 0)
        return (entries, entry.id)
    }

    /// Each variant once, whatever its case or spacing ("Claud", "claud"): the first
    /// one kept, in the order they came.
    static func deduplicated(_ heardAs: [String]) -> [String] {
        var seen = Set<String>()
        return heardAs.filter { seen.insert(key($0)).inserted }
    }

    /// `variant` is the word of some other entry than `word`'s.
    static func isOtherWord(_ variant: String, than word: String, in entries: [VocabularyEntry]) -> Bool {
        entries.contains { key($0.word) == key(variant) && key($0.word) != key(word) }
    }

    /// False when the variant can't be added: not a word, the entry's own word, or
    /// another entry's word.
    @discardableResult
    func addVariant(_ variant: String, to entry: VocabularyEntry) -> Bool {
        let v = Self.tidy(variant)
        guard Self.isValidWord(v), let i = entries.firstIndex(where: { $0.id == entry.id }),
              Self.key(v) != Self.key(entries[i].word),
              !Self.isOtherWord(v, than: entries[i].word, in: entries) else { return false }
        guard !entries[i].heardAs.contains(where: { Self.key($0) == Self.key(v) }) else { return true }
        entries[i].heardAs.append(v)
        return true
    }

    /// Fixes a typo in a word, keeping its variants and count.
    func rename(_ entry: VocabularyEntry, to word: String) {
        let word = Self.tidy(word)
        guard Self.isValidWord(word), let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        offerUndo(String(localized: "Ändrade till ”\(word)”"), before: entries)
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

    /// Something just changed that "Ångra" (or ⌘Z) can take back.
    private func offerUndo(_ label: String, before: [VocabularyEntry]) {
        undoSnapshot = before
        toast = label
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.undoSnapshot = nil
        }
    }

    /// "Ångra" on the toast. The same change is also on ⌘Z's undo stack: taken off,
    /// so it can't be put back a second time.
    func undoLast() {
        guard let before = undoSnapshot else { return }
        entries = before
        undoSnapshot = nil
        toast = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    /// The window's undo manager, from the last removal — for taking the toast's undo off it.
    private weak var undoManager: UndoManager?

    // MARK: Suggestions

    /// A word worth suggesting: not on the list, not said no to, not an ordinary word.
    /// A word already on the list only with a new way it was heard: just that is offered.
    func suggest(_ word: String, heardAs: String? = nil, from source: String?) {
        let word = Self.tidy(word)
        guard Self.isValidWord(word), word.filter(\.isLetter).count >= 3,
              !word.contains(where: \.isNumber),
              !suggestions.contains(where: { Self.key($0.word) == Self.key(word) }),
              !declined.contains(Self.key(word)),
              !Self.isDictionaryWord(word.lowercased()) || heardAs != nil else { return }
        let variants = heardAs.map { [Self.tidy($0)] }?.filter { Self.isValidWord($0) && Self.key($0) != Self.key(word) } ?? []
        let suggestion = VocabularySuggestion(word: word, heardAs: variants, source: source)
        // Nothing new for a word on the list: no suggestion.
        guard let kept = Self.pruned([suggestion], against: entries).first else { return }
        suggestions.insert(kept, at: 0)
        if suggestions.count > 20 { suggestions.removeLast(suggestions.count - 20) }
    }

    /// The word of the list a suggestion is about, when it's on the list already.
    func existing(_ suggestion: VocabularySuggestion) -> VocabularyEntry? {
        entries.first { Self.key($0.word) == Self.key(suggestion.word) }
    }

    /// Suggestions without what the list already has: a word on it is kept only for a
    /// way it was heard that it doesn't have yet (in its spelling on the list), and
    /// otherwise dropped. Pure, for the self-test.
    static func pruned(_ suggestions: [VocabularySuggestion], against entries: [VocabularyEntry]) -> [VocabularySuggestion] {
        var seen = Set<String>()
        return suggestions.compactMap { s in
            guard seen.insert(key(s.word)).inserted else { return nil }
            guard let entry = entries.first(where: { key($0.word) == key(s.word) }) else { return s }
            let new = deduplicated(s.heardAs.filter { v in
                key(v) != key(entry.word) && !entry.heardAs.contains { key($0) == key(v) }
                    && !isOtherWord(v, than: entry.word, in: entries)
            })
            guard !new.isEmpty else { return nil }
            var kept = s
            kept.heardAs = new
            return kept
        }
    }

    func accept(_ suggestion: VocabularySuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        if let id = add(word: suggestion.word, heardAs: suggestion.heardAs.joined(separator: ", ")),
           let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].source = suggestion.source
        }
    }

    func decline(_ suggestion: VocabularySuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        declined.insert(Self.key(suggestion.word))
        Settings.keep(Array(declined), forKey: "vocabularyDeclined")
    }

    // MARK: Import and export

    /// One word a line: "Mindact; min dakt, mind act".
    func exportText() -> String {
        entries.map { e in e.heardAs.isEmpty ? e.word : e.word + "; " + e.heardAs.joined(separator: ", ") }
            .joined(separator: "\n") + "\n"
    }

    /// The same format back in; returns how many words were added or got new variants.
    @discardableResult
    func importText(_ text: String) -> Int {
        let (updated, n) = Self.importing(text, into: entries)
        if updated != entries { entries = updated }
        return n
    }

    /// Pure, for the self-test: the list after the import, and how many lines changed it.
    static func importing(_ text: String, into entries: [VocabularyEntry]) -> (entries: [VocabularyEntry], changed: Int) {
        var entries = entries
        var n = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ";", maxSplits: 1).map { String($0) }
            guard let word = parts.first, isValidWord(tidy(word)) else { continue }
            let (updated, _) = adding(word: word, heardAs: parts.count > 1 ? parts[1] : "", to: entries)
            // A word already there, with nothing new to it, isn't counted.
            if updated != entries { n += 1 }
            entries = updated
        }
        return (entries, n)
    }

    /// Removes an entry; "Ångra" or ⌘Z puts it back where it was.
    func remove(_ entry: VocabularyEntry, undo: UndoManager?) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        offerUndo(String(localized: "Tog bort ”\(entry.word)”"), before: entries)
        let removed = entries.remove(at: i)
        undoManager = undo
        undo?.registerUndo(withTarget: self) { vocabulary in
            MainActor.assumeIsolated {
                vocabulary.entries = Self.restoring(removed, at: i, into: vocabulary.entries)
            }
        }
        undo?.setActionName(String(localized: "Ta bort \(removed.word)"))
    }

    /// The entry back where it was — unless it's already there ("Ångra" on the toast
    /// first, then ⌘Z: never twice).
    static func restoring(_ removed: VocabularyEntry, at i: Int, into entries: [VocabularyEntry]) -> [VocabularyEntry] {
        guard !entries.contains(where: { $0.id == removed.id || key($0.word) == key(removed.word) }) else { return entries }
        var entries = entries
        entries.insert(removed, at: min(i, entries.count))
        return entries
    }

    func removeVariant(_ variant: String, from entry: VocabularyEntry, undo: UndoManager?) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }),
              let v = entries[i].heardAs.firstIndex(of: variant) else { return }
        offerUndo(String(localized: "Tog bort ”\(variant)”"), before: entries)
        entries[i].heardAs.remove(at: v)
        let id = entry.id
        undoManager = undo
        undo?.registerUndo(withTarget: self) { vocabulary in
            MainActor.assumeIsolated {
                vocabulary.entries = Self.restoring(variant: variant, at: v, of: id, into: vocabulary.entries)
            }
        }
        undo?.setActionName(String(localized: "Ta bort \(variant)"))
    }

    /// The variant back on its entry — unless it's already there.
    static func restoring(variant: String, at v: Int, of id: UUID, into entries: [VocabularyEntry]) -> [VocabularyEntry] {
        guard let i = entries.firstIndex(where: { $0.id == id }),
              !entries[i].heardAs.contains(where: { key($0) == key(variant) }) else { return entries }
        var entries = entries
        entries[i].heardAs.insert(variant, at: min(v, entries[i].heardAs.count))
        return entries
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
        startListener()
    }

    /// "Ladda ned" on the word list.
    func allowListener() {
        Settings.listenerAllowed = true
        prepareListener()
    }

    /// The introduction and Modeller: fetched now, before there are words of your own —
    /// it's small, and the words you add later are heard right away. "Försök igen"
    /// after a download that failed, too.
    func fetchListener() {
        Settings.listenerAllowed = true
        guard !VocabularyBoost.isInstalled else { return }
        startListener()
    }

    /// "Ladda ned igen": the listener is here but wouldn't start — fetched afresh.
    func refetchListener() {
        Settings.listenerAllowed = true
        Task {
            await VocabularyBoost.shared.remove()
            startListener()
        }
    }

    /// "Ta bort" on Ordlista: the folder goes, and it isn't fetched again until you say so.
    func removeListener() {
        Settings.listenerAllowed = false
        Task { await VocabularyBoost.shared.remove() }
    }

    /// Room for the download, and for preparing it for this Mac, before anything is fetched.
    private func startListener() {
        if !VocabularyBoost.isInstalled {
            let bytes = VocabularyBoost.bytes
            guard BetterNotes.freeBytes > bytes * 2 + 500_000_000 else {
                VocabularyBoostStatus.shared.set(.failed(String(localized: "Det behövs drygt \(DiskSize.text(bytes * 2)) ledigt på disken.")))
                return
            }
        }
        Task { await VocabularyBoost.shared.prepare() }
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

    /// Counts what the list fixes in a text without returning it — a meeting's words
    /// are fixed as they're shown (reapply), so the count is taken once, when the
    /// meeting is done.
    func noteFixes(in text: String) {
        let counts = matcher.apply(to: text, isWord: Self.isDictionaryWord).counts
        guard !counts.isEmpty else { return }
        var updated = entries
        for (i, n) in counts where updated.indices.contains(i) { updated[i].fixes += n }
        entries = updated
    }

    /// For the page's preview: the fixed text and where the fixes are — after the
    /// same tidying a dictation gets first, so the preview reads as the text would.
    func preview(_ text: String) -> (text: String, ranges: [NSRange]) {
        let cleaned = TextCleanup.apply(text, fillers: Settings.removeFillers, commands: false)
        let result = matcher.apply(to: cleaned, isWord: Self.isDictionaryWord)
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
