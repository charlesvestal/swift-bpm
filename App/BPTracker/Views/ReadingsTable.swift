import SwiftData
import SwiftUI

struct ReadingsTable: View {
    let readings: [Reading]
    @Binding var editor: EditorRequest?

    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @State private var selection = Set<PersistentIdentifier>()
    @State private var pendingDelete: [Reading] = []

    private var selectedReadings: [Reading] { readings.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            HStack {
                Text(selection.isEmpty ? "\(readings.count) reading\(readings.count == 1 ? "" : "s")" : "\(selectedReadings.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit…") { if let r = selectedReadings.first { editor = .edit(r) } }
                    .disabled(selectedReadings.count != 1)
                Button("Delete…", role: .destructive) { pendingDelete = selectedReadings }
                    .disabled(selectedReadings.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private var table: some View {
        columns
            .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
                menu(for: readings.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                if let reading = readings.first(where: { ids.contains($0.id) }) { editor = .edit(reading) }
            }
            .onDeleteCommand { pendingDelete = selectedReadings }
            .confirmationDialog(pendingDelete.count == 1 ? "Delete this reading?" : "Delete \(pendingDelete.count) readings?",
                                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                Button("Delete", role: .destructive) {
                    try? ReadingImporter(context: context).delete(pendingDelete)
                    selection.removeAll()
                    pendingDelete = []
                }
            } message: {
                Text("They won't be imported again from the monitor. You can undo with ⌘Z.")
            }
    }

    private var columns: some View {
        Table(readings, selection: $selection) {
            TableColumn("Date") { r in
                Text(r.timestamp, format: .dateTime.year().month().day().hour().minute())
            }
            .width(min: 140, ideal: 160)
            TableColumn("Pressure") { r in
                Text(r.pressureText).monospacedDigit().fontWeight(.medium)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Pulse") { r in
                Text(r.pulse.map(String.init) ?? "–").monospacedDigit()
            }
            .width(min: 40, ideal: 50)
            TableColumn("Category") { r in
                CategoryBadge(category: r.category)
            }
            .width(min: 120, ideal: 160)
            TableColumn("IHB") { r in
                if r.irregularHeartbeat {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .help("Irregular heartbeat detected")
                        .accessibilityLabel("Irregular heartbeat")
                }
            }
            .width(30)
            TableColumn("Source") { r in
                Text(r.sourceName + (r.deviceUser.map { " · user \($0)" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Note") { r in
                Text(r.note).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for chosen: [Reading]) -> some View {
        if chosen.count == 1, let reading = chosen.first {
            Button("Edit…") { editor = .edit(reading) }
        }
        if !chosen.isEmpty {
            Menu("Move to Profile") {
                ForEach(profiles) { profile in
                    Button(profile.name) {
                        chosen.forEach { $0.profile = profile }
                        try? context.save()
                    }
                    .disabled(chosen.allSatisfy { $0.profile == profile })
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = chosen }
        }
    }
}
