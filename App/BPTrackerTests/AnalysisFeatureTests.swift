import AppKit
import BPMKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import BPTracker

@MainActor
struct AnalysisFeatureTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try AppSchema.inMemoryContainer()
        context = container.mainContext
    }

    func reading(_ date: Date, _ sys: Int, _ dia: Int, hidden: Bool = false, profile: Profile) -> Reading {
        let r = Reading(timestamp: date, systolic: sys, diastolic: dia, pulse: 60, sourceName: "Manual",
                        deviceID: profile.manualDeviceID, deviceUser: nil, hidden: hidden, profile: profile)
        context.insert(r)
        return r
    }

    @Test func analysisSkipsHiddenAndGroups() {
        let p = Profile(name: "P")
        context.insert(p)
        let now = Date()
        let readings = [reading(now.addingTimeInterval(-120), 140, 90, profile: p),
                        reading(now.addingTimeInterval(-60), 130, 80, profile: p),
                        reading(now.addingTimeInterval(-30), 200, 120, hidden: true, profile: p),
                        reading(now.addingTimeInterval(-86_400 * 60), 120, 80, profile: p)]

        let plain = ReadingAnalysis(readings: readings, period: Period(kind: .last30), options: AnalysisOptions())
        #expect(plain.points.count == 2)
        #expect(plain.summary.systolic?.max == 140)

        let grouped = ReadingAnalysis(readings: readings, period: Period(kind: .all), options: AnalysisOptions(groupWindowMinutes: 5))
        #expect(grouped.points.count == 2)
        #expect(grouped.summary.readingCount == 3)
        #expect(grouped.points.last?.systolic == 135)
    }

    @Test func defaultGuidelineIsEuropean() {
        let p = Profile(name: "P")
        context.insert(p)
        let r = reading(Date(), 123, 75, profile: p)
        #expect(AnalysisOptions().guideline == .esh2023)
        #expect(r.category(in: AnalysisOptions().guideline).title == "Normal")
        #expect(r.category(in: .accAha2017).title == "Elevated")
        let analysis = ReadingAnalysis(readings: [r], period: Period(kind: .all), options: AnalysisOptions(guideline: .accAha2017))
        #expect(analysis.summary.categoryShares.map(\.category.title) == ["Elevated"])
    }

    @Test func calendarPeriodsPage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let mid = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12)))
        var period = Period(kind: .month, anchor: mid)
        let march = try #require(period.interval())
        #expect(calendar.component(.day, from: march.start) == 1)
        #expect(period.contains(mid))
        #expect(!period.contains(march.end))
        #expect(period.title == mid.formatted(.dateTime.month(.wide).year()))
        #expect(period.canStepForward(now: mid.addingTimeInterval(86_400 * 60)))
        #expect(!period.canStepForward(now: mid))

        period.step(by: -1)
        #expect(calendar.component(.month, from: period.anchor) == 2)
        #expect(!period.contains(mid))

        #expect(Period(kind: .all).contains(.distantPast))
        #expect(!Period(kind: .last7).contains(Date().addingTimeInterval(-8 * 86_400)))
    }

    @Test func backupWritesCSVAndKeepsNewest() throws {
        let suite = "backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppSettings.backupsEnabled)
        defaults.set(2, forKey: AppSettings.backupsToKeep)
        let folder = FileManager.default.temporaryDirectory.appending(path: "backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let p = Profile(name: "Alex")
        context.insert(p)
        _ = reading(Date(), 120, 80, hidden: true, profile: p)
        let manager = BackupManager(context: context, defaults: defaults, defaultFolder: folder)

        // Old backups from earlier days, plus an unrelated file that must survive pruning.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for day in ["2026-01-01 080000", "2026-01-02 080000"] {
            try Data().write(to: folder.appending(path: "\(BackupManager.filePrefix)\(day).csv"))
        }
        try Data().write(to: folder.appending(path: "notes.txt"))

        let url = try manager.backUpNow()
        let rows = try ReadingsCSV.decode(String(contentsOf: url, encoding: .utf8))
        #expect(rows.count == 1 && rows[0].hidden && rows[0].profile == "Alex")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.count == 3)
        #expect(files.contains("notes.txt"))
        #expect(!files.contains("\(BackupManager.filePrefix)2026-01-01 080000.csv"))

        #expect(manager.lastBackup != nil)
        manager.backUpIfDue() // not due again yet
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)
    }

    /// Renders sample screens for a visual check. Run with TEST_RUNNER_RENDER_SAMPLES=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_SAMPLES"] != nil))
    func renderSamples() throws {
        let p = Profile(name: "Alex")
        context.insert(p)
        var readings: [Reading] = []
        let start = Date().addingTimeInterval(-86_400 * 45)
        for day in 0..<45 {
            for (hour, bump) in [(7, 8), (7, 8), (21, 0)] {
                let t = Calendar.current.date(bySettingHour: hour, minute: readings.count % 2, second: 0,
                                              of: start.addingTimeInterval(Double(day) * 86_400))!
                readings.append(reading(t, 118 + bump + (day * 7) % 19, 74 + bump / 2 + (day * 5) % 11, profile: p))
            }
        }
        readings[3].irregularHeartbeat = true
        let options = AnalysisOptions(groupWindowMinutes: 5)
        let analysis = ReadingAnalysis(readings: readings, period: Period(kind: .last90), options: options)
        // GroupBox and segmented pickers are AppKit-backed and do not render offscreen.
        let view = VStack(alignment: .leading, spacing: 24) {
            TimeOfDayTable(analysis: analysis, useMedian: false)
            CategoryDistribution(summary: analysis.summary)
            RangeChart(buckets: analysis.buckets, thresholds: options.thresholds, guideline: options.guideline).frame(height: 220)
        }
            .frame(width: 900, height: 800).padding().background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let png = try #require(renderer.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let dir = FileManager.default.temporaryDirectory
        try png.write(to: dir.appending(path: "statistics.png"))
        try PDFReport.render(profileName: "Alex", period: Period(kind: .last90), readings: readings, options: options)
            .write(to: dir.appending(path: "report.pdf"))
        print("SAMPLES: \(dir.path)")
    }
}

