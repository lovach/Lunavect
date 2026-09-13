import Foundation
import Security

public enum AwakeServiceID {
    public static let label = "com.weekleft.awake-helper"
    public static let plist = label + ".plist"
    public static let app = "com.weekleft.app"
    public static let leaseSeconds: TimeInterval = 30

    public enum PeerPolicy: String, Sendable {
        case development
        case developerID = "developer-id"
    }
    // `exists` is false for an absent entitlement or a Boolean false value.
    public static let debuggerExclusion = "! entitlement[\"com.apple.security.get-task-allow\"] exists"
    public static var peerPolicy: PeerPolicy {
        #if LUNAVECT_DISTRIBUTION
        return .developerID
        #else
        return .development
        #endif
    }
    /// Local Release and Debug builds support Apple Development from the same team.
    /// Distribution builds additionally require Developer ID and disallow debugging.
    public static func requirement(for identifier: String) throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw AwakeFailure.identity }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw AwakeFailure.identity }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AwakeFailure.identity }
        return try requirement(for: identifier, team: team, policy: peerPolicy)
    }
    public static func requirement(for identifier: String, team: String, policy: PeerPolicy) throws -> String {
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AwakeFailure.identity }
        let base = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        switch policy {
        case .development: return base
        case .developerID:
            return base + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " + debuggerExclusion
        }
    }
}

@objc public protocol LunavectAwakeProtocol {
    func begin(seconds: Int, withReply reply: @escaping @Sendable (Bool, String) -> Void)
    func beginConfigured(seconds: Int, allowBattery: Bool, batteryProtection: Bool, minimumBatteryPercent: Int,
                         thermalProtection: Bool, withReply reply: @escaping @Sendable (Bool, String) -> Void)
    func configure(allowBattery: Bool, batteryProtection: Bool, minimumBatteryPercent: Int,
                   thermalProtection: Bool, withReply reply: @escaping @Sendable (Bool, String) -> Void)
    func keepAlive(withReply reply: @escaping @Sendable (Bool, String) -> Void)
    func end(withReply reply: @escaping @Sendable (Bool, String) -> Void)
}

public enum AwakeFailure: String, Error {
    case identity, permission, unavailable, busy, external, system, recovery, expired, battery, thermal, power, lost
}

/// App-level stopping rules. Connection leases and crash recovery are never optional.
public struct AwakeSafetyPolicy: Codable, Equatable, Sendable {
    public var allowBattery: Bool
    public var batteryProtection: Bool
    public var minimumBatteryPercent: Int
    public var thermalProtection: Bool
    public init(allowBattery: Bool = true, batteryProtection: Bool = true,
                minimumBatteryPercent: Int = 10, thermalProtection: Bool = true) {
        self.allowBattery = allowBattery; self.batteryProtection = batteryProtection
        self.minimumBatteryPercent = min(50, max(5, minimumBatteryPercent))
        self.thermalProtection = thermalProtection
    }
    public var normalized: Self {
        Self(allowBattery: allowBattery, batteryProtection: batteryProtection,
             minimumBatteryPercent: minimumBatteryPercent, thermalProtection: thermalProtection)
    }
    public func failure(onBattery: Bool, batteryPercent: Double?, thermalSeverity: Int) -> AwakeFailure? {
        if thermalProtection && thermalSeverity >= 2 { return .thermal }
        if onBattery && !allowBattery { return .power }
        if onBattery && batteryProtection, let batteryPercent,
           batteryPercent <= Double(normalized.minimumBatteryPercent) { return .battery }
        return nil
    }
}
