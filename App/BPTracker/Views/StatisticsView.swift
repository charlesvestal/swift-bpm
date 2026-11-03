import BPMKit
import Charts
import SwiftUI

/// Average or median by time of day, the category distribution, and
/// per-day/week/month ranges for the period.
struct StatisticsView: View {
    let analysis: ReadingAnalysis
    @Binding var useMedian: Bool

    var body: some View {
        ScrollView {
            StatisticsContent(analysis: analysis, useMedian: $useMedian)
        }
    }
}

struct StatisticsContent: View {
    let analysis: ReadingAnalysis
    @Binding var useMedian: Bool

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("Show", selection: $useMedian) {
                        Text("Average").tag(false)
                        Text("Median").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if analysis.options.groupWindowMinutes > 0 {
                        Text("Readings within \(analysis.options.groupWindowMinutes) minutes are averaged first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if analysis.points.isEmpty {
                    Text("No readings in this period.").foregroundStyle(.secondary)
                } else {
                    GroupBox("By time of day") {
                        TimeOfDayTable(analysis: analysis, useMedian: useMedian)
                            .padding(6)
                    }
                    GroupBox("Categories") {
                        CategoryDistribution(summary: analysis.summary)
                            .padding(6)
                    }
                    GroupBox(bucketTitle) {
                        RangeChart(buckets: analysis.buckets, thresholds: analysis.options.thresholds, guideline: analysis.options.guideline)
                            .frame(height: 220)
                            .padding(6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bucketTitle: String {
        switch analysis.buckets.unit {
        case .day: "Daily averages"
        case .weekOfYear: "Weekly averages"
        default: "Monthly averages"
        }
    }
}

/// Rows: whole period, then each part of the day with readings.
struct TimeOfDayTable: View {
    let analysis: ReadingAnalysis
    let useMedian: Bool
    var fontSize: CGFloat? = nil
    var text = ReportText.english

    var body: some View {
        let rows: [(String, String, BPSummary)] = [(text("All", "Alle"), "", analysis.summary)]
            + analysis.byTimeOfDay.map { (text.timeOfDay($0.0), $0.0.hours, $0.1) }
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("n")
                Text(text("Systolic", "Systolisch"))
                Text(text("Diastolic", "Diastolisch"))
                Text(text("Pulse", "Puls"))
                Text(text("MAP", "MAD"))
                Text(text("PP", "PD"))
                Text(text("Above", "Über") + " \(analysis.options.thresholds.systolic)/\(analysis.options.thresholds.diastolic)")
            }
            .font(font.weight(.semibold))
            Divider()
            ForEach(rows, id: \.0) { title, hours, s in
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                        if !hours.isEmpty { Text(hours).font(smallFont).foregroundStyle(.secondary) }
                    }
                    Text("\(s.count)")
                    value(s.systolic)
                    value(s.diastolic)
                    value(s.pulse)
                    value(s.meanArterialPressure)
                    value(s.pulsePressure)
                    Text(s.count == 0 ? "–" : text.percent(Double(s.aboveThresholdCount) / Double(s.count)))
                }
                .font(font)
                .monospacedDigit()
            }
        }
    }

    private var font: Font { fontSize.map { .system(size: $0) } ?? .body }
    private var smallFont: Font { fontSize.map { .system(size: $0 - 1.5) } ?? .caption }

    private func value(_ stat: BPStatistic?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(stat.map { "\(Int($0.center(median: useMedian).rounded()))" } ?? "–")
            if let stat {
                Text("\(Int(stat.min.rounded()))–\(Int(stat.max.rounded()))").font(smallFont).foregroundStyle(.secondary)
            }
        }
    }
}

/// One stacked bar of category shares, with a legend.
struct CategoryDistribution: View {
    let summary: BPSummary
    var compact = false
    var text = ReportText.english

    var body: some View {
        let shares = summary.categoryShares
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(shares, id: \.category) { share in
                        Rectangle()
                            .fill(share.category.color)
                            .frame(width: max(2, geo.size.width * share.fraction - 1))
                    }
                }
            }
            .frame(height: compact ? 10 : 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            HStack(spacing: 14) {
                ForEach(shares, id: \.category) { share in
                    HStack(spacing: 4) {
                        Circle().fill(share.category.color).frame(width: 7, height: 7)
                        Text("\(text.category(share.category)) \(text.percent(share.fraction)) (\(share.count))")
                    }
                }
            }
            .font(compact ? .system(size: 8) : .caption)
        }
    }
}

/// Floating bars from diastolic to systolic per day, week or month.
struct RangeChart: View {
    let buckets: (unit: Calendar.Component, points: [BPPoint])
    let thresholds: BPThresholds
    let guideline: BPGuideline

    var body: some View {
        Chart {
            RuleMark(y: .value("Systolic threshold", thresholds.systolic))
                .foregroundStyle(.red.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Diastolic threshold", thresholds.diastolic))
                .foregroundStyle(.blue.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(Array(buckets.points.enumerated()), id: \.offset) { _, p in
                BarMark(x: .value("Period", p.timestamp, unit: buckets.unit),
                        yStart: .value("Diastolic", p.diastolic), yEnd: .value("Systolic", p.systolic), width: .ratio(0.6))
                    .foregroundStyle(p.category(in: guideline).color.gradient)
                    .annotation(position: .top) {
                        Text("\(Int(p.systolic.rounded()))/\(Int(p.diastolic.rounded()))")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxisLabel("mmHg")
    }

    private var yDomain: ClosedRange<Double> {
        let low = min(buckets.points.map(\.diastolic).min() ?? 70, Double(thresholds.diastolic))
        let high = max(buckets.points.map(\.systolic).max() ?? 140, Double(thresholds.systolic))
        return (floor(low / 10) * 10 - 10)...(ceil(high / 10) * 10 + 10)
    }
}
