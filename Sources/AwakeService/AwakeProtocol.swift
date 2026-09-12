import Foundation
import Security

public enum AwakeServiceID {
    public static let label = "com.weekleft.awake-helper"
    public static let plist = label + ".plist"
    public static let app = "com.weekleft.app"
    public static let leaseSeconds: TimeInterval = 30

    /// Both peers accept only code signed by the same team as themselves.
    /// Unsigned development/test executables cannot control the root service.
    public static func requirement(for identifier: String) throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw AwakeFailure.identity }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw AwakeFailure.identity }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AwakeFailure.identity }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc public protocol LunavectAwakeProtocol {
    func begin(seconds: Int, withReply reply: @escaping (Bool, String) -> Void)
    func keepAlive(withReply reply: @escaping (Bool, String) -> Void)
    func end(withReply reply: @escaping (Bool, String) -> Void)
}

public enum AwakeFailure: String, Error {
    case identity, permission, unavailable, busy, external, system, recovery, expired, battery, thermal, lost
}
