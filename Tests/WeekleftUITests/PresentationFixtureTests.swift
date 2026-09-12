import XCTest
import WeekleftCore

final class PresentationFixtureTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: hour, minute: minute))!
    }
    func testCurrentDayIncludesCompletedAndCurrentWork() throws {
        let fixture = try PresentationFixture(now: date(hour: 12), calendar: calendar)
        let summary = fixture.history.summary(now: fixture.now, calendar: calendar)
        XCTAssertGreaterThan(summary.today.claude, 120, "Today's completed work must not be cut off at midnight")
        XCTAssertGreaterThan(summary.today.codex, 0, "The demo's recent Codex task must be present")
        XCTAssertEqual(summary.lastLiveObservedAt, fixture.now)
        XCTAssertTrue(fixture.history.intervals.allSatisfy { $0.end <= fixture.now })
        let justAfterMidnight = try PresentationFixture(now: date(hour: 0, minute: 1), calendar: calendar)
        XCTAssertGreaterThan(justAfterMidnight.history.summary(now: justAfterMidnight.now, calendar: calendar).today.active, 0)
    }
    func testBreakdownMatchesChartIncludingSimultaneousWork() throws {
        let fixture = try PresentationFixture(now: date(hour: 12), calendar: calendar)
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: fixture.now))!, end: fixture.now)
        for providers in [[ProviderID.claude], [.codex], [.claude, .codex]] {
            let summary = fixture.history.summary(now: fixture.now, calendar: calendar, providers: providers)
            let records = fixture.details.selected(in: range, providers: providers)
            let breakdown = ActivityDetails.totals(for: records, in: range)
            XCTAssertEqual(breakdown.active, summary.totals.active, accuracy: 0.001)
            XCTAssertEqual(breakdown.recovered, summary.totals.recovered, accuracy: 0.001)
        }
    }
    func testStatusTransitionsPreserveOtherSessionClock() throws {
        let fixture = try PresentationFixture(now: date(hour: 12), calendar: calendar)
        var previousElapsed: TimeInterval = 0
        for stage in 0...2 {
            let current = fixture.now.addingTimeInterval(Double(stage * 6))
            let sessions = fixture.sessions(stage: stage, observedAt: current)
            let work = try XCTUnwrap(sessions.first { $0.provider == .claude })
            let started = try XCTUnwrap(work.turnStartedAt)
            let elapsed = current.timeIntervalSince(started)
            XCTAssertGreaterThan(elapsed, previousElapsed)
            XCTAssertEqual(started, fixture.now.addingTimeInterval(-72))
            XCTAssertEqual(sessions[1].effectivePhase(now: current), [.running, .permission, .ready][stage])
            previousElapsed = elapsed
        }
    }
}
