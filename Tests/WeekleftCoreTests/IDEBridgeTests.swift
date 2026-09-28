import XCTest
import Darwin
import os
@testable import WeekleftCore

final class IDEBridgeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Socket directories live in /tmp; remove leftovers of crashed earlier runs.
        StaleTestDirectories.sweep()
    }
    private func withSocket(timeout: TimeInterval = 0.2, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, _ body: (IDEBridge.Connection, Int32) throws -> Void) throws {
        // A real private Unix socket, without an editor, provider or user session.
        let root = URL(fileURLWithPath: "/tmp/lunavect-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("peer.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(listener) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
        let client = try IDEBridge.Connection(path: path, timeout: timeout, uptime: uptime)
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(peer) }
        // Oversize-frame fixtures must not block their writer before the client
        // can read. A fixture failure is reported instead of hanging the suite.
        var bufferSize: Int32 = 65_536
        guard setsockopt(peer, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(peer, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        try body(client, peer)
    }
    private func write(_ bytes: Data, to peer: Int32) throws {
        let sent = bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, bytes.count) }
        guard sent == bytes.count else { throw POSIXError(.EIO) }
    }
    func testRealSocketKeepsReplyBoundariesAndReportsPeerExit() throws {
        try withSocket { client, peer in
            try write(Data("{\"status\":\"matched\",\"shellPID\":42}\n{\"status\":\"focused\"}\n".utf8), to: peer)
            let first = try client.receive()
            XCTAssertEqual(first.status, "matched"); XCTAssertEqual(first.shellPID, 42)
            XCTAssertEqual(try client.receive().status, "focused")
            let request = Data("{\"action\":\"probe\"}".utf8)
            try client.send(request)
            var bytes = [UInt8](repeating: 0, count: 256)
            let received = Darwin.read(peer, &bytes, bytes.count)
            XCTAssertGreaterThan(received, 0)
            XCTAssertEqual(Data(bytes.prefix(max(0, received))), request + Data([10]))
            shutdown(peer, SHUT_RDWR)
            XCTAssertThrowsError(try client.receive())
        }
    }
    func testRealSocketRejectsMalformedOversizedAndUnfinishedReplies() throws {
        for bytes in [Data("not-json\n".utf8), Data("{\"shellPID\":42}\n".utf8), Data([0xff, 10]),
                      Data(repeating: 65, count: 20_000), Data(("{\"status\":\"" + String(repeating: "a", count: 20_000) + "\"}\n").utf8)] {
            try withSocket { client, peer in
                try write(bytes, to: peer)
                XCTAssertThrowsError(try client.receive())
            }
        }
        // The budget is measured on the injected clock, which advances 10 ms per
        // reading: the connection must give up at the first reading past it.
        let readings = OSAllocatedUnfairLock(initialState: [TimeInterval]())
        let clock: @Sendable () -> TimeInterval = {
            readings.withLock { values in values.append(100 + Double(values.count) / 100); return values[values.count - 1] }
        }
        try withSocket(timeout: 0.05, uptime: clock) { client, peer in
            try write(Data("{\"status\":\"matched\"}".utf8), to: peer) // no frame terminator
            XCTAssertThrowsError(try TestDeadline.run("Receiving an unfinished reply", release: { shutdown(peer, SHUT_RDWR) }) {
                try client.receive()
            }) { XCTAssertEqual($0 as? SessionError, .timeout, "An unfinished reply must not hold navigation indefinitely") }
            let last = try XCTUnwrap(readings.withLock { $0.last })
            XCTAssertGreaterThanOrEqual(last, 100.05 - 1e-9)
            XCTAssertLessThan(last, 100.065, "No further polling once the budget has elapsed")
        }
    }

    func testConnectionUsesOneMonotonicBudgetEvenForBufferedReplies() throws {
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(100))
        try withSocket(timeout: 10, uptime: { clock.withLock { $0 } }) { client, peer in
            try write(Data("{\"status\":\"ready\"}\n{\"status\":\"focused\"}\n".utf8), to: peer)
            XCTAssertEqual(try client.receive().status, "ready")
            clock.withLock { $0 = 111 }
            XCTAssertThrowsError(try client.receive()) { XCTAssertEqual($0 as? SessionError, .timeout) }
            XCTAssertThrowsError(try client.send(Data())) { XCTAssertEqual($0 as? SessionError, .timeout) }
        }
    }

    func testCancelledSocketReadAndWriteStopBeforeTheLongDeadline() async throws {
        for writing in [false, true] {
            let ready = expectation(description: "Socket work started")
            let task = Task {
                try await SessionProcess.detached {
                    try self.withSocket(timeout: 30) { client, _ in
                        ready.fulfill()
                        // No peer reads/replies: eventually fills the send buffer.
                        if writing { while true { try client.send(Data(repeating: 65, count: 16_384)) } }
                        else { _ = try client.receive() }
                    }
                }
            }
            defer { task.cancel() }
            await fulfillment(of: [ready], timeout: 5)
            try await Task.sleep(for: .milliseconds(100))
            let start = ProcessInfo.processInfo.systemUptime
            task.cancel()
            do { try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected \(error)") }
            // 5 s is far below the 30 s budget the cancelled call would otherwise use.
            TimingBound.assertPrompt(since: start, strict: 0.8, "Cancellation must not wait for the connection deadline")
        }
    }

    func testSocketPeerExitPreservesFinalReplyAndClosedConnectionFailsPromptly() throws {
        // A frozen injected clock never reaches the 30 s budget: only the peer's
        // exit can end these reads, so "promptly" does not depend on wall time.
        try withSocket(timeout: 30, uptime: { 100 }) { client, peer in
            try write(Data("{\"status\":\"focused\"}\n".utf8), to: peer)
            shutdown(peer, SHUT_WR)
            XCTAssertEqual(try client.receive().status, "focused")
            XCTAssertThrowsError(try TestDeadline.run("Receiving after the peer exited", release: { shutdown(peer, SHUT_RDWR) }) {
                try client.receive()
            }) { XCTAssertEqual($0 as? SessionError, .unavailable) }
            client.closeConnection()
            XCTAssertThrowsError(try client.receive()) { XCTAssertEqual($0 as? SessionError, .unavailable) }
            XCTAssertThrowsError(try client.send(Data())) { XCTAssertEqual($0 as? SessionError, .unavailable) }
        }
    }

    func testExchangeCancellationClosesPeerBeforeAndAfterEditorCallback() async throws {
        for callback in [false, true] {
            let root = URL(fileURLWithPath: "/tmp/lunavect-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("exchange.sock").path
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(listener) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listener, 1) == 0, fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            let received = expectation(description: "Peer received navigation request")
            let server = Task {
                try await SessionProcess.detached {
                    func readable(_ fd: Int32) throws {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        guard poll(&descriptor, 1, 3000) > 0 else { throw SessionError.timeout }
                    }
                    try readable(listener)
                    let peer = accept(listener, nil, nil)
                    guard peer >= 0 else { throw POSIXError(.EIO) }
                    defer { Darwin.close(peer) }
                    var one: Int32 = 1
                    guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw POSIXError(.EIO) }
                    try readable(peer)
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    guard Darwin.read(peer, &bytes, bytes.count) > 0 else { throw SessionError.invalidResponse }
                    received.fulfill()
                    if callback {
                        let reply = "{\"status\":\"ready\",\"url\":\"vscode://lovach.lunavect/focus/\(UUID().uuidString)\"}\n"
                        try self.write(Data(reply.utf8), to: peer)
                    }
                    try readable(peer)
                    XCTAssertEqual(Darwin.read(peer, &bytes, bytes.count), 0, "Cancelled exchange must close its connection")
                }
            }
            defer { server.cancel() }
            let endpoint = IDEBridge.Descriptor(version: 1, id: UUID().uuidString, editor: .vscode, pid: 42,
                                                appPath: "/Applications/Fixture.app", bundleIdentifier: "com.microsoft.VSCode",
                                                socketPath: path, updatedAt: Date().timeIntervalSince1970)
            let task = Task {
                try await IDEBridge.exchange(endpoint, action: "open", target: .init(kind: "terminal", ancestors: [42]), timeout: 30) { _, _ in
                    XCTAssertTrue(callback)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }
            }
            defer { task.cancel() }
            await fulfillment(of: [received], timeout: 5)
            let start = ProcessInfo.processInfo.systemUptime
            if !callback { task.cancel() }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected \(error)") }
            try await server.value
            TimingBound.assertPrompt(since: start, strict: 0.8, "Cancellation must close the exchange before its 30 s budget")
        }
    }

    func testLegacyEditorLabelCannotGuessTerminalVersusProviderPanel() async throws {
        for provider in ProviderID.allCases {
            let row = AgentSession(provider: provider, sessionID: UUID().uuidString, title: "Fixture", cwd: "/tmp",
                                   client: .vscode, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
            do {
                try await IDEBridge.open(row, activateApp: { _ in XCTFail("No guessed host"); return false },
                                         openURL: { _, _ in XCTFail("No guessed panel"); return false })
                XCTFail("Missing origin must remain unavailable")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .ideSessionUnavailable("VS Code")) }
        }
    }
    // MARK: Navigation policy with fixture endpoints and exchanges

    private final class Calls: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [(id: String, action: String, timeout: TimeInterval)]())
        func record(_ id: String, _ action: String, _ timeout: TimeInterval) { lock.withLock { $0.append((id, action, timeout)) } }
        var all: [(id: String, action: String, timeout: TimeInterval)] { lock.withLock { $0 } }
    }
    private static let appPath = "/Applications/PyCharm.app"
    private func endpoint(_ state: IDEBridge.Endpoint.State, editor: SessionIDE = .jetbrains, companion: String? = nil) -> IDEBridge.Endpoint {
        let id = UUID().uuidString
        let descriptor = IDEBridge.Descriptor(version: 1, id: id, editor: editor, pid: 4242, appPath: Self.appPath,
                                              bundleIdentifier: "com.jetbrains.pycharm", socketPath: "/fixture/\(id).sock",
                                              updatedAt: Date().timeIntervalSince1970)
        return .init(editor: editor, bundleIdentifier: "com.jetbrains.pycharm", appPath: Self.appPath, companion: companion,
                     state: state, descriptor: state == .incompatible ? nil : descriptor)
    }
    private func row(usesTerminal: Bool = true) -> AgentSession {
        var row = AgentSession(provider: .claude, sessionID: UUID().uuidString, title: "Fixture", cwd: "/tmp",
                               client: .jetbrains, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        row.ideLocation = .init(editor: .jetbrains, bundleIdentifier: "com.jetbrains.pycharm", appPath: Self.appPath,
                                runtime: .init(pid: 42, startedAtMicroseconds: 1), usesTerminal: usesTerminal)
        return row
    }
    private func open(_ endpoints: [IDEBridge.Endpoint], calls: Calls = Calls(), activated: Bool = true, usesTerminal: Bool = true,
                      targets: Targets = Targets(),
                      reply: @escaping @Sendable (IDEBridge.Descriptor, String) throws -> IDEBridge.Reply) async throws {
        let environment = IDEBridge.Environment(
            endpoints: { endpoints }, ancestry: { _ in [42, 30] },
            exchange: { descriptor, action, target, timeout, _ in
                calls.record(descriptor.id, action, timeout); targets.record(target); return try reply(descriptor, action)
            },
            displayName: { _ in "PyCharm" })
        try await IDEBridge.open(row(usesTerminal: usesTerminal), activateApp: { _ in activated },
                                 openURL: { _, _ in XCTFail("JetBrains has no callback"); return false }, environment: environment)
    }
    private final class Targets: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [IDEBridge.Target]())
        func record(_ target: IDEBridge.Target) { lock.withLock { $0.append(target) } }
        var all: [IDEBridge.Target] { lock.withLock { $0 } }
    }

    /// A Reworked JetBrains tab can start Claude without a controlling terminal (seen in the
    /// 0.2.5 IDEA check: `usesTerminal: false`). The companion matches tabs by process
    /// ancestry, so the row is still opened; outside every tab it is an unsupported panel.
    func testJetBrainsRuntimeWithoutControllingTerminalIsMatchedByAncestry() async throws {
        let targets = Targets(), calls = Calls()
        try await open([endpoint(.live)], calls: calls, usesTerminal: false, targets: targets) { _, action in
            .init(status: action == "probe" ? "matched" : "focused")
        }
        XCTAssertEqual(calls.all.map(\.action), ["probe", "open"])
        XCTAssertEqual(targets.all, Array(repeating: IDEBridge.Target(kind: "terminal", ancestors: [42, 30]), count: 2),
                       "Never a provider-panel target, which the JetBrains companion does not support")
        do {
            try await open([endpoint(.live)], usesTerminal: false) { _, _ in .init(status: "notFound") }
            XCTFail("Expected a failure")
        } catch { XCTAssertEqual(error as? SessionOpeningError, .ideUnsupported("PyCharm"), "Not in any Terminal tab: an AI chat or agent panel") }
        do {
            try await open([endpoint(.live)], usesTerminal: true) { _, _ in .init(status: "notFound") }
            XCTFail("Expected a failure")
        } catch { XCTAssertEqual(error as? SessionOpeningError, .ideSessionUnavailable("PyCharm"), "A terminal session whose tab closed") }
    }

    /// N-04: a busy editor that does not answer the probe is a timeout, not a missing session.
    func testBusyOrSlowProbeIsReportedAsTimeoutWithinAFiveSecondBudget() async throws {
        for failure in ["timeout", "busy"] {
            let calls = Calls()
            do {
                try await open([endpoint(.live)], calls: calls) { _, action in
                    guard action == "probe" else { XCTFail("No open without a match"); return .init(status: "focused") }
                    if failure == "timeout" { throw SessionError.timeout }
                    return .init(status: "busy")
                }
                XCTFail("Expected a failure")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .ideTimedOut("PyCharm"), failure) }
            XCTAssertEqual(calls.all.map(\.timeout), [5], "\(failure): probes may take up to five seconds")
        }
        do {
            try await open([endpoint(.live)]) { _, _ in .init(status: "notFound") }
            XCTFail("Expected a failure")
        } catch { XCTAssertEqual(error as? SessionOpeningError, .ideSessionUnavailable("PyCharm"), "An answer that it is not there stays distinct") }
    }

    /// N-05 / T-20 / §4 items 11 and 12: installed-but-unreachable and incompatible
    /// companions are not reported as missing.
    func testUnreachableIncompatibleAndMissingCompanionsHaveDistinctMessages() async throws {
        let cases: [([IDEBridge.Endpoint], SessionOpeningError)] = [
            ([], .ideBridgeMissing("PyCharm")),
            ([endpoint(.unreachable)], .ideBridgeUnresponsive("PyCharm")),
            ([endpoint(.incompatible)], .ideCompanionIncompatible("PyCharm")),
            ([endpoint(.unreachable), endpoint(.incompatible)], .ideCompanionIncompatible("PyCharm"))
        ]
        for (endpoints, expected) in cases {
            let calls = Calls()
            do {
                try await open(endpoints, calls: calls) { _, _ in XCTFail("Nothing reachable to ask"); return .init(status: "matched") }
                XCTFail("Expected \(expected)")
            } catch { XCTAssertEqual(error as? SessionOpeningError, expected) }
            XCTAssertTrue(calls.all.isEmpty)
        }
        // After sleep the heartbeat can be late while the socket still answers.
        let calls = Calls()
        try await open([endpoint(.stale)], calls: calls) { _, action in .init(status: action == "probe" ? "matched" : "focused") }
        XCTAssertEqual(calls.all.map(\.action), ["probe", "open"])
        do {
            try await open([endpoint(.stale)]) { _, _ in throw SessionError.unavailable }
            XCTFail("Expected a failure")
        } catch { XCTAssertEqual(error as? SessionOpeningError, .ideBridgeUnresponsive("PyCharm"), "A socket that refuses is unresponsive") }
    }

    /// N-11: macOS refusing to activate the IDE is not a missing session.
    func testJetBrainsActivationFailureHasItsOwnMessage() async throws {
        let calls = Calls()
        do {
            try await open([endpoint(.live)], calls: calls, activated: false) { _, _ in .init(status: "matched") }
            XCTFail("Expected a failure")
        } catch { XCTAssertEqual(error as? SessionOpeningError, .ideActivationFailed("PyCharm")) }
        XCTAssertEqual(calls.all.map(\.action), ["probe"], "No focus request after a refused activation")
    }

    /// §4 item 9: two windows with the same project never pick one; separate
    /// projects route the open request only to the matching window.
    func testAmbiguousWindowsFailAndSeparateProjectsRouteToTheirWindow() async throws {
        let first = endpoint(.live), second = endpoint(.live)
        do {
            try await open([first, second]) { _, _ in .init(status: "matched") }
            XCTFail("Two matching windows are ambiguous")
        } catch { XCTAssertEqual(error as? SessionOpeningError, .ideAmbiguous("PyCharm")) }
        let calls = Calls()
        let target = try XCTUnwrap(second.descriptor?.id)
        try await open([first, second], calls: calls) { descriptor, action in
            .init(status: descriptor.id == target ? (action == "probe" ? "matched" : "focused") : "notFound")
        }
        XCTAssertEqual(calls.all.filter { $0.action == "open" }.map(\.id), [target])
    }

    /// N-10: descriptors left by forced quits are removed after a day; nothing
    /// that is not a Lunavect descriptor, or is still recent, is touched.
    func testDescriptorsLeftByForcedQuitsArePrunedAfterADay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func write(_ name: String, _ data: Data, age: TimeInterval, mode: Int = 0o600) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        func record(_ id: String) throws -> Data {
            try JSONEncoder().encode(IDEBridge.Descriptor(version: 1, id: id, editor: .vscode, pid: 999_999, appPath: "/Applications/Visual Studio Code.app",
                                                          bundleIdentifier: "com.microsoft.VSCode", socketPath: "/tmp/lunavect-ide-\(getuid())/\(id).sock",
                                                          updatedAt: now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970))
        }
        let old = UUID().uuidString, recent = UUID().uuidString, open = UUID().uuidString, foreign = UUID().uuidString
        let removed = [try write(old + ".json", record(old), age: 2 * 86_400),
                       try write(old + ".json.tmp", record(old), age: 2 * 86_400), try write(old + ".tmp", record(old), age: 2 * 86_400)]
        let kept = [try write(recent + ".json", record(recent), age: 3_600),
                    try write("notes.json", record(old), age: 2 * 86_400),
                    try write(open + ".json", record(open), age: 2 * 86_400, mode: 0o644),
                    try write(foreign + ".json", Data(#"{"theme":"dark"}"#.utf8), age: 2 * 86_400)]
        XCTAssertTrue(IDEBridge.descriptors(at: root, now: now).isEmpty)
        for file in removed { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent) }
        for file in kept { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent) }
        XCTAssertTrue(IDEBridge.descriptors(at: root, now: now).isEmpty, "A second reader, such as another app copy, is harmless")
    }

    /// N-10 (docs: "never records of a running editor"): a record whose heartbeat
    /// stalled for over a day (for example a long sleep) is kept while its editor
    /// still runs from the recorded bundle; the same record of an exited editor goes.
    func testPruningKeepsTheOldRecordOfAStillRunningEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-N-" + UUID().uuidString).resolvingSymlinksInPath()
        let records = root.appendingPathComponent("IDEBridge"), app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func write(pid: Int32) throws -> URL {
            let id = UUID().uuidString, file = records.appendingPathComponent(id + ".json")
            try JSONEncoder().encode(IDEBridge.Descriptor(version: 1, id: id, editor: .vscode, pid: pid, appPath: app.path,
                                                          bundleIdentifier: "com.microsoft.VSCode", socketPath: "/tmp/lunavect-ide-\(getuid())/\(id).sock",
                                                          updatedAt: now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970)).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: file.path)
            return file
        }
        let running = try write(pid: 4242), exited = try write(pid: 4343)
        _ = IDEBridge.scan(at: records, now: now, process: { pid in
            pid == 4242 ? .init(identity: .init(pid: 4242, startedAtMicroseconds: 1), parentPID: 1,
                                executable: app.path + "/Contents/MacOS/Electron", hasTerminal: false) : nil
        }, bundle: { $0 == app.path ? "com.microsoft.VSCode" : nil }, socketDirectories: ["/tmp/lunavect-ide-\(getuid())"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path), "The running editor's record is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exited.path), "An exited editor's day-old record is removed")
    }

    /// N-05 / N-09 / N-16 / T-20 / §4 items 10-12: descriptors are classified for a
    /// running editor: live, late heartbeat, missing socket, other protocol version.
    /// Installed 0.1.1 descriptors (no version field, /tmp sockets) stay live.
    func testScanClassifiesEndpointsOfRunningEditors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let records = root.appendingPathComponent("IDEBridge"), app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let sockets = "/tmp/lunavect-test-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(atPath: sockets) }
        let now = Date()
        func socket(_ id: String) throws {
            let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(listener) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array((sockets + "/" + id + ".sock").utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, chmod(sockets + "/" + id + ".sock", 0o600) == 0 else { throw POSIXError(.EIO) }
        }
        func write(_ object: [String: Any]) throws -> String {
            let id = object["id"] as! String
            let file = records.appendingPathComponent(id + ".json")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return id
        }
        func record(pid: Int = 4242, socket directory: String = sockets, age: TimeInterval = 0, appPath: String = app.path) -> [String: Any] {
            let id = UUID().uuidString
            return ["version": 1, "id": id, "editor": "vscode", "pid": pid, "appPath": appPath, "bundleIdentifier": "com.microsoft.VSCode",
                    "socketPath": directory + "/" + id + ".sock", "updatedAt": now.addingTimeInterval(-age).timeIntervalSince1970]
        }
        var current = record(); current["companion"] = "0.1.2"
        let live = try write(current); try socket(live)
        let legacy = try write(record(appPath: link.path)); try socket(legacy)
        let late = try write(record(age: 200)); try socket(late)
        let missing = try write(record())
        var future = record(); future["version"] = 2; future["socketPath"] = "/elsewhere"; let incompatible = try write(future)
        let foreign = try write(record(socket: "/tmp/other")); try? socket(foreign)
        let dead = try write(record(pid: 999)); try socket(dead)
        let endpoints = IDEBridge.scan(at: records, now: now, process: { pid in
            pid == 4242 ? .init(identity: .init(pid: 4242, startedAtMicroseconds: 1), parentPID: 1,
                                executable: app.path + "/Contents/MacOS/Electron", hasTerminal: false) : nil
        }, bundle: { $0 == app.path ? "com.microsoft.VSCode" : nil }, socketDirectories: [sockets])
        func state(_ id: String) -> IDEBridge.Endpoint.State? {
            endpoints.first { $0.descriptor?.id == id || ($0.descriptor == nil && id == incompatible) }?.state
        }
        XCTAssertEqual(state(live), .live)
        XCTAssertEqual(endpoints.first { $0.descriptor?.id == live }?.companion, "0.1.2")
        XCTAssertEqual(state(legacy), .live, "An installed 0.1.1 companion keeps working")
        XCTAssertNil(endpoints.first { $0.descriptor?.id == legacy }?.companion)
        XCTAssertEqual(endpoints.first { $0.descriptor?.id == legacy }?.appPath, app.path, "Symlinked install paths compare resolved")
        XCTAssertEqual(state(late), .stale)
        XCTAssertEqual(state(missing), .unreachable)
        XCTAssertEqual(endpoints.filter { $0.state == .incompatible }.count, 1)
        XCTAssertNil(endpoints.first { $0.descriptor?.id == foreign }, "Sockets outside the private directories are never used")
        XCTAssertNil(endpoints.first { $0.descriptor?.id == dead }, "A record of an exited editor is not an endpoint")
        XCTAssertEqual(endpoints.count, 5)
    }

    func testCompanionSocketDirectoriesArePrivateAndIncludeInstalledCompanions() {
        let directories = IDEBridge.socketDirectories
        XCTAssertEqual(directories.first, "/tmp/lunavect-ide-\(getuid())", "Companions 0.1.0 and 0.1.1 keep working")
        let temporary = directories.last ?? ""
        XCTAssertTrue(temporary.hasSuffix("/T/lunavect"), temporary)
        XCTAssertLessThan((temporary + "/" + UUID().uuidString + ".sock").utf8.count, 104, "Fits sockaddr_un with its terminator")
    }

    /// N-09 / §4 item 11: versions reported by companions against the bundled ones.
    func testCompanionUpdateComparesInstalledAndBundledVersions() {
        XCTAssertEqual(IDEBridge.companionUpdate(installed: nil, bundled: "0.1.2"), .available(installed: nil, bundled: "0.1.2"),
                       "0.1.0 and 0.1.1 report no version")
        XCTAssertEqual(IDEBridge.companionUpdate(installed: nil, bundled: "0.1.1"), .current, "Cannot tell 0.1.0 from 0.1.1")
        XCTAssertEqual(IDEBridge.companionUpdate(installed: "0.1.2", bundled: "0.1.10"), .available(installed: "0.1.2", bundled: "0.1.10"))
        XCTAssertEqual(IDEBridge.companionUpdate(installed: "0.1.2", bundled: "0.1.2"), .current)
        XCTAssertEqual(IDEBridge.companionUpdate(installed: "0.2.0", bundled: "0.1.2"), .current, "A newer companion is not downgraded")
        XCTAssertEqual(IDEBridge.companionUpdate(installed: "0.1.2", bundled: nil), .current)
        let manifest = Data(#"{"companionVersion":{"vscode":"0.1.2","jetbrains":"0.1.1","other":"1.0","bad":"x"},"version":1}"#.utf8)
        XCTAssertEqual(IDEBridge.bundledCompanionVersions(manifest: manifest), [.vscode: "0.1.2", .jetbrains: "0.1.1"])
        XCTAssertEqual(IDEBridge.bundledCompanionVersions(manifest: Data(#"{"version":1}"#.utf8)), [:])
    }

    /// The installers actually bundled with this build: a JetBrains 0.1.1 companion
    /// (which reports no version) is offered the bundled 0.1.2, and 0.1.2 is current;
    /// a VS Code 0.1.2 companion is offered 0.1.3, which reports the editor it runs in.
    func testBundledManifestOffersJetBrainsCompanionUpdate() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Weekleft/Resources/IDEConnectors/manifest.json")
        let bundled = IDEBridge.bundledCompanionVersions(manifest: try Data(contentsOf: manifest))
        XCTAssertEqual(bundled, [.vscode: "0.1.3", .jetbrains: "0.1.2"])
        XCTAssertEqual(IDEBridge.companionUpdate(installed: "0.1.2", bundled: bundled[.vscode]), .available(installed: "0.1.2", bundled: "0.1.3"))
        XCTAssertEqual(IDEBridge.companionUpdate(installed: nil, bundled: bundled[.jetbrains]), .available(installed: nil, bundled: "0.1.2"),
                       "An installed 0.1.1 plugin is asked to reinstall")
        XCTAssertEqual(IDEBridge.companionUpdate(installed: "0.1.2", bundled: bundled[.jetbrains]), .current)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertNil(object["pendingSources"], "A release bundles the JetBrains installer built from the current sources")
    }

    func testEndpointIdentityRejectsForeignPathsAndStaleRecords() throws {
        let now = Date()
        let id = UUID().uuidString
        var object: [String: Any] = ["version": 1, "id": id, "editor": "vscode", "pid": 42,
            "appPath": "/Applications/Visual Studio Code.app", "bundleIdentifier": "com.microsoft.VSCode",
            "socketPath": "/tmp/lunavect-ide-\(getuid())/\(id).sock", "updatedAt": now.timeIntervalSince1970]
        func descriptor() throws -> IDEBridge.Descriptor {
            try JSONDecoder().decode(IDEBridge.Descriptor.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(IDEBridge.valid(try descriptor(), now: now))
        object["socketPath"] = "/tmp/some-other-service.sock"
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now))
        object["socketPath"] = "/tmp/lunavect-ide-\(getuid())/\(id).sock"
        object["updatedAt"] = now.addingTimeInterval(-91).timeIntervalSince1970
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now))
        object["updatedAt"] = now.timeIntervalSince1970
        object["bundleIdentifier"] = "com.apple.Terminal"
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now))
        object["bundleIdentifier"] = "com.microsoft.VSCode"
        object["version"] = 2
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now), "T-20: another protocol version is never used")
        object["version"] = 1
        object["companion"] = "0.1.2"
        XCTAssertEqual(try descriptor().companion, "0.1.2")
        XCTAssertTrue(IDEBridge.valid(try descriptor(), now: now))
        object["companion"] = "0.1.2; rm"
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now), "Only a plain version is shown in settings")
        object["companion"] = nil
        let temporary = IDEBridge.socketDirectories.last ?? ""
        object["socketPath"] = temporary + "/\(id).sock"
        XCTAssertTrue(IDEBridge.valid(try descriptor(), now: now), "Companions from 0.1.2 use the private temporary directory")
    }

    /// R2-01: companion 0.1.2 puts its socket in `$TMPDIR/lunavect` of the editor's
    /// environment. A TMPDIR from `.zshrc`, `nix develop`, devbox or an unset one
    /// (`/tmp`) must not make a working companion look missing. Pure identity check.
    func testCompanionSocketFollowsTheEditorsTemporaryFolder() throws {
        let now = Date(), id = UUID().uuidString
        func descriptor(_ socket: String) throws -> IDEBridge.Descriptor {
            try JSONDecoder().decode(IDEBridge.Descriptor.self, from: JSONSerialization.data(withJSONObject: [
                "version": 1, "id": id, "editor": "vscode", "pid": 42, "appPath": "/Applications/Visual Studio Code.app",
                "bundleIdentifier": "com.microsoft.VSCode", "socketPath": socket, "updatedAt": now.timeIntervalSince1970, "companion": "0.1.2"]))
        }
        let known = ["/tmp/lunavect-ide-\(getuid())", "/var/folders/ab/cdef/T/lunavect"]
        for folder in ["/Users/fixture/.cache/tmp", "/nix/store/x-devbox/tmp", "/tmp", "/private/tmp", "/private/var/folders/ab/cdef/T", "/Volumes/Work/tmp dir"] {
            XCTAssertTrue(IDEBridge.valid(try descriptor(folder + "/lunavect/\(id).sock"), now: now, socketDirectories: known), folder)
        }
        for socket in ["relative/lunavect/\(id).sock", "/tmp/other/\(id).sock", "/tmp/lunavect/\(UUID().uuidString).sock",
                       "/tmp/../tmp/lunavect/\(id).sock", "/tmp/./lunavect/\(id).sock", "//tmp/lunavect/\(id).sock",
                       "/lunavect/\(id).sock", "/tmp/x\n/lunavect/\(id).sock", "/tmp/lunavect/nested/\(id).sock",
                       "/" + String(repeating: "a", count: 80) + "/lunavect/\(id).sock"] {
            XCTAssertFalse(IDEBridge.valid(try descriptor(socket), now: now, socketDirectories: known), socket)
        }
        XCTAssertTrue(IDEBridge.valid(try descriptor("/tmp/lunavect-ide-\(getuid())/\(id).sock"), now: now, socketDirectories: known),
                      "Companions 0.1.0 and 0.1.1 keep working")
    }

    /// R2-01: the folder a descriptor names is used only when it is a real directory
    /// of this user with no group or other access; peer credentials are still checked
    /// at connect. Every file lives in this test's own /tmp/lunavect-test-* folder.
    func testSocketFolderOutsideTheKnownDirectoriesMustBePrivate() throws {
        let base = "/tmp/lunavect-test-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: base) }
        let root = URL(fileURLWithPath: base).resolvingSymlinksInPath()
        let records = root.appendingPathComponent("IDEBridge"), app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        func folder(_ path: String, mode: Int16 = 0o700) throws -> String {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url.path
        }
        let custom = try folder("c/lunavect"), open = try folder("o/lunavect", mode: 0o755), plain = try folder("p/other")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("l"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("l/lunavect").path, withDestinationPath: custom)
        let linked = root.appendingPathComponent("l/lunavect").path
        let now = Date()
        func endpoint(in directory: String) throws -> String {
            let id = UUID().uuidString, path = directory + "/" + id + ".sock"
            let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(listener) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            // The linked folder reaches the same inode: bind through the real one.
            let real = directory == linked ? custom + "/" + id + ".sock" : path
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(real.utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, chmod(real, 0o600) == 0 else { throw POSIXError(.EIO) }
            let object: [String: Any] = ["version": 1, "id": id, "editor": "vscode", "pid": 4242, "appPath": app.path,
                                         "bundleIdentifier": "com.microsoft.VSCode", "socketPath": path, "companion": "0.1.2",
                                         "updatedAt": now.timeIntervalSince1970]
            let file = records.appendingPathComponent(id + ".json")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return id
        }
        let custom1 = try endpoint(in: custom), public1 = try endpoint(in: open), other1 = try endpoint(in: plain), link1 = try endpoint(in: linked)
        let endpoints = IDEBridge.scan(at: records, now: now, process: { pid in
            pid == 4242 ? .init(identity: .init(pid: 4242, startedAtMicroseconds: 1), parentPID: 1,
                                executable: app.path + "/Contents/MacOS/Electron", hasTerminal: false) : nil
        }, bundle: { $0 == app.path ? "com.microsoft.VSCode" : nil }, socketDirectories: ["/tmp/lunavect-ide-\(getuid())"])
        func state(_ id: String) -> IDEBridge.Endpoint.State? { endpoints.first { $0.descriptor?.id == id }?.state }
        XCTAssertEqual(state(custom1), .live, "A private socket folder in a non-standard TMPDIR is used")
        XCTAssertEqual(state(public1), .unreachable, "A folder other users can enter is never connected to")
        XCTAssertEqual(state(link1), .unreachable, "A linked socket folder is never followed")
        XCTAssertNil(state(other1), "Only the companions' folder name is accepted")
    }

    func testCallbackCannotOpenFilesCommandsOrAnotherExtension() {
        let id = UUID().uuidString
        XCTAssertTrue(IDEBridge.validCallback(URL(string: "vscode://lovach.lunavect/focus/\(id)?windowId=3")!))
        for text in ["file:///tmp/a", "https://example.com", "vscode://another.extension/focus/\(id)",
                     "vscode://lovach.lunavect/focus/not-an-id", "vscode://user@lovach.lunavect/focus/\(id)",
                     "vscode://lovach.lunavect:80/focus/\(id)"] {
            XCTAssertFalse(IDEBridge.validCallback(URL(string: text)!), text)
        }
    }

    func testNavigationPayloadAllowsOnlyBoundedIdentifiers() {
        XCTAssertTrue(IDEBridge.Target(kind: "terminal", ancestors: [42, 30]).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "terminal", ancestors: []).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "terminal", ancestors: [1]).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "terminal", ancestors: Array(repeating: 42, count: 25)).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "command", ancestors: [42]).valid)
        XCTAssertTrue(IDEBridge.Target(kind: "codex", sessionID: UUID().uuidString, cwd: "/tmp/project").valid)
        XCTAssertFalse(IDEBridge.Target(kind: "claude", sessionID: "../../other", cwd: "/tmp/project").valid)
        XCTAssertFalse(IDEBridge.Target(kind: "claude", sessionID: UUID().uuidString, cwd: "/tmp/project\ncommand").valid)
    }

    func testOpenedDescriptorRejectsSpecialFilesLinksAndPublicPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("endpoint.json")
        let record = IDEBridge.Descriptor(version: 1, id: UUID().uuidString, editor: .vscode, pid: 42,
                                          appPath: "/Applications/Fixture.app", bundleIdentifier: "com.microsoft.VSCode",
                                          socketPath: "/tmp/fixture.sock", updatedAt: 1)
        let encoded = try JSONEncoder().encode(record)
        try encoded.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(IDEBridge.readDescriptor(from: file), record)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(IDEBridge.readDescriptor(from: link))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNil(IDEBridge.readDescriptor(from: file))
        XCTAssertNil(IDEBridge.readDescriptor(from: root))
        let fifo = root.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(try TestDeadline.run("Reading a FIFO endpoint descriptor", release: { TestDeadline.releaseFIFOReader(fifo) }) {
            IDEBridge.readDescriptor(from: fifo)
        })
        TimingBound.assertPrompt(since: start, strict: 0.2, "A FIFO descriptor is rejected without waiting")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try (encoded + Data(repeating: 32, count: 16384 - encoded.count)).write(to: file)
        XCTAssertEqual(IDEBridge.readDescriptor(from: file), record)
        try (encoded + Data(repeating: 32, count: 16385 - encoded.count)).write(to: file)
        XCTAssertNil(IDEBridge.readDescriptor(from: file))
        try Data("{broken".utf8).write(to: file)
        XCTAssertNil(IDEBridge.readDescriptor(from: file))
    }

    func testDescriptorDirectoryCannotBeSymlinked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertTrue(IDEBridge.descriptors(at: alias).isEmpty)
    }
}
