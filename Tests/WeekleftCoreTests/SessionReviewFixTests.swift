import XCTest
@testable import WeekleftCore

/// Findings R2-03, R2-04, R2-05 and R2-08 of the 2026-09-28 review of the session
/// package. Hook records are written only to this test's temporary folder; process
/// liveness is either injected or probed on a child this test started and reaped.
final class SessionReviewFixTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func payload(_ name: String, _ extra: [String: Any] = [:], id: String = "resumed") throws -> Data {
        var object: [String: Any] = ["session_id": id, "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        object.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func event(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at seconds: Double,
                       client: SessionClient = .terminal, pid: Int32? = 4242) throws -> SessionRecord {
        var record = try SessionRecord.event(payload(name, extra), provider: .claude, previous: previous,
                                             now: start.addingTimeInterval(seconds), client: client)
        record.session.runtimePID = pid
        return record
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionReviewFix-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func reapedPID() throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        return child.processIdentifier
    }

    // MARK: R2-03

    /// Killed mid-reply, then `claude --resume` in a new process within ten minutes:
    /// the old turn does not come back as working with its old timer.
    func testResumeAfterAKilledClientStartsReadyInsteadOfReplayingTheOldTurn() throws {
        let directory = try temporaryDirectory(), dead = try reapedPID()
        try SessionHooks.capture(payload("UserPromptSubmit"), provider: .claude, at: directory, client: .terminal,
                                 runtimePID: dead, isInternal: { _ in false })
        XCTAssertEqual(SessionHooks.load(at: directory).first?.phase, .running)
        try SessionHooks.capture(payload("SessionStart", ["source": "resume"]), provider: .claude, at: directory, client: .terminal,
                                 runtimePID: getpid(), isInternal: { _ in false })
        let resumed = try XCTUnwrap(SessionHooks.load(at: directory).first)
        XCTAssertEqual(resumed.phase, .idle, "The resumed session waits for its first prompt")
        XCTAssertNil(resumed.turnStartedAt, "The killed turn's timer is not reused")
        XCTAssertEqual(resumed.runtimePID, getpid())
        XCTAssertFalse(resumed.effectivePhase(now: resumed.observedAt).isActive, "Neither counted as work nor holding Keep Awake")
    }

    func testTheRecordedRuntimeEndsOnlyWhenItIsGoneAndReplaced() throws {
        let working = try event("UserPromptSubmit", after: nil, at: 0, pid: 100)
        func settled(_ runtime: Int32?, alive: Bool) -> SessionRecord {
            SessionRecord.endingReplacedRuntime(working, runtimePID: runtime, isAlive: { _ in alive })
        }
        XCTAssertEqual(settled(200, alive: false).session.phase, .interrupted)
        XCTAssertNil(settled(200, alive: false).session.turnStartedAt)
        XCTAssertEqual(settled(200, alive: true).session.phase, .running, "Another live process of the session keeps its turn")
        XCTAssertEqual(settled(100, alive: false).session.phase, .running, "The same runtime is not replaced")
        XCTAssertEqual(settled(nil, alive: false).session.phase, .running, "No new runtime identity, no conclusion")
        // With a live second process (for example Desktop and CLI on one session) startup still keeps the turn.
        let concurrent = try SessionRecord.event(payload("SessionStart", ["source": "resume"]), provider: .claude,
                                                 previous: settled(200, alive: true), now: start.addingTimeInterval(5))
        XCTAssertEqual(concurrent.session.phase, .running)
    }

    // MARK: R2-04

    /// The dead-runtime rule is limited to clients whose runtime is known to live
    /// for the whole session: a Desktop or SDK runtime may exit between turns.
    func testDeadRuntimeRuleAppliesOnlyToTerminalAndEditorClients() throws {
        let clients: [SessionClient] = [.terminal, .vscode, .jetbrains, .desktop, .background, .unknown]
        let rows = try clients.map { client in
            try event("Stop", ["last_assistant_message": "Выберите вариант: A или B?"], after: nil, at: 0, client: client).session
        }
        XCTAssertTrue(rows.allSatisfy { $0.phase == .input })
        var stopped: [String: Date] = [:]
        let ended = SessionList.endingDeadClaudeRuntimes(rows.enumerated().map { index, row in
            var row = row; row.sessionID = "client-\(index)"; return row
        }, completeCatalog: [], stopped: &stopped, isAlive: { _ in false })
        XCTAssertEqual(ended.map(\.phase), [.interrupted, .interrupted, .interrupted, .input, .input, .input])
    }

    // MARK: R2-02 (pure part; the store test is in SessionPipelineAuditTests)

