import XCTest
@testable import WeekleftCore

/// Live collection between two observations: gap tolerance, sleep, dropped-gap
/// diagnostics, private details integrity and calendar boundaries with a tracker.
final class ActivityContinuityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(_ id: String = "fixture", provider: ProviderID = .claude, phase: SessionPhase = .running, at date: Date,
                     confirmed: Bool? = true) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "Synthetic", cwd: "/tmp/fixture", phase: phase,
                     updatedAt: date, observedAt: date, evidence: .localEvent, runtimeConfirmed: confirmed)
    }
    private func observe(_ tracker: inout ActivityTracker, at offsets: [TimeInterval], id: String = "fixture") {
        for offset in offsets { tracker.observe([row(id, at: base.addingTimeInterval(offset))], now: base.addingTimeInterval(offset)) }
    }

    // MARK: A-04

    func testSlowPublicationWithinThreePollStepsStillCountsRunningWork() {
        var tracker = ActivityTracker()
        observe(&tracker, at: [0, 11, 26])
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(26)).totals.claude, 26,
                       "An 11 s and a 15 s publication delay are within three 5 s poll steps plus 5 s")
        XCTAssertNil(tracker.history.observationGaps)
    }

    func testGapBeyondToleranceIsNotWorkButIsCountedForDiagnostics() throws {
        var tracker = ActivityTracker()
        observe(&tracker, at: [0, 5, 30, 35])
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(35)).totals.claude, 10)
        let gaps = try XCTUnwrap(tracker.history.observationGaps)
        XCTAssertEqual(gaps.count, 1); XCTAssertEqual(gaps.seconds, 25)
        // Idle or unknown gaps are not lost work and are not reported as such.
        var idle = ActivityTracker()
        for offset in [0.0, 60] { idle.observe([row(phase: .idle, at: base.addingTimeInterval(offset))], now: base.addingTimeInterval(offset)) }
        XCTAssertNil(idle.history.observationGaps)
        // The counter survives storage and older files without it still decode.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try tracker.history.save(to: url)
        XCTAssertEqual(try ActivityHistory.load(from: url).observationGaps, gaps)
        let legacy = try JSONDecoder().decode(ActivityHistory.self, from: Data("{\"intervals\":[]}".utf8))
        XCTAssertNil(legacy.observationGaps)
    }

    func testSleepOrWakeBreaksContinuityEvenForAShortSleep() {
        var tracker = ActivityTracker()
        observe(&tracker, at: [0, 5])
        tracker.interruptObservation()
        observe(&tracker, at: [15, 20])
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(20)).totals.claude, 10, "The 10 s around the sleep are unobserved")
        XCTAssertNil(tracker.history.observationGaps, "A sleep is not a dropped observation")
    }

    // MARK: A-02 (tracker side of the WP-2 runtime check)

    func testRowWhoseProcessIsGoneContributesNoTime() {
        var tracker = ActivityTracker()
        tracker.observe([row(at: base)], now: base)
        // WP-2 marks a hook row unconfirmed once its Claude process is gone.
        tracker.observe([row(at: base.addingTimeInterval(5), confirmed: false)], now: base.addingTimeInterval(5))
        tracker.observe([row(at: base.addingTimeInterval(10), confirmed: false)], now: base.addingTimeInterval(10))
        XCTAssertEqual(tracker.history.summary(now: base.addingTimeInterval(10)).totals.active, 0)
        XCTAssertTrue(tracker.details.records.isEmpty)
    }

    // MARK: A-05

    func testOverlappingDetailAppendKeepsThePrivateFileLoadable() throws {
        var details = ActivityDetails()
        let session = row(at: base)
        details.append(session, start: base, end: base.addingTimeInterval(10))
        details.append(session, start: base.addingTimeInterval(5), end: base.addingTimeInterval(20))
        let record = try XCTUnwrap(details.records.values.first)
        XCTAssertEqual(record.totals(in: DateInterval(start: base, duration: 60)).active, 10, "Like history, the overlapping span is ignored")
        details.append(session, start: base.addingTimeInterval(5), end: base.addingTimeInterval(20), reconcilingClockCorrection: true)
        XCTAssertEqual(details.records.values.first?.totals(in: DateInterval(start: base, duration: 60)).active, 20)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try details.save(to: url)
        XCTAssertEqual(try ActivityDetails.load(from: url), details)
    }

    func testLoadRepairsOverlapsInsteadOfDiscardingTheBreakdown() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let t = base.timeIntervalSinceReferenceDate
        let key = "claude:fixture:/tmp/fixture"
        let json = """
        {"records":{"\(key)":{"provider":"claude","sessionID":"fixture","title":"Synthetic","cwd":"/tmp/fixture","intervals":[
        {"start":\(t),"end":\(t + 10),"providers":1,"observedProviders":1},
        {"start":\(t + 5),"end":\(t + 20),"providers":1,"observedProviders":1}]}}}
        """
        try Data(json.utf8).write(to: url)
        let loaded = try ActivityDetails.load(from: url)
        let record = try XCTUnwrap(loaded.records[key])
        XCTAssertEqual(record.intervals.count, 1)
        XCTAssertEqual(record.totals(in: DateInterval(start: base, duration: 60)).active, 20)
        // Other invalid content is still rejected and left for recovery with its bytes.
        try Data(json.replacingOccurrences(of: "\"providers\":1,", with: "\"providers\":2,").utf8).write(to: url)
        XCTAssertThrowsError(try ActivityDetails.load(from: url))
    }

    // MARK: Calendar boundaries with a live tracker (audit 04 §4 items 5 and 6)

    private func vienna() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        return calendar
    }
    private func run(from start: Date, seconds: Int) -> ActivityTracker {
        var tracker = ActivityTracker()
        for offset in stride(from: 0, through: seconds, by: 5) {
            let date = start.addingTimeInterval(Double(offset))
            tracker.observe([row(provider: .codex, at: date)], now: date)
        }
        return tracker
    }

    func testMidnightDuringLiveWorkSplitsBetweenDaysAndHoursInVienna() throws {
        let calendar = try vienna()
        // 2026-09-27 23:59:30 CEST.
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-27T21:59:30Z"))
        let end = start.addingTimeInterval(60)
        let summary = run(from: start, seconds: 60).history.summary(now: end, calendar: calendar)
        XCTAssertEqual(summary.days[5].totals.codex, 30)
        XCTAssertEqual(summary.today.codex, 30)
        XCTAssertEqual(summary.hours[23], 30)
        XCTAssertEqual(summary.hours[0], 30)
    }

    func testDaylightSavingTransitionsDuringLiveWork() throws {
        let calendar = try vienna()
        // 01:59 CET -> 03:01 CEST on 2026-03-29: two real minutes.
        let spring = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T00:59:00Z"))
        let springDay = run(from: spring, seconds: 120).history.summary(now: spring.addingTimeInterval(120), calendar: calendar, period: .day)
        XCTAssertEqual(springDay.points.count, 23)
        XCTAssertEqual(springDay.totals.codex, 120)
        XCTAssertEqual(springDay.points.reduce(0) { $0 + $1.totals.codex }, 120)
        XCTAssertEqual(springDay.hours[1], 60); XCTAssertEqual(springDay.hours[3], 60)
        // 02:59 CEST -> 02:01 CET on 2026-10-25: the repeated hour holds both minutes.
        let fall = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:59:00Z"))
        let fallDay = run(from: fall, seconds: 120).history.summary(now: fall.addingTimeInterval(120), calendar: calendar, period: .day)
        XCTAssertEqual(fallDay.points.count, 25)
        XCTAssertEqual(fallDay.totals.codex, 120)
        XCTAssertEqual(fallDay.points.reduce(0) { $0 + $1.totals.codex }, 120)
        XCTAssertEqual(fallDay.hours[2], 120)
    }

    // MARK: Matrix A6: a time-zone change between launches

    func testTimeZoneChangeRecomputesDaysFromAbsoluteHistoryWithoutHoles() throws {
        var history = ActivityHistory()
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-27T20:00:00Z"))
        history.append(start: start, end: start.addingTimeInterval(4 * 3600), providers: 1)
        let now = start.addingTimeInterval(4 * 3600)
        var vienna = Calendar(identifier: .gregorian); vienna.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let before = history.summary(now: now, calendar: vienna)
        let after = history.summary(now: now, calendar: tokyo)
        XCTAssertEqual(before.totals.claude, 14400); XCTAssertEqual(after.totals.claude, 14400)
        // 22:00-02:00 CEST crosses midnight; 05:00-09:00 JST does not.
        XCTAssertEqual(before.days.suffix(2).map(\.totals.claude), [7200, 7200])
        XCTAssertEqual(after.days.suffix(2).map(\.totals.claude), [0, 14400])
        XCTAssertEqual(after.hours.reduce(0, +), 14400)
    }
}
