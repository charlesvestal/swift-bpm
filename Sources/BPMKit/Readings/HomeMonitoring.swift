import Foundation

/// A home blood-pressure monitoring week as the ESH recommends: for seven
/// days, two readings a minute or two apart each morning and each evening.
/// The first day is practice and left out; the result is the average of all
/// remaining readings, which should be at least 12. A home average of
/// 135/85 or more is considered raised.
public struct HomeMonitoringPlan: Sendable, Equatable {
    /// Any time on the first day; days run midnight to midnight in `calendar`.
    public var start: Date
    public var days: Int
    public var discardFirstDay: Bool

    public static let minimumReadings = 12
    public static let minimumDays = 3
    public static let readingsPerSession = 2
    public static let homeThresholds = BPThresholds(systolic: 135, diastolic: 85)

    public init(start: Date, days: Int = 7, discardFirstDay: Bool = true) {
        self.start = start
        self.days = days
        self.discardFirstDay = discardFirstDay
    }

    public func firstDay(calendar: Calendar = .current) -> Date { calendar.startOfDay(for: start) }

    public func end(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: firstDay(calendar: calendar))!
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        date >= firstDay(calendar: calendar) && date < end(calendar: calendar)
    }

    /// 0-based day of the plan, or nil outside it.
    public func dayIndex(of date: Date, calendar: Calendar = .current) -> Int? {
        guard contains(date, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: firstDay(calendar: calendar), to: calendar.startOfDay(for: date)).day
    }

    /// The moment each session is due, for reminders: `morning` and `evening`
    /// are minutes after midnight.
    public func sessionTimes(morning: Int, evening: Int, calendar: Calendar = .current) -> [(day: Int, session: HomeSession, date: Date)] {
        (0..<days).flatMap { day -> [(Int, HomeSession, Date)] in
            let date = calendar.date(byAdding: .day, value: day, to: firstDay(calendar: calendar))!
            return [(HomeSession.morning, morning), (.evening, evening)].map { session, minutes in
                (day, session, calendar.date(byAdding: .minute, value: minutes, to: date)!)
            }
        }
    }
}

public enum HomeSession: Int, CaseIterable, Sendable {
    /// Readings before noon.
    case morning
    case evening

    public init(date: Date, calendar: Calendar = .current) {
        self = calendar.component(.hour, from: date) < 12 ? .morning : .evening
    }

    public var title: String { self == .morning ? "Morning" : "Evening" }
}

public struct HomeMonitoringResult: Sendable {
    public struct Day: Sendable {
        public var index: Int
        public var date: Date
        public var morning: [BPPoint]
        public var evening: [BPPoint]
        /// Practice day, left out of the averages.
        public var excluded: Bool

        public func readings(_ session: HomeSession) -> [BPPoint] { session == .morning ? morning : evening }
        public func isComplete(_ session: HomeSession) -> Bool {
            readings(session).count >= HomeMonitoringPlan.readingsPerSession
        }
    }

    public var plan: HomeMonitoringPlan
    public var days: [Day]
    /// Readings that count towards the result.
    public var included: [BPPoint]
    public var summary: BPSummary
    public var morning: BPSummary
    public var evening: BPSummary

    public var expectedSessions: Int { days.filter { !$0.excluded }.count * HomeSession.allCases.count }
    public var completedSessions: Int {
        days.filter { !$0.excluded }.map { day in HomeSession.allCases.filter { day.isComplete($0) }.count }.reduce(0, +)
    }
    public var daysWithReadings: Int { days.filter { !$0.excluded && !($0.morning.isEmpty && $0.evening.isEmpty) }.count }

    /// Enough data for a meaningful average: at least 12 readings over at least 3 days.
    public var meetsMinimum: Bool {
        included.count >= HomeMonitoringPlan.minimumReadings && daysWithReadings >= HomeMonitoringPlan.minimumDays
    }

    /// Whether the average reaches the 135/85 home threshold; nil without readings.
    public var isRaised: Bool? {
        guard let s = summary.systolic, let d = summary.diastolic else { return nil }
        return HomeMonitoringPlan.homeThresholds.isAbove(systolic: s.mean, diastolic: d.mean)
    }

    public init(points: [BPPoint], plan: HomeMonitoringPlan, guideline: BPGuideline = .esh2023, calendar: Calendar = .current) {
        self.plan = plan
        let inPlan = points.filter { plan.contains($0.timestamp, calendar: calendar) }.sorted { $0.timestamp < $1.timestamp }
        let byDay = Dictionary(grouping: inPlan) { plan.dayIndex(of: $0.timestamp, calendar: calendar)! }
        days = (0..<plan.days).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: plan.firstDay(calendar: calendar))!
            let readings = byDay[index] ?? []
            return Day(index: index, date: date,
                       morning: readings.filter { HomeSession(date: $0.timestamp, calendar: calendar) == .morning },
                       evening: readings.filter { HomeSession(date: $0.timestamp, calendar: calendar) == .evening },
                       excluded: plan.discardFirstDay && index == 0)
        }
        included = days.filter { !$0.excluded }.flatMap { $0.morning + $0.evening }
        let thresholds = HomeMonitoringPlan.homeThresholds
        summary = BPSummary(included, thresholds: thresholds, guideline: guideline)
        morning = BPSummary(days.filter { !$0.excluded }.flatMap(\.morning), thresholds: thresholds, guideline: guideline)
        evening = BPSummary(days.filter { !$0.excluded }.flatMap(\.evening), thresholds: thresholds, guideline: guideline)
    }
}
