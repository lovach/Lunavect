import Foundation
import Darwin
import CryptoKit

// Local lifecycle metadata is a fallback when Desktop exposes no shared server.
// Decode only these fields; never retain messages, reasoning, tool arguments or outputs.
struct CodexActivityEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload
    struct Payload: Decodable {
        let type: String?
        let turn_id: String?
        let thread_id: String?
        let item: Item?
    }
    struct Item: Decodable { let type: String? }
}

struct CodexActivityState {
    var turnID: String?
    var phase: SessionPhase = .unknown
    var observedAt = Date.distantPast
    var startedAt: Date?

    private static let lifecycleTypes: Set<String> = ["task_started", "task_complete", "turn_aborted", "item_started", "item_completed"]
    private static let eventMarker = Data("event_msg".utf8)
    // "task_" covers task_started/task_complete; "item_" and "turn_aborted" the rest.
    private static let lifecycleMarkers = ["task_", "item_", "turn_aborted"].map { Data($0.utf8) }
    mutating func consume(_ data: Data, sessionID: String) {
        // Most lines are large transcript records. A lifecycle event must contain
        // both markers, so skip JSON decoding for lines that cannot match.
        guard data.range(of: Self.eventMarker) != nil,
              Self.lifecycleMarkers.contains(where: { data.range(of: $0) != nil }),
              let event = try? JSONDecoder().decode(CodexActivityEvent.self, from: data),
              event.type == "event_msg", let type = event.payload.type,
              // Most archive lines are transcript events. Reject them before
              // allocating date formatters; only lifecycle dates affect state.
              Self.lifecycleTypes.contains(type),
              let time = Self.date(event.timestamp), time >= observedAt,
              event.payload.thread_id == nil || event.payload.thread_id == sessionID else { return }
        let id = event.payload.turn_id
        switch type {
        case "task_started":
            turnID = id; phase = .running; startedAt = time
        case "task_complete", "turn_aborted":
            guard turnID == nil || id == nil || turnID == id else { return }
            turnID = id; phase = type == "task_complete" ? .ready : .interrupted
        case "item_started", "item_completed":
            guard let id else { return }
            guard turnID == nil || turnID == id else { return }
            // A late item cannot revive a turn already marked complete.
            if turnID == id && [.ready, .interrupted].contains(phase) { return }
            if turnID != id { turnID = id; startedAt = nil }
            phase = .running
        default: return
        }
        observedAt = time
    }
    // ISO8601DateFormatter is safe to share for parsing once configured.
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
    nonisolated(unsafe) private static let wholeSecondDates = ISO8601DateFormatter()
    private static func date(_ value: String) -> Date? {
        fractionalDates.date(from: value) ?? wholeSecondDates.date(from: value)
    }
    func session(from catalog: AgentSession) -> AgentSession? {
        guard phase != .unknown else { return nil }
        var row = catalog
        row.phase = phase; row.observedAt = observedAt; row.updatedAt = observedAt
        row.evidence = .localEvent; row.runtimeConfirmed = true
        row.turnStartedAt = startedAt; row.tool = nil
        return row
    }
}

