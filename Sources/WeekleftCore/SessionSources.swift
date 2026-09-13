import Foundation
import Darwin

public struct CodexSessionCatalog: Sendable {
    public enum IncompleteReason: Equatable, Sendable {
        case pageLimit, timeLimit, repeatedCursor, invalidResponse, requestFailed, priorityReadIncomplete
    }
    public let sessions: [AgentSession]
    public let incompleteReason: IncompleteReason?
    public let pagesRead: Int
    /// IDs requested by the caller but absent from both individual reads and list pages.
    /// Callers can retain those existing rows without renewing their observation dates.
    public let unresolvedPrioritySessionIDs: [String]
    /// The optional filename supplement is best effort; its bounds are separate
    /// from API pagination and must not turn normal history into a source error.
    public let discoveryLimited: Bool
    public var isComplete: Bool { incompleteReason == nil && unresolvedPrioritySessionIDs.isEmpty }
    public var isDiscoveryComplete: Bool { isComplete && !discoveryLimited }

    public init(sessions: [AgentSession], incompleteReason: IncompleteReason? = nil, pagesRead: Int = 0, unresolvedPrioritySessionIDs: [String] = [], discoveryLimited: Bool = false) {
        self.sessions = sessions; self.incompleteReason = incompleteReason; self.pagesRead = pagesRead
        self.unresolvedPrioritySessionIDs = unresolvedPrioritySessionIDs
        self.discoveryLimited = discoveryLimited
    }

    public func retainingKnownSessions(_ previous: [AgentSession]) -> [AgentSession] {
        let active = Dictionary(previous.filter { $0.provider == .codex && $0.phase.isActive }.map { ($0.sessionID, $0) },
                                uniquingKeysWith: { $0.observedAt >= $1.observedAt ? $0 : $1 })
        var result = sessions.map { row in
            guard row.provider == .codex, row.phase == .unknown, row.runtimeConfirmed == false,
                  let old = active[row.sessionID] else { return row }
            // notLoaded belongs to the queried server, not necessarily the client's
            // running server. Keep this ID eligible for another priority read while
            // its effective status remains unknown, even in a complete catalog.
            var row = row
            row.phase = old.phase; row.activityPath = row.activityPath ?? old.activityPath
            row.observedAt = .distantPast; row.runtimeConfirmed = false; row.evidence = .catalog
            return row
        }
        guard !isComplete else { return result }
        var seen = Set(result.map(\.sessionID))
        let unresolved = Set(unresolvedPrioritySessionIDs)
        for var row in previous where row.provider == .codex && (row.phase.isActive || unresolved.contains(row.sessionID)) {
            guard seen.insert(row.sessionID).inserted else { continue }
            row.observedAt = .distantPast; row.runtimeConfirmed = false; row.evidence = .catalog
            result.append(row)
        }
        return result
    }
}

