import XCTest
@testable import WeekleftCore

/// R2-S-02: Claude runs Stop hooks before it leaves the busy state, so a catalog
/// request that starts right after Lunavect's Stop record can still list the
/// session as busy. That newer listing turns the row back to working for one
/// poll; the next idle listing restores the same reply. One reply, one notice.
final class SessionNoticeIdempotencyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "lagging", "hook_event_name": name, "cwd": "/Users/fixture/Projects/lunavect"]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous,
                                       now: start.addingTimeInterval(seconds), client: .terminal)
    }
    private func catalog(_ status: String, requestedAt seconds: Double) throws -> [AgentSession] {
        let row: [String: Any] = ["sessionId": "lagging", "pid": 4242, "kind": "interactive", "cwd": "/Users/fixture/Projects/lunavect",
                                  "startedAt": 1_795_000_000_000, "status": status]
        return try SessionParser.claude(JSONSerialization.data(withJSONObject: [row]), now: start.addingTimeInterval(seconds))
    }
    private func notices(_ tracker: inout SessionNoticeTracker, _ catalog: [AgentSession], _ event: SessionRecord, at seconds: Double) -> [SessionNoticeKind] {
        let now = start.addingTimeInterval(seconds)
        return tracker.update(SessionList.merge(catalog: catalog, events: [event.session], now: now), now: now).map(\.kind)
    }

    func testABusyListingThatLagsBehindStopDoesNotAnnounceTheSameReplyTwice() throws {
        var tracker = SessionNoticeTracker()
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let stop = try hook("Stop", ["last_assistant_message": "Done."], after: prompt, at: 10)
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 5), prompt, at: 6), [])
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 5), stop, at: 10.1), [.completed])
        // Requested 0.2 s after the Stop record, answered while Claude still ran its Stop hooks.
        let lagging = try catalog("busy", requestedAt: 10.3)
        let flicker = SessionList.merge(catalog: lagging, events: [stop.session], now: start.addingTimeInterval(11))
        XCTAssertEqual(flicker.first?.phase, .running, "Precondition: the newer listing wins the merge")
        XCTAssertEqual(notices(&tracker, lagging, stop, at: 11), [])
        XCTAssertEqual(notices(&tracker, try catalog("idle", requestedAt: 25.3), stop, at: 26), [], "The same Stop is not a second reply")

        // The next reply is announced as usual.
        let next = try hook("UserPromptSubmit", after: stop, at: 30)
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 30.5), next, at: 31), [])
        let second = try hook("Stop", ["last_assistant_message": "Done again."], after: next, at: 40)
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 30.5), second, at: 40.1), [.completed])
    }

    /// The first read after Stop may already see a newer idle listing: the reply is
    /// then restored from the hook through the catalog row, which still carries the
    /// Stop's time. A later busy/idle pair without new events is the same reply.
    func testAReplyFirstSeenThroughTheIdleListingIsAlsoAnnouncedOnce() throws {
        var tracker = SessionNoticeTracker()
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let stop = try hook("Stop", ["last_assistant_message": "Done."], after: prompt, at: 10)
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 5), prompt, at: 6), [])
        let idle = try catalog("idle", requestedAt: 10.5)
        XCTAssertEqual(SessionList.merge(catalog: idle, events: [stop.session], now: start.addingTimeInterval(11)).first?.evidence, .catalog,
                       "Precondition: the reply reaches the tracker through the catalog row")
        XCTAssertEqual(notices(&tracker, idle, stop, at: 11), [.completed])
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 12), stop, at: 13), [])
        XCTAssertEqual(notices(&tracker, try catalog("idle", requestedAt: 27), stop, at: 28), [])
    }

    /// Catalog-only rows carry just the session start: a background task that
    /// works and finishes again without hooks is still announced each time.
    func testCatalogOnlyBackgroundCompletionsAreNotSettled() throws {
        var tracker = SessionNoticeTracker()
        func background(_ state: String, at seconds: Double) throws -> [AgentSession] {
            let row: [String: Any] = ["sessionId": "detached", "id": "detached", "kind": "background", "pid": 77,
                                      "status": "idle", "state": state, "startedAt": 1_795_000_000_000]
            return try SessionParser.claude(JSONSerialization.data(withJSONObject: [row]), now: start.addingTimeInterval(seconds))
        }
        var kinds: [SessionNoticeKind] = []
        for (state, seconds) in [("working", 0.0), ("done", 15), ("working", 30), ("done", 45)] {
            kinds += tracker.update(try background(state, at: seconds), now: start.addingTimeInterval(seconds + 1)).map(\.kind)
        }
        XCTAssertEqual(kinds, [.completed, .completed])
    }

    func testTheSameFailureIsAnnouncedOnce() throws {
        var tracker = SessionNoticeTracker()
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let failed = try hook("StopFailure", ["error": "server_error"], after: prompt, at: 10)
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 5), prompt, at: 6), [])
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 5), failed, at: 10.1), [.failed])
        XCTAssertEqual(notices(&tracker, try catalog("busy", requestedAt: 10.3), failed, at: 11), [])
        XCTAssertEqual(notices(&tracker, try catalog("idle", requestedAt: 25.3), failed, at: 26), [])
    }
}
