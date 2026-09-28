import Darwin
import XCTest
@testable import WeekleftCore

/// V2 (independent check of 0.2.6, R26-J-01): arguments are read only from the
/// user's own processes, a process that is gone yields nothing, the kernel layout is
/// parsed within its bounds, and no node/bun program other than the Claude Code
/// package is ever named Claude. Fixtures only: the one real process is /bin/sleep
/// started by this test; other processes are inspected for their owner, never read.
final class R26VerifyProcessArgumentsTests: XCTestCase {
    /// Fixed-seed SplitMix64: the same inputs on every run and machine.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// Another user's process (root daemons, other accounts) is never read: the
    /// owner is checked before the kernel is asked, and nothing is returned.
    func testArgumentsOfOtherUsersProcessesAreNeverRead() throws {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        var foreign: [Int32] = []
        for pid in pids.prefix(max(0, count)) where pid > 1 {
            var short = proc_bsdshortinfo()
            let size = Int32(MemoryLayout.size(ofValue: short))
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size, short.pbsi_uid != getuid() else { continue }
            foreign.append(pid)
            if foreign.count >= 64 { break }
        }
        guard !foreign.isEmpty else { throw XCTSkip("No process of another user is visible") }
        for pid in foreign {
            XCTAssertNil(SessionProcess.processArguments(pid), "pid \(pid)")
            XCTAssertNil(SessionProcess.runtimeProvider(pid: pid, executable: "/opt/homebrew/bin/node"), "pid \(pid)")
            XCTAssertFalse(SessionProcess.isLimitsCheck(pid: pid), "pid \(pid)")
        }
    }

