import XCTest
import WeekleftCore
@testable import Weekleft

final class SessionAutoHideTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func claudeEvent(_ name: String, id: String = "empty", previous: SessionRecord? = nil,
                             at time: Date? = nil) throws -> SessionRecord {
        try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": id, "hook_event_name": name, "cwd": "/example/project"
        ]), provider: .claude, previous: previous, now: time ?? start, client: .desktop)
    }
    @MainActor func testLifecycleOnlyClaudeSessionsDoNotRefillHiddenList() throws {
        try withStore { store, _, _ in
            store.autoHideMinutes = 5
            let opened = try claudeEvent("SessionStart")
            store.acceptSessions([opened.session], now: start)
            store.acceptSessions([opened.session], now: start.addingTimeInterval(300))
            XCTAssertEqual(store.hiddenCount, 0)
            XCTAssertTrue(store.sessions.isEmpty, "A CLI startup alone is not a user task")
            let ended = try claudeEvent("SessionEnd", previous: opened, at: start.addingTimeInterval(301))
            store.acceptSessions([ended.session], now: start.addingTimeInterval(601))
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertEqual(store.hiddenCount, 0)
            try store.removeHidden()
            // Desktop emits new IDs on later lifecycle-only exits, including end-only hooks.
            let another = try claudeEvent("SessionEnd", id: "another", at: start.addingTimeInterval(700))
            store.acceptSessions([ended.session, another.session], now: start.addingTimeInterval(1000))
            XCTAssertEqual(store.hiddenCount, 0)
        }
    }
    @MainActor func testStartupOnlySessionStaysAbsentAcrossCatalogPollsAndAppearsOnRealWork() throws {
        for legacy in [false, true] {
            for name in ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "StopFailure"] {
                try withStore { store, _, _ in
                    var opened = try claudeEvent("SessionStart")
                    if legacy { opened.session.hasTaskActivity = nil }
                    var catalog = AgentSession(provider: .claude, sessionID: "empty", title: "Service project",
                        cwd: "/example/project", phase: .idle, updatedAt: start, observedAt: start.addingTimeInterval(1))
                    let merged = SessionList.merge(catalog: [catalog], events: [opened.session], now: start.addingTimeInterval(1))
                    XCTAssertFalse(try XCTUnwrap(merged.first).isCurrent(now: start.addingTimeInterval(1)))
                    store.acceptSessions(merged, now: start.addingTimeInterval(1))
                    XCTAssertTrue(store.sessions.isEmpty)
                    XCTAssertEqual(store.hiddenCount, 0)
                    catalog.phase = .running
                    let active = SessionList.merge(catalog: [catalog], events: [opened.session], now: start.addingTimeInterval(1))
                    store.acceptSessions(active, now: start.addingTimeInterval(1))
                    XCTAssertEqual(store.sessions.first?.phase, .running, "Live catalog work overrides the empty startup")
                    catalog.phase = .idle
                    let work = try claudeEvent(name, previous: opened, at: start.addingTimeInterval(2))
                    catalog.observedAt = start.addingTimeInterval(2)
                    let rows = SessionList.merge(catalog: [catalog], events: [work.session], now: start.addingTimeInterval(2))
                    store.acceptSessions(rows, now: start.addingTimeInterval(2))
                    XCTAssertEqual(store.sessions.map(\.sessionID), ["empty"], name)
                    XCTAssertEqual(store.sessions.first?.phase, work.session.phase, name)
                }
            }
        }
    }
    /// Replays a Desktop pause observed on 2026-09-24: a Stop with a running
    /// background command, the status-bar hook's "done" written in the same
    /// second, and a newer idle catalog poll whose only timestamp is the start.
    @MainActor func testBackgroundPauseStaysVisibleBesideLegacyDoneAndNewerIdleCatalog() throws {
        // Both hooks run in parallel; the whole-second "done" may land on either side.
        for legacyOffset in [0.0, 0.9] { try withStore { store, _, _ in
            store.autoHideMinutes = 20
            let id = "df9bebea-ac1b-4ad2-b235-b6d2f34ccde5"
            let started = start.addingTimeInterval(-86400)
            func catalog(_ status: String, at time: Date) throws -> [AgentSession] {
                try SessionParser.claude(JSONSerialization.data(withJSONObject: [[
                    "pid": 2198, "cwd": "/example/project", "kind": "interactive", "sessionId": id,
                    "name": "Luna - updates", "status": status, "startedAt": started.timeIntervalSince1970 * 1000
                ]]), now: time)
            }
            func hook(_ name: String, previous: SessionRecord?, at time: Date, _ extra: [String: Any] = [:]) throws -> SessionRecord {
                try SessionRecord.event(JSONSerialization.data(withJSONObject: [
                    "session_id": id, "hook_event_name": name, "cwd": "/example/project"
                ].merging(extra) { $1 }), provider: .claude, previous: previous, now: time, client: .desktop)
            }
            let prompt = try hook("UserPromptSubmit", previous: nil, at: start.addingTimeInterval(-300))
            let launched = try hook("PostToolUse", previous: prompt, at: start.addingTimeInterval(-5), [
                "tool_name": "Bash", "tool_input": ["command": "sleep 120", "run_in_background": true],
                "tool_response": ["backgroundTaskId": "b1"]])
            let busy = SessionList.merge(catalog: try catalog("busy", at: start.addingTimeInterval(-4)),
                                         events: [launched.session], now: start.addingTimeInterval(-4))
            store.acceptSessions(busy, now: start.addingTimeInterval(-4))
            XCTAssertEqual(store.sessions.first?.phase, .running)
            let stopAt = start.addingTimeInterval(0.6)
            let paused = try hook("Stop", previous: launched, at: stopAt, [
                "last_assistant_message": "Reproducing the pause.",
                "background_tasks": [["id": "b1", "type": "shell", "status": "running", "command": "sleep 120"]]])
            let legacyAt = start.addingTimeInterval(legacyOffset)
            let legacyDone = AgentSession(provider: .claude, sessionID: id, title: "Lunavect", cwd: "/example/project",
                client: .desktop, phase: .ready, updatedAt: legacyAt, observedAt: legacyAt, evidence: .legacy)
            let now = start.addingTimeInterval(3)
            let rows = SessionList.merge(catalog: try catalog("idle", at: now), events: [legacyDone, paused.session], now: now)
            store.acceptSessions(rows, now: now)
            XCTAssertEqual(store.hiddenCount, 0, "A paused session must not be auto-hidden")
            let row = try XCTUnwrap(store.sessions.first { $0.sessionID == id })
            XCTAssertEqual(row.effectivePhase(now: now), .running)
            XCTAssertEqual(row.awaitingBackground, true)
            XCTAssertEqual(row.backgroundWork, BackgroundWork(commands: 1))
        } }
    }
    /// A finished response stays for the chosen auto-hide interval even when a
    /// newer catalog poll, which only knows the session start, won the phase.
    @MainActor func testFinishedResponseIsNotHiddenBeforeIntervalAfterNewerIdleCatalog() throws {
        try withStore { store, _, _ in
            store.autoHideMinutes = 20
            let id = "0f9bebea-ac1b-4ad2-b235-b6d2f34ccde5"
            let started = start.addingTimeInterval(-86400)
            func catalog(at time: Date) throws -> [AgentSession] {
                try SessionParser.claude(JSONSerialization.data(withJSONObject: [[
                    "pid": 2199, "cwd": "/example/project", "kind": "interactive", "sessionId": id,
                    "name": "Finished", "status": "idle", "startedAt": started.timeIntervalSince1970 * 1000
                ]]), now: time)
            }
            let prompt = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
                "session_id": id, "hook_event_name": "UserPromptSubmit", "cwd": "/example/project"
            ]), provider: .claude, previous: nil, now: start.addingTimeInterval(-60), client: .desktop)
            let stop = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
                "session_id": id, "hook_event_name": "Stop", "cwd": "/example/project", "last_assistant_message": "Done."
            ]), provider: .claude, previous: prompt, now: start, client: .desktop)
            for seconds in [3.0, 1199] {
                let now = start.addingTimeInterval(seconds)
                store.acceptSessions(SessionList.merge(catalog: try catalog(at: now), events: [stop.session], now: now), now: now)
                XCTAssertEqual(store.hiddenCount, 0, "hidden \(seconds) s after the response")
                XCTAssertEqual(store.sessions.first?.phase, .ready)
            }
            let late = start.addingTimeInterval(1200)
            store.acceptSessions(SessionList.merge(catalog: try catalog(at: late), events: [stop.session], now: late), now: late)
            XCTAssertEqual(store.hiddenCount, 1, "The chosen interval still applies")
        }
    }
    @MainActor func testCatalogOnlyIdleSessionIsNotAssumedToBeEmpty() throws {
        try withStore { store, _, _ in
            let session = AgentSession(provider: .claude, sessionID: "existing", title: "Existing task",
                cwd: "/example/project", phase: .idle, updatedAt: start, observedAt: start)
            store.acceptSessions([session], now: start)
            XCTAssertEqual(store.sessions.map(\.sessionID), ["existing"])
        }
    }
    @MainActor func testOldHiddenEmptyClaudeLifecycleIsRepairedOnRestartAndRealTaskReturns() throws {
        try withStore { _, defaults, directory in
            let ended = try claudeEvent("SessionEnd")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(ended).write(to: directory.appendingPathComponent("claude-empty.json"))
            var visibility = try SessionVisibility(url: directory.appendingPathComponent("hidden-sessions.json"))
            try visibility.hide(ended.session, now: start.addingTimeInterval(300))
            let store = SessionStore(directory: directory, defaults: defaults)
            XCTAssertEqual(store.hiddenCount, 0)
            let running = try claudeEvent("UserPromptSubmit", previous: ended, at: start.addingTimeInterval(500))
            store.acceptSessions([running.session], now: running.session.observedAt)
            XCTAssertEqual(store.sessions.first?.phase, .running)
            XCTAssertEqual(SessionStore(directory: directory, defaults: defaults).hiddenCount, 0)
        }
    }
    @MainActor func testRealClaudeWorkRemainsEligibleForAutoHideEvenWithMissedPrompt() throws {
        for name in ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "StopFailure"] {
            try withStore { store, _, _ in
                store.autoHideMinutes = 5
                let work = try claudeEvent(name)
                let ended = try claudeEvent("SessionEnd", previous: work, at: start.addingTimeInterval(10))
                // Exercise the same catalog merge used by the real store.
                let catalog = AgentSession(provider: .claude, sessionID: "empty", title: "Named task",
                                           cwd: "/example/project", phase: .unknown,
                                           updatedAt: start, observedAt: start)
                let rows = SessionList.merge(catalog: [catalog], events: [ended.session], now: start.addingTimeInterval(10))
                store.acceptSessions(rows, now: start.addingTimeInterval(10))
                store.acceptSessions(rows, now: start.addingTimeInterval(310))
                XCTAssertEqual(store.hiddenCount, 1, name)
                try store.removeHidden()
                store.acceptSessions(rows, now: start.addingTimeInterval(311))
                XCTAssertEqual(store.hiddenCount, 0, name)
            }
        }
    }
    private func row(_ phase: SessionPhase = .ready, id: String = "idle") -> AgentSession {
        AgentSession(provider: .codex, sessionID: id, title: "Session", cwd: "", phase: phase,
                     updatedAt: start, observedAt: start, evidence: .localEvent)
    }
    @MainActor private func withStore(_ body: (SessionStore, UserDefaults, URL) throws -> Void) throws {
        let suite = "Lunavect.AutoHideTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try body(SessionStore(directory: directory, defaults: defaults), defaults, directory)
    }
    @MainActor func testDisabledByDefaultAndChoicePersists() throws {
        try withStore { store, defaults, directory in
            XCTAssertEqual(store.autoHideMinutes, 0)
            store.acceptSessions([row()], now: start)
            store.acceptSessions([row()], now: start.addingTimeInterval(3600))
            XCTAssertEqual(store.hiddenCount, 0)
            store.autoHideMinutes = 20
            XCTAssertEqual(SessionStore(directory: directory, defaults: defaults).autoHideMinutes, 20)
        }
    }
    @MainActor func testAllTimeoutsUseActivityRatherThanPollAndSurviveStaleStatus() throws {
        for minutes in [5, 10, 20] {
            try withStore { store, _, _ in
                store.autoHideMinutes = minutes
                var idle = row()
                store.acceptSessions([idle], now: start)
                let deadline = start.addingTimeInterval(Double(minutes * 60))
                // Re-reading a source must not restart the inactivity interval.
                idle.observedAt = deadline.addingTimeInterval(-1)
                store.acceptSessions([idle], now: deadline.addingTimeInterval(-1))
                XCTAssertEqual(store.sessions.count, 1)
                // A source may also stop emitting after completion; its state expires.
                idle.observedAt = start
                store.acceptSessions([idle], now: deadline)
                XCTAssertEqual(store.hiddenCount, 1)
                XCTAssertTrue(store.sessions.isEmpty)
                XCTAssertNil(store.lastHidden, "Automatic hiding must not replace manual Undo")
            }
        }
    }
    @MainActor func testRunningWaitingUnknownAndHistoricalSessionsAreNeverAutoHidden() throws {
        try withStore { store, _, _ in
            store.autoHideMinutes = 5
            var rows = [SessionPhase.running, .permission, .input, .unknown].map { row($0, id: $0.rawValue) }
            var historical = row(.ready, id: "history")
            historical.observedAt = start.addingTimeInterval(-3600)
            var unconfirmed = row(.ready, id: "unconfirmed")
            unconfirmed.runtimeConfirmed = false
            rows += [historical, unconfirmed]
            store.acceptSessions(rows, now: start)
            store.acceptSessions(rows, now: start.addingTimeInterval(3600))
            XCTAssertEqual(store.hiddenCount, 0)
            XCTAssertEqual(store.sessions.count, rows.count)
        }
    }
    @MainActor func testNewTaskRestoresAndCompletionStartsNewInterval() throws {
        try withStore { store, _, _ in
            store.autoHideMinutes = 5
            var session = row()
            store.acceptSessions([session], now: start)
            store.acceptSessions([session], now: start.addingTimeInterval(300))
            XCTAssertEqual(store.hiddenCount, 1)
            session.phase = .running
            session.updatedAt = start.addingTimeInterval(301)
            session.observedAt = session.updatedAt
            session.turnStartedAt = session.updatedAt
            store.acceptSessions([session], now: session.updatedAt)
            XCTAssertEqual(store.hiddenCount, 0)
            session.phase = .ready
            session.updatedAt = start.addingTimeInterval(600)
            session.observedAt = session.updatedAt
            store.acceptSessions([session], now: session.updatedAt)
            store.acceptSessions([session], now: start.addingTimeInterval(899))
            XCTAssertEqual(store.sessions.count, 1)
            store.acceptSessions([session], now: start.addingTimeInterval(900))
            XCTAssertEqual(store.hiddenCount, 1)
        }
    }
    @MainActor func testManualRestoreGetsFullNewIntervalAndHiddenStatePersists() throws {
        try withStore { store, defaults, directory in
            store.autoHideMinutes = 5
            let session = row()
            store.acceptSessions([session], now: start)
            store.acceptSessions([session], now: start.addingTimeInterval(300))
            XCTAssertEqual(SessionStore(directory: directory, defaults: defaults).hiddenCount, 1)
            let restoredAt = start.addingTimeInterval(400)
            try store.restore(session.id, now: restoredAt)
            store.acceptSessions([session], now: restoredAt)
            XCTAssertEqual(store.sessions.count, 1)
            store.acceptSessions([session], now: restoredAt.addingTimeInterval(299))
            XCTAssertEqual(store.sessions.count, 1)
            store.acceptSessions([session], now: restoredAt.addingTimeInterval(300))
            XCTAssertEqual(store.hiddenCount, 1)
        }
    }
}
