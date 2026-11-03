import BPMKit
import SwiftData
import SwiftUI

struct ProfileDetailView: View {
    let profile: Profile
    @Binding var period: Period
    @Binding var editor: EditorRequest?

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case statistics = "Statistics"
        var id: String { rawValue }
    }

    @State private var tab = Tab.overview
    @AppStorage("showPulse") private var showPulse = true
    @AppStorage(AppSettings.systolicThreshold) private var systolicThreshold = 130
    @AppStorage(AppSettings.diastolicThreshold) private var diastolicThreshold = 80
    @AppStorage(AppSettings.groupWindowMinutes) private var groupWindowMinutes = 0
    @AppStorage(AppSettings.useMedian) private var useMedian = false
    @AppStorage(AppSettings.guideline) private var guideline = BPGuideline.esh2023

    private var options: AnalysisOptions {
        AnalysisOptions(thresholds: BPThresholds(systolic: systolicThreshold, diastolic: diastolicThreshold),
                        groupWindowMinutes: groupWindowMinutes, useMedian: useMedian, guideline: guideline)
    }

    var body: some View {
        let analysis = ReadingAnalysis(readings: profile.readings, period: period, options: options)
        let tableReadings = profile.readings.filter { period.contains($0.timestamp) }.sorted { $0.timestamp > $1.timestamp }

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.name).font(.largeTitle.bold())
                Spacer()
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            PeriodBar(period: $period)

            if profile.readings.isEmpty {
                ContentUnavailableView {
                    Label("No readings", systemImage: "heart.text.square")
                } description: {
                    Text("Add a reading by hand, connect your monitor, or import a CSV file.")
                } actions: {
                    Button("Add Reading") { editor = .new(profile) }
                }
            } else {
                switch tab {
                case .overview:
                    SummaryRow(latest: profile.readings.filter { !$0.hidden }.max { $0.timestamp < $1.timestamp },
                               analysis: analysis)
                    GroupBox {
                        if analysis.points.isEmpty {
                            Text("No readings in \(period.title.lowercased()).")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ReadingsChart(points: analysis.points, thresholds: options.thresholds, showPulse: showPulse)
                                .frame(minHeight: 220)
                                .padding(4)
                        }
                    } label: {
                        HStack {
                            Text("Trend")
                            if groupWindowMinutes > 0 {
                                Text("readings within \(groupWindowMinutes) min averaged")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Pulse", isOn: $showPulse).toggleStyle(.checkbox)
                        }
                    }
                    ReadingsTable(readings: tableReadings, thresholds: options.thresholds, guideline: guideline, editor: $editor)
                        .frame(minHeight: 200)
                case .statistics:
                    StatisticsView(analysis: analysis, useMedian: $useMedian)
                }
            }
        }
        .padding(20)
        .navigationTitle(profile.name)
    }
}

/// Rolling or calendar period, with paging for calendar ones.
struct PeriodBar: View {
    @Binding var period: Period

    var body: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $period.kind) {
                ForEach([Period.Kind.last7, .last30, .last90, .last365, .all]) { Text($0.pickerTitle).tag($0) }
                Divider()
                ForEach([Period.Kind.week, .month, .year]) { Text($0.pickerTitle).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            if period.isCalendar {
                ControlGroup {
                    Button { period.step(by: -1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous")
                    Button { period.step(by: 1) } label: { Image(systemName: "chevron.right") }
                        .help("Next")
                        .disabled(!period.canStepForward())
                }
                .fixedSize()
                Button("Today") { period.anchor = Date() }
                    .disabled(period.contains(Date()))
            }
            Text(period.title).font(.headline)
            Spacer()
        }
    }
}

private struct SummaryRow: View {
    let latest: Reading?
    let analysis: ReadingAnalysis

    var body: some View {
        let s = analysis.summary
        let median = analysis.options.useMedian
        let label = median ? "Median" : "Average"
        HStack(spacing: 12) {
            tile("Latest") {
                if let latest {
                    Text(latest.pressureText).font(.title.bold()).monospacedDigit()
                    CategoryBadge(category: latest.category(in: analysis.options.guideline)).font(.caption)
                    Text(latest.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            tile(label) {
                if let sys = s.systolic, let dia = s.diastolic {
                    Text("\(Int(sys.center(median: median).rounded()))/\(Int(dia.center(median: median).rounded()))")
                        .font(.title.bold()).monospacedDigit()
                    if let category = s.category(median: median) { CategoryBadge(category: category).font(.caption) }
                } else {
                    Text("–").font(.title.bold())
                }
            }
            tile("Pulse · MAP") {
                Text(s.pulse.map { "\(Int($0.center(median: median).rounded())) bpm" } ?? "–")
                    .font(.title.bold()).monospacedDigit()
                if let map = s.meanArterialPressure, let pp = s.pulsePressure {
                    Text("MAP \(Int(map.center(median: median).rounded())) · pulse pressure \(Int(pp.center(median: median).rounded()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            tile("Above \(analysis.options.thresholds.systolic)/\(analysis.options.thresholds.diastolic)") {
                Text(s.count == 0 ? "–" : "\(Int((Double(s.aboveThresholdCount) / Double(s.count) * 100).rounded()))%")
                    .font(.title.bold()).monospacedDigit()
                Text("\(s.readingCount) readings" + (s.irregularCount > 0 ? ", \(s.irregularCount) irregular heartbeat" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
