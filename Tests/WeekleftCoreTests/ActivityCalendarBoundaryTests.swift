import XCTest
@testable import WeekleftCore

final class ActivityCalendarBoundaryTests: XCTestCase {
    func testDayWeekAndMonthPreserveWorkAroundDSTTransitions() throws {
        for (zone, workDate, nowDate, hours) in [
            ("America/Santiago", "2026-09-05T15:00:00Z", "2026-09-06T18:00:00Z", 23),
            ("Europe/Vienna", "2026-03-28T15:00:00Z", "2026-03-29T18:00:00Z", 23),
            ("Europe/Vienna", "2026-10-24T15:00:00Z", "2026-10-25T18:00:00Z", 25)
        ] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let parser = ISO8601DateFormatter()
            let work = try XCTUnwrap(parser.date(from: workDate)), now = try XCTUnwrap(parser.date(from: nowDate))
            var history = ActivityHistory()
            history.append(start: work, end: work.addingTimeInterval(3600), providers: 1, observedProviders: 1)
            history.append(start: now.addingTimeInterval(-3600), end: now, providers: 2, observedProviders: 2)
            let day = history.summary(now: now, calendar: calendar, period: .day)
            XCTAssertEqual(day.points.count, hours, zone)
            XCTAssertEqual(day.totals.active, 3600, zone)
            for period in [ActivityPeriod.week, .month] {
                let summary = history.summary(now: now, calendar: calendar, period: period)
                XCTAssertEqual(summary.totals.active, 7200, zone)
                XCTAssertEqual(summary.days.filter { $0.totals.active > 0 }.count, 2, zone)
                XCTAssertEqual(summary.points.reduce(0) { $0 + $1.totals.active }, 7200, zone)
            }
        }
    }
}
