import XCTest
import WeekleftCore
@testable import Weekleft

final class SessionNavigationIntegrationTests: XCTestCase {
    @MainActor func testExplicitLocalSessionOpen() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_OPEN_SESSION_FIXTURE"] else {
            throw XCTSkip("Explicit opt-in required: opens an existing session in its real app")
        }
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await SessionNavigation.open(session)
    }
}
