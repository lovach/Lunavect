import Foundation
import SQLite3

/// Read only names for known IDs, including sessions outside the recent catalog.
/// No messages, credentials, schema writes or provider archive changes.
public enum CodexSessionMetadata {
    public static func titles(for ids: Set<String>, at home: URL? = nil) -> [String: String] {
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
            let namedQuery = "SELECT COALESCE(NULLIF(TRIM(name), ''), title) FROM threads WHERE id = ? LIMIT 1"
            if sqlite3_prepare_v2(db, namedQuery, -1, &query, nil) != SQLITE_OK {
                if let query { sqlite3_finalize(query) }
                query = nil
                guard sqlite3_prepare_v2(db, "SELECT title FROM threads WHERE id = ? LIMIT 1", -1, &query, nil) == SQLITE_OK else { continue }
            }
            defer { sqlite3_finalize(query) }
            var result: [String: String] = [:]
            for id in ids where SessionParser.validID(id) {
                sqlite3_reset(query); sqlite3_clear_bindings(query)
                id.withCString { pointer in
                    _ = sqlite3_bind_text(query, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                if sqlite3_step(query) == SQLITE_ROW, let raw = sqlite3_column_text(query, 0) {
                    let title = SessionParser.codexTitle(String(cString: raw))
                    if !title.isEmpty { result[id] = title }
                }
            }
            return result
        }
        return [:]
    }
}
