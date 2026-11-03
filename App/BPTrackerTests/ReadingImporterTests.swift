import BPMKit
import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import BPTracker

@MainActor
struct ReadingImporterTests {
    let container: ModelContainer
    let context: ModelContext
    let importer: ReadingImporter

    init() throws {
        container = try AppSchema.inMemoryContainer()
        context = container.mainContext
        importer = ReadingImporter(context: context)
    }

    func reading(_ minute: Int, user: Int?, device: String = "veroval-bpm25", sys: Int = 120) -> DeviceReading {
        DeviceReading(timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60),
                      systolic: sys, diastolic: 80, pulse: 60, deviceID: device, deviceName: "Veroval BPM25", deviceUser: user)
    }

    func readings(of profile: Profile) throws -> [Reading] {
        try context.fetch(FetchDescriptor<Reading>()).filter { $0.profile == profile }
    }

    @Test func linksDeviceUsersAndDeduplicates() throws {
        let alex = Profile(name: "Alex"), sam = Profile(name: "Sam")
        context.insert(alex)
        context.insert(sam)
        let download = [reading(0, user: 1), reading(1, user: 1), reading(2, user: 2)]

        let unlinked = try importer.unlinkedUsers(in: download)
        #expect(unlinked.map(\.deviceUser) == [1, 2])
        try importer.linkDeviceUser(unlinked[0], to: alex)
        try importer.linkDeviceUser(unlinked[1], to: sam)

        let first = try importer.importDeviceReadings(download)
        #expect(first.added == 3 && first.duplicates == 0)
        #expect(try readings(of: alex).count == 2)
        #expect(try readings(of: sam).count == 1)

        // Downloading again, plus one new reading, only adds the new one.
        let second = try importer.importDeviceReadings(download + [reading(5, user: 1)])
        #expect(second.added == 1 && second.duplicates == 3)
        #expect(try importer.unlinkedUsers(in: download).isEmpty)
    }

    @Test func sameMinuteDifferentUsersAreBothKept() throws {
        let p = Profile(name: "P")
        context.insert(p)
        for user in [1, 2] { try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: user), to: p) }
        let summary = try importer.importDeviceReadings([reading(0, user: 1), reading(0, user: 2)])
        #expect(summary.added == 2)
    }

    @Test func relinkMovesOnlyReadingsStillInOldProfile() throws {
        let a = Profile(name: "A"), b = Profile(name: "B"), c = Profile(name: "C")
        [a, b, c].forEach(context.insert)
        let link = try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 2), to: a)
        _ = try importer.importDeviceReadings([reading(0, user: 2), reading(1, user: 2)])
        let moved = try readings(of: a).first!
        moved.profile = c

        try importer.relink(link, to: b)
        #expect(try readings(of: a).isEmpty)
        #expect(try readings(of: b).count == 1)
        #expect(try readings(of: c).count == 1)
    }

    @Test func csvRoundTripIsIdempotentAndKeepsDeviceIdentity() throws {
        let alex = Profile(name: "Alex")
        context.insert(alex)
        try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 1), to: alex)
        _ = try importer.importDeviceReadings([reading(0, user: 1)])
        context.insert(Reading(timestamp: Date(timeIntervalSince1970: 1_800_100_000), systolic: 130, diastolic: 85, pulse: nil,
                               sourceName: "Manual", deviceID: alex.manualDeviceID, deviceUser: nil, note: "evening, \"tired\"",
                               profile: alex))
        try context.save()

        let csv = ReadingsCSV.encode(ReadingImporter.csvRows(for: try context.fetch(FetchDescriptor<Reading>())))
        let again = try importer.importCSV(try ReadingsCSV.decode(csv), fallbackProfile: Profile(name: "unused"))
        #expect(again.added == 0 && again.duplicates == 2)

        // Into a fresh store: profile recreated, and a later device download is recognised.
        let fresh = try AppSchema.inMemoryContainer()
        let freshImporter = ReadingImporter(context: fresh.mainContext)
        let restored = try freshImporter.importCSV(try ReadingsCSV.decode(csv), fallbackProfile: Profile(name: "unused"))
        #expect(restored.added == 2 && restored.createdProfiles == ["Alex"])
        #expect(try freshImporter.unlinkedUsers(in: [reading(0, user: 1)]).isEmpty)
        let download = try freshImporter.importDeviceReadings([reading(0, user: 1)])
        #expect(download.added == 0 && download.duplicates == 1)
    }

    @Test func ignoredDeviceUserIsSkippedAndNotAskedAgain() throws {
        let me = Profile(name: "Me")
        context.insert(me)
        let download = [reading(0, user: 1), reading(1, user: 2), reading(2, user: 2)]
        try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 1), to: me)
        try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 2), to: nil)

        #expect(try importer.unlinkedUsers(in: download).isEmpty)
        let summary = try importer.importDeviceReadings(download)
        #expect(summary.added == 1 && summary.ignored == 2)
        #expect(try readings(of: me).count == 1)
    }

    @Test func ignoringKeepsImportedReadingsAndRelinkResumes() throws {
        let me = Profile(name: "Me"), partner = Profile(name: "Partner")
        context.insert(me)
        context.insert(partner)
        let link = try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 2), to: partner)
        _ = try importer.importDeviceReadings([reading(0, user: 2)])

        try importer.ignore(link)
        #expect(try readings(of: partner).count == 1)
        #expect(try importer.importDeviceReadings([reading(0, user: 2), reading(1, user: 2)]).ignored == 2)

        try importer.relink(link, to: partner)
        let resumed = try importer.importDeviceReadings([reading(0, user: 2), reading(1, user: 2)])
        #expect(resumed.added == 1 && resumed.duplicates == 1)
    }

    @Test func deletedReadingsStayDeletedUntilForgotten() throws {
        let me = Profile(name: "Me")
        context.insert(me)
        try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 1), to: me)
        let download = [reading(0, user: 1), reading(1, user: 1)]
        _ = try importer.importDeviceReadings(download)
        let csv = ReadingsCSV.encode(ReadingImporter.csvRows(for: try readings(of: me)))

        try importer.delete(try readings(of: me).filter { $0.timestamp == download[0].timestamp })
        #expect(try readings(of: me).count == 1)

        let again = try importer.importDeviceReadings(download)
        #expect(again.added == 0 && again.previouslyDeleted == 1 && again.duplicates == 1)
        #expect(try importer.importCSV(try ReadingsCSV.decode(csv), fallbackProfile: me).previouslyDeleted == 1)

        try importer.forgetDeletedReadings()
        #expect(try importer.importDeviceReadings(download).added == 1)
    }

    @Test func autoLinkUsesUnclaimedProfilesThenCreates() throws {
        let me = Profile(name: "Me")
        context.insert(me)
        let download = [reading(0, user: 1), reading(1, user: 2)]
        let created = try importer.autoLinkUnlinkedUsers(in: download)
        #expect(created == ["User 2"])
        #expect(try importer.link(for: DeviceUserRef(download[0]))?.profile == me)
        #expect(try importer.importDeviceReadings(download).added == 2)
        // Already linked or ignored users are left alone next time.
        try importer.linkDeviceUser(DeviceUserRef(download[1]), to: nil)
        #expect(try importer.autoLinkUnlinkedUsers(in: download).isEmpty)
        #expect(try importer.link(for: DeviceUserRef(download[1]))?.ignored == true)
    }

    @Test(arguments: [false, true])
    func deletingProfileCascades(withUndo: Bool) throws {
        if withUndo { context.undoManager = UndoManager() }
        let me = Profile(name: "Me"), other = Profile(name: "Other")
        context.insert(me)
        context.insert(other)
        try importer.linkDeviceUser(DeviceUserRef(deviceID: "veroval-bpm25", deviceName: "V", deviceUser: 1), to: me)
        _ = try importer.importDeviceReadings([reading(0, user: 1), reading(1, user: 1)])
        try importer.delete([try readings(of: me)[0]])

        try importer.deleteProfile(me)
        #expect(try context.fetch(FetchDescriptor<Reading>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DeviceLink>()).allSatisfy { $0.ignored && $0.profile == nil })
        #expect(try context.fetch(FetchDescriptor<Profile>()).map(\.name) == ["Other"])
    }

    /// Mirrors the store state from the crash report: an on-disk store, both
    /// monitor users linked, readings deleted, undo enabled as in the app.
    @Test(arguments: ["Me", "User 2"])
    func deletingProfileFromOnDiskStore(name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("delete-\(UUID().uuidString).store")
        let disk = try AppSchema.container(ModelConfiguration(schema: AppSchema.current, url: url))
        let context = disk.mainContext
        context.undoManager = UndoManager()
        let importer = ReadingImporter(context: context)
        let me = Profile(name: "Me")
        context.insert(me)
        let download = [reading(0, user: 1), reading(1, user: 1), reading(2, user: 2)]
        _ = try importer.autoLinkUnlinkedUsers(in: download)
        _ = try importer.importDeviceReadings(download)
        try importer.delete(try context.fetch(FetchDescriptor<Reading>()).filter { $0.deviceUser == 1 })

        try context.save()

        // Reopen, as on app launch, and let the importer touch the readings
        // the way the auto-importer does before the profile is deleted.
        let reopened = try AppSchema.container(ModelConfiguration(schema: AppSchema.current, url: url))
        let fresh = reopened.mainContext
        fresh.undoManager = UndoManager()
        _ = try ReadingImporter(context: fresh).importDeviceReadings(download)

        let target = try #require(try fresh.fetch(FetchDescriptor<Profile>()).first { $0.name == name })
        let freshImporter = ReadingImporter(context: fresh)
        try freshImporter.deleteProfile(target)
        #expect(try fresh.fetch(FetchDescriptor<Profile>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<Reading>()).allSatisfy { $0.profile?.name != name })

        // Auto-import must not bring the deleted profile back.
        #expect(try freshImporter.autoLinkUnlinkedUsers(in: download).isEmpty)
        #expect(try freshImporter.importDeviceReadings(download).added == 0)
    }

    @Test func csvRowsWithoutProfileUseFallback() throws {
        let me = Profile(name: "Me")
        context.insert(me)
        let rows = try ReadingsCSV.decode("date,time,systolic,diastolic\n2026-11-01,08:00,118,76\n2026-11-01,20:00,124,79\n")
        let summary = try importer.importCSV(rows, fallbackProfile: me)
        #expect(summary.added == 2)
        #expect(try readings(of: me).allSatisfy(\.isManual))
    }

    @Test func pdfReportRenders() throws {
        let p = Profile(name: "Alex")
        context.insert(p)
        var rs: [Reading] = []
        for i in 0..<60 {
            let time = Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 43_200)
            let sys: Int = 110 + i % 30, dia: Int = 70 + i % 15, pulse: Int = 60 + i % 10
            rs.append(Reading(timestamp: time, systolic: sys, diastolic: dia, pulse: pulse, irregularHeartbeat: i % 17 == 0,
                              sourceName: "Manual", deviceID: p.manualDeviceID, deviceUser: nil, profile: p))
        }
        rs.forEach(context.insert)
        rs[0].hidden = true
        let data = PDFReport.render(profileName: p.name, period: Period(kind: .all), readings: rs,
                                    options: AnalysisOptions(groupWindowMinutes: 10))
        #expect(data.starts(with: Array("%PDF".utf8)))
        let pages = CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages
        #expect(pages == 3) // summary page, then 40 + 19 visible readings
        // The test host is sandboxed, so the sample goes into its container.
        if ProcessInfo.processInfo.environment["PDF_REPORT_SAMPLE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-report.pdf")
            try data.write(to: url)
            print("PDF sample: \(url.path)")
        }
    }
}

