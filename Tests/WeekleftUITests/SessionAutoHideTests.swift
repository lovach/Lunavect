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
            XCTAssertEqual(store.sessions.count, 1, "An open idle session remains available")
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
