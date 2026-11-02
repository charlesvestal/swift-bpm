import Charts
import SwiftUI

/// Systolic and diastolic over time, with the stage-1 thresholds (130/80)
/// marked. Also used, non-interactively, in the PDF report.
struct ReadingsChart: View {
    let readings: [Reading]
    var showPulse = true
    var interactive = true

    @State private var hovered: Date?

    private static let series: KeyValuePairs<String, Color> = ["Systolic": .red, "Diastolic": .blue, "Pulse": .gray]

    private var hoveredReading: Reading? {
        guard let hovered else { return nil }
        return readings.min { abs($0.timestamp.timeIntervalSince(hovered)) < abs($1.timestamp.timeIntervalSince(hovered)) }
    }

    private var yDomain: ClosedRange<Int> {
        let values = readings.flatMap { [$0.systolic, $0.diastolic] + (showPulse ? [$0.pulse].compactMap { $0 } : []) }
        let low = min(values.min() ?? 60, 70), high = max(values.max() ?? 140, 140)
        return (low / 10 * 10 - 10)...(high / 10 * 10 + 10)
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Systolic threshold", 130))
                .foregroundStyle(.red.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Diastolic threshold", 80))
                .foregroundStyle(.blue.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(readings) { r in
                LineMark(x: .value("Time", r.timestamp), y: .value("mmHg", r.systolic), series: .value("Series", "Systolic"))
                    .foregroundStyle(by: .value("Series", "Systolic"))
                PointMark(x: .value("Time", r.timestamp), y: .value("mmHg", r.systolic))
                    .foregroundStyle(by: .value("Series", "Systolic"))
                    .symbolSize(r.irregularHeartbeat ? 80 : 25)
                LineMark(x: .value("Time", r.timestamp), y: .value("mmHg", r.diastolic), series: .value("Series", "Diastolic"))
                    .foregroundStyle(by: .value("Series", "Diastolic"))
                PointMark(x: .value("Time", r.timestamp), y: .value("mmHg", r.diastolic))
                    .foregroundStyle(by: .value("Series", "Diastolic"))
                    .symbolSize(25)
                if showPulse, let pulse = r.pulse {
                    LineMark(x: .value("Time", r.timestamp), y: .value("mmHg", pulse), series: .value("Series", "Pulse"))
                        .foregroundStyle(by: .value("Series", "Pulse"))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }

            if interactive, let r = hoveredReading {
                RuleMark(x: .value("Time", r.timestamp))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.pressureText).font(.headline).monospacedDigit()
                            if let pulse = r.pulse { Text("pulse \(pulse)").font(.caption) }
                            if r.irregularHeartbeat { Text("irregular heartbeat").font(.caption) }
                            Text(r.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 2)
                    }
            }
        }
        .chartForegroundStyleScale(Self.series)
        .chartYScale(domain: yDomain)
        .chartYAxisLabel("mmHg")
        .chartXSelection(value: interactive ? $hovered : .constant(nil))
    }
}
