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
    @MainActor func testQuietLongTurnNotifiesThroughProductionObservationPublisher() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "Lunavect.QuietObservation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SessionStore(directory: directory, defaults: defaults, isolated: true, now: { now })
        var played: [SessionNoticeKind] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) })
        features.sounds = true; features.banners = false
        defer { features.stop(); store.stop() }
        let notices = store.observations.sink { observation in features.observe(observation.rows, at: observation.date) }
        var publications = 0
        let ui = store.$sessions.dropFirst().sink { _ in publications += 1 }
        defer { notices.cancel(); ui.cancel() }
        var row = AgentSession(provider: .claude, sessionID: "quiet", title: "Fixture", cwd: "/tmp",
                               phase: .running, updatedAt: now, observedAt: now, evidence: .hook)
        for second in 0...240 {
            now = Date(timeIntervalSince1970: 1_800_000_000 + Double(second))
            store.acceptSessions([row], now: now)
        }
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(played.isEmpty)
        now = now.addingTimeInterval(1)
        row.phase = .ready; row.observedAt = now; row.updatedAt = now
        store.acceptSessions([row], now: now)
        XCTAssertEqual(played, [.completed])
        // A real monitoring pause still suppresses historical completion.
        now = now.addingTimeInterval(1); row.phase = .running; row.observedAt = now
        store.acceptSessions([row], now: now)
        now = now.addingTimeInterval(130); row.phase = .ready; row.observedAt = now
        store.acceptSessions([row], now: now)
        XCTAssertEqual(played, [.completed])
    }
    @MainActor func testHiddenCompletionStaysSilentAndNewTaskRestoresNotifications() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "Lunavect.HiddenObservation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SessionStore(directory: directory, defaults: defaults, isolated: true, now: { now })
        var played: [SessionNoticeKind] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) })
        features.sounds = true; features.banners = false
        defer { store.stop(); features.stop() }
        let observer = store.observations.sink { features.observe($0.rows, at: $0.date) }
        defer { observer.cancel() }
        var record: SessionRecord?
        func event(_ name: String) throws {
            now += 1
            record = try SessionRecord.event(JSONSerialization.data(withJSONObject: ["session_id": "fixture", "hook_event_name": name]), provider: .claude, previous: record, now: now)
            store.acceptSessions([record!.session], now: now)
        }
        try event("UserPromptSubmit")
        try store.hide(record!.session)
        try event("Stop")
        XCTAssertTrue(played.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        try event("UserPromptSubmit")
        XCTAssertEqual(store.sessions.count, 1, "A real new task restores the hidden row")
        try event("Stop")
        XCTAssertEqual(played, [.completed])
    }
    @MainActor func testClaudeCatalogInterruptionPropagatesToActivityObservationAndRecoversFromFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var event = try SessionRecord.event(Data(#"{"session_id":"fixture","hook_event_name":"UserPromptSubmit"}"#.utf8), provider: .claude, previous: nil, now: now)
        var status = "busy", fails = false
        let dependencies = SessionStore.Dependencies(catalog: { _, _, _, _ in
            if fails { throw SessionError.timeout }
            let data = try JSONSerialization.data(withJSONObject: [["sessionId": "fixture", "kind": "interactive", "status": status, "pid": 123]])
            return (try SessionParser.claude(data, now: now), false)
        }, events: { _, _, _ in [event.session] })
        let store = SessionStore(directory: root, isolated: true, now: { now }, dependencies: dependencies)
        defer { store.stop() }
        store.useProviders([.claude])
        var phases: [SessionPhase] = []
        store.onObservation = { rows, now in phases.append(rows.first?.effectivePhase(now: now) ?? .unknown) }
        await store.refresh()
        XCTAssertEqual(phases.last, .running)
        status = "idle"; now += 15
        await store.refresh()
        XCTAssertEqual(phases.last, .interrupted)
        XCTAssertEqual(store.activeCount, 0)
        fails = true; now += 15
        await store.refresh()
        XCTAssertEqual(phases.last, .interrupted, "One failed poll keeps the last confirmed state within its lifetime")
        XCTAssertEqual(store.sessions.count, 1)
        now += 46
        await store.refresh()
        XCTAssertEqual(phases.last, .unknown, "Without a successful poll the catalog observation expires")
        now += 1
        event = try SessionRecord.event(Data(#"{"session_id":"fixture","hook_event_name":"UserPromptSubmit"}"#.utf8), provider: .claude, previous: event, now: now)
        await store.readEvents()
        XCTAssertEqual(phases.last, .running)
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
