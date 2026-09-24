import XCTest
@testable import WeekleftCore

final class ClaudeBackgroundWorkTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let render: [String: Any] = ["id": "b1", "type": "shell", "status": "running", "description": "4K renders", "command": "npx remotion render src/entry.tsx Tour out.mp4"]
    let monitor: [String: Any] = ["id": "b2", "type": "monitor", "status": "running", "description": "renders finishing or failing"]
    let server: [String: Any] = ["id": "b3", "type": "shell", "status": "running", "description": "dev server", "command": "npm run dev -- --port 5173"]

    private func hook(_ name: String, _ extra: [String: Any] = [:], provider: ProviderID = .claude, after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "luna", "cwd": "/tmp/luna", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: provider, previous: previous, now: start.addingTimeInterval(seconds))
    }

    func testStopWithBackgroundWorkIsAPauseNotAnAnswer() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let stop = try hook("Stop", ["last_assistant_message": "Рендер идёт. Как закончится, пришлю.", "background_tasks": [render, monitor], "session_crons": []], after: prompt, at: 5)
        XCTAssertEqual(stop.session.phase, .running)
        XCTAssertEqual(stop.session.backgroundWork, BackgroundWork(commands: 1, monitors: 1))
        XCTAssertEqual(stop.session.effectivePhase(now: start.addingTimeInterval(6)), .running)
        XCTAssertNil(stop.session.tool)
        // A task event wakes Claude without a prompt: the known wait survives tool use.
        let woken = try hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"], after: stop, at: 60)
        XCTAssertEqual(woken.session.backgroundWork?.total, 2)
        let final = try hook("Stop", ["last_assistant_message": "Все пять роликов готовы.", "background_tasks": [], "session_crons": []], after: woken, at: 70)
        XCTAssertEqual(final.session.phase, .ready)
        XCTAssertNil(final.session.backgroundWork)
        // Tasks outlive a new prompt; only the pause itself ends.
        let prompted = try hook("UserPromptSubmit", after: stop, at: 80).session
        XCTAssertEqual(prompted.backgroundWork, BackgroundWork(commands: 1, monitors: 1))
        XCTAssertNil(prompted.awaitingBackground)
        XCTAssertEqual(prompted.activityTitle, L("Думает"))
    }

    func testOneNoticeAfterTheLastTaskInsteadOfOnePerTaskEvent() throws {
        var tracker = SessionNoticeTracker()
        var record: SessionRecord?
        var notices: [(Double, SessionNoticeKind)] = []
        func step(_ name: String, _ extra: [String: Any] = [:], at seconds: Double) throws {
            record = try hook(name, extra, after: record, at: seconds)
            let now = start.addingTimeInterval(seconds)
            notices += tracker.update([record!.session], now: now).map { (seconds, $0.kind) }
        }
        try step("UserPromptSubmit", at: 0)
        try step("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"], at: 1)
        try step("PostToolUse", ["tool_name": "Bash", "tool_use_id": "t1"], at: 2)
        try step("Stop", ["last_assistant_message": "Рендер идёт.", "background_tasks": [render, monitor]], at: 3)
        // Monitor events wake Claude: it checks a frame, says "Жду." and stops again.
        try step("PreToolUse", ["tool_name": "Read", "tool_use_id": "t2"], at: 30)
        try step("PostToolUse", ["tool_name": "Read", "tool_use_id": "t2"], at: 31)
        try step("Stop", ["last_assistant_message": "Два ролика в порядке. Жду остальные.", "background_tasks": [render, monitor]], at: 32)
        try step("Stop", ["last_assistant_message": "Жду.", "background_tasks": [monitor]], at: 50)
        try step("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t3"], at: 70)
        try step("PostToolUse", ["tool_name": "Bash", "tool_use_id": "t3"], at: 75)
        XCTAssertTrue(notices.isEmpty, "interim replies to task events must stay silent: \(notices)")
        try step("Stop", ["last_assistant_message": "Все ролики готовы, вот они.", "background_tasks": []], at: 80)
        XCTAssertEqual(notices.map(\.1), [.completed])
        XCTAssertEqual(notices.first?.0, 80)
    }

    func testServicesDoNotHoldTheAnswer() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let finishedTask: [String: Any] = ["id": "b4", "type": "subagent", "status": "completed"]
        let stop = try hook("Stop", ["last_assistant_message": "Сервер запущен: http://localhost:5173", "background_tasks": [server, finishedTask]], after: prompt, at: 5)
        XCTAssertEqual(stop.session.phase, .ready)
        XCTAssertNil(stop.session.backgroundWork)
        var tracker = SessionNoticeTracker()
        _ = tracker.update([prompt.session], now: start)
        XCTAssertEqual(tracker.update([stop.session], now: start.addingTimeInterval(5)).map(\.kind), [.completed])
    }

    func testQuestionsStillAskForInputAndOtherSourcesAreUnchanged() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let question = try hook("Stop", ["last_assistant_message": "Рендер идёт.\n\nДелаем вертикальные версии?", "background_tasks": [render]], after: prompt, at: 5)
        XCTAssertEqual(question.session.phase, .input)
        XCTAssertNil(question.session.awaitingBackground, "a question is not a background pause")
        XCTAssertEqual(question.session.backgroundWork, BackgroundWork(commands: 1), "the tasks still run")
        XCTAssertEqual(try hook("Stop", ["background_tasks": [render]], after: prompt, at: 5).session.phase, .running)
        XCTAssertEqual(try hook("Stop", ["background_tasks": "unexpected"], after: prompt, at: 5).session.phase, .ready)
        XCTAssertEqual(try hook("Stop", after: prompt, at: 5).session.phase, .ready)
        let codex = try hook("UserPromptSubmit", provider: .codex, after: nil, at: 0)
        XCTAssertEqual(try hook("Stop", ["background_tasks": [render]], provider: .codex, after: codex, at: 5).session.phase, .ready)
    }

    func testBackgroundWaitKeepsOnlyCountsByKind() throws {
        let agent: [String: Any] = ["id": "a1", "type": "subagent", "status": "running", "description": "Private project notes", "agent_type": "Explore"]
        let mcp: [String: Any] = ["id": "m1", "type": "MCP task", "status": "running", "server": "x", "tool": "y"]
        let stop = try hook("Stop", ["background_tasks": [render, render, monitor, agent, mcp, server]], after: try hook("UserPromptSubmit", after: nil, at: 0), at: 5)
        XCTAssertEqual(stop.session.backgroundWork, BackgroundWork(commands: 2, agents: 1, monitors: 1, other: 1))
        XCTAssertEqual(stop.session.activityTitle, L("В фоне"))
        let stored = String(decoding: try JSONEncoder().encode(stop), as: UTF8.self)
        for secret in ["remotion", "Private project notes", "Explore", "renders finishing"] { XCTAssertFalse(stored.contains(secret), secret) }
        XCTAssertEqual(L10n.text("В фоне", language: "en", arguments: []), "In background")
    }

    /// Catalogued sessions (listed by `claude agents --json`) must keep the
    /// hook-only background count and failure reason after the merge.
    func testCatalogMergeKeepsBackgroundWorkAndFailureReason() throws {
        func catalog(_ phase: SessionPhase, at seconds: Double) -> AgentSession {
            AgentSession(provider: .claude, sessionID: "luna", title: "Luna", cwd: "/tmp/luna", client: .desktop, phase: phase,
                         updatedAt: start.addingTimeInterval(seconds), observedAt: start.addingTimeInterval(seconds), evidence: .catalog, runtimeConfirmed: true)
        }
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let paused = try hook("Stop", ["background_tasks": [render, monitor]], after: prompt, at: 5).session
        let merged = try XCTUnwrap(SessionList.merge(catalog: [catalog(.running, at: 1)], events: [paused], now: start.addingTimeInterval(6)).first)
        XCTAssertEqual(merged.phase, .running)
        XCTAssertEqual(merged.backgroundWork, BackgroundWork(commands: 1, monitors: 1))
        // A newer busy poll keeps the known wait.
        let polled = try XCTUnwrap(SessionList.merge(catalog: [catalog(.running, at: 9)], events: [paused], now: start.addingTimeInterval(10)).first)
        XCTAssertEqual(polled.backgroundWork, BackgroundWork(commands: 1, monitors: 1))

        let failed = try hook("StopFailure", ["error": "rate_limit", "last_assistant_message": "You've hit your session limit"], after: prompt, at: 5).session
        let failedRow = try XCTUnwrap(SessionList.merge(catalog: [catalog(.running, at: 1)], events: [failed], now: start.addingTimeInterval(6)).first)
        XCTAssertEqual(failedRow.phase, .failed)
        XCTAssertEqual(failedRow.failure, .limit)
        let idleAfter = try XCTUnwrap(SessionList.merge(catalog: [catalog(.idle, at: 9)], events: [failed], now: start.addingTimeInterval(10)).first)
        XCTAssertEqual(idleAfter.phase, .failed)
        XCTAssertEqual(idleAfter.failure, .limit)
    }

    /// An idle catalog poll during a background pause is not an interruption:
    /// Claude will wake when its tasks finish, and the final reply is announced once.
    func testIdleCatalogDuringBackgroundPauseKeepsTheTaskWorking() throws {
        func catalog(_ phase: SessionPhase, at seconds: Double) -> AgentSession {
            AgentSession(provider: .claude, sessionID: "luna", title: "Luna", cwd: "/tmp/luna", client: .desktop, phase: phase,
                         updatedAt: start.addingTimeInterval(seconds), observedAt: start.addingTimeInterval(seconds), evidence: .catalog, runtimeConfirmed: true)
        }
        var tracker = SessionNoticeTracker()
        var notices: [SessionNoticeKind] = []
        func observe(_ catalogRow: AgentSession, _ event: AgentSession, at seconds: Double) throws -> AgentSession {
            let now = start.addingTimeInterval(seconds)
            let row = try XCTUnwrap(SessionList.merge(catalog: [catalogRow], events: [event], now: now).first)
            notices += tracker.update([row], now: now).map(\.kind)
            return row
        }
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        _ = try observe(catalog(.running, at: 1), prompt.session, at: 2)
        let paused = try hook("Stop", ["background_tasks": [render]], after: prompt, at: 5)
        let during = try observe(catalog(.idle, at: 15), paused.session, at: 16)
        XCTAssertEqual(during.effectivePhase(now: start.addingTimeInterval(16)), .running)
        XCTAssertEqual(during.backgroundWork, BackgroundWork(commands: 1))
        XCTAssertTrue(notices.isEmpty)
        let final = try hook("Stop", ["last_assistant_message": "Готово.", "background_tasks": []], after: paused, at: 80)
        _ = try observe(catalog(.idle, at: 75), final.session, at: 81)
        XCTAssertEqual(notices, [.completed])
    }

    /// Long renders keep the task working for up to an hour without new events,
    /// then the pause expires like any stale observation.
    func testBackgroundPauseOutlivesTheHookFreshnessWindowWithinABound() throws {
        let paused = try hook("Stop", ["background_tasks": [render]], after: try hook("UserPromptSubmit", after: nil, at: 0), at: 5).session
        XCTAssertEqual(paused.effectivePhase(now: start.addingTimeInterval(5 + 1200)), .running)
        XCTAssertEqual(paused.effectivePhase(now: start.addingTimeInterval(5 + 3601)), .unknown)
        let ordinary = try hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t"], after: nil, at: 0).session
        XCTAssertEqual(ordinary.effectivePhase(now: start.addingTimeInterval(601)), .unknown)
    }

    /// While Claude still works, launched background tasks are counted as they start.
    func testLaunchesDuringTheTurnAreCounted() throws {
        var record = try hook("UserPromptSubmit", after: nil, at: 0)
        func post(_ tool: String, input: [String: Any], response: [String: Any] = [:], at seconds: Double) throws {
            record = try hook("PostToolUse", ["tool_name": tool, "tool_use_id": "t\(seconds)", "tool_input": input, "tool_response": response],
                              after: record, at: seconds)
        }
        try post("Bash", input: ["command": "swift build"], at: 1)
        XCTAssertNil(record.session.backgroundWork, "foreground commands are not background work")
        try post("Bash", input: ["command": "npx remotion render entry.tsx Tour out.mp4", "run_in_background": true], at: 2)
        try post("Agent", input: ["description": "Audit core"], response: ["status": "async_launched", "agentId": "a1"], at: 3)
        try post("Monitor", input: ["description": "renders finishing"], at: 4)
        try post("Bash", input: ["command": "npm run dev", "run_in_background": true], at: 5)
        XCTAssertEqual(record.session.backgroundWork, BackgroundWork(commands: 1, agents: 1, monitors: 1), "services are not counted")
        XCTAssertEqual(record.session.phase, .running)
        XCTAssertNil(record.session.awaitingBackground)
        XCTAssertEqual(record.session.effectivePhase(now: start.addingTimeInterval(5 + 601)), .unknown, "an active turn keeps the normal freshness")
    }

    /// SubagentStop reports the exact in-flight set without touching the turn.
    func testSubagentStopUpdatesTheCountWithoutChangingTheTurn() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let launched = try hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "a", "tool_input": ["run_in_background": true]], after: prompt, at: 1)
        let working = try hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "b"], after: launched, at: 2)
        let finished = try hook("SubagentStop", ["agent_id": "a1", "agent_type": "general-purpose", "background_tasks": [monitor]], after: working, at: 30)
        XCTAssertEqual(finished.session.backgroundWork, BackgroundWork(monitors: 1))
        XCTAssertEqual(finished.session.tool, "Bash")
        XCTAssertEqual(finished.session.observedAt, working.session.observedAt)
        XCTAssertEqual(try hook("SubagentStop", ["background_tasks": []], after: working, at: 31).session.backgroundWork, nil)
        XCTAssertThrowsError(try hook("SubagentStop", ["background_tasks": []], after: nil, at: 0), "no record is created for an unknown session")
        XCTAssertTrue(SessionHooks.events(.claude).contains("SubagentStop"))
    }

    /// Esc during a working turn still ends it, even with background tasks running.
    func testIdleCatalogDuringAnActiveTurnStillInterrupts() throws {
        let catalogRow = AgentSession(provider: .claude, sessionID: "luna", title: "Luna", cwd: "/tmp/luna", client: .desktop, phase: .idle,
                                      updatedAt: start.addingTimeInterval(20), observedAt: start.addingTimeInterval(20), evidence: .catalog, runtimeConfirmed: true)
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let launched = try hook("PostToolUse", ["tool_name": "Monitor", "tool_use_id": "m", "tool_input": [:]], after: prompt, at: 5)
        let row = try XCTUnwrap(SessionList.merge(catalog: [catalogRow], events: [launched.session], now: start.addingTimeInterval(21)).first)
        XCTAssertEqual(row.phase, .interrupted)
    }

    func testServiceCommands() {
        let services = [
            "npm run dev", "pnpm dev", "yarn start", "bun run preview", "npx vite", "vite --port 5173", "vite dev",
            "next dev -p 3000", "npx remotion studio", "python3 -m http.server 8000", "uvicorn app:app --reload",
            "flask run", "tail -f /tmp/x.log", "tail -n 50 -F log", "log stream --predicate 'process == \"x\"'",
            "watch -n 2 ls", "npx tsc --watch", "docker compose up", "ssh -N -L 8080:localhost:80 host",
            "sleep infinity", "caffeinate -dims", "cd site && bundle exec jekyll serve", "cd app\nnpm start",
        ]
        let finite = [
            "sleep 25 && echo finished", "npm run build", "vite build", "npx remotion render src/entry.tsx Tour out.mp4",
            "swift test --filter Sessions", "docker compose up -d", "caffeinate -t 600 ./render.sh", "tail -n 20 log",
            "until grep -q DONE log; do sleep 2; done", "python3 render.py --watchdog 5", "grep -r watch src",
            "xcodebuild -scheme Weekleft build",
        ]
        for command in services { XCTAssertTrue(ClaudeBackgroundWork.isService(command), command) }
        for command in finite { XCTAssertFalse(ClaudeBackgroundWork.isService(command), command) }
    }
}
