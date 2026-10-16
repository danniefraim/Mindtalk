import SwiftUI

// MARK: - Hem
//
// One night-dark tile — the same room as "Nytt möte" on Möten, with its sphere of
// light breathing in the corner — that speaks about your day: the words you said
// in big serif, the time you didn't spend typing, the week as a small chart. The
// ways to start sit on its right. While a meeting goes on, the tile is the meeting:
// the clock, pause and stop. Under it, the latest meetings as cards you can read
// without opening, and the thoughts as notes. A meeting's tasks live in its
// summary — Mindtalk isn't a to-do app.

enum HomeGreeting {
    static func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<10: return String(localized: "God morgon")
        case 10..<13: return String(localized: "God förmiddag")
        case 13..<18: return String(localized: "God eftermiddag")
        default: return String(localized: "God kväll")
        }
    }

    /// "Mathias" — the first name the Mac knows you by; nil if it knows none.
    static let firstName: String? = {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }()

    /// "torsdag 15 oktober" — after "God kväll ·", so in lower case.
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
    }
}

/// The ink tile: your day, or the meeting going on.
struct HomeHero: View {
    @ObservedObject var dictation: Dictation
    @Binding var page: Page
    /// Side by side (actions on the right) or stacked, from the page's width.
    var wide = true
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var stats = Stats.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tile is night in both modes, like the room on Möten: text is white on it.
    private var onInk: Color { .white }
    private var meetingKeys: String? { Settings.meetingShortcut.map { $0.chip.replacingOccurrences(of: " ", with: "") } }

