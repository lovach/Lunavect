import XCTest
import Darwin

/// A regression that turns a bounded call into a blocking one (a FIFO opened
/// without `O_NONBLOCK`, a socket read without a deadline) must fail the test
/// with a message, not hang the suite until the CI job limit. XCTest has no
/// per-test timeout, so the risky call runs on its own thread with a deadline.
struct DeadlineExceeded: Error, CustomStringConvertible {
    let description: String
}

/// A native fixture that could not be built or did not report as expected.
struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

enum TestDeadline {
    /// Generous upper bound for work that must not wait: a loaded runner still
    /// finishes in milliseconds, a blocking regression never does.
    static let seconds: TimeInterval = 5

    /// Runs `body` on a separate thread. If it has not returned after `seconds`,
    /// the test fails, `release` unblocks the stuck call (for example by opening
    /// the other end of a FIFO) so the thread can end, and `DeadlineExceeded` is
    /// thrown. Errors thrown by `body` are rethrown unchanged.
    static func run<T>(_ operation: String, seconds: TimeInterval = seconds, release: @escaping () -> Void = {},
                       file: StaticString = #filePath, line: UInt = #line, _ body: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>(), finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.set(Result { try body() })
            finished.signal()
        }
        thread.name = "Deadline: \(operation)"
        thread.start()
        if finished.wait(timeout: .now() + seconds) == .timedOut {
            release()
            let recovered = finished.wait(timeout: .now() + Self.seconds) == .success
            let message = "\(operation) did not return within \(Int(seconds)) s; a bounded call is blocking"
                + (recovered ? "" : " (the worker thread is still stuck after release)")
            XCTFail(message, file: file, line: line)
            throw DeadlineExceeded(description: message)
        }
        return try box.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        func set(_ value: Result<T, Error>) { lock.withLock { result = value } }
        func get() throws -> T {
            guard let result = lock.withLock({ result }) else { throw DeadlineExceeded(description: "No result") }
            return try result.get()
        }
    }

    /// Unblocks a reader stuck in `open(O_RDONLY)` on a FIFO without a writer.
    static func releaseFIFOReader(_ url: URL) {
        let writer = open(url.path, O_WRONLY | O_NONBLOCK)
        if writer >= 0 { close(writer) }
    }
}

/// Wall-clock bounds in the default suite only separate "stopped promptly" from
/// "waited for the long deadline" (seconds to tens of seconds), so they allow
/// five seconds on a loaded runner. The original millisecond budgets remain as an
/// opt-in performance check: `LUNAVECT_STRICT_TIMING=1 swift test --filter …`.
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

