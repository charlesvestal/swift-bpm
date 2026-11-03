@testable import BPMKit
import Foundation
import Testing

struct HomeMonitoringTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 2 + day, hour: hour, minute: minute))!
    }

    func point(_ date: Date, _ sys: Double, _ dia: Double) -> BPPoint {
        BPPoint(timestamp: date, systolic: sys, diastolic: dia, pulse: 60)
    }

    /// A full week: day 0 high (practice), then 128/82 mornings and 120/76 evenings.
    func fullWeek() -> [BPPoint] {
        (0..<7).flatMap { day -> [BPPoint] in
            let (m, e): ((Double, Double), (Double, Double)) = day == 0 ? ((160, 100), (160, 100)) : ((128, 82), (120, 76))
            return [point(at(day, 7, 0), m.0, m.1), point(at(day, 7, 1), m.0, m.1),
                    point(at(day, 21, 0), e.0, e.1), point(at(day, 21, 2), e.0, e.1)]
        }
    }

    @Test func fullWeekExcludesPracticeDay() {
        let plan = HomeMonitoringPlan(start: at(0, 15))
        let result = HomeMonitoringResult(points: fullWeek() + [point(at(7, 7), 200, 120), point(at(-1, 21), 200, 120)],
                                          plan: plan, calendar: calendar)
        #expect(result.days.count == 7)
        #expect(result.days[0].excluded)
        #expect(result.included.count == 24)
        #expect(result.summary.systolic?.mean == 124)
        #expect(result.summary.diastolic?.mean == 79)
        #expect(result.morning.systolic?.mean == 128)
        #expect(result.evening.systolic?.mean == 120)
        #expect(result.completedSessions == 12 && result.expectedSessions == 12)
        #expect(result.meetsMinimum)
        #expect(result.isRaised == false)
    }

    @Test func incompleteWeekReportsProgress() {
        let plan = HomeMonitoringPlan(start: at(0, 8))
        // Days 1 and 2 only, one evening reading short.
        let points = [point(at(1, 7), 140, 90), point(at(1, 7, 1), 138, 88), point(at(1, 20), 136, 86),
                      point(at(2, 7), 142, 92), point(at(2, 7, 2), 140, 90)]
        let result = HomeMonitoringResult(points: points, plan: plan, calendar: calendar)
        #expect(result.completedSessions == 2)
        #expect(!result.days[1].isComplete(.evening))
        #expect(result.daysWithReadings == 2)
        #expect(!result.meetsMinimum)
        #expect(result.isRaised == true)
    }

    @Test func keepingFirstDayAndShorterPlans() {
        let plan = HomeMonitoringPlan(start: at(0, 8), days: 3, discardFirstDay: false)
        let result = HomeMonitoringResult(points: fullWeek(), plan: plan, calendar: calendar)
        #expect(result.days.count == 3)
        #expect(result.included.count == 12)
        #expect(result.summary.systolic?.max == 160)
    }

    @Test func sessionTimesForReminders() {
        let plan = HomeMonitoringPlan(start: at(0, 18), days: 2)
        let times = plan.sessionTimes(morning: 7 * 60, evening: 21 * 60 + 30, calendar: calendar)
        #expect(times.count == 4)
        #expect(times[0].date == at(0, 7) && times[0].session == .morning)
        #expect(times[3].date == at(1, 21, 30) && times[3].day == 1)
    }

    @Test func dayIndexAcrossDaylightSavingChange() {
        // Europe/Berlin leaves summer time on 2026-10-25.
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9))!
        let plan = HomeMonitoringPlan(start: start)
        let afterChange = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 7))!
        #expect(plan.dayIndex(of: afterChange, calendar: calendar) == 3)
        #expect(plan.end(calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!)
    }
}