public enum SessionSources {
    public static func discoverClaude() -> String? { discoverClaude(home: FileManager.default.homeDirectoryForCurrentUser.path) }
    static func discoverClaude(home: String) -> String? {
        discoverClaude(home: home, systemDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"])
    }
    static func discoverClaude(home: String, systemDirectories: [String]) -> String? {
        // Official native installer first, then package managers that do not use a
        // system prefix. A GUI app does not inherit the login shell's PATH.
        var candidates = [home + "/.local/bin/claude"] + systemDirectories.prefix(2).map { $0 + "/claude" } + [
                          home + "/.claude/local/claude", home + "/.npm-global/bin/claude", home + "/.volta/bin/claude",
                          home + "/.bun/bin/claude"] + systemDirectories.dropFirst(2).map { $0 + "/claude" }
        // Try installed Node versions newest first; every candidate must be a file.
        let nvm = home + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm + "/" + $0 + "/bin/claude" }
        return candidates.first { ClientExecutableResolver.isExecutableFile($0) }
    }
    /// npm-style launchers are `#!/usr/bin/env node` scripts; their Node lives next to them.
    static func environment(forExecutable path: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        environment["PATH"] = directory + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return environment
    }
    public static func claude(path: String) async throws -> [AgentSession] {
        try await SessionProcess.detached {
            let data = try SessionProcess.run(path: path, arguments: ["agents", "--json", "--all"])
            return try SessionParser.claude(data)
        }
    }
    public static func codex(path: String) async throws -> [AgentSession] {
        try await codexCatalog(path: path).sessions
    }
    public static func codex(resolver: ClientExecutableResolver) async throws -> [AgentSession] {
        try await codexCatalog(resolver: resolver).sessions
    }
    public static func codexCatalog(resolver: ClientExecutableResolver, prioritySessionIDs: [String] = []) async throws -> CodexSessionCatalog {
        try Task.checkCancellation()
        return try await codexCatalog(path: resolver.resolve(.codex), prioritySessionIDs: prioritySessionIDs)
    }
    public static func codexCatalog(path: String, prioritySessionIDs: [String] = [], home: URL? = nil) async throws -> CodexSessionCatalog {
        try await SessionProcess.detached {
            // Share one budget across proxy discovery and fallback. A newly started
            // server is not evidence of another app-server's live session state.
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            let codexHome =
                home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let discovery = try CodexSessionDiscovery.recentIDs(home: codexHome)
            let socket = codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
            if FileManager.default.fileExists(atPath: socket.path) {
                do { return try SessionProcess.codexCatalog(path: path, proxy: true, prioritySessionIDs: prioritySessionIDs, timeout: 3, discovery: discovery) }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SessionError.timeout }
            return try SessionProcess.codexCatalog(path: path, proxy: false, prioritySessionIDs: prioritySessionIDs, timeout: remaining, discovery: discovery)
        }
    }
    public static func legacyEvents(catalog: [AgentSession], now: Date = Date()) -> [AgentSession] {
        guard !Task.isCancelled else { return [] }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/statusbar/state.d")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        let codexIDs = Set(catalog.filter { $0.provider == .codex }.map(\.sessionID))
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard !Task.isCancelled else { return nil }
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
            return AgentSession(
                provider: provider, sessionID: id, title: SessionParser.text(row["project"]), cwd: cwd, client: client,
                phase: phase, updatedAt: Date(timeIntervalSince1970: ts), observedAt: Date(timeIntervalSince1970: ts),
                evidence: .legacy, tool: SessionParser.text(row["tool"]))
        }
    }
}

/// Version-one local metadata fallback: only directory entries and the upstream
/// rollout timestamp/UUID filename shape are read, never rollout bodies or SQLite.
/// Ordinary thread/list excludes empty-preview threads, including Desktop-created
/// peer tasks without thread_spawn_edges; hydrate these candidates through thread/read.
/// Creation-date directories are searched newest first within fixed budgets; an
/// older task resumed recently may fall outside this format-limited supplement.
enum CodexSessionDiscovery {
    struct Result: Sendable {
        let ids: [String]
        let isComplete: Bool
        static let empty = Result(ids: [], isComplete: true)
    }
    private static let filename = try! NSRegularExpression(
        pattern:
            #"^rollout-([0-9]{4})-([0-9]{2})-([0-9]{2})T(?:[01][0-9]|2[0-3])-[0-5][0-9]-[0-5][0-9]-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$"#
    )

