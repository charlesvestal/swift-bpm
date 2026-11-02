import SwiftData
import SwiftUI

struct ProfileSidebar: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @Binding var selection: Profile?

    @State private var renaming: Profile?
    @State private var newName = ""
    @State private var adding = false
    @State private var deleting: Profile?

    var body: some View {
        List(selection: $selection) {
            Section("Profiles") {
                ForEach(profiles) { profile in
                    Label(profile.name, systemImage: "person.crop.circle")
                        .badge(profile.readings.count)
                        .tag(profile)
                        .contextMenu {
                            Button("Rename…") {
                                newName = profile.name
                                renaming = profile
                            }
                            Button("Delete…", role: .destructive) { deleting = profile }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newName = ""
                    adding = true
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
        .alert("New Profile", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let profile = Profile(name: name)
                context.insert(profile)
                try? context.save()
                selection = profile
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let renaming, !name.isEmpty {
                    renaming.name = name
                    try? context.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { profile in
            Button("Delete Profile and \(profile.readings.count) Readings", role: .destructive) {
                if selection == profile { selection = nil }
                context.delete(profile)
                try? context.save()
            }
        } message: { _ in
            Text("This cannot be undone. Export a CSV first if you want to keep the readings.")
        }
    }
}
