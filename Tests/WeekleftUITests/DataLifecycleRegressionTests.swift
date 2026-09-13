import XCTest
import Combine
@testable import Weekleft
@testable import WeekleftCore

final class DataLifecycleRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    @MainActor private func idle(_ service: ActivityService) async {
        guard service.importing else { return }
        let done = expectation(description: "Import completes")
        let token = service.$importing.dropFirst().filter { !$0 }.first().sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 3); token.cancel()
    }
    @MainActor func testLateProviderAutomaticallyImportsUntilEnablementAndKeepsBoundaryOnRetry() async throws {
        let date = DataClock(now)
        let codexStart = now.addingTimeInterval(3600), codexEnd = now.addingTimeInterval(7200)
        let calls = DataCalls()
        let service = ActivityService(clock: { date.now }, importer: { providers, boundary, _ in
            calls.record(providers: providers, boundary: boundary)
            var result = ActivityImportResult()
            if providers.contains(.codex), codexStart < boundary {
                result.intervals = [.init(start: codexStart, end: min(boundary, codexEnd), providers: 2)]
            }
            return result
        })
        service.start(providers: [.claude]); await idle(service)
        date.now = now.addingTimeInterval(86400)
        service.setProviders([.claude, .codex]); await idle(service)
        XCTAssertEqual(service.history.summary(now: date.now).totals.codex, 3600)
        XCTAssertEqual(service.history.providerImportCutoffs?["claude"], now)
        XCTAssertEqual(service.history.providerImportCutoffs?["codex"], date.now)
        service.setProviders([.claude]); service.setProviders([.claude, .codex]); await idle(service)
        service.requestImport(); await idle(service)
        XCTAssertEqual(service.history.summary(now: date.now).totals.codex, 3600)
        XCTAssertEqual(Set(calls.values.filter { $0.0.contains(.codex) }.map(\.1)), [date.now])
        let encoded = try JSONEncoder().encode(service.history)
        XCTAssertEqual(try JSONDecoder().decode(ActivityHistory.self, from: encoded), service.history)
        service.stop()
    }
    func testLegacyImportBoundaryMigratesOnlyPreviouslyObservedProviders() throws {
        var history = ActivityHistory()
        _ = history.prepareImport(now: now)
        history.mergeRecovered([.init(start: now.addingTimeInterval(-60), end: now, providers: 1)], now: now, limited: false)
        let legacy = try JSONEncoder().encode(history)
        var migrated = try JSONDecoder().decode(ActivityHistory.self, from: legacy)
        let enabled = now.addingTimeInterval(86400)
        let boundaries = migrated.prepareImport(providers: [.claude, .codex], now: enabled)
        XCTAssertEqual(boundaries[.claude], now)
        XCTAssertEqual(boundaries[.codex], enabled)
    }
    @MainActor func testIdleCheckpointsFiveMinutesButWorkRetainsMinuteAndQuitFlush() throws {
        let date = DataClock(now), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ActivityPersistence(historyURL: root.appendingPathComponent("history.json"), detailsURL: root.appendingPathComponent("details.json"), clock: { date.now })
        let service = ActivityService(history: .init(), details: .init(), storage: storage, clock: { date.now })
        service.setProviders([.codex])
        func row(_ phase: SessionPhase) -> AgentSession {
            AgentSession(
                provider: .codex, sessionID: "fixture", title: "Fixture", cwd: "/fixture", phase: phase,
                updatedAt: date.now, observedAt: date.now, runtimeConfirmed: true)
        }
        for seconds in stride(from: 0, through: 3595, by: 5) {
            date.now = now.addingTimeInterval(Double(seconds)); service.observe([row(.idle)])
        }
        service.flush()
        XCTAssertLessThanOrEqual(storage.counters.written, 13, "Initial state, at most twelve idle checkpoints including final flush")
        let beforeWork = storage.counters.written
        for seconds in stride(from: 3600, through: 3720, by: 5) {
            date.now = now.addingTimeInterval(Double(seconds)); service.observe([row(.running)])
        }
        service.stop()
        XCTAssertGreaterThanOrEqual(storage.counters.written - beforeWork, 3)
        XCTAssertEqual(try ActivityHistory.load(from: root.appendingPathComponent("history.json")), service.history)
        XCTAssertEqual(service.history.summary(now: date.now).totals.codex, 120)
    }
    func testTimestampOnlyQuotaWritesStayDurableWithoutReloadAndVisibleChangeReloads() throws {
        let date = DataClock(now), reloads = DataCount()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snapshot.json")
        let persistence = SnapshotPersistence(url: url, reload: { reloads.increment() }, clock: { date.now })
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let quota = try QuotaWindow(usedPercent: 42, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        var state = SharedState(snapshots: [UsageSnapshot(provider: .codex, weekly: quota, fetchedAt: now)], preferences: preferences)
        for minute in 0..<60 {
            date.now = now.addingTimeInterval(Double(minute) * 60); state.snapshots[0].fetchedAt = date.now
            _ = persistence.flush(state)
        }
        XCTAssertEqual(reloads.value, 1)
        XCTAssertEqual(SnapshotStore.load(from: url).snapshots[0].fetchedAt, date.now)
        state.snapshots[0].weekly = try QuotaWindow(usedPercent: 43, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        _ = persistence.flush(state)
        XCTAssertEqual(reloads.value, 2)
        state.snapshots[0].issue = "Fixture unavailable"; _ = persistence.flush(state)
        XCTAssertEqual(reloads.value, 3)
    }
    func testActivityWritesStayDurableWhileReloadRequestsAreCoalesced() {
        let date = DataClock(now), reloads = DataCount()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = ActivityPersistence(historyURL: root.appendingPathComponent("history.json"), detailsURL: root.appendingPathComponent("details.json"),
            writeHistory: { _, _ in }, writeDetails: { _, _ in }, reload: { reloads.increment() }, clock: { date.now })
        var history = ActivityHistory()
        for minute in 0..<60 {
            date.now = now.addingTimeInterval(Double(minute) * 60)
            history.append(start: date.now, end: date.now.addingTimeInterval(60), providers: 2, observedProviders: 2)
            _ = persistence.flush(.init(history: history, details: .init()))
        }
        XCTAssertEqual(persistence.counters.written, 60)
        XCTAssertEqual(reloads.value, 4)
    }
    @MainActor func testProductionStartLocalTimerWakeNetworkAndStopUseControlledSources() async throws {
        let date = DataClock(now), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DataLifecycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var ticks: [TimeInterval: @MainActor () -> Void] = [:], wake: (@MainActor () -> Void)?
        var cancelled = 0, forced: [Bool] = [], probes = 0
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude]
        let cached = try UsageSnapshot(
            provider: .claude,
            weekly: QuotaWindow(usedPercent: 55, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now, source: ClaudeUsageProbe.source)
        let fetchCalls = expectation(description: "start wake timer network and manual"); fetchCalls.expectedFulfillmentCount = 5
        let localRead = expectation(description: "local timer read")
        let network = NetworkConnection(settle: {}, makeMonitor: { nil })
        let scheduling = AppRefreshScheduling(repeating: { interval, action in ticks[interval] = action; return { cancelled += 1 } }, wake: { action in wake = action; return { cancelled += 1 } })
        let store = AppStore(state: .init(snapshots: [cached], preferences: preferences), network: network, defaults: defaults,
            dataServices: .init(snapshots: SnapshotPersistence(url: root.appendingPathComponent("snapshot.json")), activity: ActivityService(isolated: true), clock: { date.now },
                localQuota: { _ in localRead.fulfill(); return cached }, refreshQuota: { _, _, force in
                    forced.append(force); defer { fetchCalls.fulfill() }
                    return try await ClaudeProvider.refresh(force: force, now: date.now, cached: { cached }, probe: { probes += 1; return cached }, save: { _ in })
                }, scheduling: scheduling, discoverCodex: { "/fixture/automatic-codex" }))
        func drain() async { for _ in 0..<30 { await Task.yield() } }
        store.start(); store.start(); await drain()
        ticks[5]?(); await fulfillment(of: [localRead], timeout: 3)
        wake?(); await drain(); ticks[300]?(); await drain()
        network.update(available: false); network.update(available: true); await drain()
        await store.refresh(); await fulfillment(of: [fetchCalls], timeout: 3)
        XCTAssertEqual(forced.filter { $0 }.count, 1)
        XCTAssertEqual(probes, 1, "Only explicit refresh bypasses the fresh cache")
        XCTAssertEqual(store.codexPath, "")
        XCTAssertNil(defaults.string(forKey: "codexPath"))
        store.stop(); XCTAssertEqual(cancelled, 3)
        wake?(); ticks[5]?(); ticks[300]?(); await drain()
        XCTAssertEqual(forced.count, 5)
    }
}
private final class DataClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
}
private final class DataCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class DataCalls: @unchecked Sendable {
    private let lock = NSLock(); private var calls: [(Set<ProviderID>, Date)] = []
    var values: [(Set<ProviderID>, Date)] { lock.withLock { calls } }
    func record(providers: Set<ProviderID>, boundary: Date) { lock.withLock { calls.append((providers, boundary)) } }
}
