import BPMKit
import SwiftData
import SwiftUI

/// Downloads from a monitor, asks which profile each new device user belongs
/// to, then stores the readings.
struct DeviceImportSheet: View {
    let kind: DeviceSourceKind

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(BPM25AutoImporter.self) private var autoImporter
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    private enum Phase {
        case running(String)
        case assign([DeviceReading], [DeviceUserRef])
        case done(ImportSummary)
        case failed(String)
    }

    /// Where an unlinked device user's readings go.
    private enum Choice: Hashable {
        case newProfile
        case existing(PersistentIdentifier)
        case ignore
    }

    @State private var phase: Phase = .running("Starting…")
    @State private var choices: [String: Choice] = [:]
    @State private var newNames: [String: String] = [:]

    private var title: String {
        switch kind {
        case .bpm25: "Import from Veroval BPM25"
        case .bluetooth: "Import from Bluetooth Monitor"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())

            switch phase {
            case let .running(message):
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                if kind == .bpm25 {
                    Text("Connect the monitor with its USB cable and switch it to PC mode.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case let .assign(readings, refs):
                assignment(readings: readings, refs: refs)
            case let .done(summary):
                Label(summary.message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                switch phase {
                case .running:
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                case let .assign(readings, refs):
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") { commit(readings: readings, refs: refs) }
                        .keyboardShortcut(.defaultAction)
                case .done, .failed:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        // Dismissing the sheet cancels the task, which cancels the download.
        .task {
            await autoImporter.suspend()
            await download()
        }
        .onDisappear { autoImporter.resume() }
    }

    @ViewBuilder
    private func assignment(readings: [DeviceReading], refs: [DeviceUserRef]) -> some View {
        Text("Choose the profile for each user on the monitor, or don't import that user. You can change this later in Settings.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Form {
            ForEach(refs) { ref in
                let own = readings.filter { DeviceUserRef($0) == ref }
                Section {
                    Picker("Profile", selection: binding(for: ref)) {
                        Text("New profile").tag(Choice.newProfile)
                        Divider()
                        ForEach(profiles) { Text($0.name).tag(Choice.existing($0.persistentModelID)) }
                        Divider()
                        Text("Don't import").tag(Choice.ignore)
                    }
                    if choices[ref.id] == .newProfile {
                        TextField("Name", text: nameBinding(for: ref))
                    }
                } header: {
                    Text(ref.title)
                } footer: {
                    if let latest = own.max(by: { $0.timestamp < $1.timestamp }) {
                        Text("\(own.count) reading\(own.count == 1 ? "" : "s"), latest \(latest.systolic)/\(latest.diastolic) on \(latest.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: CGFloat(refs.count) * 120)
    }

    private func binding(for ref: DeviceUserRef) -> Binding<Choice> {
        Binding(get: { choices[ref.id] ?? .newProfile }, set: { choices[ref.id] = $0 })
    }

    private func nameBinding(for ref: DeviceUserRef) -> Binding<String> {
        Binding(get: { newNames[ref.id] ?? ref.suggestedProfileName }, set: { newNames[ref.id] = $0 })
    }

    private func download() async {
        let source: any ReadingSource
        switch kind {
        case .bpm25:
            guard let usb = BPM25Source.connected().first else {
                phase = .failed(BPM25Error.noDevice.localizedDescription)
                return
            }
            source = usb
        case .bluetooth:
            source = BluetoothBPSource()
        }

        let (messages, sink) = AsyncStream.makeStream(of: String.self)
        let progress = Task {
            for await message in messages { phase = .running(message) }
        }
        defer {
            sink.finish()
            progress.cancel()
        }

        do {
            let readings = try await source.fetchReadings { sink.yield($0) }
            progress.cancel()
            let importer = ReadingImporter(context: context)
            let unlinked = try importer.unlinkedUsers(in: readings)
            if unlinked.isEmpty {
                phase = .done(try importer.importDeviceReadings(readings))
            } else {
                // A profile with no device yet is the likely owner of the first device user.
                let unclaimed = profiles.filter { $0.deviceLinks.isEmpty }
                for (ref, profile) in zip(unlinked, unclaimed) {
                    choices[ref.id] = .existing(profile.persistentModelID)
                }
                phase = .assign(readings, unlinked)
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func commit(readings: [DeviceReading], refs: [DeviceUserRef]) {
        let importer = ReadingImporter(context: context)
        var created: [String] = []
        do {
            for ref in refs {
                let profile: Profile
                let choice = choices[ref.id] ?? .newProfile
                if choice == .ignore {
                    try importer.linkDeviceUser(ref, to: nil)
                    continue
                }
                if case let .existing(id) = choice, let existing = context.model(for: id) as? Profile {
                    profile = existing
                } else {
                    let name = (newNames[ref.id] ?? ref.suggestedProfileName).trimmingCharacters(in: .whitespaces)
                    profile = Profile(name: name.isEmpty ? ref.suggestedProfileName : name)
                    context.insert(profile)
                    created.append(profile.name)
                }
                try importer.linkDeviceUser(ref, to: profile)
            }
            var summary = try importer.importDeviceReadings(readings)
            summary.createdProfiles = created
            phase = .done(summary)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
