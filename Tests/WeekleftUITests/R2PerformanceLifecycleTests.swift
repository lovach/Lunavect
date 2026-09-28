import XCTest
import SwiftUI
import AppKit
import Combine
import Darwin
import os
import UserNotifications
import ServiceManagement
import WeekleftCore
import AwakeService
@testable import Weekleft

/// Audit r2 (agent R): resource lifecycle of the app module. Fast registration
/// checks (M12) always run; stream, shutdown and long-run measurements (M14)
/// need `LUNAVECT_R2_PERF=1`. Only temporary folders, private defaults suites
/// and injected schedulers are used; no client, helper or shared storage.
enum R2UIProbe {
    static var enabled: Bool { ProcessInfo.processInfo.environment["LUNAVECT_R2_PERF"] == "1" }
    static func requireEnabled() throws {
        guard enabled else { throw XCTSkip("Set LUNAVECT_R2_PERF=1 for R2 resource measurements") }
    }
    static func wall() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
    static func footprint() -> UInt64 {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? vm.phys_footprint : 0
    }
    static func vnodeDescriptors() -> Int {
        let pid = getpid(), bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return -1 }
        var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 64)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, Int32(list.count * MemoryLayout<proc_fdinfo>.stride))
        return list.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride).filter { $0.proc_fdtype == PROX_FDTYPE_VNODE }.count
    }
    static func threads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        return Int(count)
    }
    static func report(_ name: String, _ fields: [String: Any]) {
        var object = fields
        object["measurement"] = name
        #if DEBUG
        object["build"] = "debug"
        #else
        object["build"] = "release"
        #endif
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        print("R2PERF " + String(decoding: data, as: UTF8.self))
    }
    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-R-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A stored property of `object`, including private ones (test-only reflection).
    static func field<T>(_ object: Any, _ label: String, as type: T.Type = T.self) -> T? {
        guard let value = Mirror(reflecting: object).children.first(where: { $0.label == label })?.value else { return nil }
        // An empty Optional must not bridge to NSNull (which conforms to NSObjectProtocol).
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return nil }
            return wrapped as? T
        }
        return value as? T
    }
    /// Run the main run loop (timers, main-actor jobs) until `condition` or `timeout`.
    @MainActor static func spin(until timeout: TimeInterval, _ condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor private final class R2Permissions: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status { .notRegistered }
    func notificationStatus() async -> UNAuthorizationStatus { .denied }
    func authorizeNotifications() async throws -> Bool { false }
    func registerLogin() throws {}
    func unregisterLogin() async throws {}
    func openNotificationSettings() -> Bool { false }
    func openLoginSettings() {}
}

/// Unapproved Keep Awake helper: every `isAvailable` read stands for one
/// `SMAppService.status` query of the production client (not called here).
@MainActor private final class R2AwakeClient: AwakeClient {
    var statusQueries = 0
    var isAvailable: Bool { statusQueries += 1; return false }
    func requestPermission() throws {}
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws {}
    func configure(policy: AwakeSafetyPolicy) async throws {}
    func keepAlive() async throws {}
    func end() async throws {}
    func disconnect() {}
}

