import SwiftUI

// MARK: - Hem
//
// The day in small capitals, the greeting as the page's title, then one light tile
// that speaks about your day: the words you said in big serif, the week as a small
// chart, and under a thin line the ways to start — the dictation key as a chip, the
// two buttons on the right. The sphere of light from Möten keeps the tile's corner.
// While a meeting goes on, the tile is the meeting: the clock, pause and stop. Under
// it, the first day's three steps for a new user, the latest meetings as cards you
// can read without opening, and the thoughts as notes. A meeting's tasks live in
// its summary — Mindtalk isn't a to-do app.

enum HomeGreeting {
    static func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return String(localized: "God morgon")
        case 12..<18: return String(localized: "God eftermiddag")
        default: return String(localized: "God kväll")
        }
    }

    /// The first name the Mac knows you by; nil if it knows none.
    static let firstName: String? = {
        #if DEBUG
        if Demo.on { return "Johan" }   // screenshots: a made-up name, never the Mac's own
        #endif
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }()

    /// "torsdag 15 oktober" — set in small capitals above the greeting.
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
    }
}

/// The tile: your day, or the meeting going on.
struct HomeHero: View {
    @ObservedObject var dictation: Dictation
    @Binding var page: Page
    /// The week beside the figure, or under it, from the page's width.
    var wide = true
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var stats = Stats.shared
    @ObservedObject private var firstDay = FirstDayCard.Presence.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ink: the tile is light, so its text is the page's own.
    private var ink: Color { DS.Colors.ink }
    private var meetingKeys: String? { Settings.meetingShortcut.map { $0.chip.replacingOccurrences(of: " ", with: "") } }

