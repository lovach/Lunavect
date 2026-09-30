import XCTest
@testable import WeekleftCore

/// S-01 / T-18: Lunavect's own `/usage` probe runs `claude --safe-mode … /usage`
/// in its private folder. Claude Code 2.1.280 lists it in `claude agents --json --all`
/// as an ordinary interactive row. Every fixture here uses a temporary probe
/// folder; nothing reads the real Application Support folder.
final class QuotaProbeExclusionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaProbeExclusion-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    /// `<root>/Weekleft/QuotaProbe`, plus `<root>/link` -> `<root>/Weekleft`.
    private func probeFixture() throws -> (root: URL, probe: URL, canonical: String) {
        let root = try temporaryRoot()
        let probe = root.appendingPathComponent("Weekleft/QuotaProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Weekleft"))
        return (root, probe, ClaudeUsageProbe.canonicalPath(probe.path))
    }
    /// The live 2.1.280 shape of the probe row, and of ordinary rows next to it.
    private func liveCatalog(probeCwd: String, probePID: Int = 4242) -> [[String: Any]] {
        [
            ["pid": probePID, "cwd": probeCwd, "kind": "interactive", "startedAt": 1_795_000_000_000,
             "sessionId": "0b6c7c52-6a55-4f0e-9d1b-3a1f0c9e2d11", "name": "quotaprobe-00", "status": "waiting"],
            ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "startedAt": 1_795_000_100_000,
             "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "name": "Fix widgets", "status": "busy"],
            ["id": "bg-short-1", "cwd": "/Users/fixture/Projects/lunavect", "kind": "background", "startedAt": 1_795_000_200_000,
             "sessionId": "9e4f2b10-2c3d-4e5f-8a9b-0c1d2e3f4a5b", "name": "Nightly audit", "state": "done"],
        ]
    }

    func testEveryPathFormOfTheProbeFolderIsRecognized() throws {
        let fixture = try probeFixture()
        let path = fixture.probe.path
        var forms = [path, path + "/", path + "//", path + "/.", fixture.probe.deletingLastPathComponent().path + "/../Weekleft/QuotaProbe",
                     fixture.root.appendingPathComponent("link/QuotaProbe").path, path + "/nested/not-created-yet"]
        // The temporary folder is reached through /var -> /private/var on macOS.
        if path.hasPrefix("/private/") { forms.append(String(path.dropFirst("/private".count))) }
        else if path.hasPrefix("/var/") { forms.append("/private" + path) }
        for cwd in forms {
            XCTAssertTrue(ClaudeUsageProbe.isProbeSession(cwd: cwd, pid: nil, canonicalDirectory: fixture.canonical, parentPID: { _ in nil }), cwd)
        }
        for cwd in ["", "/", "Weekleft/QuotaProbe", path + "Other", fixture.probe.deletingLastPathComponent().path,
                    fixture.root.appendingPathComponent("QuotaProbe").path] {
            XCTAssertFalse(ClaudeUsageProbe.isProbeSession(cwd: cwd, pid: nil, canonicalDirectory: fixture.canonical, parentPID: { _ in nil }), cwd)
        }
    }

    /// R2-07: every catalog row is checked on every poll. A project folder on an
    /// unmounted SMB/NFS/autofs volume or a dataless iCloud folder can block
    /// realpath(3) for a network timeout and stall the shared refresh. Only a path
    /// that names the probe folder can resolve into it; nothing else is resolved.
    func testOnlyPathsNamingTheProbeFolderAreResolved() throws {
        let fixture = try probeFixture()
        var resolved: [String] = []
        let resolve: (String) -> String = { resolved.append($0); return ClaudeUsageProbe.canonicalPath($0) }
        for cwd in ["/Volumes/NAS/project", "/net/server/share/app", "/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs/app",
                    "/Users/fixture/Projects/lunavect", fixture.root.appendingPathComponent("Weekleft").path] {
            XCTAssertFalse(ClaudeUsageProbe.isProbeSession(cwd: cwd, pid: nil, canonicalDirectory: fixture.canonical,
                                                           parentPID: { _ in nil }, resolve: resolve), cwd)
        }
        XCTAssertEqual(resolved, [], "Folders that cannot be the probe folder are never touched")
        XCTAssertTrue(ClaudeUsageProbe.isProbeSession(cwd: fixture.canonical + "/", pid: nil, canonicalDirectory: fixture.canonical,
                                                      parentPID: { _ in nil }, resolve: resolve))
        XCTAssertEqual(resolved, [], "The physical folder Claude reports matches without a file system call")
        XCTAssertTrue(ClaudeUsageProbe.isProbeSession(cwd: fixture.root.appendingPathComponent("link/QuotaProbe").path, pid: nil,
                                                      canonicalDirectory: fixture.canonical, parentPID: { _ in nil }, resolve: resolve))
        XCTAssertEqual(resolved.count, 1, "A linked spelling of the probe folder is resolved once")
    }

    func testCanonicalFolderIsStableBeforeAndAfterTheProbeCreatesIt() throws {
        let root = try temporaryRoot()
        let probe = root.appendingPathComponent("Weekleft/QuotaProbe", isDirectory: true)
        let before = ClaudeUsageProbe.canonicalPath(probe.path)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeUsageProbe.canonicalPath(probe.path), before)
        XCTAssertFalse(before.hasSuffix("/"))
        XCTAssertEqual(ClaudeUsageProbe.canonicalPath("relative/QuotaProbe"), "", "Relative paths never match")
    }

    func testDirectChildOfThisAppIsTheProbeWhateverItsFolder() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let canonical = ClaudeUsageProbe.canonicalPath(try temporaryRoot().appendingPathComponent("QuotaProbe").path)
        XCTAssertTrue(ClaudeUsageProbe.isProbeSession(cwd: "/Users/fixture/elsewhere", pid: child.processIdentifier, canonicalDirectory: canonical))
        XCTAssertFalse(ClaudeUsageProbe.isProbeSession(cwd: "/Users/fixture/elsewhere", pid: getppid(), canonicalDirectory: canonical),
                       "A process this app did not start is a user session")
        XCTAssertFalse(ClaudeUsageProbe.isProbeSession(cwd: "/Users/fixture/elsewhere", pid: nil, canonicalDirectory: canonical))
        XCTAssertFalse(ClaudeUsageProbe.isProbeSession(cwd: "/Users/fixture/elsewhere", pid: 1, canonicalDirectory: canonical))
    }

    func testParserDropsTheProbeRowAndKeepsItsNeighbours() throws {
        let fixture = try probeFixture()
        let isInternal: (String, Int32?) -> Bool = {
            ClaudeUsageProbe.isProbeSession(cwd: $0, pid: $1, canonicalDirectory: fixture.canonical, parentPID: { _ in nil })
        }
        for cwd in [fixture.probe.path, fixture.probe.path + "/", fixture.root.appendingPathComponent("link/QuotaProbe").path] {
            for status in ["waiting", "busy", "idle"] {
                var rows = liveCatalog(probeCwd: cwd)
                rows[0]["status"] = status
                let parsed = try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: now, isInternal: isInternal)
                XCTAssertEqual(parsed.map(\.name), ["Fix widgets", "Nightly audit"], "\(cwd) \(status)")
            }
        }
        // The generated name is not the criterion: a user task may carry it.
        var named = liveCatalog(probeCwd: "/Users/fixture/Projects/quotaprobe")
        named[0]["pid"] = 777
        let kept = try SessionParser.claude(JSONSerialization.data(withJSONObject: named), now: now, isInternal: isInternal)
        XCTAssertEqual(kept.count, 3)
        let byParent = try SessionParser.claude(JSONSerialization.data(withJSONObject: named), now: now, isInternal: {
            ClaudeUsageProbe.isProbeSession(cwd: $0, pid: $1, canonicalDirectory: fixture.canonical, parentPID: { $0 == 777 ? 99 : nil }, ownPID: 99)
        })
        XCTAssertEqual(byParent.map(\.name), ["Fix widgets", "Nightly audit"], "The app's direct child is the probe in any folder")
    }

    func testCatalogCommandOutputGoesThroughTheProbeFilter() async throws {
        let fixture = try probeFixture()
        let script = fixture.root.appendingPathComponent("claude")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: liveCatalog(probeCwd: fixture.probe.path)), as: UTF8.self)
        try "#!/bin/sh\ncat <<'JSON'\n\(json)\nJSON\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let canonical = fixture.canonical
        let rows = try await SessionSources.claude(path: script.path, isInternal: {
            ClaudeUsageProbe.isProbeSession(cwd: $0, pid: $1, canonicalDirectory: canonical, parentPID: { _ in nil })
        })
        XCTAssertEqual(rows.map(\.name), ["Fix widgets", "Nightly audit"])
    }

    func testProbeHookIsNeverRecorded() throws {
        let fixture = try probeFixture()
        let sessions = fixture.root.appendingPathComponent("Sessions", isDirectory: true)
        let isInternal: (String) -> Bool = {
            ClaudeUsageProbe.isProbeSession(cwd: $0, pid: nil, canonicalDirectory: fixture.canonical, parentPID: { _ in nil })
        }
        for (index, cwd) in [fixture.probe.path, fixture.probe.path + "/", fixture.root.appendingPathComponent("link/QuotaProbe").path].enumerated() {
            for name in ["SessionStart", "UserPromptSubmit", "Notification"] {
                var payload: [String: Any] = ["session_id": "probe-\(index)", "hook_event_name": name, "cwd": cwd]
                if name == "Notification" { payload["notification_type"] = "idle_prompt" }
                try SessionHooks.capture(JSONSerialization.data(withJSONObject: payload), provider: .claude, at: sessions, isInternal: isInternal)
            }
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path))?.filter { $0.hasSuffix(".json") } ?? []
        XCTAssertEqual(written, [], "No record, so no row, activity, notice or hidden entry can follow")
        let user = try JSONSerialization.data(withJSONObject: ["session_id": "user", "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"])
        try SessionHooks.capture(user, provider: .claude, at: sessions, isInternal: isInternal)
        XCTAssertEqual(SessionHooks.load(at: sessions).map(\.sessionID), ["user"])
    }

    func testStatusBarStateOfTheProbeIsIgnored() throws {
        let fixture = try probeFixture()
        let state = fixture.root.appendingPathComponent("state.d", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        func write(_ id: String, cwd: String) throws {
            let row: [String: Any] = ["sessionId": id, "started": true, "ts": now.timeIntervalSince1970, "pid": Int(getpid()),
                                      "cwd": cwd, "entrypoint": "cli", "state": "thinking", "transcript": "/Users/fixture/.claude/projects/x.jsonl"]
            try JSONSerialization.data(withJSONObject: row).write(to: state.appendingPathComponent(id + ".json"))
        }
        try write("probe", cwd: fixture.probe.path + "/")
        try write("user", cwd: "/Users/fixture/Projects/lunavect")
        let rows = SessionSources.legacyEvents(catalog: [], now: now, directory: state, isInternal: {
            ClaudeUsageProbe.isProbeSession(cwd: $0, pid: nil, canonicalDirectory: fixture.canonical, parentPID: { _ in nil })
        })
        XCTAssertEqual(rows.map(\.sessionID), ["user"])
    }

    /// Decision 28.09: the probe's exact command line, also when run by hand elsewhere.
    /// A person typing /usage in an ordinary session is not a limits check.
    func testManualLimitsCheckIsRecognizedOnlyByTheExactProbeCommandLine() throws {
        // The probe runs exactly these arguments; the recognition uses the same definition.
        let probe = ClaudeUsageProbe.arguments
        XCTAssertEqual(probe.last, "/usage")
        XCTAssertTrue(SessionProcess.isLimitsCheck(arguments: ["claude"] + probe), "The probe's own command line is a limits check")
        XCTAssertTrue(SessionProcess.isLimitsCheck(arguments: ["/Users/u/.local/bin/claude", "--safe-mode", "--tools", "", "/usage"]))
        XCTAssertTrue(SessionProcess.isLimitsCheck(arguments: ["node", "/opt/homebrew/bin/claude"] + probe), "npm-installed Claude")
        for arguments in [["claude"], ["claude", "/usage"], ["claude", "--safe-mode", "/usage"], ["claude", "--tools", "", "/usage"],
                          ["claude", "--safe-mode", "--tools", "Bash", "/usage"], ["claude", "--safe-mode", "--tools", "", "/usage", "--verbose"],
                          ["claude", "--safe-mode", "--tools=", "/usage"], ["claude", "--safe-mode", "--tools", "", "/cost"],
                          ["claude", "--safe-mode", "--tools", "", "Please run /usage"], ["claude", "--resume", "x"], []] {
            XCTAssertFalse(SessionProcess.isLimitsCheck(arguments: arguments), arguments.joined(separator: " "))
        }
        XCTAssertFalse(SessionProcess.isLimitsCheck(pid: 42, arguments: { _ in nil }), "Unreadable arguments are an ordinary session")
        let rows: [[String: Any]] = [
            ["pid": 4343, "cwd": "/Users/fixture", "kind": "interactive", "sessionId": "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d77", "name": "fixture-a3", "status": "waiting"],
            ["pid": 51_234, "cwd": "/Users/fixture", "kind": "interactive", "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "name": "typed /usage", "status": "waiting"],
        ]
        let parsed = try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: now, limitsCheck: {
            SessionProcess.isLimitsCheck(pid: $0, arguments: { $0 == 4343 ? ["claude"] + probe : ["claude"] })
        })
        let check = try XCTUnwrap(parsed.first { $0.title == "fixture-a3" })
        XCTAssertEqual(check.isLimitsCheck, true, "Listed, not dropped: only Lunavect's own probe folder is hidden")
        XCTAssertEqual(check.phase, .input, "The observed state is kept")
        XCTAssertEqual(check.effectivePhase(now: now), .idle, "…but it is shown and counted as neutral")
        XCTAssertTrue(check.isCurrent(now: now))
        let ordinary = try XCTUnwrap(parsed.first { $0.title == "typed /usage" })
        XCTAssertNil(ordinary.isLimitsCheck)
        XCTAssertEqual(ordinary.effectivePhase(now: now), .input)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(check))
        XCTAssertEqual(decoded, check)
    }

    /// Owner report 29.09: the autoharness plugin runs `claude -p` from Python after
    /// every reply. Such a run is listed as a background run, never as work.
    func testPrintModeRunIsABackgroundRunThatIsNotWork() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for arguments in [["claude", "-p", "--agent", "autoharness:reflector", "--dangerously-skip-permissions"],
                          ["/Users/u/.local/bin/claude", "--print", "hello"], ["node", "/opt/homebrew/bin/claude", "--print=json"]] {
            XCTAssertTrue(SessionProcess.isPrintRun(arguments: arguments), arguments.joined(separator: " "))
        }
        for arguments in [["claude"], ["claude", "--resume", "x"], ["-p"], ["claude", "--output-format", "stream-json", "--input-format", "stream-json"],
                          ["claude", "--permission-mode", "plan"], []] {
            XCTAssertFalse(SessionProcess.isPrintRun(arguments: arguments), arguments.joined(separator: " "))
        }
        XCTAssertFalse(SessionProcess.isPrintRun(pid: 42, arguments: { _ in nil }), "Unreadable arguments are an ordinary session")
        let rows: [[String: Any]] = [
            ["pid": 4343, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "sessionId": "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d77",
             "name": "lunavect-dd", "status": "busy"],
            ["pid": 51_234, "cwd": "/Users/fixture", "kind": "interactive", "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "name": "Fix widgets", "status": "busy"],
        ]
        let parsed = try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: now, backgroundRun: {
            SessionProcess.isPrintRun(pid: $0, arguments: { $0 == 4343 ? ["claude", "-p", "--agent", "autoharness:reflector"] : ["claude"] })
        }, host: { $0 == 4343 ? SessionLaunchHost(kind: .application, name: "Python") : nil })
        let run = try XCTUnwrap(parsed.first { $0.title == "lunavect-dd" })
        XCTAssertEqual(run.isBackgroundRun, true)
        XCTAssertEqual(run.effectivePhase(now: now), .idle, "not counted as working")
        XCTAssertEqual(run.backgroundRunRefusal, .backgroundRun("Python"))
        XCTAssertEqual(parsed.first { $0.title == "Fix widgets" }?.isBackgroundRun, nil)
        XCTAssertEqual(parsed.first { $0.title == "Fix widgets" }?.effectivePhase(now: now), .running)
        XCTAssertTrue(SessionOpeningError.backgroundRun("Python").errorDescription?.contains("Python") == true)
        XCTAssertNotNil(SessionOpeningError.backgroundRun(nil).errorDescription)
    }

    /// The hook marks the run too, so it keeps its label after the catalog stops listing it.
    func testBackgroundRunSurvivesMergingAndItsHookRecord() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d77"
        let catalog = AgentSession(provider: .claude, sessionID: id, title: "lunavect-dd", cwd: "/Users/fixture", client: .desktop,
                                   phase: .running, updatedAt: now, observedAt: now, evidence: .catalog)
        var event = AgentSession(provider: .claude, sessionID: id, title: "", cwd: "/Users/fixture", client: .desktop,
                                 phase: .running, updatedAt: now, observedAt: now.addingTimeInterval(1), evidence: .hook)
        event.isBackgroundRun = true
        XCTAssertEqual(SessionList.merge(catalog: [catalog], events: [event], now: now.addingTimeInterval(2)).first?.isBackgroundRun, true)
        XCTAssertEqual(SessionList.merge(catalog: [], events: [event], now: now.addingTimeInterval(2)).first?.isBackgroundRun, true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(#"{"session_id":"\#(id)","hook_event_name":"UserPromptSubmit","cwd":"/Users/fixture"}"#.utf8)
        try SessionHooks.capture(payload, provider: .claude, at: directory, now: now, client: .desktop, backgroundRun: true,
                                 isInternal: { _ in false })
        XCTAssertEqual(SessionHooks.load(at: directory).first?.isBackgroundRun, true)
    }

    /// Audit 30.09: `claude -p --resume <id>` (or `--continue`) from a script on a session still open in Terminal
    /// shares its id. The print run must not take the session's tab, runtime or client, nor end it; and an
    /// interactive runtime reporting later clears a print run's mark.
    func testAPrintRunOnALiveInteractiveSessionKeepsItsTab() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d78"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func event(_ name: String) -> Data { Data(#"{"session_id":"\#(id)","hook_event_name":"\#(name)","cwd":"/Users/fixture"}"#.utf8) }
        let alive: (Int32) -> Bool = { $0 == 4100 }
        try SessionHooks.capture(event("UserPromptSubmit"), provider: .claude, at: directory, now: now, client: .terminal, nestedClaudeRuntime: false,
                                 terminal: (tty: "/dev/ttys004", app: "Terminal"), runtimePID: 4100, isInternal: { _ in false }, isAlive: alive)
        try SessionHooks.capture(event("Stop"), provider: .claude, at: directory, now: now.addingTimeInterval(5), client: .terminal, nestedClaudeRuntime: false,
                                 terminal: (tty: "/dev/ttys004", app: "Terminal"), runtimePID: 4100, isInternal: { _ in false }, isAlive: alive)
        // Live check 30.09: the print run was started from inside another Claude session and hid this one as nested.
        for (offset, name) in [(10.0, "SessionStart"), (11, "UserPromptSubmit"), (20, "Stop"), (21, "SessionEnd")] {
            try SessionHooks.capture(event(name), provider: .claude, at: directory, now: now.addingTimeInterval(offset), client: .background,
                                     nestedClaudeRuntime: true, runtimePID: 5200, backgroundRun: true, isInternal: { _ in false }, isAlive: alive)
        }
        var session = try XCTUnwrap(SessionHooks.load(at: directory).first)
        XCTAssertEqual(session.isNestedClaudeSession, false, "the print run's own parent does not hide the session")
        XCTAssertEqual(session.terminalTTY, "/dev/ttys004")
        XCTAssertEqual(session.client, .terminal)
        XCTAssertEqual(session.runtimePID, 4100)
        XCTAssertNotEqual(session.isBackgroundRun, true)
        XCTAssertNotEqual(session.phase, .finished, "the print run's end is not the session's end")
        // A print run first, then the interactive process: the interactive runtime decides again.
        let other = "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d79"
        func otherEvent(_ name: String) -> Data { Data(#"{"session_id":"\#(other)","hook_event_name":"\#(name)","cwd":"/Users/fixture"}"#.utf8) }
        try SessionHooks.capture(otherEvent("UserPromptSubmit"), provider: .claude, at: directory, now: now, client: .background,
                                 runtimePID: 5300, backgroundRun: true, isInternal: { _ in false }, isAlive: { _ in false })
        try SessionHooks.capture(otherEvent("UserPromptSubmit"), provider: .claude, at: directory, now: now.addingTimeInterval(60), client: .terminal,
                                 terminal: (tty: "/dev/ttys005", app: "Terminal"), runtimePID: 5400, isInternal: { _ in false }, isAlive: { _ in true })
        session = try XCTUnwrap(SessionHooks.load(at: directory).first { $0.sessionID == other })
        XCTAssertNil(session.isBackgroundRun)
        XCTAssertEqual(session.terminalTTY, "/dev/ttys005")
    }
}

private extension AgentSession {
    var name: String { title }
}
