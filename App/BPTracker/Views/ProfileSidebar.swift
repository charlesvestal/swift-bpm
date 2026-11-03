import BPMKit
import SwiftData
import SwiftUI

struct ProfileSidebar: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @Query(sort: \MeasurementWeek.start, order: .reverse) private var weeks: [MeasurementWeek]
    @Binding var selection: SidebarItem?
    @Binding var newWeekFor: Profile?
    @State private var deletingWeek: MeasurementWeek?

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
                        .tag(SidebarItem.profile(profile.uuid))
                        .contextMenu {
                            Button("New Measurement Week…") { newWeekFor = profile }
                            Divider()
                            Button("Rename…") {
                                newName = profile.name
                                renaming = profile
                            }
                            Button("Delete…", role: .destructive) { deleting = profile }
                        }
                    ForEach(weeks.filter { $0.profileID == profile.uuid }) { week in
                        WeekRow(week: week, profile: profile)
                            .padding(.leading, 18)
                            .tag(SidebarItem.week(week.uuid))
                            .contextMenu {
                                Button("Delete Week…", role: .destructive) { deletingWeek = week }
                            }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                AutoImportStatusView()
                Button {
                    newName = ""
                    adding = true
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(.borderless)
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
                selection = .profile(profile.uuid)
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
                if selection == .profile(profile.uuid) { selection = nil }
                let id = profile.uuid
                for week in (try? context.fetch(FetchDescriptor<MeasurementWeek>(predicate: #Predicate { $0.profileID == id }))) ?? [] {
                    Task { await WeekReminders.cancel(week) }
                }
                try? ReadingImporter(context: context).deleteProfile(profile)
            }
        } message: { _ in
            Text("Its monitor users will be set to \"Don't import\" (change that in Settings). You can undo with ⌘Z.")
        }
        .confirmationDialog("Delete this measurement week?",
                            isPresented: Binding(get: { deletingWeek != nil }, set: { if !$0 { deletingWeek = nil } }),
                            presenting: deletingWeek) { week in
            Button("Delete Week", role: .destructive) { MeasurementWeekView.delete(week, in: context) }
        } message: { _ in
            Text("The readings stay; only the week and its reminders are removed.")
        }
    }
}

/// A measurement week under its profile: dates, status and sessions done.
private struct WeekRow: View {
    let week: MeasurementWeek
    let profile: Profile

    var body: some View {
        let result = HomeMonitoringResult(points: profile.readings.filter { !$0.hidden }.map(\.point), plan: week.plan)
        Label {
            Text("Week of \(week.start.formatted(.dateTime.month(.abbreviated).day()))")
        } icon: {
            Image(systemName: week.isFinished() ? "checkmark.circle" : week.isActive() ? "calendar.badge.clock" : "calendar")
        }
        .badge(Text("\(result.completedSessions)/\(result.expectedSessions)"))
        .help(week.isFinished() ? "Finished" : week.isActive() ? "In progress" : "Upcoming")
    }
}
