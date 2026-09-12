import XCTest
@testable import WeekleftCore

final class ClientConnectionTests: XCTestCase {
    func testInstalledClientsConfirmExistingSignInWithoutReadingOutput() async throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_LIVE_CONNECTION"] == "1" else {
            throw XCTSkip("Opt-in check of existing official-client sign-in")
        }
        for provider in ProviderID.allCases {
            let path = try XCTUnwrap(provider == .claude ? SessionSources.discoverClaude() : CodexProvider.discoverCLI())
            let state = await ClientConnection.signInState(provider, executable: path)
            XCTAssertEqual(state, .signedIn, provider.rawValue)
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect-ConnectionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func executable(_ script: String, at url: URL) throws {
        try ("#!/bin/bash\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func testOfficialLoginIsExecutedWithoutInterpolatingPathsOrMessages() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = dir.appendingPathComponent("client '$(printf injected)")
        let args = dir.appendingPathComponent("arguments")
        try executable("printf '%s\\n' \"$@\" > \(SessionHooks.quote(args.path))\n", at: client)
        for provider in ProviderID.allCases {
            let script = try ClientConnection.script(provider: provider, action: .signIn, executable: client.path,
                heading: "Example '$(exit 23)' `exit 24`", completion: "Done", environment: [:])
            let file = try ClientConnection.writeLauncher(script, provider: provider, action: .signIn, directory: dir)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: args), provider == .claude ? "auth\nlogin\n" : "login\n")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
        }
    }
    func testSignInStatusUsesOnlyExitStatusAndDoesNotSaveOutput() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = dir.appendingPathComponent("client")
        for (code, expected) in [(0, ClientConnection.SignInState.signedIn), (1, .signedOut), (2, .unavailable)] {
            try executable("printf 'sensitive-fixture-output'\nprintf 'sensitive-fixture-error' >&2\nexit \(code)\n", at: client)
            for provider in ProviderID.allCases {
                let result = await ClientConnection.signInState(provider, executable: client.path)
                XCTAssertEqual(result, expected)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["client"])
    }
    func testHungStatusCheckTerminatesOnlyItsOwnProcess() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = dir.appendingPathComponent("hung")
        try executable("trap '' TERM\nwhile :; do :; done\n", at: client)
        let start = Date()
        let result = await ClientConnection.signInState(.claude, executable: client.path, timeout: 0.2)
        XCTAssertEqual(result, .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testInstallersAreOfficialAndDoNotRunAfterDownloadFailure() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let curl = dir.appendingPathComponent("failing-curl"), marker = dir.appendingPathComponent("must-not-execute")
        // Simulate a failed download that nevertheless leaves executable content.
        // Neither vendor installer may run that partial response.
        try executable("printf '%s\\n' \(SessionHooks.quote("/usr/bin/touch " + SessionHooks.quote(marker.path))) > \"${@: -1}\"\nexit 22\n", at: curl)
        for provider in ProviderID.allCases {
            let script = try ClientConnection.script(provider: provider, action: .install, executable: nil,
                heading: "Install", completion: "Done", environment: ["ANTHROPIC_API_KEY": "must-not-copy", "CODEX_ACCESS_TOKEN": "must-not-copy"])
            XCTAssertTrue(script.contains(provider == .claude ? "https://claude.ai/install.sh" : "https://chatgpt.com/codex/install.sh"))
            XCTAssertTrue(script.contains("set -euo pipefail"))
            XCTAssertTrue(script.contains("--fail"))
            XCTAssertTrue(script.contains("--proto-redir '=https'"))
            XCTAssertFalse(script.contains("must-not-copy"))
            XCTAssertFalse(script.contains("sudo"))
            XCTAssertFalse(script.contains("auth.json"))
            let fixture = script.replacingOccurrences(of: "/usr/bin/curl", with: SessionHooks.quote(curl.path))
            let file = try ClientConnection.writeLauncher(fixture, provider: provider, action: .install, directory: dir)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 22)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}
