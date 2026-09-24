import XCTest
@testable import WeekleftCore

final class DataStorageGuaranteeTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testAtomicWriterPreservesMigrationSymlinkAndRestrictiveMode() throws {
        let root = try root(), target = root.appendingPathComponent("target.json"), link = root.appendingPathComponent("legacy.json")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try LocalStateRecovery.write(Data("replacement".utf8), to: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("replacement".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
    }
    func testFailedReplacementPreservesDestinationAndCleansTemporary() throws {
        let root = try root(), destination = root.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: sentinel)
        XCTAssertThrowsError(try LocalStateRecovery.write(Data("new".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["occupied"])
    }
    func testActivityAndSelectionWritersKeepExistingSymlinks() throws {
        let root = try root(), target = root.appendingPathComponent("target.json"), link = root.appendingPathComponent("activity.json")
        try ActivityHistory().save(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var history = ActivityHistory()
        let now = Date(); history.append(start: now, end: now.addingTimeInterval(5), providers: 1)
        try history.save(to: link)
        XCTAssertEqual(try ActivityHistory.load(from: target), history)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        let selection = root.appendingPathComponent("ActivitySelection/LunavectActivityWidget-week-all.json")
        try FileManager.default.createDirectory(at: selection.deletingLastPathComponent(), withIntermediateDirectories: true)
        let selectionTarget = root.appendingPathComponent("selection-target.json")
        try JSONEncoder().encode(now).write(to: selectionTarget)
        try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: selectionTarget)
        try ActivityWidgetSelection.write(now.addingTimeInterval(10), kind: "LunavectActivityWidget", period: .week, source: .all, directory: root)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: selection.path), selectionTarget.path)
        XCTAssertEqual(try JSONDecoder().decode(Date.self, from: Data(contentsOf: selectionTarget)), now.addingTimeInterval(10))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: selectionTarget.path)[.posixPermissions] as? Int, 0o600)
    }
    func testStatusLineRecoversCorruptionWithoutLosingOriginalAndUsesSameSymlinkTarget() throws {
        let root = try root(), target = root.appendingPathComponent("quota.json"), link = root.appendingPathComponent("legacy-quota.json")
        let original = Data("broken original".utf8); try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let now = Date(),
            payload = try JSONSerialization.data(withJSONObject: [
                "rate_limits": [
                    "seven_day": [
                        "used_percentage": 20, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970,
                    ]
                ]
            ])
        try ClaudeProvider.capture(payload, destination: link, now: now)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: target)).weekly?.usedPercent, 20)
    }
    func testStatusLineConfigurationKeepsModeExactOriginalAndForeignEditsWithBoundedBackups() throws {
        let root = try root(), settings = root.appendingPathComponent("settings.json"), bridge = root.appendingPathComponent("bridge")
        let original = Data("{ \"statusLine\": {\"type\":\"command\",\"command\":\"cat\",\"padding\":2}, \"custom\": 42 }\n".utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: settings.path)
        for _ in 0..<6 {
            try ClaudeProvider.installStatusLine(executable: "/fixture/LunavectHook", settingsURL: settings, bridgeDirectory: bridge)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int, 0o640)
            try ClaudeProvider.removeStatusLine(settingsURL: settings, bridgeDirectory: bridge)
            XCTAssertEqual(try Data(contentsOf: settings), original)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: bridge.path).filter { $0.hasPrefix("settings-backup-") }
        XCTAssertEqual(backups.count, 8)
        try ClaudeProvider.installStatusLine(executable: "/fixture/LunavectHook", settingsURL: settings, bridgeDirectory: bridge)
        var edited = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        edited["custom"] = 99
        try JSONSerialization.data(withJSONObject: edited).write(to: settings)
        try ClaudeProvider.removeStatusLine(settingsURL: settings, bridgeDirectory: bridge)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(restored["custom"] as? Int, 99)
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "cat")
    }

    func testCombinedClaudeSetupRestoresExactBytesAndModeAndKeepsInterveningForeignEdit() throws {
        for foreignEdit in [false, true] {
            let root = try root(), settings = root.appendingPathComponent("settings.json")
            let original = Data("{ \"statusLine\": {\"type\":\"command\",\"command\":\"cat\"}, \"custom\": 42 }\n".utf8)
            try original.write(to: settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: settings.path)
            let setup = ClientConnection.LocalSetup(provider: .claude, executable: "/usr/bin/true", configURL: settings,
                bridgeDirectory: root.appendingPathComponent("bridge"), backupDirectory: root.appendingPathComponent("backups"))
            XCTAssertTrue(try setup.apply(.connect).connected)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int, 0o640)
            if foreignEdit {
                var changed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
                changed["custom"] = 99
                try JSONSerialization.data(withJSONObject: changed).write(to: settings)
            }
            XCTAssertTrue(try setup.apply(.disconnect).disconnected)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int, 0o640)
            if foreignEdit {
                let result = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
                XCTAssertEqual(result["custom"] as? Int, 99)
                XCTAssertEqual((result["statusLine"] as? [String: Any])?["command"] as? String, "cat")
            } else { XCTAssertEqual(try Data(contentsOf: settings), original) }
        }
    }

    /// Reinstalling after the client edited its settings (an app move or new hook
    /// events) must not record Lunavect's own old handlers as the "original".
    func testDisconnectAfterReinstallOverAnEditedFileRemovesEveryOwnHandler() throws {
        for provider in [ProviderID.codex, .claude] {
            let root = try root(), config = root.appendingPathComponent("hooks.json"), backups = root.appendingPathComponent("backups")
            try Data("{\"custom\": 1}".utf8).write(to: config)
            try SessionHooks.install(provider: provider, executable: "/bin/sh", configURL: config, backupDirectory: backups)
            var edited = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            edited["external"] = "kept"
            try JSONSerialization.data(withJSONObject: edited).write(to: config)
            try SessionHooks.install(provider: provider, executable: "/usr/bin/true", configURL: config, backupDirectory: backups)
            try SessionHooks.remove(provider: provider, configURL: config, backupDirectory: backups)
            let text = try String(contentsOf: config, encoding: .utf8)
            XCTAssertFalse(text.contains("lunavect-session-monitor"), "\(provider): no Lunavect handler survives the first disconnect")
            let result = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            XCTAssertEqual(result["external"] as? String, "kept")
            XCTAssertFalse(text.contains("\\/"), "paths are written without escaped slashes")
            XCTAssertEqual(result["custom"] as? Int, 1)
        }
    }
}
