import XCTest
@testable import WeekleftCore

/// S-11: `claude agents --json` is not a documented contract. A changed shape
/// must surface as a connection diagnostic instead of an empty session list.
/// Live 2.1.280 rows carry {id, cwd, kind, name, sessionId, startedAt, state}
/// (background) and {pid, cwd, kind, name, sessionId, startedAt, status}
/// (interactive); `waitingFor` and `updatedAt` are not emitted.
final class ClaudeCatalogContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let live: [[String: Any]] = [
        ["id": "bg-short-1", "cwd": "/Users/fixture/Projects/lunavect", "kind": "background", "name": "Nightly audit",
         "sessionId": "9e4f2b10-2c3d-4e5f-8a9b-0c1d2e3f4a5b", "startedAt": 1_795_000_200_000, "state": "blocked"],
        ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive", "name": "Fix widgets",
         "sessionId": "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01", "startedAt": 1_795_000_100_000, "status": "busy"],
    ]
    private func parse(_ rows: Any, isInternal: @escaping (String, Int32?) -> Bool = { _, _ in false }) throws -> [AgentSession] {
        try SessionParser.claude(JSONSerialization.data(withJSONObject: rows), now: now, isInternal: isInternal)
    }
    private func assertUnsupported(_ rows: Any, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(rows), message, file: file, line: line) { error in
            XCTAssertEqual((error as? ClientIntegrationIssue)?.code, "claude.sessionCatalog.unsupportedResponse", message, file: file, line: line)
        }
    }

    func testLiveShapeParsesWithoutHypotheticalFields() throws {
        let rows = try parse(live)
        XCTAssertEqual(rows.map(\.title), ["Nightly audit", "Fix widgets"])
        XCTAssertEqual(rows.map(\.phase), [.input, .running])
        XCTAssertEqual(rows[1].updatedAt, Date(timeIntervalSince1970: 1_795_000_100), "startedAt is the only activity time")
    }

    func testRenamedOrNestedRowsAreAnUnsupportedResponseNotAnEmptyList() {
        let renamed = live.map { row -> [String: Any] in
            var row = row
            row["session_id"] = row.removeValue(forKey: "sessionId"); row.removeValue(forKey: "id")
            return row
        }
        assertUnsupported(renamed, "sessionId renamed")
        assertUnsupported(live.map { ["session": $0] }, "rows wrapped in an object")
        assertUnsupported([["sessionId": 42, "kind": "interactive"]], "identifier of another type")
    }

    func testEmptyCatalogAndInternalOnlyCatalogStayValid() throws {
        XCTAssertEqual(try parse([[String: Any]]()).count, 0, "No sessions is a valid answer")
        let probeOnly = [["pid": 4242, "cwd": "/fixture/QuotaProbe", "kind": "interactive", "name": "quotaprobe-00",
                          "sessionId": "0b6c7c52-6a55-4f0e-9d1b-3a1f0c9e2d11", "startedAt": 1_795_000_000_000, "status": "waiting"]]
        XCTAssertEqual(try parse(probeOnly, isInternal: { cwd, _ in cwd == "/fixture/QuotaProbe" }).count, 0,
                       "A catalog holding only Lunavect's probe is understood, not unsupported")
        var partly = live
        partly.append(["unexpected": true])
        XCTAssertEqual(try parse(partly).count, 2, "One unknown row among recognised ones is skipped")
    }
}
