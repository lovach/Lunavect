import XCTest
import CoreGraphics
@testable import WeekleftCore

final class SessionActionsTests: XCTestCase {
    private let id = "01234567-89ab-cdef-0123-456789abcdef"
    private func row(_ provider: ProviderID = .claude, client: SessionClient = .desktop) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "A", cwd: "/tmp/a'$(touch bad)", client: client, phase: .running, updatedAt: Date(), observedAt: Date())
    }
    func testHiddenSessionSurvivesPollAndRelaunchWithoutHidingOtherProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hidden.json")
        var preferences = try SessionVisibility(url: url)
        let rows = [row(), row(.codex)]
        try preferences.setHidden(rows[0].id, true)
        XCTAssertEqual(preferences.visible(rows).map(\.id), [rows[1].id])
        var relaunched = try SessionVisibility(url: url)
        var updated = rows; updated[0].title = "Renamed"; updated[0].observedAt = Date().addingTimeInterval(30)
        XCTAssertEqual(relaunched.visible(updated).map(\.id), [rows[1].id])
        try relaunched.setHidden(rows[0].id, false)
        XCTAssertEqual(relaunched.visible(updated).count, 2)
        try relaunched.setHidden(rows[1].id, true)
        try relaunched.restoreAll()
        XCTAssertTrue(try SessionVisibility(url: url).hidden.isEmpty)
    }
    func testFailedSaveDoesNotPretendRowIsHidden() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        var visibility = try SessionVisibility(url: blocked.appendingPathComponent("hidden.json"))
        XCTAssertThrowsError(try visibility.setHidden(row().id, true))
        XCTAssertTrue(visibility.hidden.isEmpty)
    }
    func testSearchExplainsTwoActiveSessionsButOneCyrillicMatch() {
        let now = Date()
        let rows = [
            AgentSession(provider: .claude, sessionID: "claude", title: "Промпты для иконки в DALL-E", cwd: "/tmp/Lunavect", phase: .running, updatedAt: now, observedAt: now),
            AgentSession(provider: .codex, sessionID: "codex", title: "Настрой проект по OpenAI", cwd: "/tmp/Lunavect", phase: .running, updatedAt: now, observedAt: now)
        ]
        XCTAssertEqual(rows.filter { $0.effectivePhase(now: now).isActive }.count, 2)
        XCTAssertEqual(SessionList.filter(rows, query: "а", provider: nil, activeOnly: false, now: now).map(\.sessionID), ["codex"])
        XCTAssertEqual(SessionList.filter(rows, query: "", provider: nil, activeOnly: false, now: now).count, 2)
    }
    func testSwipeTargetsLowerRowAndRejectsClippedRowsUnderHeader() {
        let viewport = CGRect(x: 0, y: 150, width: 360, height: 300)
        var regions = ["upper": CGRect(x: 8, y: 154, width: 344, height: 42),
                       "lower": CGRect(x: 8, y: 198, width: 344, height: 42)]
        XCTAssertEqual(SessionSwipe.target(at: CGPoint(x: 120, y: 220), regions: regions, viewport: viewport), "lower")
        XCTAssertEqual(SessionSwipe.target(at: CGPoint(x: 120, y: 170), regions: regions, viewport: viewport), "upper")
        XCTAssertNil(SessionSwipe.target(at: CGPoint(x: 120, y: 197), regions: regions, viewport: viewport))
        regions["upper"] = CGRect(x: 8, y: 100, width: 344, height: 42)
        XCTAssertNil(SessionSwipe.target(at: CGPoint(x: 120, y: 120), regions: regions, viewport: viewport))
    }
    func testSwipeTracksFingerThenAddsContinuousResistance() {
        var swipe = SessionSwipe()
        swipe.update(dx: 30, dy: 0); XCTAssertEqual(swipe.offset, 30)
        swipe.update(dx: 34, dy: 0); XCTAssertEqual(swipe.offset, 64)
        swipe.update(dx: 1, dy: 0)
        XCTAssertGreaterThan(swipe.offset, 64); XCTAssertLessThan(swipe.offset, 65)
        let before = swipe.offset
        swipe.update(dx: 30, dy: 0)
        XCTAssertGreaterThan(swipe.offset, before); XCTAssertLessThan(swipe.offset, 95)
        swipe.update(dx: -95, dy: 0)
        XCTAssertEqual(swipe.offset, 0); XCTAssertNil(swipe.finish())
    }
    func testSwipeNeedsIntentAndFingerLift() {
        var swipe = SessionSwipe()
        swipe.update(dx: 40, dy: 1); XCTAssertNil(swipe.finish())
        swipe.update(dx: 35, dy: 1); swipe.update(dx: 40, dy: 1)
        XCTAssertEqual(swipe.finish(), .open); XCTAssertNil(swipe.finish())
        swipe.update(dx: -80, dy: 1); XCTAssertEqual(swipe.finish(), .hide)
        swipe.update(dx: 1, dy: 20); swipe.update(dx: -100, dy: 0)
        XCTAssertNil(swipe.finish())
        swipe.update(dx: -90, dy: 0); XCTAssertNil(swipe.finish(cancelled: true))
        swipe.update(dx: 90, dy: 0); swipe.update(dx: -70, dy: 0)
        XCTAssertNil(swipe.finish())
    }
    func testDestinationsKeepExactIDAndDoNotImportDesktopSession() throws {
        let session = row()
        let url = try XCTUnwrap(session.claudeDesktopURL(desktopID: "local_1234-abcd"))
        XCTAssertEqual(url.absoluteString, "claude://claude.ai/epitaxy/local_1234-abcd")
        XCTAssertNil(session.claudeDesktopURL(desktopID: "../bad?prompt=hello"))
        XCTAssertEqual(session.vscodeURL?.query, "session=" + id)
        XCTAssertNil(row(.codex).vscodeURL)
        XCTAssertEqual(row(.codex).codexURL?.absoluteString, "codex://threads/" + id)
        let script = try XCTUnwrap(session.terminalScript(executable: "/opt/Claude Code/claude"))
        XCTAssertTrue(script.contains("cd -- '/tmp/a'\"'\"'$(touch bad)' || exit 1"))
        XCTAssertTrue(script.contains("exec '/opt/Claude Code/claude' --resume '" + id + "'"))
        var bad = session; bad.sessionID = "x; touch bad"
        XCTAssertNil(bad.terminalScript(executable: "/bin/claude"))
        XCTAssertNil(bad.vscodeURL)
    }
    func testOldQuotaIsSavedNotMissingWithoutClaimingFreshness() throws {
        let now = Date()
        let quota = try QuotaWindow(usedPercent: 84, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        var snapshot = UsageSnapshot(provider: .claude, weekly: quota, fetchedAt: now.addingTimeInterval(-86400))
        XCTAssertEqual(snapshot.connectionQuotaTitle(now: now), "Лимиты сохранены")
        XCTAssertTrue(snapshot.isStale(now: now)); XCTAssertEqual(snapshot.weekly?.remaining, 16)
        snapshot.fetchedAt = now
        XCTAssertEqual(snapshot.connectionQuotaTitle(now: now), "Лимиты получены")
        snapshot.issue = "offline"
        XCTAssertEqual(snapshot.connectionQuotaTitle(now: now), "Лимиты сохранены")
        snapshot.weekly = nil
        XCTAssertEqual(snapshot.connectionQuotaTitle(now: now), "Ждём лимиты")
    }
}
