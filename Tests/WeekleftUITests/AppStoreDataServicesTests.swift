import XCTest
@testable import Weekleft
import WeekleftCore

final class AppStoreDataServicesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor func testTypedIntegrationFailureKeepsQuotaAndSpecificDiagnostic() async throws {
        for provider in ProviderID.allCases {
            let failure = ClientIntegrationIssue(provider: provider, capability: .rateLimits, reason: .unsupportedResponse)
            let quota = try QuotaWindow(usedPercent: 42, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600))
            let saved = UsageSnapshot(provider: provider, weekly: quota, fetchedAt: now,
                                      source: provider == .claude ? "Claude Code statusLine" : "Codex CLI")
            var preferences = WidgetPreferences(); preferences.enabledProviders = [provider]
            let store = AppStore(state: .init(snapshots: [saved], preferences: preferences), quotaFetcher: { _, _ in throw failure }, isolated: true)
            await store.refresh()
            let current = try XCTUnwrap(store.snapshots.first { $0.provider == provider })
            XCTAssertEqual(current.weekly, saved.weekly)
            XCTAssertEqual(current.fetchedAt, saved.fetchedAt)
            XCTAssertEqual(current.issue, failure.message)
            XCTAssertTrue(current.isStale(now: now))
            store.stop()
        }
    }
    @MainActor func testFinalStopRetriesFailedSnapshotAndIgnoresItsLateErrorCallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AppStoreData." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/fixture/codex", forKey: "codexPath")
        let failed = expectation(description: "First write fails")
        let file = root.appendingPathComponent("snapshot.json")
        let writes = DataWorkCounter()
        let persistence = SnapshotPersistence(url: file, write: { state, url in
            XCTAssertFalse(Thread.isMainThread)
            writes.add()
            if writes.value == 1 { failed.fulfill(); throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LocalStateRecovery.write(JSONEncoder().encode(state), to: url)
        })
        let snapshot = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 42, durationMinutes: 10080, resetsAt: nil), fetchedAt: now)
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let store = AppStore(state: .init(snapshots: [snapshot], preferences: preferences), quotaFetcher: { _, _ in snapshot },
            defaults: defaults, dataServices: .init(snapshots: persistence, activity: ActivityService(isolated: true), clock: { self.now }))
        await store.refresh()
        await fulfillment(of: [failed], timeout: 3)
        for index in 0..<100 { store.preferences.transparency = 0.2 + Double(index) / 200 }
        store.stop()
        let saved = SnapshotStore.load(from: file)
        XCTAssertEqual(saved.preferences, store.preferences)
        XCTAssertEqual(saved.snapshots, store.snapshots)
        XCTAssertNil(store.storageIssue)
        // Allow the earlier queued failure callback to arrive after the final flush.
        let drained = expectation(description: "Main callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertNil(store.storageIssue)
        await store.refresh(); store.stop()
        XCTAssertEqual(persistence.counters.failed, 1)
        XCTAssertEqual(persistence.counters.written, 1)
        XCTAssertEqual(writes.value, 2, "Same quota and preferences never rewrite a successfully saved value")
    }
    @MainActor func testIsolatedStoreOverridesInjectedDiskServicesAndUsesFixtureClock() async throws {
        let work = DataWorkCounter()
        let persistence = SnapshotPersistence(url: URL(fileURLWithPath: "/unused/snapshot"), read: { _ in work.add(); return .init() },
            write: { _, _ in work.add() }, reload: { work.add() })
        let activityStorage = ActivityPersistence(historyURL: URL(fileURLWithPath: "/unused/history"), detailsURL: URL(fileURLWithPath: "/unused/details"),
            writeHistory: { _, _ in work.add() }, writeDetails: { _, _ in work.add() })
        let externalActivity = ActivityService(history: .init(), details: .init(), storage: activityStorage, importer: { _, _, _ in work.add(); return .init() })
        var date = now
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let store = AppStore(state: .init(snapshots: [], preferences: preferences), isolated: true,
            dataServices: .init(snapshots: persistence, activity: externalActivity, clock: { date }))
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Fixture", cwd: "/fixture", phase: .running,
                               updatedAt: now, observedAt: now, runtimeConfirmed: true)
        store.observeActivity([row]); date = now.addingTimeInterval(5); store.observeActivity([row]); store.flushActivity()
        XCTAssertEqual(store.activityHistory.summary(now: date).totals.active, 5)
        store.preferences.transparency = 0.7; store.start(); store.importActivityHistory(); await store.refresh(); store.stop()
        XCTAssertEqual(work.value, 0)
        XCTAssertEqual(persistence.counters.submitted, 0)
        XCTAssertEqual(activityStorage.counters.submitted, 0)
    }
    @MainActor func testDisableAndReenableRejectsQuotaRequestedBeforeSelectionChanged() async throws {
        let began = expectation(description: "Quota request starts")
        var continuation: CheckedContinuation<Void, Never>?
        let initial = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: nil), fetchedAt: now)
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let store = AppStore(state: .init(snapshots: [initial], preferences: preferences), quotaFetcher: { _, _ in
            await withCheckedContinuation { continuation = $0; began.fulfill() }
            return try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 90, durationMinutes: 10080, resetsAt: nil), fetchedAt: self.now)
        }, isolated: true)
        let task = Task { await store.refresh() }
        await fulfillment(of: [began], timeout: 3)
        store.setProvider(.codex, enabled: false); store.setProvider(.codex, enabled: true)
        continuation?.resume(); await task.value
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 10)
        XCTAssertFalse(store.refreshing)
        store.stop()
    }
}
private final class DataWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
