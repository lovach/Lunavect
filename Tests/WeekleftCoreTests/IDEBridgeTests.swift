import XCTest
import Darwin
import os
@testable import WeekleftCore

final class IDEBridgeTests: XCTestCase {
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
        try withSocket(timeout: 0.05) { client, peer in
            try write(Data("{\"status\":\"matched\"}".utf8), to: peer) // no frame terminator
            let before = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try client.receive()) { XCTAssertEqual($0 as? SessionError, .timeout) }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 2, "An unfinished reply must not hold navigation indefinitely")
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
            await fulfillment(of: [ready], timeout: 2)
            try await Task.sleep(for: .milliseconds(100))
            let start = ProcessInfo.processInfo.systemUptime
            task.cancel()
            do { try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected \(error)") }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
        }
    }

    func testSocketPeerExitPreservesFinalReplyAndClosedConnectionFailsPromptly() throws {
        try withSocket(timeout: 30) { client, peer in
            try write(Data("{\"status\":\"focused\"}\n".utf8), to: peer)
            shutdown(peer, SHUT_WR)
            XCTAssertEqual(try client.receive().status, "focused")
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try client.receive()) { XCTAssertEqual($0 as? SessionError, .unavailable) }
            client.closeConnection()
            XCTAssertThrowsError(try client.receive()) { XCTAssertEqual($0 as? SessionError, .unavailable) }
            XCTAssertThrowsError(try client.send(Data())) { XCTAssertEqual($0 as? SessionError, .unavailable) }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
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
            await fulfillment(of: [received], timeout: 2)
            let start = ProcessInfo.processInfo.systemUptime
            if !callback { task.cancel() }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected \(error)") }
            try await server.value
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
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

    func testDescriptorDirectoryCannotBeSymlinked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertTrue(IDEBridge.descriptors(at: alias).isEmpty)
    }
}
