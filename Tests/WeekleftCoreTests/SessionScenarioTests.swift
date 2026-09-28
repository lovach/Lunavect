import XCTest
@testable import WeekleftCore

/// Scenarios from reports/02-sessions.md §5 and the session matrix in
/// reports/06-tests-scripts-scenarios.md §6.2 that had no test. Temporary
/// folders and injected process trees only.
final class SessionScenarioTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionScenario-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func payload(_ id: String, _ name: String, _ extra: [String: Any] = [:], cwd: String = "/Users/fixture/Projects/lunavect") throws -> Data {
        var payload: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": cwd]
        payload.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: payload)
    }
    private func event(_ id: String, _ name: String, _ extra: [String: Any] = [:], cwd: String = "/Users/fixture/Projects/lunavect",
                       provider: ProviderID = .claude, after previous: SessionRecord? = nil, at seconds: Double, client: SessionClient = .unknown) throws -> SessionRecord {
        try SessionRecord.event(payload(id, name, extra, cwd: cwd), provider: provider, previous: previous, now: start.addingTimeInterval(seconds), client: client)
    }

    // §5.4 / matrix S5: 200 tool events from five sessions, delivered in parallel
    // like Claude's concurrent hooks, under the capture lock.
    func testHookStormLeavesOneConsistentRecordPerSessionAndOneCompletionEach() throws {
        let root = try directory()
        let ids = (0..<5).map { "storm-\($0)" }
        for id in ids { try SessionHooks.capture(payload(id, "UserPromptSubmit"), provider: .claude, at: root, isInternal: { _ in false }) }
        var tracker = SessionNoticeTracker()
        _ = tracker.update(SessionHooks.load(at: root), now: Date())
        let failures = OSAllocatedUnfairLockBox()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let id = ids[index % 5], tool = "t\(index / 2)"
            let name = index % 2 == 0 ? "PreToolUse" : "PostToolUse"
            do {
                try SessionHooks.capture(payload(id, name, ["tool_name": index % 4 < 2 ? "Bash" : "Read", "tool_use_id": tool]),
                                         provider: .claude, at: root, isInternal: { _ in false })
            } catch { failures.append(error) }
        }
        XCTAssertTrue(failures.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), Set(ids.map { "claude-\($0).json" }), "No torn, temporary or duplicate files")
        for id in ids {
            let data = try Data(contentsOf: root.appendingPathComponent("claude-\(id).json"))
            let record = try JSONDecoder().decode(SessionRecord.self, from: data)
            XCTAssertEqual(record.session.phase, .running, id)
            XCTAssertTrue(record.pendingApprovals.isEmpty, id)
            XCTAssertEqual(record.session.hasTaskActivity, true)
        }
        XCTAssertTrue(tracker.update(SessionHooks.load(at: root), now: Date()).isEmpty, "Tool events are not notices")
        for id in ids { try SessionHooks.capture(payload(id, "Stop", ["last_assistant_message": "Готово."]), provider: .claude, at: root, isInternal: { _ in false }) }
        let notices = tracker.update(SessionHooks.load(at: root), now: Date())
        XCTAssertEqual(notices.map(\.kind), Array(repeating: .completed, count: 5))
        XCTAssertEqual(Set(notices.map(\.session.sessionID)), Set(ids))
        XCTAssertTrue(tracker.update(SessionHooks.load(at: root), now: Date()).isEmpty, "Reading the same Stop again is silent")
    }

    // §5.4: reordered delivery within the same second.
    func testReorderedToolEventsAndALateSessionStartKeepTheTurn() throws {
        let prompt = try event("order", "UserPromptSubmit", at: 0)
        let post = try event("order", "PostToolUse", ["tool_name": "Bash", "tool_use_id": "t1"], after: prompt, at: 1)
        let pre = try event("order", "PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"], after: post, at: 1)
        XCTAssertEqual(pre.session.phase, .running)
        XCTAssertEqual(pre.session.turnStartedAt, start)
        XCTAssertTrue(pre.pendingApprovals.isEmpty)
        let late = try event("order", "SessionStart", ["source": "startup"], after: pre, at: 1)
        XCTAssertEqual(late.session.phase, .running, "A startup hook finishing after the prompt cannot reset the turn")
        XCTAssertEqual(late.session.turnStartedAt, start)
    }

    // §5.3 / matrix S3: two terminals in one project, hooks only (no PID).
    func testTwoSessionsInOneFolderStayDistinctEverywhere() throws {
        let first = try event("first-session", "UserPromptSubmit", at: 0).session
        let second = try event("second-session", "Stop", ["last_assistant_message": "Готово."], at: 1).session
        let rows = SessionList.merge(catalog: [], events: [first, second], now: start.addingTimeInterval(2))
        XCTAssertEqual(Set(rows.map(\.id)), ["claude:first-session", "claude:second-session"])
        XCTAssertEqual(Set(rows.map(\.displayTitle)), ["lunavect"], "Same folder, same fallback title")
        XCTAssertEqual(rows.map(\.phase), [.running, .ready])

        var visibility = try SessionVisibility(url: directory().appendingPathComponent("hidden-sessions.json"), now: start)
        try visibility.hide(second, now: start.addingTimeInterval(2))
        XCTAssertEqual(visibility.visible(rows).map(\.sessionID), ["first-session"])
        var arrangement = SessionArrangement()
        arrangement.pinned.insert(first.id)
        XCTAssertEqual(arrangement.arranged(rows).first?.id, first.id)
        XCTAssertFalse(arrangement.pinned.contains(second.id))

        var tracker = ActivityTracker()
        tracker.observe(rows, now: start.addingTimeInterval(2))
        tracker.observe(rows, now: start.addingTimeInterval(7))
        XCTAssertEqual(tracker.details.records.values.map(\.sessionID), ["first-session"], "Only the working session gains time")

        // The same identifier from both providers is two sessions.
        let codex = try event("first-session", "UserPromptSubmit", provider: .codex, at: 0).session
        XCTAssertEqual(SessionList.merge(catalog: [], events: [first, codex], now: start.addingTimeInterval(2)).count, 2)
    }

    // §5.9: sleep through a completion, then wake.
    func testSleepAndWakeNeitherReplayNorInventNotices() throws {
        var tracker = SessionNoticeTracker()
        let prompt = try event("sleeper", "UserPromptSubmit", at: 0)
        let catalogRow = AgentSession(provider: .claude, sessionID: "sleeper", title: "Night task", cwd: "/Users/fixture/Projects/lunavect",
                                      phase: .running, updatedAt: start, observedAt: start.addingTimeInterval(5))
        XCTAssertTrue(tracker.update(SessionList.merge(catalog: [catalogRow], events: [prompt.session], now: start.addingTimeInterval(5)),
                                     now: start.addingTimeInterval(5)).isEmpty)
        // Stop was written ten minutes into an eight-hour sleep.
        let stop = try event("sleeper", "Stop", ["last_assistant_message": "Готово."], after: prompt, at: 600)
        let wake = start.addingTimeInterval(8 * 3600)
        XCTAssertEqual(catalogRow.effectivePhase(now: wake), .unknown, "Pre-sleep catalog rows have expired")
        let afterWake = SessionList.merge(catalog: [catalogRow], events: [stop.session], now: wake)
        XCTAssertTrue(tracker.update(afterWake, now: wake).isEmpty, "A completion from hours ago is not announced on wake")
        // New work after wake is announced normally.
        let again = try event("sleeper", "UserPromptSubmit", after: stop, at: 8 * 3600 + 5)
        _ = tracker.update([again.session], now: wake.addingTimeInterval(5))
        let done = try event("sleeper", "Stop", ["last_assistant_message": "Готово."], after: again, at: 8 * 3600 + 30)
        XCTAssertEqual(tracker.update([done.session], now: wake.addingTimeInterval(30)).map(\.kind), [.completed])
    }

    // §5.11: `codex` bundled in ChatGPT.app, started from a Terminal tab.
    func testBundledCodexCLIInATerminalIsATerminalSession() {
        let tree: [Int32: (String, Int32)] = [
            500: ("/Applications/ChatGPT.app/Contents/Resources/codex", 400),
            400: ("/bin/zsh", 300),
            300: ("/usr/bin/login", 200),
            200: ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", 1),
            610: ("/Applications/ChatGPT.app/Contents/Resources/codex", 600),
            600: ("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", 1),
        ]
        func client(_ pid: Int32, terminal: String = "") -> SessionClient {
            SessionProcess.client(parentPID: pid, entrypoint: "", terminal: terminal, path: { tree[$0]?.0 }, parent: { tree[$0]?.1 },
                                  bundleIdentifier: { _ in nil })
        }
        XCTAssertEqual(client(500), .terminal, "The bundled binary says nothing about its host")
        XCTAssertEqual(client(610), .desktop, "The same binary run by the app is the Desktop client")
        XCTAssertEqual(client(900, terminal: "Apple_Terminal"), .terminal, "Unreadable ancestry falls back to the terminal marker")
        XCTAssertEqual(client(900), .unknown)
    }

    // Matrix S9: one Codex thread used from Codex.app and resumed in a CLI.
    func testOneCodexThreadFromDesktopAndCLIIsOneRowFollowingTheLatestClient() throws {
        let root = try directory()
        let id = "019a5f0e-1d2c-7b3a-8e4f-5a6b7c8d9e0f"
        let catalog = try XCTUnwrap(SessionParser.codex(JSONSerialization.data(withJSONObject: ["data": [[
            "id": id, "name": "Refactor", "cwd": "/Users/fixture/Projects/codex", "source": "vscode", "updatedAt": start.timeIntervalSince1970,
            "status": ["type": "idle"]]]]), now: start).first)
        try SessionHooks.capture(payload(id, "UserPromptSubmit"), provider: .codex, at: root, client: .desktop, isInternal: { _ in false })
        var rows = SessionList.merge(catalog: [catalog], events: SessionHooks.load(at: root), now: Date())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.client, .desktop)
        try SessionHooks.capture(payload(id, "UserPromptSubmit"), provider: .codex, at: root, client: .terminal,
                                 terminal: ("/dev/ttys004", "Terminal"), isInternal: { _ in false })
        rows = SessionList.merge(catalog: [catalog], events: SessionHooks.load(at: root), now: Date())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.client, .terminal)
        XCTAssertEqual(rows.first?.terminalTTY, "/dev/ttys004", "Navigation goes to the live CLI tab")
        try SessionHooks.capture(payload(id, "Stop"), provider: .codex, at: root, client: .desktop, isInternal: { _ in false })
        rows = SessionList.merge(catalog: [catalog], events: SessionHooks.load(at: root), now: Date())
        XCTAssertEqual(rows.first?.client, .desktop)
        XCTAssertNil(rows.first?.terminalTTY, "Back in the app, the old tab is not a destination")
    }
}

/// A tiny thread-safe error sink for concurrentPerform.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func append(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return errors.isEmpty }
}
