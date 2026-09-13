import XCTest
@testable import WeekleftCore

final class CodexLauncherRuntimeTests: XCTestCase {
    private func fixture(waitingWrapper: Bool = false, invalid: Bool = false) throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Codex wrapper " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("native-client"), launcher = root.appendingPathComponent("codex")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/codex_runtime_fixture.c")
        _ = try SessionProcess.run(path: "/usr/bin/clang", arguments: [source.path, "-o", native.path], timeout: 30)
        let command = SessionHooks.quote(native.path) + " \"$@\"" + (invalid ? " invalid" : "")
        let body = waitingWrapper ? """
        exec 3<&0
        \(command) <&3 &
        child=$!
        trap 'kill "$child" 2>/dev/null; wait "$child"; exit' TERM INT
        wait "$child"
        """ : "exec " + command
        try ("#!/bin/sh\n" + body + "\n").write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return (root, native, launcher)
    }
    private func writer(native: URL, file: URL) throws -> Process {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = native; process.arguments = [file.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            try? input.fileHandleForWriting.close()
            Self.stop(process)
            try? output.fileHandleForReading.close()
        }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("R".utf8))
        return process
    }
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(process.isRunning, "Synthetic writer must stop promptly")
    }
    private func checkSilentTurn(waitingWrapper: Bool) async throws {
        let (root, native, launcher) = try fixture(waitingWrapper: waitingWrapper)
        let now = Date(), id = "11111111-2222-3333-4444-555555555555"
        let directory = root.appendingPathComponent("sessions/2026/09/13")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-2026-09-13T10-00-00-\(id).jsonl")
        let record: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-180)),
                                     "payload": ["type": "task_started", "turn_id": "fixture-turn", "thread_id": id]]
        try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: file)
        let process = try writer(native: native, file: file)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], processID: process.processIdentifier), [file.path])
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
        let catalog = try SessionProcess.codexCatalog(path: launcher.path, proxy: false, timeout: 3)
        XCTAssertTrue(catalog.isComplete)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [file.path])
        var row = AgentSession(provider: .codex, sessionID: id, title: "Fixture", cwd: "/fixture", phase: .unknown,
                               updatedAt: now, observedAt: now, runtimeConfirmed: false)
        row.activityPath = file.path
        let reader = CodexActivityReader(home: root)
        await reader.useExecutable(launcher.path)
        let rows = await reader.events(catalog: [row], now: now)
        XCTAssertEqual(rows.first?.effectivePhase(now: now), .running)
        Self.stop(process)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
        // An unrelated native process writing the same file is insufficient.
        let other = root.appendingPathComponent("unrelated-client")
        try FileManager.default.copyItem(at: native, to: other)
        _ = try writer(native: other, file: file)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
    }
    func testExecLauncherKeepsSilentTurnRunningOnlyWhileSelectedNativeClientWrites() async throws {
        try await checkSilentTurn(waitingWrapper: false)
    }
    func testInterpreterWrapperConfirmsItsSingleNativeChild() async throws {
        try await checkSilentTurn(waitingWrapper: true)
    }
    func testFailedAppServerCannotRegisterRuntimeIdentity() throws {
        let (root, native, launcher) = try fixture(invalid: true)
        let file = root.appendingPathComponent("log.jsonl"); try Data().write(to: file)
        _ = try writer(native: native, file: file)
        XCTAssertThrowsError(try SessionProcess.codexCatalog(path: launcher.path, proxy: false, timeout: 3)) {
            XCTAssertNotEqual($0 as? SessionError, .timeout, "The fixture must return a protocol error")
        }
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
    }
    func testAmbiguousInterpreterChildrenAreNotTreatedAsTheSelectedClient() throws {
        let (root, native, launcher) = try fixture()
        let script = """
        #!/bin/sh
        exec 3<&0
        /bin/sleep 30 &
        helper=$!
        \(SessionHooks.quote(native.path)) "$@" <&3 &
        client=$!
        trap 'kill "$helper" "$client" 2>/dev/null; wait; exit' TERM INT
        wait
        """
        try script.write(to: launcher, atomically: false, encoding: .utf8)
        let file = root.appendingPathComponent("log.jsonl"); try Data().write(to: file)
        _ = try writer(native: native, file: file)
        _ = try SessionProcess.codexCatalog(path: launcher.path, proxy: false, timeout: 3)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
    }
    func testChangingLauncherOrNativeBinaryRequiresANewSuccessfulProbe() throws {
        let (root, native, launcher) = try fixture()
        let file = root.appendingPathComponent("log.jsonl"); try Data().write(to: file)
        _ = try writer(native: native, file: file)
        _ = try SessionProcess.codexCatalog(path: launcher.path, proxy: false, timeout: 3)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [file.path])
        let script = try String(contentsOf: launcher)
        try (script + "# changed launcher\n").write(to: launcher, atomically: false, encoding: .utf8)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
        _ = try SessionProcess.codexCatalog(path: launcher.path, proxy: false, timeout: 3)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [file.path])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: native.path)
        XCTAssertEqual(CodexRuntimeReader.writablePaths([file.path], executable: launcher.path), [])
    }
}
