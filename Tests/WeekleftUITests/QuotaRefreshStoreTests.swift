import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// The app's refresh triggers (timer, wake, network, session events, reset time,
/// explicit refresh) with an injected clock, schedulers and providers. No client
/// is started and nothing outside a temporary directory is written.
@MainActor final class QuotaRefreshStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor final class Harness {
        struct Delay { let fireAt: Date; let action: @MainActor () -> Void; var cancelled = false }
        var now: Date
        var ticks: [TimeInterval: @MainActor () -> Void] = [:]
        var wake: (@MainActor () -> Void)?
        var delays: [Delay] = []
        var probes: [Date] = []
        var codexFetches: [Date] = []
        var stored: [ProviderID: UsageSnapshot] = [:]
        var result: (ProviderID, Date) throws -> UsageSnapshot = { id, _ in throw UsageError.timeout }
        /// Keeps a probe in flight until the test releases it.
        var hold: (() async -> Void)?
        init(now: Date) { self.now = now }
        var pending: [Delay] { delays.filter { !$0.cancelled } }
        /// Pending actions due within the next hour (not the far reset timers).
        var soon: [Delay] { pending.filter { $0.fireAt.timeIntervalSince(now) < 3600 } }
        /// Runs the one-shot actions that are due by `now`, in order.
        func fireDue() {
            let due = delays.indices.filter { !delays[$0].cancelled && delays[$0].fireAt <= now }
            for index in due { delays[index].cancelled = true }
            for index in due { delays[index].action() }
        }
        func minutes(_ dates: [Date], from start: Date) -> [Int] { dates.map { Int(($0.timeIntervalSince(start) / 60).rounded()) } }
    }

    private func drain() async { for _ in 0..<60 { await Task.yield() } }

    private func makeStore(_ h: Harness, snapshots: [UsageSnapshot], providers: [ProviderID],
                           network: NetworkConnection? = nil) throws -> AppStore {
        let network = network ?? NetworkConnection(settle: {}, makeMonitor: { nil })
        let suite = "QuotaRefreshStore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var preferences = WidgetPreferences(); preferences.enabledProviders = providers
        for snapshot in snapshots { h.stored[snapshot.provider] = snapshot }
        let scheduling = AppRefreshScheduling(
            repeating: { interval, action in h.ticks[interval] = action; return {} },
            wake: { action in h.wake = action; return {} },
            after: { delay, action in
                h.delays.append(.init(fireAt: h.now.addingTimeInterval(delay), action: action))
                let index = h.delays.count - 1
                return { h.delays[index].cancelled = true }
            })
        let store = AppStore(state: .init(snapshots: snapshots, preferences: preferences), network: network, defaults: defaults,
            dataServices: .init(snapshots: SnapshotPersistence(url: root.appendingPathComponent("snapshot.json")),
                activity: ActivityService(isolated: true), clock: { h.now }, localQuota: { _ in nil },
                refreshQuota: { id, _, force in
                    if id == .claude {
                        // Production path: ClaudeProvider applies its own cache rule to `force == false`.
                        return try await ClaudeProvider.refresh(force: force, now: h.now, cached: {
                            guard let saved = h.stored[.claude] else { throw UsageError.waitingForClaude }
                            return saved
                        }, probe: {
                            h.probes.append(h.now)
                            if let hold = h.hold { await hold() }
                            return try h.result(.claude, h.now)
                        }, save: { h.stored[.claude] = $0 })
                    }
                    // Like CodexProvider.fetch: every call starts the app-server.
                    h.codexFetches.append(h.now)
                    let snapshot = try h.result(.codex, h.now)
                    h.stored[.codex] = snapshot
                    return snapshot
                }, scheduling: scheduling, discoverCodex: { nil }))
        addTeardownBlock { await MainActor.run { store.stop() } }
        return store
    }
    private func claude(used: Double, fetchedAt: Date, reset: Date?) throws -> UsageSnapshot {
        try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: used, durationMinutes: 10080, resetsAt: reset, resetPrecision: .minute),
                          fetchedAt: fetchedAt, source: ClaudeUsageProbe.source)
    }
    private func row(_ provider: ProviderID = .claude, updatedAt: Date, evidence: SessionEvidence = .hook) -> AgentSession {
        AgentSession(provider: provider, sessionID: "fixture-" + provider.rawValue, title: "Fixture", cwd: "/fixture", client: .desktop,
                     phase: .ready, updatedAt: updatedAt, observedAt: updatedAt, evidence: evidence)
    }

    // Q-01: the five-minute timer evaluates; it is not the probe period.
    func testTimerTicksDoNotProbeEveryFiveMinutes() async throws {
        let h = Harness(now: start)
        let fresh = try claude(used: 40, fetchedAt: start, reset: start.addingTimeInterval(3 * 86400))
        h.result = { _, date in try self.claude(used: 41, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        let store = try makeStore(h, snapshots: [fresh], providers: [.claude])
        store.start(); await drain()
        for minute in stride(from: 5.0, through: 50, by: 5) {
            h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await drain()
        }
        XCTAssertEqual(h.probes.count, 0, "Idle: a verified observation is reused for an hour")
        h.now = start.addingTimeInterval(65 * 60); h.ticks[300]?(); await drain()
        XCTAssertEqual(h.probes.count, 1)
    }

    // Q-01 / 01-quota.md §6 п.6, matrix L11: failures back off 5 -> 10 -> 20 -> 40 -> 60 min; wake resets.
    func testRepeatedProbeFailuresBackOffAndWakeStartsOver() async throws {
        let failures: [(Error, String?)] = [
            (ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .usageFetchFailed),
             ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .usageFetchFailed).message),
            (UsageError.claudeSignInRequired, UsageError.claudeSignInRequired.errorDescription),
        ]
        for (failure, message) in failures {
            let h = Harness(now: start)
            let saved = try claude(used: 40, fetchedAt: start.addingTimeInterval(-2 * 3600), reset: start.addingTimeInterval(3 * 86400))
            h.result = { _, _ in throw failure }
            let store = try makeStore(h, snapshots: [saved], providers: [.claude])
            store.start(); await drain()
            for minute in stride(from: 5.0, through: 120, by: 5) {
                h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await drain()
            }
            XCTAssertEqual(h.minutes(h.probes, from: start), [0, 5, 15, 35, 75], "\(failure)")
            XCTAssertEqual(store.snapshots.first?.weekly, saved.weekly, "The last real observation stays")
            XCTAssertEqual(store.snapshots.first?.issue, message)
            h.now = start.addingTimeInterval(121 * 60)
            h.wake?(); await drain()
            XCTAssertEqual(h.probes.count, 5, "Wake waits for the network to settle")
            h.now = h.now.addingTimeInterval(5); h.fireDue(); await drain()
            XCTAssertEqual(h.probes.count, 6, "Wake starts the backoff over")
        }
    }

    // Q-08, matrix L8: slept through the weekly reset.
    func testWakeAfterAResetProbesOnceAfterSettleAndOnlyOnline() async throws {
        for sleptAfterReset in [30.0 * 60, 2.0 * 3600] {
            let h = Harness(now: start)
            let reset = start.addingTimeInterval(3600)
            let exhausted = try claude(used: 100, fetchedAt: start, reset: reset)
            h.result = { _, date in try self.claude(used: 3, fetchedAt: date, reset: reset.addingTimeInterval(7 * 86400)) }
            let network = NetworkConnection(settle: {}, makeMonitor: { nil })
            let store = try makeStore(h, snapshots: [exhausted], providers: [.claude], network: network)
            store.start(); await drain()
            XCTAssertEqual(h.probes.count, 0, "0% remaining before the reset: no probe at launch")
            h.now = reset.addingTimeInterval(sleptAfterReset)
            h.wake?(); await drain()
            XCTAssertEqual(h.probes.count, 0, "Not before the network has settled")
            network.update(available: false)
            h.now = h.now.addingTimeInterval(5); h.fireDue(); await drain()
            XCTAssertEqual(h.probes.count, 0, "Offline after wake: wait for the connection")
            network.update(available: true); await drain()
            XCTAssertEqual(h.probes.count, 1, "The restored connection asks once")
            h.wake?(); await drain(); h.now = h.now.addingTimeInterval(5); h.fireDue(); await drain()
            XCTAssertEqual(h.probes.count, 1, "The new observation is current")
            XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 3)
        }
    }

    // Q-01 trigger 2: a finished response is a quota change; probe after a quiet debounce.
    func testSessionEventsProbeAfterDebounceAndSwitchToTheActiveInterval() async throws {
        let h = Harness(now: start)
        let fresh = try claude(used: 40, fetchedAt: start, reset: start.addingTimeInterval(3 * 86400))
        func codex(_ date: Date) throws -> UsageSnapshot {
            try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: self.start.addingTimeInterval(4 * 86400)),
                              fetchedAt: date, source: "Codex CLI")
        }
        h.result = { id, date in id == .codex ? try codex(date) : try self.claude(used: 45, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        let store = try makeStore(h, snapshots: [fresh, try codex(start)], providers: [.claude, .codex])
        store.start(); await drain()
        let launchFetches = h.codexFetches.count
        store.observeSessionEvents([row(updatedAt: start.addingTimeInterval(-600))], now: start)
        XCTAssertTrue(h.soon.isEmpty, "Rows already on disk at launch are the baseline, not new events")
        h.now = start.addingTimeInterval(60); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        h.now = start.addingTimeInterval(90); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        XCTAssertEqual(h.soon.count, 1, "A burst of events is debounced into one evaluation")
        h.now = start.addingTimeInterval(170); h.fireDue(); await drain()
        XCTAssertEqual(h.probes.count, 0, "Debounce waits for 90 s of quiet after the last event")
        h.now = start.addingTimeInterval(181); h.fireDue(); await drain()
        XCTAssertEqual(h.probes.count, 1, "Data older than two minutes is refreshed after the quiet period")
        XCTAssertEqual(h.codexFetches.count, launchFetches, "A Claude event does not ask Codex")
        h.now = start.addingTimeInterval(200); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        h.now = start.addingTimeInterval(291); h.fireDue(); await drain()
        XCTAssertEqual(h.probes.count, 1, "An observation younger than two minutes is kept")
        store.observeSessionEvents([row(updatedAt: h.now, evidence: .catalog)], now: h.now)
        XCTAssertTrue(h.soon.isEmpty, "Catalog rows (including the probe's own) are not session events")
        h.now = start.addingTimeInterval(181 + 15 * 60 + 5); h.ticks[300]?(); await drain()
        XCTAssertEqual(h.probes.count, 2, "With recent activity the 15-minute interval applies")
    }

    // Q-01 trigger 4: explicit refresh at most once per 30 s.
    func testExplicitRefreshAsksAtMostOncePerThirtySeconds() async throws {
        let h = Harness(now: start)
        let fresh = try claude(used: 40, fetchedAt: start.addingTimeInterval(-60), reset: start.addingTimeInterval(3 * 86400))
        h.result = { _, date in try self.claude(used: 41, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        let store = try makeStore(h, snapshots: [fresh], providers: [.claude])
        await store.refresh(); await store.refresh()
        XCTAssertEqual(h.probes.count, 1)
        h.now = start.addingTimeInterval(31); await store.refresh()
        XCTAssertEqual(h.probes.count, 2)
    }

    // Q-09, 01-quota.md §6 п.20: Codex uses the same states and intervals.
    func testCodexIsNotAskedEveryFiveMinutes() async throws {
        let h = Harness(now: start)
        let reset = start.addingTimeInterval(2 * 3600)
        let exhausted = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: reset),
                                          fetchedAt: start, source: "Codex CLI")
        h.result = { _, date in try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 2, durationMinutes: 10080, resetsAt: reset.addingTimeInterval(7 * 86400)),
                                                  fetchedAt: date, source: "Codex CLI") }
        let store = try makeStore(h, snapshots: [exhausted], providers: [.codex])
        store.start(); await drain()
        for minute in stride(from: 5.0, through: 120, by: 5) {
            h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await drain()
        }
        XCTAssertEqual(h.codexFetches.count, 0, "Exhausted until the reset")
        h.now = reset.addingTimeInterval(6); h.fireDue(); h.ticks[300]?(); await drain()
        XCTAssertEqual(h.codexFetches.count, 1, "One confirming request after the exact reset plus 5 s")
        for minute in stride(from: 5.0, through: 50, by: 5) {
            h.now = reset.addingTimeInterval(6 + minute * 60); h.ticks[300]?(); await drain()
        }
        XCTAssertEqual(h.codexFetches.count, 1)
    }

    // Q-01 trigger 5: a one-shot timer at resetsAt + grace.
    func testResetTimerRunsOneConfirmingProbeAtResetPlusGrace() async throws {
        let h = Harness(now: start)
        let reset = start.addingTimeInterval(40 * 60)
        let exhausted = try claude(used: 100, fetchedAt: start, reset: reset)
        h.result = { _, date in try self.claude(used: 0, fetchedAt: date, reset: nil) }
        let store = try makeStore(h, snapshots: [exhausted], providers: [.claude])
        store.start(); await drain()
        // WP-1b: the reset is the end of the shown minute, so the probe's grace is 30 s.
        let timer = try XCTUnwrap(h.pending.first { abs($0.fireAt.timeIntervalSince(reset.addingTimeInterval(30))) < 1 },
                                  "Scheduled for the reset plus the probe's grace")
        XCTAssertNotNil(timer)
        h.now = reset.addingTimeInterval(30); h.fireDue(); await drain()
        XCTAssertEqual(h.probes.count, 1)
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 0)
        XCTAssertNil(store.snapshots.first?.weekly?.resetsAt, "The new window starts with the first request")
    }

    // Matrix L3: one probe at a time; a second request while one runs is not a second process.
    func testOnlyOneProbeRunsAtATime() async throws {
        let h = Harness(now: start)
        let stale = try claude(used: 40, fetchedAt: start.addingTimeInterval(-7200), reset: start.addingTimeInterval(3 * 86400))
        h.result = { _, date in try self.claude(used: 41, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        var release: CheckedContinuation<Void, Never>?
        h.hold = { await withCheckedContinuation { release = $0 } }
        let store = try makeStore(h, snapshots: [stale], providers: [.claude])
        let first = Task { await store.refresh() }
        await drain()
        XCTAssertTrue(store.refreshing)
        XCTAssertEqual(h.probes.count, 1)
        h.hold = nil
        h.now = start.addingTimeInterval(45)
        await store.refresh()
        await drain()
        XCTAssertEqual(h.probes.count, 1, "A refresh while the probe runs does not start another client")
        release?.resume()
        await first.value
        XCTAssertEqual(h.probes.count, 1)
        XCTAssertFalse(store.refreshing)
    }
}
