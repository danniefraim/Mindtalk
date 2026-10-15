import SwiftUI

// MARK: - Hem
//
// One ink tile that speaks about your day in big serif — the words you said,
// the time you didn't spend typing, the week as a quiet skyline — with the ways to
// start on its right. While a meeting goes on, the tile is the meeting: the clock,
// pause and stop. Under it, the latest meetings as cards you can read without
// opening, and the thoughts as notes. A meeting's tasks live in its summary —
// Mindtalk isn't a to-do app.

enum HomeGreeting {
    static func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<10: return String(localized: "God morgon")
        case 10..<13: return String(localized: "God förmiddag")
        case 13..<18: return String(localized: "God eftermiddag")
        default: return String(localized: "God kväll")
        }
    }

    /// "Torsdag 15 oktober".
    static func day(_ date: Date) -> String {
        let day = date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
        return day.prefix(1).uppercased() + day.dropFirst()
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

    private var onInk: Color { DS.Colors.onInk }
    private var meetingKeys: String? { Settings.meetingShortcut.map { $0.chip.replacingOccurrences(of: " ", with: "") } }

    var body: some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        layout {
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(verbatim: HomeGreeting.greeting(context.date) + " · " + HomeGreeting.day(context.date))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(onInk.opacity(0.72))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 18)
                if session.isRecording {
                    meeting
                } else if case .finishing(let what) = session.phase {
                    Text("Mötet skrivs ned.").font(.system(size: 44, weight: .regular, design: .serif)).foregroundStyle(onInk)
                    HStack(spacing: 10) {
                        SettlingLine(color: onInk).frame(width: 48)
                        Text(what).font(.system(size: 14)).foregroundStyle(onInk.opacity(0.75))
                    }
                    .padding(.top, 10)
                } else {
                    Text(verbatim: headline).font(.system(size: 44, weight: .regular, design: .serif))
                        .foregroundStyle(onInk).lineLimit(2).minimumScaleFactor(0.7)
                    Text(verbatim: subline).font(.system(size: 14)).foregroundStyle(onInk.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                }
                Spacer(minLength: 26)
                HStack(alignment: .bottom, spacing: 18) {
                    weekBars
                    Spacer()
                    Text(verbatim: stats.weekWords > 0
                         ? String(localized: "Vecka \(stats.weekNumber) · \(Stats.number(stats.weekWords)) ord")
                         : String(localized: "Vecka \(stats.weekNumber)"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(onInk.opacity(0.65)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dictation.needsSetup {
                VStack(alignment: wide ? .trailing : .leading, spacing: 10) {
                    if session.isRecording {
                        meetingButtons
                    } else if session.phase == .idle {
                        startButtons
                    }
                }
            }
        }
        .padding(26)
        .frame(minHeight: 250)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [DS.Colors.ink.opacity(0.86), DS.Colors.ink], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8))
        .animation(.spring(duration: 0.35, bounce: 0.1), value: session.phase)
    }

    // MARK: Your day

    private var headline: String {
        let today = stats.today.words
        if today > 0 { return today == 1 ? String(localized: "1 ord i dag.") : String(localized: "\(Stats.number(today)) ord i dag.") }
        if stats.weekWords > 0 { return String(localized: "Inget sagt än i dag.") }
        return String(localized: "Håll in \(dictation.hotkey.inlineName) och prata.")
    }

    private var subline: String {
        let today = stats.today
        var parts: [String] = []
        if today.words > 0 {
            if today.savedSeconds >= 60 { parts.append(String(localized: "Du slapp skriva i ungefär \(Stats.duration(today.savedSeconds)).")) }
            if stats.streak > 1 { parts.append(String(localized: "\(stats.streak) dagar i rad.")) }
        } else if stats.weekWords > 0 {
            let saved = stats.week.reduce(0) { $0 + $1.stat.savedSeconds }
            parts.append(String(localized: "Den här veckan: \(Stats.number(stats.weekWords)) ord – du slapp skriva i ungefär \(Stats.duration(saved))."))
        } else {
            parts.append(String(localized: "Texten skrivs där markören står – i vilken app som helst."))
        }
        return parts.joined(separator: " ")
    }

    /// Monday to Sunday, today bright, the days to come faint.
    private var weekBars: some View {
        let week = stats.week
        let top = max(1, week.map(\.stat.words).max() ?? 1)
        var cal = Calendar.current; cal.locale = AppLanguage.locale
        let letters = cal.veryShortStandaloneWeekdaySymbols
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(onInk.opacity(day.isFuture ? 0.10 : day.stat.words > 0 ? (day.isToday ? 0.95 : 0.55) : 0.18))
                        .frame(width: 22, height: max(4, 40 * CGFloat(day.stat.words) / CGFloat(top)))
                    Text(verbatim: letters[cal.component(.weekday, from: day.date) - 1].uppercased())
                        .font(.system(size: 10, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(onInk.opacity(day.isToday ? 0.9 : 0.65))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: day.date.formatted(Date.FormatStyle().weekday(.wide).locale(AppLanguage.locale)) + ": " + String(localized: "\(Stats.number(day.stat.words)) ord")))
            }
        }
        .frame(height: 58, alignment: .bottom)
        .animation(.spring(duration: 0.5, bounce: 0.15), value: stats.weekWords)
    }

    @ViewBuilder private var startButtons: some View {
        if voices.state == .ready, dictation.engine.isInstalled {
            inkButton("Starta möte", dot: true, filled: true, keys: meetingKeys, help: "Spela in ett möte i rummet") {
                page = .meetings
                session.start(introducing: true)
            }
            .disabled(dictation.phase == .recording || dictation.phase == .transcribing)
        } else {
            inkButton("Kom igång med möten", icon: "person.2.wave.2", filled: true, keys: nil, help: "Hämta det som behövs för möten") {
                page = .meetings
            }
        }
        inkButton("Säg en tanke", icon: "lightbulb", filled: false,
                  keys: Settings.thoughtShortcut?.chip.replacingOccurrences(of: " ", with: ""),
                  help: "Säg det du kommer på – det sparas i Tankar") { dictation.startThought() }
            .disabled(dictation.phase == .recording || dictation.phase == .transcribing || !dictation.engine.isInstalled)
        HStack(spacing: 5) {
            Text("Håll in").foregroundStyle(onInk.opacity(0.65))
            Text(verbatim: dictation.hotkey.chip).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(onInk.opacity(0.16)))
                .foregroundStyle(onInk)
            Text("och prata").foregroundStyle(onInk.opacity(0.65))
        }
        .font(.system(size: 12.5)).padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Håll in \(dictation.hotkey.inlineName) och prata"))
    }

    // MARK: The meeting going on

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RecordingMark(session: session, color: onInk)
                Text(session.isPaused ? "Mötet är pausat" : "Mötet spelas in").font(.system(size: 15, weight: .semibold)).foregroundStyle(onInk)
            }
            if let start = session.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(verbatim: MeetingView.duration(session.clock(at: context.date)))
                        .font(.system(size: 56, weight: .regular, design: .serif)).monospacedDigit()
                        .foregroundStyle(onInk).padding(.top, 6)
                }
                let voices = Set((session.record?.words ?? []).compactMap(\.speaker).filter { $0 >= 0 }).count
                let since = (session.record?.date ?? start).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.locale))
                Text(verbatim: String(localized: "Sedan \(since)")
                     + (voices > 0 ? " · " + (voices == 1 ? String(localized: "1 röst hittills") : String(localized: "\(voices) röster hittills")) : ""))
                    .font(.system(size: 13.5)).foregroundStyle(onInk.opacity(0.75)).padding(.top, 8)
            }
        }
    }

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
                    Text("Avslutar om \(Int(left.rounded(.up))) s")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(onInk).fixedSize()
                }
                .frame(height: 36)
            }
            inkButton("Ångra", icon: "arrow.uturn.backward", filled: true, keys: nil, help: "Mötet fortsätter som om inget hänt") {
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) { session.cancelStop() }
            }
        } else if session.isPaused {
            inkButton("Fortsätt", icon: "play.fill", filled: true, keys: "⌥⌘P", help: "Fortsätt spela in") {
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) { session.resume() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        } else {
            inkButton("Pausa", icon: "pause.fill", filled: true, keys: "⌥⌘P", help: "Pausa mötet") {
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) { session.pause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
        inkButton("Avsluta", icon: "stop.fill", filled: false, keys: meetingKeys, help: "Avsluta mötet") {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { _ = session.requestStop() }
        }
        Button { page = .meetings } label: {
            HStack(spacing: 5) {
                Text("Visa mötet")
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(onInk.opacity(0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
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
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(onInk.opacity(filled ? 0 : 0.35), lineWidth: 1))
                .foregroundStyle(filled ? DS.Colors.ink : onInk)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .help(help)
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

/// The latest meetings as cards, the thoughts as notes.
struct HomeShelves: View {
    @Binding var page: Page
    var wide = true
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var thoughts = Thoughts.shared
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var folders = MeetingFolders.shared

    var body: some View {
        let meetings = Array(store.meetings.filter { $0.id != session.record?.id }.prefix(3))
        let open = Array(thoughts.all.filter { !$0.done }.prefix(4))
        VStack(alignment: .leading, spacing: 30) {
            shelf("Senaste möten", more: "Alla möten", label: "Alla möten", action: { MeetingsPage.lastOpen = nil; page = .meetings }) {
                if meetings.isEmpty {
                    hint("person.2.wave.2", "Här hamnar mötena du spelar in eller lägger till, med en sammanfattning du kan läsa direkt.")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: wide ? 3 : 1),
                              alignment: .leading, spacing: 12) {
                        ForEach(meetings) { m in MeetingCard(record: m, folder: folders.folder(of: m)?.name, page: $page) }
                    }
                }
            }
            shelf("Tankar", more: "Alla", label: "Alla tankar", action: { page = .thoughts }) {
                if open.isEmpty {
                    hint("lightbulb", "Det du kommer på mitt i något annat – säg det, så ligger det här.")
                } else {
                    FlowLayout(spacing: 10) {
                        ForEach(open) { t in
                            Button { page = .thoughts } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(DS.Colors.faint)
                                    Text(t.text).font(.system(size: 13)).lineLimit(1)
                                }
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .frame(maxWidth: 380, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.card))
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(t.text)
                        }
                    }
                }
            }
        }
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
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
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
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.Colors.faint).frame(width: 18)
            Text(text).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .card()
    }

    /// When, the title, what it was about, who was there.
    private struct MeetingCard: View {
        let record: MeetingRecord
        let folder: String?
        @Binding var page: Page
        @State private var hovering = false

        var body: some View {
            let m = record
            let voices = Set(m.words.compactMap(\.speaker).filter { $0 >= 0 }).count
            let about = m.summary?.overview ?? (m.finished ? String(localized: "Ingen sammanfattning än.") : String(localized: "Avbröts innan det var klart."))
            Button {
                MeetingsPage.lastOpen = m.id
                page = .meetings
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: m.source == nil ? "person.2.wave.2" : (m.source!.video ? "film" : "waveform"))
                            .font(.system(size: 11)).foregroundStyle(DS.Colors.faint)
                        Text(verbatim: MeetingRecord.when(m.date) + " · " + MeetingView.duration(m.duration))
                            .font(.system(size: 11.5)).foregroundStyle(DS.Colors.faint).monospacedDigit()
                    }
                    Text(m.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: about).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    HStack(spacing: 10) {
                        if voices > 0 {
                            Label(voices == 1 ? String(localized: "1 röst") : String(localized: "\(voices) röster"), systemImage: "person.2")
                                .font(.system(size: 11.5))
                        }
                        if let folder { Label(folder, systemImage: "folder").font(.system(size: 11.5)).lineLimit(1) }
                    }
                    .foregroundStyle(DS.Colors.faint)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
                .raised(cornerRadius: 18)
                .scaleEffect(hovering ? 1.012 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .accessibilityElement(children: .combine)
        }
    }
}
