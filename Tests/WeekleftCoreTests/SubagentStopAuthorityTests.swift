import XCTest
@testable import WeekleftCore

/// S-03 / §5.13, decision 10: on the owner's Mac an audit session that started
/// no background work showed "6 agents, 3 commands" after SubagentStop events.
/// Stop is the authority for background work; SubagentStop may only lower or
/// confirm what was launched, and an attempt to raise is kept as counts only.
final class SubagentStopAuthorityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "audit", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous, now: start.addingTimeInterval(seconds))
    }
    private func task(_ id: String?, _ type: String, _ status: String? = "running") -> [String: Any] {
        var task: [String: Any] = ["type": type, "description": "private text"]
        if let id { task["id"] = id }
        if let status { task["status"] = status }
        return task
    }
    private var foreignList: [[String: Any]] {
        (0..<6).map { task("a\($0)", "subagent") } + (0..<3).map { task("b\($0)", "shell") }
    }

    func testSubagentStopCannotRaiseCountsAboveWhatWasLaunched() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let working = try hook("PreToolUse", ["tool_name": "Task", "tool_use_id": "t1"], after: prompt, at: 1)
        let stopped = try hook("SubagentStop", ["agent_id": "x", "background_tasks": foreignList], after: working, at: 20)
        XCTAssertNil(stopped.session.backgroundWork, "No badge for tasks this session never started")
        XCTAssertEqual(stopped.session.hookDiagnostic?.kind, .backgroundCountRaised)
        XCTAssertEqual(stopped.session.hookDiagnostic?.reported, BackgroundWork(commands: 3, agents: 6))
        XCTAssertEqual(stopped.session.hookDiagnostic?.at, start.addingTimeInterval(20))
        XCTAssertEqual(stopped.session.tool, "Task", "SubagentStop is not a turn boundary")
        XCTAssertEqual(stopped.session.observedAt, working.session.observedAt)
        let stored = String(decoding: try JSONEncoder().encode(stopped), as: UTF8.self)
        XCTAssertFalse(stored.contains("private text"))
        // A later Stop without that list ends the reply normally.
        let reply = try hook("Stop", ["last_assistant_message": "Готово.", "background_tasks": []], after: stopped, at: 30)
        XCTAssertEqual(reply.session.phase, .ready)
        XCTAssertNil(reply.session.backgroundWork)
    }

    func testSubagentStopLowersAndConfirmsLaunchedWork() throws {
        var record = try hook("UserPromptSubmit", after: nil, at: 0)
        record = try hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "a", "tool_input": ["run_in_background": true]], after: record, at: 1)
        record = try hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "b", "tool_input": ["command": "swift build", "run_in_background": true]], after: record, at: 2)
        record = try hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "c", "tool_input": ["command": "npm run build", "run_in_background": true]], after: record, at: 3)
        XCTAssertEqual(record.session.backgroundWork, BackgroundWork(commands: 2, agents: 1))
        let confirmed = try hook("SubagentStop", ["background_tasks": [task("b", "shell"), task("c", "shell"), task("a", "subagent")]], after: record, at: 10)
        XCTAssertEqual(confirmed.session.backgroundWork, BackgroundWork(commands: 2, agents: 1))
        XCTAssertNil(confirmed.session.hookDiagnostic)
        let lowered = try hook("SubagentStop", ["background_tasks": [task("c", "shell")]], after: confirmed, at: 20)
        XCTAssertEqual(lowered.session.backgroundWork, BackgroundWork(commands: 1))
        let mixed = try hook("SubagentStop", ["background_tasks": [task("c", "shell"), task("m", "monitor")]], after: lowered, at: 25)
        XCTAssertEqual(mixed.session.backgroundWork, BackgroundWork(commands: 1), "A kind is never raised, another may still drop")
        XCTAssertEqual(mixed.session.hookDiagnostic?.reported, BackgroundWork(commands: 1, monitors: 1))
        XCTAssertNil(try hook("SubagentStop", ["background_tasks": []], after: mixed, at: 30).session.backgroundWork)
    }

    func testOnlyRunningOrPendingTasksWithAnIdentifierAreCounted() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let tasks = [task("r", "shell"), task("p", "subagent", "pending"), task(nil, "shell"), task("", "shell"),
                     task("q", "shell", "in_progress"), task("s", "monitor", nil), task("d", "subagent", "completed")]
        let stop = try hook("Stop", ["background_tasks": tasks], after: prompt, at: 5)
        XCTAssertEqual(stop.session.backgroundWork, BackgroundWork(commands: 1, agents: 1))
        XCTAssertEqual(stop.session.phase, .running, "Known running work is still a pause")
    }

    func testStopRemainsTheAuthorityInBothDirections() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let raised = try hook("Stop", ["background_tasks": [task("r1", "shell"), task("r2", "shell")]], after: prompt, at: 5)
        XCTAssertEqual(raised.session.backgroundWork, BackgroundWork(commands: 2), "Stop may report work that PostToolUse missed")
        XCTAssertNil(raised.session.hookDiagnostic)
        let launched = try hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "a", "tool_input": ["run_in_background": true]],
                                after: try hook("UserPromptSubmit", after: raised, at: 10), at: 11)
        let reply = try hook("Stop", ["background_tasks": [task("other", "subagent", "completed")]], after: launched, at: 20)
        XCTAssertNil(reply.session.backgroundWork, "A Stop list without the session's tasks clears the count")
        XCTAssertEqual(reply.session.phase, .ready)
    }
}
