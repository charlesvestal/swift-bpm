import Foundation

/// One measurement as delivered by a reading source, before it is stored.
public struct DeviceReading: Sendable, Hashable {
    public var timestamp: Date
    public var systolic: Int
    public var diastolic: Int
    public var pulse: Int?
    public var irregularHeartbeat: Bool
    public var bodyMovement: Bool
    /// Stable identity of the device that produced the reading.
    public var deviceID: String
    public var deviceName: String
    /// The device's own user/memory slot, if it has one.
    public var deviceUser: Int?

    public init(timestamp: Date, systolic: Int, diastolic: Int, pulse: Int?,
                irregularHeartbeat: Bool = false, bodyMovement: Bool = false,
                deviceID: String, deviceName: String, deviceUser: Int?) {
        self.timestamp = timestamp
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.irregularHeartbeat = irregularHeartbeat
        self.bodyMovement = bodyMovement
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceUser = deviceUser
    }

    public var key: String { ReadingKey.make(deviceID: deviceID, deviceUser: deviceUser, timestamp: timestamp) }
}

/// Something that can deliver blood-pressure readings: a USB monitor, a
/// Bluetooth monitor, a file.
public protocol ReadingSource: Sendable {
    var name: String { get }
    func fetchReadings(progress: @escaping @Sendable (String) -> Void) async throws -> [DeviceReading]
}

/// Deduplication key: device, device user and timestamp to the minute.
/// Device clocks (the BPM25 included) only record minutes, so a reading that
/// is downloaded again lands on the same key.
public enum ReadingKey {
    public static func make(deviceID: String, deviceUser: Int?, timestamp: Date) -> String {
        let minute = Int((timestamp.timeIntervalSince1970 / 60).rounded(.down))
        return "\(deviceID)|\(deviceUser ?? 0)|\(minute)"
    }
}