    var body: some View {
        // The week once per redraw — it's date maths over seven days.
        let week = stats.week
        let weekWords = week.reduce(0) { $0 + $1.stat.words }
        let fresh = stats.totalWords == 0
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        layout {
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let hello = HomeGreeting.greeting(context.date) + (HomeGreeting.firstName.map { ", " + $0 } ?? "")
                    (Text(verbatim: hello).foregroundStyle(onInk.opacity(0.92))
                     + Text(verbatim: " · " + HomeGreeting.day(context.date)).foregroundStyle(onInk.opacity(0.6)))
                        .font(.system(size: 15, weight: .medium))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 18)
                if session.isRecording {
                    LiveMeeting(session: session, onInk: onInk)
                } else if case .finishing(let what) = session.phase {
                    Text("Mötet är slut").font(.system(size: 44, weight: .regular, design: .serif)).foregroundStyle(onInk)
                    HStack(spacing: 10) {
                        SettlingLine(color: onInk).frame(width: 48)
                        Text(what).font(.system(size: 14)).foregroundStyle(onInk.opacity(0.75))
                    }
                    .padding(.top, 10)
                } else if needsSetup {
                    if case .modelDownloading(let p) = setupIssue {
                        // Only the download left: nothing for you to do but wait.
                        Text("Nästan klart").font(.system(size: 44, weight: .regular, design: .serif)).foregroundStyle(onInk)
                        Text(verbatim: SpeechModel.isPreparing(p)
                             ? String(localized: "Talmodellen görs redo för din Mac – bara första gången.")
                             : String(localized: "Laddar ned talmodellen · \(dictation.engine.progressText(p, started: dictation.downloadStarted[dictation.engine]))"))
                            .font(.system(size: 14)).foregroundStyle(onInk.opacity(0.75)).monospacedDigit().padding(.top, 10)
                    } else {
                        // Not ready yet: the steps are in the card below, not a promise here.
                        Text("Ett par steg kvar").font(.system(size: 44, weight: .regular, design: .serif)).foregroundStyle(onInk)
                        Text(verbatim: setupIssue.map(issueLine) ?? String(localized: "Mindtalk gör sig redo."))
                            .font(.system(size: 14)).foregroundStyle(onInk.opacity(0.75)).padding(.top, 10)
                    }
                } else if let since = slowStart {
                    // The first start on a Mac takes about half a minute (on the GPU while the
                    // Neural Engine is prepared). Said plainly rather than "Håll in … och prata".
                    Text("Nästan klart").font(.system(size: 44, weight: .regular, design: .serif)).foregroundStyle(onInk)
                    TimelineView(.periodic(from: since, by: 30)) { context in
                        let minutes = Int(context.date.timeIntervalSince(since) / 60)
                        let text = String(localized: "Talmodellen görs redo för din Mac – bara första gången, ungefär en halv minut.")
                        Text(verbatim: minutes < 1 ? text : text + " " + String(localized: "\(minutes) min hittills."))
                            .font(.system(size: 15)).foregroundStyle(onInk.opacity(0.75)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                    SettlingLine(color: onInk).frame(width: 60, alignment: .leading).padding(.top, 14).accessibilityHidden(true)
                } else {
                    let today = stats.today.words
                    if today > 0 || weekWords > 0 {
                        // The figure is the headline: today's words, or the week's when today is still empty.
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            DayFigure(value: today > 0 ? today : weekWords)
                                .font(.system(size: 96, weight: .regular, design: .serif))
                                .tracking(-2)
                                .foregroundStyle(onInk)
                                .lineLimit(1).minimumScaleFactor(0.5)
                            Text(today > 0 ? "ord i dag" : "ord i veckan")
                                .font(.system(size: 22, weight: .regular, design: .serif))
                                .foregroundStyle(onInk.opacity(0.75))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: headline(weekWords: weekWords, fresh: fresh)))
                    } else {
                        Text(verbatim: headline(weekWords: weekWords, fresh: fresh)).font(.system(size: 44, weight: .regular, design: .serif))
                            .foregroundStyle(onInk).lineLimit(2).minimumScaleFactor(0.7)
                    }
                    Text(verbatim: subline(week: week, weekWords: weekWords, fresh: fresh)).font(.system(size: 15)).foregroundStyle(onInk.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, today > 0 || weekWords > 0 ? 2 : 10)
                }
                // A new user has no week to show: seven grey stubs would read as a broken chart.
                if !fresh, !session.isRecording {
                    Spacer(minLength: 26)
                    HStack(alignment: .bottom, spacing: 22) {
                        weekBars(week)
                        Text(verbatim: weekWords > 0
                             ? String(localized: "Vecka \(stats.weekNumber) · \(Stats.number(weekWords)) ord")
                             : String(localized: "Vecka \(stats.weekNumber)"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(onInk.opacity(0.6)).monospacedDigit()
                            .lineLimit(1).fixedSize()
                            .padding(.bottom, 20)
                            .accessibilityHidden(true)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !needsSetup {
                VStack(alignment: wide ? .trailing : .leading, spacing: 10) {
                    if session.isRecording {
                        meetingButtons
                    } else if case .finishing = session.phase {
                        showMeeting
                    } else if session.phase == .idle {
                        startButtons
                    }
                }
            }
        }
        .padding(26)
        .frame(minHeight: needsSetup ? 180 : 280)
        .background(alignment: .bottomTrailing) {
            // The sphere of light from Möten, breathing in the corner — with your voice
            // while you dictate.
            HeroSphere(meter: dictation.meter, listening: dictation.phase == .recording)
                .frame(width: 340, height: 340)
                .offset(x: 70, y: 120)
                .opacity(0.55)
                .allowsHitTesting(false)
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(DS.Colors.night))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: session.phase)
        // A start that takes more than a few seconds is the long first one; a language
        // switch is over before it would show.
        .task(id: "\(dictation.model == .loading)-\(dictation.loadingSince.timeIntervalSince1970)") {
            slowSince = nil
            // Only the very first start on this Mac is long; a slow ordinary one isn't "Nästan klart".
            guard dictation.model == .loading, dictation.firstPreparation else { return }
            let since = dictation.loadingSince
            let wait = 3 - Date().timeIntervalSince(since)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled, dictation.model == .loading { slowSince = since }
        }
    }

    // MARK: Getting ready

    /// Set when the speech model has been starting for a while.
    @State private var slowSince: Date?

    private var slowStart: Date? {
        #if DEBUG
        if HomeDebug.modelLoading { return Date().addingTimeInterval(-3 * 60 - 10) }
        #endif
        return slowSince
    }

    private var needsSetup: Bool {
        #if DEBUG
        if HomeDebug.ready { return false }
        if HomeDebug.modelPreparing { return true }
        #endif
        return dictation.needsSetup
    }

    private var setupIssue: Dictation.SetupIssue? {
        #if DEBUG
        if HomeDebug.modelPreparing { return .modelDownloading(0.95) }
        #endif
        return dictation.setupIssue
    }

    /// The issue in Hem's words: one name for the model — "talmodellen".
    private func issueLine(_ issue: Dictation.SetupIssue) -> String {
        switch issue {
        case .modelMissing: return String(localized: "Ladda ned talmodellen (\(dictation.engine.title.lowercased()))")
        default: return issue.title
        }
    }

    /// "Håll in" or "Tryck på", as the dictation key works.
    private var pressVerb: String {
        dictation.mode == .toggle ? String(localized: "Tryck på") : String(localized: "Håll in")
    }

    // MARK: Your day

    private func headline(weekWords: Int, fresh: Bool) -> String {
        let today = stats.today.words
        if today > 0 { return today == 1 ? String(localized: "1 ord i dag") : String(localized: "\(Stats.number(today)) ord i dag") }
        if weekWords > 0 { return String(localized: "\(Stats.number(weekWords)) ord i veckan") }
        if !fresh { return String(localized: "Inget sagt i dag än") }
        return dictation.mode == .toggle ? String(localized: "Tryck på \(dictation.hotkey.inlineName) och prata")
                                         : String(localized: "Håll in \(dictation.hotkey.inlineName) och prata")
    }

    private func subline(week: [Stats.WeekDay], weekWords: Int, fresh: Bool) -> String {
        let today = stats.today
        let streak = stats.streak
        var parts: [String] = []
        if today.words > 0 {
            if today.savedSeconds >= 60 { parts.append(String(localized: "Du har sluppit skriva i ungefär \(Stats.prose(today.savedSeconds)).")) }
            if streak > 1 { parts.append(String(localized: "Du har dikterat \(streak) dagar i rad.")) }
        } else if weekWords > 0 {
            let saved = week.reduce(0) { $0 + $1.stat.savedSeconds }
            parts.append(String(localized: "Inget sagt i dag än."))
            if saved >= 60 { parts.append(String(localized: "I veckan har du sluppit skriva i ungefär \(Stats.prose(saved)).")) }
        } else if !fresh {
            // A new week (a Monday morning) — not a new user.
            parts.append(streak > 0 ? String(localized: "Du har dikterat \(streak) dagar i rad.")
                                    : String(localized: "Texten skrivs där markören står – i vilken app som helst."))
        } else {
            parts.append(String(localized: "Texten skrivs där markören står – i vilken app som helst."))
        }
        return parts.joined(separator: "\n")
    }

    /// Monday to Sunday: "mån tis ons", today bright with its figure above it, the
    /// days to come faint, on a thin baseline.
    private func weekBars(_ week: [Stats.WeekDay]) -> some View {
        let top = max(1, week.map(\.stat.words).max() ?? 1)
        var cal = Calendar.current; cal.locale = AppLanguage.locale
        let names = cal.shortStandaloneWeekdaySymbols
        let weekday = { (d: Date) in d.formatted(Date.FormatStyle().weekday(.wide).locale(AppLanguage.locale)) }
        // One element for VoiceOver: the days said, not seven stops.
        let spoken = week.filter { !$0.isFuture }.map { day in
            (day.isToday ? String(localized: "i dag") : weekday(day.date)) + " " + String(localized: "\(Stats.number(day.stat.words)) ord")
        }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 5) {
                        Text(verbatim: day.isToday && day.stat.words > 0 ? Stats.number(day.stat.words) : " ")
                            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(onInk.opacity(0.9)).lineLimit(1).fixedSize()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(onInk.opacity(day.isFuture ? 0.12 : day.stat.words > 0 ? (day.isToday ? 0.95 : 0.5) : 0.22))
                            .frame(width: 28, height: max(3, 64 * CGFloat(day.stat.words) / CGFloat(top)))
                    }
                    .frame(width: 28)
                    .help(Text(verbatim: weekday(day.date) + ": " + String(localized: "\(Stats.number(day.stat.words)) ord")))
                }
            }
            Rectangle().fill(onInk.opacity(0.2)).frame(width: 7 * 28 + 6 * 10, height: 1)
            HStack(spacing: 10) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                    Text(verbatim: names[cal.component(.weekday, from: day.date) - 1].lowercased())
                        .font(.system(size: 11, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(onInk.opacity(day.isToday ? 0.92 : 0.6))
                        .frame(width: 28)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15), value: week.map(\.stat.words))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(localized: "Vecka \(stats.weekNumber)") + ": " + spoken))
    }

    @ViewBuilder private var startButtons: some View {
        // Dictating or saying a thought holds the microphone; a moment after (a thought
        // saved, text copied) it is free again.
        let micBusy = dictation.phase == .recording || dictation.phase == .transcribing
        if voices.state == .ready, dictation.engine.isInstalled {
            inkButton("Starta möte", dot: true, filled: true, keys: meetingKeys,
                      help: micBusy ? "Går när dikteringen är klar" : "Spela in ett möte i rummet") {
                session.start(introducing: true)
                if session.phase != .idle { page = .meetings }
            }
            .disabled(micBusy)
        } else {
            inkButton("Kom igång med möten", icon: "person.2.wave.2", filled: true, keys: nil, help: "Hämta det som behövs för möten") {
                page = .meetings
            }
        }
        inkButton("Säg en tanke", icon: "lightbulb", filled: false,
                  keys: Settings.thoughtShortcut?.chip.replacingOccurrences(of: " ", with: ""),
                  help: micBusy ? "Går när dikteringen är klar" : "Säg det du kommer på – det sparas i Tankar") { dictation.startThought() }
            .disabled(micBusy || !dictation.engine.isInstalled)
        HStack(spacing: 5) {
            Text(verbatim: pressVerb).foregroundStyle(onInk.opacity(0.65))
            Text(verbatim: dictation.hotkey.chip).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(onInk.opacity(0.16)))
                .foregroundStyle(onInk)
            Text("för att diktera").foregroundStyle(onInk.opacity(0.65))
        }
        .font(.system(size: 12.5)).padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dictation.mode == .toggle ? Text("Tryck på \(dictation.hotkey.inlineName) för att diktera")
                                                      : Text("Håll in \(dictation.hotkey.inlineName) för att diktera"))
    }

    // MARK: The meeting going on

    @ViewBuilder private var meetingButtons: some View {
        if let stopAt = session.stopAt {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let left = max(0, stopAt.timeIntervalSince(context.date))
                HStack(spacing: 9) {
                    ZStack {
                        Circle().stroke(onInk.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: left / MeetingSession.undoSeconds)
                            .stroke(onInk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                    Text("Avslutas om \(Int(left.rounded(.up))) s")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(onInk).fixedSize()
                }
                .frame(height: 36)
            }
            inkButton("Ångra", icon: "arrow.uturn.backward", filled: true, keys: nil, help: "Mötet fortsätter som om inget hänt") {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { session.cancelStop() }
            }
        } else if session.isPaused {
            inkButton("Fortsätt", icon: "play.fill", filled: true, keys: "⌥⌘P", help: "Fortsätt spela in") {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { session.resume() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        } else {
            inkButton("Pausa", icon: "pause.fill", filled: true, keys: "⌥⌘P", help: "Pausa mötet") {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { session.pause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
        inkButton("Avsluta", icon: "stop.fill", filled: false, keys: meetingKeys, help: "Avsluta mötet") {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() }
        }
        showMeeting
    }

    private var showMeeting: some View {
        Button { page = .meetings } label: {
            HStack(spacing: 5) {
                Text("Visa mötet")
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(onInk.opacity(0.75))
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }

    /// A button on the ink tile: filled (paper on ink) or outlined, with its shortcut beside it.
    private func inkButton(_ title: LocalizedStringKey, icon: String? = nil, dot: Bool = false, filled: Bool,
                           keys: String?, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if dot { Circle().fill(DS.Colors.recording).frame(width: 8, height: 8).accessibilityHidden(true) }
                    if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true) }
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(minWidth: 150)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(filled ? onInk : onInk.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(onInk.opacity(filled ? 0 : 0.5), lineWidth: 1))
                .foregroundStyle(filled ? DS.Colors.night : onInk)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .help(help)
            .accessibilityHint(keys.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            Text(verbatim: keys ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(onInk.opacity(0.65))
                .frame(minWidth: 44, alignment: .leading).fixedSize()
                .accessibilityHidden(true)
        }
    }

    private struct PressStyle: ButtonStyle {
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// The day's figure, counted up from nothing the first time Hem shows it after
/// launch — then it simply changes. Still with Reduce Motion.
private struct DayFigure: View {
    let value: Int
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @MainActor private static var counted = false

    var body: some View {
        Counting(value: shown)
            .onAppear {
                var still = Self.counted || reduceMotion
                #if DEBUG
                still = still || CommandLine.arguments.contains("--render-home")   // screenshots: the figure, not its start
                #endif
                if still { shown = Double(value); return }
                Self.counted = true
                withAnimation(.easeOut(duration: 0.9)) { shown = Double(value) }
            }
            .onChange(of: value) { _, new in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { shown = Double(new) }
            }
    }

    private struct Counting: View, Animatable {
        var value: Double
        var animatableData: Double {
            get { value }
            set { value = newValue }
        }
        var body: some View { Text(verbatim: Stats.number(Int(value.rounded()))).monospacedDigit() }
    }
}

/// The sphere of light in the tile's corner. It breathes at rest and follows your
/// voice while you dictate; it stops when the window can't be seen.
private struct HeroSphere: View {
    @ObservedObject var meter: LevelMeter
    let listening: Bool
    @State private var visible = true

    var body: some View {
        let level = listening ? Double(min(1, (meter.levels.suffix(3).max() ?? 0) * 1.6)) : 0.22
        Constellation(figure: nil, color: .white, level: level, searching: listening, paused: !visible)
            .onAppear { visible = AppDelegate.mainWindowVisible }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window.contentViewController is NSHostingController<MainView> else { return }
                visible = window.occlusionState.contains(.visible)
            }
    }
}

/// The meeting going on: the clock, and who has spoken so far. The speakers are
/// counted once a second with the clock, not on every word the meeting publishes.
private struct LiveMeeting: View {
    @ObservedObject var session: MeetingSession
    let onInk: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RecordingMark(session: session, color: onInk)
                Text(session.isPaused ? "Mötet är pausat" : "Mötet spelas in").font(.system(size: 15, weight: .semibold)).foregroundStyle(onInk)
            }
            if let start = session.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let speakers = Set((session.record?.words ?? []).compactMap(\.speaker).filter { $0 >= 0 }).count
                    let since = (session.record?.date ?? start).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: MeetingView.duration(session.clock(at: context.date)))
                            .font(.system(size: 56, weight: .regular, design: .serif)).monospacedDigit()
                            .foregroundStyle(onInk).padding(.top, 6)
                        Text(verbatim: String(localized: "Sedan \(since)")
                             + (speakers > 0 ? " · " + (speakers == 1 ? String(localized: "1 talare hittills") : String(localized: "\(speakers) talare hittills")) : ""))
                            .font(.system(size: 13.5)).foregroundStyle(onInk.opacity(0.75)).padding(.top, 8)
                    }
                }
            }
        }
    }
}

