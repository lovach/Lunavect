import XCTest
@testable import WeekleftCore

/// S-06: a permission request ends with the first event that cannot happen while
/// its dialog is open. Payloads follow the documented hook input: Claude's and
/// Codex's PermissionRequest name the tool but carry no `tool_use_id`; tool
/// events carry it; a Claude subagent's events carry the parent's `session_id`
/// and its own `agent_id`. A request declined in the dialog is followed by no
/// PostToolUse, PostToolUseFailure or PermissionDenied (that one is auto mode only).
final class PermissionResolutionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ tool: String, _ id: String, agent: String? = nil, turn: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["tool_name": tool, "tool_use_id": id, "tool_input": ["command": "fixture"]]
        if let agent { payload["agent_id"] = agent; payload["agent_type"] = "Explore" }
        if let turn { payload["turn_id"] = turn }
        return payload
    }
    private func request(_ tool: String, agent: String? = nil, turn: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["tool_name": tool, "tool_input": ["command": "fixture"], "permission_mode": "default"]
        if let agent { payload["agent_id"] = agent; payload["agent_type"] = "Explore" }
        if let turn { payload["turn_id"] = turn }
        return payload
    }
    private func event(_ name: String, _ extra: [String: Any], provider: ProviderID, after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "parent-session", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: provider, previous: previous,
                                       now: start.addingTimeInterval(seconds), client: .terminal)
    }
    /// One event per second; returns the record after each event.
    private func play(_ steps: [(String, [String: Any])], provider: ProviderID = .claude, from previous: SessionRecord? = nil,
                      at first: Double = 0) throws -> [SessionRecord] {
        var record = previous, result: [SessionRecord] = []
        for (index, step) in steps.enumerated() {
            record = try event(step.0, step.1, provider: provider, after: record, at: first + Double(index))
            result.append(record!)
        }
        return result
    }
    private func phases(_ records: [SessionRecord]) -> [SessionPhase] { records.map(\.session.phase) }

    func testAnApprovedRequestEndsWhenItsToolRuns() throws {
        for finished in ["PostToolUse", "PostToolUseFailure"] {
            let steps = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash")),
                                  (finished, call("Bash", "x"))])
            XCTAssertEqual(phases(steps), [.running, .running, .permission, .running], finished)
            XCTAssertTrue(steps.last!.pendingApprovals.isEmpty)
            XCTAssertNil(steps.last!.unidentifiedApproval)
        }
    }

    /// «No» with a comment: Claude continues with another tool. Nothing reports the
    /// declined call, so the next call is the first proof the dialog is closed.
    func testADeclinedRequestEndsWithTheNextToolCall() throws {
        let claude = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash")),
                               ("PreToolUse", call("Read", "y")), ("PostToolUse", call("Read", "y")), ("Stop", [:])])
        XCTAssertEqual(phases(claude), [.running, .running, .permission, .running, .running, .ready])
        XCTAssertEqual(claude[3].session.tool, "Read")
        XCTAssertEqual(claude[3].session.turnStartedAt, start, "The same reply goes on")

        // A lost PreToolUse: completion of a call Lunavect never saw start is progress too.
        let lost = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash")),
                             ("PostToolUse", call("Read", "y"))])
        XCTAssertEqual(lost.last?.session.phase, .running)

        // Codex: declined («No, continue without running it») and the turn goes on.
        let codex = try play([("UserPromptSubmit", ["turn_id": "t1"]), ("PreToolUse", call("Bash", "x", turn: "t1")),
                              ("PermissionRequest", request("Bash", turn: "t1")), ("PreToolUse", call("apply_patch", "y", turn: "t1")),
                              ("PostToolUse", call("apply_patch", "y", turn: "t1")), ("Stop", ["turn_id": "t1"])], provider: .codex)
        XCTAssertEqual(phases(codex), [.running, .running, .permission, .running, .running, .ready])
    }

    /// The declined call was the last step of the reply, or the reply stopped there.
    func testADeclinedRequestEndsWithTheReplyOrTheTurn() throws {
        let closing: [(ProviderID, String, [String: Any], SessionPhase)] = [
            (.claude, "Stop", ["last_assistant_message": "Хорошо, не буду удалять."], .ready),
            (.claude, "StopFailure", ["error": "server_error"], .failed),
            (.claude, "UserPromptSubmit", [:], .running),   // «No» without a comment stops the turn; the next prompt
            (.claude, "SessionEnd", ["reason": "prompt_input_exit"], .finished),
            (.codex, "Interrupt", ["turn_id": "t1"], .interrupted),
            (.codex, "Stop", ["turn_id": "t1"], .ready),
        ]
        for (provider, name, extra, expected) in closing {
            let steps = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x", turn: "t1")),
                                  ("PermissionRequest", request("Bash", turn: "t1")), (name, extra)], provider: provider)
            XCTAssertEqual(steps.last?.session.phase, expected, "\(provider) \(name)")
            XCTAssertTrue(steps.last!.pendingApprovals.isEmpty)
            XCTAssertNil(steps.last!.unidentifiedApproval)
            // A new call after the new prompt is not held by the old request.
            let next = try event("PreToolUse", call("Read", "z"), provider: provider, after: steps.last!, at: 10)
            XCTAssertEqual(next.session.phase, .running, "\(provider) \(name)")
        }
    }

    /// Two dialogs at once (read-only calls run in parallel): each ends with its own call.
    func testParallelRequestsEachEndWithTheirOwnCall() throws {
        let different = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("WebFetch", "a")), ("PreToolUse", call("mcp__docs__read", "b")),
                                  ("PermissionRequest", request("WebFetch")), ("PermissionRequest", request("mcp__docs__read")),
                                  ("PostToolUse", call("WebFetch", "a")), ("PostToolUse", call("mcp__docs__read", "b"))])
        XCTAssertEqual(phases(different), [.running, .running, .running, .permission, .permission, .permission, .running])

        let same = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("WebFetch", "a")), ("PreToolUse", call("WebFetch", "b")),
                             ("PermissionRequest", request("WebFetch")), ("PermissionRequest", request("WebFetch")),
                             ("PostToolUse", call("WebFetch", "a")), ("PostToolUseFailure", call("WebFetch", "b"))])
        XCTAssertEqual(phases(same), [.running, .running, .running, .permission, .permission, .permission, .running])

        // A parallel call that needed no approval finishes while the dialog is open.
        let sibling = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("WebFetch", "a")), ("PreToolUse", call("Read", "r")),
                                ("PermissionRequest", request("WebFetch")), ("PostToolUse", call("Read", "r")),
                                ("PostToolUse", call("WebFetch", "a"))])
        XCTAssertEqual(phases(sibling), [.running, .running, .running, .permission, .permission, .running])

        let codex = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "a", turn: "t1")), ("PreToolUse", call("apply_patch", "p", turn: "t1")),
                              ("PermissionRequest", request("Bash", turn: "t1")), ("PermissionRequest", request("apply_patch", turn: "t1")),
                              ("PostToolUse", call("Bash", "a", turn: "t1")), ("PostToolUse", call("apply_patch", "p", turn: "t1"))], provider: .codex)
        XCTAssertEqual(phases(codex), [.running, .running, .running, .permission, .permission, .permission, .running])
    }

    /// S-I3: events are ordered by the time the helper captured them.
    func testALateOrRepeatedRequestCannotReopenAnAnsweredDialog() throws {
        let steps = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash")),
                              ("PostToolUse", call("Bash", "x"))])
        let answered = steps.last!
        for (name, extra) in [("PermissionRequest", request("Bash")), ("Notification", ["notification_type": "permission_prompt"])] {
            let late = try event(name, extra, provider: .claude, after: answered, at: 2.5)
            XCTAssertEqual(late.session.phase, .running, name)
            XCTAssertEqual(late.session.observedAt, answered.session.observedAt, "An older event changes nothing")
            XCTAssertTrue(late.pendingApprovals.isEmpty && late.unidentifiedApproval == nil)
        }
        // A request delivered twice (an identified form) is one dialog.
        let twice = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", ["tool_name": "Bash", "tool_use_id": "x"]),
                              ("PermissionRequest", ["tool_name": "Bash", "tool_use_id": "x"]), ("PostToolUse", call("Bash", "x"))])
        XCTAssertEqual(phases(twice), [.running, .running, .permission, .permission, .running])
        // The reminder after about six seconds does not add a second dialog.
        let reminded = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash")),
                                 ("Notification", ["notification_type": "permission_prompt"]), ("PostToolUse", call("Bash", "x"))])
        XCTAssertEqual(phases(reminded), [.running, .running, .permission, .permission, .running])
    }

    /// A subagent's events carry the parent's session_id: only that subagent can
    /// answer for its own dialog, and the main conversation only for its own.
    func testASubagentRequestEndsOnlyWithThatSubagent() throws {
        let opening: [(String, [String: Any])] = [
            ("UserPromptSubmit", [:]), ("PreToolUse", call("Agent", "task-a")), ("PreToolUse", call("Agent", "task-b")),
            ("PreToolUse", call("Bash", "a1", agent: "agent-a")), ("PreToolUse", call("Read", "b1", agent: "agent-b")),
            ("PermissionRequest", request("Bash", agent: "agent-a")),
        ]
        let other = try play(opening + [("PostToolUse", call("Read", "b1", agent: "agent-b")), ("PreToolUse", call("Grep", "b2", agent: "agent-b")),
                                        ("PostToolUse", call("Grep", "b2", agent: "agent-b")),
                                        ("SubagentStop", ["agent_id": "agent-b", "agent_type": "Explore", "background_tasks": []]),
                                        ("PostToolUse", call("Agent", "task-b"))])
        XCTAssertEqual(phases(other).suffix(6), [.permission, .permission, .permission, .permission, .permission, .permission],
                       "Another subagent's work does not answer this dialog")

        let continued = try play(opening + [("PreToolUse", call("Read", "a2", agent: "agent-a"))])
        XCTAssertEqual(continued.last?.session.phase, .running, "Declined with a comment: the same subagent goes on")

        let finished = try play(opening + [("SubagentStop", ["agent_id": "agent-a", "agent_type": "Explore", "background_tasks": []])])
        XCTAssertEqual(finished.last?.session.phase, .running, "Declined, and the subagent ended its work")
        XCTAssertTrue(finished.last!.pendingApprovals.isEmpty && finished.last!.unidentifiedApproval == nil)

        // The main conversation's dialog is not answered by a subagent working alongside.
        let main = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Agent", "task-b")), ("PreToolUse", call("WebFetch", "m1")),
                             ("PermissionRequest", request("WebFetch")), ("PreToolUse", call("Read", "b1", agent: "agent-b")),
                             ("PostToolUse", call("Read", "b1", agent: "agent-b")), ("PreToolUse", call("Read", "m2"))])
        XCTAssertEqual(phases(main).suffix(4), [.permission, .permission, .permission, .running])
    }

    /// The waiting count and notices follow the request, not the next reply.
    func testNoticesAndWaitingCountFollowADeclinedRequest() throws {
        var tracker = SessionNoticeTracker()
        var notices: [SessionNoticeKind] = [], waiting: [Int] = []
        let steps = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash")),
                              ("PreToolUse", call("Read", "y")), ("PostToolUse", call("Read", "y")), ("Stop", [:])])
        for (index, record) in steps.enumerated() {
            let now = start.addingTimeInterval(Double(index) + 0.5)
            let rows = SessionList.merge(catalog: [], events: [record.session], now: now)
            notices += tracker.update(rows, now: now).map(\.kind)
            waiting.append(SessionList.filter(rows, query: "", provider: nil, activeOnly: true, now: now)
                .filter { [.permission, .input].contains($0.effectivePhase(now: now)) }.count)
        }
        XCTAssertEqual(notices, [.permission, .completed])
        XCTAssertEqual(waiting, [0, 0, 1, 0, 0, 0])
    }

    /// The hook helper decodes the record again for every event.
    func testRequestsSurviveTheHelperBetweenEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r26-S2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func capture(_ name: String, _ extra: [String: Any]) throws -> SessionPhase? {
            var payload: [String: Any] = ["session_id": "parent-session", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
            payload.merge(extra) { $1 }
            try SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: root, client: .terminal,
                                     runtimePID: 4242, isInternal: { _ in false }, isAlive: { _ in true })
            return SessionHooks.load(at: root).first?.phase
        }
        XCTAssertEqual(try capture("UserPromptSubmit", [:]), .running)
        XCTAssertEqual(try capture("PreToolUse", call("WebFetch", "a")), .running)
        XCTAssertEqual(try capture("PreToolUse", call("Read", "r")), .running)
        XCTAssertEqual(try capture("PreToolUse", call("Bash", "s1", agent: "agent-a")), .running)
        XCTAssertEqual(try capture("PermissionRequest", request("WebFetch")), .permission)
        XCTAssertEqual(try capture("PermissionRequest", request("Bash", agent: "agent-a")), .permission)
        XCTAssertEqual(try capture("PostToolUse", call("Read", "r")), .permission, "A parallel call's completion")
        XCTAssertEqual(try capture("PostToolUse", call("WebFetch", "a")), .permission, "The subagent's dialog is still open")
        // Stop's background list may be missing; SubagentStop still ends its own dialogs.
        XCTAssertEqual(try capture("SubagentStop", ["agent_id": "agent-a", "agent_type": "Explore"]), .running)
        XCTAssertEqual(try capture("Stop", [:]), .ready)
    }

    /// Records written by earlier releases keep their wait until progress.
    func testOlderRecordsKeepTheirWaitUntilProgress() throws {
        var identified = try play([("UserPromptSubmit", [:]), ("PermissionRequest", ["tool_name": "Bash", "tool_use_id": "first"])]).last!
        identified.pendingApprovals = ["first", "second"]; identified.unidentifiedApproval = nil; identified.approvalVersion = 2
        let version2 = try JSONDecoder().decode(SessionRecord.self, from: stripped(identified))
        let v2 = try play([("PostToolUse", call("Bash", "first")), ("PostToolUse", call("Edit", "second"))], from: version2, at: 5)
        XCTAssertEqual(phases(v2), [.permission, .running])

        var legacy = identified
        legacy.pendingApprovals = ["Bash"]; legacy.approvalVersion = nil
        let version1 = try JSONDecoder().decode(SessionRecord.self, from: stripped(legacy))
        XCTAssertEqual(try play([("PreToolUse", call("Read", "y"))], from: version1, at: 5).last?.session.phase, .running)

        // Earlier releases read the current record: the summary fields stay in it.
        let current = try play([("UserPromptSubmit", [:]), ("PreToolUse", call("Bash", "x")), ("PermissionRequest", request("Bash"))]).last!
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        XCTAssertEqual(json["pendingApprovals"] as? [String], [])
        XCTAssertEqual(json["unidentifiedApproval"] as? Bool, true)
    }
    /// The record as an earlier release wrote it: without fields added later.
    private func stripped(_ record: SessionRecord) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "approvals"); json.removeValue(forKey: "runningTools")
        return try JSONSerialization.data(withJSONObject: json)
    }
}
