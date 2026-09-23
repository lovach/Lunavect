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
    public static func subagentIDs(for ids: Set<String>, at home: URL? = nil, now: Date = Date()) -> Set<String> {
        // A thread's recorded source never changes, so a classification read once
        // is reused. Missing IDs are queried again after a short pause: the
        // thread may be recorded later, and polls run every one to five seconds.
        let (known, recentlyMissing) = classifications.lookup(ids, home: home, now: now)
        let unknown = ids.subtracting(known.keys).subtracting(recentlyMissing)
        var result = Set(known.filter(\.value).keys)
        guard !unknown.isEmpty else { return result }
        let sources = values(for: unknown, at: home, queries: ["SELECT source FROM threads WHERE id = ? LIMIT 1"])
        var found: [String: Bool] = [:]
        for (id, source) in sources {
            let decoded = try? JSONSerialization.jsonObject(with: Data(source.utf8))
            let subagent = decoded.map { SessionParser.codexSubagent(source: $0) } ?? false
            found[id] = subagent
            if subagent { result.insert(id) }
        }
        classifications.store(found, missing: unknown.subtracting(found.keys), home: home, now: now)
        return result
    }
    private final class Classifications: @unchecked Sendable {
        static let missRetry: TimeInterval = 30
        private let lock = NSLock()
        private var home: URL??
        private var values: [String: Bool] = [:]
        private var misses: [String: Date] = [:]
        func lookup(_ ids: Set<String>, home: URL?, now: Date) -> ([String: Bool], Set<String>) {
            lock.lock(); defer { lock.unlock() }
            guard self.home == .some(home) else { return ([:], []) }
            let missing = misses.filter { ids.contains($0.key) && now.timeIntervalSince($0.value) >= 0 && now.timeIntervalSince($0.value) < Self.missRetry }
            return (values.filter { ids.contains($0.key) }, Set(missing.keys))
        }
        func store(_ found: [String: Bool], missing: Set<String>, home: URL?, now: Date) {
            lock.lock(); defer { lock.unlock() }
            if self.home != .some(home) { self.home = .some(home); values = [:]; misses = [:] }
            if values.count + found.count > 4096 { values = [:] }
            values.merge(found) { _, new in new }
            for id in found.keys { misses.removeValue(forKey: id) }
            if misses.count + missing.count > 4096 { misses = [:] }
            for id in missing { misses[id] = now }
        }
    }
    private static let classifications = Classifications()
    public static func markingSubagents(in rows: [AgentSession], at home: URL? = nil) -> [AgentSession] {
        let ids = Set(rows.filter { $0.provider == .codex }.map(\.sessionID))
        let children = subagentIDs(for: ids, at: home)
        let memories = memoryDirectories(home)
        return rows.map { row in
            var row = row
            if row.provider == .codex, children.contains(row.sessionID) || isInside(row.cwd, memories) { row.isCodexSubagent = true }
            return row
        }
    }
    /// Codex consolidates its memories with an internal agent that works in
    /// `CODEX_HOME/memories`. The agent reports hook events like a task, but it
    /// has no rollout, state row or title, so it is never a user session and
    /// the app-server cannot read it back.
    static func memoryDirectories(_ home: URL?) -> [String] {
        let memories = codexHome(home).appendingPathComponent("memories", isDirectory: true)
        return Array(Set([memories.standardizedFileURL.path, memories.resolvingSymlinksInPath().standardizedFileURL.path]))
    }
    static func isInside(_ cwd: String, _ directories: [String]) -> Bool {
        guard !cwd.isEmpty else { return false }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return directories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    private static func codexHome(_ home: URL?) -> URL {
        home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    private static func values(for ids: Set<String>, at home: URL?, queries: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let base = codexHome(home)
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
