#if DEBUG
import AppKit
import SwiftUI

// MARK: - `Mindtalk --render-window out.png --page settings [--section language] [--dark] [--size 1000x620]`
//
// The whole main window's content, the tab bar and the page, as the window draws it
// (scroll views and all), with the traffic lights where macOS puts them, so the
// layout can be judged. Pages: home, dictation, meetings, thoughts, vocabulary,
// settings. Nothing is saved, no permission is asked for and no store is loaded; the
// window is never on screen.
//   --setup        Hem as before anything is allowed (microphone, Hjälpmedel)
//   --asked        … and Tillåt for Hjälpmedel already pressed
//   --ready        everything allowed, the speech model ready and the start card not preparing
//   --demo         made-up meetings, thoughts, folders and an MCP log, in memory only
//                  (Demo.on gives the dictations and the statistics); the greeting
//                  says a made-up name
//   --open-meeting with --demo: Möten showing the demo meeting, its summary open
//   --show-folder "Kunder"  with --demo: Möten's list in that folder
//   --find-query "ord"  with --open-meeting: ⌘F open in the meeting, that searched for
//   --meeting-state silence|latecomer|manyvoices|whoareyou|paused|scrolled: a meeting
//                  being recorded, at that moment (scrolled: read back, "Till det senaste");
//                  ended: recorded, then ended a second later, the finished meeting shown;
//                  voiceconsent: the start card asking about the voices
//   --voices-off   "Kom ihåg rösterna" as for someone who never chose (off), in memory only
//   --models-ready with --ready: the start card as if the meeting models were downloaded
//   --tried        with --open-meeting: the summary just rewritten by Gemma 4 E4B, picked
//                  for this meeting, and "Använd … i alla möten?" under its foot

@MainActor
enum WindowRender {
    static func run(out: String, args: [String]) async {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let dark = args.contains("--dark")
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var size = CGSize(width: 1000, height: 620)
        if let text = value("--size") {
            let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        let pages: [String: Page] = ["home": .dictation, "dictation": .recent, "meetings": .meetings,
                                     "thoughts": .thoughts, "vocabulary": .vocabulary, "settings": .settings]
        MainView.startPage = value("--page").flatMap { pages[$0] } ?? .dictation
        MainView.rendering = true
        SettingsSection.preview = value("--section").flatMap(SettingsSection.init(rawValue:)) ?? .general
        // `--anchor summaries`: Settings scrolled to that card, as a link to it does.
        SettingsPage.pendingAnchor = value("--anchor").flatMap(SettingsAnchor.init(rawValue:))
        if Demo.on { WindowDemo.fill(openMeeting: args.contains("--open-meeting")) }
        if args.contains("--tried"), Demo.on, var first = MeetingStore.shared.meetings.first, var summary = first.summary {
            summary.writer = NotesModel.small.name
            first.summary = summary
            MeetingStore.shared.replaceAll([first] + MeetingStore.shared.meetings.dropFirst())
            MeetingNotes.shared.previewTried(first.id, .gemma(.small))
        }
        // In memory only: a render never writes a setting (Settings.previewing).
        if args.contains("--voices-off") { VoiceMemory.shared.enabled = false }
        if let state = value("--meeting-state") { MeetingSession.shared.preview(state: state) }
        if args.contains("--setup") || args.contains("--asked") {
            Dictation.shared.preview(mic: false, accessibility: false, asked: args.contains("--asked"))
        } else if args.contains("--ready") {
            Dictation.shared.preview(mic: true, accessibility: true, asked: false, model: .ready)
            // Möten's start card as ready: the voices counted as warm, nothing loaded.
            MeetingSession.previewPreparing = false
        }

        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -40_000, y: -40_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainView(dictation: .shared, prefs: .shared)
            .environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        // The page's entrance and the model sizes being counted.
        try? await Task.sleep(for: .seconds(2.5))
        // The voice memory loads from disk after launch and would put back the made-up
        // people and the switch: set again now, then let the page draw them.
        if Demo.on { VoiceMemory.shared.showDemoPeople() }
        if args.contains("--voices-off") { VoiceMemory.shared.enabled = false }
        try? await Task.sleep(for: .seconds(0.4))
        host.layoutSubtreeIfNeeded()
        // `--scroll 600`: the page scrolled down that far, to draw what's below the fold.
        if let down = value("--scroll").flatMap(Double.init), let scroll = WindowPerf.tallestScroll(in: host) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: down))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .seconds(0.6))
            host.layoutSubtreeIfNeeded()
        }

        // The frame view: the content and the window's own buttons.
        let view = window.contentView?.superview ?? host
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { print("Misslyckades"); return }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            print("Ritad: \(out)")
        }
        window.close()
    }
}

