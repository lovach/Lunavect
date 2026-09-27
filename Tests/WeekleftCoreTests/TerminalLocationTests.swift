import XCTest
@testable import WeekleftCore

/// Terminal focus scripts another application, so its inputs are validated here.
final class TerminalLocationTests: XCTestCase {
    func testDetachedHookFindsItsClientsControllingTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c"), executable = root.appendingPathComponent("claude")
        try #"""
        #include <util.h>
        #include <unistd.h>
        #include <stdio.h>
        #include <signal.h>
        int main(void) {
            int master; pid_t client = forkpty(&master, NULL, NULL, NULL);
            if (client < 0) return 1;
            if (client == 0) {
                if (fork() == 0) {
                    if (setsid() < 0) _exit(2);
                    printf("%d\n", getpid()); fflush(stdout);
                }
                for (;;) pause();
            }
            char bytes[128]; int n = read(master, bytes, sizeof(bytes));
            if (n > 0) { write(STDOUT_FILENO, bytes, n); }
            for (;;) pause();
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]; try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let output = Pipe(), process = Process(); process.executableURL = executable; process.standardOutput = output
        process.currentDirectoryURL = root
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let hook = try XCTUnwrap(Int32(line))
        defer { _ = kill(hook, SIGTERM) }
        let client = try XCTUnwrap(SessionProcess.runtimeProcess(hook)).parentPID
        defer { _ = kill(client, SIGTERM) }
        let expected = try XCTUnwrap(SessionProcess.terminalLocation(parentPID: client, termProgram: "Apple_Terminal"))
        let actual = SessionProcess.terminalLocation(parentPID: hook, termProgram: "Apple_Terminal")
        XCTAssertEqual(actual?.tty, expected.tty, "A detached hook has no controlling TTY; its live client still does")
        XCTAssertEqual(actual?.app, "Terminal")
        XCTAssertEqual(TerminalLocation.runningTarget(provider: .claude, cwd: root.path)?.tty, expected.tty)

        let otherOutput = Pipe(), other = Process(); other.executableURL = executable
        other.currentDirectoryURL = root; other.standardOutput = otherOutput
        try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        let otherLine = String(decoding: otherOutput.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let otherHook = try XCTUnwrap(Int32(otherLine))
        defer { _ = kill(otherHook, SIGTERM) }
        let otherClient = try XCTUnwrap(SessionProcess.runtimeProcess(otherHook)).parentPID
        defer { _ = kill(otherClient, SIGTERM) }
        XCTAssertNil(TerminalLocation.runningTarget(provider: .claude, cwd: root.path),
                     "Two sessions in one folder cannot be distinguished by folder alone")
    }