    static func recentIDs(home: URL, maximumEntries: Int = 4096, maximumCandidates: Int = 256,
                          deadline: TimeInterval? = nil, uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> Result {
        try Task.checkCancellation()
        let endsAt = deadline ?? uptime() + 0.25
        let manager = FileManager.default, suppliedRoot = home.appendingPathComponent("sessions")
        guard manager.fileExists(atPath: suppliedRoot.path) else { return .empty }
        guard let rootValues = try? suppliedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return Result(ids: [], isComplete: false) }
        let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
        var visited = 0, complete = true, ids: [String] = [], seen = Set<String>()
        func contents(_ directory: URL) throws -> [(URL, URLResourceValues)] {
            try Task.checkCancellation()
            guard uptime() < endsAt, visited < max(0, maximumEntries) else { complete = false; return [] }
            let freshDirectory = URL(fileURLWithPath: directory.path).standardizedFileURL
            guard freshDirectory.path == root.path || freshDirectory.path.hasPrefix(root.path + "/"),
                  freshDirectory.resolvingSymlinksInPath().path == freshDirectory.path,
                  let values = try? freshDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { complete = false; return [] }
            guard let iterator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, _ in complete = false; return false }) else {
                complete = false; return []
            }
            var entries: [(URL, URLResourceValues)] = []
            while let file = iterator.nextObject() as? URL {
                try Task.checkCancellation()
                guard uptime() < endsAt, visited < max(0, maximumEntries) else { complete = false; break }
                visited += 1
                guard file.standardizedFileURL.path.hasPrefix(root.path + "/"),
                      let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isSymbolicLink != true else { continue }
                entries.append((file, values))
            }
            return entries
        }
        func directories(_ parent: URL, digits: Int, range: ClosedRange<Int>) throws -> [URL] {
            try contents(parent).compactMap { url, values in
                let name = url.lastPathComponent
                guard values.isDirectory == true, name.utf8.count == digits,
                      name.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(name), range.contains(number) else { return nil }
                return url
            }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        scan: for year in try directories(root, digits: 4, range: 1970...9999) {
            for month in try directories(year, digits: 2, range: 1...12) {
                for day in try directories(month, digits: 2, range: 1...31) {
                    let parts = DateComponents(year: Int(year.lastPathComponent), month: Int(month.lastPathComponent), day: Int(day.lastPathComponent))
                    let calendar = Calendar(identifier: .gregorian)
                    guard let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day], from: date) == parts else { continue }
                    let entries = try contents(day).sorted {
                        let left = $0.1.contentModificationDate ?? .distantPast, right = $1.1.contentModificationDate ?? .distantPast
                        return left == right ? $0.0.lastPathComponent > $1.0.lastPathComponent : left > right
                    }
                    for (file, values) in entries where values.isRegularFile == true {
                        try Task.checkCancellation()
                        guard uptime() < endsAt else { complete = false; break scan }
                        let name = file.lastPathComponent
                        guard let match = filename.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                              let idRange = Range(match.range(at: 4), in: name),
                              name.hasPrefix("rollout-\(year.lastPathComponent)-\(month.lastPathComponent)-\(day.lastPathComponent)T"),
                              let uuid = UUID(uuidString: String(name[idRange])) else { continue }
                        let id = uuid.uuidString.lowercased()
                        guard seen.insert(id).inserted else { continue }
                        guard ids.count < max(0, maximumCandidates) else { complete = false; break scan }
                        ids.append(id)
                    }
                    if !complete { break scan }
                }
            }
        }
        return Result(ids: ids, isComplete: complete)
    }
}

