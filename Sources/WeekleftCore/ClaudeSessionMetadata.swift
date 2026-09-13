import Foundation

/// Desktop's local session metadata, read only. No messages, settings or credentials decoded.
public enum ClaudeSessionMetadata {
    private struct Entry: Decodable {
        var cliSessionId: String?
        var title: String?
        var isArchived: Bool?
    }
    public static func title(from data: Data, sessionID: String) -> String? {
        guard data.count < 2_000_000, let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.cliSessionId == sessionID, entry.isArchived != true else { return nil }
        let title = SessionParser.text(entry.title)
        return title.isEmpty ? nil : title
    }
    public static func titles(for ids: Set<String>, at root: URL? = nil) -> [String: String] {
        records(for: ids, at: root).compactMapValues { $0.title.isEmpty ? nil : $0.title }
    }
    /// The title may be empty while Desktop is still naming a session; its route stays valid.
    public struct Record: Sendable { public let title: String; public let desktopID: String }
    public static func records(for ids: Set<String>, at root: URL? = nil) -> [String: Record] {
        guard !ids.isEmpty else { return [:] }
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func children(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        }
        func directory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        var result: [String: (Record, Date)] = [:]
        // Exactly account/workspace/local_*.json; never recurse into transcripts or browser storage.
        for account in children(base).filter(directory) {
            for workspace in children(account).filter(directory) {
                for file in children(workspace) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let info = try? file.resourceValues(forKeys: keys), info.isSymbolicLink != true,
                          (info.fileSize ?? Int.max) < 2_000_000, let data = try? Data(contentsOf: file),
                          let entry = try? JSONDecoder().decode(Entry.self, from: data),
                          let id = entry.cliSessionId, ids.contains(id), entry.isArchived != true else { continue }
                    let title = self.title(from: data, sessionID: id) ?? ""
                    let modified = info.contentModificationDate ?? .distantPast
                    let desktopID = file.deletingPathExtension().lastPathComponent
                    // The newest file owns the route; a name from another copy is kept until a new one arrives.
                    if let previous = result[id], modified <= previous.1 {
                        if previous.0.title.isEmpty, !title.isEmpty { result[id] = (Record(title: title, desktopID: previous.0.desktopID), previous.1) }
                    } else {
                        result[id] = (Record(title: title.isEmpty ? result[id]?.0.title ?? "" : title, desktopID: desktopID), modified)
                    }
                }
            }
        }
        return result.mapValues { $0.0 }
    }
}
