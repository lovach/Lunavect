import XCTest
@testable import WeekleftCore

/// Owner decision 18 and audit findings Q-06, S-16, H-04: client configuration
/// names a stable link to the running app's hook helper. Every fixture lives in a
/// temporary folder whose path contains spaces and an apostrophe; nothing reads
/// the real ~/.claude, ~/.codex or ~/Library.
final class StableHelperPathTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lunavect helper's path " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var link: URL { root.appendingPathComponent("Library/Application Support/Weekleft/bin/LunavectHook") }
    /// An app bundle whose helper records its arguments and answers like the real one.
    @discardableResult private func bundle(_ relative: String, helper: Bool = true) throws -> URL {
        let app = root.appendingPathComponent(relative)
        let executable = app.appendingPathComponent("Contents/Helpers/LunavectHook")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        if helper {
            let log = root.appendingPathComponent("arguments.txt")
            try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + SessionHooks.quote(log.path) + "\nprintf '{}'\n")
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return app
    }
    private func location(_ app: URL) -> HookHelperLocation { HookHelperLocation(link: link, bundle: app, fallback: nil) }
    private func helperPath(_ app: URL) -> String { app.appendingPathComponent("Contents/Helpers/LunavectHook").path }
    private func run(_ command: String, input: String = "{}") throws -> (status: Int32, output: String, seconds: TimeInterval) {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let start = ProcessInfo.processInfo.systemUptime
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output, ProcessInfo.processInfo.systemUptime - start)
    }

    func testLinkFollowsTheRunningCopyAndATranslocatedCopyLeavesItAlone() throws {
        let home = try bundle("Home/Applications/Lunavect.app"), system = try bundle("Applications/Lunavect.app")
        XCTAssertEqual(location(home).commandExecutable, helperPath(home), "before the first launch: the copy's own helper")
        XCTAssertEqual(try location(home).refreshLink(), .updated)
        XCTAssertEqual(try location(home).refreshLink(), .unchanged)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperPath(home))
        XCTAssertEqual(location(home).commandExecutable, link.path)
        XCTAssertEqual(Set(location(home).acceptedExecutables), [link.path, helperPath(home)])
        // A second copy that runs later owns the link; commands need no rewrite.
        XCTAssertEqual(try location(system).refreshLink(), .updated)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperPath(system))
        // A quarantined download that macOS runs from App Translocation is temporary.
        let moved = try bundle("private/var/folders/xy/T/AppTranslocation/0A1B/d/Lunavect.app")
        XCTAssertTrue(location(moved).isTranslocated)
        XCTAssertEqual(try location(moved).refreshLink(), .translocated)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperPath(system))
        XCTAssertNil(location(moved).commandExecutable, "no command is installed from a temporary copy")
        XCTAssertEqual(location(moved).acceptedExecutables, [link.path])
        // Only a link is ever replaced; a missing helper never produces a dangling link.
        let empty = try bundle("Broken/Lunavect.app", helper: false)
        XCTAssertEqual(try location(empty).refreshLink(), .missingHelper)
        try FileManager.default.removeItem(at: link)
        try Data("not ours".utf8).write(to: link)
        XCTAssertThrowsError(try location(home).refreshLink())
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "not ours")
        XCTAssertFalse(location(home).acceptedExecutables.contains(link.path))
    }

    func testCommandsThroughTheLinkRunUnderShWithSpacesAndQuotes() throws {
        let app = try bundle("Wet Dog's Apps/Lunavect.app")
        try location(app).refreshLink()
        let settings = root.appendingPathComponent(".claude/settings.json"), bridge = root.appendingPathComponent("bridge")
        try SessionHooks.install(provider: .claude, executable: link.path, configURL: settings, backupDirectory: root.appendingPathComponent("backups"))
        try ClaudeProvider.installStatusLine(executable: link.path, settingsURL: settings, bridgeDirectory: bridge)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hook = try XCTUnwrap(((config["hooks"] as? [String: [[String: Any]]])?["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(hook.hasPrefix(SessionHooks.quote(link.path)), hook)
        let hookRun = try run(hook)
        XCTAssertEqual(hookRun.status, 0); XCTAssertEqual(hookRun.output, "{}")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8), "--session-hook\nclaude\n")
        let status = try XCTUnwrap((config["statusLine"] as? [String: Any])?["command"] as? String)
        XCTAssertEqual(try run(status).status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8), "--claude-statusline\n")
        XCTAssertTrue(SessionHooks.installed(.claude, configURL: settings, accepting: location(app).acceptedExecutables))
        XCTAssertTrue(ClaudeProvider.statusLineInstalled(settingsURL: settings, accepting: location(app).acceptedExecutables))
    }

    /// Matrix P5: while an update replaces the bundle the link briefly leads nowhere.
    /// The client's hook then fails as a non-blocking error (never exit code 2,
    /// which would block a tool call) at once and prints nothing to parse.
    func testMissingHelperNeverBlocksTheClient() throws {
        let app = try bundle("Applications/Lunavect.app")
        try location(app).refreshLink()
        try FileManager.default.removeItem(at: app)
        for command in [SessionHooks.command(.claude, executable: link.path), SessionHooks.quote(link.path) + " --claude-statusline"] {
            let result = try run(command)
            XCTAssertEqual(result.status, 127, command)
            XCTAssertEqual(result.output, "")
            XCTAssertLessThan(result.seconds, 3)
        }
    }

    func testBothTheLinkAndTheOlderAbsoluteFormCountAsInstalled() throws {
        let app = try bundle("Applications/Lunavect.app")
        try location(app).refreshLink()
        let accepted = location(app).acceptedExecutables
        for (executable, installed) in [(link.path, true), (helperPath(app), true), ("/gone/Lunavect.app/Contents/Helpers/LunavectHook", false),
                                        ("/private/var/folders/xy/T/AppTranslocation/0A1B/d/Lunavect.app/Contents/Helpers/LunavectHook", false)] {
            let file = root.appendingPathComponent(UUID().uuidString + "/hooks.json")
            try SessionHooks.install(provider: .codex, executable: executable, configURL: file, backupDirectory: root.appendingPathComponent("backups"))
            XCTAssertEqual(SessionHooks.installed(.codex, configURL: file, accepting: accepted), installed, executable)
            XCTAssertTrue(SessionHooks.configured(.codex, configURL: file))
            XCTAssertEqual(SessionHooks.missingCommandExecutable(.codex, configURL: file) != nil, !FileManager.default.isExecutableFile(atPath: executable))
            // Disconnecting removes Lunavect's handlers in every form.
            try SessionHooks.remove(provider: .codex, configURL: file, backupDirectory: root.appendingPathComponent("backups"))
            XCTAssertFalse(SessionHooks.configured(.codex, configURL: file))
        }
    }
}

