import AVFoundation
import AppKit
import Combine
import UserNotifications
import ServiceManagement
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        // Self-test: `Mindtalk --transcribe file.wav [--model swedish|multilingual] [--clean]`
        // prints what the model hears (and, with --clean, the cleaned and polished text).
        // `Mindtalk --clean "text"` runs only the cleanup.
        let args = CommandLine.arguments
        #if DEBUG
        // Synthetic keyboard events only; no event tap, permissions or app UI.
        if args.contains("--hotkey-test") {
            Task { exit(await HotkeySelfTest.run()) }
            RunLoop.main.run()
            return
        }
        // Exercise microphone startup and device switching without loading a
        // speech model, listening for hotkeys, or typing into another app.
        if args.contains("--record-test") {
            Task { exit(await RecorderSelfTest.run(arguments: args)) }
            RunLoop.main.run()
            return
        }
        #endif
        if let i = args.firstIndex(of: "--clean"), i + 1 < args.count, !args.contains("--transcribe") {
            Task {
                await printCleanup(of: args[i + 1])
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let model = args.firstIndex(of: "--model").flatMap { j in
                j + 1 < args.count ? SpeechModel(rawValue: args[j + 1]) : nil
            } ?? .swedish
            Task {
                do {
                    let samples = try Recorder.load(URL(fileURLWithPath: args[i + 1]))
                    let t0 = Date()
                    // `--boost "Mindact,Anna"`: the same audio without and with the terms (VocabularyBoost).
                    if let b = args.firstIndex(of: "--boost"), b + 1 < args.count {
                        let terms = VocabularyBoost.terms(from: args[b + 1].split(separator: ",").map(String.init))
                        await VocabularyBoost.shared.prepare()
                        let plain = try await SpeechEngine.shared.transcribe(samples: samples, with: model)
                        let t1 = Date()
                        let (boosted, fixed) = try await SpeechEngine.shared.transcribe(samples: samples, with: model, listeningFor: terms)
                        print("UTAN: " + plain)
                        print("MED:  " + boosted)
                        print(String(format: "lyssnade: %@  byten: %@  (%.2f s)", VocabularyBoost.worthListening(plain, terms: terms) ? "ja" : "nej",
                                     fixed.joined(separator: ", "), Date().timeIntervalSince(t1)))
                        exit(0)
                    }
                    let raw = try await SpeechEngine.shared.transcribe(samples: samples, with: model)
                    print(raw)
                    print(String(format: "(%.1f s ljud, %.2f s)", Double(samples.count) / 16_000, Date().timeIntervalSince(t0)))
                    if args.contains("--clean") { await printCleanup(of: raw) }
                    exit(0)
                } catch {
                    print("Fel: \(error.localizedDescription)")
                    exit(1)
                }
            }
            RunLoop.main.run()
        }

        #if DEBUG
        // Self-test: `Mindtalk --meeting file.wav [--model …] [--speed 2]` plays a recording
        // through the meeting pipeline as if it were the microphone.
        // `Mindtalk --install-notes`: downloads and checks "Bättre anteckningar" (Gemma 4).
        if args.contains("--install-notes") {
            Task { @MainActor in
                let notes = BetterNotes.shared
                print("Ledigt: \(BetterNotes.freeBytes / 1_000_000_000) GB, minne: \(BetterNotes.memoryGB) GB")
                notes.download()
                var last = -1
                while true {
                    switch notes.state {
                    case .downloading(let p):
                        let pct = Int(p * 100)
                        if pct / 5 != last / 5 { last = pct; print("\(pct) %") }
                    case .ready: print("Klar: \(BetterNotes.directory.path)"); exit(0)
                    case .failed(let m): print("Fel: \(m)"); exit(1)
                    case .unsupported: print("Stöds inte på den här Macen."); exit(1)
                    case .missing: break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            RunLoop.main.run()
        }
        // `Mindtalk --signal-test`: the microphone's signal dies after 4 s — it must be
        // noticed then, and not during a headset's quiet start.
        if args.contains("--signal-test") {
            let recorder = Recorder(keepSamples: false)
            let healthy = args.contains("--healthy")       // no signal loss: nothing may be reported
            recorder.zerosAfter = healthy ? nil : 4
            let t0 = Date()
            recorder.onSignalLost = {
                let t = Date().timeIntervalSince(t0)
                let ok = !healthy && (5.0...7.5).contains(t)
                print(String(format: "Ingen signal upptäckt efter %.1f s (%@)", t, ok ? "rätt" : "FEL"))
                exit(ok ? 0 : 1)
            }
            do { try recorder.start() } catch { print("Fel: \(error)"); exit(1) }
            print("Mikrofon: \(recorder.usesBluetooth ? "Bluetooth" : "inte Bluetooth")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                print(healthy ? "Inget falsklarm på 12 s (rätt)" : "FEL: inget upptäcktes")
                exit(healthy ? 0 : 1)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --search "ord"`: what the meeting search finds, printed.
        if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
            MeetingStore.shared.loadNow()
            // `--times 12`: the meetings a dozen times over (in memory only) — a big library.
            let times = args.firstIndex(of: "--times").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1
            let all = (0..<times).flatMap { _ in MeetingStore.shared.meetings.map { var r = $0; r.id = UUID(); return r } }
            var found: [MeetingMatch] = []
            for round in 1...2 {
                let t0 = Date()
                found = MeetingSearch.find(args[i + 1], in: all)
                print(String(format: "%d möten av %d, varv %d (%.0f ms)", found.count, all.count, round, Date().timeIntervalSince(t0) * 1000))
            }
            if times > 1 { exit(0) }
            for m in found {
                print("• \(m.record.title)")
                for h in m.hits {
                    let at = h.at.map { " [\(MeetingView.duration($0))]" } ?? ""
                    print("    \(h.kind): \(h.who.map { $0 + ": " } ?? "")\(h.text)\(at)")
                }
            }
            exit(0)
        }
        // `Mindtalk --ask-all "fråga"`: a question across all meetings, as the Möten page asks it.
        if let i = args.firstIndex(of: "--ask-all"), i + 1 < args.count {
            Task { @MainActor in
                MeetingStore.shared.loadNow()
                let question = args[i + 1]
                let local = BetterNotes.shared.isActive
                let meetings = MeetingStore.shared.meetings.filter { !$0.words.isEmpty }
                let context = LibraryContext(question: question, meetings: meetings, budget: local ? 12_000 : Lines.appleBudget)
                print("Modell: \(local ? "Gemma 4" : "Apple Intelligence") · läser \(context.meetings) möten, \(context.text.split(separator: " ").count) ord")
                if args.contains("--show-context") { print(context.text) }
                let t0 = Date()
                do {
                    let reply = try await MeetingNotes.answerAcross(question, context: context, history: "", local: local)
                    print(String(format: "Svar (%.1f s): %@", Date().timeIntervalSince(t0), reply.answer))
                    let titles = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title) })
                    for n in reply.lines {
                        if let s = context.sources[n] {
                            print("  källa [\(n)]: \(titles[s.meeting] ?? "?") \(s.at.map { MeetingView.duration($0) } ?? "")")
                        }
                    }
                } catch { print("Fel: \(error)") }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --test-turns`: the kept-and-regrouped turns equal turns grouped all anew,
        // on all meetings joined into one long one, as it grows.
        if args.contains("--test-turns") {
            Task { @MainActor in
                MeetingStore.shared.loadNow()
                var words: [MeetingWord] = []
                var shift = 0.0
                for m in MeetingStore.shared.meetings {
                    for var w in m.words { w.start += shift; w.end += shift; words.append(w) }
                    shift = (words.last?.end ?? shift) + 3
                }
                var bad = 0, runs = 0
                let t0 = Date()
                for n in stride(from: 50, through: words.count, by: 97) {
                    let settled = Array(words[..<max(0, n - 12)])
                    var pending = Array(words[max(0, n - 12)..<n])
                    for j in pending.indices where j % 3 == 0 { pending[j].speaker = nil }
                    runs += 1
                    if MeetingText.turns(settled, pending: pending, paragraphs: true)
                        != MeetingText.turnsAllAnew(settled, pending: pending) { bad += 1 }
                }
                // A paragraph that begins on a word with no voice of its own (it takes the
                // speaker before it), right where the kept part is cut.
                for unknown in [MeetingWord.unknown, nil] as [Int?] {
                    var w: [MeetingWord] = (0..<700).map { n in
                        let t = Double(n) * 0.4 + (n >= 150 ? 3 : 0)
                        return MeetingWord(text: n % 12 == 11 ? "ord." : "ord", start: t, end: t + 0.3, speaker: 1)
                    }
                    w[150].speaker = unknown
                    runs += 1
                    if MeetingText.turns(w, paragraphs: true) != MeetingText.turnsAllAnew(w, pending: []) { bad += 1; print("FEL: tur delad vid okänd talare") }
                }
                print("Turer: \(words.count) ord, \(runs) jämförelser, \(bad) olika (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                // A two-hour meeting: one update, kept vs all anew.
                var long = words
                while long.count < 20_000, let last = long.last {
                    long += words.map { var w = $0; w.start += last.end + 3; w.end += last.end + 3; return w }
                }
                let tail = Array(long.suffix(10))
                let body = Array(long.dropLast(10))
                _ = MeetingText.turns(body, pending: tail, paragraphs: true)
                var t = Date()
                for _ in 0..<20 { _ = MeetingText.turns(body, pending: tail, paragraphs: true) }
                let kept = Date().timeIntervalSince(t) / 20 * 1000
                t = Date()
                for _ in 0..<20 { _ = MeetingText.turnsAllAnew(body, pending: tail) }
                let anew = Date().timeIntervalSince(t) / 20 * 1000
                print(String(format: "%d ord: %.1f ms per uppdatering (förut %.1f ms)", long.count, kept, anew))
                t = Date()
                for _ in 0..<20 { var h = Hasher(); for w in body { h.combine(w.speaker) }; _ = h.finalize() }
                print(String(format: "  hash %.2f ms", Date().timeIntervalSince(t) / 20 * 1000))
                let all = MeetingText.turns(body, pending: tail, paragraphs: true)
                t = Date()
                for _ in 0..<20 { _ = MeetingText.folded(all) }
                print(String(format: "  vikning %.2f ms (%d turer)", Date().timeIntervalSince(t) / 20 * 1000, all.count))
                exit(bad == 0 ? 0 : 1)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --test-names`: which said phrases name someone in the round.
        if args.contains("--test-names") {
            for (text, whole) in [("Anna", true), ("Anna.", true), ("Anna Svensson", true), ("Hej", true), ("Ja.", true),
                                  ("Okej, det blir bra.", true), ("Erik här.", true), ("Jag heter Lisa.", false),
                                  ("Det här var Johan. Hej", false), ("Det här var Johan Hej hej", false), ("Hej, det är Karin.", false), ("Johan", true),
                                  ("Per", true), ("Bra", true), ("Tack", true), ("Stockholm", true), ("Johanna Berg här", true),
                                  ("This is John.", false), ("Sara", true), ("Nästa", true), ("Hallå", true), ("Nigg", true), ("Käll", true), ("Matilda", true), ("Karin här", true), ("Liam", true), ("Emma", true), ("Björn", true), ("Linda", true), ("Det är Volvo.", false), ("Jag heter Zylvana.", false), ("Man", true), ("Nu", true), ("My name’s Tom.", false)] {
                print("\(text) → \(IntroRound.name(in: text, whole: whole) ?? "–")")
            }
            for (a, b) in [("Matilda", "Mathilda"), ("Eric", "Erik"), ("Anna", "Erik"), ("Johan", "Johanna"), ("Sara", "Sarah"), ("Per", "Pelle"), ("Anna", "Anne"), ("Lisa", "Lina"), ("Johan", "Jonas"), ("Max", "Mia"), ("Emil", "Elin"), ("Karin", "Karl"), ("Philip", "Filip"), ("Zandra", "Sandra")] {
                print("\(a) ~ \(b): \(VoiceMemory.spelledAlike(a, b))")
            }
            exit(0)
        }
        // `Mindtalk --render-voices out.png [--dark]`: the voices Mindtalk knows, as in
        // Settings, drawn to an image.
        if let i = args.firstIndex(of: "--render-voices"), i + 1 < args.count {
            Task { @MainActor in
                NSApplication.shared.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
                let renderer = ImageRenderer(content: VoiceMemoryCard(memory: VoiceMemory.shared).padding(28).frame(width: 720).background(DS.Colors.paper))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-marks out.png`: the mark buttons closed, under the pointer
        // and just clicked, drawn to an image.
        if let i = args.firstIndex(of: "--render-marks"), i + 1 < args.count {
            Task { @MainActor in
                let kinds = MeetingRecord.Mark.Kind.allCases
                let row = { (open: MeetingRecord.Mark.Kind?, done: Bool) in
                    HStack(spacing: 6) {
                        ForEach(Array(kinds.enumerated()), id: \.element) { n, kind in
                            MarkPill(kind: kind, key: n + 1, open: open == kind, done: done && open == kind)
                        }
                        Spacer()
                    }
                }
                let view = VStack(alignment: .leading, spacing: 50) {
                    row(nil, false)
                    ForEach(kinds) { kind in row(kind, false) }
                    row(.task, true)
                }
                .padding(24)
                .padding(.top, 30)
                .frame(width: 420)
                .background(Color(white: 0.07))
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --test-import file`: a file imported as the window would, then what came of it.
        if let i = args.firstIndex(of: "--test-import"), i + 1 < args.count {
            Task { @MainActor in
                MeetingStore.shared.loadNow()
                let importer = MeetingImport.shared
                let t0 = Date()
                importer.add([URL(fileURLWithPath: args[i + 1])], folder: nil)
                var last = ""
                while let job = importer.jobs.first, job.stage != .done, job.stage != .failed {
                    let now = "\(job.stage.title) \(Int(job.progress * 100)) %"
                    if now != last { print(String(format: "[%5.1f s] ", Date().timeIntervalSince(t0)) + now); last = now }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard let job = importer.jobs.first else { exit(1) }
                print("Steg: \(job.stage.title) \(job.error ?? "") efter \(Int(Date().timeIntervalSince(t0))) s")
                if let id = job.meeting, let r = MeetingStore.shared.meetings.first(where: { $0.id == id }) {
                    print("Möte: \(r.title) · datum \(r.date) · \(Int(r.duration)) s · \(r.words.count) ord · talare \(Set(r.words.compactMap(\.speaker)).sorted()) · klart \(r.finished) · genomlyssnat \(r.refined) · källa \(r.source.map { "\($0.file), video \($0.video)" } ?? "–") · sammanfattning \(r.summary?.title ?? "–")")
                    print(String(MeetingText.plain(r).prefix(400)))
                    print("MAPP: \(MeetingStore.folder(for: id).path)")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --test-export dir [--title "del av titel"]`: a meeting in every format, to a folder.
        if let i = args.firstIndex(of: "--test-export"), i + 1 < args.count {
            Task { @MainActor in
                MeetingStore.shared.loadNow()
                let wanted = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                guard let record = MeetingStore.shared.meetings.first(where: {
                    $0.summary != nil && !$0.words.isEmpty && (wanted == nil || $0.title.contains(wanted!)) }) else {
                    print("Inget möte med anteckningar."); exit(1)
                }
                let dir = URL(fileURLWithPath: args[i + 1])
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for content in MeetingExport.Content.allCases {
                    for format in MeetingExport.Format.allCases {
                        let url = dir.appendingPathComponent("\(content)-\(format.ext).\(format.ext)")
                        do { try MeetingExport.write(record, content, as: format, to: url); print("OK \(url.lastPathComponent)") }
                        catch { print("FEL \(url.lastPathComponent): \(error)") }
                    }
                }
                try? MeetingExport.srt(record).write(to: dir.appendingPathComponent("text.srt"), atomically: true, encoding: .utf8)
                if record.hasAudio, let session = AVAssetExportSession(asset: AVURLAsset(url: MeetingStore.audioURL(for: record.id)),
                                                                        presetName: AVAssetExportPresetAppleM4A) {
                    do { try await session.export(to: dir.appendingPathComponent("audio.m4a"), as: .m4a); print("OK audio.m4a") }
                    catch { print("FEL audio.m4a: \(error)") }
                }
                print("Möte: \(record.title)")
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --test-locate "file.mp3"`: where "importerad från" would take you.
        if let i = args.firstIndex(of: "--test-locate"), i + 1 < args.count {
            Task {
                let url = await SourceLink.locate(MeetingRecord.Source(file: args[i + 1], video: false, importedAt: Date()))
                print("Hittad: \(url?.path ?? "–")")
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --test-names`-like check for imported files' names.
        if args.contains("--test-filenames") {
            for (name, human) in [("Intervju med Anna", true), ("Styrelsemöte oktober", true), ("Riksdagsdebatt", false),
                                  ("holyshitai", false), ("Z2kJBzgKtOa3u-bTcQ3CqQ", false), ("IMG_1234", false),
                                  ("Tavus_-_Introducing_Griffin_the_first_model [2105703934073683968] 1080p", false),
                                  ("2025-12-15 13-15-13", false), ("Ny inspelning 12", false), ("Kundmöte Nordljus - uppstart", true),
                                  ("musecam-1765465253476", false), ("Podd avsnitt 12", true)] {
                let got = MeetingImport.isHumanName(name)
                print("\(got == human ? "OK " : "FEL") \(name) → \(got ? "behålls" : "anteckningarnas rubrik") · visas som \"\(MeetingImport.displayName(name))\"")
            }
            exit(0)
        }
        // `Mindtalk --test-folders`: the folder suggestion on made-up meetings (nothing saved).
        if args.contains("--test-folders") {
            Task { @MainActor in
                let folders = MeetingFolders.shared
                folders.preview(["Kund Nordljus", "Styrelsen", "Möte"])
                let nordljus = folders.sorted.first { $0.name == "Kund Nordljus" }!.id
                let styrelsen = folders.sorted.first { $0.name == "Styrelsen" }!.id
                func meeting(_ title: String, _ names: [String], folder: UUID? = nil, userTitled: Bool = false,
                             summaryTitle: String? = nil) -> MeetingRecord {
                    var r = MeetingRecord(title: title, date: Date(), language: .swedish)
                    r.names = Dictionary(uniqueKeysWithValues: names.enumerated().map { (String($0.offset), $0.element) })
                    r.folder = folder
                    r.userTitled = userTitled
                    r.finished = true
                    if let summaryTitle { r.summary = MeetingSummary(title: summaryTitle, overview: "") }
                    return r
                }
                // You ("Jag") in every meeting; Eva and Olle at Nordljus; Kim in the board.
                let library = [
                    meeting("a", ["Jag", "Eva"], folder: nordljus), meeting("b", ["Jag", "Eva", "Olle"], folder: nordljus),
                    meeting("c", ["Jag", "Olle"], folder: nordljus), meeting("d", ["Jag", "Kim"], folder: styrelsen),
                    meeting("e", ["Jag", "Kim"], folder: styrelsen), meeting("f", ["Jag"]), meeting("g", ["Jag"]),
                ]
                let cases: [(String, MeetingRecord, String?)] = [
                    ("bara du", meeting(MeetingRecord.defaultTitle(for: Date()), ["Jag"], summaryTitle: "Planering"), nil),
                    ("Eva och du", meeting("x", ["Jag", "Eva"], summaryTitle: "Leveransplan"), "Kund Nordljus"),
                    ("Kim", meeting("x", ["Kim", "Jag"], summaryTitle: "Budget"), "Styrelsen"),
                    ("titel med mappnamn", meeting("Nordljus uppföljning", [], userTitled: true, summaryTitle: "Kund Nordljus – status"), "Kund Nordljus"),
                    ("standardtitel 'Möte …'", meeting(MeetingRecord.defaultTitle(for: Date()), [], summaryTitle: nil), nil),
                    ("Eva och Kim", meeting("x", ["Eva", "Kim"], summaryTitle: "Samordning"), nil),
                ]
                for (name, record, expected) in cases {
                    let got = folders.suggestion(for: record, among: library + [record])?.name
                    print("\(got == expected ? "OK " : "FEL") \(name): \(got ?? "–") (väntat \(expected ?? "–"))")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-archive out.png [--dark]`: the list's groups, with made-up meetings.
        if let i = args.firstIndex(of: "--render-archive"), i + 1 < args.count {
            Task { @MainActor in
                let dark = args.contains("--dark")
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let records = ArchivePreview.sample()
                for s in ArchiveSection.sections(records, now: ArchivePreview.now) {
                    print("\(s.kind) \(s.id) \"\(s.title)\" \(s.count) öppen:\(s.openByDefault) \(s.kind == .year ? s.months.map { "\($0.title) \($0.count)" }.joined(separator: ", ") : "")")
                }
                let view = ArchivePreview(records: records).padding(28).frame(width: 720).background(DS.Colors.paper)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-panel out.png [--dark]`: the menu bar panel, with your figures.
        if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
            Task { @MainActor in
                let dark = args.contains("--dark")
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = StatusPanelView(dictation: .shared, stats: .shared, close: {}, flat: true)
                    .padding(20).background(Color(white: dark ? 0.2 : 0.75))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-thoughts out.png [--dark]`: the Tankar page with made-up thoughts.
        if let i = args.firstIndex(of: "--render-thoughts"), i + 1 < args.count {
            Task { @MainActor in
                let dark = args.contains("--dark")
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                func t(_ text: String, _ hoursAgo: Double, done: Bool = false) -> Thought {
                    var x = Thought(text: text); x.date = Date().addingTimeInterval(-hoursAgo * 3600); x.done = done; return x
                }
                Thoughts.shared.preview([
                    t("Ring tillbaka Eva om offerten och kolla budgeten för Q2.", 0.2),
                    t("Idé: visa vem som pratar mest i ett möte.", 3),
                    t("Boka lokal till kickoffen i november.", 26),
                    t("Fråga Kim om styrelsens datum.", 30, done: true),
                ])
                let view = ThoughtsPage(dictation: .shared, scrolls: false).frame(width: 760).background(DS.Colors.paper)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-home out.png [--dark]`: the Hem page with your meetings.
        if let i = args.firstIndex(of: "--render-home"), i + 1 < args.count {
            Task { @MainActor in
                let dark = args.contains("--dark")
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                MeetingStore.shared.loadNow()
                if Thoughts.shared.all.isEmpty {
                    var a = Thought(text: "Ring tillbaka Eva om offerten och kolla budgeten för Q2."); a.date = Date()
                    Thoughts.shared.preview([a])
                }
                let view = VStack(alignment: .leading, spacing: 30) {
                    HomeHero(dictation: .shared, page: .constant(.dictation))
                    HomeShelves(page: .constant(.dictation))
                }
                .padding(28).frame(width: 820).background(DS.Colors.paper)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-import out.png [--dark]`: the import cards and the drop sign.
        if let i = args.firstIndex(of: "--render-import"), i + 1 < args.count {
            Task { @MainActor in
                let dark = args.contains("--dark")
                let f = { (n: String) in URL(fileURLWithPath: "/tmp/\(n)") }
                let view = VStack(alignment: .leading, spacing: 10) {
                    StartCard(session: .shared, voices: .shared, dictation: .shared)
                    ImportCard(job: .init(url: f("Intervju med Anna.m4a"), video: false, folder: nil, stage: .writing, progress: 0.34)) { _ in }
                    ImportCard(job: .init(url: f("Styrelsemöte oktober.mov"), video: true, folder: nil, stage: .waiting)) { _ in }
                    ImportCard(job: .init(url: f("Podd avsnitt 12.mp3"), video: false, folder: nil, stage: .done, progress: 1)) { _ in }
                    ImportCard(job: .init(url: f("anteckningar.pdf"), video: false, folder: nil, stage: .failed)) { _ in }
                    DropSign(folder: nil).frame(height: 360)
                }
                .padding(28)
                .frame(width: 720)
                .background(DS.Colors.paper)
                .environment(\.colorScheme, dark ? .dark : .light)
                NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-folders out.png [--dark]`: the folder row, a meeting's folder
        // tag and the suggestion, with made-up folders (nothing saved).
        if let i = args.firstIndex(of: "--render-folders"), i + 1 < args.count {
            Task { @MainActor in
                NSApplication.shared.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
                let folders = MeetingFolders.shared
                folders.preview(["Kund Nordljus", "Styrelsen", "Veckomöten"])
                folders.selected = folders.sorted.first?.id
                var record = MeetingRecord(title: "Nordljus – uppstart", date: Date(), language: .swedish)
                record.folder = nil
                var tagged = record
                tagged.folder = folders.sorted.first?.id
                let view = VStack(alignment: .leading, spacing: 18) {
                    FolderBar(folders: folders, store: MeetingStore.shared)
                    HStack(spacing: 8) {
                        Text(verbatim: "i dag 13:30 · 52 min").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        FolderTag(record: record)
                        FolderTag(record: tagged)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(DS.Colors.muted)
                        Text("Lägg mötet i \(Text(verbatim: "Kund Nordljus").fontWeight(.semibold))?").font(.system(size: 13))
                        Spacer()
                        Button("Lägg i mappen") {}.buttonStyle(.soft)
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.muted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10).card()
                }
                .padding(28)
                .frame(width: 720)
                .background(DS.Colors.paper)
                .environment(\.colorScheme, args.contains("--dark") ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --render-search out.png "sökord" "fråga"`: the search results and an
        // answer drawn to an image, without a window (the screen may be locked).
        if let i = args.firstIndex(of: "--render-search"), i + 3 < args.count {
            Task { @MainActor in
                NSApplication.shared.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
                MeetingStore.shared.loadNow()
                let library = MeetingLibrary.shared
                library.ask(args[i + 3])
                await library.waitUntilAnswered()
                let view = VStack(alignment: .leading, spacing: 20) {
                    LibraryAnswers(library: library) { _, _ in }
                    SearchResults(matches: MeetingSearch.find(args[i + 2], in: MeetingStore.shared.meetings),
                                  query: args[i + 2]) { _, _ in }
                }
                .padding(28)
                .frame(width: 720)
                .background(DS.Colors.paper)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                    print("Ritad: \(args[i + 1])")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --voice-test`: a voiceprint for every speaker with enough speech in
        // every meeting, and how alike they are — to set the threshold.
        if args.contains("--voice-test") {
            Task { @MainActor in
                MeetingStore.shared.loadNow()
                let memory = VoiceMemory.shared
                memory.prepare()
                for _ in 0..<100 where memory.state == .missing { try? await Task.sleep(for: .milliseconds(100)) }
                guard memory.state == .ready else { print("Modellen: \(memory.state)"); exit(1) }
                var prints: [(label: String, named: String?, print: [Float])] = []
                let t0 = Date()
                for record in MeetingStore.shared.meetings {
                    let url = MeetingStore.audioURL(for: record.id)
                    for speaker in Set(record.words.compactMap(\.speaker)).filter({ $0 >= 0 }).sorted() {
                        guard let p = await VoicePrints.shared.print(of: speaker, in: record.words, audio: url) else { continue }
                        let name = record.names[String(speaker)].flatMap { $0.isEmpty ? nil : $0 }
                        prints.append(("\(record.title.prefix(22)) · \(name ?? "T\(speaker)")", name, p))
                    }
                }
                print(String(format: "%d röstavtryck på %.1f s", prints.count, Date().timeIntervalSince(t0)))
                var same: [Float] = [], other: [Float] = []
                for i in prints.indices { for j in prints.indices where j > i {
                    guard let a = prints[i].named, let b = prints[j].named else { continue }
                    let c = VoiceMemory.cosine(prints[i].print, prints[j].print)
                    (a == b ? { same.append(c) } : { other.append(c) })()
                    print(String(format: "  %@ %.2f  %@ ↔ %@", a == b ? "SAMMA " : "OLIKA ", c, prints[i].label, prints[j].label))
                }}
                print(String(format: "Samma person: %.2f–%.2f · olika: %.2f–%.2f", same.min() ?? 0, same.max() ?? 0,
                             other.min() ?? 0, other.max() ?? 0))
                print("Onamngivna mot namngivna (bästa):")
                for u in prints where u.named == nil {
                    let best = prints.filter { $0.named != nil }.map { ($0.named!, VoiceMemory.cosine(u.print, $0.print)) }
                        .sorted { $0.1 > $1.1 }
                    var byName: [String: Float] = [:]
                    for (n, c) in best where byName[n] == nil { byName[n] = c }
                    let line = byName.sorted { $0.value > $1.value }.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
                    print("  \(u.label): \(line)")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --rewrite-models 20 out.json folder` and `--rewrite-report out.html name=file.json …`
        if let i = args.firstIndex(of: "--rewrite-models"), i + 3 < args.count {
            Task { @MainActor in
                await RewriteCompare.runModel(count: Int(args[i + 1]) ?? 20, folder: URL(fileURLWithPath: args[i + 3]),
                                              out: URL(fileURLWithPath: args[i + 2]))
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--rewrite-report"), i + 2 < args.count {
            let cols = args[(i + 2)...].compactMap { a -> (String, URL)? in
                let p = a.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]), URL(fileURLWithPath: String(p[1]))) : nil
            }
            RewriteCompare.report(columns: cols, out: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // `Mindtalk --rewrite-compare 20 out.html`: written language, Apple against Gemma (RewriteCompare).
        if let i = args.firstIndex(of: "--rewrite-compare"), i + 2 < args.count {
            Task { @MainActor in
                await RewriteCompare.run(count: Int(args[i + 1]) ?? 20, out: URL(fileURLWithPath: args[i + 2]))
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --polish-recent 30`: the latest dictations through the AI polish —
        // before, after and how long — nothing typed or saved.
        if let i = args.firstIndex(of: "--polish-recent") {
            let n = i + 1 < args.count ? Int(args[i + 1]) ?? 30 : 30
            Task { @MainActor in
                let url = SpeechModel.rootDirectory.deletingLastPathComponent().appendingPathComponent("Recent.json")
                struct Item: Decodable { let text: String }
                let items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: url))) ?? []
                print("Apple Intelligence: \(Polisher.status)")
                var times: [Double] = []
                var changed = 0, kept = 0
                for (k, item) in items.prefix(n).enumerated() {
                    // As a dictation goes: the rules first, then the polish.
                    let rules = TextCleanup.apply(item.text, fillers: true, commands: false)
                    let t0 = Date()
                    let polished = await Polisher.shared.polish(rules)
                    let t = Date().timeIntervalSince(t0)
                    times.append(t)
                    let out = polished ?? rules
                    if out != item.text { changed += 1 } else { kept += 1 }
                    print("\n#\(k + 1) (\(String(format: "%.2f", t)) s)\nFÖRE:  \(item.text)" +
                          (rules != item.text ? "\nREGEL: \(rules)" : "") +
                          "\nEFTER: \(out == item.text ? "(oförändrad)" : out)\(polished == nil ? "  [putsning avvisad/ingen]" : "")")
                }
                let sorted = times.sorted()
                if !sorted.isEmpty {
                    print(String(format: "\n%d texter: %d ändrade, %d oförändrade/avvisade · tid median %.2f s, längsta %.2f s",
                                 sorted.count, changed, kept, sorted[sorted.count / 2], sorted.last!))
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --guard-test`: what the AI polish may and may not do to a dictation,
        // and the rules for what the speech model gets wrong.
        if args.contains("--guard-test") {
            let guardCases: [(String, String, Bool)] = [
                ("Jag tryck på att ladda ner gemma", "Jag trycker på att ladda ner gemma", true),
                ("Jag skickar det till hund", "Jag skickar det till hunden", true),
                ("Jag godkänner inte avtalet", "Jag godkänner avtalet", false),
                ("Det kostar tjugo kronor", "Det kostar tjugofem kronor", false),
                ("Sa Anna någonting om mat", "Sa Anna något om mat", false),
                ("Kan du kolla på detta", "Kan du titta på detta", false),
                ("Vi ses på tisdag, nej jag menar onsdag", "Vi ses på onsdag", true),
                ("Blir det fel? Eller är det jag som läser fel?", "Blir det fel eller är det jag som läser fel?", false),
                ("Den är bättre så vi borde ha den", "Den är bättre, så vi borde ha den", true),
            ]
            let ruleCases: [(String, String)] = [
                ("Erik vill bygga med kubeh.", "Erik vill bygga med kub."),
                ("Fick detta svar av. Erik?", "Fick detta svar av Erik?"),
                ("Den låg längst ner där i. Fönstret där man pratar.", "Den låg längst ner där i fönstret där man pratar."),
                ("Det var det jag tänkte på. Sen gick vi hem.", "Det var det jag tänkte på. Sen gick vi hem."),
                ("Yeah, det är okej, meh.", "Yeah, det är okej, meh."),
            ]
            let nameCases: [(String, String?)] = [
                ("Hej, jag heter Erik och jobbar med försäljningen.", "Erik"),
                ("Hej allihop, det är Anna här.", "Anna"),
                ("Det är bra, jag är med.", nil),
                ("Och jag är Sara Lind.", "Sara Lind"),
                ("Hi everyone, I'm Tom.", "Tom"),
                ("Och så är det jag här också, hej.", nil),
            ]
            var failed = 0
            for (said, want) in nameCases where VoiceScanner.spokenName(in: said) != want {
                failed += 1; print("FEL namn: \(said) → \(VoiceScanner.spokenName(in: said) ?? "–")")
            }
            for (before, after, want) in guardCases where PolishGuard.accepts(after, as: before) != want {
                failed += 1; print("FEL spärr: \(before) → \(after)")
            }
            for (input, want) in ruleCases {
                let got = TextCleanup.apply(input, fillers: true, commands: true)
                if got != want { failed += 1; print("FEL regel: \(input) → \(got)") }
            }
            print(failed == 0 ? "Polish guard, rules and names self-test passed (\(guardCases.count + ruleCases.count + nameCases.count) cases)." : "\(failed) fel")
            exit(failed == 0 ? 0 : 1)
        }
        // `Mindtalk --gemma-download`: fetches Gemma 4 without the window, printing how
        // far it is — continuing an earlier try. Stop it with Ctrl-C to test that.
        if args.contains("--gemma-download") {
            Task { @MainActor in
                print("Kvar att hämta: \(BetterNotes.remainingBytes / 1_000_000) MB")
                BetterNotes.shared.download()
                let t0 = Date()
                while case .downloading(let p) = BetterNotes.shared.state {
                    print(String(format: "%5.1f %%  (%.0f s)", p * 100, Date().timeIntervalSince(t0)))
                    try? await Task.sleep(for: .seconds(5))
                }
                print("Klart: \(BetterNotes.shared.state)")
                exit(0)
            }
            RunLoop.main.run()
        }
        // `Mindtalk --notes "fråga"`: notes and an answer for the newest meeting.
        if let i = args.firstIndex(of: "--notes"), i + 1 < args.count {
            Task {
                await MeetingNotes.selfTest(question: args[i + 1])
                exit(0)
            }
            RunLoop.main.run()
        }
        // `--auto-meeting [--round]` (with `--fake-mic fil`): starts a meeting by itself once the window is up.
        if args.contains("--auto-meeting") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Self.showWindow(page: .meetings)
                MeetingSession.shared.start(introducing: args.contains("--round"))
                print("[auto] möte startat, runda: \(MeetingSession.shared.introducing), fel: \(MeetingSession.shared.lastError ?? "inget")")
                // `--continue-from s [--continue-limit s]`: once it's written, the meeting is
                // continued with the file from there on — then what came of it, and quit.
                if let from = MeetingSession.argSeconds("--continue-from") {
                    Task { @MainActor in
                        let session = MeetingSession.shared
                        while session.finished == nil { try? await Task.sleep(for: .milliseconds(300)) }
                        guard let id = session.finished,
                              let first = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                        let boundary = first.duration
                        let firstSpeakers = Set(first.words.compactMap(\.speaker))
                        print("[test] del 1: \(Int(boundary)) s, \(first.words.count) ord, talare \(firstSpeakers.sorted())")
                        session.fakeRange = (from, MeetingSession.argSeconds("--continue-limit"))
                        session.continueMeeting(id)
                        print("[test] fortsätter: \(session.isRecording), fel: \(session.lastError ?? "inget")")
                        while session.finished == id || session.isBusy { try? await Task.sleep(for: .milliseconds(300)) }
                        while session.finished != id { try? await Task.sleep(for: .milliseconds(300)) }
                        guard let done = MeetingStore.shared.meetings.first(where: { $0.id == id }) else { return }
                        let url = MeetingStore.audioURL(for: id)
                        let file = try? AVAudioFile(forReading: url)
                        let seconds = Double(file?.length ?? 0) / 16_000
                        let more = FileManager.default.fileExists(atPath: MeetingStore.continuationURL(for: id).path)
                        print("[test] klart: längd \(String(format: "%.1f", done.duration)) s, ljudfil \(String(format: "%.1f", seconds)) s, kvar att foga: \(more), genomlyssnat \(done.refined), klart \(done.finished)")
                        let before = done.words.filter { $0.end <= boundary }, after = done.words.filter { $0.start >= boundary }
                        print("[test] ord före gränsen \(before.count) (var \(first.words.count)), efter \(after.count)")
                        print("[test] talare före \(Set(before.compactMap(\.speaker)).sorted()), efter \(Set(after.compactMap(\.speaker)).sorted())")
                        let sorted = zip(done.words, done.words.dropFirst()).allSatisfy { $0.start <= $1.start + 0.01 }
                        print("[test] tiderna i ordning: \(sorted), sista ordet slutar \(String(format: "%.1f", done.words.last?.end ?? 0)) s")
                        let near = done.words.filter { abs($0.start - boundary) < 12 }
                        print("[test] kring gränsen: " + near.map { "\($0.text)[\($0.speaker.map(String.init) ?? "-")]" }.joined(separator: " "))
                        exit(0)
                    }
                }
                // `--in-panel`: the meeting in its panel, as when started from the menu bar.
                if args.contains("--in-panel") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MeetingPanel.shared.collapse() }
                }
            }
        }
        if let i = args.firstIndex(of: "--relisten"), i + 1 < args.count {
            Task { @MainActor in
                await MeetingSession.shared.relistenTest(title: args[i + 1])
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--meeting"), i + 1 < args.count {
            let model = args.firstIndex(of: "--model").flatMap { j in
                j + 1 < args.count ? SpeechModel(rawValue: args[j + 1]) : nil
            } ?? .swedish
            let speed = args.firstIndex(of: "--speed").flatMap { j in j + 1 < args.count ? Double(args[j + 1]) : nil } ?? 1
            Task {
                // `--voices-from "titel,titel"`: knowing the voices named in those meetings.
                if let v = args.firstIndex(of: "--voices-from"), v + 1 < args.count {
                    await VoiceMemory.shared.test(learningFrom: args[v + 1].split(separator: ",").map(String.init))
                }
                await MeetingSession.shared.simulate(file: URL(fileURLWithPath: args[i + 1]), language: model, speed: speed)
                exit(0)
            }
            RunLoop.main.run()
        }
        #endif

        // Self-test: `Mindtalk --install multilingual` downloads, verifies and installs a model.
        if let i = args.firstIndex(of: "--install"), i + 1 < args.count, let model = SpeechModel(rawValue: args[i + 1]) {
            Task {
                do {
                    let t0 = Date()
                    var last = -1
                    try await model.install { p in
                        let pct = Int(p * 100)
                        if pct / 10 != last / 10 { last = pct; print("\(pct) %") }
                    }
                    print(String(format: "Installerad i %@ (%.0f s)", model.ownDirectory.path, Date().timeIntervalSince(t0)))
                    exit(0)
                } catch {
                    print("Fel: \(error.localizedDescription)")
                    exit(1)
                }
            }
            RunLoop.main.run()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let statusPanel = StatusPanel()
    private var window: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let dictation = Dictation.shared

    func applicationWillTerminate(_ notification: Notification) {
        MediaControl.shared.restoreNow()
        MeetingSession.shared.saveBeforeQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defer {
            launched = true
            if !pendingOpen.isEmpty {
                let files = pendingOpen
                pendingOpen = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.application(NSApp, open: files) }
            }
        }
        // From the disk image or Downloads: offer to move to Applications first.
        if AppMover.offerIfNeeded() { return }
        MediaControl.shared.restoreAfterCrash()
        SpeechModel.removeLeftoverDownloads()
        Updates.shared.start()
        // The voice models, ready before the first meeting (after an update macOS can
        // take a minute to prepare them — better now, quietly, than when you press start).
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { VoiceModels.warmUp() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Left or right click: the panel — one menu, nothing hidden.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NSApp.mainMenu = Self.mainMenu()
        AppPrefs.shared.apply()
        Self.updateDockPolicy()

        dictation.$phase.combineLatest(dictation.$model)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        // Picking a shortcut ends when you turn to another app — left waiting, it
        // would swallow a key there and take the next modifier as your shortcut.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.dictation.stopPickingKey() }
            .store(in: &cancellables)
        // A meeting lives in its own panel beside your work, and in the menu bar —
        // a red dot and the time — wherever you are. Put away, a notification says
        // when it's written.
        MeetingPanel.shared.watch()
        // Recordings kept no longer than you chose (Inställningar → Möten).
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { MeetingStore.shared.applyRetention() }
        UNUserNotificationCenter.current().delegate = self
        MeetingSession.shared.$phase.combineLatest(MeetingSession.shared.$warning.removeDuplicates(),
                                                   MeetingSession.shared.$pausedAt.map { $0 != nil }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                DispatchQueue.main.async { self?.statusPanel.refit() }
            }
            .store(in: &cancellables)

        // Keep the panel's size in step with what's in it.
        dictation.$recent.combineLatest(dictation.$phase, dictation.$model)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.statusPanel.refit() } }
            .store(in: &cancellables)

        dictation.start()
        KeyListener.shared.onMeetingChord = { [weak self] in self?.toggleMeeting() }
        Vocabulary.shared.prepareListener()
        #if DEBUG
        if CommandLine.arguments.contains("--simulate-keys") { return simulateKeys() }
        // Simulates a 3-second dictation against whatever is playing.
        if CommandLine.arguments.contains("--media-test") {
            Task { @MainActor in
                func show(_ label: String) { print(label, MediaControl.playingProcesses().map(\.bundleID)) }
                show("före:")
                MediaControl.shared.begin()
                for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(500)); show("  dikterar:") }
                MediaControl.shared.end()
                for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(500)); show("  efter:") }
                exit(0)
            }
            return
        }
        // Download test: log every two seconds what the introduction shows.
        if Demo.autoDownload {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [self] _ in
                MainActor.assumeIsolated {
                    let parts = SpeechModel.allCases.map { m -> String in
                        if let p = dictation.downloads[m] { return "\(m.rawValue) \(Int(p * 100))%" }
                        if let e = dictation.downloadErrors[m] { return "\(m.rawValue) FEL: \(e)" }
                        return "\(m.rawValue) \(m.isInstalled ? "klar" : "–")"
                    }
                    print("\(Int(Date().timeIntervalSince1970) % 100000) \(parts.joined(separator: " · ")) · aktiv: \(dictation.engine.rawValue) \(dictation.model)")
                }
            }
        }
        // "Visa introduktionen" from Settings, as the button does it.
        if CommandLine.arguments.contains("--test-intro") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                showWindow()
                if CommandLine.arguments.contains("--maximized"), let screen = window?.screen {
                    window?.setFrame(screen.visibleFrame, display: true)
                }
                if CommandLine.arguments.contains("--fullscreen") { window?.toggleFullScreen(nil) }
                NotificationCenter.default.post(name: .showPage, object: Page.settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--fullscreen") ? 2.5 : 1.2)) {
                    AppDelegate.showIntroduction()
                    print("Under introduktionen – huvudfönstret synligt: \(self.window?.isVisible == true)")
                    if CommandLine.arguments.contains("--then-close") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.onboardingWindow?.performClose(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                print("Efter stängning – huvudfönstret synligt: \(self.window?.isVisible == true)")
                                exit(0)
                            }
                        }
                    }
                }
            }
            return
        }
        if CommandLine.arguments.contains("--show-about") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppDelegate.showAbout() }
            return
        }
        // README screenshots: an onboarding step, or the dictation HUD.
        if Demo.onboardingStep != nil { showOnboarding(); return }
        if CommandLine.arguments.contains("--demo-meeting") {
            MeetingSession.shared.showDemo(finished: CommandLine.arguments.contains("--demo-finished"))
        }
        if Demo.hud {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.dictation.demoRecording() }
            return
        }
        // Opens the panel on launch, for screenshots.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                if let button = statusItem.button { statusPanel.show(from: button) }
            }
            return
        }
        #endif

        if !Settings.didOnboard {
            // Start at login from the first launch — installed in /Applications, that is.
            if Bundle.main.bundlePath.hasPrefix("/Applications") { try? SMAppService.mainApp.register() }
            showOnboarding()
        } else if let raw = UserDefaults.standard.string(forKey: "reopenPage"), let page = Page(rawValue: raw) {
            UserDefaults.standard.removeObject(forKey: "reopenPage")
            MainView.startPage = page
            showWindow()
        } else if dictation.needsSetup {
            showWindow()
        }
    }

    /// Recording: a red dot and the elapsed time. Finishing: the "working" icon.
    private func showMeeting(_ meeting: MeetingSession) {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        if meeting.isRecording {
            // Something is wrong with the recording: say so here too — the window may be closed.
            let dot = meeting.isPaused
                ? NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: String(localized: "Pausat"))?
                    .withSymbolConfiguration(.init(paletteColors: [.white, .systemGray]))
                : meeting.warning == nil
                ? NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: String(localized: "Spelar in"))?
                    .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
                : NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                          accessibilityDescription: String(localized: "Något är fel med inspelningen"))?
                    .withSymbolConfiguration(.init(paletteColors: [.black, .systemYellow]))
            dot?.isTemplate = false
            button.image = dot
            let tick = { [weak self] in
                guard MeetingSession.shared.startedAt != nil else { return }
                self?.statusItem.button?.title = " " + MeetingView.duration(MeetingSession.shared.clock(at: Date()))
            }
            tick()
            if meetingClock == nil {
                meetingClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated { tick() }
                }
            }
        } else {
            meetingClock?.invalidate()
            meetingClock = nil
            button.title = ""
            statusItem.length = NSStatusItem.squareLength
            let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Mindtalk")
            image?.isTemplate = true
            button.image = image
        }
    }

    // MARK: Quitting

    /// Mid-meeting, quitting asks first — and finishes the meeting before it goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let meeting = MeetingSession.shared
        if !meeting.isBusy, MeetingImport.shared.busy {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "En fil skrivs ned")
            alert.informativeText = String(localized: "Avslutar du nu blir den inte klar – du kan importera den igen sedan.")
            alert.addButton(withTitle: String(localized: "Avsluta ändå"))
            alert.addButton(withTitle: String(localized: "Vänta"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        guard meeting.isBusy else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Ett möte spelas in")
        alert.informativeText = String(localized: "Mindtalk gör klart mötet innan det avslutas, så att texten blir färdig.")
        alert.addButton(withTitle: String(localized: "Avsluta mötet och Mindtalk"))
        alert.addButton(withTitle: String(localized: "Fortsätt spela in"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Self.isQuitting = true
        if meeting.isRecording { meeting.stop() }
        Task { @MainActor in
            // The final pass, then quit — at most two minutes.
            for _ in 0..<240 where MeetingSession.shared.isBusy { try? await Task.sleep(for: .milliseconds(500)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func toggleMeeting() {
        let meeting = MeetingSession.shared
        if meeting.isRecording {
            // Asks once — in the panel, or the large window if that's where the meeting is.
            if !meeting.requestStop(), !Self.mainWindowVisible { MeetingPanel.shared.show() }
        } else if meeting.phase == .idle {
            Self.startMeeting()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingWindow?.isVisible == true { showOnboarding() } else { showWindow() }
        return false
    }

    // MARK: Status item

    private var meetingClock: Timer?

    private func updateIcon() {
        let meeting = MeetingSession.shared
        guard !meeting.isBusy else { return showMeeting(meeting) }
        meetingClock?.invalidate()
        meetingClock = nil
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.title = ""
        let symbol: String
        switch dictation.phase {
        case .recording: symbol = "waveform.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .failed: symbol = "exclamationmark.circle"
        case .copied: symbol = "doc.on.clipboard"
        case .saved: symbol = "lightbulb"
        case .idle:
            if case .downloading = dictation.model { symbol = "arrow.down.circle" }
            else { statusItem.button?.image = Mark.menuBarImage; return }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mindtalk")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    #if DEBUG
    /// Drives the key logic with scripted presses (no event tap, no paste) and
    /// prints every state change — for checking hold / tap / double-tap / space.
    private func simulateKeys() {
        TextInserter.dryRun = true
        let keys = KeyListener.shared
        var cancellables = Set<AnyCancellable>()
        dictation.$phase.removeDuplicates().sink { print("  fas: \($0)") }.store(in: &cancellables)
        dictation.$handsFree.removeDuplicates().filter { $0 }.sink { _ in print("  låst") }.store(in: &cancellables)
        let originalMode = dictation.mode
        Task { @MainActor in
            while dictation.model != .ready { try? await Task.sleep(for: .milliseconds(200)) }
            func step(_ title: String) async { print("== \(title)"); try? await Task.sleep(for: .milliseconds(300)) }
            @MainActor func press(_ s: Double) async { keys.onPress?(); try? await Task.sleep(for: .seconds(s)); keys.onRelease?() }
            func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            for mode in DictationMode.allCases {
                dictation.setMode(mode)
                print("##### Läge: \(mode.title)")
                await step("A: håll in 1,2 s"); await press(1.2); await pause(1.5)
                await step("B: enkeltryck"); await press(0.08); await pause(1.2)
                await step("C: dubbeltryck, vänta 1,5 s, tryck"); await press(0.08); await pause(0.12); await press(0.08)
                await pause(1.5); await press(0.08); await pause(1.5)
                await step("D: håll in + mellanslag, släpp, vänta, tryck")
                keys.onPress?(); await pause(0.5)
                print("  mellanslag slukat: \(keys.onSpaceWhileHeld?() ?? false)")
                await pause(0.3); keys.onRelease?(); await pause(1.0); await press(0.08); await pause(1.5)
                if dictation.phase != .idle { print("  (städar)"); _ = keys.onEscape?() }
            }
            _ = cancellables
            dictation.setMode(originalMode)
            print("== klart"); exit(0)
        }
    }
    #endif

    // MARK: Menu bar (while the window is open)

    /// The standard menus — without an Edit menu, ⌘C/⌘V/⌘A do nothing in our own text fields.
    private static func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let title = String(localized: String.LocalizationValue(title))
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }
        let main = NSMenu()
        main.addItem(submenu("Mindtalk", [
            item("Om Mindtalk", #selector(AppDelegate.menuAbout)),
            {
                let check = item("Sök efter uppdateringar…", #selector(Updates.checkNow))
                check.target = Updates.shared
                return check
            }(),
            .separator(),
            item("Inställningar…", #selector(AppDelegate.menuSettings), ","),
            .separator(),
            item("Göm Mindtalk", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Avsluta Mindtalk", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Redigera", [
            item("Ångra", Selector(("undo:")), "z"),
            item("Gör om", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Klipp ut", #selector(NSText.cut(_:)), "x"),
            item("Kopiera", #selector(NSText.copy(_:)), "c"),
            item("Klistra in", #selector(NSText.paste(_:)), "v"),
            item("Markera allt", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("Möte", [
            item("Starta möte", #selector(AppDelegate.toggleMeeting), "r", [.command, .shift]),
            item("Importera fil…", #selector(AppDelegate.menuImport), "o"),
        ]))
        main.addItem(submenu("Visa", [
            item("Hem", #selector(AppDelegate.menuDictation), "1"),
            item("Diktering", #selector(AppDelegate.menuRecent), "2"),
            item("Möten", #selector(AppDelegate.menuMeetings), "3"),
            item("Tankar", #selector(AppDelegate.menuThoughts), "4"),
            item("Ordlista", #selector(AppDelegate.menuVocabulary), "5"),
        ]))
        let window = submenu("Fönster", [
            item("Minimera", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zooma", #selector(NSWindow.performZoom(_:))),
            item("Stäng", #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    // MARK: Menu actions

    @objc func menuAbout() { Self.showAbout() }
    /// ⌘O: a sound or video file to transcribe — into the folder chosen on the Möten page.
    @objc func menuImport() {
        MeetingsPage.lastOpen = nil
        Self.showWindow(page: .meetings)
        MeetingImport.shared.choose(folder: MeetingFolders.shared.selected)
    }

    /// "Öppna med › Mindtalk", or a file dropped on the app: transcribed as a meeting.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { MeetingImport.canImport($0) }
        guard !files.isEmpty else { return }
        // Opened before Mindtalk had started: once it has.
        guard launched else { pendingOpen += files; return }
        MeetingsPage.lastOpen = nil
        Self.showWindow(page: .meetings)
        MeetingImport.shared.add(files, folder: MeetingFolders.shared.selected)
    }
    private var launched = false
    private var pendingOpen: [URL] = []
    @objc func menuSettings() { Self.showWindow(page: .settings) }
    @objc func menuDictation() { Self.showWindow(page: .dictation) }
    @objc func menuMeetings() { Self.showWindow(page: .meetings) }
    @objc func menuRecent() { Self.showWindow(page: .recent) }
    @objc func menuThoughts() { Self.showWindow(page: .thoughts) }
    @objc func menuVocabulary() { Self.showWindow(page: .vocabulary) }

    // MARK: Relaunch

    /// Quits and starts again (to switch the app's language), reopening the window on `page`.
    static func relaunch(showing page: Page) {
        guard !MeetingSession.shared.isBusy else { return NSSound.beep() }
        UserDefaults.standard.set(page.rawValue, forKey: "reopenPage")
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Onboarding

    static var isOnboarding: Bool {
        (NSApp.delegate as? AppDelegate)?.onboardingWindow?.isVisible == true
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: OnboardingView(dictation: dictation) { [weak self] in
                self?.onboardingWindow?.close()
            })
            window.setContentSize(NSSize(width: 760, height: 640))
            window.center()
            // No zoom-in from macOS: it would play on top of the introduction's
            // own entrance. The window simply appears, solid and still.
            window.animationBehavior = .none
            // Its own window, never a tab of the main one, and shown in the space
            // you're in — also a full-screen one — so macOS doesn't slide between spaces.
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
            onboardingWindow = window
        }
        windowOpen = true
        Self.updateDockPolicy()
        bringForward(onboardingWindow)
    }


    // MARK: Main window

    private static func printCleanup(of raw: String) async {
        let rules = TextCleanup.apply(raw, fillers: true, commands: true)
        let cleaned = await Vocabulary.shared.reapply(rules)       // your list, nothing counted
        print("Regler: \(rules.debugDescription)")
        if cleaned != rules { print("Ordlista: \(cleaned.debugDescription)") }
        let t0 = Date()
        let polished = await Polisher.shared.polish(cleaned)
        print(String(format: "Putsad: %@ (%.2f s)", polished?.debugDescription ?? "– (behåller reglernas text)", Date().timeIntervalSince(t0)))
    }

    /// Starts a meeting — with the round ("Vem är här?"), which can be skipped; after
    /// it, the meeting goes on in its panel. If it can't start (a model or a
    /// permission is missing), the Meetings page says why.
    static func startMeeting(introducing: Bool = true) {
        let meeting = MeetingSession.shared
        // From the Möten page (⇧⌘R in the window): into the folder chosen there. From
        // the menu bar or the shortcut elsewhere, in none.
        let folder = mainWindowIsKey ? MeetingFolders.shared.selected : nil
        // With the round: the window comes forward first — while your click still counts,
        // before the microphone takes its moment to start — so it lands in front of the
        // app you were in, not behind it. (Afterwards the meeting goes to the panel.)
        if introducing, VoiceModels.isInstalled, !mainWindowIsKey {
            MeetingPanel.shared.startedElsewhere = true
            showWindow(page: .meetings)
        }
        if VoiceModels.isInstalled { meeting.start(introducing: introducing, folder: folder) }
        if !meeting.isRecording {
            MeetingPanel.shared.startedElsewhere = false
            showWindow(page: .meetings)
            return
        }
        // Without the round, from the menu bar: the panel shows the meeting, and the
        // keyboard goes back to the app you were in rather than to Mindtalk with no window.
        if !introducing, !mainWindowVisible { NSApp.deactivate() }
    }

    /// Goes on with a finished meeting — in the window when it's open, in the panel
    /// otherwise, as a meeting started without the round.
    static func continueMeeting(_ id: UUID) {
        let meeting = MeetingSession.shared
        meeting.continueMeeting(id)
        // It couldn't: the meeting's page says why.
        if !meeting.isRecording {
            MeetingsPage.lastOpen = id
            showWindow(page: .meetings)
        }
    }

    static var mainWindowVisible: Bool { (NSApp.delegate as? AppDelegate)?.window?.isVisible == true }
    static var mainWindowIsKey: Bool { (NSApp.delegate as? AppDelegate)?.window?.isKeyWindow == true && mainWindowVisible }
    /// Quitting with a meeting running: nothing opens on the way out.
    private(set) static var isQuitting = false

    static func hideMainWindow() { (NSApp.delegate as? AppDelegate)?.window?.close() }

    static func showWindow(page: Page? = nil) {
        if let page { MainView.startPage = page }
        (NSApp.delegate as? AppDelegate)?.showWindow()
        if let page { NotificationCenter.default.post(name: .showPage, object: page) }
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        statusPanel.toggle(from: sender)
    }

    /// Settings, scrolled to "Om Mindtalk" (credits and licences).
    static func showAbout() {
        SettingsPage.jumpToAbout = true
        showWindow(page: .settings)
        NotificationCenter.default.post(name: .showAbout, object: nil)
    }

    /// The introduction again. With the main window open it plays inside that
    /// window — no second window, so nothing for macOS to animate or rearrange;
    /// otherwise in its own window, as on first launch.
    static func showIntroduction() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        if let window = delegate.window, window.isVisible {
            NotificationCenter.default.post(name: .showIntroduction, object: nil)
        } else {
            delegate.showOnboarding()
        }
    }

    func closeStatusPanel(immediately: Bool = false) { statusPanel.close(immediately: immediately) }

    /// Closes the menu bar panel if it's open; true if it was.
    static func closeStatusPanelIfShown() -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate, delegate.statusPanel.isShown else { return false }
        delegate.statusPanel.close()
        return true
    }

    /// While the window is open Mindtalk is a regular app (Dock, ⌘-Tab); closed,
    /// it lives in the menu bar only.
    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.tabbingMode = .disallowed
            window.contentViewController = NSHostingController(rootView: MainView(dictation: dictation, prefs: .shared))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1060, height: 700))
            #if DEBUG
            // Screenshots: the same size every time, and your own window size left alone.
            if Demo.on { window.setContentSize(NSSize(width: 1040, height: 700)); window.center() }
            else { window.setFrameAutosaveName("MindtalkMain") }
            #else
            window.setFrameAutosaveName("MindtalkMain")
            #endif
            if !window.setFrameUsingName("MindtalkMain") { window.center() }
            self.window = window
        } else if window?.isVisible != true {
            // Shown again: text that changed while it was closed is drawn afresh.
            WindowEpoch.shared.reopened()
        }
        windowOpen = true
        Self.updateDockPolicy()
        bringForward(window)
        // Nothing focused on open — otherwise the "Prova" box grabs focus and scrolls the page.
        window?.makeFirstResponder(nil)
    }

    /// Shows a window in front and makes Mindtalk the active app, so the window
    /// is key — coloured traffic lights, keyboard focus. Switching from menu bar
    /// app to Dock app has to settle first, or macOS turns the activation down.
    private func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        // Asked at once, while the click that asked for it still counts.
        NSApp.activate()
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // Once more a moment later if macOS hadn't let us in yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !NSApp.isActive || !window.isKeyWindow else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async { MeetingPanel.shared.openFromNotification(info); completionHandler() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func windowWillClose(_ notification: Notification) {
        dictation.stopPickingKey()
        // The meeting carries on in its panel when its window goes.
        if (notification.object as? NSWindow) === window { MeetingPanel.shared.mainWindowClosed() }
        if (notification.object as? NSWindow) === onboardingWindow {
            // Closing the introduction — however it's closed — means it's done.
            Settings.didOnboard = true
            onboardingWindow = nil
        }
        windowOpen = [window, onboardingWindow].contains { w in
            w != nil && w !== (notification.object as? NSWindow) && w?.isVisible == true
        }
        Self.updateDockPolicy()
    }

    private var windowOpen = false

    /// In the Dock while the window is open, or always if the user wants it there.
    static func updateDockPolicy() {
        let open = (NSApp.delegate as? AppDelegate)?.windowOpen ?? false
        NSApp.setActivationPolicy(open || Settings.showInDock ? .regular : .accessory)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// "Starta möte" becomes "Avsluta mötet" while one is recorded.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleMeeting) else { return true }
        let meeting = MeetingSession.shared
        item.title = meeting.isRecording ? String(localized: "Avsluta mötet") : String(localized: "Starta möte")
        return meeting.isRecording || (meeting.phase == .idle && Dictation.shared.phase == .idle)
    }
}
