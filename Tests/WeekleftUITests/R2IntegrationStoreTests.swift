import XCTest
import AppKit
import Combine
import Darwin
@testable import Weekleft
@testable import WeekleftCore

/// r2 audit X: scenarios that cross the stores the app wires together in
/// `AppDelegate.applicationDidFinishLaunching` and stops in `AppEnvironment.stop`.
/// Every store here uses temporary folders, private defaults, fixture clocks and
/// fixture sources; nothing reaches a client, the network or the home folder.
@MainActor final class R2IntegrationStoreTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lunavect-r2-X-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() throws -> UserDefaults {
        let suite = "lunavect-r2-X." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private let inertResolver = { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) }

    /// Waits for a condition with a wall-clock deadline instead of a fixed sleep.
    private func waitUntil(_ what: String, seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var spins = 0
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Timed out: \(what)", file: file, line: line) }
            spins += 1
            if spins < 200 { await Task.yield() } else { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    private func row(_ provider: ProviderID, _ id: String, _ phase: SessionPhase, at date: Date,
                     evidence: SessionEvidence = .hook) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "Fixture " + id, cwd: "/fixture/" + id, client: .terminal,
                     phase: phase, updatedAt: date, observedAt: date, evidence: evidence, runtimeConfirmed: true)
    }

    // MARK: M1 — long sleep, one source vanished, a pre-sleep read finishes last

    func testPreSleepReadFinishingAfterWakeReachesNoConsumerAndSleepIsNotWork() async throws {
        var clock = instant, awake = false, holdNextRead = false
        var held: CheckedContinuation<Void, Never>?
        let readHeld = expectation(description: "Pre-sleep event read held")
        let sleepMarker = instant.addingTimeInterval(5)
        let sessions = SessionStore(directory: try folder(), defaults: try defaults(), isolated: true, now: { clock },
            dependencies: .init(catalog: { provider, _, _, _ in
                // After wake the Codex source is gone (app-server unavailable).
                if provider == .codex, awake { throw SessionError.timeout }
                return ([], false)
            }, events: { _, _, _ in
                if holdNextRead {
                    holdNextRead = false
                    let stale = [self.row(.codex, "vanished", .running, at: sleepMarker)]
                    await withCheckedContinuation { held = $0; readHeld.fulfill() }
                    return stale
                }
                // Hook records stay on disk: the vanished session keeps its last (old) record.
                let vanishedAt = awake ? sleepMarker : clock
                return [self.row(.codex, "vanished", .running, at: vanishedAt),
                        self.row(.claude, "kept", awake ? .running : .idle, at: clock)]
            }))
        defer { sessions.stop() }
        let power = NotificationCenter()
        let activity = ActivityService(powerNotifications: power, clock: { clock }, importer: { _, _, _ in
            XCTFail("An unstarted service never imports"); return ActivityImportResult()
        })
        var observations: [(rows: [AgentSession], date: Date)] = []
        sessions.onObservation = { rows, now in observations.append((rows, now)); activity.observe(rows, now: now) }
        sessions.useProviders([.claude, .codex]); activity.setProviders([.claude, .codex])

        await sessions.refresh()
        clock += 5; await sessions.readEvents()
        // `history` is republished at checkpoints; flush publishes the tracker (no storage here).
        activity.flush(now: clock)
        XCTAssertEqual(activity.history.summary(now: clock).totals.active, 5, "Five seconds of observed work before sleep")

        holdNextRead = true
        let late = Task { await sessions.readEvents() }
        await fulfillment(of: [readHeld], timeout: 5)
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        clock += 7200; awake = true
        power.post(name: NSWorkspace.didWakeNotification, object: nil)

        await sessions.refresh()
        let afterWake = observations.count
        let vanished = try XCTUnwrap(sessions.sessions.first { $0.sessionID == "vanished" })
        XCTAssertFalse(vanished.isCurrent(now: clock), "A source that vanished during sleep is not current")
        XCTAssertNotEqual(vanished.effectivePhase(now: clock), .finished, "Disappearance is not a recorded end")
        XCTAssertNotEqual(vanished.effectivePhase(now: clock), .running)
        XCTAssertEqual(sessions.currentSessions.map(\.sessionID), ["kept"])
        XCTAssertEqual(sessions.typedIssues[.codex]?.reason, .timedOut, "The vanished source is reported")

        held?.resume(); await late.value
        XCTAssertEqual(observations.count, afterWake, "The pre-sleep read finished last and must reach no consumer")
        XCTAssertEqual(sessions.currentSessions.map(\.sessionID), ["kept"])
        activity.flush(now: clock)
        XCTAssertEqual(activity.history.summary(now: clock).totals.active, 5, "Two hours of sleep are not work")

        clock += 5; await sessions.readEvents()
        activity.flush(now: clock)
        XCTAssertEqual(activity.history.summary(now: clock).totals.active, 10, "Measurement continues after wake")
    }

    // MARK: M8 — a provider is turned off while its quota, catalog and import are in flight

    func testTurningOffAProviderMidOperationLeavesNoTraceInAnyStoreOrFile() async throws {
        let root = try folder(), prefs = try defaults()
        var clock = instant
        let quota = R2Gate(expectation(description: "Codex quota held"))
        let catalog = R2Gate(expectation(description: "Codex catalog held"))
        let imports = R2Gate(expectation(description: "Codex import held"))
        let oldCodex = try UsageSnapshot(provider: .codex,
            weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: instant.addingTimeInterval(3 * 86400)),
            fetchedAt: instant.addingTimeInterval(-7200), source: "Codex CLI")
        let freshClaude = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: instant.addingTimeInterval(86400), resetPrecision: .minute),
            fetchedAt: instant, source: ClaudeUsageProbe.source)
        let activity = ActivityService(powerNotifications: nil, clock: { clock }, importer: { _, _, now in
            var result = ActivityImportResult()
            // Only the first request (Claude and Codex) is held; it carries recovered Codex work.
            if await imports.pass() {
                result.intervals = [.init(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-60), providers: 2, recovered: true)]
            }
            return result
        })
        let snapshotURL = root.appendingPathComponent("Shared/snapshot.json")
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]
        let store = AppStore(state: .init(snapshots: [oldCodex, freshClaude], preferences: preferences),
            network: NetworkConnection(settle: {}, makeMonitor: { nil }), defaults: prefs,
            dataServices: .init(snapshots: SnapshotPersistence(url: snapshotURL), activity: activity, clock: { clock },
                localQuota: { _ in nil }, refreshQuota: { id, _, _ in
                    guard id == .codex else { return freshClaude }
                    _ = await quota.pass()
                    return try UsageSnapshot(provider: .codex,
                        weekly: QuotaWindow(usedPercent: 80, durationMinutes: 10080, resetsAt: self.instant.addingTimeInterval(3 * 86400)),
                        fetchedAt: clock, source: "Codex CLI")
                }, scheduling: AppRefreshScheduling(repeating: { _, _ in {} }, wake: { _ in {} }, after: { _, _ in {} }),
                discoverCodex: { nil }))
        let sessions = SessionStore(directory: root.appendingPathComponent("Sessions"), defaults: prefs, isolated: true, now: { clock },
            dependencies: .init(catalog: { provider, _, _, _ in
                guard provider == .codex else { return ([], false) }
                _ = await catalog.pass()
                return ([self.row(.codex, "late", .running, at: clock, evidence: .catalog)], false)
            }))
        // The same wiring as AppDelegate: the selection reaches the session store one run-loop turn later.
        let selection = store.$preferences.map(\.providers).removeDuplicates().receive(on: RunLoop.main)
            .sink { sessions.useProviders($0) }
        var observed: [AgentSession] = []
        sessions.onObservation = { rows, now in observed += rows; store.observeActivity(rows, now: now); store.observeSessionEvents(rows, now: now) }
        defer { selection.cancel(); sessions.stop(); store.stop() }
        sessions.useProviders(store.providers)
        store.start()
        let sessionRefresh = Task { await sessions.refresh() }
        await fulfillment(of: [quota.reached, catalog.reached, imports.reached], timeout: 5)

        store.setProvider(.codex, enabled: false)
        await waitUntil("session store follows the selection") { sessions.providers == [.claude] }
        clock += 30
        quota.open(); catalog.open(); imports.open()
        await sessionRefresh.value
        await waitUntil("quota and import settle") { store.quotaRefreshIdle && !activity.importing }

        XCTAssertEqual(store.snapshots.first { $0.provider == .codex }?.weekly?.usedPercent, 40, "A late Codex quota is not shown")
        XCTAssertFalse(sessions.sessions.contains { $0.provider == .codex }, "A late Codex catalog is not listed")
        XCTAssertFalse(observed.contains { $0.provider == .codex }, "No consumer (activity, Keep Awake, notices) saw a Codex row")
        XCTAssertFalse(activity.history.intervals.contains { $0.providers & 2 != 0 }, "A late Codex import is not merged")
        store.stop()
        let saved = try JSONDecoder().decode(SharedState.self, from: Data(contentsOf: snapshotURL))
        XCTAssertEqual(saved.preferences.enabledProviders, [.claude])
        XCTAssertEqual(saved.snapshots.first { $0.provider == .codex }?.weekly?.usedPercent, 40, "The file never received the late quota")
    }

    // MARK: M12 — repeated recovery must not accumulate watchers, timers or descriptors

    private func openDescriptors() -> Int {
        (0..<Int(min(getdtablesize(), 16384))).reduce(0) { count, fd in fcntl(Int32(fd), F_GETFD) != -1 ? count + 1 : count }
    }

    func testRepeatedProviderChangesAndRestartsKeepOneWatcherAndNoLeakedDescriptors() async throws {
        let directory = try folder()
        var reads = 0
        let sessions = SessionStore(directory: directory, defaults: try defaults(), isolated: true, now: { self.instant },
            dependencies: .init(events: { _, _, _ in reads += 1; return [] }, schedulesTimers: true, watchesEvents: true))
        defer { sessions.stop() }
        sessions.useProviders([.codex])
        let baseline = openDescriptors()
        sessions.start(clientResolver: inertResolver)
        for cycle in 0..<200 {
            sessions.useProviders(cycle % 2 == 0 ? [.claude, .codex] : [.codex])
            if cycle % 20 == 19 { sessions.stop(); sessions.start(clientResolver: inertResolver) }
        }
        await waitUntil("cancelled watchers close their descriptors") { self.openDescriptors() <= baseline + 1 }
        XCTAssertLessThanOrEqual(openDescriptors(), baseline + 1, "One live folder watcher, not one per recovery")
        XCTAssertNotNil(sessions.polling, "A running store keeps its polling policy")

        // The one remaining watcher still belongs to the current generation.
        await waitUntil("startup reads settle") { !sessions.refreshing }
        let before = reads
        try Data("{}".utf8).write(to: directory.appendingPathComponent("codex-watch.json"))
        await waitUntil("a written record reaches the store through the current watcher") { reads > before }

        sessions.stop()
        await waitUntil("stop closes the last watcher") { self.openDescriptors() <= baseline }
        XCTAssertLessThanOrEqual(openDescriptors(), baseline)
        XCTAssertNil(sessions.polling, "Stop leaves no polling timers")
    }

    func testRepeatedStartsWakesAndNetworkFlapsKeepOneSetOfTriggersAndOneRequest() async throws {
        final class Registrations { var live: [Int: String] = [:]; var next = 0; var wake: (@MainActor @Sendable () -> Void)? }
        let registrations = Registrations()
        func register(_ kind: String) -> () -> Void {
            registrations.next += 1
            let token = registrations.next
            registrations.live[token] = kind
            return { registrations.live[token] = nil }
        }
        var clock = instant, calls = 0
        var hold: CheckedContinuation<Void, Never>?
        let held = expectation(description: "Launch request held")
        let old = try UsageSnapshot(provider: .codex,
            weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: instant.addingTimeInterval(3 * 86400)),
            fetchedAt: instant.addingTimeInterval(-7200), source: "Codex CLI")
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let network = NetworkConnection(settle: {}, makeMonitor: { nil })
        var restored = 0
        let store = AppStore(state: .init(snapshots: [old], preferences: preferences), savesChanges: false, network: network,
            defaults: try defaults(), dataServices: .init(snapshots: SnapshotPersistence(url: try folder().appendingPathComponent("snapshot.json")),
                activity: ActivityService(isolated: true), clock: { clock }, localQuota: { _ in nil }, refreshQuota: { id, _, _ in
                    calls += 1
                    if calls == 1 { await withCheckedContinuation { hold = $0; held.fulfill() } }
                    return try UsageSnapshot(provider: id,
                        weekly: QuotaWindow(usedPercent: 41, durationMinutes: 10080, resetsAt: self.instant.addingTimeInterval(3 * 86400)),
                        fetchedAt: clock, source: "Codex CLI")
                }, scheduling: AppRefreshScheduling(repeating: { interval, _ in register("repeating-\(Int(interval))") },
                                                     wake: { action in registrations.wake = action; return register("wake") },
                                                     after: { _, _ in register("after") }),
                discoverCodex: { nil }))
        store.onNetworkRestored = { restored += 1 }
        defer { store.stop() }

        for _ in 0..<50 {
            store.start(); store.start()
            XCTAssertEqual(registrations.live.values.filter { $0.hasPrefix("repeating") }.count, 2)
            XCTAssertEqual(registrations.live.values.filter { $0 == "wake" }.count, 1)
            registrations.wake?(); registrations.wake?()
            XCTAssertLessThanOrEqual(registrations.live.values.filter { $0 == "after" }.count, 2, "At most one wake settle and one reset check")
            store.stop()
            XCTAssertEqual(registrations.live, [:], "Stop cancels every trigger it registered")
        }

        store.start()
        await fulfillment(of: [held], timeout: 5)
        for _ in 0..<100 { network.update(available: false); network.update(available: true) }
        clock += 1
        hold?.resume()
        await waitUntil("recovery settles") { store.quotaRefreshIdle && !network.restoring }
        XCTAssertEqual(calls, 1, "One hanging request plus 100 restored connections still ask the client once")
        XCTAssertLessThanOrEqual(restored, 1, "Only the surviving recovery refreshes sessions")
        XCTAssertEqual(store.snapshots.first?.weekly?.usedPercent, 41)
    }

    // MARK: M14 — event flood, open panel, writes and shutdown

    func testEventFloodWithOpenPanelThenShutdownCoalescesReadsAndKeepsTheLastState() async throws {
        let root = try folder(), prefs = try defaults()
        var clock = instant, eventCalls = 0
        var hold: CheckedContinuation<Void, Never>?
        var holdCall: Int? = 1
        var heldExpectation = expectation(description: "First read held")
        let sessions = SessionStore(directory: root.appendingPathComponent("Sessions"), defaults: prefs, isolated: true, now: { clock },
            dependencies: .init(events: { _, _, _ in
                eventCalls += 1
                let rows = [self.row(.codex, "busy", .running, at: clock)]
                if eventCalls == holdCall { await withCheckedContinuation { hold = $0; heldExpectation.fulfill() } }
                return rows
            }))
        let history = root.appendingPathComponent("Shared/activity.json"), details = root.appendingPathComponent("Private/activity-details.json")
        // A slow disk: every history write takes 20 ms, so shutdown finds a queue.
        let storage = ActivityPersistence(historyURL: history, detailsURL: details, writeHistory: { value, url in
            usleep(20_000); try value.save(to: url)
        }, clock: { clock })
        let activity = ActivityService(storage: storage, powerNotifications: nil, clock: { clock }, importer: { _, _, _ in ActivityImportResult() })
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.codex]
        let fresh = try UsageSnapshot(provider: .codex,
            weekly: QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: instant.addingTimeInterval(3 * 86400)),
            fetchedAt: instant, source: "Codex CLI")
        let snapshotURL = root.appendingPathComponent("Shared/snapshot.json")
        let store = AppStore(state: .init(snapshots: [fresh], preferences: preferences),
            network: NetworkConnection(settle: {}, makeMonitor: { nil }), defaults: prefs,
            dataServices: .init(snapshots: SnapshotPersistence(url: snapshotURL), activity: activity, clock: { clock },
                localQuota: { _ in nil }, refreshQuota: { id, _, _ in UsageSnapshot(provider: id) },
                scheduling: AppRefreshScheduling(repeating: { _, _ in {} }, wake: { _ in {} }, after: { _, _ in {} }), discoverCodex: { nil }))
        var observations = 0, publications = 0
        sessions.onObservation = { rows, now in observations += 1; store.observeActivity(rows, now: now) }
        let panel = sessions.$sessions.dropFirst().sink { _ in publications += 1 }
        defer { panel.cancel(); sessions.stop(); store.stop() }
        sessions.useProviders([.codex])
        store.start()
        sessions.setPanelVisible(true)

        let first = Task { await sessions.readEvents() }
        await fulfillment(of: [heldExpectation], timeout: 5)
        for _ in 0..<10_000 { sessions.sourceChanged() }
        XCTAssertEqual(eventCalls, 1, "Ten thousand changes during one read start no second read yet")
        hold?.resume(); await first.value
        await waitUntil("exactly one follow-up read") { eventCalls == 2 && sessions.sessions.count == 1 }
        for _ in 0..<10 { clock += 5; await sessions.readEvents() }
        XCTAssertEqual(eventCalls, 12)
        XCTAssertLessThanOrEqual(publications, eventCalls, "The panel is republished per read, not per change")
        let workedSeconds: TimeInterval = 50   // ten running reads, 5 s apart

        holdCall = 13; heldExpectation = expectation(description: "Last read held")
        let last = Task { await sessions.readEvents() }
        await fulfillment(of: [heldExpectation], timeout: 5)
        for _ in 0..<10_000 { sessions.sourceChanged() }
        store.setProvider(.claude, enabled: true)   // a settings edit still in its 200 ms coalescing window
        let observedBeforeShutdown = observations
        let began = ProcessInfo.processInfo.systemUptime
        // AppEnvironment.stop order: sessions, then quota/activity stores with their final flushes.
        sessions.stop(); store.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 5, "Shutdown stays bounded with a slow disk")
        hold?.resume(); await last.value
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(observations, observedBeforeShutdown, "Nothing is published after stop")
        XCTAssertEqual(eventCalls, 13, "No follow-up read starts after stop")

        let savedHistory = try ActivityHistory.load(from: history)
        XCTAssertEqual(savedHistory.summary(now: clock).totals.active, workedSeconds, "The final activity state reached the disk")
        let savedState = try JSONDecoder().decode(SharedState.self, from: Data(contentsOf: snapshotURL))
        XCTAssertEqual(savedState.preferences.enabledProviders, [.claude, .codex], "The last settings edit was flushed at shutdown")
    }

    // MARK: X-I2 — one window state on every limits surface

    /// Metamorphic check (R2-X-01): the observation age of an exhausted window or
    /// of a plan without limits changes nothing on any surface, because neither
    /// value can change before the next reset. Every limits card and the menu bar
    /// must show exactly the same thing for a fresh and a two-hour-old reading.
    func testObservationAgeOfExhaustedOrUnlimitedWindowChangesNoSurface() throws {
        let now = instant
        struct Surface: Equatable { var value: String; var dimmed: Bool; var status: Bool; var attention: Bool }
        func surfaces(_ snapshot: UsageSnapshot) throws -> [String: Surface] {
            let claude = UsageSnapshot(provider: .claude,
                weekly: try QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetPrecision: .minute),
                fetchedAt: now, source: ClaudeUsageProbe.source)
            var both = WidgetPreferences(); both.enabledProviders = [.claude, .codex]
            var single = WidgetPreferences(); single.enabledProviders = [.codex]
            let entry = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [snapshot], providers: [.codex],
                                                              preferences: MenuBarLimitsPreferences(enabled: true), now: now).first)
            func surface(_ display: WidgetQuotaDisplay) -> Surface {
                Surface(value: display.value, dimmed: display.dimmed, status: display.showsStatus, attention: display.needsAttention)
            }
            return [
                "menu bar": Surface(value: entry.value, dimmed: entry.stale, status: entry.note != nil, attention: entry.stale),
                "medium": surface(WeekleftCard(snapshots: [claude, snapshot], preferences: both, now: now).display(snapshot)),
                "small": surface(SmallLimitsCard(snapshots: [claude, snapshot], preferences: both, now: now).display(snapshot)),
                "single": surface(SingleProviderLimitsCard(snapshot: snapshot, preferences: single, now: now).display),
                "overview": surface(OverviewLimitsCard(snapshots: [claude, snapshot], preferences: both, now: now).display(snapshot)),
            ]
        }
        let exhausted = { (age: TimeInterval) in
            try UsageSnapshot(provider: .codex,
                weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
                fetchedAt: now.addingTimeInterval(-age), source: "Codex CLI")
        }
        let unlimited = { (age: TimeInterval) in
            UsageSnapshot(provider: .codex, fetchedAt: now.addingTimeInterval(-age), source: "Codex CLI", unlimited: true)
        }
        for (name, make) in [("exhausted", exhausted), ("unlimited", unlimited)] {
            let fresh = try surfaces(make(0)), aged = try surfaces(make(7200))
            XCTAssertEqual(aged, fresh, "\(name): a two-hour-old reading shows the same on every surface")
            for (surface, shown) in fresh where surface != "menu bar" {
                XCTAssertEqual(shown.value, name == "exhausted" ? PercentText.format(0) : "∞", "\(name): \(surface)")
                XCTAssertFalse(shown.dimmed, "\(name): \(surface) is not marked as saved data")
            }
        }
    }

    // MARK: X-I7 at the store level: startup repair in a protected folder

    /// Stores created by tests with a default folder point at the live data
    /// (SessionHooks.directory, the Application Support fallback of SnapshotStore).
    /// Their startup repair must be refused there like every other write.
    func testStartupRepairOfStoresLeavesAProtectedFolderUntouched() throws {
        let home = try folder().appendingPathComponent("home", isDirectory: true)
        let sessions = home.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-7200)
        for (name, text) in [("snapshot.json", "{damaged"), ("activity.json", "{damaged"), ("activity-details.json", "{damaged"),
                             ("." + UUID().uuidString + ".tmp", "partial")] {
            let url = home.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        for name in ["hidden-sessions.json", "arrangement.json"] {
            try Data("{damaged".utf8).write(to: sessions.appendingPathComponent(name))
        }
        func tree() -> [String] {
            (FileManager.default.enumerator(atPath: home.path)?.allObjects as? [String] ?? []).sorted()
        }
        let before = tree()
        LiveWriteGuard.protect(home)
        defer { LiveWriteGuard.unprotect(home) }
        _ = SnapshotPersistence(url: home.appendingPathComponent("snapshot.json")).load()
        _ = ActivityPersistence(historyURL: home.appendingPathComponent("activity.json"),
                                detailsURL: home.appendingPathComponent("activity-details.json")).load()
        let store = SessionStore(directory: sessions, defaults: try defaults(), isolated: true, now: { self.instant })
        store.stop()
        XCTAssertEqual(tree(), before, "Startup repair changed a protected folder")
    }
}

/// Holds the first caller until `open()`; later callers pass at once.
private final class R2Gate: @unchecked Sendable {
    let reached: XCTestExpectation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0
    init(_ reached: XCTestExpectation) { self.reached = reached }
    /// Returns true for the held (first) call.
    func pass() async -> Bool {
        let first = lock.withLock { calls += 1; return calls == 1 }
        guard first else { return false }
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            reached.fulfill()
        }
        return true
    }
    func open() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { continuation = nil }; return continuation }?.resume() }
}
