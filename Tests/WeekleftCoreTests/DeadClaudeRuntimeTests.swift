import XCTest
@testable import WeekleftCore

/// S-13 / A-02 / §5.8: a Claude client killed (kill -9, crash, closed terminal)
/// in the middle of a turn sends no Stop or SessionEnd. Its hook record said
/// "working" or "waiting" for up to ten minutes (an hour for a background
/// pause): false activity minutes, Keep Awake and "Waiting 1" in the menu bar.
final class DeadClaudeRuntimeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func hook(_ name: String, _ extra: [String: Any] = [:], id: String = "killed", after previous: SessionRecord?, at seconds: Double,
                      provider: ProviderID = .claude, pid: Int32? = 4242) throws -> AgentSession {
        var payload: [String: Any] = ["session_id": id, "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        // A terminal client: the rule is limited to clients whose runtime lives for the session (R2-04).
        var record = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: provider, previous: previous,
                                             now: start.addingTimeInterval(seconds), client: .terminal)
        record.session.runtimePID = pid
        return record.session
    }

    func testAKilledClientsWorkingOrWaitingTurnEndsAsInterrupted() throws {
        let rows = [try hook("UserPromptSubmit", id: "working", after: nil, at: 0),
                    try hook("PermissionRequest", ["tool_use_id": "t"], id: "approval", after: nil, at: 0),
                    try hook("Notification", ["notification_type": "elicitation_dialog"], id: "form", after: nil, at: 0),
                    try hook("Stop", ["background_tasks": [["id": "b", "type": "shell", "status": "running", "command": "sleep 900"]]],
                             id: "paused", after: nil, at: 0)]
        XCTAssertEqual(rows.map(\.phase), [.running, .permission, .input, .running])
        let ended = SessionList.endingDeadClaudeRuntimes(rows, completeCatalog: [], isAlive: { _ in false })
        XCTAssertEqual(ended.map(\.phase), [.interrupted, .interrupted, .interrupted, .interrupted])
        XCTAssertTrue(ended.allSatisfy { !$0.effectivePhase(now: self.start.addingTimeInterval(20)).isActive })
        XCTAssertTrue(ended.allSatisfy { $0.awaitingBackground == nil && $0.backgroundWork == nil })

        // ActivityTracker counts no working time for them.
        var tracker = ActivityTracker()
        for seconds in [20.0, 25, 30] {
            tracker.observe(SessionList.endingDeadClaudeRuntimes(rows, completeCatalog: [], isAlive: { _ in false }), now: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(tracker.history.intervals.filter { $0.providers != 0 }.count, 0)
    }

    func testOnlyProvenAbsenceEndsTheTurn() throws {
        let working = try hook("UserPromptSubmit", after: nil, at: 0)
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: [], isAlive: { _ in true }).first?.phase, .running,
                       "A live process is still working")
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: nil, isAlive: { _ in false }).first?.phase, .running,
                       "A failed or partial catalog proves nothing")
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: [working.id], isAlive: { _ in false }).first?.phase, .running,
                       "A listed session is not gone")
        let unknownPID = try hook("UserPromptSubmit", after: nil, at: 0, pid: nil)
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([unknownPID], completeCatalog: [], isAlive: { _ in false }).first?.phase, .running,
                       "Records from older helpers keep the freshness rule")
        let codex = try hook("UserPromptSubmit", after: nil, at: 0, provider: .codex)
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([codex], completeCatalog: [], isAlive: { _ in false }).first?.phase, .running)
        let ready = try hook("Stop", ["last_assistant_message": "Готово."], after: nil, at: 0)
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([ready], completeCatalog: [], isAlive: { _ in false }).first?.phase, .ready,
                       "A finished reply stays as it is")
    }

    func testHookRecordsTheNearestNonShellAncestor() {
        func tree(_ nodes: [Int32: (Int32, String)]) -> (Int32) -> SessionProcess.RuntimeProcess? {
            { pid in nodes[pid].map { SessionProcess.RuntimeProcess(parentPID: $0.0, executable: $0.1) } }
        }
        let native = "/Users/fixture/.local/share/claude/versions/2.1.280"
        XCTAssertEqual(SessionProcess.hookClientPID(startPID: 300, read: tree([300: (200, "/bin/sh"), 200: (100, native), 100: (50, "/bin/zsh")])), 200)
        XCTAssertEqual(SessionProcess.hookClientPID(startPID: 200, read: tree([200: (100, native), 100: (50, "/bin/zsh")])), 200, "The runner exec'd the hook")
        XCTAssertEqual(SessionProcess.hookClientPID(startPID: 310, read: tree([310: (305, "/bin/bash"), 305: (200, "/usr/bin/env"), 200: (100, "/opt/homebrew/bin/node")])), 200)
        XCTAssertNil(SessionProcess.hookClientPID(startPID: 300, read: tree([:])), "Unreadable ancestry records nothing")
        XCTAssertNil(SessionProcess.hookClientPID(startPID: 300, read: tree([300: (1, "/bin/sh")])), "A reparented shell has no client")
        XCTAssertNil(SessionProcess.hookClientPID(startPID: 1, read: tree([1: (0, "/sbin/launchd")])))
    }

    func testCaptureStoresOnlyTheRuntimePIDAndProcessLivenessUsesESRCH() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeadRuntime-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONSerialization.data(withJSONObject: ["session_id": "live", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture"])
        try SessionHooks.capture(data, provider: .claude, at: directory, runtimePID: 4242, isInternal: { _ in false })
        XCTAssertEqual(SessionHooks.load(at: directory).first?.runtimePID, 4242)
        let codex = try JSONSerialization.data(withJSONObject: ["session_id": "codex", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture"])
        try SessionHooks.capture(codex, provider: .codex, at: directory, runtimePID: 4343, isInternal: { _ in false })
        XCTAssertNil(SessionHooks.load(at: directory).first { $0.provider == .codex }?.runtimePID, "Only Claude has a catalog to compare with")

        XCTAssertTrue(SessionProcess.isAlive(getpid()))
        XCTAssertTrue(SessionProcess.isAlive(1), "launchd exists even though signalling it is not permitted")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        XCTAssertFalse(SessionProcess.isAlive(child.processIdentifier), "A reaped child is gone")
    }
}
