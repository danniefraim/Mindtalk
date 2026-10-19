import AVFoundation
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import os

// MARK: - Importing a recording
//
// An audio or video file dropped on the Möten page (or chosen with "Importera fil…",
// or opened with Mindtalk from Finder) becomes a meeting like the others: the same
// text with its speakers and names, the same notes, questions, folders and export.
// Its sound is read once into the meeting's own recording (16 kHz, as a meeting
// records — of a video only the sound is kept), then listened through as a meeting
// is when it ends. Files are taken one at a time; nothing leaves the Mac. The
// meeting appears in the list only once it has its text — never half made.

@MainActor
final class MeetingImport: ObservableObject {
    static let shared = MeetingImport()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Import")

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var name: String { MeetingImport.displayName(url.deletingPathExtension().lastPathComponent) }
        let video: Bool
        /// The folder chosen when it was dropped.
        let folder: UUID?
        /// What it's listened to with — the dictation language, unless chosen.
        var language: SpeechModel
        var stage: Stage = .waiting
        /// Of the whole job, 0…1 — estimated within a step from the recording's length.
        var progress: Double = 0
        var meeting: UUID?
        /// The meeting's title once it's made (the notes may give it a better one).
        var title: String?
        var error: String?
        /// When it was done — the card goes a while after, unless you're looking at it.
        var doneAt: Date?

        init(url: URL, video: Bool, folder: UUID?, language: SpeechModel) {
            self.url = url; self.video = video; self.folder = folder; self.language = language
        }

        #if DEBUG
        init(url: URL, video: Bool, folder: UUID?, stage: Stage, progress: Double = 0) {
            self.init(url: url, video: video, folder: folder, language: .swedish)
            self.stage = stage; self.progress = progress
            if stage == .done { meeting = UUID() }
            if stage == .failed { error = String(localized: "Filen har inget ljud.") }
        }
        #endif