@MainActor
struct HealthExporterTests {
    @Test func writesEachReadingOnceToNewFiles() throws {
        let container = try AppSchema.inMemoryContainer()
        let context = container.mainContext
        let suite = "health-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let me = Profile(name: "Me"), other = Profile(name: "Other")
        context.insert(me)
        context.insert(other)
        func add(_ profile: Profile, _ time: String, _ sys: Int, _ dia: Int, _ pulse: Int?, hidden: Bool = false) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            context.insert(Reading(timestamp: f.date(from: time)!, systolic: sys, diastolic: dia, pulse: pulse, sourceName: "Manual",
                                   deviceID: profile.manualDeviceID, deviceUser: nil, hidden: hidden, profile: profile))
        }
        add(me, "2026-11-02 21:40", 119, 77, nil)
        add(me, "2026-11-02 07:05", 128, 82, 66)
        add(me, "2026-11-02 08:00", 200, 120, 90, hidden: true)
        add(other, "2026-11-02 09:00", 140, 90, 70)

        let exporter = HealthExporter(context: context, defaults: defaults, folder: folder)
        exporter.setProfile(me)
        // Turned off: nothing is written or marked.
        #expect(try exporter.exportPending() == 0)
        #expect(exporter.pending().count == 2)

        // Turned on: the missing folder is created.
        defaults.set(true, forKey: AppSettings.healthEnabled)
        #expect(try exporter.exportPending() == 2)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try String(contentsOf: files[0], encoding: .utf8) == "2026-11-02 07:05,128,82,66\n2026-11-02 21:40,119,77,")

        // Remembered across launches.
        let firstWrite = try #require(exporter.lastExport)
        #expect(firstWrite.count == 2)
        let relaunched = HealthExporter(context: context, defaults: defaults, folder: folder)
        #expect(relaunched.lastExport?.date == firstWrite.date && relaunched.lastExport?.count == 2)

        // Nothing new: no second file, and "last written" stays.
        #expect(try exporter.exportPending() == 0)
        #expect(exporter.lastExport?.date == firstWrite.date)
        add(me, "2026-11-03 07:10", 125, 80, 64)
        #expect(try exporter.exportPending(now: Date().addingTimeInterval(5)) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)

        try exporter.resendAll()
        #expect(exporter.pending().count == 3)
        try exporter.markAllSent()
        #expect(exporter.pending().isEmpty)
    }
}

