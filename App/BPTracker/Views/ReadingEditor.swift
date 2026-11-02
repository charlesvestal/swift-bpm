import BPMKit
import SwiftData
import SwiftUI

/// Add a reading by hand, or edit one. Readings downloaded from a device keep
/// their measured values; only the note and profile can be changed.
struct ReadingEditor: View {
    let request: EditorRequest

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    @State private var timestamp = Date()
    @State private var systolic: Int?
    @State private var diastolic: Int?
    @State private var pulse: Int?
    @State private var irregularHeartbeat = false
    @State private var note = ""
    @State private var profile: Profile?
    @State private var error: String?

    private var existing: Reading? {
        if case let .edit(r) = request { r } else { nil }
    }

    private var valuesEditable: Bool { existing?.isManual ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Profile", selection: $profile) {
                    ForEach(profiles) { Text($0.name).tag(Optional($0)) }
                }
                DatePicker("Time", selection: $timestamp)
                    .disabled(!valuesEditable)
                TextField("Systolic (mmHg)", value: $systolic, format: .number)
                    .disabled(!valuesEditable)
                TextField("Diastolic (mmHg)", value: $diastolic, format: .number)
                    .disabled(!valuesEditable)
                TextField("Pulse (bpm)", value: $pulse, format: .number, prompt: Text("optional"))
                    .disabled(!valuesEditable)
                Toggle("Irregular heartbeat", isOn: $irregularHeartbeat)
                    .disabled(!valuesEditable)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                if let existing, !existing.isManual {
                    Text("Downloaded from \(existing.sourceName). Measured values can't be changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private func load() {
        switch request {
        case let .new(p):
            profile = p
        case let .edit(r):
            profile = r.profile
            timestamp = r.timestamp
            systolic = r.systolic
            diastolic = r.diastolic
            pulse = r.pulse
            irregularHeartbeat = r.irregularHeartbeat
            note = r.note
        }
    }

    private func validationError() -> String? {
        guard profile != nil else { return "Choose a profile." }
        guard valuesEditable else { return nil }
        guard let systolic, let diastolic else { return "Enter systolic and diastolic pressure." }
        guard (40...300).contains(systolic) else { return "Systolic should be between 40 and 300 mmHg." }
        guard (20...250).contains(diastolic) else { return "Diastolic should be between 20 and 250 mmHg." }
        guard systolic > diastolic else { return "Systolic should be higher than diastolic." }
        if let pulse, !(20...250).contains(pulse) { return "Pulse should be between 20 and 250 bpm." }
        guard timestamp <= Date().addingTimeInterval(60) else { return "The time is in the future." }
        return nil
    }

    private func save() {
        if let message = validationError() {
            error = message
            return
        }
        guard let profile else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing {
            existing.profile = profile
            existing.note = trimmedNote
            if existing.isManual, let systolic, let diastolic {
                let newKey = ReadingKey.make(deviceID: existing.deviceID, deviceUser: nil, timestamp: timestamp)
                if newKey != existing.key, (try? ReadingImporter(context: context).existingKeys().contains(newKey)) == true {
                    error = "There is already a manual reading at that minute."
                    return
                }
                existing.timestamp = timestamp
                existing.systolic = systolic
                existing.diastolic = diastolic
                existing.pulse = pulse
                existing.irregularHeartbeat = irregularHeartbeat
                existing.refreshKey()
            }
        } else if let systolic, let diastolic {
            let reading = Reading(timestamp: timestamp, systolic: systolic, diastolic: diastolic, pulse: pulse,
                                  irregularHeartbeat: irregularHeartbeat, sourceName: "Manual",
                                  deviceID: profile.manualDeviceID, deviceUser: nil, note: trimmedNote, profile: profile)
            if (try? ReadingImporter(context: context).existingKeys().contains(reading.key)) == true {
                error = "\(profile.name) already has a manual reading at that minute."
                return
            }
            context.insert(reading)
            try? ReadingImporter(context: context).clearDeletedMarker(for: reading.key)
        }
        do {
            try context.save()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
