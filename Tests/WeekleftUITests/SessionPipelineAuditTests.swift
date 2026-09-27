import XCTest
import Combine
@testable import Weekleft
@testable import WeekleftCore

/// Store-level regressions from the 2026-09-28 session audit (reports/02-sessions.md).
/// Every store is isolated: injected clock, temporary folder, fixture catalogs.
@MainActor final class SessionPipelineAuditTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionPipelineAudit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store(_ dependencies: SessionStore.Dependencies = .init(), directory: URL? = nil, now: @escaping () -> Date) throws -> SessionStore {
        let suite = "SessionPipelineAudit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SessionStore(directory: try directory ?? self.directory(), defaults: defaults, isolated: true, now: now, dependencies: dependencies)
    }
    private func claudeRows(_ rows: [[String: Any]], at date: Date) throws -> [AgentSession] {
        try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: date)
    }

    // S-11
    func testChangedCatalogShapeIsReportedAndKeepsTheLastRows() async throws {
        var clock = instant, renamed = false
        let row: [String: Any] = ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "name": "Fix widgets",
                                  "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "startedAt": 1_795_000_100_000, "status": "busy"]
        let sessions = try store(.init(catalog: { _, _, _, _ in
            var shaped = row
            if renamed { shaped["session_id"] = shaped.removeValue(forKey: "sessionId") }
            return (try self.claudeRows([shaped], at: clock), false)
        }), now: { clock })
        defer { sessions.stop() }
        sessions.useProviders([.claude])
        await sessions.refresh()
        XCTAssertEqual(sessions.currentSessions.map(\.title), ["Fix widgets"])
        clock += 15; renamed = true
        await sessions.refresh()
        XCTAssertEqual(sessions.typedIssues[.claude]?.code, "claude.sessionCatalog.unsupportedResponse")
        XCTAssertEqual(sessions.diagnosticEntries.last?.issue.code, "claude.sessionCatalog.unsupportedResponse")
        XCTAssertEqual(sessions.currentSessions.map(\.title), ["Fix widgets"], "The last listing remains until it expires")
    }
}
