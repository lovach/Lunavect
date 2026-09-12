import Foundation
import Darwin

public enum SessionSources {
    public static func discoverClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func claude(path: String) async throws -> [AgentSession] {
        try await Task.detached(priority: .utility) {
            let data = try SessionProcess.run(path: path, arguments: ["agents", "--json"])
            return try SessionParser.claude(data)
        }.value
    }
    public static func codex(path: String) async throws -> [AgentSession] {
        try await Task.detached(priority: .utility) {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
            if FileManager.default.fileExists(atPath: socket.path),
               let result = try? SessionProcess.codexList(path: path, proxy: true) {
                return try SessionParser.codex(result)
            }
            return try SessionParser.codex(SessionProcess.codexList(path: path, proxy: false))
        }.value
    }
    public static func legacyEvents(catalog: [AgentSession], now: Date = Date()) -> [AgentSession] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/statusbar/state.d")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        let codexIDs = Set(catalog.filter { $0.provider == .codex }.map(\.sessionID))
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), size.isSymbolicLink != true, (size.fileSize ?? 0) < 65536,
                  let data = try? Data(contentsOf: file), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = row["sessionId"] as? String, SessionParser.validID(id), row["started"] as? Bool == true,
                  let ts = row["ts"] as? Double, now.timeIntervalSince1970 - ts < 86400,
                  let pid = row["pid"] as? Int32, pid > 1, kill(pid, 0) == 0 else { return nil }
            let transcript = row["transcript"] as? String ?? "", entrypoint = row["entrypoint"] as? String ?? ""
            let provider: ProviderID
            if codexIDs.contains(id) || transcript.contains("/.codex/") { provider = .codex }
            else if transcript.contains("/.claude/") || entrypoint.contains("claude") || entrypoint == "cli" { provider = .claude }
            else { return nil }
            let phase: SessionPhase
            switch row["state"] as? String {
            case "thinking", "tool": phase = .running
            case "permission": phase = .permission
            case "done": phase = .ready
            default: phase = .unknown
            }
            let cwd = row["cwd"] as? String ?? ""
            let client = SessionProcess.client(parentPID: pid, entrypoint: entrypoint, terminal: row["term_program"] as? String ?? "")
            return AgentSession(provider: provider, sessionID: id, title: SessionParser.text(row["project"], fallback: "Сессия \(provider.title)"), cwd: cwd, client: client, phase: phase, updatedAt: Date(timeIntervalSince1970: ts), observedAt: Date(timeIntervalSince1970: ts), evidence: .legacy, tool: SessionParser.text(row["tool"]))
        }
    }
}

