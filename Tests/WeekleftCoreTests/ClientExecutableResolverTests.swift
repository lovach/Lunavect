import XCTest
@testable import WeekleftCore

final class ClientExecutableResolverTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Client resolver " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testExplicitClientOutsideSearchPathsHandlesQuotaAndExactResumeArguments() async throws {
        let directory = try directory()
        let executable = directory.appendingPathComponent("Codex '$(touch unexpected)")
        let arguments = directory.appendingPathComponent("arguments")
        let script = """
        #!/bin/sh
        if [ "$1" = app-server ]; then
          while IFS= read -r line; do
            case "$line" in
              *rateLimits*) printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1900000000}}}}'; exit 0 ;;
              *clientInfo*) printf '%s\\n' '{"id":1,"result":{}}' ;;
            esac
          done
        else
          printf '%s\\n' "$PWD" "$@" > \(SessionHooks.quote(arguments.path))
        fi
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let resolver = ClientExecutableResolver(codexPath: executable.path, discoverCodex: {
            XCTFail("An explicit selected client must not trigger discovery")
            return nil
        })
        let quota = try await CodexProvider.fetch(resolver: resolver)
        XCTAssertEqual(quota.weekly?.usedPercent, 23)
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let session = AgentSession(provider: .codex, sessionID: id, title: "Fixture", cwd: directory.path,
                                   client: .terminal, phase: .finished, updatedAt: .distantPast, observedAt: .distantPast, evidence: .hook)
        let launcher = directory.appendingPathComponent("resume.command")
        try session.terminalScript(resolver: resolver).write(to: launcher, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: arguments), directory.resolvingSymlinksInPath().path + "\nresume\n" + id + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected").path))
    }

    func testMissingExplicitClientFailsWithRecoveryInsteadOfSwitchingInstallation() throws {
        let resolver = ClientExecutableResolver(codexPath: "/missing/selected/codex", discoverCodex: { "/bin/echo" })
        XCTAssertThrowsError(try resolver.resolve(.codex)) {
            XCTAssertEqual($0 as? SessionOpeningError, .unavailableConfiguredCodex)
            XCTAssertFalse($0.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try ClientExecutableResolver(discoverCodex: { "/bin/echo" }).resolve(.codex), "/bin/echo")
    }

    func testInvalidExecutableNeverProducesAResumeLauncher() throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("not executable")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        for path in [directory.path, file.path, "relative/codex", "/bin/echo\n", "/bin/echo\0"] {
            XCTAssertThrowsError(try ClientExecutableResolver(codexPath: path).resolve(.codex), path)
        }
        XCTAssertEqual(try ClientExecutableResolver(codexPath: "/missing/codex", discoverClaude: { "/bin/echo" }).resolve(.claude), "/bin/echo")
    }
}
