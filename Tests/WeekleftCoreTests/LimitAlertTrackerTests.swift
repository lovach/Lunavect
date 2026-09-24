import XCTest
@testable import WeekleftCore

final class LimitAlertTrackerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ provider: ProviderID = .claude, fiveHourUsed: Double? = nil, weeklyUsed: Double? = nil,
                          fiveHourReset: TimeInterval = 7200, weeklyReset: TimeInterval = 3 * 86400,
                          fetched: TimeInterval = 0, issue: String? = nil) throws -> UsageSnapshot {
        UsageSnapshot(provider: provider,
                      weekly: try weeklyUsed.map { try QuotaWindow(usedPercent: $0, durationMinutes: 10080, resetsAt: now.addingTimeInterval(weeklyReset)) },
                      fiveHour: try fiveHourUsed.map { try QuotaWindow(usedPercent: $0, durationMinutes: 300, resetsAt: now.addingTimeInterval(fiveHourReset)) },
                      fetchedAt: now.addingTimeInterval(fetched), source: "test", issue: issue)
    }

    func testWarnsOncePerWindowCycleBelowTheThreshold() throws {
        var tracker = LimitAlertTracker()
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 85, weeklyUsed: 50)], threshold: 10, now: now).isEmpty)
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 90, weeklyUsed: 50)], threshold: 10, now: now).isEmpty, "exactly 10% left is not below 10%")
        let alerts = tracker.update([try snapshot(fiveHourUsed: 92.4, weeklyUsed: 50)], threshold: 10, now: now)
        XCTAssertEqual(alerts, [LimitAlert(provider: .claude, window: .fiveHour, kind: .low(remaining: 8), resetsAt: now.addingTimeInterval(7200))])
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 97, weeklyUsed: 50)], threshold: 10, now: now).isEmpty)
        // Sources round reset times differently: five minutes apart is the same cycle, twenty is not.
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 97, fiveHourReset: 7200 + 300)], threshold: 10, now: now).isEmpty)
        XCTAssertEqual(tracker.update([try snapshot(fiveHourUsed: 97, fiveHourReset: 7200 + 1200)], threshold: 10, now: now).count, 1)
    }

    func testIgnoresStaleOrFailedObservations() throws {
        var tracker = LimitAlertTracker()
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 99, fetched: -901)], threshold: 10, now: now).isEmpty)
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 99, issue: "Claude usage unavailable")], threshold: 10, now: now).isEmpty)
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 99, fiveHourReset: -60)], threshold: 10, now: now).isEmpty)
        XCTAssertEqual(tracker.update([try snapshot(.codex, weeklyUsed: 95)], threshold: 10, now: now).map(\.window), [.weekly])
    }

    func testThresholdChangesDoNotRepeatAnAlert() throws {
        var tracker = LimitAlertTracker()
        XCTAssertEqual(tracker.update([try snapshot(weeklyUsed: 85)], threshold: 20, now: now).count, 1)
        XCTAssertTrue(tracker.update([try snapshot(weeklyUsed: 85)], threshold: 25, now: now).isEmpty)
        XCTAssertTrue(tracker.update([try snapshot(weeklyUsed: 95)], threshold: 10, now: now).isEmpty)
    }

    func testRestoredOnlyAfterAWarningAndOnlyWhenOnTime() throws {
        var tracker = LimitAlertTracker()
        _ = tracker.update([try snapshot(fiveHourUsed: 50, weeklyUsed: 95)], threshold: 10, now: now)
        XCTAssertEqual(tracker.nextDeadline(now: now), now.addingTimeInterval(3 * 86400))
        XCTAssertTrue(tracker.update([], threshold: 10, now: now.addingTimeInterval(7300)).isEmpty, "the five-hour window was never low")
        let restored = tracker.update([], threshold: 10, now: now.addingTimeInterval(3 * 86400 + 5))
        XCTAssertEqual(restored, [LimitAlert(provider: .claude, window: .weekly, kind: .restored, resetsAt: now.addingTimeInterval(3 * 86400))])
        XCTAssertTrue(tracker.update([], threshold: 10, now: now.addingTimeInterval(3 * 86400 + 60)).isEmpty)
        XCTAssertNil(tracker.nextDeadline(now: now.addingTimeInterval(3 * 86400 + 60)))

        var late = LimitAlertTracker()
        _ = late.update([try snapshot(fiveHourUsed: 95)], threshold: 10, now: now)
        XCTAssertTrue(late.update([], threshold: 10, now: now.addingTimeInterval(7200 + 3601)).isEmpty, "a reset learned much later is closed silently")
        XCTAssertNil(late.nextDeadline(now: now.addingTimeInterval(7200 + 3601)))
    }

    func testStateSurvivesRestartAndOldCyclesArePruned() throws {
        var tracker = LimitAlertTracker()
        _ = tracker.update([try snapshot(fiveHourUsed: 95)], threshold: 10, now: now)
        let saved = try JSONEncoder().encode(tracker.state)
        var restarted = LimitAlertTracker(state: try JSONDecoder().decode(LimitAlertState.self, from: saved))
        XCTAssertTrue(restarted.update([try snapshot(fiveHourUsed: 96)], threshold: 10, now: now.addingTimeInterval(60)).isEmpty)
        _ = restarted.update([], threshold: 10, now: now.addingTimeInterval(9 * 86400))
        XCTAssertTrue(restarted.state.cycles.isEmpty)
    }

    func testUsesTheDisplayedRoundingForTheThreshold() throws {
        var tracker = LimitAlertTracker()
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 90.4)], threshold: 10, now: now).isEmpty, "9.6% is shown as 10%")
        XCTAssertEqual(tracker.update([try snapshot(fiveHourUsed: 90.6)], threshold: 10, now: now).first?.kind, .low(remaining: 9))
    }

    func testMutedNotificationsDoNotConsumeTheWarningAndDisabledProvidersStaySilent() throws {
        var tracker = LimitAlertTracker()
        XCTAssertTrue(tracker.update([try snapshot(fiveHourUsed: 95)], threshold: 10, now: now, announce: false).isEmpty)
        XCTAssertEqual(tracker.update([try snapshot(fiveHourUsed: 95)], threshold: 10, now: now).count, 1, "enabling later still warns")
        XCTAssertTrue(tracker.update([], threshold: 10, now: now.addingTimeInterval(7205), providers: [.codex]).isEmpty,
                      "a disconnected provider's return is not announced")
    }

    func testAMovedResetClosesTheEarlierCycleWithoutAFalseReturn() throws {
        var tracker = LimitAlertTracker()
        _ = tracker.update([try snapshot(weeklyUsed: 95)], threshold: 10, now: now)
        // The provider moves the weekly reset a day later while the window is still low.
        XCTAssertEqual(tracker.update([try snapshot(weeklyUsed: 96, weeklyReset: 4 * 86400)], threshold: 10, now: now.addingTimeInterval(60)).count, 1)
        let atOldReset = tracker.update([try snapshot(weeklyUsed: 97, weeklyReset: 4 * 86400, fetched: 3 * 86400)], threshold: 10, now: now.addingTimeInterval(3 * 86400 + 5))
        XCTAssertTrue(atOldReset.isEmpty, "the moved window has not reset yet")
        XCTAssertEqual(tracker.update([], threshold: 10, now: now.addingTimeInterval(4 * 86400 + 5)).map(\.kind), [.restored])
    }
}
