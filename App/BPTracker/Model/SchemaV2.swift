import BPMKit
import Foundation
import SwiftData

/// Version 2 adds measurement weeks. The other models are unchanged from V1,
/// so V2 reuses them; the migration only creates the new table.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SchemaV1.Profile.self, SchemaV1.Reading.self, SchemaV1.DeviceLink.self, SchemaV1.DeletedReading.self,
         MeasurementWeek.self]
    }
}

typealias MeasurementWeek = SchemaV2.MeasurementWeek

extension SchemaV2 {
    /// A home-monitoring week (see `HomeMonitoringPlan`) for one profile. The
    /// readings themselves are the profile's ordinary readings in that week.
    @Model
    final class MeasurementWeek {
        var uuid: UUID = UUID()
        /// `Profile.uuid`; a plain value so V1's Profile needs no new relationship.
        var profileID: UUID = UUID()
        var start: Date = Date()
        var days: Int = 7
        var discardFirstDay: Bool = true
        /// Minutes after midnight.
        var morningMinutes: Int = 7 * 60
        var eveningMinutes: Int = 21 * 60
        var remindersEnabled: Bool = true
        var createdAt: Date = Date()

        init(profileID: UUID, start: Date, morningMinutes: Int, eveningMinutes: Int, remindersEnabled: Bool) {
            self.profileID = profileID
            self.start = Calendar.current.startOfDay(for: start)
            self.morningMinutes = morningMinutes
            self.eveningMinutes = eveningMinutes
            self.remindersEnabled = remindersEnabled
        }

        var plan: HomeMonitoringPlan { HomeMonitoringPlan(start: start, days: days, discardFirstDay: discardFirstDay) }

        func isActive(now: Date = Date()) -> Bool { plan.contains(now) }
        func isFinished(now: Date = Date()) -> Bool { now >= plan.end() }
    }
}