/// Checks the sandbox exception for the real hand-off folder from inside the
/// sandboxed app. Creates iCloud Drive › Shortcuts › Blood Pressure if missing.
/// Run with TEST_RUNNER_HEALTH_FOLDER_CHECK=1.
struct HealthFolderAccessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEALTH_FOLDER_CHECK"] != nil))
    @MainActor func sandboxCanWriteHandOffFolder() throws {
        let folder = HealthExporter.defaultFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {}
        // A real write: isWritableFile does not consult the sandbox. Hidden name, deleted at once.
        let probe = folder.appending(path: ".write-check")
        try Data("ok".utf8).write(to: probe)
        try FileManager.default.removeItem(at: probe)
        print("HEALTH FOLDER: \(folder.path)")
    }
}

@MainActor
struct DemoDataTests {
    @Test func demoDataIsSeparateRepeatableAndRemovable() throws {
        let container = try AppSchema.inMemoryContainer()
        let context = container.mainContext
        let now = Date()
        let added = try DemoData.insert(into: context, now: now)
        #expect(added > 300)
        #expect(try DemoData.insert(into: context, now: now) == 0) // only once
        let demo = try #require(try DemoData.profile(in: context))
        #expect(demo.readings.count == added)
        #expect(demo.readings.filter(\.hidden).count == 1)
        #expect(demo.readings.allSatisfy { $0.timestamp <= now && $0.sourceName == "Demo data" })

        // Mornings run higher than evenings, and pressure eases over the period.
        let analysis = ReadingAnalysis(readings: demo.readings, period: Period(kind: .all), options: AnalysisOptions(groupWindowMinutes: 5))
        let parts = Dictionary(uniqueKeysWithValues: analysis.byTimeOfDay.map { ($0.0, $0.1) })
        #expect(try #require(parts[.morning]?.systolic?.mean) > (try #require(parts[.evening]?.systolic?.mean)))
        let points = analysis.points
        let firstMonth = BPSummary(Array(points.prefix(40))).systolic!.mean
        let lastMonth = BPSummary(Array(points.suffix(40))).systolic!.mean
        #expect(firstMonth > lastMonth + 5)

        try DemoData.remove(from: context)
        #expect(try DemoData.profile(in: context) == nil)
        #expect(try context.fetch(FetchDescriptor<Reading>()).isEmpty)
    }
}

@MainActor
struct MeasurementWeekTests {
    @Test func weekReportAndCleanup() throws {
        let container = try AppSchema.inMemoryContainer()
        let context = container.mainContext
        let me = Profile(name: "Me")
        context.insert(me)
        let start = Calendar.current.date(byAdding: .day, value: -8, to: Calendar.current.startOfDay(for: Date()))!
        let week = MeasurementWeek(profileID: me.uuid, start: start, morningMinutes: 420, eveningMinutes: 1260, reminderStyle: .off)
        context.insert(week)
        var readings: [Reading] = []
        for day in 0..<7 {
            for (hour, sys, dia) in [(7, 131, 84), (21, 124, 79)] {
                for minute in 0..<2 {
                    let t = Calendar.current.date(byAdding: .minute, value: hour * 60 + minute,
                                                  to: Calendar.current.date(byAdding: .day, value: day, to: start)!)!
                    let r = Reading(timestamp: t, systolic: sys + minute, diastolic: dia, pulse: 64, sourceName: "Manual",
                                    deviceID: me.manualDeviceID, deviceUser: nil, profile: me)
                    context.insert(r)
                    readings.append(r)
                }
            }
        }
        try context.save()
        #expect(week.isFinished() && !week.isActive())

        let result = HomeMonitoringResult(points: me.readings.map(\.point), plan: week.plan)
        #expect(result.included.count == 24 && result.meetsMinimum)

        let data = PDFReport.renderWeek(profileName: "Me", week: week, readings: me.readings, guideline: .esh2023)
        #expect(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages == 2) // summary + 28 readings
        if ProcessInfo.processInfo.environment["RENDER_SAMPLES"] != nil {
            let url = FileManager.default.temporaryDirectory.appending(path: "week-report.pdf")
            try data.write(to: url)
            print("WEEK SAMPLE: \(url.path)")
        }

        try ReadingImporter(context: context).deleteProfile(me)
        #expect(try context.fetch(FetchDescriptor<MeasurementWeek>()).isEmpty)
    }
}
