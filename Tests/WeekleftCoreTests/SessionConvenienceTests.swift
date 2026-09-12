import XCTest
@testable import WeekleftCore

final class SessionConvenienceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ id: String, _ phase: SessionPhase, seconds: Double = 0) -> AgentSession {
        AgentSession(provider: .codex, sessionID: id, title: id, cwd: "", phase: phase,
                     updatedAt: now.addingTimeInterval(seconds), observedAt: now.addingTimeInterval(seconds), evidence: .hook)
    }
    func testNoticesOnlyOnNewTransitions() {
        var tracker = SessionNoticeTracker()
        XCTAssertTrue(tracker.update([row("a", .running), row("old", .ready)], now: now).isEmpty)
        XCTAssertEqual(tracker.update([row("a", .permission, seconds: 1)], now: now.addingTimeInterval(1)).map(\.kind), [.permission])
        XCTAssertTrue(tracker.update([row("a", .permission, seconds: 2)], now: now.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(tracker.update([row("a", .ready, seconds: 3)], now: now.addingTimeInterval(3)).map(\.kind), [.completed])
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: 4)], now: now.addingTimeInterval(4)).isEmpty)
        _ = tracker.update([row("a", .running, seconds: 5)], now: now.addingTimeInterval(5))
        XCTAssertEqual(tracker.update([row("a", .input, seconds: 6)], now: now.addingTimeInterval(6)).map(\.kind), [.input])
    }
    func testNoNoticesOnRediscoveryStaleOrLateEvents() {
        var tracker = SessionNoticeTracker()
        _ = tracker.update([row("a", .running)], now: now)
        XCTAssertTrue(tracker.update([], now: now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .running, seconds: 2)], now: now.addingTimeInterval(2)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: -10)], now: now.addingTimeInterval(3)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: 1)], now: now.addingTimeInterval(700)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: 701)], now: now.addingTimeInterval(701)).isEmpty)
    }
    func testLongRunningWorkStillNotifiesWhileMonitoringContinues() {
        var tracker = SessionNoticeTracker()
        _ = tracker.update([row("a", .running)], now: now)
        for seconds in stride(from: 60, through: 1200, by: 60) {
            XCTAssertTrue(tracker.update([row("a", .running)], now: now.addingTimeInterval(Double(seconds))).isEmpty)
        }
        XCTAssertEqual(tracker.update([row("a", .ready, seconds: 1201)], now: now.addingTimeInterval(1201)).map(\.kind), [.completed])
    }
    func testOldWidgetPreferencesPreserveSavedValues() throws {
        let data = Data(#"{"showFiveHour":true,"transparency":0.7,"subscriptionDates":{"claude":"2026-10-02"}}"#.utf8)
        let value = try JSONDecoder().decode(WidgetPreferences.self, from: data)
        XCTAssertFalse(value.transparentBackground)
        XCTAssertTrue(value.showFiveHour)
        XCTAssertEqual(value.transparency, 0.7)
        XCTAssertEqual(value.subscriptionDates["claude"], "2026-10-02")
    }
    func testExperimentalBackgroundRequiresOptInAndRetainsExplicitChoice() throws {
        XCTAssertFalse(WidgetPreferences().transparentBackground)
        for enabled in [false, true] {
            var preferences = WidgetPreferences()
            preferences.transparentBackground = enabled
            let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(decoded.transparentBackground, enabled)
        }
    }
    func testMovingFirstRowAfterLastAndPinsStaySeparate() {
        let rows = [row("a", .running), row("b", .ready), row("c", .permission)]
        var order = SessionArrangement()
        order.move(rows[0].id, before: rows[2].id, after: true, visible: rows.map(\.id))
        XCTAssertEqual(order.arranged(rows).map(\.sessionID), ["b", "c", "a"])
        order.pinned.insert(rows[1].id)
        let saved = order
        order.move(rows[0].id, before: rows[1].id, visible: rows.map(\.id))
        XCTAssertEqual(order, saved)
    }
    func testOrderingAndPinsPersistWithoutChangingSessions() throws {
        let rows = [row("a", .running), row("b", .ready), row("c", .permission)]
        var order = SessionArrangement()
        order.move(rows[2].id, before: rows[0].id, visible: rows.map(\.id))
        XCTAssertEqual(order.arranged(rows).map(\.sessionID), ["c", "a", "b"])
        order.pinned.insert(rows[1].id)
        let restored = try JSONDecoder().decode(SessionArrangement.self, from: JSONEncoder().encode(order))
        XCTAssertEqual(restored.arranged(rows).map(\.sessionID), ["b", "c", "a"])
        XCTAssertEqual(restored.arranged([rows[0], rows[2]]).map(\.sessionID), ["c", "a"])
        order.move("codex:missing", before: rows[0].id, visible: rows.map(\.id))
        XCTAssertEqual(order, restored)
        XCTAssertEqual(rows[0].phase, .running)
    }
}
