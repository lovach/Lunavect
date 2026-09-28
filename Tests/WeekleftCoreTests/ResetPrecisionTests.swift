import XCTest
@testable import WeekleftCore

/// Q-05: `/usage` prints a reset truncated to the minute ("11:59pm" for
/// 23:59:59.767 in Vienna). The window has certainly reset only at the end of the
/// shown minute; no surface, policy or notice may treat it as reset earlier.
final class ResetPrecisionTests: XCTestCase {
    /// The pair observed on the owner's Mac for the weekly reset of 2026-09-27
    /// (Apple reference-date seconds, usage.json and quota.json): the probe stored
    /// the start of the shown minute, the status line the reset itself.
    private let probeReset = Date(timeIntervalSinceReferenceDate: 812_239_140)       // 21:59:00Z, "11:59pm"
    private let statusLineReset = Date(timeIntervalSinceReferenceDate: 812_239_200)  // 22:00:00Z
    private let vienna = TimeZone(identifier: "Europe/Vienna")!

    private func screen(weeklyUsed: Int) -> String {
        """
        Current session
        12% used
        Resets 11:59pm (Europe/Vienna)
        Current week (all models)
        \(weeklyUsed)% used
        Resets Sep 27 at 11:59pm (Europe/Vienna)
        Esc to cancel
        """
    }
    private func statusLine(used: Double, observed: Date) throws -> UsageSnapshot {
        try UsageParser.claude(["seven_day": ["used_percentage": used, "resets_at": statusLineReset.timeIntervalSince1970]], now: observed)
    }

    func testProbeStoresTheEndOfTheShownMinuteLikeTheStatusLine() throws {
        let observed = probeReset.addingTimeInterval(-3600)
        let probe = try ClaudeUsageText.parse(screen(weeklyUsed: 100), now: observed, timeZone: vienna)
        XCTAssertEqual(probe.weekly?.resetsAt, statusLineReset)
        XCTAssertEqual(probe.weekly?.resetPrecision, .minute)
        XCTAssertEqual(probe.fiveHour?.resetsAt, statusLineReset)
        let exact = try statusLine(used: 100, observed: observed)
        XCTAssertEqual(exact.weekly?.resetsAt, probe.weekly?.resetsAt)
        XCTAssertNil(exact.weekly?.resetPrecision, "The status line reports an exact epoch")
    }

    func testShownMinuteIsNotExpiredBeforeItEnds() throws {
        let inside = probeReset.addingTimeInterval(30)
        let probe = try ClaudeUsageText.parse(screen(weeklyUsed: 100), now: inside, timeZone: vienna)
        let weekly = try XCTUnwrap(probe.weekly)
        XCTAssertEqual(weekly.resetsAt, statusLineReset)
        XCTAssertFalse(weekly.isExpired(at: inside))
        XCTAssertEqual(probe.status(of: weekly, now: inside), .exhausted, "0 % until the reset, not a passed reset")
        XCTAssertNotEqual(weekly.countdown(now: inside, language: "ru"), "обновление")
        XCTAssertTrue(weekly.isExpired(at: statusLineReset))
        XCTAssertEqual(probe.status(of: weekly, now: statusLineReset), .resetPassed(statusLineReset))
    }

    func testReturnIsNotAnnouncedBeforeTheEndOfTheShownMinute() throws {
        var tracker = LimitAlertTracker()
        let before = probeReset.addingTimeInterval(-600)
        let low = try ClaudeUsageText.parse(screen(weeklyUsed: 95), now: before, timeZone: vienna)
        XCTAssertEqual(tracker.update([low], threshold: 10, now: before).map(\.kind), [.low(remaining: 5)])
        XCTAssertEqual(tracker.nextDeadline(now: before), statusLineReset, "The return timer fires at the certain reset")
        XCTAssertTrue(tracker.update([low], threshold: 10, now: probeReset.addingTimeInterval(30)).isEmpty,
                      "Inside the shown minute the window has not certainly reset")
        XCTAssertEqual(tracker.update([low], threshold: 10, now: statusLineReset).map(\.kind), [.restored])
    }

