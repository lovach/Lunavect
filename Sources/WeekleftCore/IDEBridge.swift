import Darwin
import Foundation

/// Local, user-owned IDE endpoints. Messages contain navigation metadata only.
public enum IDEBridge {
    public struct Descriptor: Codable, Equatable, Sendable {
        public let version: Int
        public let id: String
        public let editor: SessionIDE
        public let pid: Int32
        public let appPath: String
        public let bundleIdentifier: String
        public let socketPath: String
        public let updatedAt: Double
        /// The companion's own version (from 0.1.2). Older companions omit it; the
        /// descriptor protocol stays 1 because this field is optional.
        public var companion: String? = nil
    }

    public struct Target: Codable, Equatable, Sendable {
        public let kind: String
        public var ancestors: [Int32]?
        public var sessionID: String?
        public var cwd: String?

        public init(kind: String, ancestors: [Int32]? = nil, sessionID: String? = nil, cwd: String? = nil) {
            self.kind = kind; self.ancestors = ancestors; self.sessionID = sessionID; self.cwd = cwd
        }

        var valid: Bool {
            if kind == "terminal" {
                return ancestors.map { !$0.isEmpty && $0.count <= 24 && $0.allSatisfy { $0 > 1 } } == true
            }
            return ["claude", "codex"].contains(kind) && sessionID.flatMap(UUID.init(uuidString:)) != nil &&
                cwd.map { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } == true
        }
    }

    struct Request: Encodable {
        let version = 1
        let action: String
        let target: Target
    }

    struct Reply: Codable, Sendable {
        let status: String
        var url: String?
        var shellPID: Int32?
    }

