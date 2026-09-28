import XCTest
@testable import WeekleftCore

/// Events go through `SessionHooks.capture`, the path the hook helper uses, not
/// only through `SessionRecord.event`. Records are written to this test's own
/// temporary folder; process liveness is injected.
final class HookCaptureContractTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-S-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func capture(_ name: String, _ extra: [String: Any] = [:], id: String = "subagents", at root: URL) throws {
        var payload: [String: Any] = ["session_id": id, "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        try SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: root, client: .terminal,
                                 runtimePID: 4242, isInternal: { _ in false }, isAlive: { _ in true })
    }
    private func task(_ id: String, _ type: String) -> [String: Any] { ["id": id, "type": type, "status": "running"] }

    /// R2-S-01: decision 10 and docs/sessions.md say SubagentStop lowers or confirms
    /// the background count. The helper parsed every event once without a previous
    /// record, where SubagentStop is rejected, so it never reached the stored record.
    func testSubagentStopReachesTheStoredRecord() throws {
        let root = try directory()
        try capture("UserPromptSubmit", at: root)
        try capture("PostToolUse", ["tool_name": "Bash", "tool_use_id": "b",
                                    "tool_input": ["command": "swift build", "run_in_background": true]], at: root)
        try capture("PostToolUse", ["tool_name": "Bash", "tool_use_id": "c",
                                    "tool_input": ["command": "npm run build", "run_in_background": true]], at: root)
        let before = try XCTUnwrap(SessionHooks.load(at: root).first)
        XCTAssertEqual(before.backgroundWork, BackgroundWork(commands: 2))

        XCTAssertNoThrow(try capture("SubagentStop", ["background_tasks": [task("c", "shell")]], at: root))
        let lowered = try XCTUnwrap(SessionHooks.load(at: root).first)
        XCTAssertEqual(lowered.backgroundWork, BackgroundWork(commands: 1), "The documented lowering reaches the record")
        XCTAssertEqual(lowered.phase, .running, "SubagentStop is not a turn boundary")
        XCTAssertEqual(lowered.observedAt, before.observedAt, "It does not refresh the turn's evidence")

        // A raise is refused and kept as a fixed diagnostic code with counts.
        let foreign = (0..<6).map { task("a\($0)", "subagent") } + (0..<3).map { task("s\($0)", "shell") }
        XCTAssertNoThrow(try capture("SubagentStop", ["background_tasks": foreign], at: root))
        let refused = try XCTUnwrap(SessionHooks.load(at: root).first)
        XCTAssertEqual(refused.backgroundWork, BackgroundWork(commands: 1))
        XCTAssertEqual(refused.hookDiagnostic?.kind, .backgroundCountRaised)
        XCTAssertEqual(refused.hookDiagnostic?.reported, BackgroundWork(commands: 3, agents: 6))
    }

    /// Without an existing record SubagentStop carries no lifecycle: no file is created.
    func testSubagentStopForAnUnknownSessionCreatesNoRecord() throws {
        let root = try directory()
        try? capture("SubagentStop", ["background_tasks": [task("c", "shell")]], id: "unknown", at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude-unknown.json").path))
        XCTAssertTrue(SessionHooks.load(at: root).isEmpty)
    }
}
