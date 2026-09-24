import XCTest
@testable import WeekleftCore

final class SessionOrganizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func row(_ id: String, phase: SessionPhase = .running) -> AgentSession {
        AgentSession(provider: .claude, sessionID: id, title: id, cwd: "", phase: phase, updatedAt: now, observedAt: now)
    }
    func testNewAttentionRowsLeadWithoutReorderingExistingManualRowsOrPins() {
        let rows = [row("a"), row("b", phase: .ready), row("new", phase: .permission), row("ordinary", phase: .ready)]
        var arrangement = SessionArrangement()
        arrangement.order = [rows[1].id, rows[0].id]
        XCTAssertEqual(arrangement.arranged(rows).map(\.sessionID), ["new", "b", "a", "ordinary"])
        arrangement.pinned = [rows[0].id]
        XCTAssertEqual(arrangement.arranged(rows).map(\.sessionID), ["a", "new", "b", "ordinary"])
        arrangement.order.append(rows[2].id)
        XCTAssertEqual(arrangement.arranged(rows).map(\.sessionID), ["a", "b", "new", "ordinary"])
    }
    func testOnlyLongAbsentOrderIDsArePrunedAndLegacyPreferencesGetGracePeriod() throws {
        var arrangement = try JSONDecoder().decode(SessionArrangement.self, from: Data(#"{"order":["claude:old","claude:present"],"pinned":["claude:old"]}"#.utf8))
        XCTAssertTrue(arrangement.observe(["claude:present"], now: now))
        XCTAssertEqual(arrangement.order.count, 2)
        _ = arrangement.observe(["claude:present"], now: now.addingTimeInterval(34 * 86400))
        XCTAssertEqual(arrangement.pinned, ["claude:old"])
        _ = arrangement.observe(["claude:present"], now: now.addingTimeInterval(36 * 86400))
        XCTAssertEqual(arrangement.order, ["claude:present"])
        XCTAssertTrue(arrangement.pinned.isEmpty)
    }
    func testLoadingPrunesOnlyExpiredRemovedTombstones() throws {
        let url = try directory().appendingPathComponent("hidden.json")
        var records = [String: Any]()
        for index in 0..<20_000 { records["claude:\(index)"] = ["hiddenAt": now.addingTimeInterval(-40 * 86400).timeIntervalSinceReferenceDate, "removed": true] }
        records["claude:kept"] = ["hiddenAt": now.addingTimeInterval(-40 * 86400).timeIntervalSinceReferenceDate]
        records["claude:recent"] = ["hiddenAt": now.timeIntervalSinceReferenceDate, "removed": true]
        try JSONSerialization.data(withJSONObject: ["sessions": records]).write(to: url)
        let visibility = try SessionVisibility(url: url, now: now)
        XCTAssertEqual(visibility.hidden, ["claude:kept"])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((saved["sessions"] as? [String: Any])?.count, 2)
        XCTAssertTrue(visibility.visible([row("recent")]).isEmpty)
    }
    func testHiddenRecordsExpireOnlyAfterLongAbsenceFromACompleteSource() throws {
        let url = try directory().appendingPathComponent("hidden.json")
        let old = now.addingTimeInterval(-40 * 86400).timeIntervalSinceReferenceDate
        let records: [String: Any] = [
            "claude:listed": ["hiddenAt": old], "claude:gone": ["hiddenAt": old], "codex:unobserved": ["hiddenAt": old],
            "claude:active": ["hiddenAt": old, "eventAt": now.addingTimeInterval(-2 * 86400).timeIntervalSinceReferenceDate],
            "claude:removed": ["hiddenAt": now.timeIntervalSinceReferenceDate, "removed": true],
        ]
        try JSONSerialization.data(withJSONObject: ["sessions": records]).write(to: url)
        var visibility = try SessionVisibility(url: url, now: now)
        XCTAssertEqual(visibility.hidden.count, 4, "Loading alone never expires a hidden session")
        XCTAssertEqual(try visibility.observe(["claude:listed"], completeProviders: [], now: now), 0, "A partial observation proves no absence")
        XCTAssertEqual(try visibility.observe(["claude:listed"], completeProviders: [.claude], now: now), 1)
        XCTAssertEqual(visibility.hidden, ["claude:listed", "claude:active", "codex:unobserved"])
        XCTAssertTrue(visibility.visible([row("listed")]).isEmpty, "A session that is still listed stays hidden")
        // A sighting restarts the retention period; later absence counts from it.
        XCTAssertEqual(try visibility.observe([], completeProviders: [.claude], now: now.addingTimeInterval(34 * 86400)), 1)
        XCTAssertEqual(try SessionVisibility(url: url, now: now.addingTimeInterval(34 * 86400)).hidden, ["claude:listed", "codex:unobserved"])
        XCTAssertEqual(try visibility.observe([], completeProviders: [.claude], now: now.addingTimeInterval(36 * 86400)), 1)
        XCTAssertEqual(visibility.hidden, ["codex:unobserved"], "An unobserved provider keeps its records")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil((saved["sessions"] as? [String: Any])?["claude:removed"], "Removed tombstones keep their own expiry")
    }
    func testAbandonedTemporariesAreRemovedButWritesInProgressAndForeignFilesAreKept() throws {
        let root = try directory(), manager = FileManager.default, date = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: date.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let abandoned = try file("." + UUID().uuidString + ".tmp", age: 7200)
        let kept = try [file("." + UUID().uuidString + ".tmp", age: 60), file(".notes.tmp", age: 7200),
                        file(UUID().uuidString + ".tmp", age: 7200), file(".lunavect-" + UUID().uuidString + ".tmp", age: 7200)]
        let link = root.appendingPathComponent("." + UUID().uuidString + ".tmp")
        try manager.createSymbolicLink(at: link, withDestinationURL: kept[1])
        try SessionHooks.prune(at: root, now: date)
        XCTAssertFalse(manager.fileExists(atPath: abandoned.path))
        for url in kept + [link] { XCTAssertNotNil(try? manager.attributesOfItem(atPath: url.path), url.lastPathComponent) }
        // The status-line helper cleans its own directory after a capture.
        let status = try directory(), orphan = status.appendingPathComponent("." + UUID().uuidString + ".tmp")
        try Data("x".utf8).write(to: orphan)
        try manager.setAttributes([.modificationDate: date.addingTimeInterval(-7200)], ofItemAtPath: orphan.path)
        try ClaudeProvider.capture(JSONSerialization.data(withJSONObject: ["rate_limits": ["seven_day": [
            "used_percentage": 20, "resets_at": date.addingTimeInterval(86400).timeIntervalSince1970]]]),
            destination: status.appendingPathComponent("quota.json"), now: date)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: status.path).filter { $0.hasSuffix(".tmp") }, [])
    }
    func testOnlyOwnLaunchersOlderThanADayArePruned() throws {
        let root = try directory(), manager = FileManager.default, date = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/zsh\n".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: date.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let old = try file("claude-" + UUID().uuidString + ".command", age: 2 * 86400)
        let kept = try [file("codex-" + UUID().uuidString + ".command", age: 3600), file("notes.command", age: 2 * 86400),
                        file("claude-" + UUID().uuidString + ".txt", age: 2 * 86400)]
        let link = root.appendingPathComponent("claude-" + UUID().uuidString + ".command")
        try manager.createSymbolicLink(at: link, withDestinationURL: kept[1])
        XCTAssertEqual(try SessionHooks.pruneOpeners(in: root, now: date), 1)
        XCTAssertFalse(manager.fileExists(atPath: old.path))
        for url in kept + [link] { XCTAssertNotNil(try? manager.attributesOfItem(atPath: url.path), url.lastPathComponent) }
        XCTAssertEqual(try SessionHooks.pruneOpeners(in: root.appendingPathComponent("missing"), now: date), 0)
    }
    func testHookConnectionRoundTripPreservesBytesModeAndForeignSemantics() throws {
        let root = try directory(), file = root.appendingPathComponent("settings.json"), backups = root.appendingPathComponent("backups")
        let original = Data("{ \"env\": {\"X\":\"值\"}, \"unrelated\": [1,true,null] }\n".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try SessionHooks.install(provider: .claude, executable: "/bin/echo", configURL: file, backupDirectory: backups)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o640)
        try SessionHooks.remove(provider: .claude, configURL: file, backupDirectory: backups)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o640)
        try SessionHooks.install(provider: .claude, executable: "/bin/echo", configURL: file, backupDirectory: backups)
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        changed["foreignChange"] = ["keep": true]
        try JSONSerialization.data(withJSONObject: changed).write(to: file)
        try SessionHooks.remove(provider: .claude, configURL: file, backupDirectory: backups)
        let removed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((removed["foreignChange"] as? [String: Bool])?["keep"], true)
        XCTAssertNil(removed["hooks"])
    }
    func testBackupRotationKeepsForeignNamesAndSymlinks() throws {
        let root = try directory(), file = root.appendingPathComponent("settings.json"), backups = root.appendingPathComponent("backups")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let foreign = backups.appendingPathComponent("claude-personal.json")
        try Data("foreign".utf8).write(to: foreign)
        let link = backups.appendingPathComponent("claude-" + UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        for _ in 0..<12 {
            try SessionHooks.install(provider: .claude, executable: "/bin/echo", configURL: file, backupDirectory: backups)
            try SessionHooks.remove(provider: .claude, configURL: file, backupDirectory: backups)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(names.count, 10, "Eight owned snapshots plus the foreign file and symlink")
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), foreign.path)
    }
    func testNewConfigIsRemovedOnUnchangedDisconnectAndReadOnlyConfigIsPreserved() throws {
        let root = try directory(), file = root.appendingPathComponent("hooks.json"), backups = root.appendingPathComponent("backups")
        try SessionHooks.install(provider: .codex, executable: "/bin/echo", configURL: file, backupDirectory: backups)
        try SessionHooks.remove(provider: .codex, configURL: file, backupDirectory: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        XCTAssertThrowsError(try SessionHooks.install(provider: .codex, executable: "/bin/echo", configURL: file, backupDirectory: backups))
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
    }
    func testIncompleteCatalogHasItsOwnRefreshDiagnostic() {
        let issue = ClientIntegrationIssue(provider: .codex, capability: .sessionCatalog, reason: .incompleteCatalog)
        let diagnostic = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .signedIn, eventsConfigured: true, snapshot: nil, sessionIssue: issue.message, now: now, sourceIssue: issue)
        XCTAssertEqual(diagnostic.state, .incompleteCatalog)
        XCTAssertEqual(diagnostic.repair, .refresh)
        XCTAssertFalse(diagnostic.guidance.contains("обработчик"))
    }
    func testMissingTitleUsesDisplayFallbackWithoutRewritingRealNames() throws {
        let data = Data(#"{"session_id":"fixture","hook_event_name":"SessionStart"}"#.utf8)
        var session = try SessionRecord.event(data, provider: .claude, previous: nil, now: now).session
        XCTAssertEqual(session.title, "")
        XCTAssertEqual(session.displayTitle, L("Сессия Claude"))
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.displayTitle(language: "en"), L10n.text("Сессия Claude", language: "en"))
        XCTAssertEqual(decoded.displayTitle(language: "de"), L10n.text("Сессия Claude", language: "de"))
        XCTAssertNotEqual(decoded.displayTitle(language: "en"), decoded.displayTitle(language: "de"))
        session.title = " \n "
        XCTAssertEqual(session.displayTitle, L("Сессия Claude"))
        session.title = "scratch-real-user-title"
        XCTAssertEqual(session.displayTitle, "scratch-real-user-title")
        session.title = "Сессия Claude"
        XCTAssertEqual(session.displayTitle, "Сессия Claude", "Explicit names are never recognized by comparing fallback text")
    }
}
