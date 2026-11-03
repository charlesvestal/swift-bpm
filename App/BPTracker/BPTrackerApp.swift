import SwiftData
import SwiftUI

@main
struct BPTrackerApp: App {
    static let mainWindowID = "main"
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true

    let container: ModelContainer
    @State private var autoImporter: BPM25AutoImporter
    @State private var backups: BackupManager
    @State private var health: HealthExporter

    init() {
        AppSettings.registerDefaults()
        do {
            StoreSnapshot.takeIfNeeded()
            container = try AppSchema.container(ModelConfiguration(schema: AppSchema.current))
        } catch {
            fatalError("Could not open the data store: \(error)")
        }
        let backups = BackupManager(context: container.mainContext)
        let health = HealthExporter(context: container.mainContext)
        let context = container.mainContext
        let importer = BPM25AutoImporter(context: context) { summary in
            guard summary.added > 0 else { return }
            _ = try? backups.backUpNow()
            Task { await WeekReminders.markCompleted(in: context) }
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
        WindowGroup(id: Self.mainWindowID) {
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

        MenuBarExtra("Blood Pressure", systemImage: "heart.fill", isInserted: $showMenuBarExtra) {
            MenuBarStatus()
                .environment(autoImporter)
                .environment(health)
        }

        Settings {
            SettingsView()
                .environment(backups)
                .environment(health)
                .modelContainer(container)
        }
    }
}
