import XCTest
@testable import WeekleftCore

/// S-10 / §5.19: Notification types from the Claude Code hooks reference that
/// Lunavect did not know were rejected, so an answered MCP form stayed
/// "Input needed" and a background agent's request for input was lost.
final class NotificationHookTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "forms", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous, now: start.addingTimeInterval(seconds))
    }
    private func notification(_ type: String, after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        try hook("Notification", ["notification_type": type, "message": "private text"], after: previous, at: seconds)
    }

    func testAnsweredFormReturnsToWork() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        for dialog in ["elicitation_dialog", "elicitation_url_dialog"] {
            let asking = try notification(dialog, after: prompt, at: 5)
            XCTAssertEqual(asking.session.phase, .input)
            for answer in ["elicitation_complete", "elicitation_response"] {
                let answered = try notification(answer, after: asking, at: 9)
                XCTAssertEqual(answered.session.phase, .running, "\(dialog) -> \(answer)")
                XCTAssertEqual(answered.session.observedAt, start.addingTimeInterval(9))
                XCTAssertEqual(answered.session.turnStartedAt, prompt.session.turnStartedAt, "The same reply continues")
            }
        }
    }

    func testBackgroundAgentAskingForInputNeedsTheUser() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let asking = try notification("agent_needs_input", after: prompt, at: 5)
        XCTAssertEqual(asking.session.phase, .input)
        var tracker = SessionNoticeTracker()
        _ = tracker.update([prompt.session], now: start)
        XCTAssertEqual(tracker.update([asking.session], now: start.addingTimeInterval(5)).map(\.kind), [.input])
    }

    func testOtherNotificationsAreIgnoredWithoutAnError() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        for type in ["agent_completed", "quota_auto_resume_started", "quota_auto_resume_completed", "auth_success", "a_future_type"] {
            let ignored = try notification(type, after: prompt, at: 5)
            XCTAssertEqual(ignored.session, prompt.session, "\(type) changes nothing, not even freshness")
        }
        XCTAssertThrowsError(try hook("Notification", after: prompt, at: 5), "A Notification without a type is still malformed")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationHook-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONSerialization.data(withJSONObject: ["session_id": "unseen", "hook_event_name": "Notification",
                                                               "notification_type": "agent_completed", "cwd": "/Users/fixture"])
        XCTAssertNoThrow(try SessionHooks.capture(data, provider: .claude, at: directory, isInternal: { _ in false }))
        XCTAssertTrue(SessionHooks.load(at: directory).isEmpty, "An ignored notice creates no session record")
    }
}