enum SessionProcess {
    static func withProcess<T>(path: String, arguments: [String], timeout: TimeInterval = 12, operation: (Process, Pipe, Pipe, TimeInterval) throws -> T) throws -> T {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw SessionError.unavailable }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let endsAt = ProcessInfo.processInfo.systemUptime + timeout
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let hardDeadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: hardDeadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            // Keep the hard deadline for a child that ignores SIGTERM after a successful reply.
            if !process.isRunning { hardDeadline.cancel() }
        }
        return try operation(process, input, output, endsAt)
    }
    /// A descendant can keep stdout open after the direct child exits. Bound the
    /// reads themselves, rather than relying on terminating the direct child.
    static func readChunk(_ handle: FileHandle, until deadline: TimeInterval) throws -> Data {
        let fd = handle.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 65536)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return Data() }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw SessionError.invalidResponse }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 50)
        }
        throw SessionError.timeout
    }
    static func run(path: String, arguments: [String], timeout: TimeInterval = 12) throws -> Data {
        try withProcess(path: path, arguments: arguments, timeout: timeout) { process, input, output, deadline in
            try input.fileHandleForWriting.close()
            var result = Data()
            while true {
                let chunk = try readChunk(output.fileHandleForReading, until: deadline)
                if chunk.isEmpty { break }
                result.append(chunk)
                guard result.count < 8_000_000 else { throw SessionError.invalidResponse }
            }
            while process.isRunning {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SessionError.timeout }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard process.terminationStatus == 0 else { throw process.terminationReason == .uncaughtSignal ? SessionError.timeout : SessionError.invalidResponse }
            return result
        }
    }
    static func codexList(path: String, proxy: Bool) throws -> Data {
        try withProcess(path: path, arguments: proxy ? ["app-server", "proxy"] : ["app-server", "--stdio"]) { _, input, output, deadline in
            func send(_ value: [String: Any]) throws {
                var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
                try input.fileHandleForWriting.write(contentsOf: bytes)
            }
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "lunavect_sessions", "version": "0.1.0"]]])
            var buffer = Data(), total = 0
            while true {
                let chunk = try readChunk(output.fileHandleForReading, until: deadline)
                guard !chunk.isEmpty else { throw SessionError.timeout }
                total += chunk.count; guard total < 8_000_000 else { throw SessionError.invalidResponse }; buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                    guard message["error"] == nil else { throw SessionError.invalidResponse }
                    if id == 1 {
                        try send(["method": "initialized"])
                        try send(["id": 2, "method": "thread/list", "params": ["limit": 100, "sortKey": "updated_at", "useStateDbOnly": true]])
                    } else if id == 2, let result = message["result"] as? [String: Any] {
                        return try JSONSerialization.data(withJSONObject: result)
                    }
                }
            }
        }
    }
    static func client(parentPID: Int32, entrypoint: String, terminal: String) -> SessionClient {
        // Query executable paths and parent PIDs directly. Never spawn ps, read
        // arguments, or inspect environment variables of another process.
        var pid = parentPID
        for _ in 0..<16 {
            // libproc defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
            // that expression macro is not imported into Swift.
            var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { break }
            let name = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            if ["/ChatGPT.app/", "/Codex.app/", "/Claude.app/"].contains(where: name.contains) { return .desktop }
            if name.contains("/Visual Studio Code.app/") { return .vscode }
            if name.contains("/Terminal.app/") || name.contains("/iTerm.app/") { return .terminal }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid > 1, info.pbi_ppid != UInt32(pid) else { break }
            pid = Int32(info.pbi_ppid)
        }
        if entrypoint.contains("desktop") { return .desktop }
        if terminal.lowercased().contains("vscode") { return .vscode }
        if !terminal.isEmpty || entrypoint == "cli" { return .terminal }
        return .unknown
    }
}

public extension SessionHooks {
    static func captureFromStandardInput(provider: ProviderID) {
        // Lifecycle tools must never block, approve, or inject context into the source session.
        let input = FileHandle.standardInput
        var data = Data()
        while let part = try? input.read(upToCount: 65536), !part.isEmpty {
            data.append(part)
            if data.count > 1_000_000 { print("{}"); return }
        }
        let env = ProcessInfo.processInfo.environment
        let client = SessionProcess.client(parentPID: getppid(), entrypoint: env["CLAUDE_CODE_ENTRYPOINT"] ?? "", terminal: env["TERM_PROGRAM"] ?? "")
        try? capture(data, provider: provider, client: client)
        print("{}")
    }
}

public extension AgentSession {
    var codexURL: URL? {
        guard provider == .codex, UUID(uuidString: sessionID) != nil else { return nil }
        return URL(string: "codex://threads/\(sessionID)")
    }
    var resumeCommand: String {
        let command: String
        if provider == .codex { command = "codex resume \(SessionHooks.quote(sessionID))" }
        else if client == .background, let resumeID, SessionParser.validID(resumeID) { command = "claude attach \(SessionHooks.quote(resumeID))" }
        else { command = "claude --resume \(SessionHooks.quote(sessionID))" }
        return cwd.isEmpty ? command : "cd \(SessionHooks.quote(cwd)) && \(command)"
    }
}
