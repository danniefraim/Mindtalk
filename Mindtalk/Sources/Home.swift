import SwiftUI

// MARK: - Hem
//
// What Mindtalk does, at a glance: dictate, meetings, thoughts — each with its key
// and what happened last — then the tasks your meetings left you, and how much
// talking instead of typing has saved you.

/// "God eftermiddag" and today's date.
struct HomeGreeting: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.greeting(context.date)).font(DS.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                let day = context.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
                Text(day.prefix(1).uppercased() + day.dropFirst())
                    .font(.system(size: 14)).foregroundStyle(DS.Colors.muted)
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

/// One of the three: an icon, a name, how to start it, what happened last.
private struct HomeTile<Action: View, Detail: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var action: Action
    @ViewBuilder var detail: Detail
    var open: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(DS.Colors.chip)
                    Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.Colors.ink)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                if open != nil {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.faint).opacity(hovering ? 1 : 0.5)
                        .accessibilityHidden(true)
                }
            }
            detail
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            action
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .raised(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { open?() }
        .onHover { hovering = $0 }
    }
}

/// The three tiles: dictate, meetings, thoughts.
struct HomeTiles: View {
    @ObservedObject var dictation: Dictation
    @Binding var page: Page
    @ObservedObject private var stats = Stats.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var thoughts = Thoughts.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14, alignment: .top)], spacing: 14) {
            dictate
            meetings
            thinking
        }
    }

    private var dictate: some View {
        HomeTile(icon: "waveform", title: String(localized: "Diktera")) {
            HStack(spacing: 6) {
                Text("Håll").foregroundStyle(DS.Colors.muted)
                KeyChip(text: dictation.hotkey.chip)
            }
            .font(.system(size: 13))
        } detail: {
            VStack(alignment: .leading, spacing: 4) {
                Text("I vilken app som helst – texten skrivs där markören står.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                let words = stats.today.words
                if words > 0 {
                    Text(words == 1 ? String(localized: "1 ord i dag") : String(localized: "\(Stats.number(words)) ord i dag"))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
            }
        }
    }

    private var meetings: some View {
        let last = store.meetings.first { $0.id != session.record?.id }
        return HomeTile(icon: "person.2.wave.2", title: String(localized: "Möten"), action: {
            if session.isRecording {
                Button { page = .meetings } label: {
                    HStack(spacing: 8) {
                        RecordingDot()
                        Text(session.isPaused ? "Mötet är pausat" : "Mötet spelas in")
                    }
                }
                .buttonStyle(.soft)
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
                Button("Kom igång") { page = .meetings }.buttonStyle(.soft)
            }
        }, detail: {
            if let last {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Senast").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.Colors.faint)
                    Text(last.title).font(.system(size: 13.5, weight: .medium)).lineLimit(2)
                    Text(MeetingRecord.when(last.date) + " · " + MeetingView.duration(last.duration))
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                }
            } else {
                Text("Spela in ett möte i rummet, eller dra in en inspelning – du ser vem som sa vad och får en sammanfattning.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, open: {
            if let last { MeetingsPage.lastOpen = last.id }
            page = .meetings
        })
    }

    private var thinking: some View {
        let latest = thoughts.all.first { !$0.done }
        return HomeTile(icon: "lightbulb", title: String(localized: "Tankar"), action: {
            HStack(spacing: 8) {
                Button {
                    dictation.startThought()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold))
                        Text("Säg en tanke")
                    }
                }
                .buttonStyle(.soft)
                .disabled(dictation.phase == .recording || dictation.phase == .transcribing || !dictation.engine.isInstalled)
                if let chord = Settings.thoughtShortcut { KeyCap(keys: chord.chip.replacingOccurrences(of: " ", with: "")) }
            }
        }, detail: {
            if let latest {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thoughts.openCount == 1 ? String(localized: "1 ny") : String(localized: "\(thoughts.openCount) nya"))
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.Colors.faint)
                    Text(latest.text).font(.system(size: 13.5)).lineLimit(2)
                }
            } else {
                Text("Det du kommer på mitt i något annat – sagt på en sekund, sparat här.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, open: { page = .thoughts })
    }
}

/// "Att göra från dina möten": the open tasks of the last month's summaries.
struct HomeTasks: View {
    @Binding var page: Page
    @ObservedObject private var store = MeetingStore.shared

    private struct Task: Identifiable {
        let item: MeetingSummary.Item
        let meeting: MeetingRecord
        var id: UUID { item.id }
    }

    var body: some View {
        let limit = Date().addingTimeInterval(-31 * 86_400)
        let tasks = store.meetings.filter { $0.date > limit }
            .flatMap { m in (m.summary?.tasks ?? []).filter { $0.done != true }.map { Task(item: $0, meeting: m) } }
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle("Att göra från dina möten")
                    Text("\(tasks.count)").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).padding(.top, 8)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tasks.prefix(6).enumerated()), id: \.element.id) { i, task in
                        if i > 0 { CardDivider() }
                        row(task)
                    }
                }
                .padding(4)
                .card()
                if tasks.count > 6 {
                    Text(String(localized: "Och \(tasks.count - 6) till – i mötenas sammanfattningar."))
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                }
            }
        }
    }

    private func row(_ task: Task) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { store.setDone(task.item.id, true, in: task.meeting.id) }
            } label: {
                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(DS.Colors.faint)
            }
            .buttonStyle(.plain)
            .help("Klar")
            .accessibilityLabel("Markera som klar")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.item.text + (task.item.owner.map { " – \($0)" } ?? ""))
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
                Text(task.meeting.title + " · " + MeetingRecord.when(task.meeting.date))
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            MeetingsPage.lastOpen = task.meeting.id
            page = .meetings
        }
    }
}
