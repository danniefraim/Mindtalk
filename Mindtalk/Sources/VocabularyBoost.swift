import AVFoundation
import FluidAudio
import Foundation
import os

// MARK: - The Ordlista, heard
//
// Your words are fixed in the text afterwards (Vocabulary.swift) — but a name
// the speech model has never seen often comes out as something that merely
// sounds alike: "Mindakt", "Whisper Flow", "Kelly". Here the model is given the
// list too. After a dictation, when a word in the text resembles one of your
// terms, a small second model (Parakeet CTC 110M, ~100 MB, downloaded once)
// listens to the audio for the term, and the text is corrected where the term
// is clearly what was said — the "phrase boosting" Klang describes for
// Pianissimo, through FluidAudio.
//
// Only a resemblance in the text calls for a listen, so most dictations cost
// nothing; one with a name in it takes about 0.4 s longer. Nothing is replaced
// unless the word also looks like the term (two thirds of its letters), and of
// a longer phrase only the part that matches best — measured so that no
// ordinary word was ever swapped for a name.

actor VocabularyBoost {
    static let shared = VocabularyBoost()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Ordlista")

    /// The listener's folder, beside the speech models.
    nonisolated static var directory: URL { SpeechModel.rootDirectory.appendingPathComponent("parakeet-ctc-110m-coreml") }
    nonisolated static var isInstalled: Bool { CtcModels.modelsExist(at: directory) }
    static let sizeText = "100 MB"
    static let bytes: Int64 = 100_000_000
    /// The commit of FluidInference/parakeet-ctc-110m-coreml that's fetched (`ModelPins`).
    nonisolated static let revision = "accdafd8cf8a2ff1cabe3c11e54416b405d409aa"
    nonisolated static let repo = "FluidInference/parakeet-ctc-110m-coreml"

    private var models: CtcModels?
    private var ready: (terms: [String], spotter: CtcKeywordSpotter, rescorer: VocabularyRescorer, vocabulary: CustomVocabularyContext)?
    private var downloading = false

    /// The listener, downloaded on first need and loaded once.
    private func load() async throws -> CtcModels {
        if let models { return models }
        let wasInstalled = Self.isInstalled
        if !wasInstalled {
            guard !downloading else { throw ListenerError.busy }
            downloading = true
            await VocabularyBoostStatus.shared.set(.downloading)
        }
        defer { downloading = false }
        do {
            let loaded = try await CtcModels.downloadAndLoad(to: Self.directory, variant: .ctc110m)
            models = loaded
            await VocabularyBoostStatus.shared.set(.ready)
            if !wasInstalled { Self.log.info("listener downloaded") }
            return loaded
        } catch {
            Self.log.error("listener: \(error.localizedDescription, privacy: .public)")
            // Said plainly: a download that failed, or a listener here that wouldn't start.
            let why = await MainActor.run {
                Self.isInstalled ? String(localized: "Lyssnaren startade inte.") : Dictation.plainWords(for: error)
            }
            await VocabularyBoostStatus.shared.set(.failed(why))
            throw error
        }
    }

    /// Lets go of the listener and deletes its folder ("Ta bort" on Ordlista, or
    /// before fetching it afresh).
    func remove() async {
        models = nil
        ready = nil
        try? FileManager.default.removeItem(at: Self.directory)
        await VocabularyBoostStatus.shared.set(.missing)
    }

    enum ListenerError: Error { case busy, notLoaded }

    /// Makes sure the listener is on disk and loaded — called when the list has words.
    /// The speech model first: both are prepared for the Neural Engine by the same
    /// one-at-a-time service in macOS, and nothing can be dictated before the speech
    /// model is ready (the first time on a Mac that takes minutes).
    func prepare() async {
        if !Self.isInstalled { await VocabularyBoostStatus.shared.set(.downloading) }
        for _ in 0..<1800 {
            let busy = await MainActor.run { () -> Bool in
                switch Dictation.shared.model {
                case .loading, .downloading: return true
                default: return false
                }
            }
            guard busy else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        _ = try? await load()
    }

    /// Terms worth listening for: your words, three letters or more.
    nonisolated static func terms(from words: [String]) -> [String] {
        words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.filter(\.isLetter).count >= 3 }
    }

    /// Does the text have a word that resembles one of the terms, written differently?
    /// Only then is the audio worth a listen.
    nonisolated static func worthListening(_ text: String, terms: [String]) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        for term in terms {
            let t = key(term)
            let n = max(1, term.split(separator: " ").count)
            for i in words.indices {
                for j in i..<min(words.count, i + n + 1) {
                    let k = key(words[i...j].joined())
                    if k != t, alike(k, t) >= 0.6 { return true }
                }
            }
        }
        return false
    }

    /// The text with your terms where the audio says they were said.
    /// Returns the text and the terms that were put in.
    func refine(_ text: String, timings: [TokenTiming], audio: [Float], terms: [String]) async -> (text: String, fixed: [String]) {
        guard !terms.isEmpty, !timings.isEmpty, Self.worthListening(text, terms: terms) else { return (text, []) }
        do {
            let (spotter, rescorer, vocabulary) = try await session(for: terms)
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: vocabulary, minScore: nil)
            guard !spot.logProbs.isEmpty else { return (text, []) }
            let evidence = rescorer.ctcTokenEvaluateCandidates(transcript: text, tokenTimings: timings,
                                                                logProbs: spot.logProbs, frameDuration: spot.frameDuration)
            let edits = Self.gate(evidence)
            // Nothing to change: the text as it was, its spacing too.
            guard !edits.isEmpty else { return (text, []) }
            Self.log.info("ordlistan hörd: \(edits.count) byten")
            var words = evidence.baseWords
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                words.replaceSubrange(edit.range, with: [edit.text])
            }
            return (words.joined(separator: " "), edits.map(\.term))
        } catch {
            // Boosting must never cost a dictation: the text as the model wrote it.
            Self.log.error("ordlistan: \(error.localizedDescription, privacy: .public)")
            return (text, [])
        }
    }

    /// A meeting's words, with your terms where the audio says they were said. Only
    /// the stretches around a word that resembles a term are listened to — a few
    /// seconds each, not the whole meeting.
    func refine(words: [MeetingWord], audio url: URL, terms: [String]) async -> (words: [MeetingWord], fixed: [String]) {
        guard !terms.isEmpty, !words.isEmpty else { return (words, []) }
        // Where to listen: around every word that resembles a term, stretches merged.
        var stretches: [Range<Int>] = []
        let longest = terms.map { $0.split(separator: " ").count }.max() ?? 1
        var i = 0
        while i < words.count {
            var hit = false
            for n in 1...(longest + 1) where i + n <= words.count {
                let k = Self.key(words[i..<(i + n)].map(\.text).joined())
                if terms.contains(where: { let t = Self.key($0); return k != t && Self.alike(k, t) >= 0.6 }) { hit = true; break }
            }
            if hit {
                let from = max(0, i - 6), to = min(words.count, i + longest + 6)
                if let last = stretches.last, last.upperBound >= from { stretches[stretches.count - 1] = last.lowerBound..<to }
                else { stretches.append(from..<to) }
            }
            i += 1
        }
        guard !stretches.isEmpty, let file = try? AVAudioFile(forReading: url) else { return (words, []) }
        // A meeting's final pass can wait for the listener to load (a dictation never
        // does) — but never for a download: not on disk, the text stays as written.
        if models == nil, Self.isInstalled { _ = try? await load() }
        guard models != nil else { return (words, []) }
        let rate = file.processingFormat.sampleRate
        var out = words
        var fixed: [String] = []
        for stretch in stretches.reversed() {
            let slice = Array(words[stretch])
            let start = max(0, slice[0].start - 1), end = min(Double(file.length) / rate, slice[slice.count - 1].end + 1)
            guard end > start, let audio = Self.read(file, from: start, to: end, rate: rate) else { continue }
            // The words as the rescorer wants them: one "token" per word, at its time within the stretch.
            let timings = slice.map {
                TokenTiming(token: "▁" + $0.text, tokenId: 0, startTime: $0.start - start, endTime: $0.end - start, confidence: 1)
            }
            let text = slice.map(\.text).joined(separator: " ")
            do {
                let (spotter, rescorer, vocabulary) = try await session(for: terms)
                let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: vocabulary, minScore: nil)
                guard !spot.logProbs.isEmpty else { continue }
                let evidence = rescorer.ctcTokenEvaluateCandidates(transcript: text, tokenTimings: timings,
                                                                    logProbs: spot.logProbs, frameDuration: spot.frameDuration)
                guard evidence.baseWords.count == slice.count else { continue }      // the words must line up one to one
                for edit in Self.gate(evidence).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                    let first = stretch.lowerBound + edit.range.lowerBound, last = stretch.lowerBound + edit.range.upperBound - 1
                    var word = out[first]
                    word.text = edit.text
                    word.end = out[last].end
                    out.replaceSubrange(first...last, with: [word])
                    fixed.append(edit.term)
                }
            } catch {
                Self.log.error("ordlistan (möte): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !fixed.isEmpty { Self.log.info("ordlistan hörd i mötet: \(fixed.count) byten") }
        return (out, fixed)
    }

    private static func read(_ file: AVAudioFile, from start: Double, to end: Double, rate: Double) -> [Float]? {
        let frames = AVAudioFrameCount((end - start) * rate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        file.framePosition = AVAudioFramePosition(start * rate)
        guard (try? file.read(into: buffer, frameCount: frames)) != nil, let data = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func session(for terms: [String]) async throws -> (CtcKeywordSpotter, VocabularyRescorer, CustomVocabularyContext) {
        if let ready, ready.terms == terms { return (ready.spotter, ready.rescorer, ready.vocabulary) }
        // Only a listener already loaded by prepare(): a dictation never waits for a
        // download or a model load — offline, or while the download runs, the text
        // is used as the model wrote it.
        guard let models else { throw ListenerError.notLoaded }
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        // Without the acoustic "rescue" pass: it swapped ordinary phrases for names.
        let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
        let boosting = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models, config: config)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: boosting.vocabulary,
                                                           config: config, ctcModelDirectory: Self.directory)
        ready = (terms, spotter, rescorer, boosting.vocabulary)
        return (spotter, rescorer, boosting.vocabulary)
    }

    // MARK: Mindtalk's own rule on top of the acoustic comparison

    /// Of the candidates the library found acoustic evidence for: the phrase must also
    /// look like the term (≥ 0.65 alike in letters — "Kelly"/"Kellie" 0.67, "kissa"/
    /// "Lisa" 0.60), and of a longer phrase only the part that matches the term best
    /// is replaced ("Klang AI är" keeps its "är"). Punctuation stays.
    struct Edit { let range: Range<Int>; let text: String; let term: String }

    nonisolated static func gate(_ evidence: VocabularyRescorer.CandidateEvidenceOutput) -> [Edit] {
        let words = evidence.baseWords
        var edits: [Edit] = []
        var taken = Set<Int>()
        let ranked = evidence.candidates.sorted { ($0.rawVocabularyCTCScore ?? -99) > ($1.rawVocabularyCTCScore ?? -99) }
        for c in ranked where c.comparisonPassed {
            let span = Array(c.wordRange)
            guard !span.isEmpty, !span.contains(where: taken.contains) else { continue }
            var best: (range: Range<Int>, alike: Double)?
            for i in span.indices {
                for j in i..<span.count {
                    let alike = alike(key(words[span[i]...span[j]].joined()), key(c.canonicalTerm))
                    if best == nil || alike > best!.alike { best = (span[i]..<(span[j] + 1), alike) }
                }
            }
            guard let best, best.alike >= 0.65 else { continue }
            let original = words[best.range].joined(separator: " ")
            if key(original) == key(c.canonicalTerm) { continue }      // same word, just written differently: the list's own rules handle case
            let last = words[best.range.upperBound - 1]
            let tail = String(last.reversed().prefix { ",.!?:;".contains($0) }.reversed())
            taken.formUnion(best.range)
            edits.append(Edit(range: best.range, text: c.canonicalTerm + tail, term: c.canonicalTerm))
        }
        return edits
    }

    nonisolated static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// 1 − normalised edit distance.
    nonisolated static func alike(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}

/// What the Ordlista page shows about the listener.
@MainActor
final class VocabularyBoostStatus: ObservableObject {
    static let shared = VocabularyBoostStatus()

    enum State: Equatable {
        case missing
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = VocabularyBoost.isInstalled ? .ready : .missing

    func set(_ new: State) { state = new }

    /// As the page or Modeller appears: a folder deleted in Finder (or put back) is
    /// noticed. A download under way, or a failure, is left to say its piece.
    func refresh() {
        switch state {
        case .downloading, .failed: break
        case .ready, .missing: state = VocabularyBoost.isInstalled ? .ready : .missing
        }
    }
}