enum SessionProcess {
    /// Synchronous pipe/PTY work stays off the caller's actor, while cancellation
    /// follows the detached worker and remains CancellationError at the boundary.
    static func detached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await worker.value
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { worker.cancel() }
    }
    /// Own only this configured child. Cleanup is bounded even if it ignores TERM;
    /// it never waits for descendants or signals a user's independent client.
    static func withRunningProcess<T>(_ process: Process, operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try process.run()
        defer { stop(process) }
        try Task.checkCancellation()
        do {
            let result = try operation()
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let gracefulEnd = ProcessInfo.processInfo.systemUptime + 0.3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < gracefulEnd { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let hardEnd = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < hardEnd { Thread.sleep(forTimeInterval: 0.01) }
    }
    static func withProcess<T>(path: String, arguments: [String], timeout: TimeInterval = 12, operation: (Process, Pipe, Pipe, TimeInterval) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: path) else { throw SessionError.unavailable }
        let runtimeLauncher = arguments.first == "app-server" ? CodexRuntimeReader.ExecutableIdentity(path) : nil
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = SessionSources.environment(forExecutable: path)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        return try withRunningProcess(process) {
            let result = try operation(process, input, output, ProcessInfo.processInfo.systemUptime + timeout)
            try Task.checkCancellation()
            // The app-server callers validate the protocol response before returning.
            // Observe our own child before cleanup; never launch an extra probe.
            if let runtimeLauncher { CodexRuntimeReader.rememberRuntime(launcher: runtimeLauncher, process: process) }
            return result
        }
    }
    /// A descendant can keep stdout open after the direct child exits. Bound the
    /// reads themselves, rather than relying on terminating the direct child.
    static func readChunk(_ handle: FileHandle, until deadline: TimeInterval) throws -> Data {
        let fd = handle.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 65536)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return Data() }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw SessionError.invalidResponse }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 50)
        }
        try Task.checkCancellation()
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
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SessionError.timeout }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard process.terminationStatus == 0 else { throw process.terminationReason == .uncaughtSignal ? SessionError.timeout : SessionError.invalidResponse }
            return result
        }
    }
    static func codexCatalog(path: String, proxy: Bool, prioritySessionIDs: [String] = [], timeout: TimeInterval = 12, maxPages: Int = 8,
                             discovery: CodexSessionDiscovery.Result = .empty) throws -> CodexSessionCatalog {
        try withProcess(path: path, arguments: proxy ? ["app-server", "proxy"] : ["app-server", "--stdio"], timeout: timeout) { _, input, output, deadline in
            func send(_ value: [String: Any], until requestDeadline: TimeInterval) throws {
                var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
                try writeCodexInput(bytes, to: input.fileHandleForWriting, until: min(deadline, requestDeadline))
            }
            var buffer = Data(), total = 0, nextID = 1
            func request(_ method: String, _ params: [String: Any], _ requestDeadline: TimeInterval) throws -> [String: Any] {
                try Task.checkCancellation()
                let expectedID = nextID; nextID += 1
                guard ProcessInfo.processInfo.systemUptime < min(deadline, requestDeadline) else { throw SessionError.timeout }
                try send(["id": expectedID, "method": method, "params": params], until: requestDeadline)
                while true {
                    while let newline = buffer.firstIndex(of: 10) {
                        try Task.checkCancellation()
                        let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              message["id"] as? Int == expectedID else { continue }
                        // Notifications and late replies to a timed-out priority read
                        // must not complete the current request.
                        return try ClientResponseContract.codexResult(message, capability: method == "initialize" ? .initialization : .sessionCatalog)
                    }
                    let chunk = try readChunk(output.fileHandleForReading, until: min(deadline, requestDeadline))
                    guard !chunk.isEmpty else { throw SessionError.timeout }
                    total += chunk.count; guard total < 8_000_000 else { throw SessionError.invalidResponse }; buffer.append(chunk)
                }
            }
            _ = try request("initialize", ["clientInfo": ["name": "lunavect_sessions", "version": "0.1.0"]], deadline)
            try send(["method": "initialized"], until: deadline)
            return try readCodexCatalog(prioritySessionIDs: prioritySessionIDs, maxPages: maxPages, discovery: discovery, deadline: deadline, request: request)
        }
    }

    /// A long opaque cursor can fill stdin when the server stops reading. Bound
    /// writes as well as reads, including when a descendant retains the pipe.
    static func writeCodexInput(_ data: Data, to handle: FileHandle, until deadline: TimeInterval) throws {
        try Task.checkCancellation()
        let fd = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw SessionError.invalidResponse }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SessionError.timeout }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                guard count < 0 else { throw SessionError.invalidResponse }
                if errno == EINTR { continue }
                // EPIPE is reported here without changing SIGPIPE handling for the app.
                guard errno == EAGAIN || errno == EWOULDBLOCK else { throw SessionError.invalidResponse }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SessionError.timeout }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&descriptor, 1, Int32(max(1, min(50, ceil(remaining * 1000)))))
                guard polled >= 0 || errno == EINTR,
                      descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw SessionError.invalidResponse }
            }
        }
    }

    /// The injected request/clock are also used by fixture tests. Each request has
    /// its own deadline while the entire catalog remains bounded by one deadline.
    static func readCodexCatalog(prioritySessionIDs: [String] = [], maxPages: Int = 8, maxPriorityReads: Int = 16,
                                 discovery: CodexSessionDiscovery.Result = .empty, maxDiscoveryReads: Int = 32,
                                 deadline: TimeInterval, uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                 request: (String, [String: Any], TimeInterval) throws -> [String: Any]) throws -> CodexSessionCatalog {
        var sessions: [AgentSession] = [], indices: [String: Int] = [:], pagesRead = 0
        try Task.checkCancellation()
        var priorityIDs: [String] = [], seenIDs = Set<String>()
        for id in prioritySessionIDs where SessionParser.validID(id) && seenIDs.insert(id).inserted { priorityIDs.append(id) }
        func append(_ rows: [AgentSession]) {
            for row in rows {
                if let index = indices[row.sessionID] { sessions[index] = row }
                else { indices[row.sessionID] = sessions.count; sessions.append(row) }
            }
        }
        func result(_ reason: CodexSessionCatalog.IncompleteReason? = nil) throws -> CodexSessionCatalog {
            var discoveryLimited = !discovery.isComplete, discoverySeen = Set<String>()
            let missing = discovery.ids.filter { SessionParser.validID($0) && !seenIDs.contains($0) && indices[$0] == nil && discoverySeen.insert($0).inserted }
            let discoveryDeadline = min(deadline, uptime() + 3)
            for (index, id) in missing.enumerated() {
                try Task.checkCancellation()
                guard index < max(0, maxDiscoveryReads), uptime() < discoveryDeadline else { discoveryLimited = true; break }
                do {
                    let reply = try request("thread/read", ["threadId": id, "includeTurns": false], min(discoveryDeadline, uptime() + 1))
                    guard let row = reply["thread"] as? [String: Any], row["id"] as? String == id else { discoveryLimited = true; continue }
                    try ClientResponseContract.validateCodexThreadList(["data": [row]])
                    let parsed = try SessionParser.codex(JSONSerialization.data(withJSONObject: ["data": [row]]))
                    guard parsed.count == 1, parsed.first?.sessionID == id else { discoveryLimited = true; continue }
                    append(parsed)
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); discoveryLimited = true }
            }
            try Task.checkCancellation()
            let unresolved = priorityIDs.filter { indices[$0] == nil }
            return CodexSessionCatalog(sessions: sessions, incompleteReason: reason ?? (unresolved.isEmpty ? nil : .priorityReadIncomplete),
                                       pagesRead: pagesRead, unresolvedPrioritySessionIDs: unresolved, discoveryLimited: discoveryLimited)
        }
        // Reserve at least two thirds of the remaining budget for list pages even
        // when a known thread is deleted or slow to read. This only reads summaries.
        let started = uptime(), priorityDeadline = min(deadline, started + min(3, max(0, deadline - started) / 3))
        for id in priorityIDs.prefix(max(0, maxPriorityReads)) {
            try Task.checkCancellation()
            guard uptime() < priorityDeadline else { break }
            do {
                let reply = try request("thread/read", ["threadId": id, "includeTurns": false], min(priorityDeadline, uptime() + 1))
                guard let row = reply["thread"] as? [String: Any], row["id"] as? String == id else { continue }
                append(try SessionParser.codex(JSONSerialization.data(withJSONObject: ["data": [row]])))
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); continue }
        }
        var cursor: String?, seenCursors = Set<String>()
        while true {
            try Task.checkCancellation()
            guard pagesRead < max(1, maxPages) else { return try result(.pageLimit) }
            guard uptime() < deadline else {
                if sessions.isEmpty && pagesRead == 0 { throw SessionError.timeout }
                return try result(.timeLimit)
            }
            var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "useStateDbOnly": true, "modelProviders": [String](),
                                         "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]]
            if let cursor { params["cursor"] = cursor }
            do {
                let reply = try request("thread/list", params, deadline)
                append(try SessionParser.codex(JSONSerialization.data(withJSONObject: reply)))
                try ClientResponseContract.validateCodexThreadList(reply)
                pagesRead += 1
                if reply["nextCursor"] is NSNull { return try result() }
                guard let next = reply["nextCursor"] as? String, !next.isEmpty, next.utf8.count <= 65536 else { return try result(.invalidResponse) }
                guard seenCursors.insert(next).inserted else { return try result(.repeatedCursor) }
                cursor = next
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                // Keep successful pages on a late timeout or malformed response.
                if sessions.isEmpty && pagesRead == 0 { throw error }
                if case SessionError.timeout = error { return try result(.timeLimit) }
                if case SessionError.invalidResponse = error { return try result(.invalidResponse) }
                if let issue = error as? ClientIntegrationIssue {
                    if issue.reason == .unsupportedResponse { return try result(.invalidResponse) }
                    if issue.reason == .timedOut { return try result(.timeLimit) }
                }
                return try result(.requestFailed)
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
        guard SessionParser.validID(sessionID) else { return "" }
        let command: String
        if provider == .codex { command = "codex resume \(SessionHooks.portableQuote(sessionID))" }
        else if client == .background, let resumeID, SessionParser.validID(resumeID) { command = "claude attach \(SessionHooks.portableQuote(resumeID))" }
        else { command = "claude --resume \(SessionHooks.portableQuote(sessionID))" }
        return cwd.isEmpty || cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? command : "cd -- \(SessionHooks.portableQuote(cwd)) && \(command)"
    }
}
