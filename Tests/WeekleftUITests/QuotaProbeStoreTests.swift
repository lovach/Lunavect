import XCTest
import Combine
import AwakeService
@testable import Weekleft
@testable import WeekleftCore

@MainActor private final class ProbeAwakeClient: AwakeClient {
    var isAvailable = true
    var beginCount = 0
    func requestPermission() throws {}
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { beginCount += 1 }
    func configure(policy: AwakeSafetyPolicy) async throws {}
    func keepAlive() async throws {}
    func end() async throws {}
    func disconnect() {}
}

/// S-01: the probe row observed on the owner's Mac on 2026-09-28 (Claude Code
/// 2.1.280) reaches no consumer of the session store. The catalog dependency
/// parses the live row shape exactly as `SessionSources.claude` does, with a
/// temporary probe folder in place of Application Support.
@MainActor final class QuotaProbeStoreTests: XCTestCase {
    func testProbeRowReachesNoPanelCounterNoticeActivityAwakeHiddenListOrFastPolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaProbeStore-" + UUID().uuidString, isDirectory: true)
        let probe = root.appendingPathComponent("Weekleft/QuotaProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let suite = "Lunavect.QuotaProbeStore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let canonical = ClaudeUsageProbe.canonicalPath(probe.path)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        // Every probe run is a new Claude session with a new UUID.
        var probeID = UUID().uuidString.lowercased(), probeStatus = "busy"
        let store = SessionStore(directory: root.appendingPathComponent("Sessions"), defaults: defaults, isolated: true, now: { now },
                                 dependencies: .init(catalog: { _, _, _, _ in
            let rows: [[String: Any]] = [
                ["pid": 4242, "cwd": probe.path, "kind": "interactive", "startedAt": now.timeIntervalSince1970 * 1000 - 2000,
                 "sessionId": probeID, "name": "quotaprobe-00", "status": probeStatus],
                ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "startedAt": 1_795_000_100_000,
                 "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "name": "Fix widgets", "status": "idle"],
            ]
            let rowsData = try JSONSerialization.data(withJSONObject: rows)
            return (try SessionParser.claude(rowsData, now: now, isInternal: {
                ClaudeUsageProbe.isProbeSession(cwd: $0, pid: $1, canonicalDirectory: canonical, parentPID: { _ in nil })
            }), false)
        }, schedulesTimers: true))
        store.useProviders([.claude])
        store.autoHideMinutes = 5
        let client = ProbeAwakeClient()
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        var played: [SessionNoticeKind] = [], observed: [[String]] = []
        var activity = ActivityTracker()
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) })
        features.sounds = true; features.banners = false
        store.onObservation = { rows, date in
            observed.append(rows.map(\.title)); activity.observe(rows, now: date); awake.observe(rows)
        }
        let notices = store.observations.sink { features.observe($0.rows, at: $0.date) }
        defer { notices.cancel(); features.stop(); awake.shutdown(); store.stop() }
        await awake.setAutomatic(true)
        store.start(clientResolver: { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) })
        // One probe lifetime: busy at start, then waiting on the /usage screen,
        // polled every few seconds; then the next run five minutes later.
        var probeIDs: Set<String> = []
        for run in 0..<3 {
            probeIDs.insert(probeID)
            for status in ["busy", "waiting", "waiting", "idle"] {
                probeStatus = status
                await store.refresh(); await awake.reconcileAutomatic()
                XCTAssertFalse(store.sessions.contains { probeIDs.contains($0.sessionID) }, "run \(run) \(status): no panel row")
                XCTAssertEqual(store.activeCount, 0, "Menu bar counters: nothing works or waits")
                XCTAssertEqual(store.polling?.catalog, 45, "The probe cannot switch the catalog to its 15-second cadence")
                now += 5
            }
            now += 300; probeID = UUID().uuidString.lowercased()
        }
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { !$0.contains("quotaprobe-00") }, "Activity tracking and Keep Awake never see the probe")
        XCTAssertTrue(played.isEmpty, "No 'Input needed' sound for the probe's /usage screen")
        XCTAssertEqual(activity.history.intervals.filter { $0.providers != 0 }.count, 0, "No Claude working minutes")
        XCTAssertEqual(client.beginCount, 0, "Automatic Keep Awake stays off")
        XCTAssertFalse(store.hiddenIDs.contains { id in probeIDs.contains { id.hasSuffix($0) } }, "Auto-hide does not archive probe runs")
    }

    /// Owner's case 28.09 10:37: the probe's exact command run by hand in another folder
    /// (the embedded terminal of Claude Desktop, cwd ~). It stays listed with a neutral
    /// state, but is not waiting work, a notice, activity or a reason to keep awake.
    func testManualLimitsCheckIsListedButNeverWaitsNotifiesOrCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaProbeStore-" + UUID().uuidString, isDirectory: true)
        let suite = "Lunavect.QuotaProbeStore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let checkID = "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d77", workID = "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01"
        var checkStatus = "busy"
        let store = SessionStore(directory: root.appendingPathComponent("Sessions"), defaults: defaults, isolated: true, now: { now },
                                 dependencies: .init(catalog: { _, _, _, _ in
            let rows: [[String: Any]] = [
                ["pid": 4343, "cwd": "/Users/fixture", "kind": "interactive", "startedAt": now.timeIntervalSince1970 * 1000 - 2000,
                 "sessionId": checkID, "name": "fixture-a3", "status": checkStatus],
                ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "startedAt": 1_795_000_100_000,
                 "sessionId": workID, "name": "Fix widgets", "status": "waiting"],
            ]
            let data = try JSONSerialization.data(withJSONObject: rows)
            let arguments = ["claude", "--safe-mode", "--ax-screen-reader", "--tools", "", "--strict-mcp-config",
                             "--mcp-config", #"{"mcpServers":{}}"#, "--no-chrome", "/usage"]
            return (try SessionParser.claude(data, now: now, limitsCheck: {
                SessionProcess.isLimitsCheck(pid: $0, arguments: { $0 == 4343 ? arguments : ["claude"] })
            }), false)
        }, schedulesTimers: true))
        store.useProviders([.claude])
        let client = ProbeAwakeClient()
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        var observed: [[String]] = [], noticed: [[String]] = []
        var activity = ActivityTracker()
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { _ in })
        features.sounds = true; features.banners = false
        store.onObservation = { rows, date in
            observed.append(rows.map(\.sessionID)); activity.observe(rows, now: date); awake.observe(rows)
        }
        let notices = store.observations.sink { noticed.append($0.rows.map(\.sessionID)); features.observe($0.rows, at: $0.date) }
        defer { notices.cancel(); features.stop(); awake.shutdown(); store.stop() }
        await awake.setAutomatic(true)
        store.start(clientResolver: { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) })
        for status in ["busy", "waiting", "waiting", "idle"] {
            checkStatus = status
            await store.refresh(); await awake.reconcileAutomatic()
            let row = try XCTUnwrap(store.sessions.first { $0.sessionID == checkID }, "\(status): the check stays listed")
            XCTAssertEqual(row.isLimitsCheck, true)
            XCTAssertEqual(row.effectivePhase(now: now), .idle, "\(status): neutral, never working or awaiting input")
            XCTAssertEqual(store.activeCount, 1, "\(status): only the real session waits")
            now += 5
        }
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { !$0.contains(checkID) && $0.contains(workID) }, "Activity and Keep Awake never see the check")
        XCTAssertTrue(noticed.allSatisfy { !$0.contains(checkID) }, "Notices never see the check")
        XCTAssertEqual(activity.history.intervals.filter { $0.providers != 0 }.count, 0, "No working minutes")
    }
}
