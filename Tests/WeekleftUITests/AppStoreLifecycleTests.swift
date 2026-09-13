import XCTest
@testable import Weekleft
import WeekleftCore

final class AppStoreLifecycleTests: XCTestCase {
    @MainActor func testCancelledRefreshDoesNotStartProviderWork() async {
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex, .claude]
        var calls = 0
        let store = AppStore(state: SharedState(preferences: preferences), quotaFetcher: { id, _ in
            calls += 1; return UsageSnapshot(provider: id)
        }, isolated: true)
        let request = Task { await store.refresh() }
        request.cancel()
        await request.value
        XCTAssertEqual(calls, 0)
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
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0
        let store = AppStore(state: SharedState(snapshots: [old], preferences: preferences), quotaFetcher: { id, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
            }
            return try UsageSnapshot(provider: id, weekly: QuotaWindow(usedPercent: 80, durationMinutes: 10080, resetsAt: nil), fetchedAt: Date())
        }, isolated: true)
        let request = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        store.stop()
        resume?.resume()
        await request.value
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 40)
        XCTAssertFalse(store.refreshing)
        await store.refresh()
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
        await fulfillment(of: [completed], timeout: 2)
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
        var resume: CheckedContinuation<Void, Never>?
        let network = NetworkConnection(settle: {
            await withCheckedContinuation { continuation in resume = continuation; waiting.fulfill() }
        })
        network.onRestored = { restored.fulfill() }
        network.update(available: false); network.update(available: true)
        await fulfillment(of: [waiting], timeout: 2)
        network.stop(); resume?.resume()
        await fulfillment(of: [restored], timeout: 0.04)
        XCTAssertFalse(network.restoring)
    }
}