private final class R2Count: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class R2PerformanceLifecycleTests: XCTestCase {
    private func resolver() -> ClientExecutableResolver { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) }

    // MARK: M12 — repeated recovery must not multiply timers, watchers or descriptors

    /// Start/stop, provider changes, panel visibility and active/idle policy changes
    /// 200 times: only the current timer pair and one directory watcher stay live;
    /// after stop, none. Timers and the watcher are reached by reflection.
    /// Synchronous on purpose: spinning the main run loop from an async test does not
    /// run main-actor jobs (checked during this audit), so timer-driven reads would stall.
    @MainActor func testRepeatedRecoveryKeepsOnlyCurrentTimersWatcherAndDescriptor() throws {
        let root = try R2UIProbe.temporaryDirectory("m12-sessions")
        let suite = "R2.M12." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let catalogCalls = R2Count(), eventCalls = R2Count()
        var dependencies = SessionStore.Dependencies()
        dependencies.catalog = { _, _, _, _ in catalogCalls.increment(); return ([], false) }
        dependencies.events = { _, _, _ in eventCalls.increment(); return [] }
        dependencies.schedulesTimers = true
        dependencies.watchesEvents = true
        var now = Date()
        let store = SessionStore(directory: root, defaults: defaults, now: { now }, dependencies: dependencies)
        let vnodesBefore = R2UIProbe.vnodeDescriptors()
        var timers: [ObjectIdentifier: Timer] = [:]
        var watchers: [ObjectIdentifier: DispatchSourceFileSystemObject] = [:]
        func collect() {
            for label in ["localTimer", "sourceTimer"] {
                if let timer = R2UIProbe.field(store, label, as: Timer.self) { timers[ObjectIdentifier(timer)] = timer }
            }
            if let watcher = R2UIProbe.field(store, "eventWatcher", as: DispatchSourceFileSystemObject.self) {
                watchers[ObjectIdentifier(watcher)] = watcher
            }
        }
        let running = AgentSession(provider: .claude, sessionID: "m12", title: "M12", cwd: "/synthetic", phase: .running,
                                   updatedAt: now, observedAt: now, evidence: .hook)
        var stops = 0
        for cycle in 0..<200 {
            store.start(clientResolver: resolver)
            collect()
            store.setPanelVisible(cycle.isMultiple(of: 2)); collect()
            now = now.addingTimeInterval(1)
            var row = running; row.observedAt = now; row.updatedAt = now
            store.acceptSessions(cycle.isMultiple(of: 3) ? [row] : [], now: now); collect()
            store.useProviders(cycle.isMultiple(of: 5) ? [.claude] : ProviderID.allCases); collect()
            if cycle % 4 == 3 {
                store.stop(); collect(); stops += 1
                XCTAssertNil(R2UIProbe.field(store, "localTimer", as: Timer.self))
                XCTAssertNil(R2UIProbe.field(store, "eventWatcher", as: DispatchSourceFileSystemObject.self))
                XCTAssertTrue(timers.values.allSatisfy { !$0.isValid }, "A timer outlives stop() (cycle \(cycle))")
            }
            if cycle.isMultiple(of: 10) { R2UIProbe.spin(until: 0.005) }
        }
        store.start(clientResolver: resolver); store.setPanelVisible(true); collect()
        let current = Set(["localTimer", "sourceTimer"].compactMap { R2UIProbe.field(store, $0, as: Timer.self) }.map(ObjectIdentifier.init))
        let valid = timers.filter { $0.value.isValid }
        let liveWatchers = watchers.values.filter { !$0.isCancelled }
        // Cancel handlers close descriptors on a utility queue.
        R2UIProbe.spin(until: 2) { R2UIProbe.vnodeDescriptors() <= vnodesBefore + 1 }
        let vnodesStarted = R2UIProbe.vnodeDescriptors()
        // Real timers (opt-in, 2.5 s): with the panel visible the local poll runs every second.
        let eventsBefore = eventCalls.value
        if R2UIProbe.enabled { R2UIProbe.spin(until: 2.5) }
        let eventsInWindow = eventCalls.value - eventsBefore
        store.stop()
        R2UIProbe.spin(until: 2) { R2UIProbe.vnodeDescriptors() <= vnodesBefore }
        let vnodesStopped = R2UIProbe.vnodeDescriptors()
        R2UIProbe.report("m12-session-store", ["cycles": 200, "stops": stops, "timers_created": timers.count, "timers_valid_after_restart": valid.count,
                                               "watchers_created": watchers.count, "watchers_live_after_restart": liveWatchers.count,
                                               "vnodes_before": vnodesBefore, "vnodes_started": vnodesStarted, "vnodes_after_stop": vnodesStopped,
                                               "event_reads_in_2_5s_panel_visible": eventsInWindow, "catalog_calls_total": catalogCalls.value])
        XCTAssertGreaterThan(timers.count, 10, "The cycles must actually recreate timers")
        XCTAssertLessThanOrEqual(valid.count, 2)
        XCTAssertEqual(Set(valid.keys), current, "Only the store's current timers may remain scheduled")
        XCTAssertEqual(liveWatchers.count, 1, "Exactly one directory watcher while started")
        XCTAssertLessThanOrEqual(vnodesStarted, vnodesBefore + 1, "Watcher descriptors accumulate across recoveries")
        XCTAssertLessThanOrEqual(vnodesStopped, vnodesBefore, "The watcher descriptor outlives stop()")
        XCTAssertTrue(timers.values.allSatisfy { !$0.isValid })
        XCTAssertTrue(watchers.values.allSatisfy(\.isCancelled))
        // 1 s cadence (tolerance 0.1 s): two or three reads, never one per leaked timer.
        if R2UIProbe.enabled {
            XCTAssertGreaterThanOrEqual(eventsInWindow, 1, "The timer-driven read must actually run in this harness")
            XCTAssertLessThanOrEqual(eventsInWindow, 4)
        }
    }

    /// AppStore start/stop 100 times with bursts of session events: every repeating
    /// trigger, wake observer and one-shot is cancelled; none accumulates.
    @MainActor func testRepeatedAppStoreStartStopLeavesNoScheduledTrigger() async throws {
        let root = try R2UIProbe.temporaryDirectory("m12-app")
        let suite = "R2.M12.App." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var live: Set<Int> = [], created = 0, maximumLive = 0
        func register() -> () -> Void {
            let id = created; created += 1; live.insert(id); maximumLive = max(maximumLive, live.count)
            return { live.remove(id) }
        }
        let scheduling = AppRefreshScheduling(repeating: { _, _ in register() }, wake: { _ in register() }, after: { _, _ in register() })
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]
        var now = Date()
        let store = AppStore(state: SharedState(preferences: preferences), network: NetworkConnection(settle: {}, makeMonitor: { nil }),
                             defaults: defaults,
                             dataServices: AppDataServices(snapshots: SnapshotPersistence(url: root.appendingPathComponent("snapshot.json")),
                                                           activity: ActivityService(isolated: true), clock: { now },
                                                           localQuota: { _ in nil }, refreshQuota: { _, _, _ in throw UsageError.waitingForClaude },
                                                           scheduling: scheduling, discoverCodex: { nil }))
        for cycle in 0..<100 {
            store.start()
            for burst in 0..<3 {
                now = now.addingTimeInterval(1)
                let row = AgentSession(provider: burst.isMultiple(of: 2) ? .claude : .codex, sessionID: "a\(cycle)", title: "", cwd: "",
                                       phase: .running, updatedAt: now, observedAt: now, evidence: .hook)
                store.observeSessionEvents([row], now: now)
            }
            if cycle.isMultiple(of: 10) { try await Task.sleep(for: .milliseconds(2)) }
            store.stop()
            XCTAssertTrue(live.isEmpty, "Cycle \(cycle): \(live.count) scheduled trigger(s) survive stop()")
        }
        R2UIProbe.report("m12-app-store", ["cycles": 100, "registrations": created, "maximum_simultaneously_live": maximumLive, "live_after_stop": live.count])
        XCTAssertLessThanOrEqual(maximumLive, 6, "Triggers accumulate while the store runs")
    }

    /// AppFeatures start/stop 100 times: activation and wake observers are removed
    /// and the limit timer is invalidated each time.
    @MainActor func testRepeatedFeatureStartStopRemovesObserversAndTimers() async throws {
        let suite = "R2.M12.Features." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = AppFeatures(defaults: defaults, permissionAccess: R2Permissions(), now: Date.init, playSound: { _ in })
        let snapshot = try UsageSnapshot(provider: .claude, fiveHour: QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: Date().addingTimeInterval(3600)),
                                         fetchedAt: Date())
        features.sounds = true; features.limits = true
        var limitTimers: [Timer] = []
        for cycle in 0..<100 {
            features.start()
            XCTAssertNotNil(R2UIProbe.field(features, "activationObserver", as: NSObjectProtocol.self))
            features.observeLimits([snapshot], providers: [.claude])
            if let timer = R2UIProbe.field(features, "limitTimer", as: Timer.self) { limitTimers.append(timer) }
            if cycle.isMultiple(of: 10) { try await Task.sleep(for: .milliseconds(2)) }
            features.stop()
            XCTAssertNil(R2UIProbe.field(features, "activationObserver", as: NSObjectProtocol.self))
            XCTAssertNil(R2UIProbe.field(features, "wakeObserver", as: NSObjectProtocol.self))
        }
        R2UIProbe.report("m12-features", ["cycles": 100, "limit_timers_seen": limitTimers.count, "limit_timers_valid": limitTimers.filter(\.isValid).count])
        XCTAssertTrue(limitTimers.allSatisfy { !$0.isValid }, "A limit timer outlives stop()")
    }

    // MARK: M14 — event stream + open panel + activity writes + shutdown

    private final class Producers: @unchecked Sendable {
        private let lock = NSLock()
        private var last: [String: String] = [:]
        private var written = 0, failures = 0
        func record(_ id: String, _ event: String) { lock.withLock { last[id] = event; written += 1 } }
        func fail() { lock.withLock { failures += 1 } }
        var summary: (last: [String: String], written: Int, failures: Int) { lock.withLock { (last, written, failures) } }
    }

    /// Eight writers deliver hook events for 48 Claude sessions as fast as the
    /// capture lock allows for 4 s while the sessions panel is hosted and the
    /// activity service records work. Afterwards the store must converge on the
    /// last record of every session, and shutdown must write the final history.
    @MainActor func testEventStormWithOpenPanelConvergesAndShutdownWritesLastState() throws {
        try R2UIProbe.requireEnabled()
        let root = try R2UIProbe.temporaryDirectory("m14")
        let hooks = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let suite = "R2.M14." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let reads = R2Count(), reloads = R2Count()
        var dependencies = SessionStore.Dependencies()
        dependencies.events = { _, _, _ in reads.increment(); return SessionHooks.load(at: hooks) }
        dependencies.initialEvents = { SessionHooks.load(at: $0) }
        dependencies.schedulesTimers = true
        dependencies.watchesEvents = true
        let store = SessionStore(directory: hooks, defaults: defaults, dependencies: dependencies)
        let persistence = ActivityPersistence(historyURL: root.appendingPathComponent("activity.json"),
                                              detailsURL: root.appendingPathComponent("activity-details.json"),
                                              reload: { reloads.increment() })
        let activity = ActivityService(storage: persistence, powerNotifications: nil, importer: { _, _, _ in ActivityImportResult() })
        activity.start(providers: [.claude])
        var observations = 0
        store.onObservation = { rows, now in observations += 1; activity.observe(rows, now: now) }
        store.useProviders([.claude])
        // The panel, hosted as in the app (offscreen window).
        let environment = try AppEnvironment.preview(rows: [])
        defer { environment.stop() }
        _ = NSApplication.shared
        let panelState = SessionPanelState(isVisible: true)
        let host = NSHostingView(rootView: SessionsView(store: store, panelState: panelState, updates: environment.updates,
                                                        awake: environment.awake, onSettings: {}).defaultAppStorage(environment.defaults))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        store.setPanelVisible(true)
        store.start(clientResolver: resolver)
        let before = (footprint: R2UIProbe.footprint(), threads: R2UIProbe.threads(), vnodes: R2UIProbe.vnodeDescriptors(), cpu: R2UIProbe.cpuSeconds())
        // Main-thread responsiveness: a 20 ms heartbeat that also lays out the panel.
        var lateness: [Double] = [], lastBeat = R2UIProbe.wall(), layouts = 0
        let heartbeat = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = R2UIProbe.wall()
                lateness.append(max(0, now - lastBeat - 0.02)); lastBeat = now
                if lateness.count % 5 == 0 { host.layoutSubtreeIfNeeded(); layouts += 1 }
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        // Control: the same heartbeat with the panel open and no events.
        R2UIProbe.spin(until: 2)
        let baseline = lateness.sorted(); lateness = []
        let producers = Producers(), stormSeconds = 4.0
        let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
        let deadline = R2UIProbe.wall() + stormSeconds
        let group = DispatchGroup()
        for worker in 0..<8 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                var step = 0
                while R2UIProbe.wall() < deadline {
                    for local in 0..<6 {
                        let id = "storm-\(worker)-\(local)", name = events[(step + local) % events.count]
                        var payload: [String: Any] = ["session_id": id, "hook_event_name": name, "cwd": "/synthetic/project-\(worker)"]
                        if name.hasSuffix("ToolUse") { payload["tool_name"] = "Bash"; payload["tool_use_id"] = "toolu_\(step)" }
                        do {
                            try SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: hooks, client: .terminal,
                                                     isInternal: { _ in false }, isAlive: { _ in true })
                            producers.record(id, name)
                        } catch { producers.fail() }
                    }
                    step += 1
                }
            }
        }
        var finished = false
        group.notify(queue: .main) { finished = true }
        let stormStart = R2UIProbe.wall()
        R2UIProbe.spin(until: stormSeconds + 10) { finished }
        let stormWall = R2UIProbe.wall() - stormStart
        let readsDuringStorm = reads.value
        let summary = producers.summary
        // Convergence: every session shows the phase of its last record on disk.
        func expected() -> [String: SessionPhase] {
            Dictionary(uniqueKeysWithValues: SessionHooks.load(at: hooks).map { ($0.id, $0.phase) })
        }
        let target = expected()
        let convergeStart = R2UIProbe.wall()
        R2UIProbe.spin(until: 8) {
            let shown = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0.phase) })
            return target.allSatisfy { shown[$0.key] == $0.value }
        }
        let convergeWall = R2UIProbe.wall() - convergeStart
        let shown = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0.phase) })
        heartbeat.invalidate()
        let sortedLateness = lateness.sorted()
        let afterStorm = (footprint: R2UIProbe.footprint(), threads: R2UIProbe.threads(), vnodes: R2UIProbe.vnodeDescriptors(), cpu: R2UIProbe.cpuSeconds())
        // Shutdown in the application's order: sessions, then activity (final flush).
        let stopStart = R2UIProbe.wall()
        store.stop(); activity.stop()
        let stopWall = R2UIProbe.wall() - stopStart
        let readsAtStop = reads.value
        R2UIProbe.spin(until: 1.5)
        let saved = try ActivityHistory.load(from: root.appendingPathComponent("activity.json"))
        R2UIProbe.report("m14-event-storm", [
            "storm_seconds": stormWall, "hook_events_written": summary.written, "hook_capture_failures": summary.failures,
            "hook_events_per_second": Double(summary.written) / stormWall, "sessions": target.count,
            "event_reads_during_storm": readsDuringStorm, "observations_total": observations, "panel_layouts": layouts,
            "main_lateness_p50_ms": sortedLateness.isEmpty ? -1 : sortedLateness[sortedLateness.count / 2] * 1000,
            "main_lateness_p99_ms": sortedLateness.isEmpty ? -1 : sortedLateness[min(sortedLateness.count - 1, sortedLateness.count * 99 / 100)] * 1000,
            "main_lateness_max_ms": (sortedLateness.last ?? -1) * 1000,
            "baseline_lateness_p50_ms": baseline.isEmpty ? -1 : baseline[baseline.count / 2] * 1000,
            "baseline_lateness_max_ms": (baseline.last ?? -1) * 1000,
            "converge_after_storm_s": convergeWall, "sessions_matching_last_record": target.filter { shown[$0.key] == $0.value }.count,
            "stop_wall_s": stopWall, "reads_after_stop": reads.value - readsAtStop, "history_intervals": saved.intervals.count,
            "history_file_matches_memory": saved == activity.history, "widget_reloads": reloads.value,
            "cpu_s_storm_and_convergence": afterStorm.cpu - before.cpu,
            "footprint_before_bytes": Int(before.footprint), "footprint_after_bytes": Int(afterStorm.footprint),
            "threads_before": before.threads, "threads_after": afterStorm.threads, "vnodes_before": before.vnodes, "vnodes_after": afterStorm.vnodes])
        XCTAssertEqual(summary.failures, 0)
        XCTAssertEqual(target.count, 48)
        XCTAssertEqual(target.filter { shown[$0.key] == $0.value }.count, 48, "The panel does not converge on the last event of every session")
        XCTAssertLessThan(stopWall, 3.5, "Shutdown exceeds the termination budget")
        XCTAssertEqual(reads.value, readsAtStop, "Reads continue after stop()")
        XCTAssertEqual(saved, activity.history, "The final activity state is not on disk after shutdown")
        XCTAssertGreaterThan(saved.intervals.count, 0, "The storm must have produced measured work")
    }

    private final class SlowWriter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0; private var last: ActivityHistory?
        let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        func write(_ history: ActivityHistory, _ url: URL) throws {
            Thread.sleep(forTimeInterval: delay)
            try history.save(to: url)
            lock.withLock { count += 1; last = history }
        }
        var writes: Int { lock.withLock { count } }
    }

    /// Fault injection: history writes take 50 ms while 120 checkpoints (a 32-minute
    /// stall at the 15 s transition debounce) are submitted. Measures what the
    /// unbounded FIFO retains, how long the termination flush waits, and whether
    /// the last state reaches the disk once the queue drains.
    @MainActor func testSlowDiskBacklogRetainsEveryCheckpointAndDelaysFinalFlush() throws {
        try R2UIProbe.requireEnabled()
        let root = try R2UIProbe.temporaryDirectory("m14-slow")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SlowWriter(delay: 0.05)
        let persistence = ActivityPersistence(historyURL: root.appendingPathComponent("activity.json"),
                                              detailsURL: root.appendingPathComponent("activity-details.json"),
                                              writeHistory: { try writer.write($0, $1) })
        // A long retained history: 20,000 intervals within 35 days.
        var history = ActivityHistory()
        var now = Date()
        let start = now.addingTimeInterval(-34 * 86400)
        for index in 0..<20_000 {
            let from = start.addingTimeInterval(Double(index) * 140)
            history.append(start: from, end: from.addingTimeInterval(70), providers: index % 2 + 1, observedProviders: 3)
        }
        let clock = { now }
        let activity = ActivityService(history: history, details: ActivityDetails(), storage: persistence, powerNotifications: nil,
                                       clock: { clock() }, importer: { _, _, _ in ActivityImportResult() })
        activity.setProviders([.claude])
        R2UIProbe.spin(until: 0.2)
        let footprintBefore = R2UIProbe.footprint(), writesBefore = writer.writes
        var row = AgentSession(provider: .claude, sessionID: "slow", title: "", cwd: "/synthetic", phase: .running,
                               updatedAt: now, observedAt: now, evidence: .hook)
        let checkpoints = 120
        for index in 0..<checkpoints {
            // Two observations 2 s apart (counted work), then 16 s later a phase change.
            now = now.addingTimeInterval(2); row.observedAt = now; row.updatedAt = now
            row.phase = .running; activity.observe([row], now: now)
            now = now.addingTimeInterval(16); row.observedAt = now; row.updatedAt = now
            row.phase = index.isMultiple(of: 2) ? .ready : .running
            activity.observe([row], now: now)
        }
        let footprintQueued = R2UIProbe.footprint(), writesWhenQueued = writer.writes - writesBefore
        let flushStart = R2UIProbe.wall()
        activity.stop()
        let flushWall = R2UIProbe.wall() - flushStart
        let issue = activity.issue
        let final = activity.history
        R2UIProbe.spin(until: 30) { (try? ActivityHistory.load(from: root.appendingPathComponent("activity.json"))) == final }
        let drained = (try? ActivityHistory.load(from: root.appendingPathComponent("activity.json"))) == final
        R2UIProbe.report("m14-slow-disk", ["write_delay_s": 0.05, "checkpoints": checkpoints, "history_intervals": final.intervals.count,
                                           "writes_done_when_all_submitted": writesWhenQueued,
                                           "footprint_growth_while_queued_bytes": Int64(footprintQueued) - Int64(footprintBefore),
                                           "termination_flush_wall_s": flushWall, "flush_issue_reported": issue != nil,
                                           "total_writes": writer.writes - writesBefore, "final_state_on_disk_after_drain": drained])
        XCTAssertLessThan(flushWall, 3.5, "The termination flush must stay within its budget")
        XCTAssertTrue(drained, "The final state never reaches the disk")
    }

    /// Realistic hook traffic (5 and 20 events/s across 6 sessions, panel closed):
    /// how many full reads the directory watcher triggers, and their CPU cost.
    @MainActor func testModerateHookStreamReadRateWithPanelClosed() throws {
        try R2UIProbe.requireEnabled()
        // Control: the same stream with the directory watcher off (timer reads only),
        // so the difference is the cost of watcher-driven reads.
        for (rate, watcher) in [(5.0, true), (5.0, false), (20.0, true), (20.0, false)] {
            let root = try R2UIProbe.temporaryDirectory("stream")
            let hooks = root.appendingPathComponent("Sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let suite = "R2.Stream." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            let reads = R2Count()
            var dependencies = SessionStore.Dependencies()
            dependencies.events = { _, _, _ in reads.increment(); return SessionHooks.load(at: hooks) }
            dependencies.schedulesTimers = true
            dependencies.watchesEvents = watcher
            let store = SessionStore(directory: hooks, defaults: defaults, dependencies: dependencies)
            var publications = 0
            let subscriber = store.$sessions.sink { _ in publications += 1 }
            defer { subscriber.cancel() }
            store.useProviders([.claude])
            store.start(clientResolver: resolver)
            R2UIProbe.spin(until: 1)
            let names = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PreToolUse", "PostToolUse", "Stop"]
            let seconds = 6.0, total = Int(seconds * rate)
            var sent = 0
            let startReads = reads.value, startPublications = publications, cpu = R2UIProbe.cpuSeconds(), start = R2UIProbe.wall()
            let timer = Timer(timeInterval: 1 / rate, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard sent < total else { return }
                    let payload: [String: Any] = ["session_id": "stream-\(sent % 6)", "hook_event_name": names[(sent / 6) % names.count],
                                                  "tool_name": "Bash", "tool_use_id": "toolu_\(sent)", "cwd": "/synthetic"]
                    try? SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: hooks, client: .terminal,
                                              isInternal: { _ in false }, isAlive: { _ in true })
                    sent += 1
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            R2UIProbe.spin(until: seconds + 0.5) { sent >= total }
            R2UIProbe.spin(until: 0.5)
            timer.invalidate()
            let wall = R2UIProbe.wall() - start, used = R2UIProbe.cpuSeconds() - cpu
            let streamReads = reads.value - startReads
            store.stop()
            R2UIProbe.report("hook-stream-read-rate", ["events_per_second": rate, "watcher": watcher, "events": sent, "wall_s": wall,
                                                       "reads": streamReads, "reads_per_event": Double(streamReads) / Double(max(1, sent)),
                                                       "timer_only_reads_expected": Int(wall / 2) + 1,
                                                       "publications": publications - startPublications,
                                                       "process_cpu_s": used, "process_cpu_percent_one_core": used / wall * 100])
        }
    }

    // MARK: Hosting — the panel is built and torn down every time it opens

    /// 300 open/close cycles of the sessions panel with 50 rows (offscreen host):
    /// retained memory must level off. Control: the same loop with a plain view.
    @MainActor func testPanelBuildAndTeardownDoesNotAccumulateMemory() throws {
        try R2UIProbe.requireEnabled()
        let now = Date()
        let rows = (0..<50).map { index in
            AgentSession(provider: index.isMultiple(of: 2) ? .claude : .codex, sessionID: "host-\(index)", title: "Task \(index)",
                         cwd: "/synthetic/project-\(index % 5)", phase: index.isMultiple(of: 3) ? .running : .ready,
                         updatedAt: now, observedAt: now, evidence: .hook)
        }
        let environment = try AppEnvironment.preview(rows: rows, now: now)
        defer { environment.stop() }
        _ = NSApplication.shared
        func settledFootprint() -> UInt64 { malloc_zone_pressure_relief(nil, 0); return R2UIProbe.footprint() }
        func cycles(_ count: Int, panel: Bool) -> [Int] {
            var samples: [Int] = []
            for cycle in 0..<count {
                autoreleasepool {
                    let host: NSView = panel
                        ? NSHostingView(rootView: SessionsView(store: environment.sessions, panelState: SessionPanelState(isVisible: true),
                                                               updates: environment.updates, awake: environment.awake, onSettings: {})
                            .defaultAppStorage(environment.defaults))
                        : NSHostingView(rootView: Text("control \(cycle)").frame(width: 360, height: 480))
                    host.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                    window.contentView = nil
                    window.close()
                }
                if cycle.isMultiple(of: 50) || cycle == count - 1 { samples.append(Int(settledFootprint())) }
            }
            return samples
        }
        let wallStart = R2UIProbe.wall()
        let control = cycles(300, panel: false)
        let panel = cycles(300, panel: true)
        R2UIProbe.spin(until: 0.5)
        R2UIProbe.report("panel-host-cycles", ["cycles": 300, "rows": rows.count, "control_footprint_bytes": control, "panel_footprint_bytes": panel,
                                               "panel_growth_after_first_100_bytes": panel.last! - panel[2],
                                               "control_growth_after_first_100_bytes": control.last! - control[2],
                                               "wall_s": R2UIProbe.wall() - wallStart])
    }

    /// Agent Y's lead: automatic Keep Awake with an unapproved helper re-reads the
    /// registration status on every session observation. Real observation stream
    /// (hook events at 20/s, watcher on, panel closed), injected client.
    @MainActor func testAutomaticKeepAwakeStatusQueriesFollowObservationRate() throws {
        try R2UIProbe.requireEnabled()
        let root = try R2UIProbe.temporaryDirectory("awake")
        let hooks = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let suite = "R2.Awake." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "awake.whileWorking")
        let client = R2AwakeClient()
        let awake = KeepAwake(client: client, defaults: defaults)
        R2UIProbe.spin(until: 0.2)
        XCTAssertTrue(awake.automatic)
        var dependencies = SessionStore.Dependencies()
        dependencies.events = { _, _, _ in SessionHooks.load(at: hooks) }
        dependencies.schedulesTimers = true
        dependencies.watchesEvents = true
        let store = SessionStore(directory: hooks, defaults: defaults, dependencies: dependencies)
        var observations = 0, awakeChanges = 0
        store.onObservation = { rows, _ in observations += 1; awake.observe(rows) }
        let changes = awake.objectWillChange.sink { _ in awakeChanges += 1 }
        defer { changes.cancel(); store.stop() }
        store.useProviders([.claude])
        store.start(clientResolver: resolver)
        R2UIProbe.spin(until: 0.5)
        let queriesBefore = client.statusQueries, observationsBefore = observations, changesBefore = awakeChanges
        var sent = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard sent < 60 else { return }
                let payload: [String: Any] = ["session_id": "awake-\(sent % 3)", "hook_event_name": sent % 2 == 0 ? "PreToolUse" : "PostToolUse",
                                              "tool_name": "Bash", "tool_use_id": "toolu_\(sent)", "cwd": "/synthetic"]
                if sent < 3 {
                    try? SessionHooks.capture(JSONSerialization.data(withJSONObject: ["session_id": "awake-\(sent)", "hook_event_name": "UserPromptSubmit", "cwd": "/synthetic"]),
                                              provider: .claude, at: hooks, client: .terminal, isInternal: { _ in false }, isAlive: { _ in true })
                }
                try? SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: hooks, client: .terminal,
                                          isInternal: { _ in false }, isAlive: { _ in true })
                sent += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let start = R2UIProbe.wall()
        R2UIProbe.spin(until: 4) { sent >= 60 }
        R2UIProbe.spin(until: 0.5)
        timer.invalidate()
        let wall = R2UIProbe.wall() - start
        let queries = client.statusQueries - queriesBefore
        R2UIProbe.report("awake-status-queries", ["hook_events": sent, "wall_s": wall, "observations": observations - observationsBefore,
                                                  "status_queries": queries, "status_queries_per_second": Double(queries) / wall,
                                                  "keep_awake_object_will_change": awakeChanges - changesBefore])
        XCTAssertGreaterThan(observations - observationsBefore, 0)
    }
}