public actor CodexActivityReader {
    public static let shared = CodexActivityReader()
    private struct Cursor {
        var path: String
        var file: FileMetadata
        var checkpoint: ContentCheckpoint?
        var offset: UInt64 = 0
        var pending = Data()
        var state = CodexActivityState()
        var client: SessionClient = .unknown
        var historyBoundary: UInt64 = 0
        var startSearch: TurnStartSearch?
    }
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let createdSeconds: Int
        let createdNanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino
            createdSeconds = info.st_birthtimespec.tv_sec; createdNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }
    private struct FileMetadata: Equatable {
        let identity: FileIdentity
        let count: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init?(_ handle: FileHandle) {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
            self.init(info)
        }
        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            self.init(info)
        }
        private init?(_ info: stat) {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return nil }
            identity = FileIdentity(info); count = UInt64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }
    /// Detect truncate-and-regrow between polls with bounded I/O, including when
    /// the new length exceeds the old offset. Retain digests, never transcript bytes.
    private struct ContentCheckpoint: Equatable {
        let offset: UInt64
        let prefix: SHA256.Digest
        let boundary: SHA256.Digest
        init(_ handle: FileHandle, offset: UInt64) throws {
            self.offset = offset
            let size = Int(min(offset, 4_096))
            func digest(at position: UInt64) throws -> SHA256.Digest {
                try handle.seek(toOffset: position)
                let bytes = try handle.read(upToCount: size) ?? Data()
                guard bytes.count == size else { throw CocoaError(.fileReadCorruptFile) }
                return SHA256.hash(data: bytes)
            }
            prefix = try digest(at: 0)
            boundary = offset <= 4_096 ? prefix : try digest(at: offset - UInt64(size))
        }
        func matches(_ handle: FileHandle) throws -> Bool { try self == ContentCheckpoint(handle, offset: offset) }
    }
    private struct Origin: Decodable {
        let type: String
        let payload: Metadata
        struct Metadata: Decodable { let id: String; let originator: String? }
    }
    private var cursors: [String: Cursor] = [:]
    private let root: URL
    private let writerPaths: @Sendable (Set<String>, String?) -> Set<String>
    /// The executable chosen through ClientExecutableResolver, if any.
    private var executable: String?
    public init(home: URL? = nil) {
        let home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        root = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
        writerPaths = { CodexRuntimeReader.writablePaths($0, executable: $1) }
    }
    init(home: URL, writerPaths: @escaping @Sendable (Set<String>) -> Set<String>) {
        root = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
        self.writerPaths = { paths, _ in writerPaths(paths) }
    }
    /// A manually selected Codex installation must also be able to confirm live writers.
    public func useExecutable(_ path: String?) { executable = path }
    public func events(catalog: [AgentSession], now: Date? = nil) -> [AgentSession] {
        guard !Task.isCancelled else { return [] }
        let rows = catalog.filter { $0.provider == .codex }
        let ids = Set(rows.map(\.sessionID))
        cursors = cursors.filter { ids.contains($0.key) }
        var recoveryBudget = 8_000_000
        var observations: [String: FileMetadata] = [:]
        var events: [AgentSession] = rows.compactMap { row in
            // Header/tail reads create temporary Foundation buffers. Drain them
            // after each file; a large catalog must not retain every read until
            // the actor finishes the entire batch. Cursor state remains retained.
            autoreleasepool { () -> AgentSession? in
                guard !Task.isCancelled else { return nil }
                // Most catalog rows are finished history. A journal unchanged since its
                // last complete read yields the same state without reopening it.
                if let path = row.activityPath, let cursor = cursors[row.sessionID], cursor.path == path,
                   cursor.offset == cursor.file.count,
                   !(cursor.state.phase == .running && cursor.state.startedAt == nil),
                   let current = FileMetadata(path: path), current == cursor.file {
                    observations[row.sessionID] = current
                    var event = cursor.state.session(from: row)
                    if cursor.client != .unknown { event?.client = cursor.client }
                    return event
                }
                guard let path = row.activityPath,
                      let file = validFile(path, id: row.sessionID),
                      let handle = try? FileHandle(forReadingFrom: file) else {
                    cursors.removeValue(forKey: row.sessionID)
                    return nil
                }
                defer { try? handle.close() }
                // Identity and length must describe the descriptor that we actually
                // read, including backward recovery, not a path resolved before open.
                guard let metadata = FileMetadata(handle) else {
                    cursors.removeValue(forKey: row.sessionID)
                    return nil
                }
                let count = metadata.count
                var cursor = cursors[row.sessionID] ?? Cursor(path: path, file: metadata)
                do {
                    try Task.checkCancellation()
                    if cursor.path != path || cursor.file.identity != metadata.identity || cursor.offset > count ||
                        (cursor.offset == count && cursor.file != metadata) {
                        cursor = Cursor(path: path, file: metadata)
                    } else if cursor.file != metadata, let checkpoint = cursor.checkpoint, try !checkpoint.matches(handle) {
                        cursor = Cursor(path: path, file: metadata)
                    }
                    let previousCheckpoint = cursor.checkpoint
                    let checkpoint: ContentCheckpoint
                    if cursor.file == metadata, let saved = cursor.checkpoint, saved.offset == count { checkpoint = saved }
                    else { checkpoint = try ContentCheckpoint(handle, offset: count) }
                    try handle.seek(toOffset: 0)
                    if cursor.offset == 0 {
                        let header = try handle.read(upToCount: 1_000_000) ?? Data()
                        let origin = header.firstIndex(of: 10).flatMap {
                            try? JSONDecoder().decode(Origin.self, from: Data(header.prefix(upTo: $0)))
                        }
                        // A segmented filename carries both thread and segment IDs.
                        // Confirm the thread from the bounded header before reading
                        // lifecycle events that may omit thread_id.
                        if !file.lastPathComponent.hasSuffix("-\(row.sessionID).jsonl"),
                           origin?.type != "session_meta" || origin?.payload.id != row.sessionID {
                            cursors.removeValue(forKey: row.sessionID)
                            return nil
                        }
                        if let origin, origin.type == "session_meta", origin.payload.id == row.sessionID,
                           ["Codex Desktop", "codex_work_desktop"].contains(origin.payload.originator) {
                            cursor.client = .desktop
                        }
                        // History untouched for over a day cannot yield a fresh lifecycle
                        // event; the merge would discard it. Start at its end so launch does
                        // not scan up to 8 MB of every old thread, and read only appended work.
                        if Date().timeIntervalSince1970 - Double(metadata.modifiedSeconds) > 86400 {
                            cursor.offset = count; cursor.file = metadata; cursor.checkpoint = checkpoint
                            cursors[row.sessionID] = cursor
                            return nil
                        }
                    }
                    // Bound startup and recovery reads, then only consume appended bytes.
                    let start = max(cursor.offset, count > 8_000_000 ? count - 8_000_000 : 0)
                    let skipped = start > cursor.offset
                    let previousState = cursor.state
                    if skipped { cursor.pending = Data(); cursor.state = CodexActivityState() }
                    try handle.seek(toOffset: start)
                    var bytes = try handle.read(upToCount: Int(count - start)) ?? Data()
                    guard bytes.count == Int(count - start) else { throw CocoaError(.fileReadCorruptFile) }
                    cursor.offset = start + UInt64(bytes.count)
                    if skipped {
                        if let newline = bytes.firstIndex(of: 10) {
                            // Include the skipped boundary line in backward recovery.
                            cursor.historyBoundary = start + UInt64(newline + 1)
                            bytes.removeSubrange(...newline)
                        } else {
                            cursor.historyBoundary = start
                            bytes.removeAll()
                        }
                    }
                    cursor.pending.append(bytes)
                    var lineStart = cursor.pending.startIndex
                    for newline in cursor.pending.indices where cursor.pending[newline] == 10 {
                        try Task.checkCancellation()
                        cursor.state.consume(Data(cursor.pending[lineStart..<newline]), sessionID: row.sessionID)
                        lineStart = cursor.pending.index(after: newline)
                    }
                    // Compact once, not once per line: initial multi-megabyte reads
                    // must remain linear in the number of bytes.
                    cursor.pending = Data(cursor.pending[lineStart...])
                    if cursor.pending.count > 8_000_000 { cursor.pending.removeAll() }
                    if cursor.state.startedAt == nil, let turn = cursor.state.turnID, turn == previousState.turnID {
                        cursor.state.startedAt = previousState.startedAt
                    }
                    if cursor.state.phase == .running, cursor.state.startedAt == nil, let turn = cursor.state.turnID {
                        if cursor.startSearch?.turnID != turn {
                            cursor.startSearch = TurnStartSearch(turnID: turn, offset: cursor.historyBoundary)
                        }
                        if var search = cursor.startSearch {
                            let recovered = try? search.advance(handle, sessionID: row.sessionID,
                                                                before: cursor.state.observedAt, budget: &recoveryBudget)
                            cursor.state.startedAt = recovered
                            cursor.startSearch = search
                        }
                    } else { cursor.startSearch = nil }
                    try Task.checkCancellation()
                    // Appending while we parse is fine. A concurrent rewrite is not:
                    // discard this observation and retry from an empty cursor next poll.
                    guard let final = FileMetadata(handle), final.identity == metadata.identity, final.count >= count,
                          try (final == metadata || (final.count > count && checkpoint.matches(handle) &&
                               (previousCheckpoint?.matches(handle) ?? true))) else {
                        cursors.removeValue(forKey: row.sessionID)
                        return nil
                    }
                    cursor.file = metadata; cursor.checkpoint = checkpoint
                    cursors[row.sessionID] = cursor
                    observations[row.sessionID] = final
                    var event = cursor.state.session(from: row)
                    if cursor.client != .unknown { event?.client = cursor.client }
                    return event
                } catch is CancellationError {
                    // No partially consumed cursor is committed; a later refresh can retry.
                    return nil
                } catch {
                    cursors.removeValue(forKey: row.sessionID)
                    return nil
                }
            }
        }
        // Only an unfinished lifecycle plus a writable handle held by Codex can
        // bridge silent reasoning. A running app or a file's mtime is insufficient.
        // Probe once per batch, only as events approach their freshness limit.
        // Initial bounded reads of large histories can take several seconds.
        // Date the live observation after those reads, not at method entry.
        let now = now ?? Date()
        guard !Task.isCancelled else { return [] }
        let paths = Set(events.filter { $0.phase == .running && now.timeIntervalSince($0.observedAt) >= 90 }.compactMap(\.activityPath))
        let live = paths.isEmpty ? [] : writerPaths(paths, executable)
        guard !Task.isCancelled else { return [] }
        // The writer probe may race a rename. Never attach the replacement's
        // live writer to lifecycle state read through the previous descriptor.
        events.removeAll { event in
            guard let cursor = cursors[event.sessionID], let observed = observations[event.sessionID],
                  isCurrent(cursor, observed: observed) else {
                cursors.removeValue(forKey: event.sessionID)
                return true
            }
            return false
        }
        for i in events.indices where events[i].phase == .running {
            if let path = events[i].activityPath, live.contains(path) {
                events[i].runtimeObservedAt = now
            }
        }
        return events
    }
    private func isCurrent(_ cursor: Cursor, observed: FileMetadata) -> Bool {
        guard let current = FileMetadata(path: cursor.path), current.identity == observed.identity else { return false }
        if current == observed { return true }
        // A writer can append during its own probe. Validate continuity instead
        // of dropping every observation of a busy log; rewrites still invalidate it.
        guard current.count > observed.count, let checkpoint = cursor.checkpoint,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: cursor.path)) else { return false }
        defer { try? handle.close() }
        return FileMetadata(handle) == current && (try? checkpoint.matches(handle)) == true &&
            FileMetadata(handle) == current && FileMetadata(path: cursor.path) == current
    }
    private func validFile(_ path: String, id: String) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let stem = file.deletingPathExtension().lastPathComponent
        let segment = stem.range(of: "-\(id)_", options: .backwards).flatMap {
            UUID(uuidString: String(stem[$0.upperBound...]))
        }
        guard file.path.hasPrefix(root.path + "/"), file.pathExtension == "jsonl",
              file.lastPathComponent.hasSuffix("-\(id).jsonl") || segment != nil,
              file.resolvingSymlinksInPath().path == file.path else { return nil }
        return file
    }

    /// Recover only the exact current turn's start, in bounded backward chunks.
    /// Large message/tool lines are discarded; no transcript is decoded or cached.
    private struct TurnStartSearch {
        let turnID: String
        var offset: UInt64
        var suffix = Data()
        var discardingLongLine = false
        private static let marker = Data("task_started".utf8)
        private static let maximumLine = 65_536

        mutating func advance(_ handle: FileHandle, sessionID: String, before: Date, budget: inout Int) throws -> Date? {
            func start(in line: Data) -> Date? {
                guard line.count <= Self.maximumLine, line.range(of: Self.marker) != nil else { return nil }
                var state = CodexActivityState()
                state.consume(line, sessionID: sessionID)
                guard state.turnID == turnID, let time = state.startedAt, time <= before else { return nil }
                return time
            }
            while offset > 0 && budget > 0 && !Task.isCancelled {
                let size = min(262_144, budget, Int(offset))
                let next = offset - UInt64(size)
                try handle.seek(toOffset: next)
                guard var bytes = try handle.read(upToCount: size), bytes.count == size else { return nil }
                offset = next; budget -= size
                bytes.append(suffix)
                var end = bytes.endIndex
                for newline in bytes.indices.reversed() where bytes[newline] == 10 {
                    guard !Task.isCancelled else { return nil }
                    if discardingLongLine { discardingLongLine = false }
                    else if end - newline - 1 <= Self.maximumLine,
                            let time = start(in: Data(bytes[(newline + 1)..<end])) { return time }
                    end = newline
                }
                if next == 0 {
                    return discardingLongLine ? nil : start(in: Data(bytes.prefix(upTo: end)))
                }
                if discardingLongLine || end > Self.maximumLine {
                    suffix.removeAll(keepingCapacity: false); discardingLongLine = true
                } else { suffix = Data(bytes.prefix(upTo: end)) }
            }
            return nil
        }
    }
}

