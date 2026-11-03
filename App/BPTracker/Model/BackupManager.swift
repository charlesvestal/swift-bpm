import BPMKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Writes a CSV of every reading once a day and keeps the newest few.
///
/// Backups go to a folder the user picked (kept as a security-scoped
/// bookmark) or, by default, to Backups inside the app's container. Restore
/// with File › Import › CSV; deduplication makes re-importing safe.
@Observable
final class BackupManager {
    static let interval: TimeInterval = 24 * 60 * 60
    static let filePrefix = "Blood Pressure Backup "

    private(set) var lastError: String?
    private(set) var lastBackup: Date?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultFolder: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.charlesvestal.BPTracker", category: "backup")

    init(context: ModelContext, defaults: UserDefaults = .standard,
         defaultFolder: URL = URL.applicationSupportDirectory.appending(path: "Backups", directoryHint: .isDirectory)) {
        self.context = context
        self.defaults = defaults
        self.defaultFolder = defaultFolder
        lastBackup = defaults.object(forKey: AppSettings.lastBackup) as? Date
    }

    private var customFolder: BookmarkedFolder { BookmarkedFolder(defaults: defaults, key: AppSettings.backupFolderBookmark) }

    /// The custom folder's path, or nil when backups go to the default folder.
    var customFolderPath: String? {
        customFolder.url?.path
    }

    /// Checks hourly whether a backup is due.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.backUpIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func backUpIfDue() {
        guard defaults.bool(forKey: AppSettings.backupsEnabled) else { return }
        if let lastBackup, Date().timeIntervalSince(lastBackup) < Self.interval { return }
        _ = try? backUpNow()
    }

    @discardableResult
    func backUpNow() throws -> URL {
        do {
            let readings = try context.fetch(FetchDescriptor<Reading>())
            let csv = ReadingsCSV.encode(ReadingImporter.csvRows(for: readings))
            let url = try withFolder { folder in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HHmmss"
                let stamp = formatter.string(from: Date())
                let url = folder.appending(path: "\(Self.filePrefix)\(stamp).csv")
                try Data(csv.utf8).write(to: url, options: .atomic)
                try prune(folder)
                return url
            }
            lastBackup = Date()
            defaults.set(lastBackup, forKey: AppSettings.lastBackup)
            lastError = nil
            log.info("Backed up \(readings.count) readings to \(url.path, privacy: .public)")
            return url
        } catch {
            lastError = error.localizedDescription
            log.error("Backup failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func setCustomFolder(_ url: URL?) throws {
        try customFolder.set(url)
        lastError = nil
    }

    /// Runs `body` with the backup folder, holding security-scoped access to a custom one.
    func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        try customFolder.withAccess(body) ?? body(defaultFolder)
    }

    /// Deletes all but the newest backups this app wrote.
    private func prune(_ folder: URL) throws {
        let keep = max(1, defaults.integer(forKey: AppSettings.backupsToKeep))
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(keep) {
            try FileManager.default.removeItem(at: old)
        }
    }
}
