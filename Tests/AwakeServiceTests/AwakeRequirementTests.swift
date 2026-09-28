import XCTest
import Security
import os
@testable import AwakeService

/// Answers every call; used only on an in-process anonymous listener.
private final class AnsweringHelper: NSObject, LunavectAwakeProtocol, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func begin(seconds: Int, withReply reply: @escaping @Sendable (Bool, String) -> Void) { reply(true, "") }
    func beginConfigured(seconds: Int, allowBattery: Bool, batteryProtection: Bool, minimumBatteryPercent: Int,
                         thermalProtection: Bool, withReply reply: @escaping @Sendable (Bool, String) -> Void) { reply(true, "") }
    func configure(allowBattery: Bool, batteryProtection: Bool, minimumBatteryPercent: Int,
                   thermalProtection: Bool, withReply reply: @escaping @Sendable (Bool, String) -> Void) { reply(true, "") }
    func keepAlive(withReply reply: @escaping @Sendable (Bool, String) -> Void) { reply(true, "") }
    func end(withReply reply: @escaping @Sendable (Bool, String) -> Void) { reply(true, "") }
}

final class AwakeRequirementTests: XCTestCase {
    func testDebuggerGateEvaluatesActualSignedFixtureEntitlements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(AwakeServiceID.debuggerExclusion as CFString, [], &requirement), errSecSuccess)
        let gate = try XCTUnwrap(requirement)
        for entitlement: Bool? in [nil, false, true] {
            let fixture = directory.appendingPathComponent("fixture-" + String(describing: entitlement))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: fixture)
            let plist = directory.appendingPathComponent("entitlements.plist")
            let values: [String: Bool] = entitlement.map { ["com.apple.security.get-task-allow": $0] } ?? [:]
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--entitlements", plist.path, fixture.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            XCTAssertEqual(sign.terminationStatus, 0, "Ad-hoc fixture signing uses no account or keychain")
            var code: SecStaticCode?
            XCTAssertEqual(SecStaticCodeCreateWithPath(fixture as CFURL, [], &code), errSecSuccess)
            let result = SecStaticCodeCheckValidity(try XCTUnwrap(code), [], gate)
            XCTAssertEqual(result == errSecSuccess, entitlement != true,
                           "Enabled debugging must fail; absent/false must pass")
        }
    }
    func testBothPoliciesCompileAsRealSecurityRequirements() throws {
        for policy in [AwakeServiceID.PeerPolicy.development, .developerID] {
            let text = try AwakeServiceID.requirement(for: AwakeServiceID.app, team: "TESTTEAM01", policy: policy)
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
            XCTAssertNotNil(requirement)
            XCTAssertTrue(text.contains("anchor apple generic"))
            XCTAssertTrue(text.contains("identifier \"com.weekleft.app\""))
            XCTAssertTrue(text.contains("subject.OU"))
            XCTAssertEqual(text.contains("get-task-allow"), policy == .developerID)
            XCTAssertEqual(text.contains("1.2.840.113635.100.6.1.13"), policy == .developerID)
        }
    }
    func testRequirementRejectsInjectedIdentifiersAndMissingIdentity() {
        for (identifier, team) in [("com.weekleft.app\" or true", "TESTTEAM01"), ("com.weekleft.app", ""),
                                   ("com.weekleft.app", "TEAM\" or true") ] {
            XCTAssertThrowsError(try AwakeServiceID.requirement(for: identifier, team: team, policy: .developerID))
        }
    }
    /// Audit 05 §5 item 7: the helper's listener requirement refuses a caller that
    /// is not Lunavect from the expected team. This test process is such a caller;
    /// without the requirement the same call is answered. No daemon is involved.
    func testListenerRequirementRefusesACallerWithoutLunavectsSignature() throws {
        for required in [false, true] {
            let helper = AnsweringHelper(), listener = NSXPCListener.anonymous()
            if required {
                listener.setConnectionCodeSigningRequirement(
                    try AwakeServiceID.requirement(for: AwakeServiceID.app, team: "TESTTEAM01", policy: .developerID))
            }
            listener.delegate = helper; listener.resume()
            defer { listener.invalidate() }
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: LunavectAwakeProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let finished = expectation(description: "answer or refusal")
            let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            let record: @Sendable (Bool) -> Void = { value in
                if outcome.withLock({ current in defer { if current == nil { current = value } }; return current == nil }) { finished.fulfill() }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in record(false) } as? LunavectAwakeProtocol
            try XCTUnwrap(proxy).keepAlive { answered, _ in record(answered) }
            wait(for: [finished], timeout: 10)
            XCTAssertEqual(outcome.withLock { $0 }, !required, required ? "an unsigned caller is refused" : "control: an open listener answers")
        }
    }
}

