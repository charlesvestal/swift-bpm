import BPMKit
import Foundation
import SwiftData

// The app's data model, versioned so future changes migrate explicitly.
//
// To change the model: copy `SchemaV1` to `SchemaV2` in a new file with the
// changes, point the typealiases below at `SchemaV2`, append `SchemaV2` to
// `AppMigrationPlan.schemas`, and add a `MigrationStage` from V1 to V2
// (`.lightweight` for added properties with defaults, `.custom` otherwise).
// Keep `SchemaV1` unchanged: it describes stores already on disk.

typealias Profile = SchemaV1.Profile
typealias Reading = SchemaV1.Reading
typealias DeviceLink = SchemaV1.DeviceLink
typealias DeletedReading = SchemaV1.DeletedReading

/// Version 1 matches the store as first shipped (before versioning, the
/// models were declared unversioned with these exact definitions).
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Profile.self, Reading.self, DeviceLink.self, DeletedReading.self] }
}

extension SchemaV1 {
    @Model
    final class Profile {
        var uuid: UUID
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \Reading.profile) var readings: [Reading] = []
        @Relationship(deleteRule: .cascade, inverse: \DeviceLink.profile) var deviceLinks: [DeviceLink] = []

        init(name: String) {
            uuid = UUID()
            self.name = name
            createdAt = Date()
        }

        /// Device ID for readings entered by hand (or imported without one) for this profile.
        var manualDeviceID: String { "manual:\(uuid.uuidString)" }
    }

    @Model
    final class Reading {
        /// Device + device user + minute; see `ReadingKey`.
        @Attribute(.unique) var key: String
        var timestamp: Date
        var systolic: Int
        var diastolic: Int
        var pulse: Int?
        var irregularHeartbeat: Bool
        var bodyMovement: Bool
        /// Human-readable origin, such as "Veroval BPM25" or "Manual".
        var sourceName: String
        var deviceID: String
        var deviceUser: Int?
        var note: String
        var profile: Profile?
        /// Kept, but left out of charts, statistics and reports.
        var hidden: Bool = false
        /// Already written to the Apple Health hand-off folder (see HealthExporter).
        var sentToHealth: Bool = false

        init(timestamp: Date, systolic: Int, diastolic: Int, pulse: Int?, irregularHeartbeat: Bool = false,
             bodyMovement: Bool = false, sourceName: String, deviceID: String, deviceUser: Int?, note: String = "",
             hidden: Bool = false, profile: Profile?) {
            key = ReadingKey.make(deviceID: deviceID, deviceUser: deviceUser, timestamp: timestamp)
            self.timestamp = timestamp
            self.systolic = systolic
            self.diastolic = diastolic
            self.pulse = pulse
            self.irregularHeartbeat = irregularHeartbeat
            self.bodyMovement = bodyMovement
            self.sourceName = sourceName
            self.deviceID = deviceID
            self.deviceUser = deviceUser
            self.note = note
            self.hidden = hidden
            self.profile = profile
        }

        var point: BPPoint {
            BPPoint(timestamp: timestamp, systolic: Double(systolic), diastolic: Double(diastolic),
                    pulse: pulse.map(Double.init), irregularHeartbeat: irregularHeartbeat)
        }

        var meanArterialPressure: Int { Int(point.meanArterialPressure.rounded()) }
        var pulsePressure: Int { systolic - diastolic }

        var isManual: Bool { deviceID.hasPrefix("manual:") }
        func category(in guideline: BPGuideline) -> BPCategory {
            guideline.category(systolic: systolic, diastolic: diastolic)
        }

        func refreshKey() {
            key = ReadingKey.make(deviceID: deviceID, deviceUser: deviceUser, timestamp: timestamp)
        }
    }

    /// Which profile a device's user slot belongs to, or that it is ignored.
    @Model
    final class DeviceLink {
        var deviceID: String
        var deviceName: String
        /// 0 when the device does not report users.
        var deviceUser: Int
        var profile: Profile?
        /// Readings from this device user are skipped on import.
        var ignored: Bool = false

        init(deviceID: String, deviceName: String, deviceUser: Int, profile: Profile?, ignored: Bool = false) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.deviceUser = deviceUser
            self.profile = profile
            self.ignored = ignored
        }

        /// Settled: either filed under a profile or deliberately ignored.
        var isResolved: Bool { ignored || profile != nil }

        var title: String { deviceUser == 0 ? deviceName : "\(deviceName) · user \(deviceUser)" }
    }

    /// Key of a reading the user deleted, so downloading the monitor's memory
    /// again does not bring it back.
    @Model
    final class DeletedReading {
        @Attribute(.unique) var key: String
        var deletedAt: Date

        init(key: String) {
            self.key = key
            deletedAt = Date()
        }
    }}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum AppSchema {
    static let current = Schema(versionedSchema: SchemaV1.self)

    /// Opens a container with the migration plan, for the app and for tests.
    static func container(_ configurations: ModelConfiguration...) throws -> ModelContainer {
        try ModelContainer(for: current, migrationPlan: AppMigrationPlan.self, configurations: configurations)
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try container(ModelConfiguration(schema: current, isStoredInMemoryOnly: true))
    }
}
