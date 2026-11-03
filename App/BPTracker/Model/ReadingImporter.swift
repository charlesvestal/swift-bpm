import BPMKit
import Foundation
import SwiftData

/// A device's user slot, as seen in downloaded readings.
struct DeviceUserRef: Hashable, Identifiable {
    var deviceID: String
    var deviceName: String
    var deviceUser: Int

    var id: String { "\(deviceID)|\(deviceUser)" }
    var title: String { deviceUser == 0 ? deviceName : "\(deviceName) · user \(deviceUser)" }
    var suggestedProfileName: String { deviceUser == 0 ? deviceName : "User \(deviceUser)" }

    init(deviceID: String, deviceName: String, deviceUser: Int?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceUser = deviceUser ?? 0
    }

    init(_ reading: DeviceReading) {
        self.init(deviceID: reading.deviceID, deviceName: reading.deviceName, deviceUser: reading.deviceUser)
    }
}

struct ImportSummary: Equatable {
    var added = 0
    var duplicates = 0
    /// Skipped because the user deleted them before.
    var previouslyDeleted = 0
    /// Skipped because their device user is set to "Don't import".
    var ignored = 0
    var createdProfiles: [String] = []

    var message: String {
        var parts = ["\(added) new reading\(added == 1 ? "" : "s")"]
        if duplicates > 0 { parts.append("\(duplicates) already imported") }
        if previouslyDeleted > 0 { parts.append("\(previouslyDeleted) previously deleted") }
        if ignored > 0 { parts.append("\(ignored) from ignored monitor users") }
        if !createdProfiles.isEmpty { parts.append("created profile\(createdProfiles.count == 1 ? "" : "s") \(createdProfiles.joined(separator: ", "))") }
        return parts.joined(separator: ", ") + "."
    }
}

/// Every path into the store (device download, CSV, manual entry) goes
/// through here so deduplication by `Reading.key` happens in one place.
struct ReadingImporter {
    let context: ModelContext

    func existingKeys() throws -> Set<String> {
        // Fetch whole objects: partially fetched models left in the context
        // crash a later cascade delete when undo is on ("A snapshot should
        // exist before creating a new snapshot for undo").
        Set(try context.fetch(FetchDescriptor<Reading>()).map(\.key))
    }