    var body: some View {
        // The week once per redraw — it's date maths over seven days.
        let week = stats.week
        let weekWords = week.reduce(0) { $0 + $1.stat.words }
        let fresh = stats.totalWords == 0
        // An empty week is no chart: seven grey stubs would read as a broken one. While a
        // meeting goes on, the setup isn't done or the first start is explained, the tile
        // is about that.
        let showWeek = weekWords > 0 && !welcoming(fresh) && !session.isRecording && !needsSetup && slowStart == nil
        let top = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
        VStack(alignment: .leading, spacing: 22) {
            header
            VStack(alignment: .leading, spacing: 0) {
                // Above the line: the figure, the week, and the sphere in a column of
                // its own, so nothing is ever written over it.
                HStack(alignment: needsSetup ? .center : .top, spacing: 28) {
                    top {
                        headline(week: week, weekWords: weekWords, fresh: fresh)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if showWeek { weekChart(week, weekWords: weekWords) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The sphere of light from Möten — with your voice while you dictate.
                    // (The cloud is about two thirds of its frame: the rest is let go.)
                    InkSphere(meter: dictation.meter, listening: dictation.phase == .recording)
                        .frame(width: DS.Layout.sphere, height: DS.Layout.sphere)
                        .padding(.top, -20).padding(.bottom, -46).padding(.trailing, -14)
                        .allowsHitTesting(false)
                }
                // A meeting going on keeps its pause and stop, setup done or not.
                if !needsSetup || session.isBusy {
                    Rectangle().fill(DS.Colors.divider).frame(height: 1)
                        .padding(.top, 12).padding(.bottom, 18)
                    bottomRow
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile()
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: session.phase)
            // The first start of a language on this Mac is the long one, said almost at once
            // (half a second, so a start that is over in a blink never shows it). A slow
            // ordinary start isn't "Nästan klart".
            .task(id: "\(dictation.model == .loading)-\(dictation.loadingSince.timeIntervalSince1970)") {
                slowSince = nil
                guard dictation.model == .loading, dictation.firstPreparation else { return }
                let since = dictation.loadingSince
                let wait = 0.5 - Date().timeIntervalSince(since)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled, dictation.model == .loading { slowSince = since }
            }
        }
    }

    /// The day in small capitals, then the greeting as the page's title.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: HomeGreeting.day(context.date).uppercased())
                    .font(.system(size: 11.5, weight: .semibold)).tracking(1.8).foregroundStyle(DS.Colors.muted)
                Text(verbatim: HomeGreeting.greeting(context.date) + (HomeGreeting.firstName.map { ", " + $0 } ?? ""))
                    .font(DS.pageTitle)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    // MARK: Above the line

    /// The figure, the meeting's clock, or what's left to set up.
    @ViewBuilder private func headline(week: [Stats.WeekDay], weekWords: Int, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.isRecording {
                LiveMeeting(session: session, ink: ink)
            } else if case .finishing(let what) = session.phase {
                Text(verbatim: MeetingSession.endedSentence())
                    .font(.system(size: 30, weight: .regular, design: .serif)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SettlingLine(color: ink).frame(width: 48)
                    Text(what).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                }
                .padding(.top, 10)
            } else if needsSetup {
                if case .modelDownloading(let p) = setupIssue {
                    // Only the download left: nothing for you to do but wait. "Nästan klart"
                    // once the files are in, not at the first byte.
                    let preparing = SpeechModel.isPreparing(p)
                    Text(preparing ? "Nästan klart" : "Laddar ned talmodellen").font(.system(size: 40, weight: .regular, design: .serif)).foregroundStyle(ink)
                    Text(verbatim: preparing
                         ? String(localized: "Talmodellen görs redo för din Mac, bara första gången.")
                         : dictation.engine.progressText(p, started: dictation.downloadStarted[dictation.engine]))
                        .font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted).monospacedDigit().padding(.top, 8)
                } else {
                    // Not ready yet: the steps are asked for in Kom igång below, and only there.
                    // Named as in the tab bar: "Hjälpmedel saknas", "2 steg kvar".
                    Text(verbatim: FloatingTabBar.stepsText(dictation))
                        .font(.system(size: 40, weight: .regular, design: .serif)).foregroundStyle(ink)
                    Text("Det som saknas står här nedanför.")
                        .font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted).padding(.top, 8)
                }
            } else if let since = slowStart {
                // The first start on a Mac takes about half a minute (on the GPU while the
                // Neural Engine is prepared). Said plainly rather than "Håll in … och prata".
                Text("Nästan klart").font(.system(size: 40, weight: .regular, design: .serif)).foregroundStyle(ink)
                TimelineView(.periodic(from: since, by: 30)) { context in
                    let minutes = Int(context.date.timeIntervalSince(since) / 60)
                    // The same words as the introduction's: half a minute at first, then the
                    // minutes so far, with a small ring going round in front.
                    HStack(alignment: .center, spacing: 10) {
                        LoadingRing(color: ink)
                        Text(verbatim: String(localized: "Talmodellen görs redo för din Mac") + ". "
                             + (minutes < 1 ? String(localized: "Det tar ungefär en halv minut, bara första gången.")
                                            : String(localized: "Det tar en liten stund, bara första gången. \(minutes) min hittills.")))
                            .font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            } else if welcoming(fresh) {
                // Nothing said yet and the first-day card below says how: the hero
                // welcomes rather than saying the key a third time.
                Text("Välkommen till Mindtalk").font(.system(size: 40, weight: .regular, design: .serif))
                    .foregroundStyle(ink).lineLimit(2).minimumScaleFactor(0.7)
                Text("Allt du säger blir text, direkt på din Mac.").font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } else {
                let today = stats.today.words
                if today > 0 || weekWords > 0 {
                    // The figure is the headline: today's words, or the week's when today is still empty.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        DayFigure(value: today > 0 ? today : weekWords)
                            .font(.system(size: 84, weight: .regular, design: .serif))
                            .tracking(-2.5)
                            .foregroundStyle(ink)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(today > 0 ? (today == 1 ? "one|ord i dag" : "ord i dag") : (weekWords == 1 ? "one|ord i veckan" : "ord i veckan"))
                            .font(.system(size: 21, weight: .regular, design: .serif))
                            .foregroundStyle(DS.Colors.muted)
                    }
                    .padding(.top, -6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: headline(weekWords: weekWords, fresh: fresh)))
                } else {
                    Text(verbatim: headline(weekWords: weekWords, fresh: fresh)).font(.system(size: 40, weight: .regular, design: .serif))
                        .foregroundStyle(ink).lineLimit(2).minimumScaleFactor(0.7)
                }
                Text(verbatim: subline(week: week, weekWords: weekWords, fresh: fresh)).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, today > 0 || weekWords > 0 ? 2 : 8)
            }
            // Another program has Secure Input on: the key can't be heard. Said here as in
            // the menu bar panel, as a warning, since nothing else on the page says why.
            if dictation.isReady, dictation.keyboardBlocked, !session.isBusy {
                Label("Ett annat program spärrar tangentbordet just nu, så tangenten för diktering fungerar inte.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
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

    /// Nothing dictated yet, with the first-day card on the page: it says how, so the
    /// hero welcomes and the line under it keeps the key to itself.
    private func welcoming(_ fresh: Bool) -> Bool {
        #if DEBUG
        if HomeDebug.fresh { return true }
        #endif
        return fresh && firstDay.showing
    }

    /// "12 ord", "1 word".
    static func words(_ n: Int) -> String {
        n == 1 ? String(localized: "1 ord") : String(localized: "\(Stats.number(n)) ord")
    }

    /// "Håll in" or "Tryck på", as the dictation key works.
    private var pressVerb: String {
        dictation.mode == .toggle ? String(localized: "Tryck på") : String(localized: "Håll in")
    }

    // MARK: Your day

    private func headline(weekWords: Int, fresh: Bool) -> String {
        let today = stats.today.words
        if today > 0 { return today == 1 ? String(localized: "1 ord i dag") : String(localized: "\(Stats.number(today)) ord i dag") }
        if weekWords > 0 { return weekWords == 1 ? String(localized: "1 ord i veckan") : String(localized: "\(Stats.number(weekWords)) ord i veckan") }
        if !fresh { return String(localized: "Inget dikterat i dag än") }
        return dictation.mode == .toggle ? String(localized: "Tryck på \(dictation.hotkey.shortName) och prata")
                                         : String(localized: "Håll in \(dictation.hotkey.shortName) och prata")
    }

    /// Hem is about today (and this week, before today has words); the totals and the
    /// days in a row are on Diktering.
    private func subline(week: [Stats.WeekDay], weekWords: Int, fresh: Bool) -> String {
        let today = stats.today
        var parts: [String] = []
        if today.words > 0 {
            if today.savedSeconds >= 60 { parts.append(Stats.saved(today.savedSeconds, .today)) }
        } else if weekWords > 0 {
            let saved = week.reduce(0) { $0 + $1.stat.savedSeconds }
            parts.append(String(localized: "Inget dikterat i dag än."))
            if saved >= 60 { parts.append(Stats.saved(saved, .week)) }
        } else if !fresh {
            // A new week (a Monday morning) — not a new user.
            parts.append(String(localized: "Texten skrivs där markören står, i vilken app som helst."))
        } else {
            parts.append(String(localized: "Texten skrivs där markören står, i vilken app som helst."))
        }
        return parts.joined(separator: "\n")
    }

    /// The week in small capitals, then Monday to Sunday as bars on a thin baseline:
    /// today in ink, the days before in grey, the days to come as faint stubs.
    private func weekChart(_ week: [Stats.WeekDay], weekWords: Int) -> some View {
        let top = max(1, week.map(\.stat.words).max() ?? 1)
        let bar: CGFloat = 20, gap: CGFloat = 8, tall: CGFloat = 54
        var cal = Calendar.current; cal.locale = AppLanguage.locale
        let names = cal.shortStandaloneWeekdaySymbols
        let weekday = { (d: Date) in d.formatted(Date.FormatStyle().weekday(.wide).locale(AppLanguage.locale)) }
        // One element for VoiceOver: the days said, not seven stops.
        let spoken = week.filter { !$0.isFuture }.map { day in
            (day.isToday ? String(localized: "i dag") : weekday(day.date)) + " " + Self.words(day.stat.words)
        }.joined(separator: ", ")
        let title = weekWords > 0 ? String(localized: "Vecka \(stats.weekNumber)") + " · " + Self.words(weekWords)
                                  : String(localized: "Vecka \(stats.weekNumber)")
        return VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(1.4).monospacedDigit()
                .foregroundStyle(DS.Colors.muted).lineLimit(1).fixedSize()
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(day.isFuture ? DS.Colors.divider
                                  : day.stat.words > 0 ? (day.isToday ? DS.Colors.ink : DS.Colors.barPast) : DS.Colors.fieldStroke)
                            .frame(width: bar, height: max(3, tall * CGFloat(day.stat.words) / CGFloat(top)))
                            .help(Text(verbatim: weekday(day.date) + ": " + Self.words(day.stat.words)))
                    }
                }
                Rectangle().fill(DS.Colors.barBase).frame(width: 7 * bar + 6 * gap, height: 1).padding(.top, 3)
                HStack(spacing: gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        Text(verbatim: names[cal.component(.weekday, from: day.date) - 1].lowercased())
                            .font(.system(size: 10.5, weight: day.isToday ? .semibold : .regular))
                            .foregroundStyle(day.isToday ? ink : DS.Colors.faint)
                            .lineLimit(1).fixedSize()
                            .frame(width: bar)
                    }
                }
                .padding(.top, 7)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15), value: week.map(\.stat.words))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(localized: "Vecka \(stats.weekNumber)") + ": " + spoken))
    }

    // MARK: Under the line

    /// How to start, on the left; the buttons on the right. While a meeting goes on:
    /// the way to it, and pause and stop.
    private var bottomRow: some View {
        HStack(alignment: .center, spacing: 16) {
            if session.isRecording || { if case .finishing = session.phase { return true } else { return false } }() {
                showMeeting
            } else if !welcoming(stats.totalWords == 0) {
                dictationHint
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if session.isRecording {
                    meetingButtons
                } else {
                    startButtons
                }
            }
        }
    }

    /// "Håll in ⌥ Opt → för att diktera", the key as a chip.
    private var dictationHint: some View {
        HStack(spacing: 6) {
            Text(verbatim: pressVerb)
            KeyChip(text: dictation.hotkey.chip, small: true)
            Text("för att diktera")
        }
        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dictation.mode == .toggle ? Text("Tryck på \(dictation.hotkey.inlineName) för att diktera")
                                                      : Text("Håll in \(dictation.hotkey.inlineName) för att diktera"))
    }

    @ViewBuilder private var startButtons: some View {
        // Dictating or saying a thought holds the microphone; a moment after (a thought
        // saved, text copied) it is free again.
        let micBusy = dictation.phase == .recording || dictation.phase == .transcribing
        let busy = String(localized: "Går att göra när dikteringen är klar")
        tileButton("Säg en tanke", primary: false, keys: Settings.thoughtShortcut?.chip,
                   help: micBusy ? busy : String(localized: "Säg det du kommer på, så sparas det i Tankar")) { dictation.startThought() }
            .disabled(micBusy || !dictation.engine.isInstalled)
        // A thought can be said while the last meeting is written out; the next meeting waits.
        if case .finishing = session.phase {
        } else if voices.state == .ready, dictation.engine.isInstalled {
            tileButton("Starta möte", dot: true, primary: true, keys: meetingKeys,
                       help: micBusy ? busy : String(localized: "Spela in ett möte i rummet")) {
                // To the start card, waiting for your choice: nothing is recorded yet.
                session.armed = true
                page = .meetings
            }
            .disabled(micBusy)
        } else {
            tileButton("Kom igång med möten", icon: "person.2.wave.2", primary: true, keys: nil,
                       help: String(localized: "Hämta det som behövs för möten")) {
                page = .meetings
            }
        }
    }

    // MARK: The meeting going on

    @ViewBuilder private var meetingButtons: some View {
        if let stopAt = session.stopAt {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let left = max(0, stopAt.timeIntervalSince(context.date))
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(ink.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: left / MeetingSession.undoSeconds)
                            .stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                    Text("Avslutas om \(Int(left.rounded(.up))) s")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(ink).fixedSize()
                }
                .padding(.trailing, 8)
            }
            tileButton("Ångra", icon: "arrow.uturn.backward", primary: true, keys: nil,
                       help: String(localized: "Mötet fortsätter som om inget hänt")) {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { session.cancelStop() }
            }
        } else {
            tileButton("stop|Avsluta", icon: "stop.fill", primary: false, keys: meetingKeys, help: String(localized: "Avsluta mötet")) {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() }
            }
            if session.isPaused {
                tileButton("resume|Fortsätt", icon: "play.fill", primary: true, keys: "⌥⌘P", help: String(localized: "Fortsätt spela in")) {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { session.resume() }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            } else {
                tileButton("Pausa", icon: "pause.fill", primary: true, keys: "⌥⌘P", help: String(localized: "Pausa mötet")) {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { session.pause() }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
    }

    private var showMeeting: some View {
        Button { page = .meetings } label: {
            HStack(spacing: 5) {
                Text("Visa mötet")
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A button on the tile (TileButtonStyle): ink with paper text, or soft grey. Its
    /// shortcut is in the tooltip and for VoiceOver, not beside it.
    private func tileButton(_ title: LocalizedStringKey, icon: String? = nil, dot: Bool = false, primary: Bool,
                            keys: String?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if dot { Circle().fill(DS.Colors.recording).frame(width: 7, height: 7).accessibilityHidden(true) }
                if let icon { Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).accessibilityHidden(true) }
                Text(title)
            }
        }
        .buttonStyle(TileButtonStyle(primary: primary))
        .help(Text(verbatim: help + (keys.map { "  " + $0 } ?? "")))
        .accessibilityHint(keys.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
    }
}

/// A small ring going round while the speech model is made ready: the tile's
/// "Avslutas om" ring, with no end to count down to. Still with Reduce Motion.
private struct LoadingRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 2)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 + (reduceMotion ? 0 : turn * 360)))
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
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

