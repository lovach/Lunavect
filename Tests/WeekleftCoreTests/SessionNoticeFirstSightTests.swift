import XCTest
@testable import WeekleftCore

/// R2-S-03: the tracker used the first sight of every session as a silent baseline.
/// The contract forbids only historical notices from the initial list. A session
/// that appears after monitoring started, with an event newer than the previous
/// poll, already in an attention or finished state, is a new transition.
final class SessionNoticeFirstSightTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ id: String, _ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": "/Users/fixture/Projects/" + id]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous,
                                       now: start.addingTimeInterval(seconds), client: .terminal)
    }
    /// A session whose prompt and next state both happened between two reads.
    private func appeared(_ id: String, _ name: String, _ extra: [String: Any] = [:], at seconds: Double) throws -> AgentSession {
        try hook(id, name, extra, after: hook(id, "UserPromptSubmit", after: nil, at: seconds - 1.5), at: seconds).session
    }
    private func monitoring() throws -> (SessionNoticeTracker, AgentSession) {
        var tracker = SessionNoticeTracker()
        let existing = try hook("existing", "UserPromptSubmit", after: nil, at: 0).session
        XCTAssertTrue(tracker.update([existing], now: start.addingTimeInterval(1)).isEmpty)
        return (tracker, existing)
    }

    func testANewSessionFirstSeenInAnAttentionOrFinishedStateIsAnnounced() throws {
        let cases: [(AgentSession, [SessionNoticeKind])] = [
            (try appeared("approval", "PermissionRequest", ["tool_use_id": "t1", "tool_name": "Bash"], at: 11.5), [.permission]),
            (try appeared("form", "Notification", ["notification_type": "elicitation_dialog"], at: 11.5), [.input]),
            (try appeared("question", "Stop", ["last_assistant_message": "Shall I apply these changes?"], at: 11.5), [.input]),
            (try appeared("reply", "Stop", ["last_assistant_message": "Done."], at: 11.5), [.completed]),
            (try appeared("failure", "StopFailure", ["error": "server_error"], at: 11.5), [.failed]),
            (try appeared("working", "PreToolUse", ["tool_name": "Bash", "tool_use_id": "t2"], at: 11.5), []),
        ]
        for (row, expected) in cases {
            var (tracker, existing) = try monitoring()
            XCTAssertEqual(tracker.update([existing, row], now: start.addingTimeInterval(12)).map(\.kind), expected, row.sessionID)
            XCTAssertTrue(tracker.update([existing, row], now: start.addingTimeInterval(13)).isEmpty, "Once: \(row.sessionID)")
        }
    }

    /// `claude -p`: prompt, Stop and SessionEnd between two reads is one answered reply.
    func testAHeadlessReplyFirstSeenAfterItEndedIsAnnouncedOnceAndAnInterruptedOneIsNot() throws {
        var (tracker, existing) = try monitoring()
        let answered = try hook("headless", "SessionEnd", ["reason": "other"],
                                after: hook("headless", "Stop", ["last_assistant_message": "Done."],
                                            after: hook("headless", "UserPromptSubmit", after: nil, at: 10), at: 11), at: 11.01).session
        let closed = try hook("closed", "SessionEnd", ["reason": "prompt_input_exit"],
                              after: hook("closed", "UserPromptSubmit", after: nil, at: 10), at: 11).session
        let notices = tracker.update([existing, answered, closed], now: start.addingTimeInterval(12))
        XCTAssertEqual(notices.map(\.session.sessionID), ["headless"])
        XCTAssertEqual(notices.map(\.kind), [.completed])
    }

    func testTheInitialListCatalogRowsOlderEventsAndAMonitoringGapStayABaseline() throws {
        let waiting = try appeared("approval", "PermissionRequest", ["tool_use_id": "t1", "tool_name": "Bash"], at: 11.5)
        var first = SessionNoticeTracker()
        XCTAssertTrue(first.update([waiting], now: start.addingTimeInterval(12)).isEmpty, "The initial list is history")

        var (tracker, existing) = try monitoring()
        let catalogRow = try XCTUnwrap(SessionParser.claude(JSONSerialization.data(withJSONObject: [[
            "sessionId": "listed", "pid": 51, "kind": "interactive", "cwd": "/Users/fixture/Projects/listed",
            "startedAt": 1_799_999_990_000, "status": "waiting"]]), now: start.addingTimeInterval(11)).first)
        XCTAssertTrue(tracker.update([existing, catalogRow], now: start.addingTimeInterval(12)).isEmpty,
                      "A catalog-only row has no event time: first sight stays a baseline")
        let older = try appeared("older", "PermissionRequest", ["tool_use_id": "t3", "tool_name": "Bash"], at: 11.8)
        _ = tracker.update([existing, catalogRow], now: start.addingTimeInterval(20))
        XCTAssertTrue(tracker.update([existing, catalogRow, older], now: start.addingTimeInterval(21)).isEmpty,
                      "An event before the previous poll is history even when first seen now")

        var (gap, existingAgain) = try monitoring()
        let afterSleep = try appeared("sleeper", "Stop", ["last_assistant_message": "Done."], at: 300)
        XCTAssertTrue(gap.update([existingAgain, afterSleep], now: start.addingTimeInterval(301)).isEmpty,
                      "After a monitoring gap the list is a baseline again")
    }
}
