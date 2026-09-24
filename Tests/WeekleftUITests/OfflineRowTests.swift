import XCTest
@testable import Weekleft
@testable import WeekleftCore

final class OfflineRowTests: XCTestCase {
    @MainActor func testRowsSayNoNetworkOnlyAfterTheConnectionStaysDown() {
        let network = NetworkConnection(makeMonitor: { nil })
        network.update(available: false)
        let since = try! XCTUnwrap(network.offlineSince)
        let running = AgentSession(provider: .claude, sessionID: "net", title: "Render", cwd: "", phase: .running, updatedAt: since, observedAt: since)
        func row(_ phase: SessionPhase, after seconds: Double) -> SessionRow {
            SessionRow(session: running, now: since.addingTimeInterval(seconds), phase: phase, offlineSince: network.offlineSince,
                       swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in })
        }
        XCTAssertEqual(row(.running, after: 5).statusTitle, L("Думает"))
        XCTAssertEqual(row(.running, after: 12).statusTitle, L("Нет сети"))
        XCTAssertEqual(row(.ready, after: 12).statusTitle, L("Ответ готов"))
        let failed = { () -> SessionRow in
            var session = running; session.phase = .failed; session.failure = .limit; session.cwd = "/Projects/Studio/tour"
            return SessionRow(session: session, now: since, phase: .failed, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in })
        }()
        XCTAssertTrue(failed.rowToolTip.contains(L("Лимит исчерпан")), "the tooltip repeats the status the row shows")
        XCTAssertTrue(failed.rowToolTip.contains("/Projects/Studio/tour"), "the full folder is readable")
        XCTAssertTrue(row(.running, after: 12).rowToolTip.contains(L("Нет сети")))
        network.update(available: true)
        XCTAssertNil(network.offlineSince)
        network.stop()
    }
}
