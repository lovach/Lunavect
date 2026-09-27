import XCTest
import Combine
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
}