// MARK: - `Mindtalk --render-perf <meeting id> [--size 1000x700]`
//
// A long meeting opened in the main window (never on screen, nothing saved) and timed:
// opening it, scrolling its summary and its text a screen at a time, and switching
// between the two tabs. Each step is the scroll (or the switch) and the window drawn
// once, on the main thread — what a frame costs. Prints one line per part.

@MainActor
enum WindowPerf {
    static func run(id: String, args: [String]) async {
        let size: CGSize = {
            guard let i = args.firstIndex(of: "--size"), i + 1 < args.count else { return CGSize(width: 1000, height: 700) }
            let p = args[i + 1].lowercased().split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? CGSize(width: p[0], height: p[1]) : CGSize(width: 1000, height: 700)
        }()
        MeetingStore.shared.loadNow()
        guard let record = MeetingStore.shared.meetings.first(where: { $0.id.uuidString.hasPrefix(id.uppercased()) }) else {
            return print("PERF fel: inget möte \(id)")
        }
        print("PERF möte: \(record.words.count) ord, \(Int(record.duration)) s, sammanfattning: \(record.summary != nil)")
        MainView.startPage = .meetings
        MainView.rendering = true
        MeetingsPage.lastOpen = record.id
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -40_000, y: -40_000), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let t0 = Date()
        let host = NSHostingView(rootView: MainView(dictation: .shared, prefs: .shared))
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let first = Date().timeIntervalSince(t0)
        // Then whatever the page does by itself once open (its entrance, tasks), until quiet.
        let settle = await stalls(for: 2.0)
        print(String(format: "PERF öppna: första bilden %.0f ms; sedan %@", first * 1000, settle))

