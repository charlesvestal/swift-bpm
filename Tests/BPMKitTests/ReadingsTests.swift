@testable import BPMKit
import Foundation
import Testing

struct ReadingKeyTests {
    @Test func sameMinuteSameKey() {
        let a = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ReadingKey.make(deviceID: "d", deviceUser: 1, timestamp: a)
            == ReadingKey.make(deviceID: "d", deviceUser: 1, timestamp: a.addingTimeInterval(59)))
        #expect(ReadingKey.make(deviceID: "d", deviceUser: 1, timestamp: a)
            != ReadingKey.make(deviceID: "d", deviceUser: 1, timestamp: a.addingTimeInterval(60)))
    }

    @Test func userAndDeviceSeparateKeys() {
        let a = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ReadingKey.make(deviceID: "d", deviceUser: 1, timestamp: a) != ReadingKey.make(deviceID: "d", deviceUser: 2, timestamp: a))
        #expect(ReadingKey.make(deviceID: "d", deviceUser: 1, timestamp: a) != ReadingKey.make(deviceID: "e", deviceUser: 1, timestamp: a))
    }

    @Test func bpm25ReadingsKeepKeysAcrossDownloads() {
        // The 08:12 reading appears in both captures with a different index.
        let utc = TimeZone(identifier: "UTC")!
        let first = BPM25Source.readings(from: BPM25.parse(BPM25ProtocolTests.capturedOneReading), timeZone: utc)
        let second = BPM25Source.readings(from: BPM25.parse(BPM25ProtocolTests.capturedTwoUsers), timeZone: utc)
        #expect(second.count == 3)
        #expect(Set(second.map(\.key)).isSuperset(of: first.map(\.key)))
        #expect(second.map(\.deviceUser) == [1, 1, 2])
    }
}

struct BPCategoryTests {
    @Test(arguments: [
        (115, 75, BPCategory.normal), (125, 78, .elevated), (128, 82, .stage1), (135, 70, .stage1),
        (142, 85, .stage2), (120, 95, .stage2), (185, 100, .crisis), (150, 125, .crisis),
    ])
    func classifies(sys: Int, dia: Int, expected: BPCategory) {
        #expect(BPCategory(systolic: sys, diastolic: dia) == expected)
    }
}

struct ReadingsCSVTests {
    @Test func roundTrips() throws {
        let rows = [
            CSVReading(timestamp: Date(timeIntervalSince1970: 1_793_000_000), profile: "Alex, Sr.", systolic: 121, diastolic: 79,
                       pulse: 64, irregularHeartbeat: true, source: "BPM25", deviceID: "veroval-bpm25", deviceUser: 1,
                       note: "after \"coffee\"\r\nsecond line"),
            CSVReading(timestamp: Date(timeIntervalSince1970: 1_793_003_600), systolic: 130, diastolic: 85),
        ]
        let decoded = try ReadingsCSV.decode(ReadingsCSV.encode(rows))
        #expect(decoded == rows)
    }

    @Test func acceptsMinimalForeignFile() throws {
        let text = "\u{FEFF}Date,Time,Systolic,Diastolic,Pulse\n2026-10-14,08:12,128,84,71\n\n"
        let rows = try ReadingsCSV.decode(text, timeZone: TimeZone(identifier: "UTC")!)
        #expect(rows.count == 1)
        #expect(rows[0].timestamp == ISO8601DateFormatter().date(from: "2026-10-14T08:12:00Z"))
        #expect(rows[0].pulse == 71)
        #expect(rows[0].profile == nil)
    }

    @Test func reportsBadValuesWithLine() {
        let text = "timestamp,systolic,diastolic\n2026-10-14 08:12,abc,84\n"
        #expect(throws: ReadingsCSVError.badValue(line: 2, column: "systolic", value: "abc")) {
            try ReadingsCSV.decode(text)
        }
    }

    @Test func requiresPressureColumns() {
        #expect(throws: ReadingsCSVError.missingColumn("diastolic")) {
            try ReadingsCSV.decode("timestamp,systolic\n")
        }
    }
}

struct BloodPressureMeasurementTests {
    @Test func decodesFullMeasurement() throws {
        // flags: mmHg, timestamp, pulse, user ID, status
        let bytes: [UInt8] = [
            0x1E,
            0x7A, 0x00, 0x50, 0x00, 0x5E, 0x00, // 122 / 80 / 94
            0xEA, 0x07, 0x0A, 0x0E, 0x08, 0x0C, 0x1E, // 2026-10-14 08:12:30
            0x45, 0x00, // pulse 69
            0x02, // user 2
            0x05, 0x00, // body movement + irregular pulse
        ]
        let m = try BloodPressureMeasurement(bytes: bytes)
        #expect(m.systolic == 122)
        #expect(m.diastolic == 80)
        #expect(m.meanArterialPressure == 94)
        #expect(m.pulseRate == 69)
        #expect(m.userID == 2)
        #expect(m.bodyMovement && m.irregularPulse && !m.cuffTooLoose)
        #expect(m.date(in: TimeZone(identifier: "UTC")!) == ISO8601DateFormatter().date(from: "2026-10-14T08:12:30Z"))

        let reading = BluetoothBPSource.reading(from: m, receivedAt: .distantPast, deviceID: "ble:x", deviceName: "X",
                                                timeZone: TimeZone(identifier: "UTC")!)
        #expect(reading.deviceUser == 2)
        #expect(reading.irregularHeartbeat)
        #expect(reading.timestamp != .distantPast)
    }

    @Test func decodesKPaAndMissingMAP() throws {
        // 16.0 kPa = mantissa 160, exponent -1 -> 0xF0A0; MAP NaN
        let m = try BloodPressureMeasurement(bytes: [0x01, 0xA0, 0xF0, 0x6B, 0xF0, 0xFF, 0x07])
        #expect(abs(m.systolic - 120.0) < 0.01)
        #expect(abs(m.diastolic - 80.25) < 0.01)
        #expect(m.meanArterialPressure == nil)
        #expect(m.timestamp == nil)
        #expect(m.userID == nil)
    }

    @Test func unknownUserAndMissingTimeFallback() throws {
        let m = try BloodPressureMeasurement(bytes: [0x08, 0x78, 0x00, 0x50, 0x00, 0x5E, 0x00, 0xFF])
        #expect(m.userID == nil)
        let now = Date()
        #expect(BluetoothBPSource.reading(from: m, receivedAt: now, deviceID: "d", deviceName: "n").timestamp == now)
    }

    @Test func rejectsTruncated() {
        #expect(throws: BloodPressureMeasurement.DecodeError.truncated) {
            try BloodPressureMeasurement(bytes: [0x02, 0x78, 0x00, 0x50, 0x00, 0x5E, 0x00, 0xEA])
        }
    }

    @Test func sfloatSpecialValues() {
        #expect(BloodPressureMeasurement.sfloat(0x07FF) == nil)
        #expect(BloodPressureMeasurement.sfloat(0x0800) == nil)
        #expect(BloodPressureMeasurement.sfloat(0x0FFF) == -1)
        #expect(BloodPressureMeasurement.sfloat(0x1001) == 10)
    }
}
