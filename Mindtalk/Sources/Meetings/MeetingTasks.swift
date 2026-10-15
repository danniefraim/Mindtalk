import SwiftUI

// MARK: - Att göra, on Möten
//
// The tasks your meetings left you live in each meeting's summary; here they're
// gathered, folded into one line under the start card — "Att göra 16 · från 7
// möten". Opened: by meeting, newest first, each with who and a jump to the moment
// it was said. Ticking one off ticks it in its meeting too — it's the same task.
// The last month's, and the folder's when one is chosen.

struct MeetingTasksBar: View {
    /// Coming from Hem's "16 att göra →": open when the page appears.
    static var openOnArrival = false

    let meetings: [MeetingRecord]
    let open: (UUID, Double?) -> Void
    @AppStorage("meetingTasksOpen") private var expanded = false
    @State private var undo: (task: UUID, meeting: UUID)?
    @State private var hovering = false

    private struct Group: Identifiable {
        let meeting: MeetingRecord
        let tasks: [MeetingSummary.Item]
        var id: UUID { meeting.id }
    }

    var body: some View {
        let limit = Date().addingTimeInterval(-31 * 86_400)
        let groups = meetings.filter { $0.date > limit }.compactMap { m -> Group? in
            let open = (m.summary?.tasks ?? []).filter { $0.done != true }
            return open.isEmpty ? nil : Group(meeting: m, tasks: open)
        }
        let count = groups.reduce(0) { $0 + $1.tasks.count }
        if count > 0 || undo != nil {
            VStack(alignment: .leading, spacing: 0) {
                header(count: count, meetings: groups.count)
                if expanded {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in groupView(group) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .card()
            .animation(.spring(duration: 0.35, bounce: 0.1), value: expanded)
            .animation(.snappy, value: count)
            .onAppear {
                if Self.openOnArrival { expanded = true; Self.openOnArrival = false }
            }
        }
    }

    private func header(count: Int, meetings: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.markTask)
                    Text("Att göra").font(.system(size: 14, weight: .semibold))
                    Text(count == 1 ? String(localized: "1 · från 1 möte")
                         : meetings == 1 ? String(localized: "\(count) · från 1 möte")
                         : String(localized: "\(count) · från \(meetings) möten"))
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(DS.Colors.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Att göra, \(count)"))
            .accessibilityHint(expanded ? "Fäll ihop" : "Visa uppgifterna")
            if let undo {
                Button("Ångra") {
                    withAnimation(.snappy) { MeetingStore.shared.setDone(undo.task, false, in: undo.meeting) }
                    self.undo = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.chip.opacity(hovering && !expanded ? 0.4 : 0)))
        .onHover { hovering = $0 }
    }

    private func groupView(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open(group.meeting.id, nil) } label: {
                HStack(spacing: 6) {
                    Text(group.meeting.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(MeetingRecord.when(group.meeting.date)).font(.system(size: 12)).foregroundStyle(DS.Colors.faint)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Colors.faint)
                }
                .foregroundStyle(DS.Colors.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Öppna mötet")
            VStack(spacing: 0) {
                ForEach(group.tasks) { task in row(task, in: group.meeting) }
            }
        }
    }

    private func row(_ task: MeetingSummary.Item, in meeting: MeetingRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                    MeetingStore.shared.setDone(task.id, true, in: meeting.id)
                }
                let ticked = (task: task.id, meeting: meeting.id)
                undo = ticked
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if undo?.task == ticked.task { withAnimation { undo = nil } }
                }
            } label: {
                Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(DS.Colors.faint)
            }
            .buttonStyle(.plain)
            .help("Klar")
            .accessibilityLabel("Markera som klar")
            Text(task.text + (task.owner.map { " – \($0)" } ?? ""))
                .font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let at = task.at {
                Button { open(meeting.id, at) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 7))
                        Text(MeetingView.duration(at)).monospacedDigit()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(DS.Colors.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Visa där det sades")
            }
        }
        .padding(.vertical, 5)
        .transition(.opacity)
    }
}
