import XCTest
@testable import WeekleftCore

/// S-04 / §5.14, decision 12: Esc sends no Stop. Leaving Claude within one catalog
/// poll after an interruption produced SessionEnd right after the running
/// turn, and "Response ready" with the Lift sound for a reply that never came.
final class SessionEndNoticeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double,
                      provider: ProviderID = .claude) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "exit", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: provider, previous: previous, now: start.addingTimeInterval(seconds))
    }

    func testSessionEndAfterActiveWorkIsSilent() throws {
        for (provider, first) in [(ProviderID.claude, "UserPromptSubmit"), (.claude, "PermissionRequest"), (.claude, "PreToolUse"), (.codex, "UserPromptSubmit")] {
            var tracker = SessionNoticeTracker()
            let working = try hook(first, ["tool_use_id": "t1", "tool_name": "Bash"], after: nil, at: 0, provider: provider)
            XCTAssertTrue(tracker.update([working.session], now: start).isEmpty)
            let ended = try hook("SessionEnd", ["reason": "prompt_input_exit"], after: working, at: 8, provider: provider)
            XCTAssertEqual(ended.session.phase, .finished)
            XCTAssertEqual(tracker.update([ended.session], now: start.addingTimeInterval(9)).map(\.kind), [], "\(provider) \(first)")
        }
    }

    func testCompletedAndFailedRepliesStillNotifyBeforeTheSessionEnds() throws {
        var tracker = SessionNoticeTracker()
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        _ = tracker.update([prompt.session], now: start)
        let stop = try hook("Stop", ["last_assistant_message": "Готово."], after: prompt, at: 5)
        XCTAssertEqual(tracker.update([stop.session], now: start.addingTimeInterval(5)).map(\.kind), [.completed])
        let ended = try hook("SessionEnd", ["reason": "logout"], after: stop, at: 10)
        XCTAssertTrue(tracker.update([ended.session], now: start.addingTimeInterval(10)).isEmpty)
        let retry = try hook("UserPromptSubmit", after: nil, at: 20)
        _ = tracker.update([retry.session], now: start.addingTimeInterval(20))
        let failed = try hook("StopFailure", ["error": "rate_limit"], after: retry, at: 25)
        XCTAssertEqual(tracker.update([failed.session], now: start.addingTimeInterval(25)).map(\.kind), [.failed])
    }

    func testSessionEndReasonIsKeptAsAFixedCode() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        for reason in ["prompt_input_exit", "clear", "logout", "other", "bypass_permissions_disabled"] {
            XCTAssertEqual(try hook("SessionEnd", ["reason": reason], after: prompt, at: 1).session.endReason, reason)
        }
        for reason: Any in ["Quit because /Users/fixture/secret", String(repeating: "x", count: 80), 42, ""] {
            XCTAssertNil(try hook("SessionEnd", ["reason": reason], after: prompt, at: 1).session.endReason, "\(reason)")
        }
        let ended = try hook("SessionEnd", ["reason": "prompt_input_exit"], after: prompt, at: 1)
        XCTAssertNil(try hook("SessionStart", ["source": "resume"], after: ended, at: 2).session.endReason, "A later event starts a new lifecycle")
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(ended))
        XCTAssertEqual(decoded.session.endReason, "prompt_input_exit")
    }
}
