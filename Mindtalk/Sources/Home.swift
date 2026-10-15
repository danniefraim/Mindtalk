import SwiftUI

// MARK: - Hem
//
// One job: start something, and see what just happened. The greeting with today's
// words; one line on dictating (a key you hold, not a button); a button for a
// meeting and one for a thought; then one list of the last days — meetings,
// imported recordings and thoughts together, newest first. A meeting's tasks live
// in the meeting (and gathered on Möten); here at most one quiet line about them.

/// "God eftermiddag" — and today's date, with the words dictated so far.
struct HomeGreeting: View {
    @ObservedObject private var stats = Stats.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.greeting(context.date)).font(DS.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                let day = context.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
                let words = stats.today.words
                Text(day.prefix(1).uppercased() + day.dropFirst()
                     + (words > 0 ? " · " + (words == 1 ? String(localized: "1 ord dikterat i dag")
                                                        : String(localized: "\(Stats.number(words)) ord dikterade i dag")) : ""))
                    .font(.system(size: 14)).foregroundStyle(DS.Colors.muted).monospacedDigit()
            }
        }
    }

    static func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<10: return String(localized: "God morgon")
        case 10..<13: return String(localized: "God förmiddag")
        case 13..<18: return String(localized: "God eftermiddag")
        default: return String(localized: "God kväll")
        }
    }
}

/// How to start: dictating (a line — it's a key you hold), a meeting, a thought.
struct HomeActions: View {
    @ObservedObject var dictation: Dictation
    @Binding var page: Page
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var voices = VoiceModels.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Håll").foregroundStyle(DS.Colors.muted)
                KeyChip(text: dictation.hotkey.chip)
                Text("var som helst och prata – texten skrivs där markören står.").foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13.5))
            FlowLayout(spacing: 12) {
                meetingButton
                thoughtButton
            }
        }
    }

    @ViewBuilder private var meetingButton: some View {
        if session.isRecording {
            // A meeting going on: where it is, one click away.
            Button { page = .meetings } label: {
                HStack(spacing: 8) {
                    RecordingMark(session: session, color: .primary)
                    Text(session.isPaused ? "Mötet är pausat" : "Mötet spelas in")
                    if let start = session.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(MeetingView.duration(session.clock(at: context.date))).monospacedDigit()
                                .foregroundStyle(DS.Colors.muted)
                        }
                    }
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.soft)
        } else if case .finishing(let what) = session.phase {
            HStack(spacing: 10) {
                SettlingLine(color: DS.Colors.ink).frame(width: 48)
                Text(what).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            }
        } else if voices.state == .ready, dictation.engine.isInstalled {
            HStack(spacing: 8) {
                Button {
                    page = .meetings
                    session.start(introducing: true)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(DS.Colors.recording).frame(width: 8, height: 8)
                        Text("Starta möte")
                    }
                }
                .buttonStyle(.ink)
                .disabled(dictation.phase != .idle)
                KeyCap(keys: "⇧⌘R")
            }
        } else {
            Button { page = .meetings } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.wave.2").font(.system(size: 12, weight: .semibold))
                    Text("Kom igång med möten")
                }
            }
            .buttonStyle(.soft)
        }
    }

    private var thoughtButton: some View {
        HStack(spacing: 8) {
            Button { dictation.startThought() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb").font(.system(size: 12, weight: .semibold))
                    Text("Säg en tanke")
                }
            }
            .buttonStyle(.soft)
            .disabled(dictation.phase == .recording || dictation.phase == .transcribing || !dictation.engine.isInstalled
                      || session.isRecording)
            if let chord = Settings.thoughtShortcut { KeyCap(keys: chord.chip.replacingOccurrences(of: " ", with: "")) }
        }
    }
}

/// The last week: meetings, recordings and thoughts, newest first, by day.
struct HomeFeed: View {
    @Binding var page: Page
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var thoughts = Thoughts.shared
    @ObservedObject private var session = MeetingSession.shared

    private enum Item: Identifiable {
        case meeting(MeetingRecord)
        case thought(Thought)
        var id: UUID { switch self { case .meeting(let m): m.id; case .thought(let t): t.id } }
        var date: Date { switch self { case .meeting(let m): m.date; case .thought(let t): t.date } }
    }