        for (name, tab) in [("Sammanfattning", MeetingView.Tab.summary), ("Text", MeetingView.Tab.transcript)] {
            let s0 = Date()
            NotificationCenter.default.post(name: MeetingView.perfTab, object: tab)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let switched = Date().timeIntervalSince(s0)
            let after = await stalls(for: 1.0)
            print(String(format: "PERF byt till %@: %.0f ms; sedan %@", name, switched * 1000, after))
            guard let scroll = tallestScroll(in: host) else { print("PERF \(name): ingen rullningsvy"); continue }
            let height = scroll.documentView?.frame.height ?? 0
            var steps: [Double] = []
            var y: CGFloat = 0
            let page = scroll.contentView.bounds.height * 0.5
            // Down to the end and back up, half a screen a step.
            for direction in [1.0, -1.0] {
                for _ in 0..<400 {
                    y = max(0, min(y + page * direction, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height))
                    let a = Date()
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    steps.append(Date().timeIntervalSince(a) * 1000)
                    if let ms = steps.last, ms > 50 {
                        print(String(format: "PERF   långt steg %d: %.0f ms vid y %.0f av %.0f", steps.count, ms, y, scroll.documentView?.frame.height ?? 0))
                    }
                    // The run loop gets a turn between steps, as between frames.
                    try? await Task.sleep(for: .milliseconds(16))
                    if direction > 0, y >= (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - 1 { break }
                    if direction < 0, y <= 0 { break }
                }
            }
            let sorted = steps.sorted()
            let q = { (p: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            print(String(format: "PERF rulla %@ (%.0f pt): %d steg, median %.1f ms, p95 %.1f ms, max %.1f ms, över 100 ms: %d, över 16 ms: %d",
                         name, height, steps.count, q(0.5), q(0.95), sorted.last ?? 0,
                         steps.filter { $0 > 100 }.count, steps.filter { $0 > 16 }.count))
        }
        for _ in 0..<3 {
            for (name, tab) in [("Sammanfattning", MeetingView.Tab.summary), ("Text", MeetingView.Tab.transcript)] {
                let s0 = Date()
                NotificationCenter.default.post(name: MeetingView.perfTab, object: tab)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let switched = Date().timeIntervalSince(s0)
                let after = await stalls(for: 0.6)
                print(String(format: "PERF byt igen till %@: %.0f ms; sedan %@", name, switched * 1000, after))
            }
        }
        window.close()
    }

    /// The scroll view with the most to scroll: the page's own.
    static func tallestScroll(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    /// How the main thread kept up for a while: ticks asked for every 8 ms, and the
    /// longest gap between two (a gap is the main thread busy).
    private static func stalls(for seconds: Double) async -> String {
        var last = Date(), worst = 0.0, over = 0, busy = 0.0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(8))
            let now = Date()
            let gap = now.timeIntervalSince(last) * 1000
            worst = max(worst, gap)
            if gap > 100 { over += 1 }
            busy += max(0, gap - 8)
            last = now
        }
        return String(format: "längsta glapp %.0f ms, glapp över 100 ms: %d, upptaget ~%.0f ms av %.0f", worst, over, busy, seconds * 1000)
    }
}

// MARK: - `--demo`: what the pages show, all made up

/// Meetings with a summary, thoughts, folders and an MCP log for `--render-window
/// --demo`, held in memory only: nothing is read from or written to your own. The
/// words are the app's language; the names are the same in both.
@MainActor
enum WindowDemo {
    private static var english: Bool { Bundle.main.preferredLocalizations.first == "en" }

    /// A moment on a day: today at 9:30, yesterday at 14:00.
    private static func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func fill(openMeeting: Bool) {
        MeetingStore.shared.loadNow()
        MeetingFolders.shared.preview(english ? ["Customers", "Board", "Suppliers"] : ["Kunder", "Styrelsen", "Leverantörer"]
            // `--many-folders`: enough of them that the row has to put some under Fler.
            + (CommandLine.arguments.contains("--many-folders")
               ? ["IT", "Ledningsmöte", "Supporten", "Testmöten", "Rekrytering", "Marknad", "Projekt Norge", "Ekonomi"] : []))
        let meetings = meetings()
        MeetingStore.shared.replaceAll(meetings)
        Thoughts.shared.preview(thoughts())
        let now = Date()
        ClaudeSharing.shared.preview(enabled: true, entries: [
            .init(date: now.addingTimeInterval(-120), tool: "mindtalk_search", scope: MeetingFolders.shared.folders[0].name, items: 4, characters: 3000, client: "Claude"),
            .init(date: now.addingTimeInterval(-180), tool: "mindtalk_get_meeting", scope: meetings[0].title, items: 1, characters: 1850, client: "Claude"),
            .init(date: now.addingTimeInterval(-86_400), tool: "mindtalk_list_meetings", scope: MeetingFolders.shared.folders[1].name, items: 12, characters: 2400, client: "ChatGPT"),
            .init(date: now.addingTimeInterval(-90_000), tool: "mindtalk_list_thoughts", scope: LogScope.thoughts, items: 7, characters: 900),
        ])
        if openMeeting { MeetingsPage.lastOpen = meetings[0].id }
    }

