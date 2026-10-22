import Combine
import SwiftUI

// MARK: - Personer
//
// The people named in your meetings, as a row of chips under the folders: their
// voice figure, their name and how many meetings they're in. A chip pressed shows
// only the meetings where that person has a named voice, in the folder chosen; pressed
// again, all of them. A speaker never named ("Talare 2") is nobody here. You are
// counted like anyone else.

@MainActor
final class MeetingPeople: ObservableObject {
    static let shared = MeetingPeople()

    struct Person: Identifiable, Equatable {
        /// The name in lower case: "anna" and "Anna" are one person.
        let key: String
        /// As written in the newest meeting that names them.
        let name: String
        let meetings: Set<UUID>
        var id: String { key }
        var count: Int { meetings.count }
    }

    /// Everyone named, the most meetings first.
    @Published private(set) var people: [Person] = []
    /// How many meetings name anyone at all.
    @Published private(set) var namedMeetings = 0
    /// The person chosen (their key) — nil: everyone. Kept while you visit other pages,
    /// like the folder, not across launches.
    @Published var selected: String?

    private var watching: AnyCancellable?

    private init() {
        update(MeetingStore.shared.meetings)
        // Worked out once per change of the meetings, not per row or per frame: the
        // list asks for it on every redraw.
        watching = MeetingStore.shared.$meetings.sink { [weak self] in self?.update($0) }
    }

    /// The row once there's something to choose between: two people, six meetings with names.
    var worthShowing: Bool { people.count >= 2 && namedMeetings >= 6 }

    var chosen: Person? { selected.flatMap { key in people.first { $0.key == key } } }

    /// The meetings with the person chosen; all of them when nobody is.
    func filter(_ records: [MeetingRecord]) -> [MeetingRecord] {
        guard let person = chosen else { return records }
        return records.filter { person.meetings.contains($0.id) }
    }

    func toggle(_ person: Person) {
        selected = selected == person.key ? nil : person.key
    }

    private func update(_ meetings: [MeetingRecord]) {
        var names: [String: String] = [:]
        var found: [String: Set<UUID>] = [:]
        var named = 0
        for record in meetings {
            var any = false
            for raw in record.names.values {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !Self.isNumbered(name) else { continue }
                let key = name.lowercased()
                if names[key] == nil { names[key] = name }
                found[key, default: []].insert(record.id)
                any = true
            }
            if any { named += 1 }
        }
        let unsorted: [Person] = found.map { key, ids in Person(key: key, name: names[key] ?? key, meetings: ids) }
        let new = unsorted.sorted { (a: Person, b: Person) -> Bool in
            if a.count != b.count { return a.count > b.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if new != people { people = new }
        if named != namedMeetings { namedMeetings = named }
        // Renamed or gone: nobody chosen, rather than an empty list for a name no longer there.
        if let key = selected, !new.contains(where: { $0.key == key }) { selected = nil }
    }

    /// "Talare 2", "Speaker 3": a number, not a name, even when typed in by hand.
    private static func isNumbered(_ name: String) -> Bool {
        let parts = name.split(separator: " ")
        guard parts.count == 2, Int(parts[1]) != nil else { return false }
        return ["talare", "speaker"].contains(parts[0].lowercased())
    }
}

/// The row of people in the list's pinned header: up to eight chips, the rest in "Fler…".
struct PeopleBar: View {
    @ObservedObject var people: MeetingPeople
    static let chips = 8

    var body: some View {
        let all = people.people
        let first = Array(all.prefix(Self.chips))
        let rest = Array(all.dropFirst(Self.chips))
        // Chosen from "Fler…": its chip comes first in the row, so you see who is chosen
        // even when the row runs past the window's edge.
        let extra = rest.first { $0.key == people.selected }
        HStack(spacing: 12) {
            CapsLabel(String(localized: "Personer")).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let extra {
                        PersonChip(person: extra, tint: SpeakerMark.fill(Self.chips), selected: true) { choose(extra) }
                            .transition(.opacity)
                    }
                    ForEach(Array(first.enumerated()), id: \.element.id) { n, person in
                        PersonChip(person: person, tint: SpeakerMark.fill(n), selected: people.selected == person.key) {
                            choose(person)
                        }
                    }
                    if !rest.isEmpty { more(rest) }
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Personer")
    }

    /// Everyone after the first eight, the most meetings first.
    private func more(_ rest: [MeetingPeople.Person]) -> some View {
        Menu {
            ForEach(rest) { person in
                Button { choose(person) } label: {
                    if people.selected == person.key {
                        Label { Text(verbatim: "\(person.name) (\(person.count))") } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: "\(person.name) (\(person.count))")
                    }
                }
            }
        } label: {
            Text("Fler…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.muted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(DS.Colors.chip.opacity(0.7)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Fler personer")
        .accessibilityLabel(rest.count == 1 ? String(localized: "En person till") : String(localized: "\(rest.count) personer till"))
    }

    private func choose(_ person: MeetingPeople.Person) {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { people.toggle(person) }
    }
}

/// One person: their voice figure in a quiet colour, their name, how many meetings.
/// Chosen, ink with paper text and an × — pressed again, everyone.
private struct PersonChip: View {
    let person: MeetingPeople.Person
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // The same figure as beside their name in the list's rows.
                VoiceFigureView(figure: VoiceFigure.remembered(person.name) ?? VoiceFigure.from(seed: person.name),
                                color: selected ? DS.Colors.onInk : tint, size: .compact, diameter: 18, tinted: true)
                Text(verbatim: person.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text(verbatim: "\(person.count)")
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(DS.Colors.onInk.opacity(0.65)) : AnyShapeStyle(DS.Colors.muted))
                if selected {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(DS.Colors.onInk.opacity(0.75))
                        .padding(.leading, 1)
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(DS.Colors.onInk) : AnyShapeStyle(DS.Colors.muted))
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 28)
            .background(Capsule().fill(selected ? DS.Colors.ink : DS.Colors.chip.opacity(hovering ? 1 : 0.7)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(selected ? String(localized: "Visa alla möten igen") : String(localized: "Visa bara möten med \(person.name)"))
        .accessibilityLabel(person.count == 1 ? String(localized: "\(person.name), 1 möte") : String(localized: "\(person.name), \(person.count) möten"))
        .accessibilityHint(selected ? String(localized: "Visar alla möten igen") : String(localized: "Visar bara möten med \(person.name)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
