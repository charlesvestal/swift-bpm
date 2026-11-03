import AppKit
import BPMKit
import ServiceManagement
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettingsView()
                .tabItem { Label("Monitors", systemImage: "cable.connector") }
            AnalysisSettingsView()
                .tabItem { Label("Analysis", systemImage: "chart.xyaxis.line") }
            BackupSettingsView()
                .tabItem { Label("Backups", systemImage: "externaldrive") }
            HealthSettingsView()
                .tabItem { Label("Apple Health", systemImage: "heart") }
        }
        .frame(width: 520, height: 600)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                                       set: { setOpenAtLogin($0) }))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Blood Pressure in System Settings › General › Login Items.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Auto-import, Apple Health and backups only run while the app is open. With it opening at login and in the menu bar, they keep working after you close the window.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

private struct AnalysisSettingsView: View {
    @AppStorage(AppSettings.systolicThreshold) private var systolicThreshold = 130
    @AppStorage(AppSettings.diastolicThreshold) private var diastolicThreshold = 80
    @AppStorage(AppSettings.groupWindowMinutes) private var groupWindowMinutes = 0
    @AppStorage(AppSettings.useMedian) private var useMedian = false
    @AppStorage(AppSettings.guideline) private var guideline = BPGuideline.esh2023

    var body: some View {
        Form {
            Section {
                Picker("Guideline", selection: $guideline) {
                    ForEach(BPGuideline.allCases) { Text($0.title).tag($0) }
                }
                Text(guideline.categories.map(\.title).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Classification")
            } footer: {
                Text("Names the category of each reading and colours it. European monitors such as Veroval use ESH. Both guidelines are written for readings taken at a clinic.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $systolicThreshold, in: 100...200, step: 5) {
                    LabeledContent("Systolic", value: "\(systolicThreshold) mmHg")
                }
                Stepper(value: $diastolicThreshold, in: 60...120, step: 5) {
                    LabeledContent("Diastolic", value: "\(diastolicThreshold) mmHg")
                }
                HStack {
                    Button("ACC/AHA (130/80)") { (systolicThreshold, diastolicThreshold) = (130, 80) }
                    Button("ESH home (135/85)") { (systolicThreshold, diastolicThreshold) = (135, 85) }
                }
            } header: {
                Text("Thresholds")
            } footer: {
                Text("Shown as lines on the charts. Readings at or above either value are shown in red and counted as raised. Your clinician may give you different targets.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Average readings taken within", selection: $groupWindowMinutes) {
                    Text("Off").tag(0)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                Picker("Statistics show", selection: $useMedian) {
                    Text("Average").tag(false)
                    Text("Median").tag(true)
                }
            } header: {
                Text("Statistics")
            } footer: {
                Text("Guidelines recommend taking two or three readings a minute apart and using their average. With grouping on, back-to-back readings count as one measurement in charts, statistics and reports. The readings themselves are not changed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HealthSettingsView: View {
    @Environment(HealthExporter.self) private var health
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @AppStorage(AppSettings.healthEnabled) private var enabled = false
    @AppStorage(AppSettings.healthProfile) private var profileID = ""
    @State private var confirmResend = false
    @State private var message: String?

    var body: some View {
        // Read so the view refreshes when the profile changes.
        let _ = profileID
        Form {
            Section {
                Toggle("Send readings to Apple Health", isOn: $enabled)
                Picker("Profile", selection: Binding(get: { health.profile }, set: { health.setProfile($0) })) {
                    Text("None").tag(Profile?.none)
                    ForEach(profiles) { Text($0.name).tag(Optional($0)) }
                }
            } footer: {
                Text("Health isn't available on the Mac. New readings of this profile are written to a folder in iCloud Drive, and a shortcut on your iPhone adds them to Health, skipping any it already has.")
                    .foregroundStyle(.secondary)
            }
            Section("Setup") {
                LabeledContent("Folder") {
                    HStack {
                        Text("iCloud Drive › Shortcuts › \(health.folder.lastPathComponent)")
                        Button("Show in Finder") {
                            try? health.ensureFolder()
                            NSWorkspace.shared.activateFileViewerSelecting([health.folder])
                        }
                    }
                }
                LabeledContent("Shortcut") {
                    Button("Add to Shortcuts…") {
                        if let url = HealthExporter.shortcutURL { NSWorkspace.shared.open(url) }
                    }
                }
                Text("It syncs to your iPhone through iCloud. Run it there once and allow access to Health. To run it daily, add a Time of Day automation in Shortcuts set to Run Immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Waiting to be written") {
                    if health.profile == nil {
                        Text("Choose a profile above").foregroundStyle(.orange)
                    } else {
                        Text("\(health.pending().count)" + (enabled ? "" : " (turn on to start)"))
                    }
                }
                LabeledContent("Last written") {
                    if let last = health.lastExport {
                        Text("\(last.date.formatted(date: .abbreviated, time: .shortened)), \(last.count) reading\(last.count == 1 ? "" : "s")")
                    } else {
                        Text("Never")
                    }
                }
                HStack {
                    Button("Write Now") {
                        do {
                            let n = try health.exportPending()
                            message = n == 0 ? "Nothing new to write." : "Wrote \(n) readings."
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                    .disabled(!enabled)
                    Button("Mark All as Already in Health") { try? health.markAllSent() }
                    Button("Send All Again…") { confirmResend = true }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = health.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _, on in
            if on {
                do { try health.ensureFolder() } catch CocoaError.fileWriteFileExists {} catch { message = error.localizedDescription }
            }
        }
        .confirmationDialog("Send every reading again?", isPresented: $confirmResend) {
            Button("Send All Again", role: .destructive) { try? health.resendAll() }
        } message: {
            Text("The shortcut skips readings Health already has, so this only fills in gaps.")
        }
    }
}

private struct BackupSettingsView: View {
    @Environment(BackupManager.self) private var backups
    @AppStorage(AppSettings.backupsEnabled) private var enabled = true
    @AppStorage(AppSettings.backupsToKeep) private var keep = 10
    @State private var choosingFolder = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Back up daily", isOn: $enabled)
                Stepper(value: $keep, in: 1...100) {
                    LabeledContent("Keep", value: "\(keep) backups")
                }
                LabeledContent("Folder") {
                    Text(backups.customFolderPath ?? "App container (default)")
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…") { choosingFolder = true }
                    if backups.customFolderPath != nil {
                        Button("Use Default") { try? backups.setCustomFolder(nil) }
                    }
                    Spacer()
                    Button("Show in Finder") { reveal() }
                }
                LabeledContent("Last backup") {
                    Text(backups.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
                Button("Back Up Now") {
                    do {
                        let url = try backups.backUpNow()
                        message = "Saved \(url.lastPathComponent)"
                    } catch {
                        message = error.localizedDescription
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = backups.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Each backup is a CSV of every profile, hidden readings included. Restore one with Import › CSV File; readings you already have are skipped.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                do {
                    try backups.setCustomFolder(url)
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }

    private func reveal() {
        try? backups.withFolder { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
