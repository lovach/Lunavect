import XCTest
import SwiftUI
import Combine
import WeekleftCore
@testable import Weekleft

final class SessionEfficiencyTests: XCTestCase {
    @MainActor func testUnchangedPollDoesNotRepublishRowsButAgingStatusDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory), now = Date()
        let row = AgentSession(provider: .claude, sessionID: "efficiency", title: "Fixture", cwd: "/tmp/fixture",
                               phase: .running, updatedAt: now, observedAt: now, evidence: .hook)
        var publications = 0, observations = 0
        let observer = store.$sessions.dropFirst().sink { _ in publications += 1 }
        defer { observer.cancel() }
        store.onObservation = { _, _ in observations += 1 }
        store.acceptSessions([row], now: now)
        store.acceptSessions([row], now: now.addingTimeInterval(1))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(observations, 2, "Activity tracking still receives observations while the panel is hidden")
        store.acceptSessions([row], now: now.addingTimeInterval(601))
        XCTAssertEqual(publications, 2, "The menu bar must learn that the running evidence expired")
    }
    func testIdlePollingPreservesCatalogFreshnessAndVisibleResponsiveness() {
        let idle = SessionPolling(panelVisible: false, hasActiveSessions: false)
        let working = SessionPolling(panelVisible: false, hasActiveSessions: true)
        let visible = SessionPolling(panelVisible: true, hasActiveSessions: false)
        XCTAssertLessThan(idle.catalog, 60, "Catalog evidence expires after one minute")
        XCTAssertGreaterThan(idle.events, working.events)
        XCTAssertGreaterThan(working.events, visible.events)
        XCTAssertLessThanOrEqual(working.catalog, 15)
        XCTAssertLessThanOrEqual(visible.events, 1)
    }
    @MainActor func testHiddenPanelUnmountsTimelineAndResumesWhenShown() throws {
        final class Counter { var ticks = 0 }
        let counter = Counter(), state = SessionPanelState(isVisible: true)
        let host = NSHostingView(rootView: SessionPanelContent(state: state) {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                let _ = { counter.ticks += 1 }()
                Text(context.date.formatted()).frame(width: 200, height: 50)
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        settle()
        let initial = counter.ticks
        settle()
        XCTAssertGreaterThan(counter.ticks, initial, "The test must exercise an actual ticking TimelineView")
        state.isVisible = false
        settle()
        let hidden = counter.ticks
        settle()
        XCTAssertEqual(counter.ticks, hidden, "Hidden content must not execute timeline updates")
        state.isVisible = true
        settle()
        XCTAssertGreaterThan(counter.ticks, hidden)
    }
}