/// Native fixtures compiled with clang once per test class and the processes
/// spawned from them. Every process registered here, and every descendant it
/// forked, is killed in `stopAll()` even when an assertion or `XCTUnwrap` ends
/// the test early, so no `pause()` fixture outlives its test.
final class NativeFixtures: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    /// Each registered process with its start time, read when it was registered.
    /// A process is killed only while that pid still has the same start time: a
    /// pid the system reused for another program after the fixture exited is never
    /// signalled (audit r2 R2-B-11).
    private var roots: [(pid: Int32, start: UInt64?)] = []
    private var processes: [Process] = []

    init(prefix: String) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)").resolvingSymlinksInPath()
    }

    private var built: [String: Result<URL, Error>] = [:]

    /// Compiles `source` into `directory/name` the first time it is requested
    /// (call it from `class func setUp`) and returns the same binary, or the same
    /// compiler failure, to every later test of the class.
    @discardableResult
    func compileOnce(_ source: @autoclosure () throws -> String, as name: String) throws -> URL {
        try lock.withLock { () -> Result<URL, Error> in
            if let result = built[name] { return result }
            let result = Result { try compile(source(), as: name) }
            built[name] = result
            return result
        }.get()
    }

    /// Compiles `source` into `directory/name`, bounded so a stuck compiler
    /// cannot hang the suite. Throws with the compiler's output on failure.
    private func compile(_ source: String, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent(name + ".c"), output = directory.appendingPathComponent(name)
        try source.write(to: input, atomically: true, encoding: .utf8)
        let compiler = Process(), log = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [input.path, "-o", output.path]
        compiler.standardOutput = log; compiler.standardError = log
        let finished = DispatchSemaphore(value: 0)
        compiler.terminationHandler = { _ in finished.signal() }
        try compiler.run()
        if finished.wait(timeout: .now() + 120) == .timedOut {
            compiler.terminate()
            throw DeadlineExceeded(description: "clang did not finish compiling \(name) within 120 s")
        }
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            let text = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FixtureError(description: "clang failed for \(name): \(text)")
        }
        return output
    }

    /// Starts `executable` and registers it (and later its descendants) for cleanup.
    func launch(_ executable: URL, arguments: [String] = [], in directory: URL? = nil, output: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let output { process.standardOutput = output }
        try process.run()
        let pid = process.processIdentifier, start = Self.startTime(of: pid)
        lock.withLock { processes.append(process); roots.append((pid, start)) }
        return process
    }

    /// Registers a process the fixture reported but did not start directly
    /// (a daemonised grandchild whose parent may already have exited).
    func track(_ pid: Int32) { track(pid, recordedStart: Self.startTime(of: pid)) }
    /// `recordedStart` is the start time the pid had when it was reported; tests
    /// pass an outdated one to model a pid that was reused since.
    func track(_ pid: Int32, recordedStart: UInt64?) {
        guard pid > 1 else { return }
        lock.withLock { roots.append((pid, recordedStart)) }
    }

    /// The process's start time in microseconds, or nil once it no longer exists.
    static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Kills every registered process and all of its descendants. The tree is
    /// collected before any kill: a killed parent's children move to launchd.
    func stopAll() {
        let (registered, started) = lock.withLock { () -> ([(pid: Int32, start: UInt64?)], [Process]) in
            defer { roots = []; processes = [] }
            return (roots, processes)
        }
        // Only a registered pid that still names the same process, and its current
        // descendants; never this test process or its parent.
        let own: Set<Int32> = [getpid(), getppid()]
        var all = Set<Int32>()
        var pending = registered.filter { $0.start != nil && Self.startTime(of: $0.pid) == $0.start }.map(\.pid)
        while let pid = pending.popLast() {
            guard pid > 1, !own.contains(pid), all.insert(pid).inserted else { continue }
            pending += Self.children(of: pid)
        }
        for pid in all { kill(pid, SIGKILL) }
        for process in started { process.waitUntilExit() }
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }

    static func children(of pid: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 256)
        // libproc returns the number of PIDs here (not bytes, unlike proc_listpids);
        // unused slots stay zero and are filtered either way.
        let found = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard found > 0 else { return [] }
        return buffer.prefix(min(Int(found), buffer.count)).filter { $0 > 1 }
    }

    /// Reads one line from a fixture's output, however the bytes are split
    /// across reads, and fails after `seconds` instead of waiting forever.
    static func readLine(from handle: FileHandle, within seconds: TimeInterval = TestDeadline.seconds) throws -> String {
        let fd = handle.fileDescriptor, end = ProcessInfo.processInfo.systemUptime + seconds
        var received = Data()
        while !received.contains(10) {
            let remaining = end - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw DeadlineExceeded(description: "Fixture wrote no complete line within \(Int(seconds)) s; received \(String(decoding: received, as: UTF8.self).debugDescription)")
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 0.25) * 1000) + 1)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard ready > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else {
                throw FixtureError(description: "Fixture closed its output before a complete line; received \(String(decoding: received, as: UTF8.self).debugDescription)")
            }
            received.append(contentsOf: bytes.prefix(count))
        }
        let line = received.prefix(upTo: received.firstIndex(of: 10) ?? received.endIndex)
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
