import BPMKit
import Foundation

/// What the charts, statistics and report work from: the visible readings in
/// a period, grouped as configured, and their summary.
struct ReadingAnalysis {
    let readings: [Reading]
    let points: [BPPoint]
    let summary: BPSummary
    let options: AnalysisOptions

    init(readings all: [Reading], period: Period, options: AnalysisOptions) {
        readings = all.filter { !$0.hidden && period.contains($0.timestamp) }.sorted { $0.timestamp > $1.timestamp }
        points = BPAnalysis.groupConsecutive(readings.map(\.point), within: TimeInterval(options.groupWindowMinutes * 60))
        summary = BPSummary(points, thresholds: options.thresholds, guideline: options.guideline)
        self.options = options
    }

    var byTimeOfDay: [(TimeOfDay, BPSummary)] { BPSummary.byTimeOfDay(points, thresholds: options.thresholds, guideline: options.guideline) }

    /// Averages per day, week or month, whichever suits the span shown.
    var buckets: (unit: Calendar.Component, points: [BPPoint]) {
        guard let first = summary.first, let last = summary.last else { return (.day, []) }
        let span = last.timeIntervalSince(first) / 86_400
        let unit: Calendar.Component = span <= 31 ? .day : span <= 200 ? .weekOfYear : .month
        let calendar = Calendar.current
        let groups = Dictionary(grouping: points) { calendar.dateInterval(of: unit, for: $0.timestamp)!.start }
        let bucketed = groups.map { start, members in
            BPAnalysis.groupConsecutive(members.map { var p = $0; p.timestamp = start; return p }, within: .infinity)[0]
        }
        return (unit, bucketed.sorted { $0.timestamp < $1.timestamp })
    }
}
