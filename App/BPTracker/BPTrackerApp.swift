import SwiftData
import SwiftUI

@main
struct BPTrackerApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Profile.self, Reading.self, DeviceLink.self, DeletedReading.self)
        } catch {
            fatalError("Could not open the data store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 780)

        Settings {
            DevicesSettingsView()
                .modelContainer(container)
        }
    }
}
