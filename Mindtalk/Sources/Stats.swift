import AppKit

// MARK: - Statistik
//
// Words per day, kept on this Mac only (never the text itself). "Sparad tid"
// compares typing the same words at 40 words a minute — a typical pace — with
// the time you actually spent talking.

struct DayStat: Codable, Equatable {
    var words = 0
    var seconds: Double = 0
    var dictations = 0

    /// Time saved against typing at `Stats.typingWordsPerMinute`.
    var savedSeconds: Double { max(0, Double(words) / Stats.typingWordsPerMinute * 60 - seconds) }
}

@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()
    static let typingWordsPerMinute = 40.0

    /// "2026-09-25" → that day.
    @Published private(set) var days: [String: DayStat] {
        didSet { save() }
    }

    private static let key = "stats"
    private static let keepDays = 400

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Today's key. It moves at midnight — and when the Mac wakes on a new day — so
    /// "i dag" and the week follow the clock rather than wait for the next dictation.
    @Published private(set) var day = Stats.key(for: Date())
    private var dayWatch: [NSObjectProtocol] = []

    private init() {
        #if DEBUG
        if Demo.on { days = Demo.days; return }
        #endif
        let data = UserDefaults.standard.data(forKey: Self.key)
        days = data.flatMap { try? JSONDecoder().decode([String: DayStat].self, from: $0) } ?? [:]
        let roll: @Sendable (Notification) -> Void = { _ in Task { @MainActor in Stats.shared.rollDay() } }
        dayWatch = [
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: roll),
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: roll),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: roll),
        ]
    }

    private func rollDay() {
        let now = Self.key(for: Date())
        if now != day { day = now }
    }

    private func save() {
        #if DEBUG
        if Demo.on { return }
        #endif
        UserDefaults.standard.set(try? JSONEncoder().encode(days), forKey: Self.key)
    }

    static func key(for date: Date) -> String { dayFormatter.string(from: date) }

    func record(text: String, seconds: Double) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return }
        var day = days[Self.key(for: Date()), default: DayStat()]
        day.words += words
        day.seconds += seconds
        day.dictations += 1
        var updated = days
        updated[Self.key(for: Date())] = day
        if updated.count > Self.keepDays {
            for old in updated.keys.sorted().prefix(updated.count - Self.keepDays) { updated[old] = nil }
        }
        days = updated
    }

    var today: DayStat { days[Self.key(for: Date())] ?? DayStat() }
    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalSaved: Double { days.values.reduce(0) { $0 + $1.savedSeconds } }

    /// How fast you talk when you dictate — over everything kept. Nil until there's
    /// a minute of it, so a first "hej" doesn't say 400 words a minute.
    var wordsPerMinute: Int? {
        let seconds = days.values.reduce(0) { $0 + $1.seconds }
        guard seconds >= 60 else { return nil }
        return Int((Double(totalWords) / seconds * 60).rounded())
    }

    /// The day you said the most.
    var bestDay: (date: Date, words: Int)? {
        guard let best = days.max(by: { $0.value.words < $1.value.words }), best.value.words > 0,
              let date = Self.dayFormatter.date(from: best.key) else { return nil }
        return (date, best.value.words)
    }

    /// Swedish weeks: Monday first, ISO week numbers.
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = AppLanguage.locale
        cal.timeZone = .current
        return cal
    }()

    struct WeekDay {
        let date: Date
        let stat: DayStat
        let isToday: Bool
        let isFuture: Bool
    }

    /// This calendar week, Monday to Sunday.
    var week: [WeekDay] {
        let cal = Self.calendar
        let now = Date()
        guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<7).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            let isToday = cal.isDate(date, inSameDayAs: now)
            return WeekDay(date: date, stat: days[Self.key(for: date)] ?? DayStat(),
                           isToday: isToday, isFuture: !isToday && date > now)
        }
    }

    var weekNumber: Int { Self.calendar.component(.weekOfYear, from: Date()) }
    var weekWords: Int { week.reduce(0) { $0 + $1.stat.words } }

    /// Days in a row with at least one dictation, counting today (or up to yesterday).
    var streak: Int {
        let cal = Calendar.current
        var date = Date()
        if days[Self.key(for: date)] == nil { date = cal.date(byAdding: .day, value: -1, to: date) ?? date }
        var count = 0
        while days[Self.key(for: date)] != nil {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return count
    }

    /// "≈ 40 min", "≈ 2 h 5 min", "≈ 45 s".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The same, written out for a sentence: "53 minuter", "1 timme", "2 timmar 5 minuter".
    /// `round`: whole hours from three hours up — "10 timmar", not "10 timmar 26 minuter".
    static func prose(_ seconds: Double, round: Bool = false) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        func m(_ n: Int) -> String { n == 1 ? String(localized: "1 minut") : String(localized: "\(n) minuter") }
        func h(_ n: Int) -> String { n == 1 ? String(localized: "1 timme") : String(localized: "\(n) timmar") }
        if minutes < 60 { return m(minutes) }
        if round, minutes >= 180 { return h(Int((Double(minutes) / 60).rounded())) }
        return minutes % 60 == 0 ? h(minutes / 60) : h(minutes / 60) + " " + m(minutes % 60)
    }

    static func number(_ n: Int) -> String {
        n.formatted(.number.locale(AppLanguage.locale))
    }
}
