import Foundation
import SQLite3

/// Read only names and source classification for known IDs outside the recent catalog.
/// No messages, credentials, schema writes or provider archive changes.
public enum CodexSessionMetadata {
    public static func titles(for ids: Set<String>, at home: URL? = nil) -> [String: String] {
        values(for: ids, at: home, queries: [
            "SELECT COALESCE(NULLIF(TRIM(name), ''), title) FROM threads WHERE id = ? LIMIT 1",
            "SELECT title FROM threads WHERE id = ? LIMIT 1"
        ]).mapValues { SessionParser.codexTitle($0) }.filter { !$0.value.isEmpty }
    }
    public static func subagentIDs(for ids: Set<String>, at home: URL? = nil) -> Set<String> {
        let sources = values(for: ids, at: home, queries: ["SELECT source FROM threads WHERE id = ? LIMIT 1"])
        return Set(sources.compactMap { id, source in
            guard let decoded = try? JSONSerialization.jsonObject(with: Data(source.utf8)),
                  SessionParser.codexSubagent(source: decoded) else { return nil }
            return id
        })
    }
    public static func markingSubagents(in rows: [AgentSession], at home: URL? = nil) -> [AgentSession] {
        let ids = Set(rows.filter { $0.provider == .codex }.map(\.sessionID))
        let children = subagentIDs(for: ids, at: home)
        return rows.map { row in
            var row = row
            if row.provider == .codex, children.contains(row.sessionID) { row.isCodexSubagent = true }
            return row
        }
    }
    private static func values(for ids: Set<String>, at home: URL?, queries: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let base = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        let databases = files.filter { $0.lastPathComponent.range(of: #"^state_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for file in databases {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            var query: OpaquePointer?
            // Desktop stores its sidebar name separately; title can be the entire
            // initial prompt (including an attachment envelope). Older schemas
            // have only title, so retain the read-only compatibility query.
            for sql in queries {
                if sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK { break }
                if let query { sqlite3_finalize(query) }
                query = nil
            }
            guard query != nil else { continue }
            defer { sqlite3_finalize(query) }
            var result: [String: String] = [:]
            for id in ids where SessionParser.validID(id) {
                sqlite3_reset(query); sqlite3_clear_bindings(query)
                id.withCString { pointer in
                    _ = sqlite3_bind_text(query, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                if sqlite3_step(query) == SQLITE_ROW, let raw = sqlite3_column_text(query, 0) {
                    result[id] = String(cString: raw)
                }
            }
            return result
        }
        return [:]
    }
}
