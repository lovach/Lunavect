import XCTest
import SQLite3
@testable import WeekleftCore

/// Pollers reuse decoded local files; every change must still be observed.
final class LocalFileCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFileCache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Replace atomically, as the hook helper and Claude Desktop do, then age the file.
    private func write(_ data: Data, to url: URL, age: TimeInterval = 60) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func testSettledFileDecodesOnceUntilReplaced() throws {
        let file = root.appendingPathComponent("value.txt")
        let cache = LocalFileCache<String>()
        var decodes = 0
        func read() throws -> String? {
            let identity = try XCTUnwrap(LocalFileIdentity(path: file.path))
            return cache.value(for: file.path, identity: identity) {
                decodes += 1
                return try? String(contentsOf: file, encoding: .utf8)
            }
        }
        try write(Data("first".utf8), to: file)
        XCTAssertEqual(try read(), "first")
        XCTAssertEqual(try read(), "first")
        XCTAssertEqual(decodes, 1)
        try write(Data("other".utf8), to: file)
        XCTAssertEqual(try read(), "other", "An equal-size replacement has a new identity")
        XCTAssertEqual(decodes, 2)
        cache.retain([])
        XCTAssertEqual(try read(), "other")
        XCTAssertEqual(decodes, 3, "A forgotten file is decoded again")
    }

    func testRecentlyModifiedFileIsNeverReused() throws {
        let file = root.appendingPathComponent("recent.txt")
        try Data("value".utf8).write(to: file)
        let cache = LocalFileCache<String>()
        var decodes = 0
        for _ in 0..<3 {
            let identity = try XCTUnwrap(LocalFileIdentity(path: file.path))
            _ = cache.value(for: file.path, identity: identity) { decodes += 1; return "value" }
        }
        XCTAssertEqual(decodes, 3)
        XCTAssertNil(LocalFileIdentity(path: root.appendingPathComponent("missing").path))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(LocalFileIdentity(path: link.path), "Links are not followed")
    }

    func testHookRecordsFollowNewEventsAndRemovedFiles() throws {
        func event(_ name: String) -> Data {
            Data(#"{"session_id":"cache-session","hook_event_name":"\#(name)","cwd":"/tmp/project"}"#.utf8)
        }
        try SessionHooks.capture(event("UserPromptSubmit"), provider: .claude, at: root)
        let file = root.appendingPathComponent("claude-cache-session.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        XCTAssertEqual(SessionHooks.load(at: root).map(\.phase), [.running])
        XCTAssertEqual(SessionHooks.load(at: root).map(\.phase), [.running])
        try SessionHooks.capture(event("Stop"), provider: .claude, at: root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        XCTAssertEqual(SessionHooks.load(at: root).map(\.phase), [.ready])
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(SessionHooks.load(at: root), [])
    }

    func testDesktopTitleChangeIsReadAfterCaching() throws {
        let workspace = root.appendingPathComponent("account/workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("local_cache-route.json")
        for title in ["First title", "Second title"] {
            try write(JSONSerialization.data(withJSONObject: ["cliSessionId": "cache-id", "title": title]), to: file)
            XCTAssertEqual(ClaudeSessionMetadata.titles(for: ["cache-id"], at: root), ["cache-id": title])
            XCTAssertEqual(ClaudeSessionMetadata.titles(for: ["cache-id"], at: root), ["cache-id": title])
        }
        try write(JSONSerialization.data(withJSONObject: ["cliSessionId": "cache-id", "title": "Second title", "isArchived": true]), to: file)
        XCTAssertEqual(ClaudeSessionMetadata.records(for: ["cache-id"], at: root).count, 0)
    }

    func testThreadRecordedAfterFirstLookupIsClassified() throws {
        let path = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,title TEXT,source TEXT); INSERT INTO threads VALUES ('parent','Parent','vscode');", nil, nil, nil), SQLITE_OK)
        let start = Date()
        XCTAssertEqual(CodexSessionMetadata.subagentIDs(for: ["parent", "late-child"], at: root, now: start), [])
        XCTAssertEqual(sqlite3_exec(db, #"INSERT INTO threads VALUES ('late-child','Child','{"subagent":{"review":{}}}');"#, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(CodexSessionMetadata.subagentIDs(for: ["parent", "late-child"], at: root, now: start.addingTimeInterval(5)), [],
                       "A missing thread is not queried on every poll")
        XCTAssertEqual(CodexSessionMetadata.subagentIDs(for: ["parent", "late-child"], at: root, now: start.addingTimeInterval(31)), ["late-child"])
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM threads;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(CodexSessionMetadata.subagentIDs(for: ["late-child"], at: root, now: start.addingTimeInterval(32)), ["late-child"],
                       "A recorded origin is immutable and served without the database")
    }
}
