import XCTest
import WeekleftCore
@testable import Weekleft

final class HiddenSessionUndoTests: XCTestCase {
    @MainActor func testNotificationChannelsStartDisabledAndPersistIndependently() {
        let suite = "Lunavect.NoticeTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppFeatures(defaults: defaults)
        XCTAssertFalse(settings.banners)
        XCTAssertFalse(settings.sounds)
        settings.sounds = true
        let restored = AppFeatures(defaults: defaults)
        XCTAssertTrue(restored.sounds)
        XCTAssertFalse(restored.banners)
    }
    @MainActor func testNewTaskReturnsToStoreAndClearsUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let t = Date()
        var row = AgentSession(provider: .claude, sessionID: "new-task", title: "Test", cwd: "", phase: .ready,
                               updatedAt: t, observedAt: t, evidence: .hook)
        row.turnStartedAt = t.addingTimeInterval(-60)
        store.acceptSessions([row]); try store.hide(row)
        row.phase = .running; row.observedAt = t.addingTimeInterval(5)
        row.updatedAt = row.observedAt; row.turnStartedAt = row.observedAt
        store.acceptSessions([row], now: row.observedAt)
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertEqual(store.sessions.map(\.id), [row.id])
        XCTAssertNil(store.lastHidden)
    }
    @MainActor func testUndoExpiresButHiddenSessionRemainsRestorable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, undoDelay: .milliseconds(30))
        let row = AgentSession(provider: .codex, sessionID: "undo-test", title: "Test", cwd: "", phase: .running, updatedAt: .now, observedAt: .now)
        store.sessions = [row]
        try store.hide(row)
        XCTAssertEqual(store.lastHidden?.id, row.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.lastHidden)
        XCTAssertEqual(store.hiddenCount, 1)
        XCTAssertTrue(store.sessions.isEmpty)
        try store.restore(row.id)
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertEqual(store.sessions.map(\.id), [row.id])
    }
}