    /// A cycle saved by an earlier version (or by any source that read the same
    /// reset earlier) moves to the later reading; it never moves earlier.
    func testSavedCycleWaitsForTheLaterReadingOfTheSameReset() throws {
        let saved = LimitAlertState.Cycle(provider: .claude, window: .weekly, resetsAt: probeReset, warned: true)
        var tracker = LimitAlertTracker(state: LimitAlertState(cycles: [saved]))
        let exact = try statusLine(used: 97, observed: probeReset.addingTimeInterval(-120))
        XCTAssertTrue(tracker.update([exact], threshold: 10, now: probeReset.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(tracker.nextDeadline(now: probeReset.addingTimeInterval(30)), statusLineReset)
        XCTAssertEqual(tracker.update([exact], threshold: 10, now: statusLineReset).map(\.kind), [.restored])

        var earlier = LimitAlertTracker(state: LimitAlertState(cycles: [.init(provider: .claude, window: .weekly, resetsAt: statusLineReset, warned: true)]))
        let legacy = try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 97, durationMinutes: 10080, resetsAt: probeReset),
                                       fetchedAt: probeReset.addingTimeInterval(-120), source: "test")
        XCTAssertTrue(earlier.update([legacy], threshold: 10, now: probeReset.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(earlier.nextDeadline(now: probeReset), statusLineReset, "An earlier reading never advances the return")
    }

    /// usage.json and snapshot.json written before resets carried their precision
    /// hold the start of the shown minute. They still decode, as the end of it.
    func testLegacyProbeSnapshotDecodesToTheEndOfItsShownMinute() throws {
        let fetched = probeReset.addingTimeInterval(-7200).timeIntervalSinceReferenceDate
        let reset = probeReset.timeIntervalSinceReferenceDate
        let legacy = """
        {"provider":"claude","source":"Claude Code /usage","fetchedAt":\(fetched),
         "weekly":{"usedPercent":100,"durationMinutes":10080,"resetsAt":\(reset)},
         "fiveHour":{"usedPercent":0,"durationMinutes":300},
         "modelQuotas":[{"name":"Fable","fetchedAt":\(fetched),"window":{"usedPercent":40,"durationMinutes":10080,"resetsAt":\(reset)}}]}
        """
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.weekly?.resetsAt, statusLineReset)
        XCTAssertEqual(decoded.weekly?.resetPrecision, .minute)
        XCTAssertEqual(decoded.fiveHour, try QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil), "An unstarted window has no reset to move")
        XCTAssertEqual(decoded.modelQuotas?.first?.window.resetsAt, statusLineReset)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(decoded)), decoded, "Moved once, not on every load")

        let exact = legacy.replacingOccurrences(of: "Claude Code /usage", with: "Claude Code statusLine")
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: Data(exact.utf8)).weekly?.resetsAt, probeReset,
                       "Exact sources are not moved")

        var tracker = LimitAlertTracker(state: LimitAlertState(cycles: [.init(provider: .claude, window: .weekly, resetsAt: probeReset, warned: true)]))
        XCTAssertTrue(tracker.update([decoded], threshold: 10, now: probeReset.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(tracker.update([decoded], threshold: 10, now: statusLineReset).map(\.kind), [.restored])
    }

    /// R1-12: a snapshot.json from 0.2.4 can hold the probe's model buckets inside a
    /// status-line snapshot. They are `/usage` readings and move to the end of their
    /// shown minute as well; the status line's own windows stay exact.
    func testProbeModelBucketsInsideAStatusLineSnapshotDecodeToTheEndOfTheMinute() throws {
        let fetched = probeReset.addingTimeInterval(-7200).timeIntervalSinceReferenceDate
        let legacy = """
        {"provider":"claude","source":"Claude Code statusLine","fetchedAt":\(fetched),
         "weekly":{"usedPercent":60,"durationMinutes":10080,"resetsAt":\(statusLineReset.timeIntervalSinceReferenceDate)},
         "modelQuotas":[{"name":"Fable","fetchedAt":\(fetched),"window":{"usedPercent":40,"durationMinutes":10080,"resetsAt":\(probeReset.timeIntervalSinceReferenceDate)}}]}
        """
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.weekly?.resetsAt, statusLineReset, "The status line's exact reset is not moved")
        XCTAssertNil(decoded.weekly?.resetPrecision)
        XCTAssertEqual(decoded.modelQuotas?.first?.window.resetsAt, statusLineReset)
        XCTAssertEqual(decoded.modelQuotas?.first?.window.resetPrecision, .minute)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(decoded)), decoded, "Moved once, not on every load")
        let model = try XCTUnwrap(decoded.modelQuotas?.first)
        XCTAssertNotEqual(model.status(now: probeReset.addingTimeInterval(30)), .resetPassed(probeReset), "Not expired inside the shown minute")
    }

    /// WP-1a's confirming probe ran 90 s after the shown minute's start. The reset is
    /// now stored 60 s later, so the grace is 30 s: the probe keeps its moment.
    func testConfirmingProbeKeepsItsMomentAfterTheShownMinute() throws {
        let observed = probeReset.addingTimeInterval(-3600)
        let exhausted = try ClaudeUsageText.parse(screen(weeklyUsed: 100), now: observed, timeZone: vienna)
        let policy = QuotaRefreshPolicy()
        XCTAssertFalse(policy.shouldFetch(.claude, snapshot: exhausted, trigger: .timer, now: statusLineReset.addingTimeInterval(-1)))
        XCTAssertFalse(policy.shouldFetch(.claude, snapshot: exhausted, trigger: .timer, now: statusLineReset.addingTimeInterval(29)))
        XCTAssertTrue(policy.shouldFetch(.claude, snapshot: exhausted, trigger: .timer, now: statusLineReset.addingTimeInterval(30)))
        XCTAssertEqual(QuotaRefreshPolicy.nextResetCheck([exhausted], now: observed), statusLineReset.addingTimeInterval(30))
        XCTAssertTrue(WidgetTimelineSchedule.dates(from: observed, snapshots: [exhausted]).contains(statusLineReset))
    }
}
