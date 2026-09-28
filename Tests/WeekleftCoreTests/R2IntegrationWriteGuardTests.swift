import XCTest
import Darwin
@testable import WeekleftCore

/// r2 audit X, invariant X-I7: under XCTest no production write path changes a
/// protected folder, including the side effects that come before the final
/// write (folder creation, lock files, moving a damaged file aside, removing
/// abandoned temporaries). `LiveWriteGuardTests` proves the final writes of the
/// connection sites; these cases cover the remaining write sites that share
/// state with the real home folder by default.
///
/// Every case works in a temporary folder that the test marks as protected;
/// nothing is ever aimed at the real home folder. Cases whose production code
/// still acts before the guard are wrapped in a strict `XCTExpectFailure` named
/// after the finding (R2-X-02). Once the proposed guard lands, the wrapper
/// reports "expected failure did not occur": remove it and the case becomes an
/// ordinary regression test.
final class R2IntegrationWriteGuardTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lunavect-r2-X-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { LiveWriteGuard.unprotect(home) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Every entry below `home` with its bytes (folders map to an empty marker).
    private func tree() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = home.path + "/"
        guard let items = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey]) else { return result }
        for case let url as URL in items {
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            result[relative] = directory ? Data("<folder>".utf8) : try Data(contentsOf: url)
        }
        return result
    }

    private func write(_ text: String, to relative: String, age: TimeInterval = 0) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
        return url
    }

    /// The operation is refused and the protected folder is byte-for-byte unchanged.
    private func assertRefusedWithoutSideEffects(_ name: String, before: [String: Data], _ operation: () throws -> Void,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        var outcome: Error?
        do { try operation() } catch { outcome = error }
        XCTAssertTrue(outcome is LiveWriteGuard.Refused, "\(name): expected a refusal, got \(String(describing: outcome))", file: file, line: line)
        XCTAssertEqual(try tree(), before, "\(name): the protected folder changed", file: file, line: line)
    }

    // MARK: Shared recovery helpers (owner P, Storage.swift)

    func testMovingADamagedFileAsideIsRefusedInAProtectedFolder() throws {
        let url = try write("{damaged", to: "state.json")
        let before = try tree()
        LiveWriteGuard.protect(home)
        XCTExpectFailure("R2-X-02: LocalStateRecovery.load moves the file before any LiveWriteGuard check") {
            try? assertRefusedWithoutSideEffects("recovery move", before: before) {
                _ = try LocalStateRecovery.load(from: url, empty: [String: Int]()) {
                    try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: $0))
                }
            }
        }
    }

    func testAbandonedTemporaryCleanupIsRefusedInAProtectedFolder() throws {
        _ = try write("partial", to: "." + UUID().uuidString + ".tmp", age: 7200)
        let before = try tree()
        LiveWriteGuard.protect(home)
        XCTExpectFailure("R2-X-02: removeAbandonedTemporaries deletes without a LiveWriteGuard check") {
            try? assertRefusedWithoutSideEffects("temporary cleanup", before: before) {
                _ = try LocalStateRecovery.removeAbandonedTemporaries(in: home, now: Date())
            }
        }
    }

    // MARK: Status line and probe observations (owner Q, Providers.swift)

    private var statusLinePayload: Data {
        get throws {
            try JSONSerialization.data(withJSONObject: ["rate_limits": ["seven_day": [
                "used_percentage": 20, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]]])
        }
    }

    func testStatusLineCaptureCreatesNothingInAProtectedFolder() throws {
        let destination = home.appendingPathComponent("ClaudeStatusLine/quota.json")
        let before = try tree()
        LiveWriteGuard.protect(home)
        let payload = try statusLinePayload
        XCTExpectFailure("R2-X-02: ClaudeProvider.capture creates its folder and lock file before the guarded write") {
            try? assertRefusedWithoutSideEffects("status line capture", before: before) {
                try ClaudeProvider.capture(payload, destination: destination, now: now)
            }
        }
    }

    func testStatusLineCaptureKeepsADamagedObservationInAProtectedFolder() throws {
        let destination = try write("{damaged", to: "ClaudeStatusLine/quota.json")
        let before = try tree()
        LiveWriteGuard.protect(home)
        let payload = try statusLinePayload
        XCTExpectFailure("R2-X-02: ClaudeProvider.capture moves a damaged quota.json aside before the guarded write") {
            try? assertRefusedWithoutSideEffects("status line recovery", before: before) {
                try ClaudeProvider.capture(payload, destination: destination, now: now)
            }
        }
    }

    func testProbeObservationSaveCreatesNoFolderInAProtectedFolder() throws {
        let snapshot = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600), resetPrecision: .minute),
            fetchedAt: now, source: ClaudeUsageProbe.source)
        let before = try tree()
        LiveWriteGuard.protect(home)
        XCTExpectFailure("R2-X-02: ClaudeProvider.saveUsage creates its folder before the guarded write") {
            try? assertRefusedWithoutSideEffects("probe save", before: before) {
                try ClaudeProvider.saveUsage(snapshot, destination: home.appendingPathComponent("ClaudeStatusLine/usage.json"))
            }
        }
    }

    // MARK: Shared activity files and widget selection (owner P)

    func testActivityWritersCreateNoFolderInAProtectedFolder() throws {
        let before = try tree()
        LiveWriteGuard.protect(home)
        XCTExpectFailure("R2-X-02: ActivityHistory/ActivityDetails/ActivityWidgetSelection create folders before the guarded write") {
            try? assertRefusedWithoutSideEffects("history", before: before) {
                try ActivityHistory().save(to: home.appendingPathComponent("Shared/activity.json"))
            }
            try? assertRefusedWithoutSideEffects("details", before: before) {
                try ActivityDetails().save(to: home.appendingPathComponent("Private/activity-details.json"))
            }
            try? assertRefusedWithoutSideEffects("widget selection", before: before) {
                try ActivityWidgetSelection.write(now, kind: "LunavectActivityWidget", period: .week, source: .all, directory: home)
            }
        }
    }

    func testClearingAWidgetSelectionIsRefusedInAProtectedFolder() throws {
        _ = try write("0", to: "ActivitySelection/LunavectActivityWidget-week-all.json")
        let before = try tree()
        LiveWriteGuard.protect(home)
        XCTExpectFailure("R2-X-02: ActivityWidgetSelection.write(nil) removes the file without a LiveWriteGuard check") {
            try? assertRefusedWithoutSideEffects("widget selection clear", before: before) {
                try ActivityWidgetSelection.write(nil, kind: "LunavectActivityWidget", period: .week, source: .all, directory: home)
            }
        }
    }

    // MARK: Session organization (owner S)

    func testSessionOrganizationWritersCreateNoFolderInAProtectedFolder() throws {
        let row = AgentSession(provider: .codex, sessionID: "guarded", title: "Fixture", cwd: "/fixture", phase: .ready,
                               updatedAt: now, observedAt: now, evidence: .hook)
        let before = try tree()
        LiveWriteGuard.protect(home)
        XCTExpectFailure("R2-X-02: SessionVisibility/SessionArrangement create their folder before the guarded write") {
            try? assertRefusedWithoutSideEffects("hidden sessions", before: before) {
                var visibility = try SessionVisibility(url: home.appendingPathComponent("Sessions/hidden-sessions.json"), now: now)
                try visibility.hide(row, now: now)
            }
            try? assertRefusedWithoutSideEffects("arrangement", before: before) {
                try SessionArrangement().save(to: home.appendingPathComponent("Order/arrangement.json"))
            }
        }
    }

    // MARK: Editor descriptors (owner N)

    func testEditorDescriptorSweepLeavesAProtectedFolderAlone() throws {
        let bridge = home.appendingPathComponent("IDEBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let header: [String: Any] = ["version": 1, "id": id, "pid": 4242, "appPath": "/Applications/Visual Studio Code.app",
                                     "bundleIdentifier": "com.microsoft.VSCode"]
        let descriptor = bridge.appendingPathComponent(id + ".json")
        try JSONSerialization.data(withJSONObject: header).write(to: descriptor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date().addingTimeInterval(-3 * 86400)],
                                              ofItemAtPath: descriptor.path)
        let before = try tree()
        LiveWriteGuard.protect(home)
        let endpoints = IDEBridge.scan(at: bridge, now: Date(), process: { _ in nil }, bundle: { _ in nil }, socketDirectories: [])
        XCTAssertTrue(endpoints.isEmpty, "A stopped editor is never an endpoint")
        XCTExpectFailure("R2-X-02: IDEBridge.scan removes expired descriptors without a LiveWriteGuard check") {
            XCTAssertEqual(try? tree(), before, "The sweep changed a protected folder")
        }
    }

    // MARK: The guard itself still refuses what it covers

    /// Control case: the guarded sites of the same folder are refused and leave
    /// nothing behind, so the expected failures above are specific to their sites.
    func testGuardedSitesStayRefusedWithoutSideEffects() throws {
        _ = try write("{\"keep\":true}", to: "Sessions/claude-kept.json")
        let before = try tree()
        LiveWriteGuard.protect(home)
        try assertRefusedWithoutSideEffects("state write", before: before) {
            try LocalStateRecovery.write(Data("{}".utf8), to: home.appendingPathComponent("Sessions/state.json"))
        }
        try assertRefusedWithoutSideEffects("hook capture", before: before) {
            try SessionHooks.capture(Data(#"{"session_id":"guard","hook_event_name":"Stop"}"#.utf8), provider: .codex,
                                     at: home.appendingPathComponent("Sessions"), isInternal: { _ in false }, isAlive: { _ in true })
        }
        try assertRefusedWithoutSideEffects("hook prune", before: before) {
            _ = try SessionHooks.prune(at: home.appendingPathComponent("Sessions"), now: now)
        }
    }
}
