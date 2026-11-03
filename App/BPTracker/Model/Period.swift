import Foundation

/// The span of readings being looked at: a rolling window up to now, or a
/// calendar week, month or year that can be paged through.
struct Period: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case last7, last30, last90, last365, all, week, month, year
        var id: String { rawValue }

        var pickerTitle: String {
            switch self {
            case .last7: "7 days"
            case .last30: "30 days"
            case .last90: "90 days"
            case .last365: "1 year"
            case .all: "All"
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            }
        }

        var days: Int? {
            switch self {
            case .last7: 7
            case .last30: 30
            case .last90: 90
            case .last365: 365
            default: nil
            }
        }

        var calendarUnit: Calendar.Component? {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            default: nil
            }
        }
    }

    var kind: Kind = .last30
    /// Any date inside the calendar period shown.
    var anchor = Date()

    var isCalendar: Bool { kind.calendarUnit != nil }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        if let days = kind.days {
            return DateInterval(start: calendar.date(byAdding: .day, value: -days, to: now)!, end: .distantFuture)
        }
        guard let unit = kind.calendarUnit else { return nil }
        return calendar.dateInterval(of: unit, for: anchor)
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        guard let interval = interval(now: now) else { return true }
        return date >= interval.start && date < interval.end
    }

    var title: String {
        switch kind {
        case .all: return "All readings"
        case .week:
            let start = interval()?.start ?? anchor
            return "Week of \(start.formatted(date: .abbreviated, time: .omitted))"
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .year: return anchor.formatted(.dateTime.year())
        default: return "Last \(kind.pickerTitle)"
        }
    }

    mutating func step(by offset: Int, calendar: Calendar = .current) {
        guard let unit = kind.calendarUnit else { return }
        anchor = calendar.date(byAdding: unit, value: offset, to: anchor) ?? anchor
    }

    func canStepForward(now: Date = Date()) -> Bool {
        guard isCalendar, let interval = interval(now: now) else { return false }
        return interval.end <= now
    }
}
