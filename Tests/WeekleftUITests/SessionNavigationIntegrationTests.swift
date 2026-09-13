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
            try await SessionNavigation.open(session, resolver: resolver)
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
                do {
                    try await SessionNavigation.open(row, resolver: resolver)
                    XCTFail("Must not launch a second client")
                } catch { XCTAssertEqual(error as? SessionOpeningError, .sessionMayBeOpen) }
            }
        }
    }
    @MainActor func testExplicitLocalSessionOpen() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_OPEN_SESSION_FIXTURE"] else {
            throw XCTSkip("Explicit opt-in required: opens an existing session in its real app")
        }
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await SessionNavigation.open(session)
    }
}
