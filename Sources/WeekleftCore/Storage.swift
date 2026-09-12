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
    private enum CodingKeys: String, CodingKey { case showFiveHour, transparency, transparentBackground, subscriptionDates, enabledProviders }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showFiveHour = try values.decodeIfPresent(Bool.self, forKey: .showFiveHour) ?? false
        let alpha = try values.decodeIfPresent(Double.self, forKey: .transparency) ?? 0.5
        transparency = alpha.isFinite ? min(0.75, max(0.2, alpha)) : 0.5
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
}
public enum SnapshotStore {
    public static var directory: URL {
        if let group = Bundle.main.object(forInfoDictionaryKey: "WeekleftAppGroup") as? String, !group.isEmpty,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return url.appendingPathComponent("Weekleft", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Weekleft", isDirectory: true)
    }
    public static func load() -> SharedState {
        let url = directory.appendingPathComponent("snapshot.json")
        do {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(SharedState.self, from: data)
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
            try JSONDecoder().decode(SharedState.self, from: Data(contentsOf: file))
        }
        // A malformed quota must not erase valid subscription dates or preferences.
        if let backup = result.backupURL, let data = try? Data(contentsOf: backup),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let value = root["preferences"], let bytes = try? JSONSerialization.data(withJSONObject: value),
               let preferences = try? JSONDecoder().decode(WidgetPreferences.self, from: bytes) {
                result.value.preferences = preferences
            }
            result.value.snapshots = (root["snapshots"] as? [Any] ?? []).compactMap { value in
                guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(UsageSnapshot.self, from: bytes)
            }
        }
        return result
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

/// Preserve invalid bytes before allowing a fresh state to be saved. Permission,
/// I/O and backup failures propagate, so callers cannot overwrite unreadable data.
public enum LocalStateRecovery {
    public static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard rename(tmp.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
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