    /// A meeting from its lines: who spoke, what they said, and the pause before
    /// (seconds), so the words spread over the meeting's length.
    private static func meeting(_ title: String, date: Date, names: [String], lines: [(Int, Double, String)]) -> (MeetingRecord, [Double]) {
        var r = MeetingRecord(title: title, date: date, language: english ? .multilingual : .swedish)
        var t = 3.0
        var starts: [Double] = []
        for (speaker, pause, line) in lines {
            t += pause
            starts.append(t)
            for word in line.split(separator: " ") {
                r.words.append(MeetingWord(text: String(word), start: t, end: t + 0.3, speaker: speaker))
                t += 0.38
            }
            t += 1.2
        }
        r.names = Dictionary(uniqueKeysWithValues: names.enumerated().map { (String($0.offset), $0.element) })
        r.duration = t + 40
        r.refined = true
        return (r, starts)
    }

    private static func meetings() -> [MeetingRecord] {
        let en = english
        // The weekly meeting: the launch, the budget, the next meeting.
        var (weekly, starts) = meeting(en ? "Weekly meeting about the launch" : "Veckomöte om lanseringen", date: at(daysAgo: 0, 9, 30),
                                       names: ["Anna", "Erik", "Sara"], lines: en ? [
            (0, 0, "Let's get going. Welcome everyone. Today we'll go through the launch, the budget for the autumn and what happens next."),
            (1, 140, "The numbers look really good. We had more downloads on the first day than in the whole of last month."),
            (0, 90, "Great! Do we know where most of the users come from?"),
            (2, 60, "Mostly Sweden, but some from Norway and Denmark too. Support is already getting questions in English."),
            (1, 310, "I think we should prioritise the meetings feature. It's what people ask about most."),
            (0, 120, "Agreed. Can you put together a plan by Thursday?"),
            (1, 30, "Yes, absolutely. I'll send it on Thursday morning."),
            (2, 260, "Then I'll take the budget at the same time. We need to move about 150,000 kronor to marketing in Norway and Denmark."),
            (0, 420, "Good. We'll meet again on Tuesday at ten and go through the plan and the budget before the board meeting."),
        ] : [
            (0, 0, "Då kör vi. Välkomna allihop. I dag går vi igenom lanseringen, budgeten för hösten och vad som händer härnäst."),
            (1, 140, "Siffrorna ser riktigt bra ut. Vi hade fler nedladdningar första dagen än under hela förra månaden."),
            (0, 90, "Vad kul! Vet vi var de flesta användarna kommer ifrån?"),
            (2, 60, "Mest från Sverige, men en del från Norge och Danmark också. Supporten får redan frågor på engelska."),
            (1, 310, "Jag tycker att vi ska prioritera mötesfunktionen. Det är det folk frågar mest om."),
            (0, 120, "Håller med. Kan du ta fram en plan till torsdag?"),
            (1, 30, "Ja, absolut. Jag skickar den på torsdag förmiddag."),
            (2, 260, "Då tar jag budgeten samtidigt. Vi behöver flytta ungefär 150 000 kronor till marknadsföring i Norge och Danmark."),
            (0, 420, "Bra. Vi ses igen tisdag klockan tio, så går vi igenom planen och budgeten innan styrelsemötet."),
        ])
        weekly.marks = [MeetingRecord.Mark(at: starts[4] + 1, kind: .decision, text: en ? "Meetings first" : "Mötesfunktionen först"),
                        MeetingRecord.Mark(at: starts[7] + 2, kind: .task)]
        typealias Item = MeetingSummary.Item
        var summary = MeetingSummary(overview: en
            ? "The launch went better than expected, with most users in Sweden and growing interest in Norway and Denmark. The team agreed to build the meetings feature next, and the autumn budget is adjusted before the board meeting."
            : "Lanseringen gick bättre än väntat, med flest användare i Sverige och ett växande intresse i Norge och Danmark. Teamet enades om att bygga mötesfunktionen härnäst, och höstbudgeten justeras innan styrelsemötet.")
        summary.decisions = [
            Item(text: en ? "The meetings feature is built first, before the integrations." : "Mötesfunktionen byggs först, före integrationerna.", at: starts[4] + 1, marked: true),
            Item(text: en ? "150,000 kronor of the autumn budget goes to marketing in Norway and Denmark." : "150 000 kronor av höstbudgeten går till marknadsföring i Norge och Danmark.", at: starts[7] + 2),
        ]
        summary.tasks = [
            Item(text: en ? "Put together a plan for the meetings feature by Thursday." : "Ta fram en plan för mötesfunktionen till torsdag.", owner: "Erik", at: starts[5] + 1, done: false),
            Item(text: en ? "Compile the budget before the board meeting." : "Sammanställa budgeten inför styrelsemötet.", owner: "Sara", at: starts[7] + 1, done: false, marked: true),
        ]
        summary.points = [
            Item(text: en ? "Erik: more downloads on the first day than in all of last month." : "Erik: fler nedladdningar första dagen än hela förra månaden.",
                 at: starts[1] + 1, topic: en ? "The launch" : "Lanseringen"),
            Item(text: en ? "Most users are in Sweden, but Norway and Denmark are growing." : "De flesta användarna finns i Sverige, men Norge och Danmark växer.",
                 at: starts[3] + 1, topic: en ? "The launch" : "Lanseringen"),
            Item(text: en ? "Support is already getting questions in English." : "Supporten får redan frågor på engelska.",
                 at: starts[3] + 2, topic: en ? "The launch" : "Lanseringen"),
            Item(text: en ? "Erik: the meetings feature is what people ask about most." : "Erik: mötesfunktionen är det folk frågar mest om.",
                 at: starts[4] + 1, topic: en ? "What comes next" : "Vad som byggs härnäst"),
            Item(text: en ? "Anna wants a plan before anything is started." : "Anna vill ha en plan innan något sätts igång.",
                 at: starts[5] + 1, topic: en ? "What comes next" : "Vad som byggs härnäst"),
            Item(text: en ? "Next meeting: Tuesday at ten, before the board meeting." : "Nästa möte: tisdag klockan tio, innan styrelsemötet.", at: starts[8] + 1),
        ]
        summary.notesFrom = weekly.notesFingerprint
        weekly.summary = summary

        var (customer, _) = meeting(en ? "Customer meeting, kick-off" : "Kundmöte, uppstart", date: at(daysAgo: 1, 14, 0), names: ["Johan", "Anna"], lines: en ? [
            (0, 0, "Thanks for coming. We'd like to start with a pilot in January."),
            (1, 400, "That works. We'll send over a proposal next week."),
        ] : [
            (0, 0, "Tack för att ni kom. Vi vill gärna börja med en pilot i januari."),
            (1, 400, "Det går bra. Vi skickar över ett förslag nästa vecka."),
        ])
        customer.duration = 52 * 60
        customer.folder = MeetingFolders.shared.folders.first?.id
        customer.summary = MeetingSummary(overview: en
            ? "The customer wants a pilot in January. A proposal goes out next week."
            : "Kunden vill ha en pilot i januari. Ett förslag skickas nästa vecka.")

        var (budget, _) = meeting(en ? "Autumn budget" : "Höstbudget", date: at(daysAgo: 6, 10, 0), names: ["Sara", "Erik"], lines: en ? [
            (0, 0, "Let's go through the autumn line by line."),
            (1, 300, "Marketing is the big question. The rest looks fine."),
        ] : [
            (0, 0, "Vi tar hösten rad för rad."),
            (1, 300, "Marknadsföringen är den stora frågan. Resten ser bra ut."),
        ])
        budget.duration = 41 * 60
        budget.summary = MeetingSummary(overview: en
            ? "The autumn budget holds, apart from marketing, which is decided at the weekly meeting."
            : "Höstbudgeten håller, förutom marknadsföringen, som avgörs på veckomötet.")
        return [weekly, customer, budget] + older()
    }

