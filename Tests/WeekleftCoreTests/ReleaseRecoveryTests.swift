import XCTest
@testable import WeekleftCore

final class ReleaseRecoveryTests: XCTestCase {
    func testEmbeddedHookIsPreferredAndMovesWithoutReplacingPreviousHUD() throws {
        let root = try directory(), bundle = root.appendingPathComponent("Lunavect.app")
        let helper = bundle.appendingPathComponent("Contents/Helpers/LunavectHook")
        let fallback = bundle.appendingPathComponent("Contents/MacOS/Lunavect").path
        XCTAssertEqual(SessionHooks.monitorExecutable(bundle: bundle, fallback: fallback), fallback)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        XCTAssertEqual(SessionHooks.monitorExecutable(bundle: bundle, fallback: fallback), helper.path)
        let config = root.appendingPathComponent("settings.json"), bridge = root.appendingPathComponent("bridge")
        try Data(#"{"statusLine":{"type":"command","command":"my-hud"}}"#.utf8).write(to: config)
        try ClaudeProvider.installStatusLine(executable: fallback, settingsURL: config, bridgeDirectory: bridge)
        let backup = try Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json"))
        try ClaudeProvider.installStatusLine(executable: helper.path, settingsURL: config, bridgeDirectory: bridge)
        XCTAssertTrue(ClaudeProvider.statusLineInstalled(settingsURL: config, executable: helper.path))
        XCTAssertEqual(try Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json")), backup)
    }
    func testOutputHeldOpenByDescendantStillTimesOut() throws {
        let root = try directory(), script = root.appendingPathComponent("cli"), pidFile = root.appendingPathComponent("child")
        try Data("#!/bin/sh\nread line\n/bin/sleep 10 &\necho $! >> \(SessionHooks.quote(pidFile.path))\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer {
            if let value = try? String(contentsOf: pidFile) {
                for line in value.split(separator: "\n") { if let pid = Int32(line) { kill(pid, SIGTERM) } }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SessionProcess.run(path: script.path, arguments: [], timeout: 0.3)) {
            XCTAssertEqual(($0 as? SessionError)?.errorDescription, SessionError.timeout.errorDescription)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
        XCTAssertThrowsError(try CodexProvider.read(cliPath: script.path, timeout: 0.3)) {
            XCTAssertEqual(($0 as? UsageError)?.errorDescription, UsageError.timeout.errorDescription)
        }
        XCTAssertEqual(String(decoding: try SessionProcess.run(path: "/bin/echo", arguments: ["ok"]), as: UTF8.self), "ok\n")
    }
    func testPruningKeepsRecentAndForeignFilesAndCaptureUsesOneLock() throws {
        let root = try directory(), now = Date(), old = now.addingTimeInterval(-90000)
        func record(_ id: String, observed: Date, modified: Date) throws -> URL {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": id, "hook_event_name": "Stop"])
            let record = try SessionRecord.event(data, provider: .claude, previous: nil, now: observed)
            let url = root.appendingPathComponent("claude-\(id).json")
            try JSONEncoder().encode(record).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let expired = try record("old-session", observed: old, modified: old)
        let recent = try record("recent-session", observed: now, modified: old)
        let touched = try record("touched-session", observed: old, modified: now)
        let foreign = root.appendingPathComponent("hidden-sessions.json"), legacyLock = expired.appendingPathExtension("lock")
        try Data("keep".utf8).write(to: foreign); try Data().write(to: legacyLock)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: legacyLock.path)
        XCTAssertEqual(try SessionHooks.prune(at: root, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLock.path))
        for file in [recent, touched, foreign] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        for id in ["first-session", "second-session"] {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": id, "hook_event_name": "UserPromptSubmit"])
            try SessionHooks.capture(data, provider: .claude, at: root)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".lock") }, [".capture.lock"])
        XCTAssertEqual(try SessionHooks.prune(at: root, now: now.addingTimeInterval(10)), 0)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testMalformedQuotaPreservesPreferencesAndOriginalBytes() throws {
        let file = try directory().appendingPathComponent("snapshot.json")
        var preferences = WidgetPreferences()
        preferences.subscriptionDates = ["claude": "2026-12-01"]
        preferences.enabledProviders = [.claude]; preferences.showFiveHour = true
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SharedState(preferences: preferences))) as? [String: Any])
        root["snapshots"] = [["provider": "claude", "weekly": "broken"]]
        let bytes = try JSONSerialization.data(withJSONObject: root)
        try bytes.write(to: file)
        let recovered = try SnapshotStore.loadRecovering(from: file)
        XCTAssertEqual(recovered.value.preferences, preferences)
        XCTAssertTrue(recovered.value.snapshots.isEmpty)
        let backup = try XCTUnwrap(recovered.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        try JSONEncoder().encode(recovered.value).write(to: file)
        XCTAssertNil(try SnapshotStore.loadRecovering(from: file).backupURL)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }
    func testMissingIsEmptyButPermissionErrorsNeverBecomeEmptyOrOverwriteData() throws {
        let file = try directory().appendingPathComponent("snapshot.json")
        XCTAssertNil(try SnapshotStore.loadRecovering(from: file).backupURL)
        let bytes = Data("private original".utf8); try bytes.write(to: file)
        XCTAssertThrowsError(try LocalStateRecovery.load(from: file, empty: SharedState()) { _ in
            throw CocoaError(.fileReadNoPermission)
        })
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testInvalidActivityCanResumeAfterPreservingOriginal() throws {
        let file = try directory().appendingPathComponent("activity.json")
        let bytes = Data(#"{"intervals":[{"start":100,"end":90,"providers":1}]}"#.utf8)
        try bytes.write(to: file)
        let result = try LocalStateRecovery.load(from: file, empty: ActivityHistory(), read: { try ActivityHistory.load(from: $0) })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backupURL)), bytes)
        var history = result.value
        history.append(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 120), providers: 1)
        try history.save(to: file)
        XCTAssertEqual(try ActivityHistory.load(from: file).intervals.count, 1)
    }
    func testOlderImportReportWithMissingCountersKeepsIntervals() throws {
        let file = try directory().appendingPathComponent("activity.json")
        try Data(#"{"intervals":[{"start":100,"end":120,"providers":1}],"importReport":{"providers":[{"id":"claude","filesRead":3}]}}"#.utf8).write(to: file)
        let history = try ActivityHistory.load(from: file)
        XCTAssertEqual(history.intervals.count, 1)
        XCTAssertEqual(history.importReport?.providers.first?.filesRead, 3)
        XCTAssertEqual(history.importReport?.providers.first?.bytesRead, 0)
        XCTAssertTrue(history.needsImport)
    }
    func testStatusLineMoveDisconnectAndReconnectPreserveHUDAndSymlink() throws {
        let root = try directory(), target = root.appendingPathComponent("real-settings.json"), link = root.appendingPathComponent("settings.json"), bridge = root.appendingPathComponent("bridge")
        let original: [String: Any] = ["permissions": ["allow": ["Read"]], "statusLine": ["type": "command", "command": "cat", "padding": 2]]
        try JSONSerialization.data(withJSONObject: original).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try ClaudeProvider.installStatusLine(executable: "/Volumes/Installer/Lunavect.app/main", settingsURL: link, bridgeDirectory: bridge)
        let saved = try Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json"))
        let current = try XCTUnwrap(Bundle.main.executablePath)
        XCTAssertFalse(ClaudeProvider.statusLineInstalled(settingsURL: link, executable: current))
        try ClaudeProvider.installStatusLine(executable: current, settingsURL: link, bridgeDirectory: bridge)
        XCTAssertTrue(ClaudeProvider.statusLineInstalled(settingsURL: link, executable: current))
        XCTAssertEqual(try Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json")), saved)
        try ClaudeProvider.removeStatusLine(settingsURL: link, bridgeDirectory: bridge)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: link)) as? NSDictionary, original as NSDictionary)
        XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        try ClaudeProvider.installStatusLine(executable: current, settingsURL: link, bridgeDirectory: bridge)
        try ClaudeProvider.removeStatusLine(settingsURL: link, bridgeDirectory: bridge)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: link)) as? NSDictionary, original as NSDictionary)
    }
    func testRemovingBridgeDoesNotReplaceNewUserHUDAndMissingBackupFailsClosed() throws {
        let root = try directory(), file = root.appendingPathComponent("settings.json"), bridge = root.appendingPathComponent("bridge")
        try ClaudeProvider.installStatusLine(executable: "/old/app", settingsURL: file, bridgeDirectory: bridge)
        try FileManager.default.removeItem(at: bridge.appendingPathComponent("previous-statusline.json"))
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try ClaudeProvider.removeStatusLine(settingsURL: file, bridgeDirectory: bridge))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let user = Data(#"{"statusLine":{"type":"command","command":"my-new-hud"}}"#.utf8)
        try user.write(to: file)
        try ClaudeProvider.removeStatusLine(settingsURL: file, bridgeDirectory: bridge)
        XCTAssertEqual(try Data(contentsOf: file), user)
    }
    func testHookMoveChecksExecutableAndPreservesOtherHooksAndSymlink() throws {
        let root = try directory(), real = root.appendingPathComponent("dotfile.json"), file = root.appendingPathComponent("hooks.json"), backup = root.appendingPathComponent("backups")
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-hook"}]}]}}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        try SessionHooks.install(provider: .codex, executable: "/gone/Lunavect", configURL: file, backupDirectory: backup)
        let current = try XCTUnwrap(Bundle.main.executablePath)
        XCTAssertTrue(SessionHooks.configured(.codex, configURL: file))
        XCTAssertFalse(SessionHooks.installed(.codex, configURL: file, executable: current))
        try SessionHooks.install(provider: .codex, executable: current, configURL: file, backupDirectory: backup)
        XCTAssertTrue(SessionHooks.installed(.codex, configURL: file, executable: current))
        XCTAssertTrue(try String(contentsOf: file).contains("my-hook"))
        XCTAssertEqual(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertFalse(SessionHooks.installed(.codex, configURL: file, executable: "/gone/Lunavect"))
    }
    func testFreshCacheAvoidsProbeButExpiredWindowRequiresRefresh() throws {
        let now = Date(), end = now.addingTimeInterval(3600)
        var snapshot = UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 20, durationMinutes: 10080, resetsAt: end), fiveHour: try QuotaWindow(usedPercent: 5, durationMinutes: 300, resetsAt: end), fetchedAt: now, source: "Claude Code statusLine")
        XCTAssertTrue(ClaudeProvider.cacheIsCurrent(snapshot, now: now.addingTimeInterval(20)))
        XCTAssertFalse(ClaudeProvider.cacheIsCurrent(snapshot, now: now.addingTimeInterval(301)))
        snapshot.fiveHour = try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: now)
        XCTAssertFalse(ClaudeProvider.cacheIsCurrent(snapshot, now: now))
    }
}
