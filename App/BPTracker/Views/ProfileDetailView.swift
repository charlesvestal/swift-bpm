import BPMKit
import SwiftData
import SwiftUI

struct ProfileDetailView: View {
    let profile: Profile
    @Binding var range: TimeRange
    @Binding var editor: EditorRequest?
    @AppStorage("showPulse") private var showPulse = true

    private var readings: [Reading] {
        profile.readings.filter { range.contains($0.timestamp) }.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        let readings = readings
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.name).font(.largeTitle.bold())
                Spacer()
                Picker("Period", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if profile.readings.isEmpty {
                ContentUnavailableView {
                    Label("No readings", systemImage: "heart.text.square")
                } description: {
                    Text("Add a reading by hand, import from a monitor, or import a CSV file.")
                } actions: {
                    Button("Add Reading") { editor = .new(profile) }
                }
            } else {
                SummaryRow(latest: profile.readings.max { $0.timestamp < $1.timestamp }, stats: ReadingStats(readings), range: range)

                GroupBox {
                    if readings.isEmpty {
                        Text("No readings in the last \(range.rawValue).")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ReadingsChart(readings: readings, showPulse: showPulse)
                            .frame(minHeight: 240)
                            .padding(4)
                    }
                } label: {
                    HStack {
                        Text("Trend")
                        Spacer()
                        Toggle("Pulse", isOn: $showPulse).toggleStyle(.checkbox)
                    }
                }

                ReadingsTable(readings: readings, editor: $editor)
                    .frame(minHeight: 200)
            }
        }
        .padding(20)
        .navigationTitle(profile.name)
    }
}

private struct SummaryRow: View {
    let latest: Reading?
    let stats: ReadingStats
    let range: TimeRange

    var body: some View {
        HStack(spacing: 12) {
            tile("Latest") {
                if let latest {
                    Text(latest.pressureText).font(.title.bold()).monospacedDigit()
                    CategoryBadge(category: latest.category).font(.caption)
                    Text(latest.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            tile("Average, \(range.rawValue)") {
                if let sys = stats.systolic, let dia = stats.diastolic {
                    Text("\(Int(sys.mean.rounded()))/\(Int(dia.mean.rounded()))").font(.title.bold()).monospacedDigit()
                    if let category = stats.averageCategory { CategoryBadge(category: category).font(.caption) }
                } else {
                    Text("–").font(.title.bold())
                }
            }
            tile("Pulse, \(range.rawValue)") {
                if let pulse = stats.pulse {
                    Text("\(Int(pulse.mean.rounded())) bpm").font(.title.bold()).monospacedDigit()
                    Text("range \(pulse.min)–\(pulse.max)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("–").font(.title.bold())
                }
            }
            tile("Readings, \(range.rawValue)") {
                Text("\(stats.count)").font(.title.bold()).monospacedDigit()
                Text(stats.irregularCount == 0 ? "no irregular heartbeat" : "\(stats.irregularCount) with irregular heartbeat")
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