/// The sphere of light in a tile's own column, in ink: on Hem and on "Nytt möte". It
/// breathes at rest and follows your voice while you dictate; it stops when the
/// window can't be seen.
struct InkSphere: View {
    @ObservedObject var meter: LevelMeter
    let listening: Bool
    /// Off screen for another reason (scrolled away, a file dragged over): no frames drawn.
    var paused = false
    @State private var visible = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let level = listening ? Double(min(1, (meter.levels.suffix(3).max() ?? 0) * 1.6)) : 0.22
        // Plain ink points on the light tile; light added to the dark one. The value comes
        // from the app's appearance (a still picture has no colour scheme); the scheme is
        // read so the body is drawn again when the appearance changes.
        let _ = colorScheme
        let light = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        Constellation(figure: nil, color: DS.Colors.ink, level: level, searching: listening, paused: !visible || paused, onLight: light)
            .opacity(light ? 0.5 : 0.42)
            .onAppear {
                visible = AppDelegate.mainWindowVisible
                // Opened from the menu bar, the page can appear a moment before its window
                // is shown: look again, or the sphere stays frozen on its first, faint frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { visible = AppDelegate.mainWindowVisible }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window.contentViewController is NSHostingController<MainView> else { return }
                visible = window.occlusionState.contains(.visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let window = note.object as? NSWindow, window.contentViewController is NSHostingController<MainView> else { return }
                visible = true
            }
    }
}

