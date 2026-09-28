import XCTest

// Test targets cannot share sources; this mirrors the parts of
// WeekleftCoreTests/TestDeadlines.swift that the UI tests use.

/// Wall-clock bounds in the default suite only separate "stopped promptly" from
/// "waited for the long deadline", so they allow five seconds on a loaded
/// runner. The original budgets remain an opt-in check: `LUNAVECT_STRICT_TIMING=1`.
enum TimingBound {
    static let prompt: TimeInterval = 5
    static var strict: Bool { ProcessInfo.processInfo.environment["LUNAVECT_STRICT_TIMING"] == "1" }

    static func assertPrompt(since start: TimeInterval, strict budget: TimeInterval, _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, prompt, message(), file: file, line: line)
        if strict { XCTAssertLessThan(elapsed, budget, "Strict timing: " + message(), file: file, line: line) }
    }
}

/// A C fixture compiled once per test class (from `class func setUp`); later
/// requests return the same binary or the same compiler failure.
final class CompiledFixture: @unchecked Sendable {
    let directory: URL
    private let source: String, name: String
    private let lock = NSLock()
    private var result: Result<URL, Error>?

    init(_ source: String, name: String, prefix: String) {
        self.source = source; self.name = name
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)").resolvingSymlinksInPath()
    }

    func executable() throws -> URL {
        try lock.withLock { () -> Result<URL, Error> in
            if let result { return result }
            let compiled = Result { try compile() }
            result = compiled
            return compiled
        }.get()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private func compile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent(name + ".c"), output = directory.appendingPathComponent(name)
        try source.write(to: input, atomically: true, encoding: .utf8)
        let compiler = Process(), log = Pipe(), finished = DispatchSemaphore(value: 0)
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [input.path, "-o", output.path]
        compiler.standardOutput = log; compiler.standardError = log
        compiler.terminationHandler = { _ in finished.signal() }
        try compiler.run()
        guard finished.wait(timeout: .now() + 120) == .success else {
            compiler.terminate()
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "clang did not finish \(name) within 120 s"])
        }
        guard compiler.terminationStatus == 0 else {
            let text = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "clang failed for \(name): \(text)"])
        }
        return output
    }
}