    /// Older meetings, a line or two each: enough for folded months below the recent ones.
    private static func older() -> [MeetingRecord] {
        let en = english
        let folders = MeetingFolders.shared.folders
        func short(_ title: String, _ daysAgo: Int, _ hour: Int, names: [String], minutes: Double, folder: Int? = nil,
                   overview: String) -> MeetingRecord {
            let said = en ? ["Let's begin with where we are.", "That sounds right to me.", "I'll follow up on it this week.",
                             "Good, then we agree."]
                          : ["Vi börjar med läget.", "Det låter rätt tycker jag.", "Jag följer upp det i veckan.", "Bra, då är vi överens."]
            var (r, _) = meeting(title, date: at(daysAgo: daysAgo, hour, 0), names: names,
                                 lines: names.indices.map { ($0, $0 == 0 ? 0 : 60, said[$0 % said.count]) })
            r.duration = minutes * 60
            r.folder = folder.map { folders[$0].id }
            r.summary = MeetingSummary(overview: overview)
            return r
        }
        return [
            short(en ? "Board meeting before the autumn" : "Styrelsemöte inför hösten", 8, 15, names: ["Anna", "Johan", "Liz"],
                  minutes: 64, folder: 1, overview: en ? "The board approved the autumn plan." : "Styrelsen godkände planen för hösten."),
            short(en ? "Supplier check-in" : "Avstämning med leverantören", 12, 10, names: ["Erik", "Markus"], minutes: 28, folder: 2,
                  overview: en ? "Deliveries move to every other week." : "Leveranserna går över till varannan vecka."),
            short(en ? "Planning the kickoff" : "Planering av kickoffen", 20, 13, names: ["Anna", "Sara", "Liz"], minutes: 45,
                  overview: en ? "The kickoff is in November, in Uppsala." : "Kickoffen blir i november, i Uppsala."),
            short(en ? "Customer meeting, follow-up" : "Kundmöte, uppföljning", 33, 9, names: ["Johan", "Anna"], minutes: 38, folder: 0,
                  overview: en ? "The pilot goes ahead with two teams." : "Piloten går vidare med två team."),
            short(en ? "Weekly meeting" : "Veckomöte", 40, 9, names: ["Anna", "Erik", "Sara", "Markus"], minutes: 51,
                  overview: en ? "The release moves a week." : "Releasen flyttas en vecka."),
            short(en ? "Workshop about support" : "Workshop om supporten", 50, 13, names: ["Sara", "Karin", "Olle", "Nils"], minutes: 92,
                  overview: en ? "Support answers in English from now on." : "Supporten svarar på engelska från och med nu."),
        ]
    }

    private static func thoughts() -> [Thought] {
        let en = english
        func t(_ text: String, _ daysAgo: Int, _ hour: Int, _ minute: Int, done: Bool = false, pinned: Bool = false) -> Thought {
            var x = Thought(text: text, date: at(daysAgo: daysAgo, hour, minute))
            x.done = done
            x.pinned = pinned
            x.pinOrder = pinned ? 1 : 0
            return x
        }
        return [
            t(en ? "Call back about the quote and check the Q4 budget." : "Ring tillbaka om offerten och kolla budgeten för Q4.", 0, 10, 12),
            t(en ? "Book a room for the kickoff in November." : "Boka lokal till kickoffen i november.", 0, 8, 40),
            t(en ? "Idea: show who talks the most in a meeting." : "Idé: visa vem som pratar mest i ett möte.", 1, 16, 25),
            t(en ? "Send the material to the board before Friday." : "Skicka underlaget till styrelsen före fredag.", 1, 11, 5, pinned: true),
        ]
    }
}
#endif
