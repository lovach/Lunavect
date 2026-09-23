import XCTest
import SQLite3
@testable import WeekleftCore

final class HiddenSessionManagementTests: XCTestCase {
    func testSubagentMetadataClassifiesOrphanHooksWithoutChangingSourceDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, #"CREATE TABLE threads(id TEXT,title TEXT,source TEXT); INSERT INTO threads VALUES ('child','Child','{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}'),('parent','Parent','vscode'),('peer','subagent review','appServer');"#, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: path)
        XCTAssertEqual(CodexSessionMetadata.subagentIDs(for: ["child", "parent", "peer", "missing", "';DROP TABLE threads;--"], at: dir), ["child"])
        XCTAssertEqual(CodexSessionMetadata.titles(for: ["child", "parent", "peer"], at: dir),
                       ["child": "Child", "parent": "Parent", "peer": "subagent review"])
        let now = Date()
        let rows = ["child", "parent", "peer"].map {
            AgentSession(provider: .codex, sessionID: $0, title: "", cwd: "", phase: .input,
                         updatedAt: now, observedAt: now, evidence: .hook)
        }
        let marked = CodexSessionMetadata.markingSubagents(in: rows, at: dir)
        XCTAssertEqual(Set(SessionList.merge(catalog: [], events: marked, now: now).filter { $0.isCurrent(now: now) }.map(\.sessionID)), ["parent", "peer"])
        XCTAssertEqual(try Data(contentsOf: path), before)
        let encoded = try JSONEncoder().encode(marked[0])
        XCTAssertTrue(try XCTUnwrap(JSONDecoder().decode(AgentSession.self, from: encoded).isCodexSubagent))
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldJSON.removeValue(forKey: "isCodexSubagent")
        XCTAssertNil(try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: oldJSON)).isCodexSubagent)
    }

    func testCodexMemoryAgentIsInternalOnlyInsideCodexHomeMemories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let memories = home.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memories.appendingPathComponent("rollout_summaries"), withIntermediateDirectories: true)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: link) }
        let now = Date()
        func row(_ id: String, _ cwd: String, _ provider: ProviderID = .codex) -> AgentSession {
            AgentSession(provider: provider, sessionID: id, title: "", cwd: cwd, phase: .input, updatedAt: now, observedAt: now, evidence: .hook)
        }
        let rows = [row("memory", memories.path), row("summaries", memories.appendingPathComponent("rollout_summaries").path + "/"),
                    row("home", home.path), row("project", "/Users/demo/Developer/memories"),
                    row("sibling", home.appendingPathComponent("memories-archive").path), row("claude", memories.path, .claude)]
        let marked = CodexSessionMetadata.markingSubagents(in: rows, at: home)
        XCTAssertEqual(Set(marked.filter { $0.isCodexSubagent == true }.map(\.sessionID)), ["memory", "summaries"])
        XCTAssertEqual(Set(SessionList.merge(catalog: [], events: marked, now: now).filter { $0.provider == .codex && $0.isCurrent(now: now) }.map(\.sessionID)),
                       ["home", "project", "sibling"], "Only the memory agent leaves the panel; other folders stay user sessions")
        XCTAssertEqual(CodexSessionMetadata.markingSubagents(in: [row("resolved", memories.resolvingSymlinksInPath().path)], at: link).first?.isCodexSubagent, true,
                       "A symlinked CODEX_HOME still recognizes the agent's real working directory")
    }

    func testDesktopNameWinsOverRawAttachmentPromptAndRepairsSavedHiddenTitle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE threads(id TEXT,title TEXT,name TEXT); INSERT INTO threads VALUES ('named','# Files mentioned by the user: attachment metadata','Разобраться с лишними сессиями'),('fallback','# Files mentioned by the user:\n\n## image.png: /private/example.png\n\n## My request:\nИсправь историю',NULL),('empty','Old title','   ');",
                nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: path)
        let titles = CodexSessionMetadata.titles(for: ["named", "fallback", "empty"], at: dir)
        XCTAssertEqual(titles["named"], "Разобраться с лишними сессиями")
        XCTAssertEqual(titles["fallback"], "Исправь историю")
        XCTAssertEqual(titles["empty"], "Old title")
        XCTAssertEqual(try Data(contentsOf: path), before)
        let url = dir.appendingPathComponent("hidden.json")
        var visibility = try SessionVisibility(url: url)
        let row = AgentSession(provider: .codex, sessionID: "named", title: "# Files mentioned by the user: truncated", cwd: "/example", phase: .ready, updatedAt: Date(), observedAt: Date())
        try visibility.hide(row)
        XCTAssertEqual(try SessionVisibility(url: url).summaries.first?.title, "",
                       "A cached truncated envelope must stay out of the UI before metadata refresh")
        try visibility.updateTitles(Dictionary(uniqueKeysWithValues: titles.map { ("codex:" + $0.key, $0.value) }))
        XCTAssertEqual(try SessionVisibility(url: url).summaries.first?.title, "Разобраться с лишними сессиями")
        XCTAssertEqual(visibility.hidden, [row.id], "Repair the title without deleting a real task")
    }

    func testAttachmentTitleUsesRequestBeforeTruncationAndNeverDisplaysFileEnvelope() throws {
        let envelope = "# Files mentioned by the user:\n\n## " + String(repeating: "attachment", count: 100) + "\n\n## My request:\nПочини название\nи историю"
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            ["id": "request", "name": envelope],
            ["id": "truncated", "name": "# Files mentioned by the user: ## image.png /private/path"],
            ["id": "normal", "name": "Обычное название"]
        ]])
        let rows = try SessionParser.codex(data)
        XCTAssertEqual(rows[0].title, "Почини название и историю")
        XCTAssertEqual(rows[1].title, "")
        XCTAssertEqual(rows[1].displayTitle, L("Сессия Codex"))
        XCTAssertEqual(rows[2].title, "Обычное название")
    }
    func testRemovalClearsListWithoutReimportingOldSessionButNewTaskReturns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hidden.json"), t = Date()
        var session = AgentSession(provider: .codex, sessionID: "removed", title: "Настоящее название", cwd: "/tmp/project", phase: .ready, updatedAt: t, observedAt: t, evidence: .hook)
        session.turnStartedAt = t.addingTimeInterval(-60)
        var visibility = try SessionVisibility(url: url)
        try visibility.hide(session, now: t)
        XCTAssertEqual(visibility.summaries.first?.title, session.title)
        try visibility.removeHidden([session.id])
        visibility = try SessionVisibility(url: url)
        XCTAssertTrue(visibility.hidden.isEmpty)
        XCTAssertTrue(visibility.summaries.isEmpty)
        XCTAssertTrue(visibility.visible([session]).isEmpty)
        XCTAssertTrue(try visibility.restoreNewTasks([session], now: t).isEmpty)
        session.phase = .running; session.observedAt = t.addingTimeInterval(20); session.updatedAt = session.observedAt
        session.turnStartedAt = session.observedAt
        XCTAssertEqual(try visibility.restoreNewTasks([session], now: session.observedAt), [session.id])
        XCTAssertEqual(visibility.visible([session]).first?.id, session.id)
    }
    func testCachedRealTitleSurvivesCatalogDisappearanceAndRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hidden.json")
        var visibility = try SessionVisibility(url: url)
        try visibility.setHidden("codex:old", true)
        try visibility.updateTitles(["codex:old": "Точное название из источника", "codex:other": "Other"])
        let relaunched = try SessionVisibility(url: url)
        XCTAssertEqual(relaunched.summaries.count, 1)
        XCTAssertEqual(relaunched.summaries.first?.title, "Точное название из источника")
    }
    func testReadOnlyMetadataFindsOnlyRequestedIDsIncludingOldTitles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,title TEXT); INSERT INTO threads VALUES ('old','Vieux projet 中文'),('other','Other');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: path)
        XCTAssertEqual(CodexSessionMetadata.titles(for: ["old", "missing", "';DROP TABLE threads;--"], at: dir), ["old": "Vieux projet 中文"])
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(CodexSessionMetadata.titles(for: ["other"], at: dir), ["other": "Other"])
    }
}
