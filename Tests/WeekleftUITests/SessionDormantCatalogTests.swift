import XCTest
import AppKit
import SwiftUI
import Combine
import WeekleftCore
import AwakeService
@testable import Weekleft

@MainActor private final class DormantCatalogAwakeClient: AwakeClient {
    var isAvailable = true
    var beginCount = 0
    func requestPermission() throws {}
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { beginCount += 1 }
    func configure(policy: AwakeSafetyPolicy) async throws {}
    func keepAlive() async throws {}
    func end() async throws {}
    func disconnect() {}
}

final class SessionDormantCatalogTests: XCTestCase {
    @MainActor func testNativeHeaderWaitingLabelUsesCurrentCount() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeCurrentHeader-" + UUID().uuidString)
        let suite = "Lunavect.NativeCurrentHeader." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SessionStore(directory: root, defaults: defaults, isolated: true, now: { now })
        defer { store.stop() }
        let raw: [[String: Any]] = (0..<5).map {
            ["sessionId": "retained-\($0)", "id": "retained-\($0)", "kind": "background", "state": "blocked"]
        }
        let retained = try SessionParser.claude(JSONSerialization.data(withJSONObject: raw), now: now)
        store.acceptSessions(retained, now: now)
        let view = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, isPreview: true, onSettings: {})
        let host = NSHostingView(rootView: view.header(at: now).defaultAppStorage(defaults))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func waitingLabel() -> String? {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            func find(_ value: Any, depth: Int) -> String? {
                guard depth < 20, let element = value as? any NSAccessibilityProtocol else { return nil }
                if element.accessibilityIdentifier() == "session-attention-filter" { return element.accessibilityLabel() }
                for child in element.accessibilityChildren() ?? [] {
                    if let label = find(child, depth: depth + 1) { return label }
                }
                return nil
            }
            return find(host, depth: 0)
        }
        guard let first = waitingLabel() else { throw XCTSkip("This AppKit test host does not expose SwiftUI header accessibility children") }
        XCTAssertEqual(first, L("В ожидании: {0}", "0"))
        var live = raw[0]; live["pid"] = 123; live["status"] = "waiting"
        let row = try XCTUnwrap(SessionParser.claude(JSONSerialization.data(withJSONObject: [live]), now: now).first)
        store.acceptSessions([row] + Array(retained.dropFirst()), now: now)
        host.rootView = view.header(at: now).defaultAppStorage(defaults)
        XCTAssertEqual(waitingLabel(), L("В ожидании: {0}", "1"), "The assertion must see the actual live header value change")
    }
    @MainActor func testHeaderCountSourceMatchesCurrentListAndPreservesExplicitHiddenHistory() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CurrentHeader-" + UUID().uuidString)
        let suite = "Lunavect.CurrentHeader." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SessionStore(directory: root, defaults: defaults, isolated: true, now: { now })
        defer { store.stop() }
        let raw: [[String: Any]] = (0..<5).map {
            ["sessionId": "retained-\($0)", "id": "retained-\($0)", "kind": "background", "state": "blocked", "startedAt": 1_783_332_137_673]
        }
        var retained = try SessionParser.claude(JSONSerialization.data(withJSONObject: raw), now: now)
        let codex = (0..<4).map {
            AgentSession(provider: .codex, sessionID: "codex-\($0)", title: "Fixture \($0)", cwd: "/fixture",
                         phase: $0 < 2 ? .running : .ready, updatedAt: now, observedAt: now, evidence: .hook)
        }
        store.acceptSessions(retained + codex, now: now)
        let view = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {})
        let waitingView = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {}, attentionOnly: true)
        let claudeView = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {}, provider: "claude")
        XCTAssertEqual(store.sessions.count, 9, "The fixture must reproduce retained rows in the source collection")
        XCTAssertEqual(view.currentCounts(at: now).total, 4)
        XCTAssertEqual(view.currentCounts(at: now).working, 2)
        XCTAssertEqual(view.currentCounts(at: now).waiting, 0, "Header metrics and its AX label use this same source")
        XCTAssertEqual(Set(view.filteredSessions(at: now).map(\.id)), Set(codex.map(\.id)))
        XCTAssertTrue(waitingView.filteredSessions(at: now).isEmpty)
        XCTAssertTrue(claudeView.filteredSessions(at: now).isEmpty)
        XCTAssertEqual(claudeView.currentCounts(at: now).total, 4, "The filter summary denominator describes all current rows")
        XCTAssertEqual(store.hiddenCount, 0, "Retained catalog history is not an explicit hidden preference")

        try store.hide(retained[0])
        XCTAssertEqual(store.hiddenCount, 1)
        XCTAssertEqual(store.hiddenSessions.map(\.id), [retained[0].id], "Explicitly hidden history remains manageable")
        XCTAssertEqual(view.currentCounts(at: now).total, 4)
        XCTAssertEqual(view.currentCounts(at: now).waiting, 0)
        try store.hide(codex[0])
        XCTAssertEqual(store.hiddenCount, 2)
        XCTAssertEqual(view.currentCounts(at: now).total, 3)
        XCTAssertEqual(view.currentCounts(at: now).working, 1)

        var live = raw[1]; live["pid"] = 123; live["status"] = "waiting"; live["waitingFor"] = "input needed"
        retained[1] = try XCTUnwrap(SessionParser.claude(JSONSerialization.data(withJSONObject: [live]), now: now).first)
        store.acceptSessions(retained + codex, now: now)
        XCTAssertEqual(view.currentCounts(at: now).total, 4)
        XCTAssertEqual(view.currentCounts(at: now).working, 1)
        XCTAssertEqual(view.currentCounts(at: now).waiting, 1)
        XCTAssertEqual(waitingView.filteredSessions(at: now).map(\.id), [retained[1].id])
        XCTAssertEqual(claudeView.filteredSessions(at: now).count, 1)
        XCTAssertEqual(view.currentCounts(at: now.addingTimeInterval(61)).waiting, 0, "Header counts use the display clock and expire stale live evidence")
        XCTAssertEqual(store.hiddenCount, 2)
    }
    @MainActor func testRetainedWaitsStayOutOfCurrentCountsNoticesActivityAndAwakeUntilFreshEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DormantCatalog-" + UUID().uuidString)
        let suite = "Lunavect.DormantCatalog." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<5).map { "retained-\($0)" }
        var liveID: String?, workID: String?, hooks: [AgentSession] = []
        let store = SessionStore(directory: root, defaults: defaults, isolated: true, now: { now }, dependencies: .init(catalog: { _, _, _, _ in
            let rows: [[String: Any]] = ids.map { id in
                var row: [String: Any] = ["sessionId": id, "id": id, "kind": "background", "state": id == workID ? "working" : "blocked", "startedAt": 1_783_332_137_673]
                if id == liveID { row["pid"] = 123; row["status"] = "waiting"; row["waitingFor"] = "input needed" }
                return row
            }
            return (try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: now), false)
        }, events: { _, _, _ in hooks }))
        store.useProviders([.claude])
        let client = DormantCatalogAwakeClient()
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        var played: [SessionNoticeKind] = [], observedIDs: [[String]] = []
        var activity = ActivityTracker()
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) })
        features.sounds = true; features.banners = false
        store.onObservation = { rows, date in
            observedIDs.append(rows.map(\.sessionID)); activity.observe(rows, now: date); awake.observe(rows)
        }
        let notices = store.observations.sink { features.observe($0.rows, at: $0.date) }
        defer { notices.cancel(); features.stop(); awake.shutdown(); store.stop() }
        await awake.setAutomatic(true)
        for _ in 0..<3 { await store.refresh(); now += 1 }
        XCTAssertEqual(store.sessions.count, 5, "Records remain available as history")
        XCTAssertTrue(store.sessions.allSatisfy { $0.phase == .input })
        XCTAssertTrue(store.currentSessions.isEmpty)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertTrue(observedIDs.allSatisfy(\.isEmpty), "Retained rows must not become activity or awake observations")
        XCTAssertTrue(activity.history.intervals.isEmpty, "Retained waits do not prove observed idle time")
        XCTAssertTrue(played.isEmpty)
        XCTAssertEqual(client.beginCount, 0)

        liveID = ids[0]
        await store.refresh()
        XCTAssertEqual(store.currentSessions.map(\.sessionID), [ids[0]], "An old session with a live wait remains current")
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertTrue(played.isEmpty, "Opening a retained wait establishes a baseline")
        XCTAssertEqual(client.beginCount, 0, "Waiting alone does not hold Keep Awake")

        now += 1; workID = ids[1]
        await store.refresh(); await awake.reconcileAutomatic()
        XCTAssertEqual(store.activeCount, 2)
        XCTAssertEqual(client.beginCount, 1, "Autonomous working state remains current without a process")

        now += 1
        hooks = [try SessionRecord.event(Data(#"{"session_id":"retained-2","hook_event_name":"PermissionRequest"}"#.utf8), provider: .claude, previous: nil, now: now).session]
        now += 1; await store.refresh()
        XCTAssertEqual(store.activeCount, 3, "A newer persisted-catalog poll cannot suppress a fresh hook")
        XCTAssertEqual(store.currentSessions.first { $0.sessionID == ids[2] }?.phase, .permission)
        now += 600; await store.refresh()
        XCTAssertEqual(store.activeCount, 2, "Repeated catalog reads cannot extend the hook lifetime")
        XCTAssertFalse(store.currentSessions.contains { $0.sessionID == ids[2] })
        XCTAssertTrue(played.isEmpty)
    }
}
