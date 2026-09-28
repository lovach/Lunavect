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
}

private extension AgentSession {
    var name: String { title }
}
