import XCTest
import SwiftUI
import AppKit
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
    /// Decision 28.09: a limits check run by hand reads as a neutral service row, not
    /// "Awaiting input". `LUNAVECT_RENDER_LIMITS_CHECK_ROW=<directory>` writes the row
    /// next to an ordinary waiting one for visual inspection.
    @MainActor func testManualLimitsCheckRowShowsANeutralServiceLabel() throws {
        let now = Date()
        var check = AgentSession(provider: .claude, sessionID: "check", title: "fixture-a3", cwd: "/Users/fixture", client: .unknown,
                                 phase: .input, updatedAt: now, observedAt: now, evidence: .catalog)
        check.isLimitsCheck = true
        let waiting = AgentSession(provider: .claude, sessionID: "work", title: "Fix widgets", cwd: "/Users/fixture/Projects/lunavect",
                                   client: .terminal, phase: .input, updatedAt: now, observedAt: now, evidence: .catalog)
        func row(_ session: AgentSession) -> SessionRow {
            SessionRow(session: session, now: now, phase: session.effectivePhase(now: now), swipePresentation: SessionSwipePresentation(),
                       onHide: {}, onError: { _ in })
        }
        XCTAssertEqual(check.effectivePhase(now: now), .idle)
        XCTAssertEqual(row(check).statusTitle, L("Служебная проверка лимитов"))
        XCTAssertTrue(row(check).rowToolTip.contains(L("Служебная проверка лимитов")))
        XCTAssertEqual(row(waiting).statusTitle, SessionPhase.input.title)
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LIMITS_CHECK_ROW"] else { return }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: VStack(spacing: 6) { row(waiting); row(check) }.padding(8).frame(width: 360))
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 2 * SessionRow.height + 22)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("limits-check-row-\(name).png"))
        }
    }
}
