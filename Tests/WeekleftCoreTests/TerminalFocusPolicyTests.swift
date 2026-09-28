import XCTest
import os
@testable import WeekleftCore

/// The terminal focus policy with fixture processes, permissions, scripts and clocks.
/// Nothing here inspects the user's processes or sends Apple events.
final class TerminalFocusPolicyTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: State())
        struct State {
            var clock: TimeInterval = 1_000
            var scripts: [(tty: String, app: String, timeout: TimeInterval)] = []
            var permissions: [(bundle: String, ask: Bool)] = []
            var running: [String] = []
        }
        var clock: TimeInterval { lock.withLock { $0.clock } }
        func advance(_ seconds: TimeInterval) { lock.withLock { $0.clock += seconds } }
        var scripts: [(tty: String, app: String, timeout: TimeInterval)] { lock.withLock { $0.scripts } }
        var permissions: [(bundle: String, ask: Bool)] { lock.withLock { $0.permissions } }
        var running: [String] { lock.withLock { $0.running } }
        func script(_ tty: String, _ app: String, _ timeout: TimeInterval) { lock.withLock { $0.scripts.append((tty, app, timeout)) } }
        func permission(_ bundle: String, _ ask: Bool) { lock.withLock { $0.permissions.append((bundle, ask)) } }
        func runningCheck(_ bundle: String) { lock.withLock { $0.running.append(bundle) } }
    }

    private func session(tty: String? = "/dev/ttys004", app: String? = "Terminal", provider: ProviderID = .claude) -> AgentSession {
        var row = AgentSession(provider: provider, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                               cwd: "/tmp/project", client: .terminal, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        row.terminalTTY = tty; row.terminalApp = app
        return row
    }

    private func environment(_ recorder: Recorder, running: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"],
                             occupancy: TerminalLocation.DeviceOccupancy = .provider,
                             permission: @escaping @Sendable (String, Bool) async throws -> Int32 = { _, _ in 0 },
                             script: @escaping @Sendable (String, String, TimeInterval) async throws -> Bool = { _, _, _ in true }) -> TerminalFocusEnvironment {
        TerminalFocusEnvironment(
            isRunning: { bundle in recorder.runningCheck(bundle); return running.contains(bundle) },
            occupancy: { _, _, _ in occupancy },
            permission: { bundle, ask in recorder.permission(bundle, ask); return try await permission(bundle, ask) },
            runScript: { tty, app, timeout in recorder.script(tty, app, timeout); return try await script(tty, app, timeout) },
            runningTarget: { _, _ in XCTFail("A recorded device must not search processes"); return nil },
            uptime: { recorder.clock })
    }

    /// N-01 / N-15: macOS hands a closed tab's device to the next tab. A fresh
    /// hook record must not make Lunavect select that unrelated tab.
    func testDeviceWithoutTheProviderIsNotFocusedEvenWhileTheHookIsFresh() async throws {
        for app in ["Terminal", "iTerm2"] {
            let recorder = Recorder()
            do {
                _ = try await TerminalLocation.focusSession(session(app: app), environment: environment(recorder, occupancy: .vacant))
                XCTFail("\(app): a reused device must not be focused")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .terminalProcessEnded, app) }
            XCTAssertTrue(recorder.scripts.isEmpty, "\(app): no Apple event for a vacant device")
            XCTAssertTrue(recorder.permissions.isEmpty, "\(app): no consent prompt for a vacant device")
        }
        for occupancy in [TerminalLocation.DeviceOccupancy.provider, .interpreter, .unknown] {
            let recorder = Recorder()
            let focused = try await TerminalLocation.focusSession(session(), environment: environment(recorder, occupancy: occupancy))
            XCTAssertTrue(focused, "\(occupancy) keeps the previous behavior")
            XCTAssertEqual(recorder.scripts.count, 1, "\(occupancy)")
        }
    }

    /// N-02: the first Automation prompt can stay open longer than the 10 s
    /// focus budget. The answer must not be charged to the script's budget.
    func testConsentPromptIsAnsweredOutsideTheFocusBudget() async throws {
        let recorder = Recorder()
        let focused = try await TerminalLocation.focusSession(session(), environment: environment(recorder, permission: { _, ask in
            guard ask else { return -1744 } // errAEEventWouldRequireUserConsent
            recorder.advance(45) // the user reads the dialog, then allows
            return 0
        }))
        XCTAssertTrue(focused)
        XCTAssertEqual(recorder.permissions.map(\.ask), [false, true])
        XCTAssertEqual(recorder.permissions.map(\.bundle), ["com.apple.Terminal", "com.apple.Terminal"])
        let script = try XCTUnwrap(recorder.scripts.first)
        XCTAssertEqual(script.timeout, Double(TerminalLocation.focusTimeout), accuracy: 0.001,
                       "The dialog's time must not be taken from the Apple event budget")
    }

    func testConsentPreflightMapsDenialMissingAppAndUnansweredPrompt() async throws {
        let cases: [(Int32, Bool, SessionOpeningError)] = [
            (-1743, false, .terminalAutomationDenied("Terminal")), // errAEEventNotPermitted
            (-600, false, .terminalTabUnavailable),                // procNotFound: quit since the running check
            (-1744, true, .terminalAutomationPending("Terminal"))  // prompt still open when the wait ends
        ]
        for (status, pending, expected) in cases {
            let recorder = Recorder()
            do {
                _ = try await TerminalLocation.focusSession(session(), environment: environment(recorder, permission: { _, ask in
                    if ask && pending { throw SessionError.timeout }
                    return status
                }))
                XCTFail("\(status) must not report success")
            } catch { XCTAssertEqual(error as? SessionOpeningError, expected, "\(status)") }
            XCTAssertTrue(recorder.scripts.isEmpty, "\(status): the script would only repeat the permission failure")
        }
    }

    /// §4 item 4: a terminal app that is not running is neither scripted nor launched.
    func testTerminalThatIsNotRunningIsNeverScripted() async throws {
        for app in ["Terminal", "iTerm2", ""] {
            let recorder = Recorder()
            do {
                _ = try await TerminalLocation.focusSession(session(app: app), environment: environment(recorder, running: []))
                XCTFail("Nothing to focus")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .terminalTabUnavailable, app) }
            XCTAssertTrue(recorder.scripts.isEmpty, app)
            XCTAssertTrue(recorder.permissions.isEmpty, "\(app): never ask to control an app that is not running")
            XCTAssertFalse(recorder.running.isEmpty, "\(app): the running check is the real policy input")
        }
    }

    /// N-17: when the host is hidden by a root-owned login, a hung first
    /// terminal must not leave nothing of the budget for the second one.
    func testTwoCandidateTerminalsShareTheBudget() async throws {
        let recorder = Recorder()
        let focused = try await TerminalLocation.focusSession(session(app: ""), environment: environment(recorder, script: { _, app, timeout in
            guard app == "Terminal" else { return true }
            recorder.advance(timeout) // Terminal hangs for its whole share
            throw SessionOpeningError.terminalFocusTimedOut("Terminal")
        }))
        XCTAssertTrue(focused)
        XCTAssertEqual(recorder.scripts.map(\.app), ["Terminal", "iTerm2"])
        let shares = recorder.scripts.map(\.timeout)
        XCTAssertEqual(shares.reduce(0, +), Double(TerminalLocation.focusTimeout), accuracy: 0.001, "One overall budget")
        XCTAssertGreaterThanOrEqual(shares.last ?? 0, Double(TerminalLocation.focusTimeout) / 2 - 0.001,
                                    "The second terminal keeps its share of the budget")
    }

    /// N-07 / N-08 / §4 items 6 and 8: identified terminals without a navigation
    /// route get an honest message; Terminal and iTerm2 are not scanned for them.
    func testUnsupportedTerminalHostsAreNamedWithoutScanningOtherTerminals() async throws {
        for (app, name) in [("tmux", "tmux"), ("screen", "screen"), ("Ghostty", "Ghostty"), ("ghostty", "Ghostty"),
                            ("WarpTerminal", "Warp"), ("Cursor", "Cursor"), ("kitty", "kitty")] {
            let recorder = Recorder()
            do {
                _ = try await TerminalLocation.focusSession(session(app: app), environment: environment(recorder))
                XCTFail("\(app) has no navigation route")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .terminalUnsupported(name), app) }
            XCTAssertTrue(recorder.scripts.isEmpty, "\(app): never scan Terminal or iTerm2 tabs")
            XCTAssertTrue(recorder.running.isEmpty, app)
            XCTAssertTrue(recorder.permissions.isEmpty, app)
        }
    }

    /// N-15: iTerm2 restores a minimized window like Terminal does, inside the
    /// same per-tab error handling.
    func testITermScriptRestoresMinimizedWindows() throws {
        let script = try XCTUnwrap(TerminalLocation.focusScript(tty: "/dev/ttys003", app: "iTerm2"))
        XCTAssertTrue(script.contains("if miniaturized of w then set miniaturized of w to false"))
        let restore = try XCTUnwrap(script.range(of: "set miniaturized of w to false"))
        let select = try XCTUnwrap(script.range(of: "tell s to select"))
        XCTAssertLessThan(restore.lowerBound, select.lowerBound, "Restore the window before selecting its session")
    }

    /// The occupancy rule over a fixture process table: only the user's processes
    /// on the exact device count; an interpreter keeps the old behavior.
    func testDeviceOccupancyUsesOnlyTheUsersProcessesOnThatDevice() {
        let uid = getuid()
        func process(_ device: Int32, _ executable: String, uid owner: uid_t = uid) -> TerminalLocation.DeviceProcess {
            .init(uid: owner, device: device, executable: executable)
        }
        let table = [process(7, "/bin/zsh"), process(7, "/usr/bin/login", uid: 0), process(8, "/Users/u/.local/bin/claude"),
                     process(7, "/Users/u/.local/share/claude/versions/2.1.280", uid: uid + 1)]
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: table), .vacant,
                       "A shell in a reused tab, or another user's runtime, is not this session")
        XCTAssertEqual(TerminalLocation.occupancy(device: 8, provider: .claude, processes: table), .provider)
        XCTAssertEqual(TerminalLocation.occupancy(device: 8, provider: .codex, processes: table), .vacant)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: table + [process(7, "/opt/homebrew/bin/node")]),
                       .interpreter, "An npm-installed CLI runs as node; do not call it gone")
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .codex, processes: table + [process(7, "/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex")]),
                       .provider)
        XCTAssertEqual(TerminalLocation.occupancy(of: "/dev/ttys9999", provider: .claude), .vacant,
                       "A device that does not exist runs nothing")
        XCTAssertEqual(TerminalLocation.occupancy(of: "/dev/console\n", provider: .claude), .unknown, "Only validated devices are inspected")
    }

    /// An npm-installed Claude on the device: the native package binary and the older
    /// node-run package script are this provider; another node program stays an interpreter.
    func testNpmInstalledClaudeOccupiesItsDevice() {
        let uid = getuid()
        let shell = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/bin/zsh", pid: 30)
        let native = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", pid: 31)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, native]), .provider,
                       "Before, a catalog row without a hook runtime was reported as ended")
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .codex, processes: [shell, native]), .vacant)
        let node = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/opt/homebrew/bin/node", pid: 32)
        let claude = ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, node], arguments: { $0 == 32 ? claude : nil }), .provider)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, node], arguments: { _ in ["node", "/Users/u/app/server.js"] }),
                       .interpreter, "Another script keeps the old interpreter state")
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .codex, processes: [shell, node], arguments: { _ in claude }), .interpreter)
    }

    /// R2-06: a live session whose CLI binary was replaced by an update (path no
    /// longer readable) or runs under a name the rule does not know must not be
    /// reported as gone. The hook's recorded runtime PID identifies it directly.
    func testUnreadableOrRenamedRuntimesAreNotCalledGone() {
        let uid = getuid()
        let shell = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/bin/zsh", pid: 30)
        let hidden = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: nil, pid: 40)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, hidden]), .unknown,
                       "A process of this user whose path cannot be read may be the session")
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell]), .vacant)
        let renamed = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/opt/tools/claude-code-wrapper", pid: 41)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, renamed], runtimePID: 41), .provider,
                       "The recorded runtime runs there, whatever its name")
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, renamed], runtimePID: 99), .vacant)
        let foreign = TerminalLocation.DeviceProcess(uid: uid + 1, device: 7, executable: nil, pid: 42)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, foreign], runtimePID: 42), .vacant,
                       "Another user's process never counts")
        let release = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/Users/u/bin/codex-aarch64-apple-darwin", pid: 43)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .codex, processes: [shell, release]), .provider,
                       "The Codex release binary keeps its download name")
    }

    /// R2-N-01: macOS gives a closed tab's device to the next tab, and that tab may
    /// run another Claude session. The runtime recorded by this session's hook
    /// identifies its tab: when it is known and no longer on the device, whatever
    /// else runs there (another Claude, node, a hidden process) is another task.
    func testAnotherSessionOnAReusedDeviceIsNotThisSession() {
        let uid = getuid()
        let shell = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/bin/zsh", pid: 30)
        let other = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/Users/u/.local/share/claude/versions/2.1.280", pid: 200)
        let node = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/opt/homebrew/bin/node", pid: 210)
        let hidden = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: nil, pid: 220)
        for extra in [other, node, hidden] {
            XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, extra], runtimePID: 100), .vacant,
                           "\(extra.executable ?? "hidden"): the recorded runtime 100 left this device")
        }
        let own = TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/Users/u/.local/share/claude/versions/2.1.280", pid: 100)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, other, own], runtimePID: 100), .provider,
                       "Its own runtime still runs there")
        let elsewhere = TerminalLocation.DeviceProcess(uid: uid, device: 8, executable: own.executable, pid: 100)
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, other, elsewhere], runtimePID: 100), .vacant,
                       "The session now runs on another device; the recorded one hosts another task")
        XCTAssertEqual(TerminalLocation.occupancy(device: 7, provider: .claude, processes: [shell, other], runtimePID: nil), .provider,
                       "Without a recorded runtime (Codex, older records) the provider rule is unchanged")
    }

    /// R2-N-01 through the focus policy: no consent prompt and no Apple event for a
    /// tab that another session received, and the row reports that its client ended.
    func testRecordedRuntimeGoneFromItsDeviceIsNeverFocused() async throws {
        let uid = getuid()
        let table = [TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/bin/zsh", pid: 30),
                     TerminalLocation.DeviceProcess(uid: uid, device: 7, executable: "/Users/u/.local/bin/claude", pid: 200)]
        for app in ["Terminal", "iTerm2", ""] {
            let recorder = Recorder()
            var row = session(app: app); row.runtimePID = 100; row.phase = .interrupted
            let environment = TerminalFocusEnvironment(
                isRunning: { _ in true },
                occupancy: { _, provider, pid in TerminalLocation.occupancy(device: 7, provider: provider, processes: table, runtimePID: pid) },
                permission: { bundle, ask in recorder.permission(bundle, ask); return 0 },
                runScript: { tty, app, timeout in recorder.script(tty, app, timeout); return true },
                runningTarget: { _, _ in XCTFail("A recorded device must not search processes"); return nil },
                uptime: { recorder.clock })
            do {
                _ = try await TerminalLocation.focusSession(row, environment: environment)
                XCTFail("\(app): the tab of another session was focused")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .terminalProcessEnded, app) }
            XCTAssertTrue(recorder.scripts.isEmpty, "\(app): no Apple event")
            XCTAssertTrue(recorder.permissions.isEmpty, "\(app): no consent prompt")
        }
    }

    func testFocusPassesTheRecordedRuntimeToTheOccupancyCheck() async throws {
        let recorder = Recorder(), seen = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        var row = session(); row.runtimePID = 4242
        let environment = TerminalFocusEnvironment(
            isRunning: { _ in true },
            occupancy: { _, _, pid in seen.withLock { $0 = pid }; return .provider },
            permission: { _, _ in 0 },
            runScript: { tty, app, timeout in recorder.script(tty, app, timeout); return true },
            runningTarget: { _, _ in nil }, uptime: { recorder.clock })
        _ = try await TerminalLocation.focusSession(row, environment: environment)
        XCTAssertEqual(seen.withLock { $0 }, 4242)
    }

    /// The live libproc path with a real pseudo-terminal that runs no provider,
    /// then one that does. Uses /usr/bin/script, not a compiler.
    func testRealDeviceOccupancyFollowsTheProcessOnThePseudoTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = root.appendingPathComponent("claude")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: provider.path)
        // A copied platform binary must be re-signed (ad hoc) before macOS runs it.
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", provider.path]
        sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("codesign could not prepare the provider-named fixture") }
        for (executable, expected) in [("/bin/sleep", TerminalLocation.DeviceOccupancy.vacant), (provider.path, .provider)] {
            let host = Process()
            host.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            host.arguments = ["-q", "/dev/null", executable, "30"]
            host.standardInput = Pipe(); host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
            try host.run()
            defer { host.terminate(); host.waitUntilExit() }
            var tty: String?, child: Int32 = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while tty == nil && ProcessInfo.processInfo.systemUptime < deadline {
                var pids = [pid_t](repeating: 0, count: 64)
                let found = proc_listchildpids(host.processIdentifier, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
                for pid in pids.prefix(max(0, Int(found))) where pid > 0 {
                    if let device = SessionProcess.terminalProcess(pid)?.tty { tty = device; child = pid }
                }
                if tty == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            let device = try XCTUnwrap(tty, "script(1) must give its child a pseudo-terminal")
            XCTAssertEqual(TerminalLocation.occupancy(of: device, provider: .claude), expected, executable)
            if expected == .provider {
                // R2-N-01 with the live process table: the recorded runtime decides.
                XCTAssertEqual(TerminalLocation.occupancy(of: device, provider: .claude, runtimePID: child), .provider, "Its own runtime")
                XCTAssertEqual(TerminalLocation.occupancy(of: device, provider: .claude, runtimePID: getpid()), .vacant,
                               "Another Claude on the device is not the session whose runtime was recorded")
            }
        }
    }
}
