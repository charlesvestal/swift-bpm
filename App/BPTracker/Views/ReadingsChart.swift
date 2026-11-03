import BPMKit
import Charts
import SwiftUI

/// Systolic and diastolic over time, with the configured thresholds marked.
/// Also used, non-interactively, in the PDF report.
struct ReadingsChart: View {
    let points: [BPPoint]
    var thresholds = BPThresholds()
    var showPulse = true
    var interactive = true

    @State private var hovered: Date?

    private static let series: KeyValuePairs<String, Color> = ["Systolic": .red, "Diastolic": .blue, "Pulse": .gray]

    private var hoveredPoint: BPPoint? {
        guard let hovered else { return nil }
        return points.min { abs($0.timestamp.timeIntervalSince(hovered)) < abs($1.timestamp.timeIntervalSince(hovered)) }
    }

    private func isInRightHalf(_ date: Date) -> Bool {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return false }
        return date.timeIntervalSince(first) > last.timeIntervalSince(first) / 2
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.flatMap { [$0.systolic, $0.diastolic] + (showPulse ? [$0.pulse].compactMap { $0 } : []) }
            + [Double(thresholds.systolic), Double(thresholds.diastolic)]
        let low = min(values.min() ?? 60, 70), high = max(values.max() ?? 140, 140)
        return (floor(low / 10) * 10 - 10)...(ceil(high / 10) * 10 + 10)
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Systolic threshold", thresholds.systolic))
                .foregroundStyle(.red.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Diastolic threshold", thresholds.diastolic))
                .foregroundStyle(.blue.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.timestamp), y: .value("mmHg", p.systolic), series: .value("Series", "Systolic"))
                    .foregroundStyle(by: .value("Series", "Systolic"))
                PointMark(x: .value("Time", p.timestamp), y: .value("mmHg", p.systolic))
                    .foregroundStyle(by: .value("Series", "Systolic"))
                    .symbolSize(p.irregularHeartbeat ? 80 : 25)
                LineMark(x: .value("Time", p.timestamp), y: .value("mmHg", p.diastolic), series: .value("Series", "Diastolic"))
                    .foregroundStyle(by: .value("Series", "Diastolic"))
                PointMark(x: .value("Time", p.timestamp), y: .value("mmHg", p.diastolic))
                    .foregroundStyle(by: .value("Series", "Diastolic"))
                    .symbolSize(25)
                if showPulse, let pulse = p.pulse {
                    LineMark(x: .value("Time", p.timestamp), y: .value("mmHg", pulse), series: .value("Series", "Pulse"))
                        .foregroundStyle(by: .value("Series", "Pulse"))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }

            if interactive, let p = hoveredPoint {
                RuleMark(x: .value("Time", p.timestamp))
                    .foregroundStyle(.secondary.opacity(0.5))
                    // Beside the line, inside the plot, on whichever side has more room.
                    .annotation(position: isInRightHalf(p.timestamp) ? .leading : .trailing, alignment: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        Tooltip(point: p)
                    }
            }
        }
        .chartForegroundStyleScale(Self.series)
        .chartYScale(domain: yDomain)
        .chartYAxisLabel("mmHg")
        .chartXSelection(value: interactive ? $hovered : .constant(nil))
    }

    private struct Tooltip: View {
        let point: BPPoint

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(point.systolic.rounded()))/\(Int(point.diastolic.rounded()))").font(.headline).monospacedDigit()
                if let pulse = point.pulse { Text("pulse \(Int(pulse.rounded()))").font(.caption) }
                Text("MAP \(Int(point.meanArterialPressure.rounded())) · PP \(Int(point.pulsePressure.rounded()))").font(.caption)
                if point.irregularHeartbeat { Text("irregular heartbeat").font(.caption) }
                if point.readingCount > 1 { Text("average of \(point.readingCount) readings").font(.caption) }
                Text(point.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }
}
