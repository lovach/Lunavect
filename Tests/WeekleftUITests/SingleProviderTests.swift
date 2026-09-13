import XCTest
import SwiftUI
import AppKit
@testable import Weekleft
import WeekleftCore

final class SingleProviderTests: XCTestCase {
    func testMigrationKeepsOnlyExistingConnectionsAndPreservesExplicitChoice() throws {
        var prefs = try JSONDecoder().decode(WidgetPreferences.self, from: Data("{}".utf8))
        let quota = try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: .distantPast)
        let saved = [UsageSnapshot(provider: .codex, weekly: quota, fetchedAt: .distantPast, issue: "offline")]
        prefs.migrateConnections(snapshots: saved, configured: [])
        XCTAssertEqual(prefs.providers, [.codex], "Offline/stale is still a connected service")
        prefs.enabledProviders = []
        var restored = try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(prefs))
        restored.migrateConnections(snapshots: saved, configured: [.claude, .codex])
        XCTAssertTrue(restored.providers.isEmpty, "Old files and hooks cannot silently reconnect a disabled service")
        var fresh = WidgetPreferences(); fresh.migrateConnections(snapshots: [], configured: [])
        XCTAssertTrue(fresh.providers.isEmpty)
    }

    @MainActor func testPollingOnlyCallsSelectedProviderAndKeepsCachedData() async throws {
        for selected in ProviderID.allCases {
            var prefs = WidgetPreferences(); prefs.enabledProviders = [selected]
            var calls: [ProviderID] = []
            let store = AppStore(state: SharedState(snapshots: [], preferences: prefs), savesChanges: false) { id, _ in
                calls.append(id)
                return UsageSnapshot(provider: id, weekly: try QuotaWindow(usedPercent: 20, durationMinutes: 10080, resetsAt: .distantFuture), fetchedAt: Date())
            }
            await store.refresh()
            XCTAssertEqual(calls, [selected])
            XCTAssertTrue(store.snapshots.first { $0.provider == selected }?.hasQuota == true)
            store.setProvider(selected, enabled: false)
            await store.refresh()
            XCTAssertEqual(calls.count, 1, "Disabled services do not launch CLI probes")
            XCTAssertTrue(store.snapshots.first { $0.provider == selected }?.hasQuota == true, "Disconnect does not delete data")
            store.setProvider(.claude, enabled: true); store.setProvider(.codex, enabled: true)
            await store.refresh()
            XCTAssertEqual(calls.count, 3); XCTAssertEqual(Set(calls.suffix(2)), Set(ProviderID.allCases))
        }
    }

    @MainActor func testDisconnectDuringPollingCannotPublishResult() async throws {
        var prefs = WidgetPreferences(); prefs.enabledProviders = [.codex]
        var resume: CheckedContinuation<Void, Never>?
        let store = AppStore(state: SharedState(snapshots: [], preferences: prefs), savesChanges: false) { id, _ in
            await withCheckedContinuation { resume = $0 }
            return UsageSnapshot(provider: id, fetchedAt: Date(), source: "late")
        }
        let refresh = Task { await store.refresh() }
        while resume == nil { await Task.yield() }
        store.setProvider(.codex, enabled: false)
        resume?.resume(); await refresh.value
        XCTAssertFalse(store.snapshots.contains { $0.source == "late" })
    }

    @MainActor func testSingleProviderSessionsHiddenListAndCounters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory), now = Date()
        let rows = ProviderID.allCases.map { AgentSession(provider: $0, sessionID: $0.rawValue, title: $0.title, cwd: "/example", phase: .running, updatedAt: now, observedAt: now, evidence: .hook) }
        store.acceptSessions(rows)
        try store.hide(rows[0])
        store.useProviders([.codex])
        XCTAssertEqual(store.sessions.map(\.provider), [.codex]); XCTAssertEqual(store.activeCount, 1); XCTAssertEqual(store.hiddenCount, 0)
        store.acceptSessions(rows)
        XCTAssertEqual(store.sessions.map(\.provider), [.codex])
        store.useProviders(ProviderID.allCases)
        XCTAssertEqual(store.hiddenCount, 1, "Disabled source's hidden records are retained")
        store.useProviders([])
        XCTAssertEqual(store.activeCount, 0); XCTAssertTrue(store.sessions.isEmpty)
    }

    func testActivityTotalsUseSelectedProviderWithoutDeletingHistory() {
        let now = Date(), start = now.addingTimeInterval(-180)
        var history = ActivityHistory()
        history.append(start: start, end: start.addingTimeInterval(60), providers: 1)
        history.append(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120), providers: 3)
        history.append(start: start.addingTimeInterval(120), end: now, providers: 2)
        let one = history.summary(now: now, providers: [.codex])
        XCTAssertEqual(one.totals.active, 120); XCTAssertEqual(one.totals.codex, 120); XCTAssertEqual(one.totals.claude, 0)
        XCTAssertEqual(history.summary(now: now).totals.active, 180)
        XCTAssertFalse(history.summary(now: now, providers: []).hasObservations)
        XCTAssertEqual(history.intervals.count, 3)
    }

    @MainActor func testNativeSingleProviderScreens() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SINGLE"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let quota = try QuotaWindow(usedPercent: 28, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400 * 3))
        let five = try QuotaWindow(usedPercent: 10, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200))
        let snapshots = ProviderID.allCases.map { UsageSnapshot(provider: $0, weekly: quota, fiveHour: five, fetchedAt: now.addingTimeInterval(-1800), source: "Claude Code statusLine") }
        for ids in [[ProviderID.claude], [.codex], [.claude, .codex], []] {
            var prefs = WidgetPreferences(); prefs.enabledProviders = ids; prefs.showFiveHour = true
            prefs.subscriptionDates = ["claude": "2026-10-02", "codex": "2026-10-09"]
            let name = ids.map(\.rawValue).joined(separator: "-")
            let store = AppStore(state: SharedState(snapshots: snapshots, preferences: prefs), savesChanges: false)
            let sessions = SessionStore(directory: directory.appendingPathComponent("sessions")); sessions.useProviders(ids)
            try render(
                ScrollView { ConnectionsView(store: store, sessions: sessions).frame(width: 592).padding(24) }.frame(
                    width: 640, height: 680
                ).background(Color(nsColor: .windowBackgroundColor)), width: 640, height: 680,
                to: directory.appendingPathComponent(name + "-connections.png"))
            try render(
                SessionsView(
                    store: sessions, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {}),
                width: 360, height: 410, to: directory.appendingPathComponent(name + "-sessions.png"))
            for size in [LunavectWidgetSize.small, .medium] {
                try render(
                    LunavectWidgetCard(
                        snapshots: snapshots, preferences: prefs, history: ActivityHistory(), content: .limits,
                        family: size, now: now
                    ).background(Color(white: 0.12)), width: size.dimensions.width, height: size.dimensions.height,
                    to: directory.appendingPathComponent(name + "-" + size.rawValue + ".png"))
            }
            try render(
                LunavectWidgetCard(
                    snapshots: snapshots, preferences: prefs, history: ActivityHistory(), content: .overview,
                    family: .large, now: now
                ).background(Color(white: 0.12)), width: 344, height: 360,
                to: directory.appendingPathComponent(name + "-overview.png"))
        }
    }
    @MainActor private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua); host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url); window.contentView = nil
    }
}