    /// A process that exits between two reads is unknown, not an empty or stale vector.
    func testArgumentsOfAProcessThatIsGoneAreUnknown() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        let pid = process.processIdentifier
        defer { if process.isRunning { process.terminate() } }
        XCTAssertEqual(SessionProcess.processArguments(pid)?.dropFirst().map { $0 }, ["60"])
        XCTAssertNil(SessionProcess.runtimeProvider(pid: pid, executable: "/bin/sleep"), "Not an interpreter: its arguments decide nothing")
        process.terminate(); process.waitUntilExit()
        let after = SessionProcess.processArguments(pid)
        XCTAssertTrue(after == nil || after?.dropFirst().map { $0 } != ["60"], "A reaped process yields no arguments")
        XCTAssertNil(SessionProcess.runtimeProvider(pid: pid, executable: "/opt/homebrew/bin/node"))
    }

    /// Bounded fuzz of the KERN_PROCARGS2 layout: arbitrary bytes never crash and
    /// never yield a vector whose length differs from its declared count; a
    /// well-formed buffer round-trips exactly its arguments and none of its environment.
    func testKernelArgumentLayoutIsParsedWithinItsBounds() {
        var random = SplitMix64(state: 0x5EED_2026_0928)
        for _ in 0..<4000 {
            var bytes = [UInt8]()
            let length = random.below(160)
            for _ in 0..<length { bytes.append(random.below(4) == 0 ? 0 : UInt8(truncatingIfNeeded: random.next())) }
            if bytes.count >= 4, random.below(2) == 0 {
                let argc = Int32(random.below(12)) - 2
                withUnsafeBytes(of: argc) { for (i, b) in $0.enumerated() { bytes[i] = b } }
            }
            let declared = bytes.count >= 4 ? Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }) : 0
            if let parsed = SessionProcess.parseProcessArguments(bytes) {
                XCTAssertEqual(parsed.count, declared)
                XCTAssertFalse(parsed.contains { $0.utf8.contains(0) })
            }
        }
        let alphabet = Array("abcXYZ/.-=_ 0123456789".utf8)
        for _ in 0..<1000 {
            func word(allowEmpty: Bool) -> [UInt8] {
                (0..<(allowEmpty ? random.below(8) : 1 + random.below(8))).map { _ in alphabet[random.below(alphabet.count)] }
            }
            // argv[0] may be empty too (R26-V2-03). The executable path is NUL-padded to an
            // 8-byte boundary of the string area, as the kernel lays it out.
            let arguments = [word(allowEmpty: true)] + (0..<random.below(6)).map { _ in word(allowEmpty: true) }
            let environment = (0..<random.below(4)).map { _ in Array("SECRET_\(random.below(99))=value".utf8) }
            let path = Array("/opt/homebrew/bin/node".utf8.prefix(1 + random.below(22)))
            var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) } + path
            bytes += [UInt8](repeating: 0, count: (path.count + 1 + 7) / 8 * 8 - path.count)
            for string in arguments + environment { bytes += string + [0] }
            let parsed = SessionProcess.parseProcessArguments(bytes)
            XCTAssertEqual(parsed, arguments.map { String(decoding: $0, as: UTF8.self) })
            XCTAssertFalse(parsed?.contains { $0.hasPrefix("SECRET_") } ?? false, "The environment is not part of the vector")
        }
    }

    /// No false positives: whatever options, subcommands and other scripts a node or
    /// bun command line has, it is Claude only when the Claude Code package script (or
    /// a link named claude that resolves into it) is on it. Adding interpreter options
    /// before the script or arguments after it never changes the answer (metamorphic).
    func testOnlyTheClaudeCodePackageScriptIsClaude() {
        let package = "/Users/u/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let link = "/Users/u/.npm-global/bin/claude"
        let links = [link: package, "/usr/local/bin/claude": "/usr/local/lib/node_modules/some-tool/index.js",
                     "/Users/u/bin/claude": "/Users/u/bin/claude"]
        let resolve: (String) -> String? = { links[$0] }
        let tokens = ["-r", "--require", "--import", "-e", "--eval", "-p", "--", "run", "--inspect", "--no-warnings", "-C", "x",
                      "/Users/u/app/server.js", "/usr/local/bin/claude", "/Users/u/bin/claude", "node_modules/@anthropic-ai/claude-code/cli.js",
                      "/x/node_modules/@anthropic-ai/claude-code/other.js", "/x/node_modules/@anthropic-ai/claude-code-router/cli.js",
                      "/x/node_modules/@anthropic-ai/claude-agent-sdk/cli.js", "--eval=" + package, "/usage", "--safe-mode"]
        let claudePaths: Set<String> = [package, link]
        var random = SplitMix64(state: 0xC1A0_DE00_0126)
        var recognized = 0
        for iteration in 0..<6000 {
            var argv = [["node", "/opt/homebrew/bin/node", "bun", "nodejs"][random.below(4)]]
            for _ in 0..<random.below(7) { argv.append(tokens[random.below(tokens.count)]) }
            if iteration % 3 == 0 { argv.insert(random.below(2) == 0 ? package : link, at: 1 + random.below(argv.count)) }
            let executable = "/opt/homebrew/bin/" + URL(fileURLWithPath: argv[0]).lastPathComponent
            let provider = SessionProcess.runtimeProvider(pid: 4242, executable: executable, arguments: { _ in argv }, resolve: resolve)
            if provider != nil {
                recognized += 1
                XCTAssertEqual(provider, .claude)
                XCTAssertFalse(claudePaths.isDisjoint(with: argv), argv.joined(separator: " "))
            }
            let python = SessionProcess.runtimeProvider(pid: 4242, executable: "/usr/bin/python3", arguments: { _ in argv }, resolve: resolve)
            XCTAssertNil(python, "Only node and bun run the package")
            if let script = SessionProcess.scriptArgument(argv), script.hasPrefix("/") {
                let widened = [argv[0], "--no-warnings", "--enable-source-maps"] + argv.dropFirst()
                XCTAssertEqual(SessionProcess.scriptProvider(arguments: widened, resolve: resolve),
                               SessionProcess.scriptProvider(arguments: argv, resolve: resolve), argv.joined(separator: " "))
                XCTAssertEqual(SessionProcess.scriptProvider(arguments: argv + ["--resume", "fixture"], resolve: resolve),
                               SessionProcess.scriptProvider(arguments: argv, resolve: resolve), argv.joined(separator: " "))
            }
        }
        XCTAssertGreaterThan(recognized, 100, "The generator reaches the positive case")
        XCTAssertNil(SessionProcess.runtimeProvider(pid: 4242, executable: "/opt/homebrew/bin/node",
                                                    arguments: { _ in ["node", "-e", "1", package] }, resolve: resolve),
                     "Evaluated code has no script, even when the package path follows")
    }
}