    func testCatalogAssociatesEachSessionWithItsOwnProcessAndPreservesLiveLocation() throws {
        let data = Data(#"[{"sessionId":"first","pid":10,"cwd":"/tmp/project","kind":"interactive","status":"busy"},{"sessionId":"second","pid":20,"cwd":"/tmp/project","kind":"interactive","status":"busy"},{"sessionId":"background","pid":30,"kind":"background","status":"busy"},{"sessionId":"bad-pid","pid":-2,"kind":"interactive"}]"#.utf8)
        var reads: [Int32] = []
        let now = Date()
        let catalog = try SessionParser.claude(data, now: now, terminal: { pid in
            reads.append(pid)
            return TerminalLocation.Target(tty: pid == 10 ? "/dev/ttys003" : "/dev/ttys004", app: "Terminal")
        })
        XCTAssertEqual(reads, [10, 20], "Background tasks use attach; invalid PIDs never reach libproc")
        XCTAssertEqual(catalog[0].client, .terminal)
        XCTAssertEqual(catalog[0].terminalTTY, "/dev/ttys003")
        XCTAssertEqual(catalog[1].terminalTTY, "/dev/ttys004")
        var old = catalog[0]; old.evidence = .hook
        old.observedAt = now.addingTimeInterval(-60); old.terminalTTY = "/dev/ttys099"
        let merged = SessionList.merge(catalog: catalog, events: [old], now: now)
        XCTAssertEqual(merged.first { $0.sessionID == "first" }?.terminalTTY, "/dev/ttys003",
                       "A hook from an earlier terminal must not overwrite the current process")
        let unlocated = try SessionParser.claude(data, now: now)
        XCTAssertEqual(SessionList.merge(catalog: unlocated, events: [old], now: now).first { $0.sessionID == "first" }?.terminalTTY,
                       "/dev/ttys099", "Hooks still recover a location when the catalog cannot")
    }

    func testAutomationDenialAndTimeoutHaveSpecificRecoveryMessages() {
        XCTAssertEqual(TerminalLocation.focusError(code: -1743, app: "Terminal"), .terminalAutomationDenied("Terminal"))
        XCTAssertEqual(TerminalLocation.focusError(code: -1712, app: "iTerm2"), .terminalFocusTimedOut("iTerm2"))
        XCTAssertEqual(TerminalLocation.focusError(code: -1708, app: "Terminal"), .terminalFocusFailed("Terminal"))
    }

    private func session(client: SessionClient, tty: String? = nil, app: String? = nil, phase: SessionPhase = .running) -> AgentSession {
        var row = AgentSession(provider: .claude, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                               cwd: "/tmp/project", client: client, phase: phase, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        row.terminalTTY = tty; row.terminalApp = app
        return row
    }

    func testOnlyPlainTerminalDevicesReachTheScript() {
        XCTAssertTrue(TerminalLocation.valid("/dev/ttys003"))
        for value in ["/dev/ttys003\n", "/dev/ttys", "/dev/ttys12345", "/dev/console", "/dev/ttys1\" & quit", " /dev/ttys1"] {
            XCTAssertFalse(TerminalLocation.valid(value), value)
            XCTAssertNil(TerminalLocation.focusScript(tty: value, app: "Terminal"), value)
        }
        XCTAssertNil(TerminalLocation.focusScript(tty: "/dev/ttys003", app: "Warp"), "Unknown terminals are not scripted")
        for app in ["Terminal", "iTerm2"] {
            let script = TerminalLocation.focusScript(tty: "/dev/ttys003", app: app)
            XCTAssertTrue(script?.contains("tell application \"\(app)\"") == true, app)
            XCTAssertTrue(script?.contains("is \"/dev/ttys003\"") == true, app)
            XCTAssertNotNil(TerminalLocation.bundleIdentifier(forApp: app))
        }
    }

    /// The helper also bounds each Apple event and stops on its first timeout;
    /// the process runner separately enforces the overall navigation budget.
    func testFocusScriptsBoundEveryAppleEventAndStopAtTheFirstTimeout() throws {
        XCTAssertLessThanOrEqual(TerminalLocation.focusTimeout, 10, "Stays well inside Keep Awake's 30 s lease")
        for app in ["Terminal", "iTerm2"] {
            let script = try XCTUnwrap(TerminalLocation.focusScript(tty: "/dev/ttys003", app: app))
            let lines = script.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(lines.first, "with timeout of \(TerminalLocation.focusTimeout) seconds", app)
            XCTAssertEqual(lines.suffix(2), ["end timeout", "return false"], app)
            let guarded = lines.filter { $0 == "try" }.count
            XCTAssertGreaterThan(guarded, 0, app)
            XCTAssertEqual(lines.filter { $0 == "if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber" }.count, guarded,
                           "\(app): a per-tab error handler must not swallow a timeout or Automation denial")
        }
    }

    func testRecordedDeviceWinsAndOnlyTerminalSessionsSearchProcesses() {
        var searches: [(ProviderID, String)] = []
        let running: (ProviderID, String) -> TerminalLocation.Target? = { provider, cwd in
            searches.append((provider, cwd)); return TerminalLocation.Target(tty: "/dev/ttys009", app: "Terminal")
        }
        XCTAssertEqual(TerminalLocation.focusTarget(for: session(client: .terminal, tty: "/dev/ttys004", app: "iTerm2"), running: running),
                       TerminalLocation.Target(tty: "/dev/ttys004", app: "iTerm2"))
        XCTAssertTrue(searches.isEmpty)
        XCTAssertEqual(TerminalLocation.focusTarget(for: session(client: .terminal), running: running)?.tty, "/dev/ttys009")
        XCTAssertEqual(searches.map(\.1), ["/tmp/project"])
        for client in [SessionClient.desktop, .vscode, .background, .unknown] {
            XCTAssertNil(TerminalLocation.focusTarget(for: session(client: client), running: running), client.rawValue)
        }
        XCTAssertEqual(searches.count, 1, "Desktop, editor and background sessions never match a CLI in the same folder")
        XCTAssertNil(TerminalLocation.focusTarget(for: session(client: .terminal, phase: .finished), running: running),
                     "An exited CLI is resumed instead")
        XCTAssertEqual(TerminalLocation.focusTarget(for: session(client: .terminal, tty: "/dev/ttys004\n"), running: running)?.tty,
                       "/dev/ttys009", "An invalid recorded device falls back to the process search")
    }

    func testRuntimeClassificationIgnoresInterpreters() {
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/.local/share/claude/versions/2.1.280"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Applications/ChatGPT.app/Contents/Resources/codex"), .codex)
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/node"), "A dev server in the same folder is not Claude")
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/versions/2.1.280"))
    }
}
