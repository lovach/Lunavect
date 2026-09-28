import XCTest
import Combine
import os
@testable import Weekleft
@testable import WeekleftCore

/// Store-level regressions from the 2026-09-28 session audit (reports/02-sessions.md).
/// Every store is isolated: injected clock, temporary folder, fixture catalogs.
@MainActor final class SessionPipelineAuditTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionPipelineAudit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store(_ dependencies: SessionStore.Dependencies = .init(), directory: URL? = nil, now: @escaping () -> Date) throws -> SessionStore {
        let suite = "SessionPipelineAudit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SessionStore(directory: try directory ?? self.directory(), defaults: defaults, isolated: true, now: now, dependencies: dependencies)
    }
    private func claudeRows(_ rows: [[String: Any]], at date: Date) throws -> [AgentSession] {
        try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: date)
    }

    // S-11
    func testChangedCatalogShapeIsReportedAndKeepsTheLastRows() async throws {
        var clock = instant, renamed = false
        let row: [String: Any] = ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "name": "Fix widgets",
                                  "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "startedAt": 1_795_000_100_000, "status": "busy"]
        let sessions = try store(.init(catalog: { _, _, _, _ in
            var shaped = row
            if renamed { shaped["session_id"] = shaped.removeValue(forKey: "sessionId") }
            return (try self.claudeRows([shaped], at: clock), false)
        }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        XCTAssertEqual(sessions.currentSessions.map(\.title), ["Fix widgets"])
        clock += 15; renamed = true
        await sessions.refresh()
        XCTAssertEqual(sessions.typedIssues[.claude]?.code, "claude.sessionCatalog.unsupportedResponse")
        XCTAssertEqual(sessions.diagnosticEntries.last?.issue.code, "claude.sessionCatalog.unsupportedResponse")
        XCTAssertEqual(sessions.currentSessions.map(\.title), ["Fix widgets"], "The last listing remains until it expires")
    }

    // S-02 / §5.2 / matrix S2: retained background history on the owner's Mac:
    // done/stopped/failed rows 30 minutes old, blocked rows from July.
    private func historyCatalog(at date: Date) throws -> [AgentSession] {
        let recent = date.addingTimeInterval(-1800).timeIntervalSince1970 * 1000
        let july = date.addingTimeInterval(-80 * 86400).timeIntervalSince1970 * 1000
        var rows: [[String: Any]] = ["done", "stopped", "failed", "done"].enumerated().map { index, state in
            ["id": "bg-\(index)", "cwd": "/Users/fixture/Projects/lunavect", "kind": "background", "name": "Task \(index)",
             "sessionId": "history-\(index)", "startedAt": recent, "state": state]
        }
        rows += (0..<3).map { index in
            ["id": "old-\(index)", "cwd": "/Users/fixture/Projects/lunavect", "kind": "background", "name": "July \(index)",
             "sessionId": "july-\(index)", "startedAt": july, "state": "blocked"]
        }
        return try claudeRows(rows, at: date)
    }

    func testRetainedBackgroundHistoryIsNeverAutoHidden() async throws {
        for minutes in [5, 10, 20] {
            var clock = instant
            let sessions = try store(.init(catalog: { _, _, _, _ in (try self.historyCatalog(at: clock), false) }), now: { clock })
            sessions.useProviders([.claude])
            sessions.autoHideMinutes = minutes
            for _ in 0..<8 {
                await sessions.refresh()
                XCTAssertEqual(sessions.hiddenCount, 0, "\(minutes) min: history never enters hidden-sessions.json")
                XCTAssertTrue(sessions.currentSessions.isEmpty, "History is not a current session")
                XCTAssertEqual(sessions.activeCount, 0, "July blocked rows are not waiting")
                clock += 300
            }
            sessions.stop()
        }
    }

    func testHiddenHistoryIsNotKeptAliveByTheCatalogListingIt() async throws {
        var clock = instant
        let root = try directory()
        let sessions = try store(.init(catalog: { _, _, _, _ in (try self.historyCatalog(at: clock), false) }), directory: root, now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        let done = try XCTUnwrap(sessions.sessions.first { $0.sessionID == "history-0" })
        try sessions.hide(done)
        XCTAssertEqual(sessions.hiddenIDs, [done.id], "An explicit hide of history stays manageable")
        for _ in 0..<37 { clock += 86400; await sessions.refresh() }
        XCTAssertEqual(sessions.hiddenIDs, [], "Re-listed history does not refresh seenAt; the entry expires after 35 days")
        XCTAssertEqual(try SessionVisibility(url: root.appendingPathComponent("hidden-sessions.json"), now: clock).hidden, [])
    }

    // Decision 11: only a row shown as current starts an inactivity interval.
    func testSessionThatEndedBeforeItWasShownIsNotArchived() throws {
        var clock = instant
        let sessions = try store(now: { clock })
        defer { sessions.stop() }
        sessions.autoHideMinutes = 5
        let prompt = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "ended", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: clock.addingTimeInterval(-60))
        let ended = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "ended", "hook_event_name": "SessionEnd", "cwd": "/Users/fixture/Projects/lunavect", "reason": "prompt_input_exit"]),
            provider: .claude, previous: prompt, now: clock.addingTimeInterval(-50))
        for _ in 0..<3 {
            sessions.acceptSessions([ended.session], now: clock)
            clock += 600
        }
        XCTAssertEqual(sessions.hiddenCount, 0, "A finished session is not in the panel, so it is not archived either")
        XCTAssertTrue(sessions.currentSessions.isEmpty)
    }

    /// Decision 11 keeps `--all` for one reason: a background task observed
    /// working still announces its completion once it becomes history.
    func testBackgroundCompletionIsStillAnnouncedAfterHistoryLeftTheMerge() async throws {
        var clock = instant, state = "working"
        let sessions = try store(.init(catalog: { _, _, _, _ in
            (try self.claudeRows([["id": "bg-1", "cwd": "/Users/fixture/Projects/lunavect", "kind": "background", "name": "Render",
                                   "sessionId": "render-1", "startedAt": 1_795_000_000_000, "state": state]], at: clock), false)
        }), now: { clock })
        let suite = "SessionPipelineAudit.Features." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var played: [SessionNoticeKind] = []
        let features = AppFeatures(defaults: defaults, now: { clock }, playSound: { played.append($0) })
        features.sounds = true; features.banners = false
        let notices = sessions.observations.sink { features.observe($0.rows, at: $0.date) }
        defer { notices.cancel(); features.stop(); sessions.stop(); defaults.removePersistentDomain(forName: suite) }
        sessions.useProviders([.claude])
        sessions.autoHideMinutes = 5
        await sessions.refresh()
        XCTAssertEqual(sessions.activeCount, 1)
        clock += 15; state = "done"
        await sessions.refresh()
        XCTAssertEqual(played, [.completed])
        XCTAssertTrue(sessions.currentSessions.isEmpty)
        clock += 900; await sessions.refresh()
        XCTAssertEqual(played, [.completed], "Re-listing the finished task does not replay it")
        XCTAssertEqual(sessions.hiddenCount, 0)
    }

    // S-08: at the idle cadence (45 s) one failed or timed-out catalog read
    // must not blank catalog-only rows before the next poll can confirm them.
    func testOneFailedIdlePollDoesNotBlankCatalogOnlyRows() async throws {
        var clock = instant, fails = false
        let rows: [[String: Any]] = [
            ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "name": "Idle task",
             "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "startedAt": 1_795_000_100_000, "status": "idle"],
            ["pid": 51_300, "cwd": "/Users/fixture/Projects/site", "kind": "interactive", "name": "Waiting task",
             "sessionId": "6e8b5b44-2d2f-4c1d-9b71-7a3e8d2c0f12", "startedAt": 1_795_000_200_000, "status": "waiting"],
        ]
        let sessions = try store(.init(catalog: { _, _, _, _ in
            if fails { throw SessionError.timeout }
            return (try self.claudeRows(rows, at: clock), false)
        }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        XCTAssertEqual(sessions.currentSessions.count, 2)
        clock += 45; fails = true
        await sessions.refresh()
        for seconds in [61.0, 90, 105] {
            clock = instant.addingTimeInterval(seconds); await sessions.readEvents()
            XCTAssertEqual(sessions.currentSessions.count, 2, "\(seconds) s: one failure is not evidence that sessions ended")
            XCTAssertEqual(sessions.activeCount, 1)
        }
        XCTAssertEqual(AgentSession.catalogLifetime, 2 * SessionPolling.idleCatalogInterval + 30)
        clock = instant.addingTimeInterval(AgentSession.catalogLifetime); await sessions.readEvents()
        XCTAssertEqual(sessions.currentSessions.count, 0, "A source that stays unavailable still expires its rows")
        clock += 1; fails = false
        await sessions.refresh()
        XCTAssertEqual(sessions.currentSessions.count, 2)
    }

    // S-05 / §5.17: the local event timer (every 1-5 s) usually delivers the
    // first acceptSessions before the catalogs (up to 12 + 3 s for Codex).
    func testDailyOrganizationWaitsForEveryCatalogInsteadOfTheFirstTimerTick() async throws {
        let root = try directory()
        var visibility = try SessionVisibility(url: root.appendingPathComponent("hidden-sessions.json"), now: instant)
        let old = instant.addingTimeInterval(-40 * 86400)
        for id in ["gone-claude", "gone-codex"] {
            let provider: ProviderID = id.hasSuffix("claude") ? .claude : .codex
            try visibility.hide(AgentSession(provider: provider, sessionID: id, title: id, cwd: "/Users/fixture", phase: .ready,
                                             updatedAt: old, observedAt: old), now: old)
        }
        var clock = instant
        let sessions = try store(.init(catalog: { provider, _, _, _ in
            if provider == .codex { throw SessionError.timeout }
            return ([], false)
        }), directory: root, now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude, .codex])
        XCTAssertEqual(sessions.hiddenIDs.count, 2)
        sessions.acceptSessions([], now: clock)
        XCTAssertEqual(sessions.hiddenIDs.count, 2, "Without any catalog nothing can prove absence")
        clock += 10
        await sessions.refresh()
        XCTAssertEqual(sessions.hiddenIDs, ["codex:gone-codex"],
                       "The check runs once the catalogs have answered; a failed Codex read proves nothing")
    }

    // S-03: a rejected SubagentStop raise reaches the store's diagnostics once,
    // as a fixed code with counts only.
    func testRejectedBackgroundRaiseBecomesOneDiagnosticEntry() async throws {
        var clock = instant
        func hook(_ name: String, _ extra: [String: Any] = [:], after previous: SessionRecord?, at date: Date) throws -> SessionRecord {
            var payload: [String: Any] = ["session_id": "audit", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": name]
            payload.merge(extra) { $1 }
            return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: previous, now: date)
        }
        let tasks: [[String: Any]] = [["id": "a1", "type": "subagent", "status": "running"], ["id": "b1", "type": "shell", "status": "running"]]
        var record = try hook("SubagentStop", ["background_tasks": tasks], after: hook("UserPromptSubmit", after: nil, at: clock), at: clock.addingTimeInterval(1))
        let sessions = try store(.init(events: { _, _, _ in [record.session] }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.readEvents(); clock += 2; await sessions.readEvents()
        XCTAssertEqual(sessions.diagnosticEntries.count, 1)
        XCTAssertEqual(sessions.diagnosticEntries.first?.issue.code, "claude.sessionCatalog.unsupportedResponse")
        XCTAssertEqual(sessions.diagnosticEntries.first?.hook, HookDiagnostic(kind: .backgroundCountRaised, at: instant.addingTimeInterval(1),
                                                                              reported: BackgroundWork(commands: 1, agents: 1)))
        XCTAssertNil(sessions.typedIssues[.claude], "A diagnostic, not a connection issue")
        XCTAssertEqual(sessions.sessions.first?.backgroundWork, nil, "No badge")
        record = try hook("SubagentStop", ["background_tasks": tasks], after: record, at: clock)
        await sessions.readEvents()
        XCTAssertEqual(sessions.diagnosticEntries.count, 2, "A later rejected report is a new entry")
    }

    // S-09: a record set aside by the hook helper becomes one diagnostic entry.
    func testUnreadableRecordFactReachesDiagnostics() async throws {
        var row = AgentSession(provider: .claude, sessionID: "damaged", title: "", cwd: "/Users/fixture", phase: .running,
                               updatedAt: instant, observedAt: instant, evidence: .hook, runtimeConfirmed: true)
        row.hookDiagnostic = HookDiagnostic(kind: .unreadableRecord, at: instant)
        let sessions = try store(.init(events: { _, _, _ in [row] }), now: { self.instant })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.readEvents(); await sessions.readEvents()
        XCTAssertEqual(sessions.diagnosticEntries.map(\.hook?.kind), [.unreadableRecord])
        XCTAssertNil(sessions.typedIssues[.claude])
    }

    // S-13 / A-02 / §5.8: the menu-bar waiting count clears as soon as the
    // complete catalog and the process table agree the client is gone.
    func testKilledClientsWaitLeavesCountersActivityAndAwakeAtOnce() async throws {
        var clock = instant, alive = true
        var permission = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "killed", "hook_event_name": "PermissionRequest", "tool_use_id": "t1", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: clock, client: .terminal).session
        permission.runtimePID = 4242
        var observed: [SessionPhase] = []
        let sessions = try store(.init(catalog: { _, _, _, _ in ([], false) }, events: { _, _, _ in [permission] },
                                       isProcessAlive: { _ in alive }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        sessions.onObservation = { rows, _ in observed.append(rows.first?.effectivePhase(now: clock) ?? .unknown) }
        await sessions.refresh()
        XCTAssertEqual(sessions.activeCount, 1, "Hooks-only wait of a live client")
        clock += 20; alive = false
        await sessions.refresh()
        XCTAssertEqual(sessions.activeCount, 0, "Not ten minutes later")
        XCTAssertEqual(observed.last, .interrupted)
        XCTAssertEqual(sessions.sessions.first?.phase, .interrupted)
    }

    // R2-02: the "Stopped" decision survives one failed `claude agents` read
    // (timeout, CLI update, changed format): counters, activity and Keep Awake
    // do not see the killed client working again for up to ten minutes.
    func testStoppedClientIsNotRevivedByAFailedCatalogRead() async throws {
        var clock = instant, failing = false
        var working = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "killed", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: clock, client: .terminal).session
        working.runtimePID = 4242
        var observed: [SessionPhase] = []
        let sessions = try store(.init(catalog: { _, _, _, _ in
            if failing { throw SessionError.timeout }
            return ([], false)
        }, events: { _, _, _ in [working] }, isProcessAlive: { _ in false }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        sessions.onObservation = { rows, _ in observed.append(rows.first?.effectivePhase(now: clock) ?? .unknown) }
        await sessions.refresh()
        XCTAssertEqual(sessions.sessions.first?.phase, .interrupted)
        XCTAssertEqual(sessions.activeCount, 0)
        clock += 15; failing = true
        await sessions.refresh()
        XCTAssertNotNil(sessions.typedIssues[.claude], "The failed read is reported")
        XCTAssertEqual(sessions.sessions.first?.phase, .interrupted, "One failed read does not resurrect the killed client")
        XCTAssertEqual(sessions.activeCount, 0)
        XCTAssertFalse(observed.contains(.running), "Activity and Keep Awake never saw it working again")
        // A new event of that session is new evidence, even while the catalog still fails.
        clock += 15
        working = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "killed", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: clock, client: .terminal).session
        await sessions.readEvents()
        XCTAssertEqual(sessions.sessions.first?.phase, .running)
    }

    // Matrix S6: without a catalog PID (Codex CLI hooks) the freshness limits
    // still end a lost SessionEnd within a bound.
    func testHookOnlySessionWithoutSessionEndLeavesTheCountsWithinItsFreshnessLimit() throws {
        var clock = instant
        let sessions = try store(now: { clock })
        defer { sessions.stop() }
        sessions.autoHideMinutes = 5
        let running = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "codex-cli", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/codex"]),
            provider: .codex, previous: nil, now: clock).session
        sessions.acceptSessions([running], now: clock)
        XCTAssertEqual(sessions.activeCount, 1)
        clock += 599; sessions.acceptSessions([running], now: clock)
        XCTAssertEqual(sessions.activeCount, 1)
        clock += 2; sessions.acceptSessions([running], now: clock)
        XCTAssertEqual(sessions.activeCount, 0)
        XCTAssertTrue(sessions.currentSessions.isEmpty, "The stale row leaves the panel")
        XCTAssertEqual(sessions.hiddenCount, 0, "Unknown state is not archived")
    }

    // Matrix S14: NTP moves the clock two hours forward while sessions are
    // open and idle. Their inactivity did not grow by two hours.
    func testClockCorrectionDoesNotHideEveryIdleSessionAtOnce() async throws {
        var clock = instant
        func rows() -> [AgentSession] {
            (0..<3).map {
                AgentSession(provider: .codex, sessionID: "open-\($0)", title: "Open \($0)", cwd: "/Users/fixture/Projects/\($0)", phase: .idle,
                             updatedAt: self.instant.addingTimeInterval(-60), observedAt: clock, runtimeConfirmed: true)
            }
        }
        let sessions = try store(.init(events: { _, _, _ in rows() }, schedulesTimers: true), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.codex])
        sessions.autoHideMinutes = 20
        sessions.start(clientResolver: { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) })
        await sessions.refresh()
        XCTAssertEqual(sessions.currentSessions.count, 3)
        clock += 7200
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        await sessions.readEvents()
        XCTAssertEqual(sessions.hiddenCount, 0, "A clock correction is not two hours of inactivity")
        clock += 1199; await sessions.readEvents()
        XCTAssertEqual(sessions.hiddenCount, 0)
        clock += 1; await sessions.readEvents()
        XCTAssertEqual(sessions.hiddenCount, 3, "The chosen interval still applies from the correction")
    }

    // §5.5 / matrix S4: /rename in the middle of a reply.
    func testRenameDuringAReplyKeepsItsTimerAndReachesHiddenEntryAndNotice() async throws {
        var clock = instant, name = "Old name", status = "busy"
        let id = "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01"
        var hook = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": id, "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: clock)
        let sessions = try store(.init(catalog: { _, _, _, _ in
            (try self.claudeRows([["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "name": name,
                                   "sessionId": id, "startedAt": 1_795_000_100_000, "status": status]], at: clock), false)
        }, events: { _, _, _ in [hook.session] }), now: { clock })
        var tracker = SessionNoticeTracker(), notices: [SessionNotice] = []
        let subscription = sessions.observations.sink { notices += tracker.update($0.rows, now: $0.date) }
        defer { subscription.cancel(); sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        let row = try XCTUnwrap(sessions.sessions.first)
        XCTAssertEqual(row.title, "Old name")
        try sessions.hide(row)
        clock += 20; name = "New name"
        await sessions.refresh()
        XCTAssertEqual(sessions.hiddenSessions.first?.title, "New name", "The hidden list shows the current name")
        try sessions.restore(row.id)
        clock += 20
        await sessions.refresh()
        let renamed = try XCTUnwrap(sessions.sessions.first)
        XCTAssertEqual(renamed.title, "New name")
        XCTAssertEqual(renamed.turnStartedAt, instant, "The reply's timer survives the rename")
        clock += 5; status = "idle"
        hook = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": id, "hook_event_name": "Stop", "cwd": "/Users/fixture/Projects/lunavect", "last_assistant_message": "Готово."]),
            provider: .claude, previous: hook, now: clock)
        clock += 1
        await sessions.refresh()
        XCTAssertEqual(notices.map(\.kind), [.completed])
        XCTAssertEqual(notices.first?.session.displayTitle, "New name")
    }

    // §5.10: 500 retained history rows and 100 hook files on every tick.
    func testLargeHistoryAndManyHookRecordsStayCheapPerTick() async throws {
        let root = try directory(), hooks = root.appendingPathComponent("Sessions", isDirectory: true)
        for index in 0..<100 {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": "hook-\(index)", "hook_event_name": "Stop", "cwd": "/Users/fixture/p\(index)"])
            try SessionHooks.capture(data, provider: .claude, at: hooks, isInternal: { _ in false })
        }
        let history = (0..<500).map { index -> [String: Any] in
            ["id": "bg-\(index)", "cwd": "/Users/fixture/Projects/lunavect", "kind": "background", "name": "Task \(index)",
             "sessionId": "history-\(index)", "startedAt": 1_783_332_137_673, "state": index % 2 == 0 ? "done" : "blocked"]
        }
        var clock = Date()
        let sessions = try store(.init(catalog: { _, _, _, _ in (try self.claudeRows(history, at: clock), false) },
                                       events: { _, _, _ in SessionHooks.load(at: hooks) }), directory: root, now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        XCTAssertEqual(sessions.sessions.count, 600)
        XCTAssertEqual(sessions.currentSessions.count, 100)
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { clock += 1; await sessions.readEvents() }
        let perTick = (ProcessInfo.processInfo.systemUptime - began) / 10
        // Decision 30: a wall-clock bound only separates "cheap" from "stuck" on a
        // loaded runner (for example the TSan job). The tight budget stays opt-in.
        XCTAssertLessThan(perTick, 5, "One tick of merge, sort and publish with 600 rows (typically a few ms)")
        if ProcessInfo.processInfo.environment["LUNAVECT_STRICT_TIMING"] == "1" {
            XCTAssertLessThan(perTick, 0.5, "Strict timing: one tick with 600 rows")
        }
        XCTAssertEqual(sessions.hiddenCount, 0)
    }

    // §5.12: hidden-sessions.json damaged after a successful launch.
    func testHiddenListDamagedWhileRunningIsRewrittenWithoutLosingEntries() throws {
        let root = try directory()
        let sessions = try store(directory: root, now: { self.instant })
        defer { sessions.stop() }
        let rows = (0..<3).map {
            AgentSession(provider: .codex, sessionID: "kept-\($0)", title: "Kept \($0)", cwd: "/Users/fixture", phase: .ready,
                         updatedAt: instant, observedAt: instant, evidence: .hook)
        }
        sessions.acceptSessions(rows, now: instant)
        try sessions.hide(rows[0])
        let file = root.appendingPathComponent("hidden-sessions.json")
        try Data("{\"sessions\":".utf8).write(to: file)
        try sessions.hide(rows[1])
        XCTAssertNil(sessions.connectionMessage, "Nothing was lost: the list in memory is the original")
        XCTAssertEqual(try SessionVisibility(url: file, now: instant).hidden, [rows[0].id, rows[1].id])
        XCTAssertEqual(SessionStore(directory: root, isolated: true, now: { self.instant }).hiddenCount, 2)
    }

    // Matrix S13: the user removed Lunavect's handlers from settings.json.
    func testRemovedHooksAreReportedAndTheLastEventsDoNotFreezeAsWork() async throws {
        var clock = instant
        let installed = OSAllocatedUnfairLock(initialState: true)
        let running = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": "orphan", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: clock).session
        let sessions = try store(.init(events: { _, _, _ in [running] }, hooksState: { [.claude: installed.withLock { $0 }] }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        XCTAssertEqual(sessions.hooksInstalled[.claude], true)
        XCTAssertEqual(sessions.activeCount, 1)
        installed.withLock { $0 = false }; clock += 30
        await sessions.refresh()
        XCTAssertEqual(sessions.hooksInstalled[.claude], false, "Connections can offer to repair the handlers")
        clock = instant.addingTimeInterval(601)
        await sessions.refresh()
        XCTAssertEqual(sessions.activeCount, 0, "The last recorded event does not stay working")
        XCTAssertTrue(sessions.currentSessions.isEmpty)
    }
}
