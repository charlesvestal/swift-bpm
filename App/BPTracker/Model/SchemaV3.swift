import BPMKit
import Foundation
import SwiftData

/// Version 3 lets a measurement week use Apple Reminders instead of
/// notifications. Weeks from V2 keep notifications (the new property's default).
enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SchemaV1.Profile.self, SchemaV1.Reading.self, SchemaV1.DeviceLink.self, SchemaV1.DeletedReading.self,
         MeasurementWeek.self]
    }
}

typealias MeasurementWeek = SchemaV3.MeasurementWeek

/// How a measurement week reminds you.
enum ReminderStyle: String, CaseIterable, Identifiable {
    /// Items in a "Blood Pressure" list in Apple Reminders, on every device.
    case appleReminders
    /// Notifications on this Mac.
    case notifications
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleReminders: "Apple Reminders"
        case .notifications: "Notifications on this Mac"
        case .off: "Off"
        }
    }
}

extension SchemaV3 {
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
        /// With `remindersEnabled`: Apple Reminders rather than notifications. New in V3.
        var useAppleReminders: Bool = false
        var createdAt: Date = Date()

        init(profileID: UUID, start: Date, morningMinutes: Int, eveningMinutes: Int, reminderStyle: ReminderStyle) {
            self.profileID = profileID
            self.start = Calendar.current.startOfDay(for: start)
            self.morningMinutes = morningMinutes
            self.eveningMinutes = eveningMinutes
            self.reminderStyle = reminderStyle
        }

        var reminderStyle: ReminderStyle {
            get { !remindersEnabled ? .off : useAppleReminders ? .appleReminders : .notifications }
            set {
                remindersEnabled = newValue != .off
                useAppleReminders = newValue == .appleReminders
            }
        }

        var plan: HomeMonitoringPlan { HomeMonitoringPlan(start: start, days: days, discardFirstDay: discardFirstDay) }

        func isActive(now: Date = Date()) -> Bool { plan.contains(now) }
        func isFinished(now: Date = Date()) -> Bool { now >= plan.end() }
    }
}