    func deletedKeys() throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<DeletedReading>()).map(\.key))
    }

    /// The link that settles where `ref`'s readings go, if there is one.
    func link(for ref: DeviceUserRef) throws -> DeviceLink? {
        let id = ref.deviceID, user = ref.deviceUser
        let descriptor = FetchDescriptor<DeviceLink>(predicate: #Predicate { $0.deviceID == id && $0.deviceUser == user })
        return try context.fetch(descriptor).first { $0.isResolved }
    }

    /// Device users in `readings` that are neither linked nor ignored.
    func unlinkedUsers(in readings: [DeviceReading]) throws -> [DeviceUserRef] {
        var seen: [DeviceUserRef] = []
        for ref in readings.map(DeviceUserRef.init) where !seen.contains(ref) {
            if try link(for: ref) == nil { seen.append(ref) }
        }
        return seen.sorted { ($0.deviceName, $0.deviceUser) < ($1.deviceName, $1.deviceUser) }
    }

    /// Files `ref`'s readings under `profile`, or ignores them when nil.
    @discardableResult
    func linkDeviceUser(_ ref: DeviceUserRef, to profile: Profile?) throws -> DeviceLink {
        if let existing = try link(for: ref) {
            existing.profile = profile
            existing.ignored = profile == nil
            return existing
        }
        let link = DeviceLink(deviceID: ref.deviceID, deviceName: ref.deviceName, deviceUser: ref.deviceUser,
                              profile: profile, ignored: profile == nil)
        context.insert(link)
        return link
    }

    /// Links every unlinked device user in `readings` without asking: first to
    /// profiles that have no device yet (oldest first), then to new profiles.
    /// Returns the names of profiles it created.
    func autoLinkUnlinkedUsers(in readings: [DeviceReading]) throws -> [String] {
        let unlinked = try unlinkedUsers(in: readings)
        guard !unlinked.isEmpty else { return [] }
        var unclaimed = try context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.deviceLinks.isEmpty }
        var created: [String] = []
        for ref in unlinked {
            if !unclaimed.isEmpty {
                try linkDeviceUser(ref, to: unclaimed.removeFirst())
            } else {
                let profile = Profile(name: ref.suggestedProfileName)
                context.insert(profile)
                try linkDeviceUser(ref, to: profile)
                created.append(profile.name)
            }
        }
        return created
    }

    /// Stores downloaded readings in the profiles their device users are
    /// linked to. Readings from ignored or unlinked device users are skipped,
    /// so link them first (see `unlinkedUsers`), as are readings deleted before.
    func importDeviceReadings(_ readings: [DeviceReading]) throws -> ImportSummary {
        var keys = try existingKeys()
        let deleted = try deletedKeys()
        var links: [DeviceUserRef: DeviceLink?] = [:]
        var summary = ImportSummary()
        for reading in readings {
            let ref = DeviceUserRef(reading)
            if links[ref] == nil { links[ref] = try link(for: ref) }
            guard let link = links[ref] ?? nil else { continue }
            if link.ignored {
                summary.ignored += 1
                continue
            }
            if deleted.contains(reading.key) {
                summary.previouslyDeleted += 1
                continue
            }
            guard keys.insert(reading.key).inserted else {
                summary.duplicates += 1
                continue
            }
            guard let profile = link.profile else { continue }
            context.insert(Reading(timestamp: reading.timestamp, systolic: reading.systolic, diastolic: reading.diastolic,
                                   pulse: reading.pulse, irregularHeartbeat: reading.irregularHeartbeat,
                                   bodyMovement: reading.bodyMovement, sourceName: reading.deviceName,
                                   deviceID: reading.deviceID, deviceUser: reading.deviceUser, profile: profile))
            summary.added += 1
        }
        try context.save()
        return summary
    }

    /// Rows name their profile; unknown names become new profiles and rows
    /// without one go to `fallbackProfile`. Rows carrying a device ID keep it,
    /// so a later download from that device recognises them as duplicates.
    func importCSV(_ rows: [CSVReading], fallbackProfile: @autoclosure () -> Profile) throws -> ImportSummary {
        var keys = try existingKeys()
        let deleted = try deletedKeys()
        var byName: [String: Profile] = [:]
        for profile in try context.fetch(FetchDescriptor<Profile>()) {
            byName[profile.name.lowercased()] = profile
        }
        var fallback: Profile?
        var summary = ImportSummary()

        for row in rows {
            let profile: Profile
            if let name = row.profile?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                if let existing = byName[name.lowercased()] {
                    profile = existing
                } else {
                    profile = Profile(name: name)
                    context.insert(profile)
                    byName[name.lowercased()] = profile
                    summary.createdProfiles.append(name)
                }
            } else {
                if fallback == nil { fallback = fallbackProfile() }
                profile = fallback!
            }

            let deviceID = row.deviceID ?? profile.manualDeviceID
            let key = ReadingKey.make(deviceID: deviceID, deviceUser: row.deviceUser, timestamp: row.timestamp)
            if deleted.contains(key) {
                summary.previouslyDeleted += 1
                continue
            }
            guard keys.insert(key).inserted else {
                summary.duplicates += 1
                continue
            }
            let isDevice = row.deviceID.map { !$0.hasPrefix("manual:") } ?? false
            if isDevice {
                let ref = DeviceUserRef(deviceID: deviceID, deviceName: row.source ?? deviceID, deviceUser: row.deviceUser)
                if try link(for: ref) == nil { try linkDeviceUser(ref, to: profile) }
            }
            context.insert(Reading(timestamp: row.timestamp, systolic: row.systolic, diastolic: row.diastolic,
                                   pulse: row.pulse, irregularHeartbeat: row.irregularHeartbeat,
                                   bodyMovement: row.bodyMovement, sourceName: row.source ?? "CSV import",
                                   deviceID: deviceID, deviceUser: row.deviceUser, note: row.note ?? "",
                                   hidden: row.hidden, profile: profile))
            summary.added += 1
        }
        try context.save()
        return summary
    }

    /// Deletes readings and remembers their keys so a later download or CSV
    /// import does not bring them back.
    func delete(_ readings: [Reading]) throws {
        let deleted = try deletedKeys()
        for reading in readings {
            if !deleted.contains(reading.key) { context.insert(DeletedReading(key: reading.key)) }
            context.delete(reading)
        }
        try context.save()
    }

    /// A reading entered again by hand should not stay blocked from import.
    func clearDeletedMarker(for key: String) throws {
        try context.delete(model: DeletedReading.self, where: #Predicate { $0.key == key })
    }

    /// Deletes a profile and its readings. Its monitor users are switched to
    /// "Don't import" rather than forgotten, so auto-import does not recreate
    /// the profile on the next download.
    ///
    /// Readings are deleted one by one instead of through the cascade rule:
    /// a cascade over readings not yet loaded into the context crashes
    /// SwiftData when undo is on.
    func deleteProfile(_ profile: Profile) throws {
        for link in profile.deviceLinks {
            link.profile = nil
            link.ignored = true
        }
        for reading in profile.readings {
            _ = reading.key // load it before deleting
            context.delete(reading)
        }
        context.delete(profile)
        try context.save()
    }

    /// Lets previously deleted readings be imported again.
    func forgetDeletedReadings() throws {
        try context.delete(model: DeletedReading.self)
        try context.save()
    }

    /// Stops importing a device user. Readings already imported stay where they are.
    func ignore(_ link: DeviceLink) throws {
        link.profile = nil
        link.ignored = true
        try context.save()
    }

    /// Points a device user at another profile and moves the readings that
    /// were filed under the old one. Readings moved by hand stay put.
    func relink(_ link: DeviceLink, to profile: Profile) throws {
        link.ignored = false
        let oldProfile = link.profile
        guard let oldProfile else {
            link.profile = profile
            return try context.save()
        }
        let id = link.deviceID
        let user: Int? = link.deviceUser == 0 ? nil : link.deviceUser
        let readings = try context.fetch(FetchDescriptor<Reading>(predicate: #Predicate { $0.deviceID == id }))
        for reading in readings where reading.deviceUser == user && reading.profile == oldProfile {
            reading.profile = profile
        }
        link.profile = profile
        try context.save()
    }

    static func csvRows(for readings: [Reading]) -> [CSVReading] {
        readings.sorted { $0.timestamp < $1.timestamp }.map {
            CSVReading(timestamp: $0.timestamp, profile: $0.profile?.name, systolic: $0.systolic, diastolic: $0.diastolic,
                       pulse: $0.pulse, irregularHeartbeat: $0.irregularHeartbeat, bodyMovement: $0.bodyMovement,
                       source: $0.sourceName, deviceID: $0.deviceID, deviceUser: $0.deviceUser,
                       note: $0.note.isEmpty ? nil : $0.note, hidden: $0.hidden)
        }
    }
}
