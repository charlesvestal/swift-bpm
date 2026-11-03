import Foundation
import Observation
import OSLog
import SwiftData

/// Hands readings to Apple Health through an iPhone shortcut.
///
/// HealthKit has no store on the Mac, so new readings of one profile are
/// written to iCloud Drive › Shortcuts › Blood Pressure (reachable through a
/// sandbox exception, see project.yml), one new file per batch. A shortcut on the iPhone logs every file it finds to Health and
/// deletes it. Each reading is written once (`Reading.sentToHealth`), and
/// files are never rewritten, so a file the phone is processing cannot change
/// under it.
///
/// File format, one reading per line, no header, local time:
/// `2026-11-02 07:05,128,82,66` (date, systolic, diastolic, pulse or empty).
@Observable
final class HealthExporter {
    static let filePrefix = "Blood Pressure for Health "

    /// The last file written, kept across launches.
    private(set) var lastExport: (date: Date, count: Int)?
    private(set) var lastError: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    let folder: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.charlesvestal.BPTracker", category: "health")

    init(context: ModelContext, defaults: UserDefaults = .standard, folder: URL = HealthExporter.defaultFolder) {
        self.context = context
        self.defaults = defaults
        self.folder = folder
        if let date = defaults.object(forKey: AppSettings.healthLastWritten) as? Date {
            lastExport = (date, defaults.integer(forKey: AppSettings.healthLastWrittenCount))
        }
    }

    static var shortcutURL: URL? { Bundle.main.url(forResource: "Blood Pressure to Health", withExtension: "shortcut") }

    /// iCloud Drive › Shortcuts › Blood Pressure, the folder the bundled shortcut
    /// reads on every device (see Tools/make-health-shortcut.py). In the sandbox
    /// the home directory is the container, so the real one comes from the user database.
    static var defaultFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appending(path: "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Blood Pressure", directoryHint: .isDirectory)
    }

    /// Creates the folder if needed; the shortcut fails when it is missing.
    func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    var profile: Profile? {
        guard let id = defaults.string(forKey: AppSettings.healthProfile).flatMap(UUID.init(uuidString:)) else { return nil }
        return try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.uuid == id })).first
    }

    func setProfile(_ profile: Profile?) {
        defaults.set(profile?.uuid.uuidString, forKey: AppSettings.healthProfile)
    }

    /// Checks for new readings every minute.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? self?.exportPending()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Readings of the Health profile not yet handed over, oldest first.
    func pending() -> [Reading] {
        guard let profile else { return [] }
        return profile.readings.filter { !$0.hidden && !$0.sentToHealth }.sorted { $0.timestamp < $1.timestamp }
    }

    /// Writes a file with every pending reading. Returns how many it wrote.
    @discardableResult
    func exportPending(now: Date = Date()) throws -> Int {
        guard defaults.bool(forKey: AppSettings.healthEnabled) else { return 0 }
        let readings = pending()
        guard !readings.isEmpty else { return 0 }
        do {
            if !FileManager.default.fileExists(atPath: folder.path) { try ensureFolder() }
            let stamp = Self.formatter("yyyy-MM-dd HHmmss").string(from: now)
            let url = folder.appending(path: "\(Self.filePrefix)\(stamp).csv")
            try Data(Self.lines(for: readings).utf8).write(to: url, options: .withoutOverwriting)
            let name = url.lastPathComponent
            context.undoManager?.disableUndoRegistration()
            defer { context.undoManager?.enableUndoRegistration() }
            readings.forEach { $0.sentToHealth = true }
            try context.save()
            lastExport = (now, readings.count)
            defaults.set(now, forKey: AppSettings.healthLastWritten)
            defaults.set(readings.count, forKey: AppSettings.healthLastWrittenCount)
            lastError = nil
            log.info("Wrote \(readings.count) readings for Apple Health to \(name, privacy: .public)")
            return readings.count
        } catch {
            lastError = error.localizedDescription
            log.error("Apple Health export failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Treat everything already stored as being in Health (for readings that got there another way).
    func markAllSent() throws {
        profile?.readings.forEach { $0.sentToHealth = true }
        try context.save()
    }

    /// Send every reading again on the next export. Health will then hold duplicates
    /// of anything it already has.
    func resendAll() throws {
        profile?.readings.forEach { $0.sentToHealth = false }
        try context.save()
    }

    static func lines(for readings: [Reading]) -> String {
        let f = formatter("yyyy-MM-dd HH:mm")
        return readings.map { "\(f.string(from: $0.timestamp)),\($0.systolic),\($0.diastolic),\($0.pulse.map(String.init) ?? "")" }
            .joined(separator: "\n") // no trailing newline: the shortcut would see an empty last line
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
