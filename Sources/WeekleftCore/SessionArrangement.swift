import Foundation

/// Local ordering only; provider conversations are never modified.
public struct SessionArrangement: Codable, Equatable {
    public var order: [String] = []
    public var pinned: Set<String> = []
    public var lastSeenAt: [String: Date]?
    public init() {}
    public func arranged(_ rows: [AgentSession]) -> [AgentSession] {
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return rows.enumerated().sorted { a, b in
            let ap = pinned.contains(a.element.id), bp = pinned.contains(b.element.id)
            if ap != bp { return ap }
            // New requests for attention lead their pin group until the user
            // places them. Existing manual order is never re-sorted by phase.
            let anew = ranks[a.element.id] == nil && [.permission, .input].contains(a.element.phase)
            let bnew = ranks[b.element.id] == nil && [.permission, .input].contains(b.element.phase)
            if anew != bnew { return anew }
            let ar = ranks[a.element.id] ?? Int.max, br = ranks[b.element.id] ?? Int.max
            return ar == br ? a.offset < b.offset : ar < br
        }.map(\.element)
    }
    public mutating func move(_ id: String, before target: String, after: Bool = false, visible: [String]) {
        guard id != target, visible.contains(id), visible.contains(target),
              pinned.contains(id) == pinned.contains(target) else { return }
        // Preserve hidden/filter-excluded IDs, while recording today's visible order.
        var next = order.filter { !visible.contains($0) }
        var moving = visible.filter { $0 != id }
        moving.insert(id, at: moving.firstIndex(of: target)! + (after ? 1 : 0))
        next.append(contentsOf: moving)
        order = next
    }
    /// Call on a coarse cadence. Missing catalog rows are retained for 35 days;
    /// no single partial discovery can destroy a user's ordering or pins.
    @discardableResult public mutating func observe(_ ids: Set<String>, now: Date = Date()) -> Bool {
        let previous = self
        var seen = lastSeenAt ?? [:]
        let owned = Set(order).union(pinned)
        for id in owned where seen[id] == nil { seen[id] = now }
        for id in owned.intersection(ids) { seen[id] = now }
        let retained = owned.filter { now.timeIntervalSince(seen[$0] ?? now) <= SessionVisibility.retention }
        order = order.filter(retained.contains); pinned.formIntersection(retained)
        lastSeenAt = retained.isEmpty ? nil : seen.filter { retained.contains($0.key) }
        return self != previous
    }
    public static func loadRecovering(from url: URL) throws -> RecoveredLocalState<SessionArrangement> {
        try loadRecovering(from: url, read: { try Data(contentsOf: $0) })
    }
    // The read seam lets tests reproduce an I/O failure without accessing user files.
    static func loadRecovering(from url: URL, read: (URL) throws -> Data) throws -> RecoveredLocalState<SessionArrangement> {
        try LocalStateRecovery.load(from: storageURL(url), empty: SessionArrangement()) { file in
            do { return try JSONDecoder().decode(SessionArrangement.self, from: read(file)) }
            catch {
                let cocoa = error as NSError
                guard error is DecodingError || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.fileReadCorruptFile.rawValue) else { throw error }
                // Atomic replacement can otherwise bypass a file's read-only bit.
                // Never relocate a file that the user has made read-only.
                try requireWritable(file)
                try requireWritable(file.deletingLastPathComponent())
                throw error
            }
        }
    }
    public func save(to url: URL) throws {
        try save(to: url, read: { try Data(contentsOf: $0) })
    }
    func save(to url: URL, read: (URL) throws -> Data) throws {
        let target = try Self.storageURL(url)
        // Revalidate at every mutation: the file may have become corrupt or
        // unreadable after the store initially loaded a valid arrangement.
        let current = try Self.loadRecovering(from: target, read: read)
        if let backupURL = current.backupURL {
            throw SessionArrangementRecoveryError(backupURL: backupURL)
        }
        if FileManager.default.fileExists(atPath: target.path) { try Self.requireWritable(target) }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.requireWritable(directory)
        try LocalStateRecovery.write(JSONEncoder().encode(self), to: target)
    }
    private static func storageURL(_ url: URL) throws -> URL {
        var target = url
        var followed = Set<String>()
        while true {
            // Foundation leaves a dangling final symlink unresolved. Recovery
            // deliberately moves its target, so resolve that final link ourselves
            // before the next standalone save can replace the symlink itself.
            target = target.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(target.lastPathComponent)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: target.path) }
            catch {
                let cocoa = error as NSError
                if cocoa.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) { return target }
                throw error
            }
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return target }
            guard followed.count < 40, followed.insert(target.path).inserted else { throw POSIXError(.ELOOP) }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
            target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : target.deletingLastPathComponent().appendingPathComponent(destination)
        }
    }
    private static func requireWritable(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o222 != 0, FileManager.default.isWritableFile(atPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// A save found new corruption, preserved its bytes, and stopped before writing.
/// The caller can explain the recovery before the user's next explicit mutation.
public struct SessionArrangementRecoveryError: Error {
    public let backupURL: URL
}
