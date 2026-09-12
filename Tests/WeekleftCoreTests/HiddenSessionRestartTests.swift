import XCTest
@testable import WeekleftCore

final class HiddenSessionRestartTests: XCTestCase {
    private func fixture() -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (dir, dir.appendingPathComponent("hidden.json"))
    }
    private func row(_ phase: SessionPhase, at date: Date, turn: Date?, provider: ProviderID = .claude) -> AgentSession {
        var row = AgentSession(provider: provider, sessionID: "restart", title: "Task", cwd: "", phase: phase,
                               updatedAt: date, observedAt: date, evidence: .hook, runtimeConfirmed: true)
        row.turnStartedAt = turn; return row
    }
    func testNewTaskRestoresAfterAppRelaunchForBothProviders() throws {
        for provider in ProviderID.allCases {
            let (dir, url) = fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let t = Date()
            var visibility = try SessionVisibility(url: url)
            let ready = row(.ready, at: t, turn: t.addingTimeInterval(-60), provider: provider)
            try visibility.hide(ready, now: t)
            visibility = try SessionVisibility(url: url)
            let next = row(.running, at: t.addingTimeInterval(10), turn: t.addingTimeInterval(10), provider: provider)
            XCTAssertEqual(try visibility.restoreNewTasks([next], now: next.observedAt), [next.id])
            XCTAssertTrue(try SessionVisibility(url: url).hidden.isEmpty)
        }
    }
    func testHiddenRunningTaskStaysHiddenThroughToolsAndCompletion() throws {
        let (dir, url) = fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date(), start = Date().addingTimeInterval(-60)
        var visibility = try SessionVisibility(url: url)
        try visibility.hide(row(.running, at: t, turn: start), now: t)
        for phase in [SessionPhase.running, .permission, .running, .ready] {
            let update = row(phase, at: t.addingTimeInterval(5), turn: start)
            XCTAssertTrue(try visibility.restoreNewTasks([update], now: update.observedAt).isEmpty)
            XCTAssertEqual(visibility.hidden.count, 1)
        }
        // A short new task may already be finished by the next poll.
        let next = row(.ready, at: t.addingTimeInterval(20), turn: t.addingTimeInterval(10))
        XCTAssertEqual(try visibility.restoreNewTasks([next], now: next.observedAt), [next.id])
    }
    func testStaleActivityAndCatalogPollCannotRestoreHiddenSession() throws {
        let (dir, url) = fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date()
        var visibility = try SessionVisibility(url: url)
        try visibility.hide(row(.ready, at: t, turn: nil), now: t)
        var poll = row(.running, at: t.addingTimeInterval(5), turn: nil)
        poll.evidence = .catalog
        XCTAssertTrue(try visibility.restoreNewTasks([poll], now: poll.observedAt).isEmpty)
        let stale = row(.running, at: t.addingTimeInterval(10), turn: t.addingTimeInterval(10))
        XCTAssertTrue(try visibility.restoreNewTasks([stale], now: t.addingTimeInterval(800)).isEmpty)
        XCTAssertEqual(visibility.hidden.count, 1)
        poll.evidence = .hook
        XCTAssertEqual(try visibility.restoreNewTasks([poll], now: poll.observedAt), [poll.id])
    }
    func testLegacyIDsMigrateAndNewTurnRestores() throws {
        let (dir, url) = fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = Date(), old = row(.running, at: Date(), turn: Date().addingTimeInterval(-60))
        try JSONEncoder().encode([old.id]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: url.path)
        var visibility = try SessionVisibility(url: url)
        XCTAssertTrue(try visibility.restoreNewTasks([old], now: t).isEmpty)
        let next = row(.running, at: t.addingTimeInterval(10), turn: t.addingTimeInterval(10))
        XCTAssertEqual(try visibility.restoreNewTasks([next], now: next.observedAt), [next.id])
    }
    func testSourceWithoutTurnMarkerRequiresActualInactiveToActiveEvent() throws {
        let (dir, url) = fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = Date()
        var visibility = try SessionVisibility(url: url)
        try visibility.hide(row(.ready, at: t, turn: nil), now: t)
        let next = row(.running, at: t.addingTimeInterval(10), turn: nil)
        XCTAssertEqual(try visibility.restoreNewTasks([next], now: next.observedAt), [next.id])
    }
}
