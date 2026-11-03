import BPMKit
import Foundation
import SwiftData
import UserNotifications

/// Morning and evening notifications for measurement weeks. Reminders for
/// sessions that already have their readings are withdrawn.
enum WeekReminders {
    static func identifier(_ week: MeasurementWeek, day: Int, session: HomeSession) -> String {
        "week.\(week.uuid.uuidString).\(day).\(session.rawValue)"
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces the week's pending reminders with one per future session.
    static func schedule(_ week: MeasurementWeek, profileName: String, now: Date = Date()) async {
        cancel(week)
        guard week.remindersEnabled, await requestAuthorization() else { return }
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        for (day, session, date) in week.plan.sessionTimes(morning: week.morningMinutes, evening: week.eveningMinutes)
        where date > now {
            let content = UNMutableNotificationContent()
            content.title = "\(session.title) blood pressure"
            content.body = "\(profileName), day \(day + 1) of \(week.days)\(day == 0 && week.discardFirstDay ? " (practice day)" : ""): "
                + "sit quietly for 5 minutes, then take two readings a minute apart."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier(week, day: day, session: session),
                                                        content: content, trigger: trigger))
        }
    }

    static func cancel(_ week: MeasurementWeek) {
        let ids = (0..<week.days).flatMap { day in HomeSession.allCases.map { identifier(week, day: day, session: $0) } }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Withdraws reminders for sessions of current weeks that already have their readings.
    static func withdrawCompleted(in context: ModelContext) {
        guard let weeks = try? context.fetch(FetchDescriptor<MeasurementWeek>()) else { return }
        let profiles = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        var done: [String] = []
        for week in weeks where !week.isFinished() {
            guard let profile = profiles.first(where: { $0.uuid == week.profileID }) else { continue }
            let result = HomeMonitoringResult(points: profile.readings.filter { !$0.hidden }.map(\.point), plan: week.plan)
            for day in result.days {
                for session in HomeSession.allCases where day.isComplete(session) {
                    done.append(identifier(week, day: day.index, session: session))
                }
            }
        }
        if !done.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: done) }
    }
}
