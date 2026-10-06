import AVFoundation
import FluidAudio
import Foundation
import os
import SwiftUI

// MARK: - Voices you've named, remembered across meetings
//
// Name a speaker once — "Talare 2" is Anna — and the next meeting she's in, Mindtalk
// names her itself. After each meeting's final pass, every unnamed voice with enough
// speech is turned into a voiceprint (CAM++, a small speaker model: 192 numbers per
// voice, no audio) and compared with the people you've named before. A clear match
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
    @Published private(set) var state: State = VoiceMemory.isInstalled ? .ready : .missing

    private init() {
        people = Self.loadPeople()
        if enabled { prepare() }
    }

    // MARK: The model (CAM++, about 16 MB, in Mindtalk's own folder)

    nonisolated static let repo = "FluidInference/campplus-coreml"
    nonisolated static let revision = "321b18e270a4e19e69ef4a13d179b4eac07cec6a"
    nonisolated static let files: [SpeechModel.RemoteFile] = [
        .init(path: "CamPlusPlus.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "be20481d48572c431a3ed23606956706d4e224a0c7994ae1ab1920813edafe5f"),
        .init(path: "CamPlusPlus.mlmodelc/coremldata.bin", size: 337, sha256: "800dc33d00a27621ead3e315fe93ec15a1800aa5d4a111c064cb1c44aeebbf3a"),
        .init(path: "CamPlusPlus.mlmodelc/model.mil", size: 971728, sha256: "8605afe81896c1c23d1670132817b580dac9d3789b5805a68c6463412c50c52b"),
        .init(path: "CamPlusPlus.mlmodelc/weights/weight.bin", size: 13854912, sha256: "058c317b6a768cac30fcf89b46676d7df1aa1915357c44ecc7ada4e5b7c11590"),
        .init(path: "CamPlusPreprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "11e99d94be389165098b54c5de6f8745ed44de70f6fd294a20ca9548c626df77"),
        .init(path: "CamPlusPreprocessor.mlmodelc/coremldata.bin", size: 330, sha256: "64fb697bb216eddb9f691250e45fee44b2ef87b52b047ede0063fe7275571f00"),
        .init(path: "CamPlusPreprocessor.mlmodelc/model.mil", size: 9364, sha256: "c551054a2a8f6ad2dba60ca9fd3512364b1c4114ea4d612bbd90d162487ecdb1"),
        .init(path: "CamPlusPreprocessor.mlmodelc/weights/weight.bin", size: 1778432, sha256: "09f13054339581673c8b5745954471945a61fea54441b6e55f934f041611143a"),
    ]
    nonisolated static var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

    nonisolated static var directory: URL {
        SpeechModel.rootDirectory.appendingPathComponent("campplus-\(revision.prefix(8))")
    }
    nonisolated private static let completeMarker = ".complete"
    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(completeMarker).path)
    }

    private var installing: Task<Void, Never>?

    /// Fetches the model once (switched on) and loads it ahead of the next meeting.
    func prepare() {
        guard installing == nil else { return }
        if Self.isInstalled {
            state = .ready
            Task {
                try? await VoicePrints.shared.load()
                await learnFromPastMeetings()
            }
            return
        }
        state = .downloading(0)
        installing = Task {
            defer { installing = nil }
            do {
                try await Self.install { p in Task { @MainActor in
                    if case .downloading = VoiceMemory.shared.state { VoiceMemory.shared.state = .downloading(p) }
                } }
                state = .ready
                try? await VoicePrints.shared.load()
                Self.log.info("voice model installed")
                await learnFromPastMeetings()
            } catch {
                Self.log.error("voice model: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated private static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".staging-campplus-\(revision.prefix(8))")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var done: Int64 = 0
        for file in files {
            let base = done
            try await SpeechModel.download(repo: repo, revision: revision, file: file,
                                           to: staging.appendingPathComponent(file.path)) { written in
                progress(Double(base + written) / Double(bytes))
            }
            done += file.size
        }
        try Data().write(to: staging.appendingPathComponent(completeMarker))
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: staging, to: directory)
        progress(1)
    }

    /// Switched on for the first time: the people you've already named in your
    /// meetings are remembered right away, so the next meeting can know them.
    func learnFromPastMeetings() async {
        guard enabled, people.isEmpty, !UserDefaults.standard.bool(forKey: "voiceMemoryLearnedPast") else { return }
        UserDefaults.standard.set(true, forKey: "voiceMemoryLearnedPast")
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
        return (try? JSONDecoder().decode([Person].self, from: data)) ?? []
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
        if !Self.isInstalled { prepare() }
        while case .downloading = state { try? await Task.sleep(for: .milliseconds(300)) }
        state = Self.isInstalled ? .ready : state
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

    /// The default "Talare 2" isn't a name; anything you typed is.
    private static func isRealName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n.range(of: #"^(Talare|Speaker) \d+$"#, options: .regularExpression) == nil
    }

    // MARK: After a meeting

    /// Two voices are the same person from this score on (cosine of CAM++ prints) —
    /// measured on real meetings: the same voice in different rooms scores
    /// well above it, two different people well below.
    nonisolated static let sameVoice: Float = 0.65
    /// And the best match must beat the next by this much.
    nonisolated static let margin: Float = 0.1

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

    /// The voices you've named in a meeting, remembered (or remembered better). A print
    /// that doesn't sound like the person at all is left out: then the speakers were
    /// probably mixed up in that meeting, and it would only teach the wrong voice.
    func learn(words: [MeetingWord], audio url: URL, names: [String: String]) async {
        guard isOn, state == .ready else { return }
        for (key, name) in names where Self.isRealName(name) {
            guard let speaker = Int(key),
                  let print = await VoicePrints.shared.print(of: speaker, in: words, audio: url) else { continue }
            if let i = people.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                if people[i].prints.count >= 2, Self.similarity(print, people[i]) < 0.25 { continue }
                people[i].prints.append(print)
                if people[i].prints.count > 5 { people[i].prints.removeFirst() }
                people[i].name = name
                people[i].updated = Date()
            } else {
                people.append(Person(name: name.trimmingCharacters(in: .whitespaces), prints: [print]))
            }
        }
        save()
    }

    /// How much a print sounds like a person: the best of their prints, so one good
    /// recording in a similar room is enough.
    nonisolated static func similarity(_ print: [Float], _ person: Person) -> Float {
        person.prints.map { cosine(print, $0) }.max() ?? -1
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float { CampPlusEmbedder.cosine(a, b) }
}

/// Turns a speaker's part of a recording into a voiceprint.
actor VoicePrints {
    static let shared = VoicePrints()
    private var embedder: CampPlusEmbedder?

    func load() throws {
        guard embedder == nil else { return }
        embedder = CampPlusEmbedder(models: try CampPlusModels.load(from: VoiceMemory.directory))
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
        return try? await embedder.embed(audio: samples)
    }

    /// The same, from samples in memory that start at the meeting's start (the
    /// introduction, while the recording is still being written).
    func print(of speaker: Int, in words: [MeetingWord], samples: [Float]) async -> [Float]? {
        guard (try? load()) != nil, let embedder else { return nil }
        var audio: [Float] = []
        for s in Self.stretches(of: speaker, in: words) {
            let a = max(0, Int(s.start * 16_000)), b = min(samples.count, Int(s.end * 16_000))
            if a < b { audio += samples[a..<b] }
        }
        guard audio.count >= Int(3.5 * 16_000) else { return nil }
        return try? await embedder.embed(audio: audio)
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
            if case .downloading(let p) = memory.state, memory.enabled {
                ProgressView(value: p).tint(DS.Colors.ink).padding(.horizontal, 22).padding(.bottom, 16)
            }
            if memory.enabled, !memory.people.isEmpty {
                CardDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Röster Mindtalk känner igen").font(.system(size: 13, weight: .semibold))
                    FlowLayout(spacing: 8) {
                        ForEach(Array(memory.people.enumerated()), id: \.element.id) { i, person in
                            HStack(spacing: 6) {
                                VoiceSigil(shape: VoiceShape.remembered(person.name) ?? VoiceShape.from(seed: person.name),
                                           color: SpeakerMark.fill(i), lineWidth: 1.5, glow: false)
                                    .frame(width: 20, height: 20)
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
            return String(localized: "Röstmodellen kunde inte laddas ned: \(why)")
        }
        return String(localized: "Ge en talare ett namn en gång, så känner Mindtalk igen rösten i kommande möten. Ett röstavtryck sparas, inget ljud, och bara på din Mac. Fråga dem du spelar in om det är okej.")
    }
}
