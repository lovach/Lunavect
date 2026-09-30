import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// Waits (at most 5 s of wall time) until no quota request runs or waits and
/// `condition` holds. Replaces a fixed number of `Task.yield()` calls (R1-13):
/// the refresh leaves the main actor for the providers and comes back, so a count
/// of yields proves neither that work finished nor that it never started.
@MainActor func settleQuota(_ store: AppStore, until condition: @MainActor () -> Bool = { true },
                            file: StaticString = #filePath, line: UInt = #line) async {
    await waitForQuota(until: { store.quotaRefreshIdle && condition() }, file: file, line: line)
}
/// Waits (at most 5 s of wall time) for a condition while work may still be in flight.
@MainActor func waitForQuota(until condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var spins = 0
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return XCTFail("Quota refresh did not reach the expected state within 5 s", file: file, line: line)
        }
        spins += 1
        if spins < 200 { await Task.yield() } else { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}

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
        /// Keeps a probe (or a Codex request) in flight until the test releases it.
        var hold: (() async -> Void)?
        var holdCodex: (() async -> Void)?
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


    private func settle(_ store: AppStore, file: StaticString = #filePath, line: UInt = #line) async {
        await settleQuota(store, file: file, line: line)
    }
    private func wait(until condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await waitForQuota(until: condition, file: file, line: line)
    }

    private func makeStore(_ h: Harness, snapshots: [UsageSnapshot], providers: [ProviderID],
                           network: NetworkConnection? = nil,
                           local: @escaping @Sendable (Date) async -> UsageSnapshot? = { _ in nil }) throws -> AppStore {
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
                activity: ActivityService(isolated: true), clock: { h.now }, localQuota: local,
                refreshQuota: { id, _, _ in
                    if id == .claude {
                        // Production path: the store's policy has decided; ClaudeProvider probes
                        // and falls back to the saved observation with the failure as its issue.
                        return try await ClaudeProvider.refresh(cached: {
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
                    if let hold = h.holdCodex { await hold() }
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
        store.start(); await settle(store)
        for minute in stride(from: 5.0, through: 50, by: 5) {
            h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await settle(store)
        }
        XCTAssertEqual(h.probes.count, 0, "Idle: a verified observation is reused for an hour")
        h.now = start.addingTimeInterval(65 * 60); h.ticks[300]?(); await settle(store)
        XCTAssertEqual(h.probes.count, 1)
    }

    // Q-01 / 01-quota.md §6 п.6, matrix L11: failures back off 5 -> 10 -> 20 -> 40 -> 60 min;
    // wake starts over for a transient cause (R1-03: see the permanent causes below).
    func testRepeatedProbeFailuresBackOffAndWakeStartsOver() async throws {
        let failures: [(Error, String?)] = [
            (ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .usageFetchFailed),
             ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .usageFetchFailed).message),
            (ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .timedOut),
             ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .timedOut).message),
            (UsageError.timeout, UsageError.timeout.errorDescription),
        ]
        for (failure, message) in failures {
            let h = Harness(now: start)
            let saved = try claude(used: 40, fetchedAt: start.addingTimeInterval(-2 * 3600), reset: start.addingTimeInterval(3 * 86400))
            h.result = { _, _ in throw failure }
            let store = try makeStore(h, snapshots: [saved], providers: [.claude])
            store.start(); await settle(store)
            for minute in stride(from: 5.0, through: 120, by: 5) {
                h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await settle(store)
            }
            XCTAssertEqual(h.minutes(h.probes, from: start), [0, 5, 15, 35, 75], "\(failure)")
            XCTAssertEqual(store.snapshots.first?.weekly, saved.weekly, "The last real observation stays")
            XCTAssertEqual(store.snapshots.first?.issue, message)
            h.now = start.addingTimeInterval(121 * 60)
            h.wake?(); await settle(store)
            XCTAssertEqual(h.probes.count, 5, "Wake waits for the network to settle")
            h.now = h.now.addingTimeInterval(5); h.fireDue(); await settle(store)
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
            store.start(); await settle(store)
            XCTAssertEqual(h.probes.count, 0, "0% remaining before the reset: no probe at launch")
            h.now = reset.addingTimeInterval(sleptAfterReset)
            h.wake?(); await settle(store)
            XCTAssertEqual(h.probes.count, 0, "Not before the network has settled")
            network.update(available: false)
            h.now = h.now.addingTimeInterval(5); h.fireDue(); await settle(store)
            XCTAssertEqual(h.probes.count, 0, "Offline after wake: wait for the connection")
            network.update(available: true); await settle(store)
            XCTAssertEqual(h.probes.count, 1, "The restored connection asks once")
            h.wake?(); await settle(store); h.now = h.now.addingTimeInterval(5); h.fireDue(); await settle(store)
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
        store.start(); await settle(store)
        let launchFetches = h.codexFetches.count
        store.observeSessionEvents([row(updatedAt: start.addingTimeInterval(-600))], now: start)
        XCTAssertTrue(h.soon.isEmpty, "Rows already on disk at launch are the baseline, not new events")
        h.now = start.addingTimeInterval(60); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        h.now = start.addingTimeInterval(90); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        XCTAssertEqual(h.soon.count, 1, "A burst of events is debounced into one evaluation")
        h.now = start.addingTimeInterval(170); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 0, "Debounce waits for 90 s of quiet after the last event")
        h.now = start.addingTimeInterval(181); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 1, "Data older than two minutes is refreshed after the quiet period")
        XCTAssertEqual(h.codexFetches.count, launchFetches, "A Claude event does not ask Codex")
        h.now = start.addingTimeInterval(200); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        h.now = start.addingTimeInterval(291); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 1, "An observation younger than two minutes is kept")
        store.observeSessionEvents([row(updatedAt: h.now, evidence: .catalog)], now: h.now)
        XCTAssertTrue(h.soon.isEmpty, "Catalog rows (including the probe's own) are not session events")
        h.now = start.addingTimeInterval(181 + 15 * 60 + 5); h.ticks[300]?(); await settle(store)
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

    // Q-09, 01-quota.md §6 п.20: Codex uses the same intervals; a used-up Codex window is
    // asked about hourly, since a manual usage-limit reset lifts it early (owner report 30.09).
    func testCodexIsNotAskedEveryFiveMinutes() async throws {
        let h = Harness(now: start)
        let reset = start.addingTimeInterval(2 * 3600)
        let exhausted = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: reset),
                                          fetchedAt: start, source: "Codex CLI")
        h.result = { _, date in
            date < reset ? try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: reset), fetchedAt: date, source: "Codex CLI")
                : try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 2, durationMinutes: 10080, resetsAt: reset.addingTimeInterval(7 * 86400)),
                                    fetchedAt: date, source: "Codex CLI")
        }
        let store = try makeStore(h, snapshots: [exhausted], providers: [.codex])
        store.start(); await settle(store)
        for minute in stride(from: 5.0, through: 115, by: 5) {
            h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await settle(store)
        }
        XCTAssertEqual(h.codexFetches.count, 1, "Used up: once an hour, not every five minutes")
        h.codexFetches.removeAll()
        h.now = reset.addingTimeInterval(6); h.fireDue(); h.ticks[300]?(); await settle(store)
        XCTAssertEqual(h.codexFetches.count, 1, "One confirming request after the exact reset plus 5 s")
        for minute in stride(from: 5.0, through: 50, by: 5) {
            h.now = reset.addingTimeInterval(6 + minute * 60); h.ticks[300]?(); await settle(store)
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
        store.start(); await settle(store)
        // WP-1b: the reset is the end of the shown minute, so the probe's grace is 30 s.
        let timer = try XCTUnwrap(h.pending.first { abs($0.fireAt.timeIntervalSince(reset.addingTimeInterval(30))) < 1 },
                                  "Scheduled for the reset plus the probe's grace")
        XCTAssertNotNil(timer)
        h.now = reset.addingTimeInterval(30); h.fireDue(); await settle(store)
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
        await wait(until: { h.probes.count == 1 && release != nil })
        XCTAssertTrue(store.refreshing)
        h.hold = nil
        h.now = start.addingTimeInterval(45)
        await store.refresh()
        XCTAssertEqual(h.probes.count, 1, "A refresh while the probe runs does not start another client")
        release?.resume()
        _ = await first.value
        await settle(store)
        XCTAssertEqual(h.probes.count, 1)
        XCTAssertFalse(store.refreshing)
    }

    // MARK: Review R1 (2026-09-28)

    /// R1-01, the owner's complaint ("when limits are exhausted the probe keeps
    /// appearing"): a used-up week cannot change before its reset, whatever the
    /// other window does. The five-hour reset passes in the middle, every screen
    /// before the weekly reset is unreadable, the Mac wakes, the network returns and
    /// sessions keep reporting events: no probe until the weekly reset plus grace,
    /// then exactly one confirmation.
    func testExhaustedWeekIsNotProbedWhenTheFiveHourResetPassesInTheMiddle() async throws {
        let h = Harness(now: start)
        let weeklyReset = start.addingTimeInterval(3 * 86400), fiveReset = start.addingTimeInterval(2 * 3600)
        let exhausted = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: weeklyReset, resetPrecision: .minute),
            fiveHour: QuotaWindow(usedPercent: 60, durationMinutes: 300, resetsAt: fiveReset, resetPrecision: .minute),
            fetchedAt: start.addingTimeInterval(-600), source: ClaudeUsageProbe.source)
        let unreadable = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .unsupportedResponse)
        h.result = { _, date in
            guard date >= weeklyReset else { throw unreadable }
            return try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil),
                                     fiveHour: QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil),
                                     fetchedAt: date, source: ClaudeUsageProbe.source)
        }
        let network = NetworkConnection(settle: {}, makeMonitor: { nil })
        let store = try makeStore(h, snapshots: [exhausted], providers: [.claude], network: network)
        store.start(); await settle(store)
        store.observeSessionEvents([row(updatedAt: start.addingTimeInterval(-60))], now: start)
        var minute = 0
        while start.addingTimeInterval(Double(minute + 5) * 60) < weeklyReset {
            minute += 5
            h.now = start.addingTimeInterval(Double(minute) * 60)
            h.fireDue(); h.ticks[300]?(); await settle(store)
            // The user keeps trying: every finished (refused) response is a session event.
            if minute % 60 == 0 { store.observeSessionEvents([row(updatedAt: h.now)], now: h.now) }
            if minute % (12 * 60) == 0 {
                h.wake?(); h.now = h.now.addingTimeInterval(5); h.fireDue(); await settle(store)
                network.update(available: false); network.update(available: true); await settle(store)
            }
        }
        XCTAssertEqual(h.probes, [], "No probe while the week is used up")
        let shown = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(shown.status(of: shown.fiveHour, now: h.now), .resetPassed(fiveReset), "The passed five-hour reset is shown, not probed")
        XCTAssertEqual(shown.status(of: shown.weekly, now: h.now), .exhausted)
        h.now = weeklyReset.addingTimeInterval(29); h.fireDue(); h.ticks[300]?(); await settle(store)
        XCTAssertEqual(h.probes, [])
        h.now = weeklyReset.addingTimeInterval(30); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes, [weeklyReset.addingTimeInterval(30)], "One confirmation after the weekly reset plus grace")
        for step in 1...11 {
            h.now = weeklyReset.addingTimeInterval(30 + Double(step) * 300); h.fireDue(); h.ticks[300]?(); await settle(store)
        }
        XCTAssertEqual(h.probes.count, 1, "The new window is current for the idle interval")
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 0)
    }

    /// R1-02: Claude's own "limit reached" screen pauses automatic probes until the
    /// earliest known reset. The saved value may still read below 100 %; it is kept,
    /// never replaced by an invented 100 %.
    func testLimitReachedPausesUntilTheEarliestKnownReset() async throws {
        let h = Harness(now: start)
        let weeklyReset = start.addingTimeInterval(3 * 86400), fiveReset = start.addingTimeInterval(2 * 3600)
        let saved = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 92, durationMinutes: 10080, resetsAt: weeklyReset, resetPrecision: .minute),
            fiveHour: QuotaWindow(usedPercent: 40, durationMinutes: 300, resetsAt: fiveReset, resetPrecision: .minute),
            fetchedAt: start.addingTimeInterval(-2 * 3600), source: ClaudeUsageProbe.source)
        let reached = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .limitReached)
        h.result = { _, _ in throw reached }
        let store = try makeStore(h, snapshots: [saved], providers: [.claude])
        store.start(); await settle(store)
        XCTAssertEqual(h.probes, [start], "The two-hour-old value is asked about at launch")
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 92, "No invented 100 %")
        XCTAssertEqual(store.snapshots.first?.issue, reached.message)
        for minute in stride(from: 5.0, through: 120, by: 5) {
            h.now = start.addingTimeInterval(minute * 60); h.fireDue(); h.ticks[300]?(); await settle(store)
            if minute == 60 { h.wake?(); h.now = h.now.addingTimeInterval(5); h.fireDue(); await settle(store) }
        }
        XCTAssertEqual(h.probes.count, 1, "Paused until the five-hour reset, the earliest one known")
        h.now = fiveReset.addingTimeInterval(30); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 2, "The earliest reset may have lifted the limit")
        for hour in 1...24 {
            h.now = fiveReset.addingTimeInterval(30 + Double(hour) * 3600); h.fireDue(); h.ticks[300]?(); await settle(store)
        }
        XCTAssertEqual(h.probes.count, 2, "Still reached: paused until the weekly reset")
        h.now = weeklyReset.addingTimeInterval(30); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 3)
    }

    /// R1-03: wake and a restored network cannot answer a trust question, sign in or
    /// change the billing: those failures keep their backoff until an explicit refresh.
    func testPermanentFailuresKeepTheirBackoffAcrossWakeAndNetwork() async throws {
        let failures: [Error] = [
            ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .workspaceTrustRequired),
            ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable),
            ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .unsupportedResponse),
            UsageError.claudeSignInRequired,
        ]
        for failure in failures {
            let h = Harness(now: start)
            let saved = try claude(used: 40, fetchedAt: start.addingTimeInterval(-2 * 3600), reset: start.addingTimeInterval(3 * 86400))
            h.result = { _, _ in throw failure }
            let network = NetworkConnection(settle: {}, makeMonitor: { nil })
            let store = try makeStore(h, snapshots: [saved], providers: [.claude], network: network)
            store.start(); await settle(store)
            for minute in stride(from: 5.0, through: 120, by: 5) {
                h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await settle(store)
            }
            XCTAssertEqual(h.minutes(h.probes, from: start), [0, 5, 15, 35, 75], "\(failure)")
            h.now = start.addingTimeInterval(121 * 60)
            h.wake?(); h.now = h.now.addingTimeInterval(5); h.fireDue(); await settle(store)
            XCTAssertEqual(h.probes.count, 5, "Wake does not remove this cause: \(failure)")
            network.update(available: false); network.update(available: true); await settle(store)
            XCTAssertEqual(h.probes.count, 5, "Nor does a restored network: \(failure)")
            h.now = start.addingTimeInterval(135 * 60); h.fireDue(); h.ticks[300]?(); await settle(store)
            XCTAssertEqual(h.probes.count, 6, "The backoff continues: \(failure)")
            h.now = start.addingTimeInterval(136 * 60); await store.refresh(); await settle(store)
            XCTAssertEqual(h.probes.count, 7, "An explicit refresh always asks: \(failure)")
        }
    }

    /// R1-04: the CLI can still show the window that has just reset. Such an answer
    /// is not the first data of the new window: the surfaces keep "reset at HH:MM,
    /// waiting for data" and the next confirmation follows the backoff.
    func testConfirmationThatStillShowsThePassedResetIsRetriedWithBackoff() async throws {
        let h = Harness(now: start)
        let reset = start.addingTimeInterval(40 * 60)
        let exhausted = try claude(used: 100, fetchedAt: start, reset: reset)
        h.result = { _, date in
            date < reset.addingTimeInterval(120)
                ? try self.claude(used: 100, fetchedAt: date, reset: reset)
                : try self.claude(used: 0, fetchedAt: date, reset: nil)
        }
        let store = try makeStore(h, snapshots: [exhausted], providers: [.claude])
        store.start(); await settle(store)
        h.now = reset.addingTimeInterval(30); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 1)
        let shown = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(shown.status(of: shown.weekly, now: h.now), .resetPassed(reset), "Still waiting for the first data of the new window")
        XCTAssertNotNil(h.pending.first { abs($0.fireAt.timeIntervalSince(reset.addingTimeInterval(330))) < 1 },
                        "The next confirmation is scheduled after the first backoff step")
        h.now = reset.addingTimeInterval(329); h.fireDue(); h.ticks[300]?(); await settle(store)
        XCTAssertEqual(h.probes.count, 1)
        h.now = reset.addingTimeInterval(330); h.fireDue(); await settle(store)
        XCTAssertEqual(h.probes.count, 2)
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 0)
        XCTAssertNil(store.snapshots.first?.weekly?.resetsAt)
        for step in 1...11 {
            h.now = reset.addingTimeInterval(330 + Double(step) * 300); h.fireDue(); h.ticks[300]?(); await settle(store)
        }
        XCTAssertEqual(h.probes.count, 2, "The confirmed new window is current")
    }

    /// R1-05, R1-06: a Codex answer without any window Lunavect knows (another
    /// window length, or no window and no unlimited flag) is unknown data. It follows
    /// the failure backoff instead of starting the app-server on every tick.
    func testCodexAnswerWithoutAKnownWindowFollowsTheBackoff() async throws {
        let answers: [[String: Any]] = [
            ["limitId": "codex", "primary": ["usedPercent": 30, "windowDurationMins": 1440, "resetsAt": 1_800_086_400]],
            ["limitId": "codex", "primary": NSNull(), "secondary": NSNull()],
        ]
        for answer in answers {
            let h = Harness(now: start)
            h.result = { _, date in try UsageParser.codex(["rateLimits": answer], now: date) }
            let store = try makeStore(h, snapshots: [], providers: [.codex])
            store.start(); await settle(store)
            for minute in stride(from: 5.0, through: 120, by: 5) {
                h.now = start.addingTimeInterval(minute * 60); h.ticks[300]?(); await settle(store)
            }
            XCTAssertEqual(h.minutes(h.codexFetches, from: start), [0, 5, 15, 35, 75], "\(answer)")
            let codex = try XCTUnwrap(store.snapshots.first { $0.provider == .codex })
            XCTAssertEqual(codex.status(of: codex.weekly, now: h.now), .unknown, "\(answer)")
        }
    }

    /// R1-11: a session event whose debounce ends while another refresh runs is
    /// evaluated after that refresh, not dropped until the next interval.
    func testSessionEventDuringAnotherRefreshIsEvaluatedAfterIt() async throws {
        let h = Harness(now: start)
        let fresh = try claude(used: 40, fetchedAt: start.addingTimeInterval(-600), reset: start.addingTimeInterval(3 * 86400))
        func codex(_ date: Date) throws -> UsageSnapshot {
            try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: self.start.addingTimeInterval(4 * 86400)),
                              fetchedAt: date, source: "Codex CLI")
        }
        h.result = { id, date in id == .codex ? try codex(date) : try self.claude(used: 45, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        var release: CheckedContinuation<Void, Never>?
        h.holdCodex = { await withCheckedContinuation { release = $0 } }
        let store = try makeStore(h, snapshots: [fresh, try codex(start.addingTimeInterval(-2 * 3600))], providers: [.claude, .codex])
        store.start()
        await wait(until: { h.codexFetches.count == 1 && release != nil })
        XCTAssertEqual(h.probes.count, 0, "At launch the Claude observation is current")
        store.observeSessionEvents([row(updatedAt: start.addingTimeInterval(-600))], now: start)
        h.now = start.addingTimeInterval(60); store.observeSessionEvents([row(updatedAt: h.now)], now: h.now)
        h.now = start.addingTimeInterval(151); h.fireDue()
        XCTAssertEqual(h.probes.count, 0, "Codex is still being asked")
        h.holdCodex = nil; release?.resume()
        await settle(store)
        XCTAssertEqual(h.probes.count, 1, "The event is evaluated once the running refresh ends")
        XCTAssertEqual(h.codexFetches.count, 1)
    }

    /// R2-Q-02: the local reader (every 5 s) rereads the saved files. After a failed
    /// probe they hold the same observation without the failure, which must not
    /// erase it: the value keeps its "*" and the reason until newer data arrives.
    func testLocalReaderKeepsTheFailureOfTheLatestProbe() async throws {
        let h = Harness(now: start)
        let saved = try claude(used: 40, fetchedAt: start.addingTimeInterval(-180), reset: start.addingTimeInterval(3 * 86400))
        let unreadable = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .unsupportedResponse)
        h.result = { _, _ in throw unreadable }
        // The saved files hold this observation throughout (a failed probe saves nothing).
        let store = try makeStore(h, snapshots: [saved], providers: [.claude], local: { [saved] _ in saved })
        store.start(); await settle(store)
        XCTAssertEqual(h.probes.count, 0, "A three-minute-old observation is current")
        await store.refresh(); await settle(store)
        XCTAssertEqual(h.probes.count, 1)
        XCTAssertEqual(store.snapshots.first?.issue, unreadable.message)
        h.now = start.addingTimeInterval(5); h.ticks[5]?(); await settle(store)
        let shown = try XCTUnwrap(store.snapshots.first { $0.provider == .claude })
        XCTAssertEqual(shown.issue, unreadable.message, "The saved copy of the same observation does not erase the failure")
        XCTAssertEqual(shown.status(of: shown.weekly, now: h.now), .current(stale: true))
        let diagnostic = ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                              snapshot: shown, sessionIssue: nil, now: h.now)
        XCTAssertEqual(diagnostic.state, .unsupportedResponse)
        // A later successful probe is shown; a local read that started before it was
        // saved returns the older observation, which never rolls the new one back.
        h.result = { _, date in try self.claude(used: 45, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        h.now = start.addingTimeInterval(40); await store.refresh(); await settle(store)
        XCTAssertEqual(h.probes.count, 2)
        let probed = try XCTUnwrap(store.snapshots.first { $0.provider == .claude })
        XCTAssertEqual(probed.weekly?.usedPercent, 45)
        XCTAssertNil(probed.issue)
        h.now = start.addingTimeInterval(45); h.ticks[5]?(); await settle(store)
        XCTAssertEqual(store.snapshots.first { $0.provider == .claude }, probed)
    }

    /// An explicit refresh pressed while an automatic request for the other provider
    /// runs is not dropped: it is evaluated once that request ends.
    func testExplicitRefreshDuringAnotherProvidersRequestIsEvaluatedAfterIt() async throws {
        let h = Harness(now: start)
        let fresh = try claude(used: 40, fetchedAt: start.addingTimeInterval(-600), reset: start.addingTimeInterval(3 * 86400))
        func codex(_ date: Date) throws -> UsageSnapshot {
            try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: self.start.addingTimeInterval(4 * 86400)),
                              fetchedAt: date, source: "Codex CLI")
        }
        h.result = { id, date in id == .codex ? try codex(date) : try self.claude(used: 45, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        var release: CheckedContinuation<Void, Never>?
        h.holdCodex = { await withCheckedContinuation { release = $0 } }
        let store = try makeStore(h, snapshots: [fresh, try codex(start.addingTimeInterval(-2 * 3600))], providers: [.claude, .codex])
        store.start()
        await wait(until: { h.codexFetches.count == 1 && release != nil })
        XCTAssertEqual(h.probes.count, 0, "At launch only Codex is due")
        await store.refresh(provider: .claude)
        XCTAssertEqual(h.probes.count, 0, "One request at a time")
        h.holdCodex = nil; release?.resume()
        await settle(store)
        XCTAssertEqual(h.probes.count, 1, "The explicit refresh runs after the running request")
        XCTAssertEqual(store.snapshots.first { $0.provider == .claude }?.weekly?.usedPercent, 45)
    }

    /// R2-P-04: 0.2.4 (a second installed copy) rewrites snapshot.json without the
    /// reset precision it does not know, so the next launch reads the end of the
    /// shown minute as its start and moves the reset another minute later. The
    /// saved probe file still holds the original reading; the local reader takes
    /// its windows for the same reading instead of keeping the shifted ones.
    func testSavedProbeReadingRepairsWindowsShiftedByAnOlderCopy() async throws {
        let h = Harness(now: start)
        let reset = start.addingTimeInterval(3 * 86400)
        let original = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: reset, resetPrecision: .minute),
            fiveHour: QuotaWindow(usedPercent: 12, durationMinutes: 300, resetsAt: start.addingTimeInterval(3600), resetPrecision: .minute),
            fetchedAt: start.addingTimeInterval(-60), source: ClaudeUsageProbe.source,
            modelQuotas: [ModelQuota(name: "Model", window: QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: reset, resetPrecision: .minute),
                                     fetchedAt: start.addingTimeInterval(-60))])
        // What 0.2.4 writes back: the same JSON without the keys it does not know.
        func strippingPrecision(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object.removeValue(forKey: "resetPrecision")
                return object.mapValues(strippingPrecision)
            }
            if let array = value as? [Any] { return array.map(strippingPrecision) }
            return value
        }
        let rewritten = try JSONSerialization.data(withJSONObject: strippingPrecision(JSONSerialization.jsonObject(with: JSONEncoder().encode(original))))
        let shifted = try JSONDecoder().decode(UsageSnapshot.self, from: rewritten)
        XCTAssertEqual(shifted.weekly?.resetsAt, reset.addingTimeInterval(60), "The two meanings of a saved reset cannot be told apart")
        let store = try makeStore(h, snapshots: [shifted], providers: [.claude], local: { [original] _ in original })
        store.start(); await settle(store)
        XCTAssertEqual(h.probes.count, 0)
        h.now = start.addingTimeInterval(5); h.ticks[5]?(); await settle(store)
        XCTAssertEqual(store.snapshots.first { $0.provider == .claude }, original)
    }

    /// With two providers a check is "too soon" only when every requested provider was
    /// asked less than 30 s ago; one provider still due is asked (V: mutation MQ3).
    func testTooSoonNeedsEveryRequestedProviderToBeWaiting() async throws {
        let h = Harness(now: start)
        func codex(_ date: Date) throws -> UsageSnapshot {
            try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: self.start.addingTimeInterval(4 * 86400)),
                              fetchedAt: date, source: "Codex CLI")
        }
        h.result = { id, date in id == .codex ? try codex(date) : try self.claude(used: 41, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        let fresh = try claude(used: 40, fetchedAt: start.addingTimeInterval(-60), reset: start.addingTimeInterval(3 * 86400))
        let store = try makeStore(h, snapshots: [fresh, try codex(start.addingTimeInterval(-60))], providers: [.claude, .codex])
        store.start(); await settle(store)
        var outcome = await store.refresh(provider: .claude)
        XCTAssertEqual(outcome, .asked)
        let fetchesAfterClaude = h.codexFetches.count
        h.now = start.addingTimeInterval(10)
        outcome = await store.refresh()
        XCTAssertEqual(outcome, .asked, "Codex was not asked yet, so this check asks it")
        XCTAssertGreaterThan(h.codexFetches.count, fetchesAfterClaude)
        h.now = start.addingTimeInterval(20)
        outcome = await store.refresh()
        XCTAssertEqual(outcome, .tooSoon(until: start.addingTimeInterval(30)), "The earliest provider decides when checking is possible again")
    }

    /// R2-U-03 (proposed by U): an explicit refresh says what happened, so the
    /// control can explain why nothing visible changed.
    func testExplicitRefreshReportsItsOutcome() async throws {
        let h = Harness(now: start)
        let fresh = try claude(used: 40, fetchedAt: start.addingTimeInterval(-60), reset: start.addingTimeInterval(3 * 86400))
        h.result = { _, date in try self.claude(used: 41, fetchedAt: date, reset: self.start.addingTimeInterval(3 * 86400)) }
        let network = NetworkConnection(settle: {}, makeMonitor: { nil })
        let store = try makeStore(h, snapshots: [fresh], providers: [.claude], network: network)
        store.start(); await settle(store)
        var outcome = await store.refresh()
        XCTAssertEqual(outcome, .asked)
        h.now = start.addingTimeInterval(10)
        outcome = await store.refresh(provider: .claude)
        XCTAssertEqual(outcome, .tooSoon(until: start.addingTimeInterval(30)))
        XCTAssertEqual(h.probes.count, 1)
        h.now = start.addingTimeInterval(30)
        outcome = await store.refresh()
        XCTAssertEqual(outcome, .asked)
        XCTAssertEqual(h.probes.count, 2)
        network.update(available: false)
        h.now = start.addingTimeInterval(90)
        outcome = await store.refresh()
        XCTAssertEqual(outcome, .offline)
        network.update(available: true); await settle(store)
        var release: CheckedContinuation<Void, Never>?
        h.hold = { await withCheckedContinuation { release = $0 } }
        let first = Task { await store.refresh() }
        await wait(until: { release != nil })
        h.hold = nil
        outcome = await store.refresh()
        XCTAssertEqual(outcome, .running)
        release?.resume(); _ = await first.value; await settle(store)
        XCTAssertEqual(h.probes.count, 3, "The request made while one ran is evaluated after it; the 30 s limit then applies")
    }

    /// R2-U-04 (proposed by U): the status line's receipt time comes through the
    /// store, so an isolated store never reads the live file.
    func testStatusLineReceiptIsReadThroughTheStoreAndNeverWhenIsolated() throws {
        let observed = start.addingTimeInterval(-600)
        let reads = LockedCount()
        func services() -> AppDataServices {
            AppDataServices(snapshots: SnapshotPersistence(url: URL(fileURLWithPath: "/unused/r2-Q.json"), write: { _, _ in XCTFail("No writes") }, reload: {}),
                            activity: ActivityService(isolated: true), clock: { self.start },
                            statusLineObservedAt: { reads.increment(); return observed },
                            scheduling: AppRefreshScheduling(repeating: { _, _ in {} }, wake: { _ in {} }), discoverCodex: { nil })
        }
        let suite = "QuotaRefreshStore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude]
        let isolated = AppStore(state: .init(snapshots: [], preferences: preferences), network: NetworkConnection(makeMonitor: { nil }),
                                isolated: true, defaults: defaults, dataServices: services())
        XCTAssertNil(isolated.statusLineObservedAt())
        XCTAssertEqual(reads.value, 0, "An isolated store reads no live status-line file")
        let connected = AppStore(state: .init(snapshots: [], preferences: preferences), savesChanges: false,
                                 network: NetworkConnection(makeMonitor: { nil }), defaults: defaults, dataServices: services())
        XCTAssertEqual(connected.statusLineObservedAt(), observed)
        XCTAssertEqual(reads.value, 1)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