    /// One editor endpoint found in the descriptor directory, with what the app can do with it.
    public struct Endpoint: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Fresh heartbeat and a socket: ready for navigation.
            case live
            /// The editor runs and its socket exists, but the heartbeat is late (for example right after sleep).
            case stale
            /// The editor runs, but its socket is missing: the companion cannot be reached.
            case unreachable
            /// The editor runs a companion with a descriptor protocol this app does not speak.
            case incompatible
        }
        public let editor: SessionIDE
        public let bundleIdentifier: String
        public let appPath: String
        public let companion: String?
        public let state: State
        public let descriptor: Descriptor?

        public init(editor: SessionIDE, bundleIdentifier: String, appPath: String, companion: String?,
                    state: State, descriptor: Descriptor?) {
            self.editor = editor; self.bundleIdentifier = bundleIdentifier; self.appPath = appPath
            self.companion = companion; self.state = state; self.descriptor = descriptor
        }
        init(live descriptor: Descriptor) {
            self.init(editor: descriptor.editor, bundleIdentifier: descriptor.bundleIdentifier, appPath: descriptor.appPath,
                      companion: nil, state: .live, descriptor: descriptor)
        }
    }

    /// Everything `open` asks of the system; tests replace it with fixtures.
    struct Environment: Sendable {
        var endpoints: @Sendable () -> [Endpoint]
        var ancestry: @Sendable (SessionProcessIdentity) -> [Int32]
        var exchange: @Sendable (Descriptor, String, Target, TimeInterval, @escaping @Sendable (URL, URL) async -> Bool) async throws -> Reply
        var displayName: @Sendable (IDESessionLocation) -> String

        static let live = Environment(
            endpoints: { IDEBridge.scan() },
            ancestry: { IDEProcessLocation.liveAncestry(of: $0) },
            exchange: { try await IDEBridge.exchange($0, action: $1, target: $2, timeout: $3, openURL: $4) },
            displayName: { IDEProcessLocation.displayName($0) })
    }

    /// Whether the editor runs an older companion than the one bundled with the app.
    public enum CompanionUpdate: Equatable, Sendable {
        case current
        /// `installed` is nil for companions before 0.1.2, which do not report a version.
        case available(installed: String?, bundled: String)
    }

    public static func companionUpdate(installed: String?, bundled: String?) -> CompanionUpdate {
        guard let bundled else { return .current }
        // Companions up to 0.1.1 omit their version; 0.1.1 is the newest of them.
        return compareVersions(installed ?? "0.1.1", bundled) == .orderedAscending ? .available(installed: installed, bundled: bundled) : .current
    }

    static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        let a = left.split(separator: ".").map { Int($0) ?? 0 }, b = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The companion versions bundled with the app, from the packaged manifest.json.
    public static func bundledCompanionVersions(manifest: Data) -> [SessionIDE: String] {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let versions = object["companionVersion"] as? [String: String] else { return [:] }
        var result: [SessionIDE: String] = [:]
        for (key, value) in versions {
            guard let editor = SessionIDE(rawValue: key),
                  value.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){1,3}\z"#, options: .regularExpression) != nil else { continue }
            result[editor] = value
        }
        return result
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lunavect/IDEBridge")
    }

    /// Sockets live in the user's private temporary directory (companions from 0.1.2)
    /// or, for installed 0.1.x companions, in /tmp/lunavect-ide-<uid>. Both stay accepted.
    public static var socketDirectories: [String] {
        var directories = ["/tmp/lunavect-ide-\(getuid())"]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let temporary = String(cString: buffer)
            if temporary.hasPrefix("/") { directories.append((temporary.hasSuffix("/") ? temporary : temporary + "/") + "lunavect") }
        }
        return directories
    }

    /// Endpoint paths are constrained to the current user's private socket directories.
    static func valid(_ descriptor: Descriptor, now: Date = Date(), socketDirectories: [String] = socketDirectories) -> Bool {
        identified(descriptor, socketDirectories: socketDirectories) && fresh(descriptor.updatedAt, now: now)
    }
    static func identified(_ descriptor: Descriptor, socketDirectories: [String]) -> Bool {
        descriptor.version == 1 && UUID(uuidString: descriptor.id) != nil && descriptor.pid > 1 &&
            descriptor.appPath.hasPrefix("/") && descriptor.appPath.hasSuffix(".app") &&
            SessionIDE.identify(bundleIdentifier: descriptor.bundleIdentifier) == descriptor.editor &&
            socketDirectories.contains { descriptor.socketPath == $0 + "/" + descriptor.id + ".sock" } &&
            descriptor.companion.map { $0.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){1,3}\z"#, options: .regularExpression) != nil } != false
    }
    /// Companions rewrite their descriptor every 30 s.
    static func fresh(_ updatedAt: Double, now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - updatedAt
        return age >= -60 && age <= 90
    }

    static func owned(_ path: String, type: mode_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == type else { return false }
        return info.st_mode & 0o077 == 0
    }

    /// Endpoints ready for navigation. Records left by forced quits older than a
    /// day are removed on the way (only the app's own descriptor files).
    public static func descriptors(at directory: URL = directory, now: Date = Date()) -> [Descriptor] {
        scan(at: directory, now: now).filter { $0.state == .live }.compactMap(\.descriptor)
    }

    /// The fields needed to attribute a record to a running editor, whatever its protocol version.
    struct Header: Decodable {
        let version: Int
        let id: String
        let pid: Int32
        let appPath: String
        let bundleIdentifier: String
        let companion: String?
    }

    /// Every descriptor that belongs to a running editor, with what the app can do
    /// with it. Only the user's private files and processes are read.
    public static func scan(at directory: URL = directory, now: Date = Date()) -> [Endpoint] {
        scan(at: directory, now: now, process: IDEProcessLocation.process, bundle: IDEProcessLocation.bundleIdentifier,
             socketDirectories: socketDirectories)
    }

    static func scan(at directory: URL, now: Date, process: (Int32) -> IDEProcessLocation.ProcessInfo?,
                     bundle: (String) -> String?, socketDirectories: [String]) -> [Endpoint] {
        guard owned(directory.path, type: S_IFDIR),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let dated = files.filter { owned($0.path, type: S_IFREG) }.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        func running(_ header: Header) -> String? {
            // The editor must still run from the recorded bundle; a recycled PID of
            // another program never qualifies. Paths are compared after resolving links.
            let appPath = URL(fileURLWithPath: header.appPath).resolvingSymlinksInPath().path
            guard header.pid > 1, header.appPath.hasPrefix("/"), header.appPath.hasSuffix(".app"),
                  let editor = process(header.pid), editor.executable.hasPrefix(appPath + "/Contents/"),
                  bundle(appPath) == header.bundleIdentifier else { return nil }
            return appPath
        }
        // A day without a heartbeat means the editor is gone; remove only files in
        // this app's own format: <uuid>.json descriptors and their heartbeat temporaries.
        let expiry = now.addingTimeInterval(-86_400)
        for (file, modified) in dated where modified < expiry {
            let name = file.lastPathComponent
            let stem = name.hasSuffix(".json.tmp") ? String(name.dropLast(9)) : (file.deletingPathExtension().lastPathComponent)
            guard UUID(uuidString: stem) != nil, ["json", "tmp"].contains(file.pathExtension) else { continue }
            if file.pathExtension == "json" {
                guard let data = read(file), let header = try? JSONDecoder().decode(Header.self, from: data),
                      header.id == stem, running(header) == nil else { continue }
            }
            try? FileManager.default.removeItem(at: file)
        }
        // Heartbeats replace descriptors. Old records left by forced quits must
        // not consume the endpoint budget ahead of currently running editors.
        let recent = dated.filter { $0.0.pathExtension == "json" && $0.1 >= expiry }.sorted { $0.1 > $1.1 }.prefix(64).map(\.0)
        return recent.compactMap { file -> Endpoint? in
            guard let data = read(file), let header = try? JSONDecoder().decode(Header.self, from: data),
                  UUID(uuidString: header.id) != nil, file.deletingPathExtension().lastPathComponent == header.id,
                  let editor = SessionIDE.identify(bundleIdentifier: header.bundleIdentifier),
                  let appPath = running(header) else { return nil }
            guard header.version == 1 else {
                return Endpoint(editor: editor, bundleIdentifier: header.bundleIdentifier, appPath: appPath,
                                companion: nil, state: .incompatible, descriptor: nil)
            }
            guard let record = try? JSONDecoder().decode(Descriptor.self, from: data), record.editor == editor,
                  identified(record, socketDirectories: socketDirectories) else { return nil }
            let socketDirectory = URL(fileURLWithPath: record.socketPath).deletingLastPathComponent().path
            let reachable = owned(socketDirectory, type: S_IFDIR) && owned(record.socketPath, type: S_IFSOCK)
            let state: Endpoint.State = !reachable ? .unreachable : fresh(record.updatedAt, now: now) ? .live : .stale
            return Endpoint(editor: editor, bundleIdentifier: record.bundleIdentifier, appPath: appPath,
                            companion: record.companion, state: state, descriptor: record)
        }
    }

    static func read(_ file: URL) -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16384 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16385)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= 16384 else { return nil }
        return Data(bytes.prefix(count))
    }

    /// Validate the opened file, not only its earlier directory entry. A stale
    /// heartbeat replaced with a FIFO or symlink must never stall discovery.
    static func readDescriptor(from file: URL) -> Descriptor? {
        read(file).flatMap { try? JSONDecoder().decode(Descriptor.self, from: $0) }
    }

    public static func open(_ session: AgentSession,
                            activateApp: @escaping @Sendable (Int32) async -> Bool,
                            openURL: @escaping @Sendable (URL, URL) async -> Bool) async throws {
        try await open(session, activateApp: activateApp, openURL: openURL, environment: .live)
    }

    static func open(_ session: AgentSession,
                     activateApp: @escaping @Sendable (Int32) async -> Bool,
                     openURL: @escaping @Sendable (URL, URL) async -> Bool,
                     environment: Environment) async throws {
        try Task.checkCancellation()
        // A legacy "vscode" label alone does not distinguish a terminal from
        // the provider extension. Require a captured origin before opening either.
        guard let location = session.ideLocation else { throw SessionOpeningError.ideSessionUnavailable(session.client.title) }
        let name = environment.displayName(location)
        let target: Target
        if location.usesTerminal {
            let ancestors = environment.ancestry(location.runtime)
            guard !ancestors.isEmpty else { throw SessionOpeningError.ideSessionUnavailable(name) }
            target = Target(kind: "terminal", ancestors: ancestors)
        } else {
            // An old terminal record without a live process identity cannot be
            // safely reinterpreted as an extension conversation.
            guard session.terminalTTY == nil else { throw SessionOpeningError.ideSessionUnavailable(name) }
            target = Target(kind: session.provider.rawValue, sessionID: session.sessionID, cwd: session.cwd)
        }
        guard target.valid else { throw SessionOpeningError.ideSessionUnavailable(name) }
        let appPath = URL(fileURLWithPath: location.appPath).resolvingSymlinksInPath().path
        let found = try await SessionProcess.detached { environment.endpoints().filter { endpoint in
            endpoint.bundleIdentifier == location.bundleIdentifier &&
                URL(fileURLWithPath: endpoint.appPath).resolvingSymlinksInPath().path == appPath
        } }
        // A late heartbeat (for example right after sleep) with its socket in place is
        // still asked: the socket answers or fails, and peer credentials are checked.
        let endpoints = found.filter { $0.state == .live || $0.state == .stale }.compactMap(\.descriptor)
        guard !endpoints.isEmpty else {
            if found.contains(where: { $0.state == .incompatible }) { throw SessionOpeningError.ideCompanionIncompatible(name) }
            if found.contains(where: { $0.state == .unreachable }) { throw SessionOpeningError.ideBridgeUnresponsive(name) }
            throw SessionOpeningError.ideBridgeMissing(name)
        }
        var matches: [Descriptor] = [], unsupported = false, busy = false, answered = false
        // A busy editor (indexing, a heavy extension host) may need longer than a
        // quick probe; it must be reported as not answering, not as a missing tab.
        let probes = await withTaskGroup(of: (Descriptor, Result<Reply, Error>).self,
                                         returning: [(Descriptor, Result<Reply, Error>)].self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do { return (endpoint, .success(try await environment.exchange(endpoint, "probe", target, probeTimeout, openURL))) }
                    catch { return (endpoint, .failure(error)) }
                }
            }
            var results: [(Descriptor, Result<Reply, Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        try Task.checkCancellation()
        for (endpoint, result) in probes {
            switch result {
            case .success(let reply):
                answered = true
                if reply.status == "matched" { matches.append(endpoint) }
                if reply.status == "ambiguous" { throw SessionOpeningError.ideAmbiguous(name) }
                if ["missingProvider", "unsupportedProvider", "unsupported"].contains(reply.status) { unsupported = true }
                if ["busy", "timeout"].contains(reply.status) { busy = true }
            case .failure(let error):
                if error is CancellationError { throw error }
                if error as? SessionError == .timeout { busy = true }
            }
        }
        guard matches.count <= 1 else { throw SessionOpeningError.ideAmbiguous(name) }
        guard let endpoint = matches.first else {
            if busy { throw SessionOpeningError.ideTimedOut(name) }
            if !answered { throw SessionOpeningError.ideBridgeUnresponsive(name) }
            throw unsupported ? SessionOpeningError.ideUnsupported(name) : SessionOpeningError.ideSessionUnavailable(name)
        }
        // Swing's toFront selects an IDE project window, but macOS does not
        // grant a background Java application foreground focus from that alone.
        if endpoint.editor == .jetbrains {
            let activated = await activateApp(endpoint.pid)
            try Task.checkCancellation()
            guard activated else { throw SessionOpeningError.ideActivationFailed(name) }
        }
        try Task.checkCancellation()
        let reply: Reply
        do { reply = try await environment.exchange(endpoint, "open", target, 10, openURL) }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw SessionOpeningError.ideTimedOut(name)
        }
        try Task.checkCancellation()
        switch reply.status {
        case "focused": return
        case "ambiguous": throw SessionOpeningError.ideAmbiguous(name)
        case "unsupported", "missingProvider", "unsupportedProvider": throw SessionOpeningError.ideUnsupported(name)
        case "timeout": throw SessionOpeningError.ideTimedOut(name)
        default: throw SessionOpeningError.ideSessionUnavailable(name)
        }
    }

    /// A probe only reads editor state, but a busy editor may need a few seconds.
    static let probeTimeout: TimeInterval = 5

    static func exchange(_ descriptor: Descriptor, action: String, target: Target, timeout: TimeInterval,
                         openURL: @escaping @Sendable (URL, URL) async -> Bool) async throws -> Reply {
        let connection = try await SessionProcess.detached { try Connection(path: descriptor.socketPath, timeout: timeout) }
        defer { connection.closeConnection() }
        try await SessionProcess.detached { try connection.send(JSONEncoder().encode(Request(action: action, target: target))) }
        let first = try await SessionProcess.detached { try connection.receive() }
        guard first.status == "ready" else { return first }
        guard action == "open", descriptor.editor == .vscode,
              let text = first.url, let url = URL(string: text), validCallback(url) else { throw SessionError.invalidResponse }
        try Task.checkCancellation()
        let opened = await openURL(url, URL(fileURLWithPath: descriptor.appPath))
        try Task.checkCancellation()
        guard opened else { throw SessionError.invalidResponse }
        return try await SessionProcess.detached { try connection.receive() }
    }

    static func validCallback(_ url: URL) -> Bool {
        ["vscode", "vscode-insiders"].contains(url.scheme ?? "") && url.host == "lovach.lunavect" &&
            url.path.hasPrefix("/focus/") && UUID(uuidString: String(url.path.dropFirst("/focus/".count))) != nil &&
            url.user == nil && url.password == nil && url.port == nil && url.absoluteString.utf8.count <= 4096
    }

    /// One serial request per connection; no UI work or persistent polling thread.
    final class Connection: @unchecked Sendable {
        private var fd: Int32
        private let deadline: TimeInterval
        private let uptime: @Sendable () -> TimeInterval
        private var buffer = Data()

        init(path: String, timeout: TimeInterval,
             uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
            try Task.checkCancellation()
            guard timeout.isFinite, timeout > 0 else { throw SessionError.timeout }
            self.uptime = uptime
            deadline = uptime() + timeout
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SessionError.unavailable }
            var one: Int32 = 1
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
                  fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                closeConnection(); throw SessionError.unavailable
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { closeConnection(); throw SessionError.invalidResponse }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { closeConnection(); throw SessionError.unavailable }
                do {
                    try wait(POLLOUT)
                    var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw SessionError.unavailable }
                } catch { closeConnection(); throw error }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { closeConnection(); throw SessionError.unavailable }
        }

        deinit { closeConnection() }
        func closeConnection() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

        private func checkActive() throws -> TimeInterval {
            try Task.checkCancellation()
            guard fd >= 0 else { throw SessionError.unavailable }
            let remaining = deadline - uptime()
            guard remaining > 0 else { throw SessionError.timeout }
            return remaining
        }

        private func wait(_ events: Int32) throws {
            while true {
                let remaining = try checkActive()
                var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
                // Short polling slices let cancellation reach the owning worker;
                // one monotonic deadline covers connect, writes and all replies.
                let result = poll(&descriptor, 1, Int32(max(1, min(50, ceil(remaining * 1000)))))
                let pollError = errno
                _ = try checkActive()
                if result < 0, pollError == EINTR { continue }
                guard result >= 0 else { throw SessionError.unavailable }
                if result == 0 { continue }
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw SessionError.unavailable }
                // Drain a final frame even when the peer closed after writing it.
                if descriptor.revents & Int16(events) != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP) != 0 { throw SessionError.unavailable }
            }
        }

        func send(_ message: Data) throws {
            _ = try checkActive()
            guard message.count <= 16384 else { throw SessionError.invalidResponse }
            let data = message + Data([10])
            var offset = 0
            while offset < data.count {
                try wait(POLLOUT)
                let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if sent < 0, errno == EAGAIN || errno == EINTR { continue }
                guard sent > 0 else { throw SessionError.unavailable }
                offset += sent
            }
        }

        func receive() throws -> Reply {
            while true {
                _ = try checkActive()
                if let newline = buffer.firstIndex(of: 10) {
                    guard newline <= 16384 else { throw SessionError.invalidResponse }
                    let data = buffer[..<newline]; buffer.removeSubrange(...newline)
                    return try JSONDecoder().decode(Reply.self, from: data)
                }
                guard buffer.count <= 16384 else { throw SessionError.invalidResponse }
                try wait(POLLIN)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0, errno == EAGAIN || errno == EINTR { continue }
                guard count > 0 else { throw SessionError.unavailable }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
    }
}