        var active: Bool { stage != .waiting && stage != .done && stage != .failed }
    }

    enum Stage: Equatable {
        case waiting, reading, writing, voices, done, failed

        var title: String {
            switch self {
            case .waiting: return String(localized: "Väntar på sin tur")
            case .reading: return String(localized: "Läser in ljudet")
            case .writing: return String(localized: "Skriver ned")
            case .voices: return String(localized: "Håller isär talarna")
            case .done: return String(localized: "Klar")
            case .failed: return String(localized: "Misslyckades")
            }
        }

        /// The steps shown as dots, in order.
        static let steps: [Stage] = [.reading, .writing, .voices]
        var index: Int { Stage.steps.firstIndex(of: self) ?? (self == .done ? Stage.steps.count : -1) }

        /// Where the step begins in the whole, 0…1 — and where the next does.
        var start: Double {
            switch self {
            case .waiting, .reading: return 0
            case .writing: return 0.12
            case .voices: return 0.6
            case .done, .failed: return 1
            }
        }
        var end: Double {
            switch self {
            case .reading: return 0.12
            case .writing: return 0.6
            default: return 1
            }
        }
    }

    @Published private(set) var jobs: [Job] = []
    /// A file dragged over the page / over the start card's zone; and whether that
    /// zone is on screen (then it lights up instead of the page being covered).
    @Published var pageDragging = false
    @Published var zoneTargeted = false
    @Published var zoneVisible = false
    var dropping: Bool { zoneTargeted || (pageDragging && zoneVisible) }

    /// What was dropped: files from Finder, and copies handed over by apps
    /// (Röstmemon, Bilder). Whether any of it could be taken.
    func take(_ providers: [NSItemProvider], folder: UUID?) -> Bool {
        var any = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                any = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in MeetingImport.shared.add([url], folder: folder) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.audiovisualContent.identifier) {
                any = true
                addCopy(of: provider, folder: folder)
            }
        }
        return any
    }
    /// Files that weren't sound or video — said for a few seconds, then gone.
    @Published private(set) var refused: String?
    /// The file last done — said under the drop zone for ten seconds, with the date
    /// the meeting got, so you know where in the list it went.
    @Published private(set) var lastDone: Done?

    struct Done: Equatable {
        let meeting: UUID
        let title: String
        let date: Date
        let dateKnown: Bool
        let at: Date

        /// "Klar: ”Styrelsemöte”, inspelad 14 augusti."
        var text: String {
            dateKnown ? String(localized: "Klar: ”\(title)”, inspelad \(MeetingRecord.day(date, long: true)).")
                      : String(localized: "Klar: ”\(title)”, datum okänt.")
        }
    }
    private var running: Task<Void, Never>?

    /// Sound and video — whatever macOS can read (mp3, m4a, wav, aiff, mp4, mov…).
    static let types: [UTType] = [.audiovisualContent]

    static func canImport(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    /// Whether files can be written out now — the speech model and the voices are here.
    var ready: Bool { Dictation.shared.engine.isInstalled && VoiceModels.isInstalled }

    /// "Importera fil…": one or more files from a panel — with the language to hear
    /// them in, when there's more than one.
    func choose(folder: UUID?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Välj en ljud- eller videofil att göra text av")
        panel.prompt = String(localized: "Importera")
        let models = SpeechModel.allCases.filter(\.isInstalled)
        var popup: NSPopUpButton?
        if models.count > 1 {
            let menu = NSPopUpButton(frame: .zero, pullsDown: false)
            for model in models { menu.addItem(withTitle: model.spokenIn) }
            menu.selectItem(at: models.firstIndex(of: Dictation.shared.engine) ?? 0)
            let label = NSTextField(labelWithString: String(localized: "Språket i filen"))
            let row = NSStackView(views: [label, menu])
            row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            panel.accessoryView = row
            panel.isAccessoryViewDisclosed = true
            popup = menu
        }
        let language = { popup.map { models[max(0, $0.indexOfSelectedItem)] } }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] answer in
                guard answer == .OK else { return }
                self?.add(panel.urls, folder: folder, language: language())
            }
        } else if panel.runModal() == .OK {
            add(panel.urls, folder: folder, language: language())
        }
    }

    /// Files dropped or opened: each one queued — the files in a folder too. Anything
    /// that isn't sound or video is said, for a moment, not silently left out.
    func add(_ urls: [URL], folder: UUID?, language: SpeechModel? = nil) {
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
                files += inside.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                files.append(url)
            }
        }
        var refused: [String] = []
        var added = 0
        for url in files {
            guard Self.canImport(url) else { refused.append(url.lastPathComponent); continue }
            guard !jobs.contains(where: { $0.url == url && $0.stage != .done && $0.stage != .failed }) else { continue }
            let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
            jobs.append(Job(url: url, video: video, folder: MeetingFolders.shared.folder(folder)?.id,
                            language: language ?? Dictation.shared.engine))
            added += 1
        }
        if !refused.isEmpty {
            let text = refused.count == 1
                ? String(localized: "\(refused[0]) är inte en ljud- eller videofil som macOS kan läsa.")
                : String(localized: "\(refused.count) filer är inte ljud- eller videofiler som macOS kan läsa.")
            self.refused = text
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.refused == text { self?.refused = nil }
            }
        }
        if added > 0 {
            AccessibilityNotification.Announcement(added == 1 ? String(localized: "En fil skrivs ned")
                                                   : String(localized: "\(added) filer skrivs ned")).post()
            NotificationCenter.default.post(name: .importAdded, object: nil)
        }
        kick()
    }

    /// A file dragged from an app that hands over a copy (Röstmemon, Bilder): written
    /// to a folder of Mindtalk's own first, then imported as any file.
    /// The folder an import's copy was made in — removed when the job ends.
    nonisolated static func dropCopy(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent.hasPrefix("Mindtalk-import-"),
              dir.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// At launch: copies left from a run that stopped part way.
    nonisolated static func sweepCopies() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for dir in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix("Mindtalk-import-") {
            try? fm.removeItem(at: dir)
        }
    }

    func addCopy(of provider: NSItemProvider, folder: UUID?) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.audiovisualContent.identifier) { url, _ in
            guard let url else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mindtalk-import-\(UUID().uuidString)")
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
            } catch { return }
            Task { @MainActor in MeetingImport.shared.add([copy], folder: folder) }
        }
    }

    /// The language changed on a card that hasn't begun.
    func setLanguage(_ language: SpeechModel, for id: UUID) {
        update(id) { if $0.stage == .waiting { $0.language = language } }
    }

    /// Taken away: a waiting or finished card — or one being worked on, stopped.
    func remove(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].active { running?.cancel() }
        // Never begun: its copy (from Röstmemon, Bilder) isn't left in the temporary folder.
        if jobs[i].stage == .waiting { Self.dropCopy(jobs[i].url) }
        jobs.remove(at: i)
    }

    /// Looked at (the pointer over it): a done card stays a while longer.
    func touch(_ id: UUID) { update(id) { if $0.doneAt != nil { $0.doneAt = Date() } } }

    /// The next file — not while a meeting is being recorded or finished (they share
    /// the speech model and the Mac's attention).
    func kick() {
        guard running == nil, let i = jobs.firstIndex(where: { $0.stage == .waiting }) else { return }
        let id = jobs[i].id
        running = Task { @MainActor [weak self] in
            while MeetingSession.shared.isBusy { try? await Task.sleep(for: .seconds(2)) }
            await self?.run(id)
            self?.running = nil
            self?.kick()
        }
    }

    /// Being written out now — quitting asks first, an update waits.
    var busy: Bool { jobs.contains(where: \.active) || running != nil }
    private func busyAfter(_ id: UUID) -> Bool { jobs.contains { $0.id != id && $0.active } }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    /// A step's progress creeping on while it works — from what such a step usually
    /// takes for this much sound — slowing near its end but never standing still.
    private func creep(_ id: UUID, _ stage: Stage, seconds: Double) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(began) / max(1, seconds)
                // Quick at first; past the estimate, ever slower towards the step's end.
                let share = t < 1.36 ? (1 - exp(-2.2 * t)) * 0.95 / 0.95
                    : 0.95 + 0.04 * (1 - exp(-(t - 1.36)))
                self?.update(id) { $0.progress = stage.start + (stage.end - stage.start) * min(0.99, share) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        // Awake for it — a long file takes minutes, often with the window closed.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Mindtalk skriver ned en fil")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            // A copy made for this import (from Röstmemon, Bilder): not left in the temporary folder.
            Self.dropCopy(job.url)
            // An update waiting for a quiet moment: now, if nothing else runs.
            if !busyAfter(id), !MeetingSession.shared.isBusy { Updates.shared.meetingEnded() }
        }
        let language = job.language
        guard language.isInstalled, VoiceModels.isInstalled else {
            update(id) { $0.stage = .failed; $0.error = String(localized: "Ladda ned talmodellen och Nemotron 3 först, under Inställningar → Modeller.") }
            return
        }
        Self.log.info("import: \(job.video ? "video" : "audio", privacy: .public), \(job.url.pathExtension, privacy: .public), \(language.rawValue, privacy: .public)")
        let (date, dateKnown) = await Self.recordedDate(job.url)
        var record = MeetingRecord(title: job.name, date: date, language: language)   // readable meanwhile
        record.folder = job.folder
        record.folderAsked = job.folder != nil
        // A name someone gave the file stays; "IMG_1234" gives way to the notes' title.
        record.userTitled = Self.isHumanName(job.url.deletingPathExtension().lastPathComponent)
        // (With no date in the file, the meeting is dated by its import: the same moment.)
        record.source = MeetingRecord.Source(file: job.url.lastPathComponent, video: job.video,
                                             importedAt: dateKnown ? Date() : date, dateKnown: dateKnown)
        // Where the file is, to show it in Finder later — not a copy in a temporary folder.
        if !job.url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            record.source?.path = job.url.path
            record.source?.bookmark = try? job.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let audio = MeetingStore.audioURL(for: record.id)
        do {
            // 1. The sound, read once into the meeting's own recording.
            update(id) { $0.stage = .reading; $0.meeting = record.id }
            try MeetingStore.prepareFolder(for: record.id)
            let url = job.url
            let reading = Task.detached(priority: .userInitiated) { [weak self] in
                try await Self.readSound(from: url, to: audio) { share in
                    Task { @MainActor in self?.update(id) { $0.progress = Stage.reading.end * share } }
                }
            }
            let duration = try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
            try Task.checkCancellation()
            guard duration >= 1 else { throw ImportError.silent }
            record.duration = duration

            // 2. What was said.
            update(id) { $0.stage = .writing; $0.progress = Stage.writing.start }
            var creeping = creep(id, .writing, seconds: 8 + duration / 50)
            defer { creeping.cancel() }
            let timed = try await SpeechEngine.shared.transcribeFile(audio, with: language)
            creeping.cancel()
            try Task.checkCancellation()
            var words = timed.map { MeetingWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
            guard !words.isEmpty else { throw ImportError.noSpeech }

            // 3. Who said it — and the names of voices you've named before.
            update(id) { $0.stage = .voices; $0.progress = Stage.voices.start }
            creeping = creep(id, .voices, seconds: 10 + duration / 25)
            let scores = try await VoiceTracker.score(file: audio, config: VoiceModels.final)
            try Task.checkCancellation()
            _ = MeetingSession.assignSentences(&words, from: 0, scores: scores, final: true)
            let terms = VocabularyBoost.terms(from: Vocabulary.shared.entries.map(\.word))
            if !terms.isEmpty {
                let heard = await VocabularyBoost.shared.refine(words: words, audio: audio, terms: terms)
                words = heard.words
                Vocabulary.shared.noteHeard(heard.fixed)
            }
            let found = await VoiceMemory.shared.recognise(words: words, audio: audio, names: [:])
            creeping.cancel()
            try Task.checkCancellation()
            record.words = words
            for (speaker, match) in found {
                record.names[String(speaker)] = match.name
                record.recognized[String(speaker)] = match.score
            }
            record.refined = true
            record.finished = true
            // Only now in the list: whole, with its text. Not written (the disk full): failed, not done.
            guard MeetingStore.shared.save(record, onlyIfWritten: true) else { throw ImportError.notSaved }
            update(id) {
                $0.stage = .done; $0.progress = 1; $0.title = record.title; $0.doneAt = Date()
            }
            Self.log.info("import: done, \(Int(duration)) s, \(words.count) words, \(Set(words.compactMap(\.speaker)).count) voices")

            // 4. The notes — written in the background, like a meeting's.
            MeetingNotes.shared.summarize(record.id)
            AccessibilityNotification.Announcement(String(localized: "\(record.title): klart att läsa")).post()
            Self.notifyIfAway(record)
            scheduleTidy(id)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            Self.log.error("import: \(error.localizedDescription, privacy: .public)")
            // Nothing half made is kept: the sound read so far, in Mindtalk's own folder.
            try? FileManager.default.removeItem(at: MeetingStore.folder(for: record.id))
            guard !cancelled else { return }
            update(id) {
                $0.stage = .failed
                $0.meeting = nil
                $0.error = (error as? ImportError)?.message ?? String(localized: "Filen kunde inte läsas: \(error.localizedDescription)")
            }
        }
    }

    /// A done card goes by itself a while after — unless you were looking at it.
    private func scheduleTidy(_ id: UUID) {
        Task { @MainActor [weak self] in
            while let self, let job = self.jobs.first(where: { $0.id == id }), let done = job.doneAt {
                let left = 25 - Date().timeIntervalSince(done)
                if left <= 0 { self.jobs.removeAll { $0.id == id }; return }
                try? await Task.sleep(for: .seconds(left))
            }
        }
    }

    /// Done while you were elsewhere (another page, another app): a notification —
    /// clicked, the meeting opens.
    private static func notifyIfAway(_ record: MeetingRecord) {
        guard !(NSApp.isActive && AppDelegate.mainWindowIsKey && MainView.currentPage == .meetings) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Klar att läsa")
            content.body = record.title
            content.userInfo = ["meeting": record.id.uuidString]
            center.add(UNNotificationRequest(identifier: "import-\(record.id.uuidString)", content: content, trigger: nil))
        }
    }

    /// The file's name made readable: "Tavus_-_Introducing_Griffin [2105703934073683968] 1080p"
    /// becomes "Tavus – Introducing Griffin".
    nonisolated static func displayName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "_", with: " ")
        for pattern in [#"\[[^\]]*\d{5,}[^\]]*\]"#, #"\((\d{3,4}p|4k|hd)\)"#, #"\b(2160p|1440p|1080p|720p|480p|4k|uhd)\b"#, #"\.{3,}"#] {
            n = n.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        n = n.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let trimmed = n.trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
        return trimmed.isEmpty ? name : trimmed
    }

    /// A file name someone chose ("Intervju med Anna") — a few real words — rather than
    /// one a device or a download gave it ("IMG_1234", "2025-12-15 13-15-13",
    /// "Z2kJBzgKtOa3u-bTcQ3CqQ", "Tavus_-_Introducing…[2105703934073683968] 1080p"):
    /// those give way to the title the notes write.
    nonisolated static func isHumanName(_ raw: String) -> Bool {
        let n = raw.trimmingCharacters(in: .whitespaces)
        // Made by a device or a downloader.
        let machine = [#"^(IMG|MOV|VID|DSC|PXL|GMT|REC|AUD|Audio|Video|zoom|Screen ?Recording|Skärminspelning)[ _-]?\d"#,
                       #"^(Ny inspelning|New Recording|Inspelning|Recording)( \d+)?$"#,
                       #"^[\d\s_.:-]+$"#, #"^\d{4}-\d{2}-\d{2}"#,
                       #"\[[^\]]*\d{5,}[^\]]*\]"#, #"\b(2160p|1440p|1080p|720p|480p)\b"#, "_"]
        if machine.contains(where: { n.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { return false }
        let words = n.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.contains(where: \.isLetter) }
        // Two to eight words, none of them an id ("bTcQ3CqQ", "a8f3e2…").
        guard (2...8).contains(words.count) else { return false }
        let id = words.contains { w in
            w.count >= 8 && w.contains(where: \.isNumber) && w.contains(where: \.isLetter)
                || (w.count >= 10 && w.contains(where: \.isUppercase) && w.dropFirst().contains(where: \.isUppercase)
                    && w.contains(where: \.isLowercase) && !w.contains(where: \.isWhitespace))
        }
        return !id
    }

    enum ImportError: Error {
        case noSound, silent, noSpeech, protected, notSaved
        var message: String {
            switch self {
            case .notSaved: return String(localized: "Mindtalk kunde inte spara mötet. Kontrollera att det finns plats på disken.")
            case .protected: return String(localized: "Filen är kopieringsskyddad och kan inte läsas.")
            case .noSound: return String(localized: "Filen har inget ljud.")
            case .silent: return String(localized: "Filen är för kort, under en sekund.")
            case .noSpeech: return String(localized: "Inget tal hördes i filen.")
            }
        }
    }

    // MARK: The sound

    /// Reads the file's sound — any format macOS can, video too — as 16 kHz mono into
    /// `out`, as a meeting records it. Returns its length in seconds.
    nonisolated static func readSound(from url: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.hasProtectedContent)) == true { throw ImportError.protected }
        // One sound track: the first in use — a dubbed language or a commentary beside
        // it would be mixed in otherwise, and two copies of the same sound clip.
        var tracks: [AVAssetTrack] = []
        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] where tracks.isEmpty {
            if (try? await track.load(.isEnabled)) ?? true { tracks = [track] }
        }
        let length = (try? await asset.load(.duration)) ?? .zero
        guard !tracks.isEmpty else { throw ImportError.noSound }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw ImportError.noSound }
        reader.add(output)
        let file = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        guard reader.startReading() else { throw reader.error ?? ImportError.noSound }
        let total = max(1, length.seconds)
        var written = 0
        var reported = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = pcm.floatChannelData?[0] else { continue }
            pcm.frameLength = AVAudioFrameCount(count)
            _ = channel.withMemoryRebound(to: UInt8.self, capacity: bytes) { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw)
            }
            for i in 0..<count { channel[i] = max(-1, min(1, channel[i])) }      // no wrap-around in 16 bits
            try file.write(from: pcm)
            written += count
            // Said now and then, not for every buffer.
            let share = min(1, Double(written) / 16_000 / total)
            if share - reported >= 0.005 { reported = share; progress(share) }
        }
        if reader.status == .failed { throw reader.error ?? ImportError.noSound }
        file.close()
        return Double(written) / 16_000
    }

    /// When it was recorded: what the file itself says (a phone's video, a voice memo),
    /// else when the file was made, else now — never in the future. `known` is false
    /// for that last case: the meeting is then dated by its import, and says so.
    nonisolated static func recordedDate(_ url: URL) async -> (date: Date, known: Bool) {
        let now = Date()
        // Not before the year 2000 (a zero date in a file's header is 1904 or 1970).
        let plausible = { (d: Date) in d < now && d > Date(timeIntervalSince1970: 946_684_800) }
        let asset = AVURLAsset(url: url)
        // A full time stamp, not a year alone ("2019" is a song's year, not a recording).
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue), plausible(date) {
            // Stored as a date, or as text with at least a day in it.
            let text = (try? await item.load(.stringValue)) ?? nil
            if text == nil || text!.count >= 10 { return (date, true) }
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let created = attributes[.creationDate] as? Date
            let modified = attributes[.modificationDate] as? Date
            // A copy is newer than what it copied: the older of the two.
            let candidates = [created, modified].compactMap { $0 }.filter(plausible)
            if let date = candidates.min() { return (date, true) }
        }
        return (now, false)
    }
}

extension SpeechModel {
    /// In a menu of what a recording is in: "Svenska", "Flera språk".
    var spokenIn: String {
        switch self {
        case .swedish: return String(localized: "Svenska")
        case .multilingual: return String(localized: "Flera språk")
        }
    }

    /// "På svenska", "På flera språk" — listening again in it.
    var listenIn: String {
        switch self {
        case .swedish: return String(localized: "På svenska")
        case .multilingual: return String(localized: "På flera språk")
        }
    }
}
