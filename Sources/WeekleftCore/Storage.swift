import Foundation
import OSLog
import Darwin

public struct WidgetPreferences: Codable, Equatable, Sendable {
    public var showFiveHour = false
    public var transparency = 0.5
    public var transparentBackground = false
    public var subscriptionDates: [String: String] = [:]
    // nil belongs to pre-selection versions; an empty array means no connections.
    public var enabledProviders: [ProviderID]?
    public var providers: [ProviderID] { ProviderID.allCases.filter { enabledProviders?.contains($0) ?? true } }
    public mutating func migrateConnections(snapshots: [UsageSnapshot], configured: [ProviderID]) {
        guard enabledProviders == nil else { return }
        enabledProviders = ProviderID.allCases.filter { id in
            configured.contains(id) || snapshots.contains { $0.provider == id && $0.hasQuota }
        }
    }
    public init() {}
    public mutating func restoreAppearanceDefaults() {
        let base = WidgetPreferences()
        showFiveHour = base.showFiveHour; transparency = base.transparency
        transparentBackground = base.transparentBackground
    }
    private enum CodingKeys: String, CodingKey { case showFiveHour, transparency, transparentBackground, subscriptionDates, enabledProviders }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showFiveHour = try values.decodeIfPresent(Bool.self, forKey: .showFiveHour) ?? false
        let alpha = try values.decodeIfPresent(Double.self, forKey: .transparency) ?? 0.5
        transparency = alpha.isFinite ? min(1, max(0, alpha)) : 0.5
        transparentBackground = try values.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? false
        subscriptionDates = try values.decodeIfPresent([String: String].self, forKey: .subscriptionDates) ?? [:]
        enabledProviders = try values.decodeIfPresent([ProviderID].self, forKey: .enabledProviders)
    }
}
public struct SharedState: Codable, Sendable {
    public var snapshots: [UsageSnapshot]
    public var preferences: WidgetPreferences
    public init(snapshots: [UsageSnapshot] = ProviderID.allCases.map { UsageSnapshot(provider: $0) }, preferences: WidgetPreferences = .init()) {
        self.snapshots = snapshots; self.preferences = preferences
    }
    private enum CodingKeys: String, CodingKey { case snapshots, preferences }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshots = try values.decode([UsageSnapshot].self, forKey: .snapshots)
        preferences = try values.decode(WidgetPreferences.self, forKey: .preferences)
        guard Set(snapshots.map(\.provider)).count == snapshots.count else {
            throw DecodingError.dataCorruptedError(forKey: .snapshots, in: values, debugDescription: "Duplicate quota providers")
        }
    }
}
public enum SnapshotStore {
    public static var directory: URL { resolved.url }
    /// A build that declares an App Group but cannot open its container stores
    /// shared state in Application Support, where the sandboxed widget cannot read it.
    public static var usesFallbackDirectory: Bool { resolved.fellBack }
    private static var resolved: (url: URL, fellBack: Bool) {
        resolveDirectory(group: Bundle.main.object(forInfoDictionaryKey: "WeekleftAppGroup") as? String,
                         container: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
                         applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
    public static func resolveDirectory(group: String?, container: (String) -> URL?, applicationSupport: URL) -> (url: URL, fellBack: Bool) {
        if let group, !group.isEmpty {
            if let url = container(group) { return (url.appendingPathComponent("Weekleft", isDirectory: true), false) }
            return (applicationSupport.appendingPathComponent("Weekleft", isDirectory: true), true)
        }
        return (applicationSupport.appendingPathComponent("Weekleft", isDirectory: true), false)
    }
    public static func load(from url: URL = directory.appendingPathComponent("snapshot.json")) -> SharedState {
        do {
            let data = try LocalStateRecovery.read(from: url, maximumBytes: 1_048_576)
            let state: SharedState
            do { state = try JSONDecoder().decode(SharedState.self, from: data) }
            catch is DecodingError { state = salvage(data) }
            Logger(subsystem: "com.weekleft.storage", category: "snapshot").debug("Snapshot loaded (\(data.count) bytes)")
            return state
        } catch {
            Logger(subsystem: "com.weekleft.storage", category: "snapshot").error("Snapshot unavailable: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return SharedState()
        }
    }
    /// Only the app repairs shared files. Widget readers remain read-only.
    public static func loadRecovering(from url: URL = directory.appendingPathComponent("snapshot.json")) throws -> RecoveredLocalState<SharedState> {
        var result = try LocalStateRecovery.load(from: url, empty: SharedState()) { file in
            try JSONDecoder().decode(SharedState.self, from: LocalStateRecovery.read(from: file, maximumBytes: 1_048_576))
        }
        if let backup = result.backupURL, let data = try? LocalStateRecovery.read(from: backup, maximumBytes: 1_048_576) {
            result.value = salvage(data)
        }
        return result
    }
    // Both readers preserve healthy preferences and providers. Only the app's
    // recovering reader moves invalid bytes aside before it can write again.
    private static func salvage(_ data: Data) -> SharedState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return SharedState() }
        func decode<Value: Decodable>(_ type: Value.Type, from value: Any?) -> Value? {
            guard let value, let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONDecoder().decode(type, from: bytes)
        }
        let rawSnapshots = root["snapshots"] as? [Any] ?? []
        let providers = rawSnapshots.compactMap { ($0 as? [String: Any])?["provider"] as? String }
        let counts = Dictionary(providers.map { ($0, 1) }, uniquingKeysWith: +)
        let snapshots = rawSnapshots.compactMap { value -> UsageSnapshot? in
            guard let snapshot = decode(UsageSnapshot.self, from: value), counts[snapshot.provider.rawValue] == 1 else { return nil }
            return snapshot
        }
        // Duplicate records are ambiguous even if one copy looks valid; never
        // pick an arbitrary quota to display as the provider's current value.
        return SharedState(snapshots: snapshots, preferences: decode(WidgetPreferences.self, from: root["preferences"]) ?? .init())
    }
    public static func save(_ state: SharedState) throws {
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("snapshot.json")
        try LocalStateRecovery.write(JSONEncoder().encode(state), to: url)
    }
}

public struct RecoveredLocalState<Value> {
    public var value: Value
    public let backupURL: URL?
}

/// The glass widget background replaces private ChronoServices implementations
/// (see docs/checks-and-release-gates.md). `defaults write` of `disablePrivateWidgetBackground` in the
/// shared App Group domain turns it off without a rebuild.
public enum WidgetBackgroundPolicy {
    public static let disableKey = "disablePrivateWidgetBackground"
    public static func usesPrivateBackground(_ preferences: WidgetPreferences, disabled: Bool = L10n.defaults.bool(forKey: disableKey)) -> Bool {
        preferences.transparentBackground && !disabled
    }
}

/// Future entries age the saved observation even when WidgetKit delays the next
/// requested read. A timeline entry never invents a new provider observation.
public enum WidgetTimelineSchedule {
    public static func dates(from now: Date, snapshots: [UsageSnapshot], calendar: Calendar = .current) -> [Date] {
        let horizon = now.addingTimeInterval(86400)
        var dates = Set((0...3).map { now.addingTimeInterval(Double($0) * 300) })
        for snapshot in snapshots {
            if let fetched = snapshot.fetchedAt { dates.insert(fetched.addingTimeInterval(901)) }
            for window in [snapshot.weekly, snapshot.fiveHour].compactMap({ $0 }) {
                if let reset = window.resetsAt { dates.insert(reset) }
            }
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) { dates.insert(midnight) }
        return dates.filter { $0 >= now && $0 <= horizon }.sorted()
    }
}

/// Preserve invalid bytes before allowing a fresh state to be saved. Permission,
/// I/O and backup failures propagate, so callers cannot overwrite unreadable data.
public enum LocalStateRecovery {
    /// Bound the actual read, not only a prior path stat: another process can
    /// replace or grow shared state while an app or widget opens it. Keep legacy
    /// migration symlinks, then validate the opened descriptor without following
    /// a replacement symlink or blocking on a special file.
    public static func read(from url: URL, maximumBytes: Int) throws -> Data {
        let target = url.resolvingSymlinksInPath()
        let descriptor = open(target.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(.EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard maximumBytes >= 0, maximumBytes < Int.max,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
    /// `synchronize: false` skips fsync for private state that is rewritten
    /// periodically; a crash then loses at most that cadence, never the old file.
    public static func write(_ data: Data, to url: URL, synchronize: Bool = true) throws {
        let target = url.resolvingSymlinksInPath()
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        // The private temporary is created exclusively and has restrictive mode
        // before the first byte. Existing migration symlinks keep their target.
        let descriptor = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try handle.write(contentsOf: data)
        if synchronize { try handle.synchronize() }
        try handle.close()
        guard rename(tmp.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    /// A writer killed between creating its private temporary and the rename
    /// (a hook or status-line helper cancelled by its client) leaves it behind.
    /// Remove only `write`'s own `.UUID.tmp` names, long after any write ends.
    @discardableResult public static func removeAbandonedTemporaries(in directory: URL, now: Date = Date(), olderThan age: TimeInterval = 3600) throws -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var removed = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) {
            let name = file.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp"), UUID(uuidString: String(name.dropFirst().dropLast(4))) != nil,
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
            try FileManager.default.removeItem(at: file); removed += 1
        }
        return removed
    }
    public static func load<Value>(from url: URL, empty: Value, read: (URL) throws -> Value) throws -> RecoveredLocalState<Value> {
        let target = url.resolvingSymlinksInPath()
        do { return RecoveredLocalState(value: try read(target), backupURL: nil) }
        catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.fileReadNoSuchFile.rawValue {
                return RecoveredLocalState(value: empty, backupURL: nil)
            }
            guard error is DecodingError || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.fileReadCorruptFile.rawValue) else { throw error }
            let backup = target.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: target, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            return RecoveredLocalState(value: empty, backupURL: backup)
        }
    }
}
