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
//   --find-query "ord"  with --open-meeting: ⌘F open in the meeting, that searched for
//   --meeting-state silence|latecomer|manyvoices|whoareyou: a meeting being recorded,
//                  at that moment; voiceconsent: the start card asking about the voices
//   --voices-off   "Kom ihåg rösterna" as for someone who never chose (off), in memory only
//   --models-ready with --ready: the start card as if the meeting models were downloaded

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
        if Demo.on { WindowDemo.fill(openMeeting: args.contains("--open-meeting")) }
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
        host.layoutSubtreeIfNeeded()

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
        MeetingFolders.shared.preview(english ? ["Customers", "Board", "Suppliers"] : ["Kunder", "Styrelsen", "Leverantörer"])
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
            ? "The launch went better than expected. The meetings feature comes next, and the autumn budget is adjusted before the board meeting."
            : "Lanseringen gick bättre än väntat. Mötesfunktionen prioriteras härnäst, och höstbudgeten justeras innan styrelsemötet.")
        summary.decisions = [
            Item(text: en ? "The meetings feature is built first, before the integrations." : "Mötesfunktionen byggs först, före integrationerna.", at: starts[4] + 1, marked: true),
            Item(text: en ? "150,000 kronor of the autumn budget goes to marketing in Norway and Denmark." : "150 000 kronor av höstbudgeten går till marknadsföring i Norge och Danmark.", at: starts[7] + 2),
        ]
        summary.tasks = [
            Item(text: en ? "Put together a plan for the meetings feature by Thursday." : "Ta fram en plan för mötesfunktionen till torsdag.", owner: "Erik", at: starts[5] + 1, done: false),
            Item(text: en ? "Compile the budget before the board meeting." : "Sammanställa budgeten inför styrelsemötet.", owner: "Sara", at: starts[7] + 1, done: false, marked: true),
        ]
        summary.points = [
            Item(text: en ? "Next meeting: Tuesday at ten, before the board meeting." : "Nästa möte: tisdag klockan tio, innan styrelsemötet.", at: starts[8] + 1),
            Item(text: en ? "Support is already getting questions in English." : "Supporten får redan frågor på engelska.", at: starts[3] + 1),
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
        return [weekly, customer, budget]
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
