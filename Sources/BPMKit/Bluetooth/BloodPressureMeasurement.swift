import Foundation

/// Decoder for the Bluetooth SIG Blood Pressure Measurement characteristic
/// (0x2A35) of the Blood Pressure Service (0x1810).
///
/// Layout: flags (1 byte), systolic / diastolic / mean arterial pressure
/// (SFLOAT each), then, as the flags say, a 7-byte timestamp, pulse rate
/// (SFLOAT), user ID (1 byte) and measurement status (16 bits). All values are
/// little-endian.
public struct BloodPressureMeasurement: Equatable, Sendable {
    public struct Timestamp: Equatable, Sendable {
        public var year, month, day, hour, minute, second: Int
    }

    /// Pressures in mmHg; kPa values are converted.
    public var systolic: Double
    public var diastolic: Double
    public var meanArterialPressure: Double?
    public var timestamp: Timestamp?
    public var pulseRate: Double?
    /// 0xFF ("unknown user") is reported as nil.
    public var userID: Int?
    public var bodyMovement = false
    public var cuffTooLoose = false
    public var irregularPulse = false
    public var improperPosition = false

    public enum DecodeError: Error, Equatable {
        case truncated
        case missingPressure
    }

    static let mmHgPerKPa = 7.500615

    public init(bytes: [UInt8]) throws {
        var reader = Reader(bytes: bytes)
        let flags = try reader.u8()
        let kPa = flags & 0x01 != 0
        let scale = kPa ? Self.mmHgPerKPa : 1

        guard let sys = try reader.sfloat(), let dia = try reader.sfloat() else { throw DecodeError.missingPressure }
        systolic = sys * scale
        diastolic = dia * scale
        meanArterialPressure = try reader.sfloat().map { $0 * scale }

        if flags & 0x02 != 0 {
            timestamp = Timestamp(year: Int(try reader.u16()), month: Int(try reader.u8()), day: Int(try reader.u8()),
                                  hour: Int(try reader.u8()), minute: Int(try reader.u8()), second: Int(try reader.u8()))
        }
        if flags & 0x04 != 0 {
            pulseRate = try reader.sfloat()
        }
        if flags & 0x08 != 0 {
            let id = try reader.u8()
            userID = id == 0xFF ? nil : Int(id)
        }
        if flags & 0x10 != 0 {
            let status = try reader.u16()
            bodyMovement = status & 0x0001 != 0
            cuffTooLoose = status & 0x0002 != 0
            irregularPulse = status & 0x0004 != 0
            improperPosition = status & 0x0020 != 0
        }
    }

    /// The device timestamp in `timeZone`, or nil if absent or unknown (year 0).
    public func date(in timeZone: TimeZone = .current) -> Date? {
        guard let t = timestamp, t.year != 0, t.month != 0, t.day != 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: t.year, month: t.month, day: t.day, hour: t.hour, minute: t.minute, second: t.second)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// IEEE 11073-20601 16-bit float: 4-bit signed exponent, 12-bit signed
    /// mantissa. Returns nil for NaN, NRes and the reserved/infinity values.
    public static func sfloat(_ raw: UInt16) -> Double? {
        switch raw {
        case 0x07FF, 0x0800, 0x07FE, 0x0802, 0x0801: return nil
        default: break
        }
        var mantissa = Int(raw & 0x0FFF)
        if mantissa >= 0x0800 { mantissa -= 0x1000 }
        var exponent = Int(raw >> 12)
        if exponent >= 0x8 { exponent -= 0x10 }
        return Double(mantissa) * pow(10, Double(exponent))
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodeError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 {
            let lo = try u8(), hi = try u8()
            return UInt16(hi) << 8 | UInt16(lo)
        }

        mutating func sfloat() throws -> Double? {
            BloodPressureMeasurement.sfloat(try u16())
        }
    }
}
