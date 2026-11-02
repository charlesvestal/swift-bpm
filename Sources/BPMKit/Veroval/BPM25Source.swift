import Foundation

public enum BPM25Error: LocalizedError {
    case noDevice
    case noResponse
    case invalidResponse([String])

    public var errorDescription: String? {
        switch self {
        case .noDevice:
            "No Veroval BPM25 found. Connect the USB cable and check the monitor is in PC mode."
        case .noResponse:
            "The monitor did not answer. Check it is switched on and in PC mode."
        case let .invalidResponse(issues):
            "The monitor's reply could not be read: " + issues.joined(separator: "; ")
        }
    }
}

/// Hartmann Veroval BPM25 over its PL2303 USB-serial bridge.
public struct BPM25Source: ReadingSource {
    /// The PL2303 has no serial number, so all BPM25 units share one identity.
    public static let deviceID = "veroval-bpm25"
    public static let deviceName = "Veroval BPM25"

    public let portPath: String
    public var name: String { "\(Self.deviceName) (USB)" }

    public init(portPath: String) {
        self.portPath = portPath
    }

    /// One source per connected 067b:2303 bridge.
    public static func connected() -> [BPM25Source] {
        USBSerialDevices.matching(vendorID: BPM25.usbVendorID, productID: BPM25.usbProductID)
            .map { BPM25Source(portPath: $0.path) }
    }

    public func fetchReadings(progress: @escaping @Sendable (String) -> Void) async throws -> [DeviceReading] {
        let path = portPath
        let bytes = try await Task.detached {
            try Self.download(portPath: path, progress: progress)
        }.value
        let response = BPM25.parse(bytes)
        guard response.isValid else { throw BPM25Error.invalidResponse(response.issues.isEmpty ? ["checksum mismatch"] : response.issues) }
        return Self.readings(from: response)
    }

    /// Records with an impossible date are dropped; everything else in a
    /// checksummed reply is kept.
    public static func readings(from response: BPM25.Response, timeZone: TimeZone = .current) -> [DeviceReading] {
        response.records.compactMap { r in
            guard let date = r.date(in: timeZone) else { return nil }
            return DeviceReading(timestamp: date, systolic: r.systolic, diastolic: r.diastolic, pulse: r.pulse,
                                 irregularHeartbeat: r.irregularHeartbeat, deviceID: deviceID,
                                 deviceName: deviceName, deviceUser: r.user)
        }
    }

    static func download(portPath: String, progress: @Sendable (String) -> Void) throws -> [UInt8] {
        let port = SerialPort(path: portPath)
        progress("Opening \(portPath)…")
        try port.open(baudRate: BPM25.baudRate)
        defer { port.close() }

        progress("Reading memory…")
        try port.write(BPM25.requestReadings)
        let bytes = try port.read(firstByteTimeout: .seconds(3), idleTimeout: .milliseconds(500)).flatMap(\.bytes)
        // Ends the session; the device does not answer it.
        try? port.write(BPM25.requestClose)
        guard !bytes.isEmpty else { throw BPM25Error.noResponse }
        return bytes
    }
}