/// Talks to a real BPM25 from inside the sandboxed app (the test host), to
/// check the serial entitlement. Run with TEST_RUNNER_BPM25_HARDWARE_TEST=1.
struct BPM25HardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BPM25_HARDWARE_TEST"] != nil))
    func downloadsFromConnectedMonitor() async throws {
        let source = try #require(BPM25Source.connected().first, "no 067b:2303 bridge visible from the sandbox")
        let readings = try await source.fetchReadings { _ in }
        print("BPM25 hardware test: \(readings.count) readings: " + readings.map { "user \($0.deviceUser ?? 0) \($0.systolic)/\($0.diastolic) \($0.timestamp)" }.joined(separator: "; "))
        #expect(!readings.isEmpty)
    }
}

@MainActor
struct SchemaMigrationTests {
    /// Stores created before versioning used the plain model list; opening one
    /// with the versioned schema and migration plan must keep everything.
    @Test func opensStoreCreatedBeforeVersioning() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "legacy-\(UUID().uuidString).store")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let legacy = try ModelContainer(for: Profile.self, Reading.self, DeviceLink.self, DeletedReading.self,
                                            configurations: ModelConfiguration(url: url))
            let p = Profile(name: "Me")
            legacy.mainContext.insert(p)
            legacy.mainContext.insert(Reading(timestamp: Date(timeIntervalSince1970: 1_800_000_000), systolic: 123, diastolic: 75,
                                              pulse: 60, sourceName: "Veroval BPM25", deviceID: "veroval-bpm25", deviceUser: 1,
                                              hidden: true, profile: p))
            legacy.mainContext.insert(DeletedReading(key: "k"))
            try legacy.mainContext.save()
        }
        let versioned = try AppSchema.container(ModelConfiguration(schema: AppSchema.current, url: url))
        let readings = try versioned.mainContext.fetch(FetchDescriptor<Reading>())
        #expect(readings.count == 1)
        #expect(readings.first?.profile?.name == "Me" && readings.first?.hidden == true)
        #expect(try versioned.mainContext.fetch(FetchDescriptor<DeletedReading>()).count == 1)
    }

    /// A store written by version 1 (as shipped in 0.1) opens as version 2 with its data.
    @Test func migratesVersion1StoreToVersion2() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "v1-\(UUID().uuidString).store")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let v1 = try ModelContainer(for: Schema(versionedSchema: SchemaV1.self),
                                        configurations: ModelConfiguration(schema: Schema(versionedSchema: SchemaV1.self), url: url))
            let p = Profile(name: "Me")
            v1.mainContext.insert(p)
            v1.mainContext.insert(Reading(timestamp: Date(timeIntervalSince1970: 1_800_000_000), systolic: 128, diastolic: 84,
                                          pulse: 71, sourceName: "Manual", deviceID: p.manualDeviceID, deviceUser: nil, profile: p))
            try v1.mainContext.save()
        }
        let v2 = try AppSchema.container(ModelConfiguration(schema: AppSchema.current, url: url))
        let context = v2.mainContext
        let profile = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        #expect(profile.readings.count == 1)
        context.insert(MeasurementWeek(profileID: profile.uuid, start: Date(), morningMinutes: 420, eveningMinutes: 1260,
                                       remindersEnabled: false))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<MeasurementWeek>()).count == 1)
    }

    @Test func snapshotIsTakenOncePerVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appending(path: "default.store")
        try Data("db".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        let folder = dir.appending(path: "Store Snapshots")

        StoreSnapshot.takeIfNeeded(store: store, folder: folder, version: "0.1-1")
        try Data("changed".utf8).write(to: store)
        StoreSnapshot.takeIfNeeded(store: store, folder: folder, version: "0.1-1") // same version: untouched
        let snap = folder.appending(path: "before 0.1-1")
        #expect(try String(contentsOf: snap.appending(path: "default.store"), encoding: .utf8) == "db")
        #expect(FileManager.default.fileExists(atPath: snap.appending(path: "default.store-wal").path))

        for v in ["0.2-1", "0.3-1", "0.4-1"] {
            StoreSnapshot.takeIfNeeded(store: store, folder: folder, version: v)
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == StoreSnapshot.keep)
    }
}