    var body: some View {
        let week = Date().addingTimeInterval(-7 * 86_400)
        let all = (store.meetings.filter { $0.date > week && $0.id != session.record?.id }.map(Item.meeting)
                   + thoughts.all.filter { !$0.done && $0.date > week }.map(Item.thought))
            .sorted { $0.date > $1.date }
        // A glance, not the archive: the latest seven — the rest a click away.
        let items = Array(all.prefix(7))
        let more = all.count - items.count
        let tasks = store.meetings.filter { $0.date > Date().addingTimeInterval(-31 * 86_400) }
            .reduce(0) { $0 + ($1.summary?.tasks.filter { $0.done != true }.count ?? 0) }
        VStack(alignment: .leading, spacing: 18) {
            if items.isEmpty {
                empty
            } else {
                ForEach(days(items), id: \.title) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(Array(day.items.enumerated()), id: \.element.id) { i, item in
                                if i > 0 { CardDivider() }
                                HomeRow(item: item, page: $page)
                            }
                        }
                        .padding(4)
                        .card()
                    }
                }
            }
            if more > 0 {
                Button { MeetingsPage.lastOpen = nil; page = .meetings } label: {
                    HStack(spacing: 6) {
                        Text(more == 1 ? String(localized: "1 till den här veckan") : String(localized: "\(more) till den här veckan"))
                        Image(systemName: "arrow.right").font(.system(size: 10.5, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -8)
            }
            if tasks > 0 {
                Button {
                    MeetingTasksBar.openOnArrival = true
                    MeetingsPage.lastOpen = nil
                    page = .meetings
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist").foregroundStyle(DS.Colors.markTask)
                        Text(tasks == 1 ? String(localized: "1 att göra från dina möten")
                                        : String(localized: "\(tasks) att göra från dina möten"))
                            .font(.system(size: 13.5, weight: .medium))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Visa uppgifterna på sidan Möten")
            }
        }
    }

    /// Nothing this week: what the page will hold, said once.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            hint("person.2.wave.2", "Möten du spelar in eller drar in hamnar här.")
            CardDivider()
            hint("lightbulb", "Tankar du säger också – det du kommer på mitt i något annat.")
        }
        .padding(4)
        .card()
    }

    private func hint(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.Colors.faint).frame(width: 18)
            Text(text).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func days(_ items: [Item]) -> [(title: String, items: [Item])] {
        let calendar = Calendar.current
        var out: [(title: String, items: [Item])] = []
        for item in items {
            let title = calendar.isDateInToday(item.date) ? String(localized: "I dag")
                : calendar.isDateInYesterday(item.date) ? String(localized: "I går") : String(localized: "Tidigare i veckan")
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    /// One line: what it is, its name, its tasks, when.
    private struct HomeRow: View {
        let item: Item
        @Binding var page: Page
        @State private var hovering = false

        var body: some View {
            Button(action: open) {
                HStack(spacing: 12) {
                    switch item {
                    case .meeting(let m):
                        Image(systemName: m.source == nil ? "person.2.wave.2" : (m.source!.video ? "film" : "waveform"))
                            .font(.system(size: 12)).foregroundStyle(DS.Colors.muted).frame(width: 20)
                        Text(m.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 12)
                        let open = m.summary?.tasks.filter { $0.done != true }.count ?? 0
                        if open > 0 {
                            Text(open == 1 ? String(localized: "1 att göra") : String(localized: "\(open) att göra"))
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.Colors.markTask)
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(Capsule().fill(DS.Colors.markTask.opacity(0.12)))
                        }
                        Text(m.date.formatted(date: .omitted, time: .shortened) + " · " + MeetingView.duration(m.duration))
                            .font(.system(size: 12)).foregroundStyle(DS.Colors.faint).monospacedDigit()
                    case .thought(let t):
                        Image(systemName: "lightbulb").font(.system(size: 12)).foregroundStyle(DS.Colors.muted).frame(width: 20)
                        Text(t.text).font(.system(size: 14)).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(t.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(DS.Colors.faint).monospacedDigit()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.chip.opacity(hovering ? 0.6 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }

        private func open() {
            switch item {
            case .meeting(let m):
                MeetingsPage.lastOpen = m.id
                page = .meetings
            case .thought:
                page = .thoughts
            }
        }
    }
}
