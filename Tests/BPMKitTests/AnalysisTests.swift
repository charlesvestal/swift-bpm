@testable import BPMKit
import Foundation
import Testing

struct AnalysisTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func point(_ minutes: Double, _ sys: Double, _ dia: Double, pulse: Double? = 60, ihb: Bool = false) -> BPPoint {
        BPPoint(timestamp: t0.addingTimeInterval(minutes * 60), systolic: sys, diastolic: dia, pulse: pulse, irregularHeartbeat: ihb)
    }

    @Test func groupsBackToBackReadings() {
        let points = [Self.point(0, 130, 80), Self.point(1, 126, 78, pulse: nil, ihb: true), Self.point(2, 122, 76, pulse: 64),
                      Self.point(30, 118, 74)]
        let grouped = BPAnalysis.groupConsecutive(points, within: 5 * 60)
        #expect(grouped.count == 2)
        #expect(grouped[0].systolic == 126 && grouped[0].diastolic == 78)
        #expect(grouped[0].pulse == 62) // mean of the readings that have a pulse
        #expect(grouped[0].irregularHeartbeat && grouped[0].readingCount == 3)
        #expect(grouped[0].timestamp == Self.t0)
        #expect(grouped[1].readingCount == 1)
        #expect(BPAnalysis.groupConsecutive(points.reversed(), within: 0).map(\.systolic) == [130, 126, 122, 118])
    }

    @Test func windowIsMeasuredFromFirstReadingOfRun() {
        // 0, 4, 8 minutes with a 5 minute window: the third starts a new run.
        let grouped = BPAnalysis.groupConsecutive([Self.point(0, 120, 80), Self.point(4, 120, 80), Self.point(8, 120, 80)], within: 300)
        #expect(grouped.map(\.readingCount) == [2, 1])
    }

    @Test func statisticsAndDerivedValues() throws {
        let s = try #require(BPStatistic([120, 130, 110, 140]))
        #expect(s.mean == 125 && s.median == 125 && s.min == 110 && s.max == 140)
        #expect(abs(s.standardDeviation - 12.91) < 0.01)
        #expect(BPStatistic([3, 1, 2])?.median == 2)
        #expect(BPStatistic([]) == nil)

        let p = Self.point(0, 120, 81)
        #expect(p.meanArterialPressure == 94)
        #expect(p.pulsePressure == 39)
    }

    @Test func summaryCountsThresholdsAndCategories() {
        let points = [Self.point(0, 118, 76), Self.point(60, 135, 79), Self.point(120, 125, 82, ihb: true), Self.point(180, 150, 95)]
        let summary = BPSummary(points, thresholds: BPThresholds(systolic: 130, diastolic: 80), guideline: .accAha2017)
        #expect(summary.aboveThresholdCount == 3)
        #expect(summary.irregularCount == 1)
        #expect(summary.categoryShares.map(\.category.title) == ["Normal", "Hypertension stage 1", "Hypertension stage 2"])
        #expect(summary.categoryShares.map(\.count) == [1, 2, 1])

        let esh = BPSummary(points, guideline: .esh2023)
        #expect(esh.categoryShares.map(\.category.title) == ["Optimal", "Normal", "High normal", "Grade 1 hypertension"])

        let strict = BPSummary(points, thresholds: BPThresholds(systolic: 135, diastolic: 85))
        #expect(strict.aboveThresholdCount == 2)
    }

    @Test func timeOfDayBuckets() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date { utc.date(bySettingHour: hour, minute: 30, second: 0, of: Self.t0)! }
        #expect(TimeOfDay(date: at(3), calendar: utc) == .night)
        #expect(TimeOfDay(date: at(4), calendar: utc) == .morning)
        #expect(TimeOfDay(date: at(12), calendar: utc) == .afternoon)
        #expect(TimeOfDay(date: at(18), calendar: utc) == .evening)

        let points = [at(7), at(8), at(20)].map { BPPoint(timestamp: $0, systolic: 120, diastolic: 80, pulse: nil) }
        let parts = BPSummary.byTimeOfDay(points, calendar: utc)
        #expect(parts.map(\.0) == [.morning, .evening])
        #expect(parts.map(\.1.count) == [2, 1])
    }
}

struct ForeignCSVTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func readsOmronLayout() throws {
        let text = """
        Date,Time Zone,Systolic (mmHg),Diastolic (mmHg),Pulse (bpm),Irregular heartbeat detected,Cuff wrap,Body Movement,Device
        2026/11/2 7:05,+01:00,128,82,66,Detected,,,M7
        2026/11/2 21:40,+01:00,119,77,61,,,Detected,M7
        not a date,,1,2,3,,,,
        """
        let result = try ColumnMapping.presets.first { $0.name == "OMRON connect" }!.decode(text, timeZone: utc)
        #expect(result.rows.count == 2)
        #expect(result.skippedLines == [4])
        #expect(result.rows[0].timestamp == ISO8601DateFormatter().date(from: "2026-11-02T07:05:00Z"))
        #expect(result.rows[0].irregularHeartbeat && !result.rows[0].bodyMovement)
        #expect(result.rows[1].bodyMovement)
        #expect(result.rows[0].source == "OMRON connect")
    }

    @Test func readsSemicolonFileWithUnitsAndAmPm() throws {
        let mapping = ColumnMapping(name: "Test", firstDataLine: 2, delimiter: ";", dateColumn: 0, dateFormat: "M/d/yyyy",
                                    timeColumn: 1, timeFormat: "h:m a", systolicColumn: 2, diastolicColumn: 3, pulseColumn: 4,
                                    irregularColumn: 5, irregularValues: "AFIB|PAD", noteColumn: 6)
        let text = "date;time;sys;dia;pulse;flags;note\n11/2/2026;8:15 PM;121 mmHg;79 mmHg;70 bpm;pad;after dinner\n"
        let row = try #require(try mapping.decode(text, timeZone: utc).rows.first)
        #expect(row.timestamp == ISO8601DateFormatter().date(from: "2026-11-02T20:15:00Z"))
        #expect([row.systolic, row.diastolic, row.pulse] == [121, 79, 70])
        #expect(row.irregularHeartbeat)
        #expect(row.note == "after dinner")
    }

    @Test func guessesPresetFromFileName() {
        #expect(ColumnMapping.guess(fileName: "OMRON_export_2026.csv")?.name == "OMRON connect")
        #expect(ColumnMapping.guess(fileName: "beurer-data.csv")?.name == "Beurer HealthManager")
        #expect(ColumnMapping.guess(fileName: "readings.csv") == nil)
    }

    @Test func hiddenColumnRoundTrips() throws {
        let row = CSVReading(timestamp: Date(timeIntervalSince1970: 1_800_000_000), systolic: 120, diastolic: 80, hidden: true)
        #expect(try ReadingsCSV.decode(ReadingsCSV.encode([row])) == [row])
    }
}
