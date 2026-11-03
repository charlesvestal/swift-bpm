import BPMKit
import SwiftUI

/// A US Letter PDF: summary, distribution, trend and time-of-day statistics
/// on the first page, then every (non-hidden) reading in the period.
enum PDFReport {
    static let pageSize = CGSize(width: 612, height: 792)
    static let rowsPerPage = 40

    static func render(profileName: String, period: Period, readings: [Reading],
                       options: AnalysisOptions = AppSettings.options, generated: Date = Date()) -> Data {
        let analysis = ReadingAnalysis(readings: readings, period: period, options: options)
        let rows = analysis.readings.map { Row($0, guideline: options.guideline) }
        var chunks: [[Row]] = []
        var rest = rows[...]
        while !rest.isEmpty {
            chunks.append(Array(rest.prefix(rowsPerPage)))
            rest = rest.dropFirst(rowsPerPage)
        }
        let pageCount = 1 + chunks.count

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        func draw(_ page: some View) {
            let renderer = ImageRenderer(content: page
                .frame(width: pageSize.width, height: pageSize.height)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, render in
                pdf.beginPDFPage(nil)
                render(pdf)
                pdf.endPDFPage()
            }
        }

        draw(ReportPage(number: 1, count: pageCount, guideline: options.guideline) {
            SummaryPage(profileName: profileName, periodTitle: period.title, analysis: analysis, generated: generated)
        })
        for (index, chunk) in chunks.enumerated() {
            draw(ReportPage(number: index + 2, count: pageCount, guideline: options.guideline) {
                RowsTable(rows: chunk, thresholds: options.thresholds)
            })
        }
        pdf.closePDF()
        return data as Data
    }

    struct Row: Identifiable {
        let id: String
        let timestamp: Date
        let systolic: Int
        let diastolic: Int
        let pulse: String
        let map: Int
        let category: BPCategory
        let irregular: Bool
        let note: String

        init(_ r: Reading, guideline: BPGuideline) {
            id = r.key
            timestamp = r.timestamp
            systolic = r.systolic
            diastolic = r.diastolic
            pulse = r.pulse.map(String.init) ?? "–"
            map = r.meanArterialPressure
            category = r.category(in: guideline)
            irregular = r.irregularHeartbeat
            note = r.note
        }
    }

    private struct ReportPage<Content: View>: View {
        let number: Int
        let count: Int
        let guideline: BPGuideline
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                content
                Spacer(minLength: 0)
                HStack {
                    Text("Categories follow the \(guideline.shortTitle) guideline (written for office readings). MAP = diastolic + ⅓ pulse pressure. This report is not a diagnosis; discuss your readings with a clinician.")
                    Spacer()
                    Text("Page \(number) of \(count)")
                }
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            }
            .padding(36)
            .background(Color.white)
            .foregroundStyle(.black)
        }
    }

    private struct SummaryPage: View {
        let profileName: String
        let periodTitle: String
        let analysis: ReadingAnalysis
        let generated: Date

        var body: some View {
            let s = analysis.summary
            let median = analysis.options.useMedian
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Blood pressure report").font(.system(size: 20, weight: .bold))
                    Spacer()
                    Text("Generated \(generated.formatted(date: .long, time: .shortened))")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(profileName).font(.system(size: 14, weight: .semibold))
                Text(subtitle(s)).font(.system(size: 9)).foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("")
                        Text(median ? "Median" : "Average").bold()
                        Text("Lowest").bold()
                        Text("Highest").bold()
                        Text("Std. dev.").bold()
                    }
                    statRow("Systolic (mmHg)", s.systolic, median)
                    statRow("Diastolic (mmHg)", s.diastolic, median)
                    statRow("Pulse (bpm)", s.pulse, median)
                    statRow("Mean arterial pressure", s.meanArterialPressure, median)
                    statRow("Pulse pressure", s.pulsePressure, median)
                }
                .font(.system(size: 9))

                HStack(spacing: 14) {
                    if let category = s.category(median: median) {
                        Text("\(median ? "Median" : "Average") category: \(category.title)").bold()
                    }
                    if s.count > 0 {
                        Text("Above \(analysis.options.thresholds.systolic)/\(analysis.options.thresholds.diastolic): \(Int((Double(s.aboveThresholdCount) / Double(s.count) * 100).rounded()))%")
                    }
                    if s.irregularCount > 0 { Text("Irregular heartbeat: \(s.irregularCount)") }
                }
                .font(.system(size: 9))

                if s.count > 0 {
                    CategoryDistribution(summary: s, compact: true)
                    ReadingsChart(points: analysis.points, thresholds: analysis.options.thresholds, showPulse: true, interactive: false)
                        .frame(height: 220)
                    Text("By time of day").font(.system(size: 10, weight: .semibold))
                    TimeOfDayTable(analysis: analysis, useMedian: median, fontSize: 8.5)
                }
            }
        }

        private func subtitle(_ s: BPSummary) -> String {
            var parts = [periodTitle]
            if let first = s.first, let last = s.last {
                parts.append("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
            }
            parts.append("\(s.readingCount) readings")
            if analysis.options.groupWindowMinutes > 0 {
                parts.append("readings within \(analysis.options.groupWindowMinutes) min averaged (\(s.count) measurements)")
            }
            return parts.joined(separator: " · ")
        }

        private func statRow(_ label: String, _ stat: BPStatistic?, _ median: Bool) -> some View {
            GridRow {
                Text(label)
                Text(stat.map { String(format: "%.0f", $0.center(median: median)) } ?? "–").monospacedDigit()
                Text(stat.map { String(format: "%.0f", $0.min) } ?? "–").monospacedDigit()
                Text(stat.map { String(format: "%.0f", $0.max) } ?? "–").monospacedDigit()
                Text(stat.map { String(format: "%.1f", $0.standardDeviation) } ?? "–").monospacedDigit()
            }
        }
    }

    private struct RowsTable: View {
        let rows: [Row]
        let thresholds: BPThresholds

        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Date").bold()
                    Text("Pressure").bold()
                    Text("Pulse").bold()
                    Text("MAP").bold()
                    Text("Category").bold()
                    Text("IHB").bold()
                    Text("Note").bold()
                }
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(row.timestamp.formatted(date: .abbreviated, time: .shortened))
                        Text("\(row.systolic)/\(row.diastolic)").monospacedDigit()
                            .foregroundStyle(thresholds.isAbove(systolic: Double(row.systolic), diastolic: Double(row.diastolic)) ? .red : .black)
                        Text(row.pulse).monospacedDigit()
                        Text("\(row.map)").monospacedDigit()
                        HStack(spacing: 3) {
                            Circle().fill(row.category.color).frame(width: 6, height: 6)
                            Text(row.category.title)
                        }
                        Text(row.irregular ? "yes" : "")
                        Text(row.note).lineLimit(1)
                    }
                    .frame(height: 12)
                }
            }
            .font(.system(size: 8.5))
        }
    }
}
