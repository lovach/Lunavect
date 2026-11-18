import XCTest
import WeekleftCore
@testable import Weekleft

final class NotchIslandTests: XCTestCase {
    /// The owner's Mac16,5 as AppKit reported it on 18.11.2026.
    func testHousingLiesBetweenTheTwoMenuBarStrips() {
        let geometry = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeTop: 32,
                                          leftArea: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
                                          rightArea: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32), menuBarHeight: 24)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notch, CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    }

    func testScreenWithoutHousingGetsANarrowGapAtTheTopCentre() {
        let geometry = NotchGeometry.make(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440), safeTop: 0,
                                          leftArea: nil, rightArea: nil, menuBarHeight: 24)
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.notch.midX, 1728 + 1280)
        XCTAssertEqual(geometry.notch.maxY, 1440)
        XCTAssertEqual(geometry.notch.height, 24)
    }

    func testWaitingSessionsComeFirstAndIdleOnesStayInThePanel() {
        let now = Date()
        func row(_ id: String, _ phase: SessionPhase, _ age: TimeInterval) -> AgentSession {
            var session = AgentSession(provider: .claude, sessionID: id, title: id, cwd: "/Users/fixture/project", client: .desktop,
                                       phase: phase, updatedAt: now - age, observedAt: now - age, evidence: .hook)
            if phase == .running { session.turnStartedAt = now - age - 60 }
            return session
        }
        let summary = IslandSummary.make([row("run", .running, 5), row("idle", .idle, 5), row("ask", .permission, 30),
                                          row("done", .ready, 2), row("run2", .running, 1)], now: now)
        XCTAssertEqual(summary.rows.map(\.id), ["claude:ask", "claude:run2", "claude:run", "claude:done"])
        XCTAssertEqual([summary.working, summary.waiting, summary.ready], [2, 1, 1])
        XCTAssertEqual(summary.rows.first?.since, now - 30, "A waiting row counts from the request")
        XCTAssertEqual(summary.rows[1].since, now - 61, "A working row counts from the turn")
        XCTAssertNil(summary.rows.last?.since)
    }

    func testClosedIslandHasEarsOnlyWithSomethingToShow() {
        let notch = CGSize(width: 185, height: 32)
        XCTAssertEqual(IslandLayout.compact(notch: notch, summary: IslandSummary()), notch)
        var busy = IslandSummary(); busy.working = 1
        XCTAssertEqual(IslandLayout.compact(notch: notch, summary: busy).width, 185 + 2 * IslandLayout.ear)
    }
}
