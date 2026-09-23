import XCTest
import WeekleftCore
@testable import Weekleft

final class SessionNavigationIntegrationTests: XCTestCase {
    @MainActor func testSelectedUnavailableClientFailsBeforeAnySystemNavigation() async throws {
        let session = AgentSession(provider: .codex, sessionID: "01234567-89ab-cdef-0123-456789abcdef",
                                   title: "Fixture", cwd: "/missing/fixture/project", client: .terminal,
                                   phase: .unknown, updatedAt: .distantPast, observedAt: .distantPast)
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
