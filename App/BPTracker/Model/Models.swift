import BPMKit
import Foundation
import SwiftData

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
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [Profile.self, Reading.self, DeviceLink.self, DeletedReading.self]
}
