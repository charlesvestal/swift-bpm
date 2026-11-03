import BPMKit
import SwiftUI

/// A US Letter PDF: summary, distribution, trend and time-of-day statistics
/// on the first page, then every (non-hidden) reading in the period.
enum PDFReport {
    static let pageSize = CGSize(width: 612, height: 792)
    static let rowsPerPage = 40

    static func render(profileName: String, period: Period, readings: [Reading],
                       options: AnalysisOptions = AppSettings.options, text: ReportText = .current,
                       generated: Date = Date()) -> Data {
        let analysis = ReadingAnalysis(readings: readings, period: period, options: options)
        let rows = analysis.readings.map { Row($0, guideline: options.guideline) }
        var chunks: [[Row]] = []
        var rest = rows[...]
        while !rest.isEmpty {
            chunks.append(Array(rest.prefix(rowsPerPage)))
            rest = rest.dropFirst(rowsPerPage)
        }
        let pageCount = 1 + chunks.count
        var pages: [AnyView] = [AnyView(ReportPage(number: 1, count: pageCount, guideline: options.guideline, text: text) {
            SummaryPage(profileName: profileName, periodTitle: text.periodTitle(period), analysis: analysis,
                        generated: generated, text: text)
        })]
        for (index, chunk) in chunks.enumerated() {
            pages.append(AnyView(ReportPage(number: index + 2, count: pageCount, guideline: options.guideline, text: text) {
                RowsTable(rows: chunk, thresholds: options.thresholds, text: text)
            }))
        }
        return pdf(pages, locale: text.locale)
    }

    /// A measurement-week report: result and sessions first, then the week's readings.
    static func renderWeek(profileName: String, week: MeasurementWeek, readings: [Reading],
                           guideline: BPGuideline = AppSettings.options.guideline, text: ReportText = .current,
                           generated: Date = Date()) -> Data {
        let visible = readings.filter { !$0.hidden }
        let result = HomeMonitoringResult(points: visible.map(\.point), plan: week.plan, guideline: guideline)
        let rows = visible.filter { week.plan.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
            .map { Row($0, guideline: guideline) }
        let chunks = stride(from: 0, to: rows.count, by: rowsPerPage).map { Array(rows[$0..<min($0 + rowsPerPage, rows.count)]) }
        let pageCount = 1 + chunks.count
        var pages: [AnyView] = [AnyView(ReportPage(number: 1, count: pageCount, guideline: guideline, text: text) {
            WeekSummaryPage(profileName: profileName, result: result, generated: generated, text: text)
        })]
        for (index, chunk) in chunks.enumerated() {
            pages.append(AnyView(ReportPage(number: index + 2, count: pageCount, guideline: guideline, text: text) {
                RowsTable(rows: chunk, thresholds: HomeMonitoringPlan.homeThresholds, text: text)
            }))
        }
        return pdf(pages, locale: text.locale)
    }

    /// Renders the pages; `locale` also sets the chart axes' date labels.
    private static func pdf(_ pages: [AnyView], locale: Locale) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        for page in pages {
            let renderer = ImageRenderer(content: page
                .frame(width: pageSize.width, height: pageSize.height)
                .environment(\.colorScheme, .light)
                .environment(\.locale, locale))
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, render in
                pdf.beginPDFPage(nil)
                render(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        return data as Data
    }

    private struct WeekSummaryPage: View {
        let profileName: String
        let result: HomeMonitoringResult
        let generated: Date
        let text: ReportText

        var body: some View {
            let plan = result.plan
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text("Home blood pressure: measurement week", "Blutdruck-Selbstmessung: Messwoche"))
                        .font(.system(size: 18, weight: .bold))
                    Spacer()
                    Text(text("Generated", "Erstellt am") + " " + text.date(generated, .long, time: .shortened))
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(profileName).font(.system(size: 14, weight: .semibold))
                Text("\(text.date(plan.firstDay(), .long)) – \(text.date(plan.end().addingTimeInterval(-1), .long)) · "
                     + text("two readings each morning and evening", "je zwei Messungen morgens und abends")
                     + (plan.discardFirstDay ? " · " + text("day 1 excluded (practice)", "Tag 1 nicht gewertet (Eingewöhnung)") : ""))
                    .font(.system(size: 9)).foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        Text(text("Mean", "Mittelwert")).bold()
                        Text(text("Readings", "Messungen")).bold()
                        Text(text("Lowest – highest", "Niedrigster – höchster")).bold()
                    }
                    row(text("Home average", "Mittelwert Selbstmessung"), result.summary, bold: true)
                    row(text.session(.morning), result.morning)
                    row(text.session(.evening), result.evening)
                }
                .font(.system(size: 10))

                Text(assessment).font(.system(size: 10, weight: .semibold))
                Text(text("Sessions with two readings: \(result.completedSessions) of \(result.expectedSessions). Readings counted: \(result.included.count) (at least \(HomeMonitoringPlan.minimumReadings) over \(HomeMonitoringPlan.minimumDays) days recommended).",
                          "Messzeitpunkte mit zwei Messungen: \(result.completedSessions) von \(result.expectedSessions). Gewertete Messungen: \(result.included.count) (empfohlen: mindestens \(HomeMonitoringPlan.minimumReadings) an \(HomeMonitoringPlan.minimumDays) Tagen)."))
                    .font(.system(size: 9))

                WeekGrid(result: result, compact: true, now: generated, text: text)
                if !result.included.isEmpty {
                    ReadingsChart(points: result.included, thresholds: HomeMonitoringPlan.homeThresholds, showPulse: true,
                                  interactive: false, text: text)
                        .frame(height: 200)
                }
                Text(text("Protocol and thresholds follow the European Society of Hypertension's home monitoring recommendations: average of all readings after the first day, with a home average of 135/85 mmHg or more considered raised. Red values on the following pages are at or above 135/85.",
                          "Vorgehen und Grenzwerte nach den Empfehlungen der Europäischen Gesellschaft für Hypertonie (ESH) zur Selbstmessung: Mittelwert aller Messungen ab dem zweiten Tag; ein Mittelwert ab 135/85 mmHg gilt als erhöht. Rote Werte auf den folgenden Seiten liegen bei oder über 135/85."))
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }

