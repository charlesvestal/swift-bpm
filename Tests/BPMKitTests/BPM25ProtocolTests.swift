import BPMKit
import Foundation
import Testing

struct BPM25ProtocolTests {
    /// Layout of a BPM25 capture with one stored reading (probe run 2026-11-02); values replaced.
    static let capturedOneReading: [UInt8] = [
        0xA6, 0xF9, 0x01,
        0x01, 0x01, 0x00, 0x80, 0x00, 0x54, 0x01, 0x47, 0x0A, 0x0E, 0x07, 0xEA, 0x08, 0x0C,
        0x35,
    ]

    /// Layout of a capture after adding a user-1 and a user-2 reading; values replaced.
    /// Both users arrive in one A5 reply; index is per user, newest = 1.
    static let capturedTwoUsers: [UInt8] = [
        0xA6, 0xF9, 0x03,
        0x01, 0x01, 0x00, 0x84, 0x00, 0x56, 0x00, 0x4A, 0x0A, 0x0E, 0x07, 0xEA, 0x13, 0x2D,
        0x01, 0x02, 0x00, 0x80, 0x00, 0x54, 0x01, 0x47, 0x0A, 0x0E, 0x07, 0xEA, 0x08, 0x0C,
        0x02, 0x01, 0x00, 0x77, 0x00, 0x4D, 0x00, 0x42, 0x0A, 0x0E, 0x07, 0xEA, 0x13, 0x34,
        0x00,
    ]

    /// Wraps records in a header and checksum, like the device does.
    static func frame(_ records: [UInt8]...) -> [UInt8] {
        let body = BPM25.responseMarker + [UInt8(records.count)] + records.flatMap { $0 }
        return body + [BPM25.checksum(body)]
    }

    @Test func requestsCarryValidChecksum() {
        #expect(BPM25.checksum(BPM25.requestReadings.dropLast()) == BPM25.requestReadings.last)
        #expect(BPM25.checksum(BPM25.requestClose.dropLast()) == BPM25.requestClose.last)
    }

    @Test func parsesDeviceCapture() throws {
        let response = BPM25.parse(Self.capturedOneReading)
        #expect(response.isValid)
        #expect(response.declaredCount == 1)
        let r = try #require(response.records.first)
        #expect([r.user, r.index, r.systolic, r.diastolic, r.pulse] == [Int]([1, 1, 128, 84, 71]))
        #expect(r.flags == 0x01)
        #expect([r.year, r.month, r.day, r.hour, r.minute] == [Int]([2026, 10, 14, 8, 12]))
        #expect(r.plausibilityIssues.isEmpty)
    }

    @Test func parsesBothUsersFromOneReply() {
        let response = BPM25.parse(Self.capturedTwoUsers)
        #expect(response.isValid)
        #expect(response.records.map(\.user) == [1, 1, 2])
        #expect(response.records.map(\.index) == [1, 2, 1])
        #expect(response.records.map(\.irregularHeartbeat) == [false, true, false])
        // The 08:12 reading from the first capture, now renumbered to index 2.
        let earlier = BPM25.parse(Self.capturedOneReading).records[0]
        #expect(response.records[1].raw.dropFirst(2) == earlier.raw.dropFirst(2))
    }

    @Test func rejectsCorruptedChecksum() {
        var bytes = Self.capturedOneReading
        bytes[6] ^= 0x10
        let response = BPM25.parse(bytes)
        #expect(!response.checksumValid)
        #expect(response.issues == ["checksum mismatch"])
    }

    static func record(user: UInt8, index: UInt8, sys: Int, dia: Int, flags: UInt8, pulse: UInt8,
                       year: Int, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8) -> [UInt8] {
        [user, index, UInt8(sys >> 8), UInt8(sys & 0xFF), UInt8(dia >> 8), UInt8(dia & 0xFF), flags, pulse,
         month, day, UInt8(year >> 8), UInt8(year & 0xFF), hour, minute]
    }

    @Test func parsesDeclaredRecords() throws {
        let a = Self.record(user: 1, index: 1, sys: 128, dia: 84, flags: 0, pulse: 66, year: 2026, month: 10, day: 31, hour: 7, minute: 45)
        let b = Self.record(user: 2, index: 1, sys: 301, dia: 90, flags: 1, pulse: 72, year: 2026, month: 11, day: 1, hour: 21, minute: 5)
        let response = BPM25.parse(Self.frame(a, b))
        #expect(response.declaredCount == 2)
        #expect(response.records.count == 2)
        #expect(response.trailer.count == 1)
        #expect(response.isValid)

        let first = response.records[0]
        #expect(first.user == 1)
        #expect(first.systolic == 128)
        #expect(first.diastolic == 84)
        #expect(first.pulse == 66)
        #expect(!first.irregularHeartbeat)
        #expect(first.plausibilityIssues.isEmpty)

        let utc = TimeZone(identifier: "UTC")!
        #expect(first.date(in: utc) == ISO8601DateFormatter().date(from: "2026-10-31T07:45:00Z"))

        let second = response.records[1]
        #expect(second.systolic == 301) // 16-bit value
        #expect(second.irregularHeartbeat)
        #expect(second.plausibilityIssues == ["systolic out of range"])
    }

    @Test func reportsTruncatedFrame() {
        let a = Self.record(user: 1, index: 1, sys: 120, dia: 80, flags: 0, pulse: 60, year: 2026, month: 1, day: 2, hour: 3, minute: 4)
        let response = BPM25.parse(BPM25.responseMarker + [0x03] + a + a.prefix(5))
        #expect(response.records.count == 1)
        #expect(response.trailer.count == 5)
        #expect(response.issues.count == 2)
    }

    @Test func handlesShortInput() {
        let response = BPM25.parse([0x01])
        #expect(response.declaredCount == nil)
        #expect(response.records.isEmpty)
        #expect(!response.issues.isEmpty)
    }

    @Test func invalidDateIsFlagged() {
        let bad = Self.record(user: 1, index: 1, sys: 120, dia: 80, flags: 0, pulse: 60, year: 2026, month: 13, day: 40, hour: 25, minute: 0)
        let response = BPM25.parse(Self.frame(bad))
        #expect(response.records[0].date() == nil)
        #expect(response.records[0].plausibilityIssues.contains("invalid date"))
    }
}
