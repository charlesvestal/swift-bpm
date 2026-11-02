import Foundation

/// Wire protocol of the Hartmann Veroval BPM25 (wrist) monitor, reached through
/// its Prolific PL2303 USB-serial bridge.
///
/// Protocol summary (community documentation, checked against a BPM25; see README):
/// - Line settings: 19200 baud, 8 data bits, no parity, 1 stop bit, no flow control.
/// - Request `A5 F9 01 01 FB` makes the device stream its stored readings.
/// - The reply holds both users' readings (user 1 first, then user 2).
/// - Request `A6 F9 01 01 FB` ends the session; the device does not reply.
/// - Response: header `A6 F9 <count>`, then `count` fixed 14-byte records, then
///   a checksum byte.
/// - Checksum (request and response): sum of every byte after the first and
///   before the checksum, modulo 256.
/// - Record layout, all integers big-endian:
///   `[0]` user/memory bank, `[1]` index (per user, newest = 1, so it shifts as
///   readings are added and cannot identify a reading), `[2…3]` systolic, `[4…5]` diastolic,
///   `[6]` flags (bit 0 = irregular heartbeat), `[7]` pulse, `[8]` month,
///   `[9]` day, `[10…11]` year, `[12]` hour, `[13]` minute.
public enum BPM25 {
    public static let usbVendorID = 0x067B
    public static let usbProductID = 0x2303
    public static let baudRate = 19200

    public static let requestReadings: [UInt8] = [0xA5, 0xF9, 0x01, 0x01, 0xFB]
    public static let requestClose: [UInt8] = [0xA6, 0xF9, 0x01, 0x01, 0xFB]

    public static let responseMarker: [UInt8] = [0xA6, 0xF9]
    public static let headerLength = 3
    public static let recordLength = 14
    public static let trailerLength = 1

    public struct Record: Equatable, Sendable {
        public var user: Int
        public var index: Int
        public var systolic: Int
        public var diastolic: Int
        public var pulse: Int
        public var flags: UInt8
        public var year: Int
        public var month: Int
        public var day: Int
        public var hour: Int
        public var minute: Int
        public var raw: [UInt8]

        public var irregularHeartbeat: Bool { flags & 0x01 != 0 }

        /// The device clock has no time zone; interpret it in `timeZone`.
        public func date(in timeZone: TimeZone = .current) -> Date? {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard components.isValidDate(in: calendar) else { return nil }
            return calendar.date(from: components)
        }

        /// Reasons this record looks implausible; empty when it looks sane.
        public var plausibilityIssues: [String] {
            var issues: [String] = []
            if !(40...300).contains(systolic) { issues.append("systolic out of range") }
            if !(20...250).contains(diastolic) { issues.append("diastolic out of range") }
            if systolic <= diastolic { issues.append("systolic <= diastolic") }
            if !(20...250).contains(pulse) { issues.append("pulse out of range") }
            if date(in: TimeZone(identifier: "UTC")!) == nil { issues.append("invalid date") }
            return issues
        }

        public init(bytes: ArraySlice<UInt8>) {
            precondition(bytes.count == BPM25.recordLength)
            let b = Array(bytes)
            func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
            user = Int(b[0])
            index = Int(b[1])
            systolic = be16(2)
            diastolic = be16(4)
            flags = b[6]
            pulse = Int(b[7])
            month = Int(b[8])
            day = Int(b[9])
            year = be16(10)
            hour = Int(b[12])
            minute = Int(b[13])
            raw = b
        }
    }

    public struct Response: Sendable {
        public var bytes: [UInt8]
        public var header: [UInt8]
        public var declaredCount: Int?
        public var records: [Record]
        /// Bytes after the declared records (expected: the checksum byte).
        public var trailer: [UInt8]
        public var issues: [String]

        /// Whether the final byte matches `BPM25.checksum` of the bytes before it.
        public var checksumValid: Bool {
            guard bytes.count >= 2, let last = bytes.last else { return false }
            return BPM25.checksum(bytes.dropLast()) == last
        }

        /// A complete, well-formed response whose records can be trusted.
        public var isValid: Bool { issues.isEmpty && checksumValid }

        public var expectedLength: Int? {
            declaredCount.map { BPM25.headerLength + $0 * BPM25.recordLength + BPM25.trailerLength }
        }
    }

    /// Sum of all bytes after the first, modulo 256.
    public static func checksum(_ frame: some Collection<UInt8>) -> UInt8 {
        frame.dropFirst().reduce(0, &+)
    }

    /// Splits a raw response into header, records and trailer. Tolerant of
    /// truncated or oversized input: it parses what is there and lists issues.
    public static func parse(_ bytes: [UInt8]) -> Response {
        var response = Response(bytes: bytes, header: [], declaredCount: nil, records: [], trailer: [], issues: [])
        guard bytes.count >= headerLength else {
            response.issues.append("response shorter than the \(headerLength)-byte header (\(bytes.count) bytes)")
            return response
        }
        response.header = Array(bytes[0..<headerLength])
        if Array(response.header.prefix(responseMarker.count)) != responseMarker {
            response.issues.append("header does not start with \(responseMarker.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        let count = Int(bytes[headerLength - 1])
        response.declaredCount = count

        var offset = headerLength
        while response.records.count < count, offset + recordLength <= bytes.count {
            response.records.append(Record(bytes: bytes[offset..<offset + recordLength]))
            offset += recordLength
        }
        response.trailer = Array(bytes[offset...])

        if response.records.count < count {
            response.issues.append("header declares \(count) records but only \(response.records.count) are complete")
        }
        if let expected = response.expectedLength, expected != bytes.count {
            response.issues.append("expected \(expected) bytes for \(count) records, got \(bytes.count)")
        } else if !response.checksumValid {
            response.issues.append("checksum mismatch")
        }
        return response
    }
}