    func testStoppedDecisionIsKeptUntilTheSessionReportsAgain() throws {
        let working = try event("UserPromptSubmit", after: nil, at: 0).session
        var stopped: [String: Date] = [:]
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: [], stopped: &stopped, isAlive: { _ in false }).first?.phase, .interrupted)
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: nil, stopped: &stopped, isAlive: { _ in false }).first?.phase, .interrupted,
                       "A failed catalog read does not revive a stopped client")
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: nil, stopped: &stopped, isAlive: { _ in true }).first?.phase, .interrupted,
                       "A recycled PID does not revive it either")
        var next = try event("UserPromptSubmit", after: nil, at: 30).session
        next.sessionID = working.sessionID
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([next], completeCatalog: nil, stopped: &stopped, isAlive: { _ in false }).first?.phase, .running,
                       "A new event of the session is new evidence")
        XCTAssertTrue(stopped.isEmpty)
        _ = SessionList.endingDeadClaudeRuntimes([working], completeCatalog: [], stopped: &stopped, isAlive: { _ in false })
        XCTAssertEqual(SessionList.endingDeadClaudeRuntimes([working], completeCatalog: [working.id], stopped: &stopped, isAlive: { _ in false }).first?.phase, .running,
                       "A complete listing that names the session again lifts the decision")
    }

    // MARK: R2-05

    /// `claude -p` and SDK scripts send Stop and SessionEnd within milliseconds. One
    /// read can see both: the finished reply is still announced, exactly once.
    func testHeadlessReplyEndingWithSessionEndInOneReadIsAnnounced() throws {
        let prompt = try event("UserPromptSubmit", after: nil, at: 0)
        let stop = try event("Stop", ["last_assistant_message": "Done."], after: prompt, at: 5)
        let end = try event("SessionEnd", ["reason": "other"], after: stop, at: 5.01)
        var tracker = SessionNoticeTracker()
        XCTAssertTrue(tracker.update([prompt.session], now: start.addingTimeInterval(1)).isEmpty)
        let notices = tracker.update([end.session], now: start.addingTimeInterval(6))
        XCTAssertEqual(notices.map(\.kind), [.completed])
        // Seen separately, Stop announces and SessionEnd stays silent.
        var separate = SessionNoticeTracker()
        _ = separate.update([prompt.session], now: start.addingTimeInterval(1))
        XCTAssertEqual(separate.update([stop.session], now: start.addingTimeInterval(5.005)).map(\.kind), [.completed])
        XCTAssertTrue(separate.update([end.session], now: start.addingTimeInterval(6)).isEmpty)
    }

    func testSessionEndAfterAnInterruptedReplyStaysSilent() throws {
        let prompt = try event("UserPromptSubmit", after: nil, at: 0)
        // Esc (no Stop), then /exit.
        let end = try event("SessionEnd", ["reason": "prompt_input_exit"], after: prompt, at: 20)
        var tracker = SessionNoticeTracker()
        _ = tracker.update([prompt.session], now: start.addingTimeInterval(1))
        XCTAssertTrue(tracker.update([end.session], now: start.addingTimeInterval(21)).isEmpty)
        // An earlier reply of the session does not count for a later, interrupted one.
        let stop = try event("Stop", ["last_assistant_message": "Done."], after: prompt, at: 5)
        let next = try event("UserPromptSubmit", after: stop, at: 30)
        let closed = try event("SessionEnd", ["reason": "prompt_input_exit"], after: next, at: 40)
        var later = SessionNoticeTracker()
        _ = later.update([next.session], now: start.addingTimeInterval(31))
        XCTAssertTrue(later.update([closed.session], now: start.addingTimeInterval(41)).isEmpty)
    }

    // MARK: R2-08

    /// Decision 13 for hidden rows: `claude --resume` of a hidden session shows it
    /// again as ready for work, before its first prompt.
    func testResumingAHiddenSessionShowsItAgain() throws {
        let directory = try temporaryDirectory()
        var visibility = try SessionVisibility(url: directory.appendingPathComponent("hidden-sessions.json"), now: start)
        let finished = try event("Stop", ["last_assistant_message": "Done."], after: try event("UserPromptSubmit", after: nil, at: 0), at: 60)
        try visibility.hide(finished.session, now: start.addingTimeInterval(120))
        XCTAssertTrue(visibility.hidden.contains(finished.session.id))
        let polled = finished.session
        XCTAssertTrue(try visibility.restoreNewTasks([polled], now: start.addingTimeInterval(130)).isEmpty, "Polling the same state keeps it hidden")
        let resumed = try event("SessionStart", ["source": "resume"], after: finished, at: 3600)
        XCTAssertEqual(resumed.session.phase, .idle)
        let restored = try visibility.restoreNewTasks([resumed.session], now: start.addingTimeInterval(3601))
        XCTAssertEqual(restored, [resumed.session.id])
        XCTAssertFalse(visibility.hidden.contains(resumed.session.id))
        // Hidden again after the resume: the same resume does not undo that.
        try visibility.hide(resumed.session, now: start.addingTimeInterval(3700))
        XCTAssertTrue(try visibility.restoreNewTasks([resumed.session], now: start.addingTimeInterval(3701)).isEmpty)
        // A plain startup or /clear is not a reopened task.
        let cleared = try event("SessionStart", ["source": "clear"], after: resumed, at: 4000)
        XCTAssertTrue(try visibility.restoreNewTasks([cleared.session], now: start.addingTimeInterval(4001)).isEmpty)
    }
}
