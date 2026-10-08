import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os
import SwiftUI

// MARK: - Voices you've named, remembered across meetings
//
// Name a speaker once — "Talare 2" is Anna — and the next meeting she's in, Mindtalk
// names her itself. After each meeting's final pass, every unnamed voice with enough
// speech is turned into a voiceprint (ReDimNet2+, a small speaker model built into the
// app: 192 numbers per voice, no audio) and compared with the people you've named before. A clear match
// gets the name; anything unsure stays "Talare N".
//
// A voiceprint is biometric data, so this is off until you switch it on (Inställningar
// → Möten). Prints live only on this Mac, in People.json next to the meetings, and
// any person — or everyone — can be forgotten at any time. Nothing is ever sent.

@MainActor
final class VoiceMemory: ObservableObject {
    static let shared = VoiceMemory()
    nonisolated static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "VoiceMemory")

    struct Person: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// Up to five voiceprints from different meetings — rooms and mics differ.
        var prints: [[Float]]
        var updated = Date()
        /// Their figure (VoiceFigure), chosen when the voice was first saved and never
        /// changed after — the same person looks the same in every meeting.
        var figure: VoiceFigure?
        /// The speaker model the prints were made with — prints from different models
        /// can't be compared (nil: the old CAM++ model).
        var model: String?
        /// The meeting each print came from (its folder name), so naming a voice again
        /// in the same meeting replaces that meeting's print rather than adding another.
        var sources: [String]?
    }

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }

    @Published var enabled = UserDefaults.standard.bool(forKey: "voiceMemory") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "voiceMemory")
            if enabled { prepare() }
        }
    }
    @Published private(set) var people: [Person] = []
    /// On — switched on in Settings, or for a self-test (never saved then).
    private var isOn: Bool { enabled || testing }
    private var testing = false
    @Published private(set) var state: State = .missing

    /// Figures shown for new voices in the introduction round, waiting for those voices
    /// to be saved under the names they were given.
    private var reserved: [String: VoiceFigure] = [:]

    private init() {
        people = Self.loadPeople()
        giveFigures()
        dropOldPrints()
        if enabled { prepare() }
    }

    /// Prints made with an earlier speaker model mean nothing to this one: they go
    /// (names and figures stay), and are made again from your meetings (relearn).
    private func dropOldPrints() {
        var changed = false
        for i in people.indices where people[i].model != Self.modelID && !people[i].prints.isEmpty {
            people[i].prints = []
            people[i].sources = nil
            changed = true
        }
        if changed { save() }
        // The old model's own folder is no longer used.
        let old = SpeechModel.rootDirectory.appendingPathComponent("campplus-321b18e2")
        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.trashItem(at: old, resultingItemURL: nil) }
    }

    // MARK: Figures

    /// Rhythms already worn by people you know.
    var takenRhythms: Set<Int> { Set(people.compactMap { $0.figure?.rhythm }) }

    /// A person's figure.
    func figure(of name: String) -> VoiceFigure? {
        people.first { Self.key($0.name) == Self.key(name) }?.figure
    }

    /// The figure a new voice gets — unlike anyone you know (and anyone in `others`).
    func figureForNew(_ print: [Float], alsoAvoiding others: Set<Int> = []) -> VoiceFigure {
        VoiceFigure.from(print: print, avoiding: takenRhythms.union(others))
    }

    /// A new voice was shown with this figure and given this name: saved, it keeps it.
    func reserve(_ figure: VoiceFigure, for name: String) {
        reserved[Self.key(name)] = figure
    }

    /// People saved before figures were kept get theirs now, from all their prints,
    /// each unlike the ones before them.
    private func giveFigures() {
        var changed = false
        for i in people.indices where people[i].figure == nil {
            guard let mean = VoiceFigure.mean(people[i].prints) else { continue }
            people[i].figure = VoiceFigure.from(print: mean, avoiding: takenRhythms)
            changed = true
        }
        if changed { save() }
    }

    // MARK: The model (ReDimNet2+, 13 MB, inside the app — nothing is downloaded)

    /// Which model made a print (see Person.model).
    nonisolated static let modelID = "redimnet2plus-int8-1"

    /// Loads the model (switched on) ahead of the next meeting, and makes prints again
    /// for anyone who has none.
    private var preparing: Task<Void, Never>?

    func prepare() {
        guard preparing == nil else { return }
        preparing = Task {
            defer { preparing = nil }
            do {
                try await VoicePrints.shared.load()
                state = .ready
            } catch {
                Self.log.error("voice model: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                return
            }
            await learnFromPastMeetings()
            await relearn()
        }
    }

    /// People you've named whose prints are gone (a new speaker model): learned again
    /// from the meetings you named them in.
    func relearn() async {
        let missing = Set(people.filter { $0.prints.isEmpty }.map { Self.key($0.name) })
        guard isOn, state == .ready, !missing.isEmpty else { return }
        await MeetingStore.shared.ready()
        for record in MeetingStore.shared.meetings.sorted(by: { $0.date < $1.date }) where record.hasAudio {
            let given = record.names.filter {
                record.recognized[$0.key] == nil && Self.isRealName($0.value) && missing.contains(Self.key($0.value))
            }
            guard !given.isEmpty else { continue }
            await learn(words: record.words, audio: MeetingStore.audioURL(for: record.id), names: given)
        }
        Self.log.info("voices made again with the new model: \(self.people.filter { !$0.prints.isEmpty }.count) of \(self.people.count)")
    }

    /// Switched on for the first time: the people you've already named in your
    /// meetings are remembered right away, so the next meeting can know them.
    func learnFromPastMeetings() async {
        guard enabled, people.isEmpty, !UserDefaults.standard.bool(forKey: "voiceMemoryLearnedPast") else { return }
        UserDefaults.standard.set(true, forKey: "voiceMemoryLearnedPast")
        await MeetingStore.shared.ready()
        for record in MeetingStore.shared.meetings.sorted(by: { $0.date < $1.date }) where record.hasAudio {
            let given = record.names.filter { record.recognized[$0.key] == nil && Self.isRealName($0.value) }
            guard !given.isEmpty else { continue }
            await learn(words: record.words, audio: MeetingStore.audioURL(for: record.id), names: given)
        }
        Self.log.info("learned \(self.people.count) people from earlier meetings")
    }

    // MARK: People

    private static var peopleURL: URL { MeetingStore.root.appendingPathComponent("People.json") }

    private static func loadPeople() -> [Person] {
        guard let data = try? Data(contentsOf: peopleURL) else { return [] }
        do {
            return try JSONDecoder().decode([Person].self, from: data)
        } catch {
            // Unreadable: kept aside, never overwritten by the next save.
            let aside = peopleURL.deletingLastPathComponent()
                .appendingPathComponent("People-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: peopleURL, to: aside)
            log.error("People.json could not be read; kept as \(aside.lastPathComponent, privacy: .public)")
            return []
        }
    }

    private func save() {
        guard !testing else { return }
        do {
            try FileManager.default.createDirectory(at: MeetingStore.root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(people).write(to: Self.peopleURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.peopleURL.path)
        } catch {
            Self.log.error("people: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Self-test (`--voices-from "titel,titel"`): on for this run only, knowing just the
    /// people named in those meetings — your own list and setting are left alone.
    func test(learningFrom titles: [String]) async {
        testing = true
        people = []
        if (try? await VoicePrints.shared.load()) != nil { state = .ready }
        await MeetingStore.shared.ready()
        for record in MeetingStore.shared.meetings where titles.contains(where: { record.title.contains($0) }) {
            await learn(words: record.words, audio: MeetingStore.audioURL(for: record.id), names: record.names)
        }
        print("Röster från \(titles.joined(separator: ", ")): \(people.map { "\($0.name) (\($0.prints.count))" }.joined(separator: ", "))")
    }
    #endif

    func forget(_ person: Person) {
        people.removeAll { $0.id == person.id }
        save()
    }

    func forgetAll() {
        people = []
        try? FileManager.default.removeItem(at: Self.peopleURL)
        // Switched on again later, it may learn from the meetings once more.
        UserDefaults.standard.set(false, forKey: "voiceMemoryLearnedPast")
    }

    private static func key(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// A name corrected in a meeting ("Mattias" → "Mathias"). The voice remembered
    /// under the old name follows: all of it when it's the same name spelled another
    /// way, or when it was only ever named in this meeting; otherwise just this
    /// meeting's print leaves it (learned again under the new name). A spelling fix
    /// also goes into your Ordlista, so it's written right from now on.
    func corrected(from old: String, to new: String, meeting: String) {
        let old = old.trimmingCharacters(in: .whitespaces), new = new.trimmingCharacters(in: .whitespaces)
        guard Self.isRealName(old), Self.isRealName(new), Self.key(old) != Self.key(new) else { return }
        let alike = Self.spelledAlike(old, new)
        if alike { Vocabulary.shared.add(word: new, heardAs: old) }
        if let figure = reserved.removeValue(forKey: Self.key(old)) { reserved[Self.key(new)] = figure }
        guard let i = people.firstIndex(where: { Self.key($0.name) == Self.key(old) }) else { return }
        let sources = people[i].sources ?? []
        if alike || sources == [meeting] {
            if let j = people.firstIndex(where: { Self.key($0.name) == Self.key(new) }) {
                // Already known under the new name: one person.
                var into = people[j]
                into.prints += people[i].prints
                into.sources = (into.sources ?? Array(repeating: "", count: into.prints.count - people[i].prints.count))
                    + (people[i].sources ?? Array(repeating: "", count: people[i].prints.count))
                while into.prints.count > 5 { into.prints.removeFirst(); into.sources?.removeFirst() }
                into.updated = Date()
                people[j] = into
                people.remove(at: i)
            } else {
                people[i].name = new
                people[i].updated = Date()
            }
        } else if let k = sources.firstIndex(of: meeting), k < people[i].prints.count {
            people[i].prints.remove(at: k)
            people[i].sources?.remove(at: k)
            if people[i].prints.isEmpty { people.remove(at: i) }
        }
        save()
        Self.log.notice("voice renamed in a meeting (same name spelled differently: \(alike))")
    }

    /// "Mattias" and "Mathias", "Eric" and "Erik": the same start, a letter or two apart —
    /// but not one name grown from the other ("Johan", "Johanna").
    nonisolated static func spelledAlike(_ a: String, _ b: String) -> Bool {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        guard let first = a.first, first == b.first, abs(a.count - b.count) <= 1,
              !a.starts(with: b), !b.starts(with: a) else { return false }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return row[b.count] <= 2
    }

    /// The default "Talare 2" isn't a name; anything you typed is.
    private static func isRealName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n.range(of: #"^(Talare|Speaker) \d+$"#, options: .regularExpression) == nil
    }

    // MARK: After a meeting

    /// Two voices are the same person from this score on (cosine of ReDimNet2+ prints) —
    /// measured on real meetings (scripts/voice-models): the same voice in another
    /// meeting scored 0.64 and up from four seconds of speech, two different people at
    /// most 0.54.
    nonisolated static let sameVoice: Float = 0.60
    /// And the best match must beat the next by this much.
    nonisolated static let margin: Float = 0.1
    /// A new print for someone you know that scores below this against their earlier
    /// ones is probably someone else's voice (speakers mixed up in that meeting).
    nonisolated static let notThem: Float = 0.5

    /// Who the unnamed voices of a meeting are, among the people you've named. Each
    /// person at most once, the clearest matches first. Returns speaker → (name, score).
    func recognise(words: [MeetingWord], audio url: URL, names: [String: String]) async -> [Int: (name: String, score: Float)] {
        guard isOn, state == .ready, !people.isEmpty else { return [:] }
        let unnamed = Set(words.compactMap(\.speaker).filter { $0 >= 0 && !(names[String($0)].map(Self.isRealName) ?? false) })
        guard !unnamed.isEmpty else { return [:] }
        let taken = Set(names.values.filter(Self.isRealName).map(Self.key))
        let candidates = people.filter { !taken.contains(Self.key($0.name)) }
        var scores: [(speaker: Int, person: Person, score: Float, lead: Float)] = []
        for speaker in unnamed {
            guard let print = await VoicePrints.shared.print(of: speaker, in: words, audio: url) else { continue }
            let ranked = candidates.map { ($0, Self.similarity(print, $0)) }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { continue }
            let lead = best.1 - (ranked.dropFirst().first?.1 ?? -1)
            Self.log.info("voice \(speaker): best \(best.0.name, privacy: .private) \(best.1, format: .fixed(precision: 2)), lead \(lead, format: .fixed(precision: 2))")
            scores.append((speaker, best.0, best.1, lead))
        }
        var out: [Int: (name: String, score: Float)] = [:]
        var used = Set<UUID>()
        for s in scores.sorted(by: { $0.score > $1.score }) where s.score >= Self.sameVoice && s.lead >= Self.margin {
            guard !used.contains(s.person.id), out[s.speaker] == nil else { continue }
            used.insert(s.person.id)
            out[s.speaker] = (s.person.name, s.score)
        }
        return out
    }

    /// The person a voiceprint is, among the people not already in the meeting — only a
    /// clear match (as after a meeting).
    func match(_ print: [Float], excluding taken: Set<String>) -> (name: String, score: Float)? {
        guard isOn, state == .ready else { return nil }
        let keys = Set(taken.map(Self.key))
        let ranked = people.filter { !keys.contains(Self.key($0.name)) }
            .map { ($0, Self.similarity(print, $0)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        let lead = best.1 - (ranked.dropFirst().first?.1 ?? -1)
        return best.1 >= Self.sameVoice && lead >= Self.margin ? (best.0.name, best.1) : nil
    }

    /// For the log (kept by macOS): how close a voice of the round came to the people
    /// you know — names private, scores readable.
    func logBest(_ print: [Float], speaker: Int, heard: Double) {
        let ranked = people.map { ($0.name, Self.similarity(print, $0)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first else { return }
        let lead = best.1 - (ranked.dropFirst().first?.1 ?? -1)
        Self.log.notice("introduction: voice \(speaker) after \(Int(heard)) s: best \(best.0, privacy: .private) \(best.1, format: .fixed(precision: 2)), lead \(lead, format: .fixed(precision: 2))")
    }

    /// The voices you've named in a meeting, remembered (or remembered better). A print
    /// that doesn't sound like the person at all is left out: then the speakers were
    /// probably mixed up in that meeting, and it would only teach the wrong voice.
    func learn(words: [MeetingWord], audio url: URL, names: [String: String]) async {
        guard isOn, state == .ready else { return }
        let source = url.deletingLastPathComponent().lastPathComponent
        for (key, name) in names where Self.isRealName(name) {
            guard let speaker = Int(key),
                  let print = await VoicePrints.shared.print(of: speaker, in: words, audio: url) else { continue }
            if let i = people.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                var sources = people[i].sources ?? []
                if sources.count != people[i].prints.count { sources = Array(repeating: "", count: people[i].prints.count) }
                // Named again in the same meeting: that meeting's print, made anew.
                if let same = sources.firstIndex(of: source) {
                    people[i].prints[same] = print
                    people[i].sources = sources
                    people[i].model = Self.modelID
                    people[i].updated = Date()
                    continue
                }
                // Below this it's hardly their voice (the same person scored 0.61 and up
                // between meetings, others 0.33 on average): left out.
                if people[i].prints.count >= 2, Self.similarity(print, people[i]) < Self.notThem { continue }
                people[i].prints.append(print)
                sources.append(source)
                people[i].model = Self.modelID
                if people[i].prints.count > 5 { people[i].prints.removeFirst(); sources.removeFirst() }
                people[i].sources = sources
                people[i].name = name
                people[i].updated = Date()
                if people[i].figure == nil { people[i].figure = figureForNew(print) }
                reserved[Self.key(name)] = nil
            } else {
                // A "new" person whose voice is someone you already know (a voice named
                // twice, or two people heard as one): not saved — it would only confuse
                // the two from now on.
                if let other = people.first(where: { Self.similarity(print, $0) >= Self.sameVoice }) {
                    Self.log.notice("not learned: a new name for the voice of \(other.name, privacy: .private)")
                    continue
                }
                let figure = reserved.removeValue(forKey: Self.key(name)) ?? figureForNew(print)
                people.append(Person(name: name.trimmingCharacters(in: .whitespaces), prints: [print], figure: figure,
                                     model: Self.modelID, sources: [source]))
            }
        }
        save()
    }

    /// How much a print sounds like a person: the best of their prints, so one good
    /// recording in a similar room is enough.
    nonisolated static func similarity(_ print: [Float], _ person: Person) -> Float {
        person.prints.map { cosine(print, $0) }.max() ?? -1
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// Turns a speaker's part of a recording into a voiceprint.
actor VoicePrints {
    static let shared = VoicePrints()
    private var embedder: SpeakerModel?

    func load() throws {
        guard embedder == nil else { return }
        embedder = try SpeakerModel()
    }

    /// At least this much clear speech, or no print — a few words say little about a voice.
    static let minimumSpeech = 6.0
    /// And at most this much: enough for a steady print, quick to compute.
    static let maximumSpeech = 30.0

    /// The speaker's longest stretches of speech (on their own, not right next to
    /// someone else's words) put together, as a voiceprint.
    func print(of speaker: Int, in words: [MeetingWord], audio url: URL) async -> [Float]? {
        guard (try? load()) != nil, let embedder else { return nil }
        // Their stretches: their words in a row, gaps under 0.6 s inside.
        var stretches: [(start: Double, end: Double)] = []
        for (i, w) in words.enumerated() where w.speaker == speaker {
            let previous = i > 0 ? words[i - 1] : nil
            if let last = stretches.last, previous?.speaker == speaker, w.start - last.end < 0.6 {
                stretches[stretches.count - 1].end = w.end
            } else {
                stretches.append((w.start, w.end))
            }
        }
        // Trimmed a little at both ends, where another voice may still be heard.
        let clean = stretches.map { (start: $0.start + 0.15, end: $0.end - 0.1) }.filter { $0.end - $0.start >= 0.8 }
        var total = 0.0
        var chosen: [(start: Double, end: Double)] = []
        for s in clean.sorted(by: { $0.end - $0.start > $1.end - $1.start }) {
            chosen.append(s)
            total += s.end - s.start
            if total >= Self.maximumSpeech { break }
        }
        guard total >= Self.minimumSpeech, let file = try? AVAudioFile(forReading: url) else { return nil }
        var samples: [Float] = []
        for s in chosen.sorted(by: { $0.start < $1.start }) {
            samples += Self.read(file, from: s.start, to: min(s.end, s.start + Self.maximumSpeech))
        }
        guard samples.count >= Int(Self.minimumSpeech * 16_000) else { return nil }
        return try? embedder.embed(audio: samples)
    }

    /// The same, from samples in memory that start at the meeting's start (the
    /// introduction, while the recording is still being written).
    /// `minimum`: seconds of their speech needed — less while a meeting runs, to name
    /// someone within seconds (strangers don't score higher on short prints).
    func print(of speaker: Int, in words: [MeetingWord], samples: [Float], minimum: Double = 3.5) async -> [Float]? {
        guard (try? load()) != nil, let embedder else { return nil }
        var audio: [Float] = []
        for s in Self.stretches(of: speaker, in: words) {
            let a = max(0, Int(s.start * 16_000)), b = min(samples.count, Int(s.end * 16_000))
            if a < b { audio += samples[a..<b] }
        }
        guard audio.count >= Int(minimum * 16_000) else { return nil }
        return try? embedder.embed(audio: audio)
    }

    /// A print of a stretch of audio known to be one voice (a turn of the round) —
    /// from a second and a half: short prints miss more, but strangers don't score
    /// higher (measured on real meetings).
    func print(raw audio: [Float]) async -> [Float]? {
        guard audio.count >= 24_000, (try? load()) != nil, let embedder else { return nil }
        return try? embedder.embed(audio: audio)
    }

    /// A speaker's longest stretches of speech, trimmed at the ends, up to half a minute.
    static func stretches(of speaker: Int, in words: [MeetingWord]) -> [(start: Double, end: Double)] {
        var stretches: [(start: Double, end: Double)] = []
        for (i, w) in words.enumerated() where w.speaker == speaker {
            let previous = i > 0 ? words[i - 1] : nil
            if let last = stretches.last, previous?.speaker == speaker, w.start - last.end < 0.6 {
                stretches[stretches.count - 1].end = w.end
            } else {
                stretches.append((w.start, w.end))
            }
        }
        let clean = stretches.map { (start: $0.start + 0.15, end: $0.end - 0.1) }.filter { $0.end - $0.start >= 0.8 }
        var total = 0.0
        var chosen: [(start: Double, end: Double)] = []
        for s in clean.sorted(by: { $0.end - $0.start > $1.end - $1.start }) {
            chosen.append(s)
            total += s.end - s.start
            if total >= maximumSpeech { break }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// 16 kHz mono samples between two times (meetings are recorded at 16 kHz).
    private static func read(_ file: AVAudioFile, from start: Double, to end: Double) -> [Float] {
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, start) * rate)
        let count = AVAudioFrameCount(max(0, (end - start) * rate))
        guard first < file.length, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: min(count, AVAudioFrameCount(file.length - first)))) != nil,
              let data = buffer.floatChannelData?[0] else { return [] }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        guard rate != 16_000 else { return samples }
        // Not expected for meetings; kept simple.
        let step = rate / 16_000
        return stride(from: 0.0, to: Double(samples.count), by: step).map { samples[Int($0)] }
    }
}

/// Settings → Möten: remembering voices — off until you switch it on, with the
/// people it knows and a way to forget each of them.
struct VoiceMemoryCard: View {
    @ObservedObject var memory: VoiceMemory
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Känn igen röster", detail: detail) {
                InkToggle(label: "Känn igen röster", isOn: $memory.enabled)
            }
            if memory.enabled, !memory.people.isEmpty {
                CardDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Röster Mindtalk känner igen").font(.system(size: 13, weight: .semibold))
                    FlowLayout(spacing: 8) {
                        ForEach(Array(memory.people.enumerated()), id: \.element.id) { i, person in
                            HStack(spacing: 6) {
                                VoiceFigureMark(figure: VoiceFigure.remembered(person.name) ?? VoiceFigure.from(seed: person.name),
                                                color: SpeakerMark.fill(i), lineWidth: 1.2)
                                    .frame(width: 18, height: 18)
                                Text(person.name).font(.system(size: 12.5, weight: .medium))
                                Button { withAnimation(.snappy) { memory.forget(person) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Colors.faint)
                                }
                                .buttonStyle(.plain)
                                .help("Glöm \(person.name)s röst")
                                .accessibilityLabel("Glöm \(person.name)")
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Capsule().fill(DS.Colors.chip))
                        }
                    }
                    Button("Glöm alla röster…") { confirmForgetAll = true }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        .card()
        .confirmationDialog("Glömma alla röster?", isPresented: $confirmForgetAll) {
            Button("Glöm alla", role: .destructive) { withAnimation(.snappy) { memory.forgetAll() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Röstavtrycken tas bort. Namnen i dina möten finns kvar.")
        }
    }

    private var detail: String {
        if case .failed(let why) = memory.state, memory.enabled {
            return String(localized: "Röstmodellen kunde inte startas: \(why)")
        }
        return String(localized: "Ge en talare ett namn en gång, så känner Mindtalk igen rösten i kommande möten. Ett röstavtryck sparas, inget ljud, och bara på din Mac. Fråga dem du spelar in om det är okej.")
    }
}

/// ReDimNet2+ (lab260, Apache 2.0) — the speaker model, inside the app, 8-bit, 13 MB.
/// Ten-second windows; shorter speech is repeated to fill one (silence would skew the
/// features), longer speech is averaged over its windows. It runs on the CPU: on the
/// Neural Engine this model's numbers come out wrong (measured, scripts/voice-models).
final class SpeakerModel {
    private let model: MLModel
    private static let window = 160_000

    init() throws {
        guard let url = Bundle.main.url(forResource: "ReDimNet2Plus", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// 16 kHz mono samples → a 192-number print, L2-normalised.
    func embed(audio: [Float]) throws -> [Float] {
        guard !audio.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let w = Self.window
        var sum = [Float](repeating: 0, count: 192)
        var start = 0
        while start < audio.count {
            let piece = audio[start..<min(start + w, audio.count)]
            if piece.count < 32_000, start > 0 { break }        // a scrap at the end says little
            let input = try MLMultiArray(shape: [1, w as NSNumber], dataType: .float32)
            let p = input.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<w { p[i] = piece[piece.startIndex + i % piece.count] }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: input)]))
            guard let e = out.featureValue(for: "embedding")?.multiArrayValue, e.count == sum.count else {
                throw CocoaError(.coderReadCorrupt)
            }
            var v = (0..<e.count).map { e[$0].floatValue }
            let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
            let weight = Float(piece.count) / Float(w)
            v = v.map { $0 / n * weight }
            for i in sum.indices { sum[i] += v[i] }
            start += w
        }
        let n = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return sum.map { $0 / n }
    }
}
