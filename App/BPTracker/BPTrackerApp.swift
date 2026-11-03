import SwiftData
import SwiftUI

@main
struct BPTrackerApp: App {
    let container: ModelContainer
    @State private var autoImporter: BPM25AutoImporter
    @State private var backups: BackupManager
    @State private var health: HealthExporter

    init() {
        AppSettings.registerDefaults()
        do {
            container = try ModelContainer(for: Profile.self, Reading.self, DeviceLink.self, DeletedReading.self)
        } catch {
            fatalError("Could not open the data store: \(error)")
        }
        let backups = BackupManager(context: container.mainContext)
        let health = HealthExporter(context: container.mainContext)
        let importer = BPM25AutoImporter(context: container.mainContext) { summary in
            if summary.added > 0 { try? backups.backUpNow() }
        }
        // Tests use their own in-memory stores and must not touch the device or backups.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            importer.start()
            backups.start()
            health.start()
        }
        _health = State(initialValue: health)
        #if DEBUG
        if CommandLine.arguments.contains("-seedDemoData") { try? DemoData.insert(into: container.mainContext) }
        #endif
        _autoImporter = State(initialValue: importer)
        _backups = State(initialValue: backups)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(autoImporter)
                .environment(backups)
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 780)
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Button("Add Demo Data") { try? DemoData.insert(into: container.mainContext) }
                Button("Remove Demo Data") { try? DemoData.remove(from: container.mainContext) }
            }
        }
        #endif

        Settings {
            SettingsView()
                .environment(backups)
                .environment(health)
                .modelContainer(container)
        }
    }
}