/// Launch repair (owner decision 17, matrix P3, audit 05 §5 item 2): only
/// Lunavect's own entries that name another path are rewritten.
final class ConnectionRepairTests: XCTestCase {
    private var root: URL!
    private var link: URL { root.appendingPathComponent("Application Support/Weekleft/bin/LunavectHook") }
    private var app: URL { root.appendingPathComponent("Applications/Lunavect.app") }
    private var settings: URL { root.appendingPathComponent(".claude/settings.json") }
    private var bridge: URL { root.appendingPathComponent("bridge") }
    private var backups: URL { root.appendingPathComponent("backups") }
    private let old = "/private/var/folders/xy/T/AppTranslocation/0A1B/d/Lunavect.app/Contents/Helpers/LunavectHook"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect repair " + UUID().uuidString).resolvingSymlinksInPath()
        let helper = app.appendingPathComponent("Contents/Helpers/LunavectHook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '{}'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func setup(_ bundle: URL? = nil, provider: ProviderID = .claude, config: URL? = nil) throws -> ClientConnection.LocalSetup {
        let location = HookHelperLocation(link: link, bundle: bundle ?? app, fallback: nil)
        _ = try? location.refreshLink()
        return ClientConnection.LocalSetup(provider: provider, location: location, configURL: config ?? settings,
                                           bridgeDirectory: bridge, backupDirectory: backups)
    }
    /// Foreign groups in every event, including non-command types and extra group
    /// keys, installed before Lunavect with an old (translocated) helper path.
    private func ownersSettings() throws -> [String: Any] {
        var hooks: [String: [[String: Any]]] = [:]
        for event in SessionHooks.events(.claude) + ["SubagentStart"] {
            hooks[event] = [["matcher": "*", "hooks": [["type": "command", "command": "node ~/.claude/statusbar.js " + event]]],
                            ["hooks": [["type": "prompt", "prompt": "Check " + event]], "note": "foreign"]]
        }
        let root: [String: Any] = ["effortLevel": "high", "permissions": ["allow": ["Read"]], "hooks": hooks,
                                   "statusLine": ["type": "command", "command": "node ~/.claude/hud.js", "padding": 1]]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: settings)
        try ClaudeProvider.installStatusLine(executable: old, settingsURL: settings, bridgeDirectory: bridge)
        try SessionHooks.install(provider: .claude, executable: old, configURL: settings, backupDirectory: backups)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }
    private func foreign(_ root: [String: Any]) -> [String: [[String: Any]]] {
        (root["hooks"] as? [String: [[String: Any]]] ?? [:]).mapValues { groups in
            groups.filter { group in !((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains("lunavect-session-monitor") == true } }
        }
    }
    private func ownCommands(_ root: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (event, groups) in root["hooks"] as? [String: [[String: Any]]] ?? [:] {
            for handler in groups.flatMap({ $0["hooks"] as? [[String: Any]] ?? [] }) {
                if let command = handler["command"] as? String, command.hasSuffix("# lunavect-session-monitor:claude") { result[event] = command }
            }
        }
        return result
    }
    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    func testRepairMovesEveryOwnCommandToTheLinkAndKeepsEverythingElse() throws {
        let before = try ownersSettings()
        let prior = try Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json"))
        let setup = try setup()
        XCTAssertEqual(setup.inspect().hooks, .partial, "a missing helper path is not a working connection")
        XCTAssertEqual(SessionHooks.missingCommandExecutable(.claude, configURL: settings), old)
        XCTAssertEqual(try setup.repair(), .repaired)
        let after = try read()
        XCTAssertEqual(Set(ownCommands(after).keys), Set(SessionHooks.events(.claude)))
        XCTAssertTrue(ownCommands(after).values.allSatisfy { $0 == SessionHooks.command(.claude, executable: link.path) })
        XCTAssertEqual((after["statusLine"] as? [String: Any])?["command"] as? String, SessionHooks.quote(link.path) + " --claude-statusline")
        XCTAssertEqual((after["statusLine"] as? [String: Any])?["padding"] as? Int, 1)
        XCTAssertEqual(foreign(after) as NSDictionary, foreign(before) as NSDictionary, "foreign groups and their order are unchanged")
        XCTAssertEqual(after["permissions"] as? NSDictionary, before["permissions"] as? NSDictionary)
        XCTAssertEqual(try Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json")), prior)
        XCTAssertTrue(setup.inspect().connected)
        XCTAssertNil(SessionHooks.missingCommandExecutable(.claude, configURL: settings))
        let repaired = try Data(contentsOf: settings)
        XCTAssertEqual(try setup.repair(), .unchanged)
        XCTAssertEqual(try Data(contentsOf: settings), repaired, "a current configuration is not rewritten")
        // An older release disconnects the new form too: marker and statusLine shape are unchanged.
        XCTAssertTrue(try setup.apply(.disconnect).disconnected)
        let disconnected = try read()
        XCTAssertTrue(ownCommands(disconnected).isEmpty)
        XCTAssertEqual((disconnected["statusLine"] as? [String: Any])?["command"] as? String, "node ~/.claude/hud.js")
        XCTAssertEqual(foreign(disconnected) as NSDictionary, foreign(before) as NSDictionary)
    }

    func testRepairMigratesTheOlderAbsoluteFormOfTheRunningCopy() throws {
        let current = app.appendingPathComponent("Contents/Helpers/LunavectHook").path
        try SessionHooks.install(provider: .codex, executable: current, configURL: root.appendingPathComponent("hooks.json"), backupDirectory: backups)
        let setup = try setup(provider: .codex, config: root.appendingPathComponent("hooks.json"))
        XCTAssertTrue(setup.inspect().connected, "the absolute form of the running copy still works")
        XCTAssertEqual(try setup.repair(), .repaired)
        let text = try String(contentsOf: root.appendingPathComponent("hooks.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("Contents/Helpers"), text)
        XCTAssertTrue(setup.inspect().connected)
    }

    func testRepairNeverReturnsARemovedEventAndLeavesPausedOrUnreadableSettingsAlone() throws {
        _ = try ownersSettings()
        var edited = try read()
        var hooks = try XCTUnwrap(edited["hooks"] as? [String: [[String: Any]]])
        hooks["PreToolUse"] = hooks["PreToolUse"]?.filter { group in
            !((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains("lunavect-session-monitor") == true }
        }
        edited["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: edited, options: [.prettyPrinted, .sortedKeys]).write(to: settings)
        XCTAssertEqual(try setup().repair(), .repaired)
        XCTAssertNil(ownCommands(try read())["PreToolUse"], "a handler the user removed is not returned")
        XCTAssertEqual(ownCommands(try read()).count, SessionHooks.events(.claude).count - 1)

        // disableAllHooks: paused by the user. No write, no backup, no "moved" report.
        try SessionHooks.install(provider: .claude, executable: old, configURL: settings, backupDirectory: backups)
        var paused = try read(); paused["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: paused, options: [.prettyPrinted, .sortedKeys]).write(to: settings)
        let bytes = try Data(contentsOf: settings)
        let backupsBefore = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(try setup().repair(), .paused)
        XCTAssertEqual(try setup().inspect().hooks, .paused)
        XCTAssertEqual(try setup().inspect().statusLine, .paused)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted(), backupsBefore)

        // Settings Lunavect cannot parse (a comment) are never rewritten or backed up.
        let commented = Data("// mine\n".utf8) + bytes
        try commented.write(to: settings)
        XCTAssertEqual(try setup().repair(), .unreadable)
        XCTAssertEqual(try setup().inspect().hooks, .unavailable)
        XCTAssertEqual(try Data(contentsOf: settings), commented)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted(), backupsBefore)
    }

    func testATranslocatedCopyRefusesToWriteAndSaysWhy() throws {
        _ = try ownersSettings()
        try? FileManager.default.removeItem(at: link.deletingLastPathComponent())
        let moved = root.appendingPathComponent("private/var/folders/xy/T/AppTranslocation/0A1B/d/Lunavect.app")
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app.appendingPathComponent("Contents/Helpers/LunavectHook"),
                                         to: moved.appendingPathComponent("Contents/Helpers/LunavectHook"))
        let bytes = try Data(contentsOf: settings)
        let setup = try setup(moved)
        XCTAssertEqual(try setup.repair(), .refused)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        XCTAssertThrowsError(try setup.apply(.connect)) {
            XCTAssertEqual(($0 as? ClientConnection.LocalFailure)?.cause.localizedDescription, SessionError.translocated.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path), "no link to a temporary copy")
    }
}

/// Coordinator rule after the 28.09 incident: under XCTest no write site may
/// reach the real home folder. Wiring is proven on a temporary folder that the
/// test marks as protected; nothing is ever aimed at the real home folder.
final class LiveWriteGuardTests: XCTestCase {
    func testRealHomeIsProtectedAndTemporaryFoldersAreNot() throws {
        let home = try XCTUnwrap(LiveWriteGuard.realHome)
        XCTAssertTrue(LiveWriteGuard.isProtected(URL(fileURLWithPath: home + "/.claude/settings.json")))
        XCTAssertTrue(LiveWriteGuard.isProtected(URL(fileURLWithPath: home + "/.codex/hooks.json")))
        XCTAssertTrue(LiveWriteGuard.isProtected(HookHelperLocation.defaultLink))
        XCTAssertTrue(LiveWriteGuard.isProtected(SessionHooks.directory))
        XCTAssertTrue(LiveWriteGuard.isProtected(ClaudeProvider.directory))
        XCTAssertFalse(LiveWriteGuard.isProtected(FileManager.default.temporaryDirectory.appendingPathComponent("x.json")))
        XCTAssertFalse(LiveWriteGuard.isProtected(URL(fileURLWithPath: home + "-other/x")), "a sibling prefix is not inside home")
    }
    func testEveryConnectionWriteSiteRefusesAProtectedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guarded home " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("outside").appendingPathComponent("LunavectHook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let home = root.appendingPathComponent("home")
        LiveWriteGuard.protect(home)
        defer { LiveWriteGuard.unprotect(home); try? FileManager.default.removeItem(at: root) }
        let settings = home.appendingPathComponent(".claude/settings.json"), bridge = home.appendingPathComponent("bridge")
        let writes: [(String, () throws -> Void)] = [
            ("hooks", { try SessionHooks.install(provider: .claude, executable: helper.path, configURL: settings, backupDirectory: home.appendingPathComponent("backups")) }),
            ("statusLine", { try ClaudeProvider.installStatusLine(executable: helper.path, settingsURL: settings, bridgeDirectory: bridge) }),
            ("statusLine removal", { try ClaudeProvider.removeStatusLine(settingsURL: settings, bridgeDirectory: bridge) }),
            ("config", { try SessionHooks.writeConfigurationVerified(Data("{}".utf8), to: settings) }),
            ("state", { try LocalStateRecovery.write(Data("{}".utf8), to: home.appendingPathComponent("state.json")) }),
            ("capture", { try SessionHooks.capture(Data(#"{"session_id":"guard","hook_event_name":"Stop"}"#.utf8), provider: .codex, at: home.appendingPathComponent("Sessions")) }),
            ("launcher", { _ = try ClientConnection.writeLauncher("#!/bin/sh\n", provider: .claude, action: .signIn, directory: home.appendingPathComponent("Setup")) }),
            ("link", { try HookHelperLocation(link: home.appendingPathComponent("bin/LunavectHook"), bundle: root, fallback: helper.path).refreshLink() }),
        ]
        for (name, write) in writes {
            XCTAssertThrowsError(try write(), name) { XCTAssertTrue($0 is LiveWriteGuard.Refused, "\(name): \($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "nothing, not even a folder, was created")
    }
}
