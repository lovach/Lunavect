import XCTest
@testable import WeekleftCore

final class DataFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func payload(_ used: Double, session: String = "a", progress: Int = 1, reset: Date? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["session_id": session,
            "cost": ["total_api_duration_ms": progress, "total_duration_ms": progress * 10],
            "rate_limits": ["seven_day": ["used_percentage": used, "resets_at": (reset ?? now.addingTimeInterval(86400)).timeIntervalSince1970]]])
    }
    func testTwoSessionReplayDoesNotReplaceNewerObservationOrAdvanceReceiptTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = root.appendingPathComponent("quota.json")
        let idle = try payload(40), working = try payload(55, session: "b")
        try ClaudeProvider.capture(idle, destination: status, now: now)
        try ClaudeProvider.capture(working, destination: status, now: now.addingTimeInterval(10))
        let original = try Data(contentsOf: status)
        try ClaudeProvider.capture(idle, destination: status, now: now.addingTimeInterval(20))
        XCTAssertEqual(try Data(contentsOf: status), original)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: original)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 55)
        XCTAssertEqual(snapshot.fetchedAt, now.addingTimeInterval(10))
        XCTAssertTrue(snapshot.isStale(now: now.addingTimeInterval(20)), "Receipt is not a server quota timestamp")
    }
    func testNewProgressCanKeepOrLowerPercentageAndResetWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quota.json")
        for (index, used) in [55.0, 55, 40, 0].enumerated() {
            let date = now.addingTimeInterval(Double(index) * 10)
            try ClaudeProvider.capture(payload(used, progress: index, reset: index == 3 ? now.addingTimeInterval(2 * 86400) : nil), destination: file, now: date)
            let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: file))
            XCTAssertEqual(snapshot.weekly?.usedPercent, used)
            XCTAssertEqual(snapshot.fetchedAt, date)
        }
    }
    func testCurrentDirectUsageWinsOverUnverifiedStatusLineAndStaleFallbackKeepsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = root.appendingPathComponent("quota.json"), usage = root.appendingPathComponent("usage.json")
        let probe = try UsageSnapshot(
            provider: .claude,
            weekly: QuotaWindow(usedPercent: 55, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now, source: ClaudeUsageProbe.source)
        try ClaudeProvider.saveUsage(probe, destination: usage)
        try ClaudeProvider.capture(payload(40), destination: status, now: now.addingTimeInterval(20))
        XCTAssertEqual(try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now.addingTimeInterval(30)), probe)
        let fallback = try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now.addingTimeInterval(1000))
        XCTAssertEqual(fallback.source, "Claude Code statusLine")
        XCTAssertEqual(fallback.fetchedAt, now.addingTimeInterval(20))
        XCTAssertTrue(fallback.isStale(now: now.addingTimeInterval(1000)))
    }
    func testAutomaticRefreshUsesCurrentCacheAndManualRefreshInvokesProbe() async throws {
        let cached = try UsageSnapshot(
            provider: .claude,
            weekly: QuotaWindow(usedPercent: 55, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now, source: ClaudeUsageProbe.source)
        var probes = 0
        for force in [false, false, true, false] {
            _ = try await ClaudeProvider.refresh(force: force, now: now.addingTimeInterval(20), cached: { cached }, probe: { probes += 1; return cached }, save: { _ in })
        }
        XCTAssertEqual(probes, 1)
    }
    func testFreshnessOfOneWindowDoesNotDependOnOtherWindowsReset() throws {
        let weekly = try QuotaWindow(usedPercent: 28, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        let fiveHour = try QuotaWindow(usedPercent: 40, durationMinutes: 300, resetsAt: now)
        let snapshot = UsageSnapshot(provider: .codex, weekly: weekly, fiveHour: fiveHour, fetchedAt: now)
        XCTAssertFalse(snapshot.isStale(window: weekly, now: now))
        XCTAssertTrue(snapshot.isStale(window: fiveHour, now: now))
        XCTAssertTrue(snapshot.isStale(now: now), "A partially expired snapshot still needs refresh")
        XCTAssertTrue(snapshot.isStale(window: nil, now: now))
        XCTAssertTrue(snapshot.isStale(window: weekly, now: now.addingTimeInterval(901)))
        var unverified = snapshot; unverified.source = "Claude Code statusLine"
        XCTAssertTrue(unverified.isStale(window: weekly, now: now))
    }
    func testTimelineContainsFutureStalenessAndResetWithoutFetching() throws {
        let reset = now.addingTimeInterval(5400)
        let snapshot = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 12, durationMinutes: 10080, resetsAt: reset), fetchedAt: now)
        let dates = WidgetTimelineSchedule.dates(from: now, snapshots: [snapshot])
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count)
        XCTAssertTrue(dates.contains(now.addingTimeInterval(901)))
        XCTAssertTrue(dates.contains(reset))
        XCTAssertTrue(snapshot.isStale(now: now.addingTimeInterval(901)))
        XCTAssertTrue(try XCTUnwrap(snapshot.weekly).isExpired(at: reset))
    }
    func testClockCorrectionStartsNewObservationWithoutFillingGapOrDoubleCounting() throws {
        func row(_ date: Date) -> AgentSession {
            AgentSession(
                provider: .codex, sessionID: "fixture", title: "Fixture", cwd: "/fixture", phase: .running,
                updatedAt: date, observedAt: date, runtimeConfirmed: true)
        }
        var tracker = ActivityTracker()
        let future = now.addingTimeInterval(3600)
        tracker.observe([row(future)], now: future)
        tracker.observe([row(future.addingTimeInterval(5))], now: future.addingTimeInterval(5))
        tracker.observe([row(now)], now: now)
        for seconds in stride(from: 5, through: 600, by: 5) {
            let date = now.addingTimeInterval(Double(seconds)); tracker.observe([row(date)], now: date)
        }
        XCTAssertEqual(tracker.history.summary(now: now.addingTimeInterval(600)).totals.active, 600)
        XCTAssertEqual(tracker.history.summary(now: future.addingTimeInterval(5)).totals.active, 605)
        XCTAssertEqual(tracker.history.intervals.count, 2)
        let roundtrip = try? JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(tracker.history))
        XCTAssertEqual(roundtrip, tracker.history)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("details.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try tracker.details.save(to: file)
        XCTAssertEqual(try ActivityDetails.load(from: file), tracker.details)
    }
}
