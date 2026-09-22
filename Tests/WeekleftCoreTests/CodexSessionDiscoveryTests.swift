import XCTest
@testable import WeekleftCore

final class CodexSessionDiscoveryTests: XCTestCase {
    func testSegmentedFilenamesDiscoverTheThreadOnceRatherThanTheSegmentID() throws {
        let home = try directory(), id = UUID().uuidString.lowercased()
        let original = try rollout(home: home, id: id)
        for _ in 0..<2 {
            let segment = original.deletingPathExtension().path + "_" + UUID().uuidString.lowercased() + ".jsonl"
            try Data().write(to: URL(fileURLWithPath: segment))
        }
        try FileManager.default.removeItem(at: original)
        let result = try CodexSessionDiscovery.recentIDs(home: home, deadline: 12, uptime: { 0 })
        XCTAssertEqual(result.ids, [id])
        XCTAssertTrue(result.isComplete)
    }
    func testEmptyPreviewPeerTasksAreDiscoveredThroughOfficialReadsWithoutInventingActivity() throws {
        let home = try directory(), ids = (0..<5).map { _ in UUID().uuidString.lowercased() }
        var files: [String: URL] = [:]
        for id in ids { files[id] = try rollout(home: home, id: id) }
        let discovery = try CodexSessionDiscovery.recentIDs(home: home, deadline: 12, uptime: { 0 })
        XCTAssertEqual(Set(discovery.ids), Set(ids))
        XCTAssertTrue(discovery.isComplete)
        var readIDs: [String] = []
        let result = try SessionProcess.readCodexCatalog(discovery: discovery, deadline: 12, uptime: { 0 }) { method, params, _ in
            if method == "thread/list" {
                XCTAssertEqual(
                    params["sourceKinds"] as? [String],
                    [
                        "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact",
                        "subAgentThreadSpawn", "subAgentOther", "unknown",
                    ])
                XCTAssertEqual(params["modelProviders"] as? [String], [])
                XCTAssertEqual(params["useStateDbOnly"] as? Bool, true)
                // The upstream history list omits the four empty-preview peers.
                return ["data": [self.row(ids[0], preview: "Root")], "nextCursor": NSNull()]
            }
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(params["includeTurns"] as? Bool, false)
            let id = try XCTUnwrap(params["threadId"] as? String)
            readIDs.append(id)
            var row = self.row(id)
            row["path"] = files[id]?.path
            return ["thread": row]
        }
        XCTAssertEqual(Set(readIDs), Set(ids.dropFirst()))
        XCTAssertEqual(Set(result.sessions.map(\.sessionID)), Set(ids))
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.isDiscoveryComplete)
        XCTAssertTrue(result.sessions.allSatisfy { $0.phase == .unknown && $0.effectivePhase() == .unknown && $0.runtimeConfirmed == false })
        for file in files.values { XCTAssertEqual(try Data(contentsOf: file), Data([0xFF, 0x00, 0xFE])) }
    }

    func testUnknownCandidateFailuresDoNotBecomeKnownPriorityIssues() throws {
        let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }
        let result = try SessionProcess.readCodexCatalog(discovery: .init(ids: ids, isComplete: true), deadline: 12, uptime: { 0 }) { method, _, _ in
            if method == "thread/list" { return ["data": [], "nextCursor": NSNull()] }
            throw ClientIntegrationIssue(provider: .codex, capability: .sessionCatalog, reason: .sourceUnavailable)
        }
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.unresolvedPrioritySessionIDs.isEmpty)
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.incompleteReason)
        XCTAssertTrue(result.discoveryLimited)
        XCTAssertFalse(result.isDiscoveryComplete)
    }

    func testMalformedDiscoveryRepliesLimitSupplementWithoutCreatingMainCatalogError() throws {
        let id = UUID().uuidString.lowercased()
        for reply: [String: Any] in [[:], ["thread": ["id": UUID().uuidString.lowercased()]], ["thread": "unsupported"],
                                    ["thread": ["id": id, "status": "unsupported"]]] {
            let result = try SessionProcess.readCodexCatalog(discovery: .init(ids: [id], isComplete: true), deadline: 12, uptime: { 0 }) { method, _, _ in
                method == "thread/list" ? ["data": [], "nextCursor": NSNull()] : reply
            }
            XCTAssertTrue(result.sessions.isEmpty)
            XCTAssertTrue(result.isComplete)
            XCTAssertNil(result.incompleteReason)
            XCTAssertTrue(result.discoveryLimited)
            XCTAssertFalse(result.isDiscoveryComplete)
        }
    }

    func testSupplementLimitsAreSeparateFromMainCatalogCompleteness() throws {
        let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }
        var reads = 0
        let result = try SessionProcess.readCodexCatalog(discovery: .init(ids: ids, isComplete: false), maxDiscoveryReads: 1, deadline: 12, uptime: { 0 }) { method, params, _ in
            if method == "thread/list" { return ["data": [], "nextCursor": NSNull()] }
            reads += 1
            return ["thread": self.row(try XCTUnwrap(params["threadId"] as? String))]
        }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.incompleteReason)
        XCTAssertTrue(result.discoveryLimited)
        XCTAssertFalse(result.isDiscoveryComplete)
        XCTAssertTrue(result.unresolvedPrioritySessionIDs.isEmpty)
    }

    func testExpiredSupplementDoesNotLaunchAReadOrCreateMainCatalogError() throws {
        var clock: TimeInterval = 0, calls = 0
        let result = try SessionProcess.readCodexCatalog(discovery: .init(ids: [UUID().uuidString], isComplete: true), deadline: 12, uptime: { clock }) { method, _, _ in
            calls += 1
            XCTAssertEqual(method, "thread/list")
            clock = 13
            return ["data": [], "nextCursor": NSNull()]
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.discoveryLimited)
    }

    func testKnownPriorityAndListedRowsAreNotReadAgainAsDiscoveryCandidates() throws {
        let id = UUID().uuidString.lowercased()
        var reads = 0
        let result = try SessionProcess.readCodexCatalog(prioritySessionIDs: [id], discovery: .init(ids: [id, id], isComplete: true), deadline: 12, uptime: { 0 }) { method, _, _ in
            if method == "thread/read" { reads += 1; return ["thread": self.row(id)] }
            return ["data": [self.row(id)], "nextCursor": NSNull()]
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.sessions.map(\.sessionID), [id])
        XCTAssertTrue(result.isComplete)
    }

    func testFilenameAndContainmentGuardsRejectSymlinksAndMalformedEntries() throws {
        let home = try directory(), outside = try directory()
        let valid = UUID().uuidString.lowercased()
        _ = try rollout(home: home, id: valid)
        let outsideFile = try rollout(home: outside, id: UUID().uuidString.lowercased())
        let day = home.appendingPathComponent("sessions/2026/09/12")
        let linkedID = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: day.appendingPathComponent("rollout-2026-09-12T12-00-00-\(linkedID).jsonl"), withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("sessions/2027"), withDestinationURL: outside.appendingPathComponent("sessions/2026"))
        for name in ["rollout-2026-09-12T12-00-00-invalid.jsonl", "rollout-2026-09-13T12-00-00-\(linkedID).jsonl",
                     "rollout-2026-09-12T99-00-00-\(linkedID).jsonl", "rollout-2026-09-12T12-00-00-\(linkedID).jsonl.backup"] {
            try Data().write(to: day.appendingPathComponent(name))
        }
        _ = try rollout(home: home, id: linkedID, date: "2026/02/31")
        let result = try CodexSessionDiscovery.recentIDs(home: home, deadline: 12, uptime: { 0 })
        XCTAssertEqual(result.ids, [valid])
        let linkedHome = try directory()
        try FileManager.default.createSymbolicLink(at: linkedHome.appendingPathComponent("sessions"), withDestinationURL: outside.appendingPathComponent("sessions"))
        let linked = try CodexSessionDiscovery.recentIDs(home: linkedHome, deadline: 12, uptime: { 0 })
        XCTAssertTrue(linked.ids.isEmpty)
        XCTAssertFalse(linked.isComplete)
    }

    func testDirectoryEntryCandidateAndTimeBudgetsAreExplicit() throws {
        let home = try directory()
        let old = UUID().uuidString.lowercased(), recent = UUID().uuidString.lowercased()
        let first = try rollout(home: home, id: old), second = try rollout(home: home, id: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: second.path)
        let limited = try CodexSessionDiscovery.recentIDs(home: home, maximumCandidates: 1, deadline: 12, uptime: { 0 })
        XCTAssertEqual(limited.ids, [recent])
        XCTAssertFalse(limited.isComplete)
        for result in [try CodexSessionDiscovery.recentIDs(home: home, maximumEntries: 0, deadline: 12, uptime: { 0 }),
                       try CodexSessionDiscovery.recentIDs(home: home, deadline: 0, uptime: { 0 })] {
            XCTAssertTrue(result.ids.isEmpty)
            XCTAssertFalse(result.isComplete)
        }
    }

    func testCancellationStopsDiscoveryAndHydration() async throws {
        let home = try directory()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CodexSessionDiscovery.recentIDs(home: home)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try SessionProcess.readCodexCatalog(discovery: .init(ids: [UUID().uuidString], isComplete: true), deadline: 12, uptime: { 0 }) { method, _, _ in
            if method == "thread/list" { return ["data": [], "nextCursor": NSNull()] }
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    private func row(_ id: String, preview: String = "") -> [String: Any] {
        ["id": id, "name": "Fixture", "preview": preview, "status": ["type": "notLoaded"], "source": "vscode"]
    }
    private func rollout(home: URL, id: String, date: String = "2026/09/12") throws -> URL {
        let day = home.appendingPathComponent("sessions/" + date)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-\(date.replacingOccurrences(of: "/", with: "-"))T12-00-00-\(id).jsonl")
        // Invalid UTF-8/body: discovery can succeed only from filename metadata.
        try Data([0xFF, 0x00, 0xFE]).write(to: file)
        return file
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
