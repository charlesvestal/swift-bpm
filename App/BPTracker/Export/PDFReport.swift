import BPMKit
import SwiftUI

/// A US Letter PDF: summary, trend chart and every reading in the period.
enum PDFReport {
    static let pageSize = CGSize(width: 612, height: 792)
    static let firstPageRows = 16
    static let rowsPerPage = 40

    static func render(profileName: String, rangeTitle: String, readings: [Reading], generated: Date = Date()) -> Data {
        let sorted = readings.sorted { $0.timestamp > $1.timestamp }
        let rows = sorted.map(Row.init)
        var chunks = [Array(rows.prefix(firstPageRows))]
        var rest = rows.dropFirst(firstPageRows)
        while !rest.isEmpty {
            chunks.append(Array(rest.prefix(rowsPerPage)))
            rest = rest.dropFirst(rowsPerPage)
        }

        let header = Header(profileName: profileName, rangeTitle: rangeTitle, stats: ReadingStats(sorted), generated: generated)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        for (index, chunk) in chunks.enumerated() {
            let page = ReportPage(number: index + 1, count: chunks.count) {
                if index == 0 {
                    header
                    ReadingsChart(readings: sorted, showPulse: true, interactive: false)
                        .frame(height: 210)
                }
                RowsTable(rows: chunk)
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .environment(\.colorScheme, .light)

            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        return data as Data
    }

    struct Row: Identifiable {
        let id: String
        let timestamp: Date
        let pressure: String
        let pulse: String
        let category: BPCategory
        let irregular: Bool
        let note: String

        init(_ r: Reading) {
            id = r.key
            timestamp = r.timestamp
            pressure = r.pressureText
            pulse = r.pulse.map(String.init) ?? "–"
            category = r.category
            irregular = r.irregularHeartbeat
            note = r.note
        }
    }

    private struct ReportPage<Content: View>: View {
        let number: Int
        let count: Int
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                content
                Spacer(minLength: 0)
                HStack {
                    Text("Categories follow the 2017 ACC/AHA guideline. This report is not a diagnosis; discuss your readings with a clinician.")
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

    private struct Header: View {
        let profileName: String
        let rangeTitle: String
        let stats: ReadingStats
        let generated: Date

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Blood pressure report").font(.system(size: 20, weight: .bold))
                    Spacer()
                    Text("Generated \(generated.formatted(date: .long, time: .shortened))")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(profileName).font(.system(size: 14, weight: .semibold))
                if let first = stats.first, let last = stats.last {
                    Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)) (\(rangeTitle)), \(stats.count) readings")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("")
                        Text("Average").bold()
                        Text("Lowest").bold()
                        Text("Highest").bold()
                    }
                    statRow("Systolic (mmHg)", stats.systolic)
                    statRow("Diastolic (mmHg)", stats.diastolic)
                    statRow("Pulse (bpm)", stats.pulse)
                }
                .font(.system(size: 9))

                HStack(spacing: 14) {
                    if let average = stats.averageCategory {
                        Text("Average category: \(average.title)").bold()
                    }
                    ForEach(BPCategory.allCases, id: \.self) { category in
                        if let n = stats.categories[category] {
                            Text("\(category.title): \(n)")
                        }
                    }
                    if stats.irregularCount > 0 {
                        Text("Irregular heartbeat: \(stats.irregularCount)")
                    }
                }
                .font(.system(size: 8))
            }
        }

        private func statRow(_ label: String, _ range: ReadingStats.Range?) -> some View {
            GridRow {
                Text(label)
                Text(range.map { String(format: "%.0f", $0.mean) } ?? "–").monospacedDigit()
                Text(range.map { "\($0.min)" } ?? "–").monospacedDigit()
                Text(range.map { "\($0.max)" } ?? "–").monospacedDigit()
            }
        }
    }

    private struct RowsTable: View {
        let rows: [Row]

        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Date").bold()
                    Text("Pressure").bold()
                    Text("Pulse").bold()
                    Text("Category").bold()
                    Text("IHB").bold()
                    Text("Note").bold()
                }
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(row.timestamp.formatted(date: .abbreviated, time: .shortened))
                        Text(row.pressure).monospacedDigit()
                        Text(row.pulse).monospacedDigit()
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
