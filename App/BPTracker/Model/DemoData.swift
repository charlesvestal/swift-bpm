#if DEBUG
import Foundation
import SwiftData

/// Four months of made-up readings in a "Demo" profile, for trying out the
/// charts and statistics. Debug builds only; removing the profile removes it all.
///
/// Pattern: two readings a minute apart each morning and evening, mornings
/// higher, the first reading of a pair higher than the second, and pressure
/// easing after a medication change. Seeded, so every run looks the same.
enum DemoData {
    static let profileName = "Demo"

    static func profile(in context: ModelContext) throws -> Profile? {
        let name = profileName
        return try context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.name == name })).first
    }

    /// Adds the demo profile unless it already exists. Returns how many readings were added.
    @discardableResult
    static func insert(into context: ModelContext, days: Int = 120, now: Date = Date()) throws -> Int {
        guard try profile(in: context) == nil else { return 0 }
        let profile = Profile(name: profileName)
        context.insert(profile)

        var rng = SeededRandom(seed: 2026)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let medicationDay = days - 75
        var count = 0

        for day in 0..<days {
            guard rng.uniform() > 0.08 else { continue } // a missed day now and then
            let date = calendar.date(byAdding: .day, value: day - days + 1, to: today)!
            // Easing from about 142/92 to 128/82 over the weeks after the medication change.
            let progress = min(1, max(0, Double(day - medicationDay) / 40))
            let baseSystolic = 142 - 14 * progress
            let baseDiastolic = 92 - 10 * progress

            for (hour, minute, bump, pulseBump) in [(7, 0, 6.0, 4.0), (21, 0, -2.0, -3.0)] {
                if hour == 21, rng.uniform() < 0.15 { continue } // evening skipped
                let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
                    .addingTimeInterval(rng.uniform(-20, 25) * 60)
                guard start < now else { continue }
                let systolic = baseSystolic + bump + rng.normal(sd: 6)
                let diastolic = baseDiastolic + bump / 2 + rng.normal(sd: 4)
                let pulse = 68 + pulseBump + rng.normal(sd: 5)

                for second in 0..<2 {
                    let drop = second == 0 ? 0 : rng.uniform(1, 5) // the second reading tends to be lower
                    let reading = Reading(
                        timestamp: start.addingTimeInterval(Double(second) * 60),
                        systolic: Int((systolic - drop).rounded()),
                        diastolic: Int((diastolic - drop / 2).rounded()),
                        pulse: Int((pulse - drop / 2).rounded()),
                        irregularHeartbeat: rng.uniform() < 0.02,
                        sourceName: "Demo data", deviceID: profile.manualDeviceID, deviceUser: nil, profile: profile)
                    if day == medicationDay, hour == 7, second == 0 { reading.note = "Started medication" }
                    if second == 0, systolic > 150 { reading.note = "After coffee" }
                    context.insert(reading)
                    count += 1
                }
            }
        }

        // A bad reading that has been hidden rather than deleted.
        let outlier = Reading(timestamp: calendar.date(byAdding: .day, value: -10, to: today)!.addingTimeInterval(13 * 3600),
                              systolic: 188, diastolic: 104, pulse: 96, sourceName: "Demo data",
                              deviceID: profile.manualDeviceID, deviceUser: nil, note: "Cuff slipped", hidden: true, profile: profile)
        context.insert(outlier)
        try context.save()
        return count + 1
    }

    static func remove(from context: ModelContext) throws {
        guard let profile = try profile(in: context) else { return }
        try ReadingImporter(context: context).deleteProfile(profile)
    }
}

/// SplitMix64, so the demo data is the same on every run.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In 0..<1.
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * uniform() }

    /// Normally distributed with mean 0 (Box–Muller).
    mutating func normal(sd: Double) -> Double {
        let u1 = max(uniform(), .leastNonzeroMagnitude), u2 = uniform()
        return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
#endif
