import XCTest
@testable import WeekleftCore

final class ClientLaunchEnvironmentTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Client path '$(false) " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func writeExecutable(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func testSiblingInterpreterSupportsCatalogSignInAndTerminalLaunchers() async throws {
        let root = try directory(), client = root.appendingPathComponent("client")
        let arguments = root.appendingPathComponent("arguments")
        // Unique name prevents the host's Node installation from satisfying the test.
        let interpreter = "fixture-runtime-" + UUID().uuidString
        try writeExecutable("#!/usr/bin/env " + interpreter + "\n", to: client)
        try writeExecutable("""
        #!/bin/sh
        shift
        printf '%s\\n' "$@" > \(SessionHooks.quote(arguments.path))
        if [ "$1" = agents ]; then printf '%s' '[{"id":"fixture","status":"busy"}]'; fi
        """, to: root.appendingPathComponent(interpreter))
        let catalog = try await SessionSources.claude(path: client.path)
        XCTAssertEqual(catalog.count, 1)
        for provider in ProviderID.allCases {
            let state = await ClientConnection.signInState(provider, executable: client.path, timeout: 2)
            XCTAssertEqual(state, .signedIn)
            XCTAssertEqual(try String(contentsOf: arguments), provider == .claude ? "auth\nstatus\n" : "login\nstatus\n")
            let login = try ClientConnection.script(provider: provider, action: .signIn, executable: client.path,
                                                    heading: "Fixture", completion: "Done", environment: [:])
            _ = try SessionProcess.run(path: "/bin/bash", arguments: ["-c", login], timeout: 2)
            XCTAssertEqual(try String(contentsOf: arguments), provider == .claude ? "auth\nlogin\n" : "login\n")
            let id = "11111111-2222-3333-4444-555555555555"
            let row = AgentSession(provider: provider, sessionID: id, title: "Fixture", cwd: root.path,
                                   phase: .finished, updatedAt: .distantPast, observedAt: .distantPast)
            let resume = try XCTUnwrap(row.terminalScript(executable: client.path))
            _ = try SessionProcess.run(path: "/bin/zsh", arguments: ["-c", resume], timeout: 2)
            XCTAssertEqual(try String(contentsOf: arguments), (provider == .claude ? "--resume\n" : "resume\n") + id + "\n")
        }
    }
    func testDiscoveryUsesInjectedSystemDirectoriesAndSkipsExecutableDirectories() throws {
        let root = try directory(), system = root.appendingPathComponent("system")
        let local = root.appendingPathComponent(".local/bin/claude")
        let nvm = root.appendingPathComponent(".nvm/versions/node/v24.1.0/bin/claude")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for url in [system.appendingPathComponent("claude"), nvm] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeExecutable("#!/bin/sh\n", to: url)
        }
        XCTAssertEqual(SessionSources.discoverClaude(home: root.path, systemDirectories: [system.path]), system.appendingPathComponent("claude").path)
        XCTAssertEqual(SessionSources.discoverClaude(home: root.path, systemDirectories: []), nvm.path)
    }
}
