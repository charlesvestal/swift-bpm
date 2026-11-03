import Foundation
import OSLog

/// Copies the data store aside before the app opens it, once per app version
/// and data-model version, so a failed migration cannot lose data. Keeps the newest few.
enum StoreSnapshot {
    static let keep = 3

    static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Store Snapshots", directoryHint: .isDirectory) }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "0")-\(info?["CFBundleVersion"] as? String ?? "0")"
        return "\(app) schema \(AppSchema.current.version)"
    }

    static func takeIfNeeded(store: URL = storeURL, folder: URL = folder, version: String = appVersion) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return }
        let target = folder.appending(path: "before \(version)", directoryHint: .isDirectory)
        guard !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: store.path + suffix)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: target.appending(path: source.lastPathComponent))
                }
            }
            let snapshots = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
                .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast }
            for old in snapshots.dropFirst(keep) { try fm.removeItem(at: old) }
        } catch {
            Logger(subsystem: "com.charlesvestal.BPTracker", category: "store")
                .error("Store snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
