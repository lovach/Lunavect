import AppKit
import XCTest
@testable import WeekleftCore
@testable import Weekleft

final class SessionNavigationIntegrationTests: XCTestCase {
    @MainActor func testExplicitIDEFixtureFromProcessOriginThroughNativeFocus() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_IDE_NAVIGATION_FIXTURE"] else {
            throw XCTSkip("Explicit opt-in required: focuses operator-owned IDE terminal fixtures")
        }
        struct Fixture: Decodable { let terminals: [Int32]; let providers: [ProviderID]?; let cwd: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var lastLocation: IDESessionLocation?
        for (provider, pid) in zip(fixture.providers ?? [.claude, .codex], fixture.terminals) {
            let location = try XCTUnwrap(IDEProcessLocation.locate(parentPID: pid, provider: provider))
            lastLocation = location
            XCTAssertTrue(location.usesTerminal)
            var row = AgentSession(provider: provider, sessionID: UUID().uuidString, title: "Fixture", cwd: fixture.cwd,
                                   client: location.editor.client, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
            row.ideLocation = location
            try await SessionNavigation.open(row)
        }
        if fixture.terminals.count > 2, let lastLocation {
            let process = try XCTUnwrap(IDEProcessLocation.process(fixture.terminals[2]))
            XCTAssertTrue(process.hasTerminal)
            var classic = AgentSession(provider: .claude, sessionID: UUID().uuidString, title: "Classic fixture", cwd: fixture.cwd,
                                       client: lastLocation.editor.client, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
            classic.ideLocation = .init(editor: lastLocation.editor, bundleIdentifier: lastLocation.bundleIdentifier,
                                       appPath: lastLocation.appPath, runtime: process.identity, usesTerminal: true)
            try await SessionNavigation.open(classic)
        }
    }
    @MainActor func testIDEOriginWinsOverStaleTerminalAndNeverFallsBackToDesktop() async throws {
        for provider in ProviderID.allCases {
            for client in [SessionClient.vscode, .jetbrains] {
                var row = AgentSession(provider: provider, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                                       cwd: "/tmp", client: client, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
                row.terminalTTY = "/dev/ttys004"; row.terminalApp = "Terminal"
                var attempts = 0
                let failure = SessionOpeningError.ideBridgeMissing(client.title)
                do {
                    try await SessionNavigation.open(row, focus: { _ in XCTFail("IDE must not run Terminal AppleScript"); return false },
                        openIDE: { selected in attempts += 1; XCTAssertEqual(selected.id, row.id); throw failure })
                    XCTFail("IDE failure must be reported without another route")
                } catch { XCTAssertEqual(error as? SessionOpeningError, failure) }
                XCTAssertEqual(attempts, 1)
            }
        }
    }
    @MainActor func testExplicitDetachedHookAndCatalogOpenRealTerminal() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_TERMINAL_NAVIGATION_FIXTURE"] else {
            throw XCTSkip("Explicit opt-in required: focuses an operator-owned Terminal fixture")
        }
        // `windowID` enables post-focus checks; `otherSpace` (§6.3 N2) additionally requires the
        // window, placed on another Space or in full screen beforehand, to be on screen afterwards.
        struct Fixture: Decodable { let clientPID: Int32; let hookPID: Int32; let tty: String; let windowID: Int?; let otherSpace: Bool? }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let hooked = try XCTUnwrap(SessionProcess.terminalLocation(parentPID: fixture.hookPID, termProgram: "Apple_Terminal"))
        XCTAssertEqual(hooked.tty, fixture.tty)
        let data = try JSONSerialization.data(withJSONObject: [["sessionId": "01234567-89ab-cdef-0123-456789abcdef",
            "pid": fixture.clientPID, "kind": "interactive", "status": "busy"]])
        let row = try XCTUnwrap(SessionParser.claude(data, terminal: { pid in
            SessionProcess.terminalLocation(parentPID: pid, termProgram: "").map { TerminalLocation.Target(tty: $0.tty, app: $0.app) }
        }).first)
        XCTAssertEqual(row.terminalTTY, fixture.tty)
        XCTAssertEqual(row.client, .terminal)
        try await SessionNavigation.open(row)
        if let windowID = fixture.windowID {
            // Unminimizing a macOS window finishes after the Apple event returns.
            try await Task.sleep(for: .seconds(1))
            let script = try XCTUnwrap(NSAppleScript(source: """
            tell application "Terminal"
                return (id of front window is \(windowID)) and (miniaturized of front window is false) and ((count of processes of selected tab of front window) > 0)
            end tell
            """))
            var error: NSDictionary?
            XCTAssertTrue(script.executeAndReturnError(&error).booleanValue, "Must show the live window, not an exited tab that reused its TTY")
            XCTAssertNil(error)
            if fixture.otherSpace == true {
                let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .compactMap { $0[kCGWindowNumber as String] as? Int }
                XCTAssertTrue(visible.contains(windowID), "Activation must switch to the window's Space")
            }
        }
    }

    /// §4 item 1 / §6.3 N5: opt-in live iTerm2 check with an operator-owned session.
    /// JSON: {"clientPID": <pid of a process in that iTerm2 session>, "tty": "/dev/ttysNNN"}.
    /// Minimize its window or move it to another Space first; the test restores and selects it.
    @MainActor func testExplicitITermFixtureSelectsTheSessionAndRestoresItsWindow() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_ITERM_NAVIGATION_FIXTURE"] else {
            throw XCTSkip("Explicit opt-in required: focuses an operator-owned iTerm2 session")
        }
        struct Fixture: Decodable { let clientPID: Int32; let tty: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let location = try XCTUnwrap(SessionProcess.terminalLocation(parentPID: fixture.clientPID, termProgram: "iTerm.app"))
        XCTAssertEqual(location.tty, fixture.tty)
        XCTAssertEqual(location.app, "iTerm2")
        var row = AgentSession(provider: .claude, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture", cwd: "/tmp",
                               client: .terminal, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        row.terminalTTY = location.tty; row.terminalApp = location.app
        let environment = TerminalFocusEnvironment(isRunning: { bundle in
            await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }
        }, occupancy: { _, _ in .unknown }) // the fixture process need not be a provider runtime
        let focused = try await TerminalLocation.focusSession(row, environment: environment)
        XCTAssertTrue(focused)
        try await Task.sleep(for: .seconds(1))
        let script = try XCTUnwrap(NSAppleScript(source: """
        tell application "iTerm2"
            return (tty of current session of current window is "\(fixture.tty)") and (miniaturized of current window is false)
        end tell
        """))
        var error: NSDictionary?
        XCTAssertTrue(script.executeAndReturnError(&error).booleanValue, "The session's own window, tab and pane must be selected")
        XCTAssertNil(error)
    }

    @MainActor func testTerminalFocusFailureReachesThePanelWithoutLaunchingAnotherClient() async throws {
        let row = AgentSession(provider: .claude, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                               cwd: "/tmp", client: .terminal, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        let resolver = ClientExecutableResolver(discoverClaude: { XCTFail("Do not resume an already open session"); return nil })
        for failure in [SessionOpeningError.terminalAutomationDenied("Terminal"), .terminalFocusTimedOut("Terminal"), .terminalTabUnavailable] {
            do {
                try await SessionNavigation.open(row, resolver: resolver, focus: { _ in throw failure })
                XCTFail("Navigation must report the actual focus failure")
            } catch { XCTAssertEqual(error as? SessionOpeningError, failure) }
        }
    }

    @MainActor func testCancelledTerminalFocusDoesNotProceedToResume() async throws {
        let row = AgentSession(provider: .claude, sessionID: UUID().uuidString, title: "Fixture", cwd: "/tmp",
                               client: .terminal, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        let resolver = ClientExecutableResolver(discoverClaude: { XCTFail("Cancelled focus must not resolve or resume a client"); return nil })
        for focused in [false, true] {
            let task = Task {
                try await SessionNavigation.open(row, resolver: resolver, focus: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return focused
                })
            }
            do { try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    @MainActor func testSelectedUnavailableClientFailsBeforeAnySystemNavigation() async throws {
        // A recorded exit is what allows a resume; only then is the client resolved.
        let session = AgentSession(provider: .codex, sessionID: "01234567-89ab-cdef-0123-456789abcdef",
                                   title: "Fixture", cwd: "/missing/fixture/project", client: .terminal,
                                   phase: .finished, updatedAt: .distantPast, observedAt: .distantPast, evidence: .hook)
        let resolver = ClientExecutableResolver(codexPath: "/missing/fixture/selected-codex", discoverCodex: {
            XCTFail("Navigation must honor the selected client")
            return "/bin/echo"
        })
        do {
            try await SessionNavigation.open(session, resolver: resolver, focus: { _ in false })
            XCTFail("Missing selected client must not open a terminal")
        } catch {
            XCTAssertEqual(error as? SessionOpeningError, .unavailableConfiguredCodex)
        }
    }
    /// N-12 / §6.3 N10: a live session whose tab could not be focused reports that
    /// it may still be open, even while its CLI is missing or being replaced
    /// (for example during an update). Only an exited session needs the CLI.
    @MainActor func testLiveSessionWithUnavailableClientStillReportsItMayBeOpen() async throws {
        let missing = ClientExecutableResolver(codexPath: "", discoverCodex: { nil }, discoverClaude: { nil })
        let configured = ClientExecutableResolver(codexPath: "/missing/fixture/selected-codex", discoverCodex: { nil }, discoverClaude: { nil })
        for (provider, resolver) in [(ProviderID.claude, missing), (.codex, missing), (.codex, configured)] {
            let live = AgentSession(provider: provider, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                                    cwd: "/tmp", client: .terminal, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
            do {
                try await SessionNavigation.open(live, resolver: resolver, focus: { _ in false })
                XCTFail("A live session must not be resumed")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .sessionMayBeOpen, provider.rawValue) }
            var ended = live
            ended.phase = .finished
            let expected: SessionOpeningError = resolver.codexPath.isEmpty ? .missingCLI(provider) : .unavailableConfiguredCodex
            do {
                try await SessionNavigation.open(ended, resolver: resolver, focus: { _ in XCTFail("An exited session is not focused"); return false })
                XCTFail("A missing client cannot resume")
            } catch { XCTAssertEqual(error as? SessionOpeningError, expected, provider.rawValue) }
        }
    }
    @MainActor func testLiveTerminalRouteStopsBeforeAnySystemNavigation() async throws {
        let resolver = ClientExecutableResolver(discoverCodex: { "/bin/echo" }, discoverClaude: { "/bin/echo" })
        for provider in ProviderID.allCases {
            for phase in SessionPhase.allCases where phase != .finished {
                let row = AgentSession(
                    provider: provider, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                    cwd: "/tmp", client: .terminal, phase: phase, updatedAt: Date(), observedAt: Date(), evidence: .hook
                )
                var focusAttempts = 0
                do {
                    try await SessionNavigation.open(row, resolver: resolver, focus: { _ in focusAttempts += 1; return false })
                    XCTFail("Must not launch a second client")
                } catch { XCTAssertEqual(error as? SessionOpeningError, .sessionMayBeOpen) }
                XCTAssertEqual(focusAttempts, 1, "A live terminal session is first brought to its own tab")
            }
        }
    }
    @MainActor func testFocusedTerminalTabCompletesNavigationAndDesktopSessionsAreNotFocused() async throws {
        let resolver = ClientExecutableResolver(discoverCodex: { XCTFail("No resume after focus"); return nil },
                                                discoverClaude: { XCTFail("No resume after focus"); return nil })
        let live = AgentSession(provider: .claude, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                                cwd: "/tmp", client: .terminal, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        try await SessionNavigation.open(live, resolver: resolver, focus: { _ in true })
        var desktop = live
        desktop.provider = .codex; desktop.client = .desktop
        XCTAssertFalse(desktop.terminalFocusCandidate, "A Desktop task is not matched to a CLI in its folder")
        desktop.terminalTTY = "/dev/ttys004"; desktop.terminalApp = "iTerm2"
        XCTAssertTrue(desktop.terminalFocusCandidate, "A device recorded by a hook is terminal evidence")
        var ended = live
        ended.phase = .finished
        XCTAssertFalse(ended.terminalFocusCandidate, "An exited CLI is resumed, not focused")
    }
    @MainActor func testExplicitLocalSessionOpen() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_OPEN_SESSION_FIXTURE"] else {
            throw XCTSkip("Explicit opt-in required: opens an existing session in its real app")
        }
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await SessionNavigation.open(session)
    }
}
