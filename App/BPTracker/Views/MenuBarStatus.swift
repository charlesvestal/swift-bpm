import SwiftUI

/// The menu-bar heart: what auto-import and the Health hand-off are doing,
/// and a way back to the window while the app runs in the background.
struct MenuBarStatus: View {
    @Environment(BPM25AutoImporter.self) private var autoImporter
    @Environment(HealthExporter.self) private var health
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(autoImportText)
        if let last = health.lastExport {
            Text("Apple Health: last written \(last.date.formatted(date: .abbreviated, time: .shortened))")
        }
        Divider()
        Button("Open Blood Pressure") {
            openWindow(id: BPTrackerApp.mainWindowID)
            NSApp.activate()
        }
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Blood Pressure") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var autoImportText: String {
        switch autoImporter.status {
        case .disabled: "Auto-import off"
        case .notConnected: "BPM25 not connected"
        case .waiting: "BPM25 connected, waiting for PC mode"
        case .importing: "Importing from BPM25…"
        case let .imported(summary, date):
            summary.added == 0 ? "BPM25 up to date, \(date.formatted(date: .omitted, time: .shortened))"
                               : "BPM25: \(summary.added) new, \(date.formatted(date: .omitted, time: .shortened))"
        case let .failed(message): "BPM25: \(message)"
        }
    }
}
