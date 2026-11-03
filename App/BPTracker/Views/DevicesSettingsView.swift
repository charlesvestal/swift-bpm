import SwiftData
import SwiftUI

/// Which profile each monitor user's readings go to.
struct DevicesSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\DeviceLink.deviceName), SortDescriptor(\DeviceLink.deviceUser)]) private var links: [DeviceLink]
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @Query private var deleted: [DeletedReading]
    @AppStorage(BPM25AutoImporter.enabledKey) private var autoImport = true
    @State private var error: String?

    /// Picker value: a profile, or "Don't import".
    private enum Target: Hashable {
        case profile(PersistentIdentifier)
        case ignore
    }

    var body: some View {
        Form {
            Section {
                Toggle("Import automatically when a Veroval BPM25 is connected", isOn: $autoImport)
            } footer: {
                Text("Readings are imported as soon as the monitor is in PC mode. New monitor users get their own profile, or one that has no monitor yet.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if links.isEmpty {
                    Text("No monitors yet. Device users appear here after the first import.")
                        .foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    HStack {
                        Picker(link.title, selection: targetBinding(for: link)) {
                            ForEach(profiles) { Text($0.name).tag(Target.profile($0.persistentModelID)) }
                            Divider()
                            Text("Don't import").tag(Target.ignore)
                        }
                        Button {
                            context.delete(link)
                            try? context.save()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this device user. You will be asked again on the next import.")
                    }
                }
            } header: {
                Text("Monitor users")
            } footer: {
                Text("Changing a profile here also moves the readings already imported from that monitor user. \"Don't import\" keeps readings already imported.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Deleted readings") {
                    Text("\(deleted.count)")
                }
                Button("Allow Deleted Readings to Be Imported Again") {
                    do {
                        try ReadingImporter(context: context).forgetDeletedReadings()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(deleted.isEmpty)
            } footer: {
                Text("Readings you delete are remembered so they don't come back the next time the monitor's memory is downloaded.")
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func targetBinding(for link: DeviceLink) -> Binding<Target> {
        Binding(get: {
            if let profile = link.profile, !link.ignored { .profile(profile.persistentModelID) } else { .ignore }
        }, set: { target in
            let importer = ReadingImporter(context: context)
            do {
                switch target {
                case .ignore:
                    try importer.ignore(link)
                case let .profile(id):
                    guard let profile = context.model(for: id) as? Profile, profile != link.profile || link.ignored else { return }
                    try importer.relink(link, to: profile)
                }
            } catch {
                self.error = error.localizedDescription
            }
        })
    }
}