/// The latest meetings as cards, the thoughts as notes.
struct HomeShelves: View {
    @Binding var page: Page
    var wide = true
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var thoughts = Thoughts.shared
    @ObservedObject private var folders = MeetingFolders.shared
    @ObservedObject private var importer = MeetingImport.shared
    /// The meeting being recorded or written out — shown on the tile, not here. Only
    /// its id: the session publishes many times a second while it records.
    @State private var live: UUID?

    var body: some View {
        let meetings = Array(store.meetings.filter { $0.id != live }.prefix(3))
        let open = thoughts.forHome
        VStack(alignment: .leading, spacing: 30) {
            // In the setup card's place once the setup is done, for a new user.
            FirstDayCard(dictation: .shared, page: $page)
            shelf("Senaste möten", more: "Alla möten", label: "Alla möten", action: { MeetingsPage.lastOpen = nil; page = .meetings }) {
                VStack(alignment: .leading, spacing: 12) {
                    // A recording being written out: there, rather than an empty shelf.
                    if !importer.jobs.isEmpty {
                        ImportCards(compact: true) { id in MeetingsPage.lastOpen = id; page = .meetings }
                    }
                    if meetings.isEmpty {
                        if importer.jobs.isEmpty {
                            hint("person.2.wave.2", "Här hamnar mötena du spelar in eller lägger till, med en sammanfattning du kan läsa direkt.")
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: wide ? 3 : 1),
                                  alignment: .leading, spacing: 12) {
                            ForEach(meetings) { m in
                                MeetingCard(record: m, folder: folders.folder(of: m)?.name,
                                            speakers: Set(m.words.compactMap(\.speaker).filter { $0 >= 0 }).count,
                                            locked: live != nil, page: $page)
                            }
                        }
                    }
                }
            }
            shelf("Tankar", more: open.count > 4 ? "Alla \(open.count) tankar" : "Alla tankar", label: "Alla tankar", action: { page = .thoughts }) {
                if open.isEmpty {
                    if let keys = Settings.thoughtShortcut?.chip.replacingOccurrences(of: " ", with: "") {
                        hint("lightbulb", "Det du kommer på mitt i något annat – håll in \(keys) och säg det, så ligger det här.")
                    } else {
                        hint("lightbulb", "Det du kommer på mitt i något annat – säg det, så ligger det här.")
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: wide ? 2 : 1),
                              alignment: .leading, spacing: 12) {
                        ForEach(open.prefix(4)) { t in ThoughtNote(thought: t, page: $page) }
                    }
                }
            }
            #if DEBUG
            if HomeDebug.menuBarHint { MenuBarHintBubble() }
            #endif
        }
        .onReceive(MeetingSession.shared.$record.map { $0?.id }.removeDuplicates()) { live = $0 }
    }

    private func shelf<C: View>(_ title: LocalizedStringKey, more: LocalizedStringKey, label: LocalizedStringKey, action: @escaping () -> Void,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(more)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
            content()
        }
    }

    private func hint(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.Colors.muted).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
    }

    /// A thought as a note: your own words in serif, and when you said them.
    private struct ThoughtNote: View {
        let thought: Thought
        @Binding var page: Page
        @State private var hovering = false

        var body: some View {
            Button { page = .thoughts } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(thought.text).font(.system(size: 15, design: .serif)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(verbatim: MeetingRecord.when(thought.date)).font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? DS.Colors.chip : DS.Colors.card))
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                            .padding(10).accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(thought.text)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: thought.text))
            .accessibilityValue(Text(verbatim: MeetingRecord.when(thought.date)))
            .accessibilityAddTraits(.isButton)
        }
    }

    /// When, the title, what it was about, who was there.
    private struct MeetingCard: View {
        let record: MeetingRecord
        let folder: String?
        /// Counted by the shelf, so a hover doesn't count every word again.
        let speakers: Int
        /// A meeting is being recorded: Möten shows that one, so a card can't open.
        let locked: Bool
        @Binding var page: Page
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let m = record
            let about = m.summary?.overview
                ?? (!m.finished ? String(localized: "Inspelningen avbröts innan mötet var klart.")
                    : MeetingNotes.isAvailable ? String(localized: "Ingen sammanfattning än.") : String(localized: "Ingen sammanfattning."))
            let when = MeetingRecord.when(m.date) + " · " + Stats.duration(m.duration)
            let people = speakers == 1 ? String(localized: "1 talare") : String(localized: "\(speakers) talare")
            Button {
                MeetingsPage.lastOpen = m.id
                page = .meetings
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: m.source == nil ? "person.2.wave.2" : (m.source!.video ? "film" : "waveform"))
                            .font(.system(size: 11)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                        Text(verbatim: when)
                            .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    }
                    Text(m.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: about).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    HStack(spacing: 10) {
                        if speakers > 0 {
                            Label(people, systemImage: "person.2").font(.system(size: 11.5))
                        }
                        if let folder { Label(folder, systemImage: "folder").font(.system(size: 11.5)).lineLimit(1) }
                    }
                    .foregroundStyle(DS.Colors.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
                .raised(cornerRadius: 18)
                .scaleEffect(hovering && !reduceMotion && !locked ? 1.012 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .help(locked ? Text("Går att öppna när mötet är klart") : Text(verbatim: about))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            // Title first, then when and who — the summary as the value.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [m.title, when, speakers > 0 ? people : nil, folder].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityValue(Text(verbatim: about))
            .accessibilityAddTraits(.isButton)
        }
    }
}