        private var assessment: String {
            guard let raised = result.isRaised else { return text("No readings in this week.", "Keine Messungen in dieser Woche.") }
            let verdict = raised
                ? text("At or above the home threshold of 135/85 mmHg.", "Bei oder über dem Grenzwert der Selbstmessung von 135/85 mmHg.")
                : text("Below the home threshold of 135/85 mmHg.", "Unter dem Grenzwert der Selbstmessung von 135/85 mmHg.")
            return result.meetsMinimum ? verdict
                : text("Too few readings for a reliable average. ", "Zu wenige Messungen für einen verlässlichen Mittelwert. ") + verdict
        }

        private func row(_ label: String, _ s: BPSummary, bold: Bool = false) -> some View {
            GridRow {
                Text(label).fontWeight(bold ? .semibold : .regular)
                Text(s.systolic.map { "\(Int($0.mean.rounded()))/\(Int(s.diastolic!.mean.rounded()))" } ?? "–")
                    .monospacedDigit().fontWeight(bold ? .semibold : .regular)
                Text("\(s.count)").monospacedDigit()
                Text(s.systolic.map { "\(Int($0.min))/\(Int(s.diastolic!.min)) – \(Int($0.max))/\(Int(s.diastolic!.max))" } ?? "–")
                    .monospacedDigit()
            }
        }
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
        let text: ReportText
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                content
                Spacer(minLength: 0)
                HStack {
                    Text(text("Categories follow the \(text.guideline(guideline)) guideline (written for office readings). MAP = diastolic + ⅓ pulse pressure. This report is not a diagnosis; discuss your readings with a clinician.",
                              "Kategorien nach der Leitlinie \(text.guideline(guideline)) (für Praxismessungen formuliert). MAD = diastolisch + ⅓ Pulsdruck. Dieser Bericht ist keine Diagnose; besprechen Sie Ihre Werte mit Ihrer Ärztin oder Ihrem Arzt."))
                    Spacer()
                    Text(text("Page \(number) of \(count)", "Seite \(number) von \(count)"))
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
        let text: ReportText

        var body: some View {
            let s = analysis.summary
            let median = analysis.options.useMedian
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text("Blood pressure report", "Blutdruckbericht")).font(.system(size: 20, weight: .bold))
                    Spacer()
                    Text(text("Generated", "Erstellt am") + " " + text.date(generated, .long, time: .shortened))
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(profileName).font(.system(size: 14, weight: .semibold))
                Text(subtitle(s)).font(.system(size: 9)).foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("")
                        Text(median ? "Median" : text("Average", "Mittelwert")).bold()
                        Text(text("Lowest", "Niedrigster")).bold()
                        Text(text("Highest", "Höchster")).bold()
                        Text(text("Std. dev.", "Std.-Abw.")).bold()
                    }
                    statRow(text("Systolic (mmHg)", "Systolisch (mmHg)"), s.systolic, median)
                    statRow(text("Diastolic (mmHg)", "Diastolisch (mmHg)"), s.diastolic, median)
                    statRow(text("Pulse (bpm)", "Puls (/min)"), s.pulse, median)
                    statRow(text("Mean arterial pressure", "Mittlerer arterieller Druck"), s.meanArterialPressure, median)
                    statRow(text("Pulse pressure", "Pulsdruck"), s.pulsePressure, median)
                }
                .font(.system(size: 9))

                HStack(spacing: 14) {
                    if let category = s.category(median: median) {
                        Text(text("\(median ? "Median" : "Average") category", "Kategorie (\(median ? "Median" : "Mittelwert"))")
                             + ": " + text.category(category)).bold()
                    }
                    if s.count > 0 {
                        Text(text("Above", "Über") + " \(analysis.options.thresholds.systolic)/\(analysis.options.thresholds.diastolic): " + text.percent(Double(s.aboveThresholdCount) / Double(s.count)))
                    }
                    if s.irregularCount > 0 { Text(text("Irregular heartbeat", "Unregelmäßiger Herzschlag") + ": \(s.irregularCount)") }
                }
                .font(.system(size: 9))

                if s.count > 0 {
                    CategoryDistribution(summary: s, compact: true, text: text)
                    ReadingsChart(points: analysis.points, thresholds: analysis.options.thresholds, showPulse: true,
                                  interactive: false, text: text)
                        .frame(height: 220)
                    Text(text("By time of day", "Nach Tageszeit")).font(.system(size: 10, weight: .semibold))
                    TimeOfDayTable(analysis: analysis, useMedian: median, fontSize: 8.5, text: text)
                }
            }
        }

        private func subtitle(_ s: BPSummary) -> String {
            var parts = [periodTitle]
            if let first = s.first, let last = s.last {
                parts.append("\(text.date(first, .abbreviated)) – \(text.date(last, .abbreviated))")
            }
            parts.append(text("\(s.readingCount) readings", "\(s.readingCount) Messungen"))
            if analysis.options.groupWindowMinutes > 0 {
                parts.append(text("readings within \(analysis.options.groupWindowMinutes) min averaged (\(s.count) measurements)",
                                  "Messungen innerhalb von \(analysis.options.groupWindowMinutes) Min. gemittelt (\(s.count) Messwerte)"))
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
        let text: ReportText

        var body: some View {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text(text("Date", "Datum")).bold()
                    Text(text("Pressure", "Blutdruck")).bold()
                    Text(text("Pulse", "Puls")).bold()
                    Text(text("MAP", "MAD")).bold()
                    Text(text("Category", "Kategorie")).bold()
                    Text(text("IHB", "Arrhythmie")).bold()
                    Text(text("Note", "Notiz")).bold()
                }
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(text.date(row.timestamp, .abbreviated, time: .shortened))
                        Text("\(row.systolic)/\(row.diastolic)").monospacedDigit()
                            .foregroundStyle(thresholds.isAbove(systolic: Double(row.systolic), diastolic: Double(row.diastolic)) ? .red : .black)
                        Text(row.pulse).monospacedDigit()
                        Text("\(row.map)").monospacedDigit()
                        HStack(spacing: 3) {
                            Circle().fill(row.category.color).frame(width: 6, height: 6)
                            Text(text.category(row.category))
                        }
                        Text(row.irregular ? text("yes", "ja") : "")
                        Text(row.note).lineLimit(1)
                    }
                    .frame(height: 12)
                }
            }
            .font(.system(size: 8.5))
        }
    }
}
