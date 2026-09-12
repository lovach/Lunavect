import XCTest
@testable import WeekleftCore

final class ActivityTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ id: String = "test", provider: ProviderID = .codex, phase: SessionPhase = .running, at date: Date? = nil) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "Private title", cwd: "/private/project", phase: phase,
                     updatedAt: date ?? base, observedAt: date ?? base, evidence: .localEvent, runtimeConfirmed: true)
    }
    func testConcurrentSessionsCountWallTimeOnceAndKeepProviderTotals() {
        var tracker = ActivityTracker()
        let rows = [row("a"), row("b"), row("c", provider: .claude)]
        tracker.observe(rows, now: base)
        tracker.observe(rows, now: base.addingTimeInterval(5))
        tracker.observe(rows, now: base.addingTimeInterval(10))
        let summary = tracker.history.summary(now: base.addingTimeInterval(10))
        XCTAssertEqual(summary.totals.active, 10)
        XCTAssertEqual(summary.totals.claude, 10)
        XCTAssertEqual(summary.totals.codex, 10)
        XCTAssertEqual(tracker.history.intervals.count, 1)
    }
    func testPollingDoesNotInventActivityFromWaitingUnknownOrUnconfirmedRows() {
        var unconfirmed = row("old"); unconfirmed.runtimeConfirmed = false
        let rows = [row("permission", phase: .permission), row("input", phase: .input), row("idle", phase: .idle), row("unknown", phase: .unknown), unconfirmed]
        var tracker = ActivityTracker()
        tracker.observe(rows, now: base)
        tracker.observe(rows, now: base.addingTimeInterval(1))
        let summary = tracker.history.summary(now: base.addingTimeInterval(1))
        XCTAssertEqual(summary.totals.active, 0)
        XCTAssertEqual(summary.totals.observed, 1)
        XCTAssertNil(summary.peakHour)
    }
    func testStaleOrFutureObservationsCannotExtendActivity() {
        var tracker = ActivityTracker()
        tracker.observe([row()], now: base.addingTimeInterval(119))
        tracker.observe([row()], now: base.addingTimeInterval(120))
        tracker.observe([row()], now: base.addingTimeInterval(121))
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(121)).totals.active, 0)
        var future = ActivityTracker()
        future.observe([row(at: base.addingTimeInterval(30))], now: base)
        future.observe([row(at: base.addingTimeInterval(30))], now: base.addingTimeInterval(1))
        XCTAssertEqual(future.history.summary(now: base.addingTimeInterval(1)).totals.active, 0)
    }
    func testDisappearanceAndTransitionsDoNotContinuePreviousRunningTime() {
        var tracker = ActivityTracker()
        tracker.observe([row()], now: base)
        tracker.observe([], now: base.addingTimeInterval(1))
        tracker.observe([row()], now: base.addingTimeInterval(2))
        tracker.observe([row(phase: .ready)], now: base.addingTimeInterval(3))
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(3)).totals.active, 0)
    }
    func testUnavailableSourcesRemainMissingInsteadOfZeroActivity() {
        var tracker = ActivityTracker()
        tracker.observe([], now: base)
        tracker.observe([], now: base.addingTimeInterval(1))
        tracker.observe([row(phase: .unknown)], now: base.addingTimeInterval(2))
        tracker.observe([row(phase: .unknown)], now: base.addingTimeInterval(3))
        XCTAssertFalse(tracker.history.summary(now: base.addingTimeInterval(3)).hasObservations)
        XCTAssertTrue(tracker.history.intervals.isEmpty)
    }
    func testSleepRestartAndDuplicatePollsLeaveUnobservedGaps() {
        var tracker = ActivityTracker()
        tracker.observe([row()], now: base)
        tracker.observe([row()], now: base.addingTimeInterval(2))
        tracker.observe([row()], now: base.addingTimeInterval(2))
        tracker.observe([row(at: base.addingTimeInterval(3600))], now: base.addingTimeInterval(3600))
        tracker.observe([row(at: base.addingTimeInterval(3600))], now: base.addingTimeInterval(3602))
        var restarted = ActivityTracker(history: tracker.history)
        restarted.observe([row(at: base.addingTimeInterval(7200))], now: base.addingTimeInterval(7200))
        restarted.observe([row(at: base.addingTimeInterval(7200))], now: base.addingTimeInterval(7202))
        let summary = restarted.history.summary(now: base.addingTimeInterval(7202))
        XCTAssertEqual(summary.totals.active, 6)
        XCTAssertEqual(summary.totals.observed, 6)
    }
    func testClockRollbackCannotDoubleCount() {
        var tracker = ActivityTracker()
        tracker.observe([row()], now: base)
        tracker.observe([row()], now: base.addingTimeInterval(2))
        tracker.observe([row()], now: base.addingTimeInterval(-1))
        tracker.observe([row()], now: base.addingTimeInterval(1))
        tracker.observe([row()], now: base.addingTimeInterval(3))
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(3)).totals.active, 3)
    }
    func testMidnightAndFractionalTimeZoneSplitExactly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-09T18:14:00Z"))
        var history = ActivityHistory()
        history.append(start: start, end: start.addingTimeInterval(120), providers: 1)
        let summary = history.summary(now: start.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(summary.days[5].totals.active, 60)
        XCTAssertEqual(summary.today.active, 60)
        XCTAssertEqual(summary.hours[23], 60)
        XCTAssertEqual(summary.hours[0], 60)
    }
    func testDaylightSavingTimeSkipsMissingHourAndCountsRepeatedHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        let spring = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T00:30:00Z"))
        var history = ActivityHistory()
        history.append(start: spring, end: spring.addingTimeInterval(7200), providers: 2)
        let summary = history.summary(now: spring.addingTimeInterval(7200), calendar: calendar)
        XCTAssertEqual(summary.hours[1], 1800)
        XCTAssertEqual(summary.hours[2], 0)
        XCTAssertEqual(summary.hours[3], 3600)
        XCTAssertEqual(summary.hours[4], 1800)
        let fall = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z"))
        history = ActivityHistory()
        history.append(start: fall, end: fall.addingTimeInterval(7200), providers: 3)
        XCTAssertEqual(history.summary(now: fall.addingTimeInterval(7200), calendar: calendar).hours[2], 7200)
    }
    func testRollingSevenDaysExcludeOldDataAndPeakUsesActiveTime() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: base)
        var history = ActivityHistory()
        history.append(start: today.addingTimeInterval(-7 * 86400), end: today.addingTimeInterval(-6 * 86400), providers: 3)
        history.append(start: today.addingTimeInterval(9 * 3600), end: today.addingTimeInterval(12 * 3600), providers: 0)
        history.append(start: today.addingTimeInterval(13 * 3600), end: today.addingTimeInterval(13 * 3600 + 120), providers: 2)
        let summary = history.summary(now: today.addingTimeInterval(14 * 3600), calendar: calendar)
        XCTAssertEqual(summary.totals.active, 120)
        XCTAssertEqual(summary.peakHour, 13)
        XCTAssertEqual(summary.peakLabel, "13–14")
        XCTAssertEqual(summary.days.count, 7)
    }
    func testPersistencePreservesOnlyAggregatesAndRejectsCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("activity.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var tracker = ActivityTracker()
        tracker.observe([row()], now: base)
        tracker.observe([row()], now: base.addingTimeInterval(2))
        try tracker.history.save(to: url)
        XCTAssertEqual(try ActivityHistory.load(from: url), tracker.history)
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("Private title")); XCTAssertFalse(text.contains("/private/project")); XCTAssertFalse(text.contains("sessionID"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        try Data("{broken".utf8).write(to: url)
        XCTAssertThrowsError(try ActivityHistory.load(from: url))
        XCTAssertEqual(try String(contentsOf: url), "{broken")
    }
    func testRetentionTrimsOldIntervalsAndMissingHistoryRemainsEmpty() {
        var history = ActivityHistory()
        history.append(start: base, end: base.addingTimeInterval(40 * 86400), providers: 1)
        XCTAssertEqual(history.intervals.first?.start, base.addingTimeInterval(5 * 86400))
        XCTAssertFalse(ActivityHistory().summary(now: base).hasObservations)
        XCTAssertNil(ActivityHistory().summary(now: base).peakHour)
    }
}
