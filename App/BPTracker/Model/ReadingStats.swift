import BPMKit
import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case week = "7 days"
    case month = "30 days"
    case quarter = "90 days"
    case year = "1 year"
    case all = "All"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .all: nil
        }
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        guard let days else { return true }
        return date >= Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }
}

struct ReadingStats {
    struct Range { var min: Int; var max: Int; var mean: Double }

    var count: Int
    var systolic: Range?
    var diastolic: Range?
    var pulse: Range?
    var irregularCount: Int
    var first: Date?
    var last: Date?
    var categories: [BPCategory: Int]

    init(_ readings: [Reading]) {
        func range(_ values: [Int]) -> Range? {
            guard let min = values.min(), let max = values.max() else { return nil }
            return Range(min: min, max: max, mean: Double(values.reduce(0, +)) / Double(values.count))
        }
        count = readings.count
        systolic = range(readings.map(\.systolic))
        diastolic = range(readings.map(\.diastolic))
        pulse = range(readings.compactMap(\.pulse))
        irregularCount = readings.filter(\.irregularHeartbeat).count
        first = readings.map(\.timestamp).min()
        last = readings.map(\.timestamp).max()
        categories = Dictionary(grouping: readings, by: \.category).mapValues(\.count)
    }

    var averageCategory: BPCategory? {
        guard let systolic, let diastolic else { return nil }
        return BPCategory(systolic: Int(systolic.mean.rounded()), diastolic: Int(diastolic.mean.rounded()))
    }
}
