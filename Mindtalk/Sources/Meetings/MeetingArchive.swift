import SwiftUI

// MARK: - The meetings, grouped
//
// The recent ones as they've always been — "I dag", "I går", "Tidigare i veckan",
// "Tidigare i oktober" — and last month open too. Older months fold into a line each
// ("September 2026 · 14 möten · Anna, Erik"), older years into one line that opens
// to its months; opened, an old month shows its meetings a line each. What you open
// or close is remembered.

struct ArchiveSection: Identifiable {
    enum Kind { case recent, month, year }
    let id: String
    let title: String
    let kind: Kind
    var meetings: [MeetingRecord] = []
    /// A year's months.
    var months: [ArchiveSection] = []
    /// Open unless you've closed it: the recent ones and last month.
    var openByDefault = false
    /// One day ("I går", "Onsdag 14 oktober"): its rows say the time, not the day.
    var day = false

    var count: Int { kind == .year ? months.reduce(0) { $0 + $1.count } : meetings.count }

    /// Grouped for the list, newest first. `others`: all meetings, to tell who is in
    /// nearly all of them (you, most likely) — not named on a folded line.
    static func sections(_ records: [MeetingRecord], now: Date = Date()) -> [ArchiveSection] {
        let calendar = Calendar.current
        let thisMonth = calendar.dateComponents([.year, .month], from: now)
        let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let lastMonth = calendar.dateComponents([.year, .month], from: lastMonthDate)
        var out: [ArchiveSection] = []
        func append(_ id: String, _ title: String, _ kind: Kind, _ record: MeetingRecord, open: Bool, day: Bool = false) {
            if let i = out.lastIndex(where: { $0.id == id }) { out[i].meetings.append(record) }
            else { out.append(ArchiveSection(id: id, title: title, kind: kind, meetings: [record], openByDefault: open, day: day)) }
        }
        var years: [Int: [String: ArchiveSection]] = [:]
        var yearOrder: [Int] = []
        for record in records {
            let parts = calendar.dateComponents([.year, .month], from: record.date)
            let monthID = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            if calendar.isDateInToday(record.date) {
                append("today", String(localized: "I dag"), .recent, record, open: true, day: true)
            } else if calendar.isDateInYesterday(record.date) {
                append("yesterday", String(localized: "I går"), .recent, record, open: true, day: true)
            } else if let days = calendar.dateComponents([.day], from: record.date, to: now).day, days < 7, record.date < now {
                // The rest of the week: a heading per day — "Onsdag 14 oktober".
                let start = calendar.startOfDay(for: record.date)
                let name = record.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
                append("day-\(Int(start.timeIntervalSince1970))", name.prefix(1).uppercased() + name.dropFirst(), .recent, record,
                       open: true, day: true)
            } else if parts.year == thisMonth.year, parts.month == thisMonth.month {
                append("month-now", String(localized: "Tidigare i \(monthName(record.date, year: false))"), .recent, record, open: true)
            } else if parts.year == thisMonth.year || (parts.year == lastMonth.year && parts.month == lastMonth.month) {
                append(monthID, monthName(record.date, year: true), .month, record,
                       open: parts.year == lastMonth.year && parts.month == lastMonth.month)
            } else {
                // Earlier years: a line each, opening to their months.
                let year = parts.year ?? 0
                if years[year] == nil { years[year] = [:]; yearOrder.append(year) }
                let name = monthName(record.date, year: false)
                var month = years[year]![monthID] ?? ArchiveSection(id: monthID, title: name.prefix(1).uppercased() + name.dropFirst(),
                                                                     kind: .month)
                month.meetings.append(record)
                years[year]![monthID] = month
            }
        }
        for year in yearOrder {
            let months = years[year]!.values.sorted { $0.id > $1.id }
            out.append(ArchiveSection(id: "year-\(year)", title: String(year), kind: .year, months: months))
        }
        return out
    }

    static func monthName(_ date: Date, year: Bool) -> String {
        let style = year ? Date.FormatStyle().month(.wide).year() : Date.FormatStyle().month(.wide)
        let name = date.formatted(style.locale(AppLanguage.locale))
        return year ? name.prefix(1).uppercased() + name.dropFirst() : name
    }

    /// Who was in this group's meetings, the most often first — leaving out anyone in
    /// most of all your meetings (that's you).
    func people(among all: [MeetingRecord]) -> [String] {
        let everyone = all.count >= 5 ? Dictionary(all.flatMap { Set($0.names.values.filter { !$0.isEmpty }) }.map { ($0, 1) },
                                                    uniquingKeysWith: +) : [:]
        let list = kind == .year ? months.flatMap(\.meetings) : meetings
        var count: [String: Int] = [:]
        for m in list { for n in Set(m.names.values.filter { !$0.isEmpty }) { count[n, default: 0] += 1 } }
        return count.filter { Double(everyone[$0.key] ?? 0) <= Double(all.count) * 0.6 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3).map(\.key)
    }
}

/// Which groups you've opened or closed, kept between launches.
@MainActor
final class ArchiveOpen: ObservableObject {
    static let shared = ArchiveOpen()
    @Published private var overrides: [String: Bool]
    private static let key = "meetingsArchiveOpen"

    private init() {
        overrides = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Bool]) ?? [:]
    }

    func isOpen(_ section: ArchiveSection) -> Bool {
        section.kind == .recent ? true : overrides[section.id] ?? section.openByDefault
    }

    func toggle(_ section: ArchiveSection) {
        overrides[section.id] = !isOpen(section)
        UserDefaults.standard.set(overrides, forKey: Self.key)
    }
}

/// A folded month or year: its name, how many meetings, who was in them — a click opens it.
struct ArchiveHeader: View {
    let section: ArchiveSection
    let open: Bool
    let people: [String]
    var nested = false
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(DS.Colors.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14)
                Text(section.title)
                    .font(.system(size: nested ? 14 : 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colors.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.chip.opacity(hovering ? 0.5 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, nested ? 0 : 4)
        .accessibilityLabel("\(section.title), \(summary)")
        .accessibilityHint(open ? "Fäll ihop" : "Visa mötena")
        .accessibilityAddTraits(.isHeader)
    }

    private var summary: String {
        let n = section.count == 1 ? String(localized: "1 möte") : String(localized: "\(section.count) möten")
        return people.isEmpty ? n : n + " · " + people.joined(separator: ", ")
    }
}