/// The meeting going on: the clock, and who has spoken so far. The speakers are
/// counted once a second with the clock, not on every word the meeting publishes.
private struct LiveMeeting: View {
    @ObservedObject var session: MeetingSession
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RecordingMark(session: session, color: ink)
                Text(session.isPaused ? "Mötet är pausat" : "Mötet spelas in").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
            }
            if let start = session.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let speakers = Set((session.record?.words ?? []).compactMap(\.speaker).filter { $0 >= 0 }).count
                    let since = (session.record?.date ?? start).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: MeetingView.duration(session.clock(at: context.date)))
                            .font(.system(size: 56, weight: .regular, design: .serif)).monospacedDigit()
                            .foregroundStyle(ink).padding(.top, 4)
                        Text(verbatim: String(localized: "Sedan \(since)")
                             + (speakers > 0 ? " · " + (speakers == 1 ? String(localized: "1 talare hittills") : String(localized: "\(speakers) talare hittills")) : ""))
                            .font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted).padding(.top, 6)
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
        // A file dropped in the last day first, under its own heading — whatever it was
        // recorded — then the latest meetings, three in all.
        let imported = Array(store.meetings.filter { $0.id != live && $0.recentlyImported() }
            .sorted { ($0.source?.importedAt ?? .distantPast) > ($1.source?.importedAt ?? .distantPast) }.prefix(3))
        let meetings = Array(store.meetings.filter { $0.id != live && !$0.recentlyImported() }.prefix(3 - imported.count))
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
                    if !imported.isEmpty {
                        CapsLabel(String(localized: "Nyligen importerade")).padding(.top, 4)
                        cards(imported)
                    }
                    if meetings.isEmpty {
                        if importer.jobs.isEmpty, imported.isEmpty {
                            hint("person.2.wave.2", "Här hamnar mötena du spelar in eller lägger till, med en sammanfattning du kan läsa direkt.")
                        }
                    } else {
                        cards(meetings)
                    }
                }
            }
            shelf("Tankar", more: open.count > 4 ? "Alla \(open.count) tankar" : "Alla tankar", label: "Alla tankar", action: { page = .thoughts }) {
                if open.isEmpty {
                    if let keys = Settings.thoughtShortcut?.inlineName {
                        hint("lightbulb", "Det du kommer på mitt i något annat. Håll in \(keys) och säg det, så hamnar det här.")
                    } else {
                        hint("lightbulb", "Det du kommer på mitt i något annat. Säg det, så hamnar det här.")
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

    private func cards(_ meetings: [MeetingRecord]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: wide ? 3 : 1),
                  alignment: .leading, spacing: 12) {
            ForEach(meetings) { m in
                MeetingCard(record: m, folder: folders.folder(of: m)?.name,
                            speakers: Set(m.words.compactMap(\.speaker).filter { $0 >= 0 }).count,
                            locked: live != nil, page: $page)
            }
        }
    }

    private func shelf<C: View>(_ title: LocalizedStringKey, more: LocalizedStringKey, label: LocalizedStringKey, action: @escaping () -> Void,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
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
        .padding(.horizontal, 16).padding(.vertical, 14)
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
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(hovering ? DS.Colors.chip : DS.Colors.card))
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                            .padding(10).accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
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

        var body: some View {
            let m = record
            let about = m.summary?.overview
                ?? (!m.finished ? String(localized: "Inspelningen avbröts innan mötet var klart.")
                    : MeetingNotes.isAvailable ? String(localized: "Ingen sammanfattning än.") : String(localized: "Ingen sammanfattning."))
            // Just imported: "Importerad i dag · inspelad 14 aug."; a file with no date: "Datum okänt".
            let when = (m.importMeta() ?? (m.source?.dateKnown == false ? String(localized: "Datum okänt") : MeetingRecord.when(m.date)))
                + " · " + Stats.duration(m.duration)
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
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(hovering && !locked ? DS.Colors.chip : DS.Colors.card))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
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
