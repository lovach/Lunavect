import XCTest
import Darwin
@testable import WeekleftCore

/// r2 audit X, invariant X-I6: a project folder name travels from a client's hook
/// payload (external input) through the hook record on disk and the session
/// store into two shell commands: the Terminal launcher that resumes an ended
/// session and the "copy resume command" text. Each hop has its own tests; this
/// case follows one hostile name through the whole chain and executes the
/// result with a fixture client, so a hop that re-parses or re-quotes the path
/// shows up as a wrong folder, a wrong argument or a side effect.
final class R2IntegrationBoundaryTests: XCTestCase {
    /// SplitMix64 with a fixed seed: the same names on every run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let pieces = ["'", "\"", "$(touch INJECTED)", "`touch INJECTED`", "$HOME", "${IFS}", "\\", ";", "&", "|", "*", "?",
                                 "[a]", "{x,y}", "~", "#", "!", "%", " ", "\t", "\n", "-", "--", "Ёлка", "Café", "🌙", "👩‍💻",
                                 "a", "b", ".", "..", ">out", "<in", "(", ")", "\u{200B}"]

    private func names() -> [String] {
        var random = Seeded(state: 0x5EED_2026_0928)
        var result = ["-n", "--", "'$(touch INJECTED)'", "trailing newline\n", "ends with space ", "\\'\\\"", "Ёлка Café 🌙"]
        while result.count < 32 {
            let count = Int.random(in: 1...6, using: &random)
            let name = (0..<count).map { _ in Self.pieces.randomElement(using: &random)! }.joined()
            guard ![".", ".."].contains(name), name.utf8.count < 200 else { continue }
            result.append(name)
        }
        return result
    }

    private func executable(_ script: String, at url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Runs a command with /bin/zsh without the host's startup files (ZDOTDIR and -f).
    private func zsh(_ arguments: [String], in directory: URL, dotfiles: URL, path: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": path, "ZDOTDIR": dotfiles.path, "HOME": dotfiles.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate(); XCTFail("zsh did not finish") }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testHostileProjectFolderSurvivesHookRecordStoreAndBothResumeCommands() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-X-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: created) }
        // realpath keeps /private, as `pwd -P` reports it (resolvingSymlinksInPath drops it).
        let canonical = try XCTUnwrap(realpath(created.path, nil))
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let hooks = root.appendingPathComponent("Sessions", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        let neutral = root.appendingPathComponent("neutral", isDirectory: true)
        for folder in [projects, hooks, bin, dotfiles, neutral] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // A host .zshenv would run for every command; this one proves the fixture never reads one.
        try Data("touch \(SessionHooks.quote(root.appendingPathComponent("ZSHENV-READ").path))\n".utf8)
            .write(to: dotfiles.appendingPathComponent(".zshenv"))
        let output = root.appendingPathComponent("client-output")
        // The fixture client records its working folder and arguments, NUL-separated.
        try executable("""
        #!/bin/sh
        /bin/pwd -P > \(SessionHooks.quote(output.path + ".cwd"))
        printf '%s\\0' "$@" > \(SessionHooks.quote(output.path + ".args"))
        """, at: bin.appendingPathComponent("claude"))

        for (index, name) in names().enumerated() {
            let project = projects.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let cwd = project.path
            let id = UUID().uuidString.lowercased()
            // 1. External input: the client's SessionEnd payload.
            let payload = try JSONSerialization.data(withJSONObject: [
                "session_id": id, "hook_event_name": "SessionEnd", "cwd": cwd, "reason": "prompt_input_exit"])
            try SessionHooks.capture(payload, provider: .claude, at: hooks, client: .terminal,
                                     isInternal: { _ in false }, isAlive: { _ in false })
            // 2. The hook record read back as the store reads it.
            let row = try XCTUnwrap(SessionHooks.load(at: hooks).first { $0.sessionID == id }, "record \(index)")
            XCTAssertEqual(row.cwd, cwd, "record \(index): the path is stored byte for byte")
            XCTAssertTrue(row.canLaunchTerminalSession, "record \(index)")

            // 3. The Terminal launcher, as Terminal runs it.
            let script = try XCTUnwrap(row.terminalScript(executable: bin.appendingPathComponent("claude").path), "launcher \(index)")
            let launcher = root.appendingPathComponent("launcher-\(index).command")
            try executable(script, at: launcher)
            for suffix in [".cwd", ".args"] { try? FileManager.default.removeItem(atPath: output.path + suffix) }
            XCTAssertEqual(try zsh([launcher.path], in: neutral, dotfiles: dotfiles, path: "/usr/bin:/bin"), 0, "launcher \(index)")
            var reported = try String(contentsOfFile: output.path + ".cwd", encoding: .utf8)
            if reported.hasSuffix("\n") { reported.removeLast() }
            XCTAssertEqual(reported, cwd, "launcher \(index): the client starts in the recorded folder")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output.path + ".args")), Data("--resume\0\(id)\0".utf8), "launcher \(index)")

            // 4. The copied resume command, pasted into a shell with the client on PATH.
            for suffix in [".cwd", ".args"] { try? FileManager.default.removeItem(atPath: output.path + suffix) }
            XCTAssertEqual(try zsh(["-c", row.resumeCommand], in: neutral, dotfiles: dotfiles, path: bin.path + ":/usr/bin:/bin"), 0, "resume \(index)")
            reported = try String(contentsOfFile: output.path + ".cwd", encoding: .utf8)
            if reported.hasSuffix("\n") { reported.removeLast() }
            // Control characters are not shell arguments: the command then omits `cd`.
            let expected = cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? neutral.path : cwd
            XCTAssertEqual(reported, expected, "resume \(index): \(row.resumeCommand.debugDescription)")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output.path + ".args")), Data("--resume\0\(id)\0".utf8), "resume \(index)")
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter {
            $0.hasSuffix("INJECTED") || $0.hasSuffix("ZSHENV-READ") || $0.hasSuffix("/out") || $0 == "out"
        }
        XCTAssertEqual(leftovers, [], "No name was executed as code and no startup file ran")
    }
}
