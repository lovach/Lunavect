import XCTest
import os
@testable import Weekleft
import WeekleftCore

// The store's fetch and settle parameters are nonisolated async closures, so
// their type does not promise where the fixtures run. Declared @Sendable, the
// fixtures below reach shared test state only through locks, and the compiler
// checks that (strict concurrency / Swift 6 language mode).
private typealias Resumption = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>
private extension OSAllocatedUnfairLock where State == CheckedContinuation<Void, Never>? {
    /// Parks the caller until `resume()` is called from the test.
    func park(_ started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in withLock { $0 = continuation }; started.fulfill() }
    }
    func resume() { withLock { $0.take() }?.resume() }
}

final class AppStoreLifecycleTests: XCTestCase {
    @MainActor func testCancelledRefreshDoesNotStartProviderWork() async {
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex, .claude]
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = AppStore(state: SharedState(preferences: preferences), quotaFetcher: { @Sendable id, _ in
            calls.withLock { $0 += 1 }; return UsageSnapshot(provider: id)
        }, isolated: true)
        let request = Task { await store.refresh() }
        request.cancel()
        await request.value
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertFalse(store.refreshing)
    }

    @MainActor func testIsolatedStoreDoesNotUsePersistedPathOrStartImports() async throws {
        let suite = "AppStoreIsolation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/fixture/original-codex", forKey: "codexPath")
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let store = AppStore(state: SharedState(snapshots: [], preferences: preferences), isolated: true, defaults: defaults)
        XCTAssertEqual(store.codexPath, "")
        XCTAssertEqual(store.activityHistory, ActivityHistory())
        XCTAssertEqual(store.activityDetails, ActivityDetails())
        store.codexPath = "/fixture/changed-codex"
        store.start(); store.importActivityHistory(); await store.refresh()
        XCTAssertFalse(store.importingActivity)
        XCTAssertFalse(store.snapshots.contains { $0.provider == .codex })
        XCTAssertEqual(defaults.string(forKey: "codexPath"), "/fixture/original-codex")
        store.stop()
    }

    @MainActor func testStoppedStoreRejectsLateQuotaResponseAndCanRefreshAgain() async throws {
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let old = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        let started = expectation(description: "Request started")
        let resumption = Resumption(initialState: nil), calls = OSAllocatedUnfairLock(initialState: 0)
        let store = AppStore(state: SharedState(snapshots: [old], preferences: preferences), quotaFetcher: { @Sendable id, _ in
            if calls.withLock({ $0 += 1; return $0 }) == 1 { await resumption.park(started) }
            return try UsageSnapshot(provider: id, weekly: QuotaWindow(usedPercent: 80, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        }, isolated: true)
        let request = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 5)
        store.stop()
        resumption.resume()
        await request.value
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 40)
        XCTAssertFalse(store.refreshing)
        await store.refresh()
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 80)
    }

    @MainActor func testChangingCodexPathRejectsLateResponseEvenWhenChangedBack() async throws {
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let old = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        let started = expectation(description: "Old executable request started")
        let resumption = Resumption(initialState: nil), paths = OSAllocatedUnfairLock(initialState: [String]())
        let store = AppStore(state: SharedState(snapshots: [old], preferences: preferences), quotaFetcher: { @Sendable id, path in
            if paths.withLock({ $0.append(path); return $0.count }) == 1 { await resumption.park(started) }
            return try UsageSnapshot(provider: id, weekly: QuotaWindow(usedPercent: 80, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        }, isolated: true)
        store.codexPath = "/fixture/original-codex"
        let request = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 5)
        store.codexPath = "/fixture/new-codex"
        store.codexPath = "/fixture/original-codex"
        resumption.resume()
        await request.value
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 40, "A response started before a connection change is obsolete")
        XCTAssertFalse(store.refreshing)
        store.codexPath = "/fixture/new-codex"
        await store.refresh()
        XCTAssertEqual(paths.withLock { $0 }, ["/fixture/original-codex", "/fixture/new-codex"])
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 80)
    }

    @MainActor func testPreferenceBurstFlushesOnlyFinalEditAndDoesNotWriteAgain() async throws {
        let scheduler = DeferredWrite(delay: .milliseconds(20))
        var values: [Int] = []
        for value in 0..<100 { scheduler.schedule { values.append(value) } }
        XCTAssertTrue(values.isEmpty)
        scheduler.flush()
        XCTAssertEqual(values, [99])
        let completed = expectation(description: "A later edit is saved")
        scheduler.schedule { values.append(100); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        scheduler.flush()
        XCTAssertEqual(values, [99, 100])
    }

    @MainActor func testCancelledDeferredWriteDoesNotRun() async {
        let scheduler = DeferredWrite(delay: .milliseconds(10))
        let written = expectation(description: "Cancelled edit must not be written"); written.isInverted = true
        scheduler.schedule { written.fulfill() }
        scheduler.cancel()
        scheduler.flush()
        await fulfillment(of: [written], timeout: 0.04)
    }

    @MainActor func testNetworkStopCancelsPendingRecovery() async {
        let waiting = expectation(description: "Network stabilization pending")
        let restored = expectation(description: "Stopped monitor must not restore"); restored.isInverted = true
        let resumption = Resumption(initialState: nil)
        let network = NetworkConnection(settle: { @Sendable in await resumption.park(waiting) })
        network.onRestored = { restored.fulfill() }
        network.update(available: false); network.update(available: true)
        await fulfillment(of: [waiting], timeout: 5)
        network.stop(); resumption.resume()
        await fulfillment(of: [restored], timeout: 0.04)
        XCTAssertFalse(network.restoring)
    }
}
