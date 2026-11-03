import Foundation

/// A value to analyse: one reading, or the average of readings taken back to
/// back (see `BPAnalysis.groupConsecutive`).
public struct BPPoint: Sendable, Equatable {
    public var timestamp: Date
    public var systolic: Double
    public var diastolic: Double
    public var pulse: Double?
    public var irregularHeartbeat: Bool
    /// How many readings were averaged into this point.
    public var readingCount: Int

    public init(timestamp: Date, systolic: Double, diastolic: Double, pulse: Double?,
                irregularHeartbeat: Bool = false, readingCount: Int = 1) {
        self.timestamp = timestamp
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.irregularHeartbeat = irregularHeartbeat
        self.readingCount = readingCount
    }

    public var meanArterialPressure: Double { BPAnalysis.meanArterialPressure(systolic: systolic, diastolic: diastolic) }
    public var pulsePressure: Double { systolic - diastolic }
    public func category(in guideline: BPGuideline) -> BPCategory {
        guideline.category(systolic: Int(systolic.rounded()), diastolic: Int(diastolic.rounded()))
    }
}

public enum BPAnalysis {
    /// MAP estimated as diastolic + one third of the pulse pressure.
    public static func meanArterialPressure(systolic: Double, diastolic: Double) -> Double {
        diastolic + (systolic - diastolic) / 3
    }

    /// Averages runs of readings taken within `window` seconds of the first
    /// reading of the run, as home-monitoring guidelines recommend (take two
    /// or three readings a minute apart and use their mean). A window of 0
    /// returns the points unchanged, sorted by time.
    public static func groupConsecutive(_ points: [BPPoint], within window: TimeInterval) -> [BPPoint] {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard window > 0 else { return sorted }
        var result: [BPPoint] = []
        var run: [BPPoint] = []

        func flush() {
            guard let first = run.first else { return }
            let pulses = run.compactMap(\.pulse)
            result.append(BPPoint(
                timestamp: first.timestamp,
                systolic: run.map(\.systolic).reduce(0, +) / Double(run.count),
                diastolic: run.map(\.diastolic).reduce(0, +) / Double(run.count),
                pulse: pulses.isEmpty ? nil : pulses.reduce(0, +) / Double(pulses.count),
                irregularHeartbeat: run.contains { $0.irregularHeartbeat },
                readingCount: run.map(\.readingCount).reduce(0, +)))
            run = []
        }

        for point in sorted {
            if let first = run.first, point.timestamp.timeIntervalSince(first.timestamp) > window { flush() }
            run.append(point)
        }
        flush()
        return result
    }
}

/// Part of the day a reading was taken in.
public enum TimeOfDay: Int, CaseIterable, Sendable {
    case morning, afternoon, evening, night

    public var title: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    public var hours: String {
        switch self {
        case .morning: "4:00–11:59"
        case .afternoon: "12:00–17:59"
        case .evening: "18:00–23:59"
        case .night: "0:00–3:59"
        }
    }

    public init(date: Date, calendar: Calendar = .current) {
        switch calendar.component(.hour, from: date) {
        case 4..<12: self = .morning
        case 12..<18: self = .afternoon
        case 18..<24: self = .evening
        default: self = .night
        }
    }
}

public struct BPStatistic: Sendable, Equatable {
    public var count: Int
    public var mean: Double
    public var median: Double
    public var min: Double
    public var max: Double
    public var standardDeviation: Double

    public init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        count = values.count
        mean = values.reduce(0, +) / Double(count)
        median = count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        min = sorted.first!
        max = sorted.last!
        let m = mean
        standardDeviation = count > 1 ? (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count - 1)).squareRoot() : 0
    }

    public func center(median useMedian: Bool) -> Double { useMedian ? median : mean }
}

/// Home thresholds above which a reading counts as raised.
public struct BPThresholds: Sendable, Equatable {
    public var systolic: Int
    public var diastolic: Int

    public init(systolic: Int = 130, diastolic: Int = 80) {
        self.systolic = systolic
        self.diastolic = diastolic
    }

    public func isAbove(systolic s: Double, diastolic d: Double) -> Bool {
        s.rounded() >= Double(systolic) || d.rounded() >= Double(diastolic)
    }
}

public struct BPSummary: Sendable {
    public var count: Int
    public var readingCount: Int
    public var systolic: BPStatistic?
    public var diastolic: BPStatistic?
    public var pulse: BPStatistic?
    public var meanArterialPressure: BPStatistic?
    public var pulsePressure: BPStatistic?
    public var irregularCount: Int
    public var aboveThresholdCount: Int
    public var categories: [BPCategory: Int]
    public var guideline: BPGuideline
    public var first: Date?
    public var last: Date?

    public init(_ points: [BPPoint], thresholds: BPThresholds = BPThresholds(), guideline: BPGuideline = .esh2023) {
        self.guideline = guideline
        count = points.count
        readingCount = points.map(\.readingCount).reduce(0, +)
        systolic = BPStatistic(points.map(\.systolic))
        diastolic = BPStatistic(points.map(\.diastolic))
        pulse = BPStatistic(points.compactMap(\.pulse))
        meanArterialPressure = BPStatistic(points.map(\.meanArterialPressure))
        pulsePressure = BPStatistic(points.map(\.pulsePressure))
        irregularCount = points.filter(\.irregularHeartbeat).count
        aboveThresholdCount = points.filter { thresholds.isAbove(systolic: $0.systolic, diastolic: $0.diastolic) }.count
        categories = Dictionary(grouping: points) { $0.category(in: guideline) }.mapValues(\.count)
        first = points.map(\.timestamp).min()
        last = points.map(\.timestamp).max()
    }

    public func category(median: Bool) -> BPCategory? {
        guard let systolic, let diastolic else { return nil }
        return guideline.category(systolic: Int(systolic.center(median: median).rounded()),
                                  diastolic: Int(diastolic.center(median: median).rounded()))
    }

    /// Share of points in each category, in category order, skipping empty ones.
    public var categoryShares: [(category: BPCategory, count: Int, fraction: Double)] {
        guideline.categories.compactMap { c in
            guard let n = categories[c], n > 0 else { return nil }
            return (c, n, Double(n) / Double(count))
        }
    }

    /// Summaries per time of day, omitting empty parts of the day.
    public static func byTimeOfDay(_ points: [BPPoint], thresholds: BPThresholds = BPThresholds(),
                                   guideline: BPGuideline = .esh2023,
                                   calendar: Calendar = .current) -> [(TimeOfDay, BPSummary)] {
        let groups = Dictionary(grouping: points) { TimeOfDay(date: $0.timestamp, calendar: calendar) }
        return TimeOfDay.allCases.compactMap { part in
            groups[part].map { (part, BPSummary($0, thresholds: thresholds, guideline: guideline)) }
        }
    }
}
