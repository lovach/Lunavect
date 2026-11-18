import XCTest
@testable import WeekleftCore

/// Owner's report, 18.11.2026: a session whose turn had ended with a workflow still
/// running showed «Думает 25:20». Every tool call of the workflow's agents cleared
/// the pause for background work. While the conversation waits, its background
/// and workflow agents' events keep the row «В фоне»; the conversation's own
/// events end the pause.
final class BackgroundWaitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "wait", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous, now: start.addingTimeInterval(seconds))
    }
    private let agentTask: [String: Any] = ["id": "a1", "type": "subagent", "status": "running", "description": "private text"]

    private func pausedForBackground() throws -> SessionRecord {
        var record = try hook("UserPromptSubmit", after: nil, at: 0)
        record = try hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "t1", "tool_input": ["run_in_background": true]], after: record, at: 1)
        record = try hook("Stop", ["last_assistant_message": "Запустил помощника, жду его.", "background_tasks": [agentTask]], after: record, at: 2)
        XCTAssertEqual(record.session.awaitingBackground, true)
        XCTAssertEqual(record.session.activityTitle, L("В фоне"))
        return record
    }

    func testBackgroundAgentCallsKeepTheRowInBackground() throws {
        var record = try pausedForBackground()
        record = try hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "s1", "agent_id": "a1"], after: record, at: 60)
        XCTAssertEqual(record.session.awaitingBackground, true)
        XCTAssertNil(record.session.tool, "The agent's tool is not the conversation's")
        XCTAssertEqual(record.session.activityTitle, L("В фоне"))
        record = try hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "s1", "agent_id": "a1"], after: record, at: 61)
        XCTAssertEqual(record.session.phase, .running)
        XCTAssertEqual(record.session.activityTitle, L("В фоне"))
        XCTAssertEqual(record.session.backgroundWork, BackgroundWork(agents: 1))
    }

    func testBackgroundAgentDialogShowsPermissionThenReturnsToBackground() throws {
        var record = try pausedForBackground()
        record = try hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "s2", "agent_id": "a1"], after: record, at: 60)
        record = try hook("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"], after: record, at: 66)
        XCTAssertEqual(record.session.phase, .permission)
        XCTAssertEqual(record.session.awaitingBackground, true)
        record = try hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "s2", "agent_id": "a1"], after: record, at: 80)
        XCTAssertEqual(record.session.phase, .running)
        XCTAssertEqual(record.session.activityTitle, L("В фоне"))
    }

    func testConversationOwnCallEndsThePause() throws {
        var record = try pausedForBackground()
        record = try hook("PreToolUse", ["tool_name": "Read", "tool_use_id": "m1"], after: record, at: 90)
        XCTAssertNil(record.session.awaitingBackground)
        XCTAssertEqual(record.session.tool, "Read")
        XCTAssertEqual(record.session.activityTitle, L("Читает файл"))
    }

    func testAgentCallDuringALiveTurnStaysThinking() throws {
        var record = try hook("UserPromptSubmit", after: nil, at: 0)
        record = try hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "s3", "agent_id": "a9"], after: record, at: 5)
        XCTAssertNil(record.session.awaitingBackground, "No pause without a Stop that left background work")
        XCTAssertEqual(record.session.tool, "Bash")
    }
}
