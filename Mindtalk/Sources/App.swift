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
        // `Mindtalk --render-search out.png "sökord" "fråga"`: the search results and an
        // answer drawn to an image, without a window (the screen may be locked).
        if let i = args.firstIndex(of: "--render-search"), i + 3 < args.count {
            Task { @MainActor in
                NSApplication.shared.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
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
                let memory = VoiceMemory.shared
                memory.prepare()
                while case .downloading = memory.state { try? await Task.sleep(for: .milliseconds(300)) }
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
                ("Sa Nelly någonting om mat", "Sa Nelly något om mat", false),
                ("Kan du kolla på detta", "Kan du titta på detta", false),
                ("Vi ses på tisdag, nej jag menar onsdag", "Vi ses på onsdag", true),
                ("Blir det fel? Eller är det jag som läser fel?", "Blir det fel eller är det jag som läser fel?", false),
                ("Den är bättre så vi borde ha den", "Den är bättre, så vi borde ha den", true),
            ]
            let ruleCases: [(String, String)] = [
                ("Johan vill bygga med kubeh.", "Johan vill bygga med kub."),
                ("Fick detta svar av. Peter?", "Fick detta svar av Peter?"),
                ("Den låg längst ner där i. Fönstret där man pratar.", "Den låg längst ner där i fönstret där man pratar."),
                ("Det var det jag tänkte på. Sen gick vi hem.", "Det var det jag tänkte på. Sen gick vi hem."),
                ("Yeah, det är okej, meh.", "Yeah, det är okej, meh."),
            ]
            var failed = 0
            for (before, after, want) in guardCases where PolishGuard.accepts(after, as: before) != want {
                failed += 1; print("FEL spärr: \(before) → \(after)")
            }
            for (input, want) in ruleCases {
                let got = TextCleanup.apply(input, fillers: true, commands: true)
                if got != want { failed += 1; print("FEL regel: \(input) → \(got)") }
            }
            print(failed == 0 ? "Polish guard and rules self-test passed (\(guardCases.count + ruleCases.count) cases)." : "\(failed) fel")
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
        // From the disk image or Downloads: offer to move to Applications first.
        if AppMover.offerIfNeeded() { return }
        MediaControl.shared.restoreAfterCrash()
        SpeechModel.removeLeftoverDownloads()
        Updates.shared.start()
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
        MeetingSession.shared.$phase.combineLatest(MeetingSession.shared.$warning.removeDuplicates())
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
            let dot = meeting.warning == nil
                ? NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: String(localized: "Spelar in"))?
                    .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
                : NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                          accessibilityDescription: String(localized: "Mötet behöver tillsyn"))?
                    .withSymbolConfiguration(.init(paletteColors: [.black, .systemYellow]))
            dot?.isTemplate = false
            button.image = dot
            let tick = { [weak self] in
                guard let start = MeetingSession.shared.startedAt else { return }
                self?.statusItem.button?.title = " " + MeetingView.duration(Date().timeIntervalSince(start))
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
        ]))
        main.addItem(submenu("Visa", [
            item("Diktering", #selector(AppDelegate.menuDictation), "1"),
            item("Möten", #selector(AppDelegate.menuMeetings), "2"),
            item("Senaste", #selector(AppDelegate.menuRecent), "3"),
            item("Ordlista", #selector(AppDelegate.menuVocabulary), "4"),
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
    @objc func menuSettings() { Self.showWindow(page: .settings) }
    @objc func menuDictation() { Self.showWindow(page: .dictation) }
    @objc func menuMeetings() { Self.showWindow(page: .meetings) }
    @objc func menuRecent() { Self.showWindow(page: .recent) }
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

    /// Starts a meeting — it opens in its panel. If it can't start (a model or a
    /// permission is missing), the Meetings page says why.
    static func startMeeting() {
        let meeting = MeetingSession.shared
        if VoiceModels.isInstalled { meeting.start() }
        if !meeting.isRecording { showWindow(page: .meetings); return }
        // Started from the menu bar: the panel shows it, and the keyboard goes back to
        // the app you were in rather than to Mindtalk with no window.
        if !mainWindowVisible { NSApp.deactivate() }
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

    func closeStatusPanel() { statusPanel.close() }

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
            window.setContentSize(NSSize(width: 960, height: 680))
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
