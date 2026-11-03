import BPMKit
import Foundation

/// UserDefaults keys and defaults shared by views (via @AppStorage) and
/// non-view code such as the PDF report and backups.
enum AppSettings {
    static let systolicThreshold = "systolicThreshold"
    static let diastolicThreshold = "diastolicThreshold"
    /// Readings within this many minutes are averaged; 0 turns grouping off.
    static let groupWindowMinutes = "groupWindowMinutes"
    static let useMedian = "useMedian"
    /// A `BPGuideline` raw value.
    static let guideline = "guideline"
    static let showMenuBarExtra = "showMenuBarExtra"
    /// A `ReportLanguage` raw value.
    static let reportLanguage = "reportLanguage"
    static let backupsEnabled = "backupsEnabled"
    static let backupsToKeep = "backupsToKeep"
    static let backupFolderBookmark = "backupFolderBookmark"
    static let lastBackup = "lastBackup"
    static let healthEnabled = "healthEnabled"
    /// UUID of the profile whose readings go to Apple Health.
    static let healthProfile = "healthProfile"
    static let healthLastWritten = "healthLastWritten"
    static let healthLastWrittenCount = "healthLastWrittenCount"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            systolicThreshold: 130,
            diastolicThreshold: 80,
            groupWindowMinutes: 0,
            useMedian: false,
            guideline: BPGuideline.esh2023.rawValue,
            showMenuBarExtra: true,
            reportLanguage: ReportLanguage.system.rawValue,
            backupsEnabled: true,
            backupsToKeep: 10,
            healthEnabled: false,
            BPM25AutoImporter.enabledKey: true,
        ])
    }

    static var options: AnalysisOptions {
        let d = UserDefaults.standard
        return AnalysisOptions(
            thresholds: BPThresholds(systolic: d.integer(forKey: systolicThreshold), diastolic: d.integer(forKey: diastolicThreshold)),
            groupWindowMinutes: d.integer(forKey: groupWindowMinutes),
            useMedian: d.bool(forKey: useMedian),
            guideline: d.string(forKey: guideline).flatMap(BPGuideline.init(rawValue:)) ?? .esh2023)
    }
}

struct AnalysisOptions: Equatable {
    var thresholds = BPThresholds()
    var groupWindowMinutes = 0
    var useMedian = false
    var guideline = BPGuideline.esh2023
}