/// Read-only libproc metadata, restricted to this user's Codex processes.
/// Never reads process arguments, environment, memory, or file contents.
enum CodexRuntimeReader {
    /// A wrapper's path can differ from the binary it execs (or starts through Node).
    /// Learn that identity only from our successful app-server child, and forget it
    /// when either file changes. No process arguments or interpreter source is read.
    struct ExecutableIdentity: Equatable, Sendable {
        let path: String
        let resolvedPath: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ path: String) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var info = stat()
            guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            self.path = path; resolvedPath = resolved
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
        var isCurrent: Bool { Self(path) == self }
    }

    private final class RuntimeIdentities: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(launcher: ExecutableIdentity, runtime: ExecutableIdentity)] = []
        func remember(_ launcher: ExecutableIdentity, _ runtime: ExecutableIdentity) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.launcher.path == launcher.path || !$0.launcher.isCurrent || !$0.runtime.isCurrent }
            entries.append((launcher, runtime))
            if entries.count > 8 { entries.removeFirst(entries.count - 8) }
        }
        func paths(for launchers: Set<String>) -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { !$0.launcher.isCurrent || !$0.runtime.isCurrent }
            return Set(entries.filter { launchers.contains($0.launcher.resolvedPath) }.map { $0.runtime.resolvedPath })
        }
    }
    private static let runtimeIdentities = RuntimeIdentities()
    private static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "node", "nodejs", "bun", "deno", "python", "python3", "ruby", "perl"]

    private static func executablePath(_ pid: Int32, names: Set<String>? = nil) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        // Resolving every component costs an lstat each. Skip unrelated processes
        // by name first when scanning all of the user's processes.
        if let names, !names.contains((path as NSString).lastPathComponent) { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func rememberRuntime(launcher: ExecutableIdentity, process: Process) {
        guard !Task.isCancelled, process.isRunning, launcher.isCurrent else { return }
        var pid = process.processIdentifier
        // Follow only a single, unambiguous interpreter child chain. Stop at the
        // native client, never at its tools/helpers, and fail closed on ambiguity.
        for _ in 0..<4 {
            guard !Task.isCancelled, process.isRunning, let path = executablePath(pid) else { return }
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !interpreters.contains(name), !name.hasPrefix("python3.") {
                guard let runtime = ExecutableIdentity(path), launcher.isCurrent else { return }
                runtimeIdentities.remember(launcher, runtime)
                return
            }
            var children = [Int32](repeating: 0, count: 3)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &children, Int32(children.count * MemoryLayout<Int32>.stride))
            guard bytes > 0, bytes < children.count * MemoryLayout<Int32>.stride else { return }
            let live = children.prefix(Int(bytes) / MemoryLayout<Int32>.stride).filter { $0 > 1 }
            guard live.count == 1, let child = live.first else { return }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid == UInt32(pid), info.pbi_uid == getuid() else { return }
            pid = child
        }
    }

    static func writablePaths(_ paths: Set<String>, executable: String? = nil) -> Set<String> {
        guard !Task.isCancelled, !paths.isEmpty else { return [] }
        let launchers = [executable, CodexProvider.discoverCLI()].compactMap { $0 }
        var accepted = Set(launchers.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        accepted.formUnion(runtimeIdentities.paths(for: accepted))
        let candidates: [Int32]
        if let known = clientProcesses.reuse(accepted: accepted, now: ProcessInfo.processInfo.systemUptime) {
            // Client processes are long-lived: between full scans only confirm that
            // each known one still runs the same executable (a PID can be reused).
            candidates = known.filter { executablePath($0.key) == $0.value }.keys.sorted()
        } else {
            guard let found = scanClientProcesses(accepted: accepted, launchers: launchers) else { return [] }
            clientProcesses.store(found, accepted: accepted, now: ProcessInfo.processInfo.systemUptime)
            candidates = found.keys.sorted()
        }
        // Open descriptors are read on every call, so a closed journal is seen at once.
        var result = Set<String>()
        for pid in candidates {
            guard !Task.isCancelled else { return [] }
            result.formUnion(writablePaths(paths.subtracting(result), processID: pid))
            if result == paths { break }
        }
        return result
    }

    private static func scanClientProcesses(accepted: Set<String>, launchers: [String]) -> [Int32: String]? {
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytes > 0, bytes < 1_000_000 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.stride + 128)
        let count = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard count > 0 else { return nil }
        // Candidate names cover the accepted paths, their unresolved launchers and
        // the bundled desktop client; the full resolved-path check below still applies.
        let names = Set((Array(accepted) + launchers).map { ($0 as NSString).lastPathComponent } + ["codex"])
        var found: [Int32: String] = [:]
        for pid in pids.prefix(Int(count) / MemoryLayout<Int32>.stride) where pid > 1 {
            guard !Task.isCancelled else { return nil }
            guard let executable = executablePath(pid, names: names) else { continue }
            guard accepted.contains(executable) || ["/Codex.app/Contents/Resources/codex", "/ChatGPT.app/Contents/Resources/codex"].contains(where: executable.hasSuffix) else { continue }
            found[pid] = executable
        }
        return found
    }

    /// The last full process scan for one accepted executable set. A new client
    /// process is found by the next scan; live writers still need a 90-second-old
    /// lifecycle before they are probed, which leaves ample margin.
    private final class ClientProcesses: @unchecked Sendable {
        static let rescan: TimeInterval = 4
        private let lock = NSLock()
        private var scan: (at: TimeInterval, accepted: Set<String>, processes: [Int32: String])?
        func reuse(accepted: Set<String>, now: TimeInterval) -> [Int32: String]? {
            lock.lock(); defer { lock.unlock() }
            guard let scan, scan.accepted == accepted, now >= scan.at, now - scan.at < Self.rescan else { return nil }
            return scan.processes
        }
        func store(_ processes: [Int32: String], accepted: Set<String>, now: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            scan = (now, accepted, processes)
        }
    }
    private static let clientProcesses = ClientProcesses()

    static func writablePaths(_ paths: Set<String>, processID: Int32) -> Set<String> {
        guard !Task.isCancelled, !paths.isEmpty else { return [] }
        // Kernel paths can use /private/var where Foundation returns /var.
        // Compare device/inode so aliases work and replaced files cannot match.
        var files: [String: stat] = [:]
        for path in paths {
            guard !Task.isCancelled else { return [] }
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { files[path] = info }
        }
        guard !files.isEmpty else { return [] }
        let bytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard bytes > 0, bytes < 1_000_000 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let count = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard count > 0 else { return [] }
        var result = Set<String>()
        for descriptor in descriptors.prefix(Int(count) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            guard !Task.isCancelled else { return [] }
            var info = vnode_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidfdinfo(processID, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &info, size) == size,
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            for (path, file) in files where info.pvi.vi_stat.vst_ino == file.st_ino &&
                info.pvi.vi_stat.vst_dev == UInt32(bitPattern: file.st_dev) {
                result.insert(path)
            }
            if result == paths { break }
        }
        return result
    }
}
