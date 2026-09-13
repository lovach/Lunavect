import XCTest
import Security
@testable import AwakeService

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
}
