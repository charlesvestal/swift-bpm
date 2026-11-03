import BPMKit
@preconcurrency import EventKit
import Foundation
import SwiftData
import UserNotifications

/// Reminders for measurement-week sessions, as Apple Reminders (in a "Blood
/// Pressure" list, on every device) or as notifications on this Mac. A
/// session's reminder is ticked off or withdrawn once it has its readings.
enum WeekReminders {
    static let listName = "Blood Pressure"

    enum ReminderError: LocalizedError {
        case notAllowed(String)

        var errorDescription: String? {
            switch self {
            case let .notAllowed(what):
                "Blood Pressure isn't allowed to use \(what). Allow it in System Settings › Privacy & Security, then choose the reminders again."
            }
        }
    }

    /// One session's reminder, whatever the style.
    struct Item: Equatable {
        var day: Int
        var session: HomeSession
        var due: Date
        var title: String
        var notes: String
        /// Identifies the session: the notification identifier, and the reminder's URL.
        var key: String
    }

    static func key(_ weekID: UUID, day: Int, session: HomeSession) -> String {
        "week.\(weekID.uuidString).\(day).\(session.rawValue)"
    }

    static func url(forKey key: String) -> URL { URL(string: "bptracker://\(key)")! }

    /// Reminders for the week's sessions still ahead of `now`.
    static func items(for week: MeasurementWeek, profileName: String, now: Date = Date()) -> [Item] {
        week.plan.sessionTimes(morning: week.morningMinutes, evening: week.eveningMinutes)
            .filter { $0.date > now }
            .map { day, session, date in
                Item(day: day, session: session, due: date,
                     title: "\(session.title) blood pressure – day \(day + 1) of \(week.days)\(day == 0 && week.discardFirstDay ? " (practice)" : "")",
                     notes: "\(profileName): sit quietly for 5 minutes, arm supported at heart level, then take two readings a minute apart.",
                     key: key(week.uuid, day: day, session: session))
            }
    }

    // MARK: Scheduling

    /// Sets up the week's reminders in its style, replacing any earlier ones.
    static func schedule(_ week: MeasurementWeek, profileName: String, now: Date = Date()) async throws {
        await cancel(week)
        let items = items(for: week, profileName: profileName, now: now)
        switch week.reminderStyle {
        case .off:
            return
        case .notifications:
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                throw ReminderError.notAllowed("notifications")
            }
            for item in items {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.notes
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.due), repeats: false)
                try await center.add(UNNotificationRequest(identifier: item.key, content: content, trigger: trigger))
            }
        case .appleReminders:
            let store = try await remindersStore()
            let list = try reminderList(in: store)
            for item in items {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = item.title
                reminder.notes = item.notes
                reminder.url = url(forKey: item.key)
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.due)
                reminder.addAlarm(EKAlarm(absoluteDate: item.due))
                try store.save(reminder, commit: false)
            }
            try store.commit()
        }
    }

    /// Removes the week's reminders of both kinds.
    static func cancel(_ week: MeasurementWeek) async {
        let keys = (0..<week.days).flatMap { day in HomeSession.allCases.map { key(week.uuid, day: day, session: $0) } }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: keys)
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let store = EKEventStore()
        let prefix = "bptracker://week.\(week.uuid.uuidString)."
        for reminder in await reminders(in: store) where reminder.url?.absoluteString.hasPrefix(prefix) == true {
            try? store.remove(reminder, commit: false)
        }
        try? store.commit()
    }

    /// Ticks off (or withdraws) reminders of sessions that now have their readings.
    static func markCompleted(in context: ModelContext) async {
        guard let weeks = try? context.fetch(FetchDescriptor<MeasurementWeek>()) else { return }
        let profiles = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        var done: Set<String> = []
        for week in weeks where week.reminderStyle != .off {
            guard let profile = profiles.first(where: { $0.uuid == week.profileID }) else { continue }
            let result = HomeMonitoringResult(points: profile.readings.filter { !$0.hidden }.map(\.point), plan: week.plan)
            for day in result.days {
                for session in HomeSession.allCases where day.isComplete(session) {
                    done.insert(key(week.uuid, day: day.index, session: session))
                }
            }
        }
        guard !done.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(done))
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let store = EKEventStore()
        var changed = false
        for reminder in await reminders(in: store, incompleteOnly: true) {
            guard let key = reminder.url?.absoluteString.replacingOccurrences(of: "bptracker://", with: ""),
                  done.contains(key) else { continue }
            reminder.isCompleted = true
            try? store.save(reminder, commit: false)
            changed = true
        }
        if changed { try? store.commit() }
    }

    // MARK: EventKit

    private static func remindersStore() async throws -> EKEventStore {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { throw ReminderError.notAllowed("Reminders") }
        return store
    }

    /// The "Blood Pressure" list, created in the default account if missing.
    private static func reminderList(in store: EKEventStore) throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listName }) { return existing }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listName
        list.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV } ?? store.sources.first { $0.sourceType == .local }
        list.cgColor = CGColor(red: 0.85, green: 0.15, blue: 0.27, alpha: 1)
        try store.saveCalendar(list, commit: true)
        return list
    }

    /// The app's reminders in the "Blood Pressure" list.
    private static func reminders(in store: EKEventStore, incompleteOnly: Bool = false) async -> [EKReminder] {
        let lists = store.calendars(for: .reminder).filter { $0.title == listName }
        guard !lists.isEmpty else { return [] }
        let predicate = incompleteOnly
            ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
            : store.predicateForReminders(in: lists)
        let found: Found = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: Found(reminders: $0 ?? [])) }
        }
        return found.reminders.filter { $0.url?.scheme == "bptracker" }
    }

    /// Carries fetched reminders out of EventKit's callback; they are only used on the main actor afterwards.
    private struct Found: @unchecked Sendable {
        var reminders: [EKReminder]
    }
}
