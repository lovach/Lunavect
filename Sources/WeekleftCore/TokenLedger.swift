import Foundation

/// Tokens of one piece of work, split the way Claude and Codex report them.
public struct TokenCounts: Codable, Sendable, Equatable {
    /// Fresh input, not read from the prompt cache.
    public var input: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    /// Visible output; Claude's thinking is part of it.
    public var output: Int64 = 0
    /// Codex reasoning output, reported apart from visible output.
    public var reasoning: Int64 = 0

    public init(input: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output; self.reasoning = reasoning
    }
    private enum CodingKeys: String, CodingKey { case input = "i", cacheRead = "cr", cacheWrite = "cw", output = "o", reasoning = "r" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decodeIfPresent(Int64.self, forKey: .input) ?? 0
        cacheRead = try values.decodeIfPresent(Int64.self, forKey: .cacheRead) ?? 0
        cacheWrite = try values.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0
        output = try values.decodeIfPresent(Int64.self, forKey: .output) ?? 0
        reasoning = try values.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if input != 0 { try values.encode(input, forKey: .input) }
        if cacheRead != 0 { try values.encode(cacheRead, forKey: .cacheRead) }
        if cacheWrite != 0 { try values.encode(cacheWrite, forKey: .cacheWrite) }
        if output != 0 { try values.encode(output, forKey: .output) }
        if reasoning != 0 { try values.encode(reasoning, forKey: .reasoning) }
    }

    public var total: Int64 { input + cacheRead + cacheWrite + output + reasoning }
    public var isEmpty: Bool { total == 0 }
    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input; lhs.cacheRead += rhs.cacheRead; lhs.cacheWrite += rhs.cacheWrite
        lhs.output += rhs.output; lhs.reasoning += rhs.reasoning
    }
    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts { var value = lhs; value += rhs; return value }
    /// Field by field, never below zero: what `self` adds to an earlier reading.
    public func adding(over earlier: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, input - earlier.input), cacheRead: max(0, cacheRead - earlier.cacheRead),
                    cacheWrite: max(0, cacheWrite - earlier.cacheWrite), output: max(0, output - earlier.output),
                    reasoning: max(0, reasoning - earlier.reasoning))
    }
    public func maximum(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input), cacheRead: max(cacheRead, other.cacheRead), cacheWrite: max(cacheWrite, other.cacheWrite),
                    output: max(output, other.output), reasoning: max(reasoning, other.reasoning))
    }
    /// Weighted like list prices: a cache read costs a tenth of fresh input and output several
    /// times more. A share of a subscription limit follows this weight, not the raw count.
    public func weight(_ provider: ProviderID) -> Double {
        let out: Double = provider == .claude ? 5 : 8
        return Double(input) + Double(cacheWrite) * 1.25 + Double(cacheRead) * 0.1 + Double(output + reasoning) * out
    }
}

/// One session's tokens, subagents included.
public struct SessionTokens: Codable, Sendable, Equatable {
    public var provider: ProviderID
    public var sessionID: String
    public var cwd: String
    public var total = TokenCounts()
    /// The part spent by subagents (Claude sidechains, Codex spawned threads).
    public var subagents = TokenCounts()
    public var models: [String: TokenCounts] = [:]
    /// Weighted tokens per hour since 1970, for limit windows and the current rate.
    public var hours: [Int: Double] = [:]
    public var first: Date?
    public var last: Date?
    public init(provider: ProviderID, sessionID: String, cwd: String) { self.provider = provider; self.sessionID = sessionID; self.cwd = cwd }
    public var key: String { TokenLedger.sessionKey(provider, sessionID) }
    public var project: String { cwd.isEmpty ? L("Без проекта") : URL(fileURLWithPath: cwd).lastPathComponent }
    public func weight(from start: Date, to end: Date) -> Double {
        let first = Int(floor(start.timeIntervalSince1970 / 3600)), last = Int(floor(end.timeIntervalSince1970 / 3600))
        return hours.reduce(0) { $1.key >= first && $1.key <= last ? $0 + $1.value : $0 }
    }
    /// Weighted tokens in the last hour, by whole hours: the current one and the part of the previous one.
    public func rate(now: Date) -> Double {
        let position = now.timeIntervalSince1970 / 3600, hour = Int(floor(position))
        return (hours[hour] ?? 0) + (hours[hour - 1] ?? 0) * (1 - (position - Double(hour)))
    }
}

/// Where a file stopped being read, so the next scan reads only what was appended.
struct TokenFileCursor: Codable, Sendable, Equatable {
    var inode: UInt64
    var offset: Int64
    /// Codex: the thread from `session_meta`, its parent for a subagent, its folder and current model.
    var session: String?
    var parent: String?
    var cwd: String?
    var model: String?
    /// Codex: the last cumulative total; the next one adds only the difference.
    var total: TokenCounts?
    /// Claude repeats one response's usage on each of its lines: the last ids seen and their readings,
    /// dropped once the file has been quiet for an hour.
    var seen: [String: TokenCounts]?
    var order: [String]?
}

/// Tokens of every Claude and Codex session on this Mac, read from their local logs.
public struct TokenLedger: Codable, Sendable, Equatable {
    /// Sessions and daily entries are kept this long; older days live on in the archive.
    public static let keepDays = 35
    /// 2: Claude transcripts' written-back copies of earlier responses are no longer counted twice.
    /// 3: nor the copies a resumed or forked session's new transcript starts with; the first pass
    /// no longer loses old days between its slices.
    public static let currentVersion = 3
    public var version: Int? = TokenLedger.currentVersion
    public var sessions: [String: SessionTokens] = [:]
    /// Day key → entry key (provider, project, model, subagent) → tokens. The archive keeps them after pruning.
    public var daily: [String: [String: TokenCounts]] = [:]
    /// True once every log has been read to its end at least once.
    public var caughtUp: Bool? = false
    var cursors: [String: TokenFileCursor] = [:]
    /// Codex threads whose turn the usage limit ended, and when (a `task_complete` with `usage_limit_exceeded`).
    public var limitHits: [String: Date]?
    /// Weighted tokens per provider and minute over the last six hours: a limit's level between two
    /// readings needs what was spent after the reading, not the whole hour it fell in.
    public var recent: [String: [Int: Double]]?
    /// From when `recent` holds every token read: six hours before a fresh ledger's first scan,
    /// or the first scan after an update that added it.
    public var recentFrom: Date?
    public static let recentSpan: TimeInterval = 6 * 3600
    /// Every Claude response counted, by message id, with its day since 1970: Claude Code writes copies of
    /// earlier responses into a transcript again, later in the same file and at the start of a resumed or
    /// forked session's new file (1656 of 93852 responses on the owner's Mac, 30.09). Kept for the whole
    /// first pass, then for the kept window; an older response after it is not counted at all.
    var claudeResponses: [String: Int]?
    public init() {}

    public static func sessionKey(_ provider: ProviderID, _ sessionID: String) -> String { provider.rawValue + ":" + sessionID }
    /// The session's own log among the files read: a Claude transcript named by its id, or the Codex rollout of its thread.
    public func transcript(_ provider: ProviderID, sessionID: String) -> URL? {
        let path: String?
        switch provider {
        case .claude: path = cursors.keys.first { $0.hasSuffix("/" + sessionID + ".jsonl") && !$0.contains("/subagents/") }
        case .codex: path = cursors.first { $0.value.session == sessionID && $0.value.parent == nil }?.key
        default: path = nil
        }
        return path.map(URL.init(fileURLWithPath:))
    }
    /// "provider|project|model|0 or 1": what the archive and statistics group by.
    public static func entryKey(_ provider: ProviderID, project: String, model: String, subagent: Bool) -> String {
        [provider.rawValue, project, model, subagent ? "1" : "0"].joined(separator: "|")
    }
    public struct Entry: Sendable, Equatable {
        public var provider: ProviderID, project: String, model: String, subagent: Bool
    }
    public static func entry(_ key: String) -> Entry? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let provider = ProviderID(rawValue: parts[0]) else { return nil }
        return Entry(provider: provider, project: parts[1], model: parts[2], subagent: parts[3] == "1")
    }

    /// "claude-opus-5-5" → "Opus 5.5"; other names as the client wrote them.
    public static func modelTitle(_ model: String) -> String {
        guard !model.isEmpty, model != "?" else { return L("Модель не указана") }
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", parts[1].allSatisfy(\.isLetter), let major = Int(parts[2]) else { return model }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        // "claude-haiku-4-5-20251001": the date is not a minor version.
        if parts.count >= 4, let minor = Int(parts[3]), minor < 100 { return family + " \(major).\(minor)" }
        return family + " \(major)"
    }

    public struct ScanReport: Sendable, Equatable {
        public var filesRead = 0, bytesRead: Int64 = 0
        /// False when the time or byte budget ended the scan; the next scan continues from the cursors.
        public var complete = true
        public init() {}
    }

    /// Reads what the logs gained since the last scan, most recently changed files first.
    public mutating func scan(sources: [ActivityHistoryImporter.Source] = ActivityHistoryImporter.localSources(), now: Date = Date(),
                              maximumSeconds: TimeInterval = 20, maximumBytes: Int64 = 2_000_000_000, calendar: Calendar = .current,
                              monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> ScanReport {
        var report = ScanReport()
        let deadline = monotonicNow() + maximumSeconds
        if recentFrom == nil { recentFrom = cursors.isEmpty ? now.addingTimeInterval(-Self.recentSpan) : now }
        var files: [(url: URL, modified: Date, size: Int64, inode: UInt64, provider: ProviderID)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var present = Set<String>()
        for source in sources {
            guard let enumerator = FileManager.default.enumerator(at: source.directory, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            while let entry = enumerator.nextObject() as? URL {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, entry.pathExtension == "jsonl" else { continue }
                var info = stat()
                guard lstat(entry.path, &info) == 0 else { continue }
                present.insert(entry.path)
                let size = Int64(info.st_size), inode = UInt64(info.st_ino)
                if let cursor = cursors[entry.path], cursor.inode == inode, cursor.offset >= size {
                    // A file quiet for an hour holds only finished responses: their merge state is not needed.
                    if cursor.seen != nil, now.timeIntervalSince(values.contentModificationDate ?? now) > 3600 {
                        cursors[entry.path]?.seen = nil; cursors[entry.path]?.order = nil
                    }
                    continue
                }
                files.append((entry, values.contentModificationDate ?? .distantPast, size, inode, source.provider))
            }
        }
        // A file that disappeared needs no cursor.
        for path in cursors.keys where !present.contains(path) { cursors.removeValue(forKey: path) }
        files.sort { $0.modified > $1.modified }
        for file in files {
            if monotonicNow() >= deadline || report.bytesRead >= maximumBytes { report.complete = false; break }
            let previous = cursors[file.url.path]
            var cursor = previous.flatMap { $0.inode == file.inode && $0.offset <= file.size ? $0 : nil }
                ?? TokenFileCursor(inode: file.inode, offset: 0)
            // A rollout rewritten at the same path is read again from its start: Codex's cumulative
            // totals then continue from the last one counted (Claude's responses are known by id).
            if cursor.offset == 0, let previous, previous.total != nil {
                cursor.session = previous.session; cursor.parent = previous.parent; cursor.cwd = previous.cwd
                cursor.model = previous.model; cursor.total = previous.total
            }
            let read = read(file.url, provider: file.provider, cursor: &cursor, now: now, calendar: calendar,
                            budget: maximumBytes - report.bytesRead, deadline: deadline, monotonicNow: monotonicNow)
            cursors[file.url.path] = cursor
            report.filesRead += 1; report.bytesRead += read
            if cursor.offset < file.size { report.complete = false }
        }
        // The first pass read the minutes of its early slices only partly: they count from now on.
        if report.complete { if caughtUp != true { recentFrom = now }; caughtUp = true }
        pruneSessions(now: now)
        return report
    }

    /// Reads complete lines from the cursor on; a partial last line waits for the next scan.
    private mutating func read(_ url: URL, provider: ProviderID, cursor: inout TokenFileCursor, now: Date, calendar: Calendar,
                               budget: Int64, deadline: TimeInterval, monotonicNow: () -> TimeInterval) -> Int64 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return 0 }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(cursor.offset)) } catch { return 0 }
        let markers = provider == .claude ? [Data("\"usage\"".utf8)] : [Data("\"token_count\"".utf8), Data("\"session_meta\"".utf8), Data("\"turn_context\"".utf8), Data("\"usage_limit_exceeded\"".utf8)]
        let chunkSize = 2 * 1024 * 1024, longestLine = 16 * 1024 * 1024
        var pending = Data(), bytes: Int64 = 0, skippingLongLine = false
        let fileSession = UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil ? url.deletingPathExtension().lastPathComponent : nil
        let isSubagentFile = url.path.contains("/subagents/")
        while bytes < budget, monotonicNow() < deadline {
            // Each chunk's Foundation objects are released with it: one pass reads gigabytes.
            let more: Bool = autoreleasepool {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            bytes += Int64(chunk.count)
            pending.append(chunk)
            var consumed = 0
            pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count, let newline = memchr(base + start, 10, raw.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    if skippingLongLine { skippingLongLine = false }
                    else if end > start {
                        let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                        if markers.contains(where: { marker in marker.withUnsafeBytes { memmem(line.baseAddress, line.count, $0.baseAddress, $0.count) != nil } }) {
                            // A line of tens of megabytes (a large tool output or written file) is never parsed whole:
                            // Claude's usage and a few short fields are cut out of it; Codex records are small.
                            if line.count <= Self.wholeLineLimit {
                                consume(Data(line), provider: provider, cursor: &cursor, fileSession: fileSession,
                                        subagentFile: isSubagentFile, now: now, calendar: calendar)
                            } else if provider == .claude, let object = Self.claudeEssentials(line) {
                                consume(object, provider: provider, cursor: &cursor, fileSession: fileSession,
                                        subagentFile: isSubagentFile, now: now, calendar: calendar)
                            }
                        }
                    }
                    start = end + 1
                }
                consumed = start
            }
            cursor.offset += Int64(consumed)
            // A fresh buffer for the partial line: removing from the front keeps Data's storage growing with the file.
            pending = consumed < pending.count ? Data(pending[(pending.startIndex + consumed)...]) : Data()
            // A line longer than any usage record carries no tokens: skip to its end.
            if pending.count > longestLine { cursor.offset += Int64(pending.count); pending.removeAll(); skippingLongLine = true }
            return true
            }
            if !more { break }
        }
        return bytes
    }

    /// Lines up to this size are parsed as a whole.
    static let wholeLineLimit = 256 * 1024
    private mutating func consume(_ line: Data, provider: ProviderID, cursor: inout TokenFileCursor, fileSession: String?,
                                  subagentFile: Bool, now: Date, calendar: Calendar) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        consume(object, provider: provider, cursor: &cursor, fileSession: fileSession, subagentFile: subagentFile, now: now, calendar: calendar)
    }

    /// The parts of a large Claude assistant line the ledger needs, as the same shape a full parse gives:
    /// the top-level keys come before `message`, `usage` is the last object in it, `timestamp` is near the end.
    static func claudeEssentials(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        func positions(_ needle: String) -> [Int] {
            var found: [Int] = [], start = 0
            let bytes = Array(needle.utf8)
            while start < line.count, let hit = memmem(base + start, line.count - start, bytes, bytes.count) {
                let index = base.distance(to: UnsafeRawPointer(hit)); found.append(index); start = index + bytes.count
                if found.count > 4096 { break }
            }
            return found
        }
        func first(_ needle: String) -> Int? {
            let bytes = Array(needle.utf8)
            return memmem(base, line.count, bytes, bytes.count).map { base.distance(to: UnsafeRawPointer($0)) }
        }
        /// The JSON string that starts right after `index`, decoded.
        func string(at index: Int) -> String? {
            var end = index, escaped = false
            while end < line.count {
                let byte = line[end]
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { break }
                end += 1
                if end - index > 64 * 1024 { return nil }
            }
            guard end < line.count else { return nil }
            let quoted = Data([34]) + Data(UnsafeRawBufferPointer(rebasing: line[index..<end])) + Data([34])
            return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
        }
        func value(_ key: String, last: Bool = false) -> String? {
            let needle = "\"" + key + "\":\""
            guard let hit = last ? positions(needle).last : first(needle) else { return nil }
            return string(at: hit + needle.utf8.count)
        }
        /// The object whose opening brace is at `index`, parsed on its own.
        func object(at index: Int) -> [String: Any]? {
            var depth = 0, inString = false, escaped = false, end = index
            while end < line.count {
                let byte = line[end]
                if inString {
                    if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }
                } else if byte == 34 { inString = true }
                else if byte == 123 { depth += 1 }
                else if byte == 125 { depth -= 1; if depth == 0 { break } }
                end += 1
                if end - index > 64 * 1024 { return nil }
            }
            guard end < line.count else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(UnsafeRawBufferPointer(rebasing: line[index...end]))) as? [String: Any]
        }
        guard first("\"role\":\"assistant\"") != nil, let usageKey = positions("\"usage\":{").last,
              let usage = object(at: usageKey + 8) else { return nil }
        var message: [String: Any] = ["usage": usage]
        if let key = first("\"message\":{") {
            let rest = UnsafeRawBufferPointer(rebasing: line[key...])
            let idNeedle = Array("\"id\":\"".utf8), modelNeedle = Array("\"model\":\"".utf8)
            if let hit = memmem(rest.baseAddress, rest.count, idNeedle, idNeedle.count) {
                message["id"] = string(at: key + rest.baseAddress!.distance(to: UnsafeRawPointer(hit)) + idNeedle.count)
            }
            if let hit = memmem(rest.baseAddress, rest.count, modelNeedle, modelNeedle.count) {
                message["model"] = string(at: key + rest.baseAddress!.distance(to: UnsafeRawPointer(hit)) + modelNeedle.count)
            }
        }
        var object: [String: Any] = ["type": "assistant", "message": message]
        object["sessionId"] = value("sessionId"); object["cwd"] = value("cwd")
        object["timestamp"] = value("timestamp", last: true); object["requestId"] = value("requestId", last: true)
        if let side = first("\"isSidechain\":true"), side < (first("\"message\":{") ?? side + 1) { object["isSidechain"] = true }
        return object
    }

    private mutating func consume(_ object: [String: Any], provider: ProviderID, cursor: inout TokenFileCursor, fileSession: String?,
                                  subagentFile: Bool, now: Date, calendar: Calendar) {
        let date = (object["timestamp"] as? String).flatMap(Self.date) ?? now
        func int(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
        if provider == .claude {
            guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let model = message["model"] as? String ?? ""
            guard model != "<synthetic>" else { return }
            let reading = TokenCounts(input: int(usage["input_tokens"]), cacheRead: int(usage["cache_read_input_tokens"]),
                                      cacheWrite: int(usage["cache_creation_input_tokens"]), output: int(usage["output_tokens"]))
            let id = message["id"] as? String ?? object["requestId"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
            var seen = cursor.seen ?? [:], order = cursor.order ?? []
            let added: TokenCounts
            if let earlier = seen[id] { let merged = reading.maximum(earlier); added = merged.adding(over: earlier); seen[id] = merged }
            else {
                // A copy of a response counted before, in this file or another one.
                if claudeResponses?[id] != nil { return }
                claudeResponses = claudeResponses ?? [:]
                claudeResponses![id] = Int(floor(date.timeIntervalSince1970 / 86400))
                added = reading; seen[id] = reading; order.append(id)
                if order.count > 64 { seen.removeValue(forKey: order.removeFirst()) }
            }
            cursor.seen = seen; cursor.order = order
            guard let session = object["sessionId"] as? String ?? fileSession else { return }
            let subagent = subagentFile || object["isSidechain"] as? Bool == true
            record(added, provider: .claude, session: session, cwd: object["cwd"] as? String ?? "", model: model,
                   subagent: subagent, at: date, now: now, calendar: calendar)
            return
        }
        guard let payload = object["payload"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "session_meta":
            cursor.session = payload["id"] as? String ?? cursor.session
            if let cwd = payload["cwd"] as? String { cursor.cwd = cwd }
            if let source = payload["source"] as? [String: Any], let subagent = source["subagent"] as? [String: Any],
               let spawn = subagent["thread_spawn"] as? [String: Any], let parent = spawn["parent_thread_id"] as? String { cursor.parent = parent }
        case "turn_context":
            if let model = payload["model"] as? String { cursor.model = model }
            if let cwd = payload["cwd"] as? String, cursor.cwd == nil { cursor.cwd = cwd }
        case "event_msg":
            if payload["type"] as? String == "task_complete" {
                // The limit ended this turn: the error travels with its completion (Codex does not keep the error event).
                if let error = payload["error"] as? [String: Any], error["codex_error_info"] as? String == "usage_limit_exceeded",
                   cursor.parent == nil, let session = cursor.session {
                    var hits = limitHits ?? [:]; hits[Self.sessionKey(.codex, session)] = date; limitHits = hits
                }
                return
            }
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any], let session = cursor.parent ?? cursor.session else { return }
            let cached = int(usage["cached_input_tokens"]), reasoning = int(usage["reasoning_output_tokens"])
            let reading = TokenCounts(input: max(0, int(usage["input_tokens"]) - cached), cacheRead: cached,
                                      cacheWrite: int(usage["cache_write_input_tokens"]),
                                      output: max(0, int(usage["output_tokens"]) - reasoning), reasoning: reasoning)
            let added = reading.adding(over: cursor.total ?? TokenCounts())
            cursor.total = reading
            record(added, provider: .codex, session: session, cwd: cursor.cwd ?? "", model: cursor.model ?? "",
                   subagent: cursor.parent != nil, at: date, now: now, calendar: calendar)
        default: break
        }
    }

    public mutating func record(_ counts: TokenCounts, provider: ProviderID, session: String, cwd: String, model: String,
                         subagent: Bool, at date: Date, now: Date, calendar: Calendar) {
        guard !counts.isEmpty else { return }
        // After the first pass the archive holds the days before the kept window: a response dated
        // there is a copy the window no longer knows, and would overwrite that archived day.
        if caughtUp == true, date < now.addingTimeInterval(-Double(Self.keepDays) * 86400) { return }
        if date >= now.addingTimeInterval(-Self.recentSpan), date <= now.addingTimeInterval(60) {
            if recent == nil { recent = [:] }
            recent![provider.rawValue, default: [:]][Int(floor(date.timeIntervalSince1970 / 60)), default: 0] += counts.weight(provider)
        }
        let project = cwd.isEmpty ? L("Без проекта") : URL(fileURLWithPath: cwd).lastPathComponent
        let day = ActivityArchive.key(date, calendar: calendar)
        daily[day, default: [:]][Self.entryKey(provider, project: project, model: model, subagent: subagent), default: TokenCounts()] += counts
        // Sessions older than the kept window only feed the archive's days.
        guard date >= now.addingTimeInterval(-Double(Self.keepDays) * 86400) else { return }
        let key = Self.sessionKey(provider, session)
        var value = sessions[key] ?? SessionTokens(provider: provider, sessionID: session, cwd: subagent ? "" : cwd)
        if value.cwd.isEmpty, !subagent { value.cwd = cwd }
        value.total += counts
        if subagent { value.subagents += counts }
        value.models[model.isEmpty ? "?" : model, default: TokenCounts()] += counts
        value.hours[Int(floor(date.timeIntervalSince1970 / 3600)), default: 0] += counts.weight(provider)
        value.first = min(value.first ?? date, date); value.last = max(value.last ?? date, date)
        sessions[key] = value
    }

    /// Drops sessions older than the kept window and hours older than eight days.
    public mutating func pruneSessions(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
        let hourCutoff = Int(floor(now.addingTimeInterval(-8 * 86400).timeIntervalSince1970 / 3600))
        sessions = sessions.filter { ($0.value.last ?? .distantPast) >= cutoff }
        limitHits = limitHits?.filter { now.timeIntervalSince($0.value) < 2 * 86400 }
        let oldest = now.addingTimeInterval(-Self.recentSpan), firstMinute = Int(floor(oldest.timeIntervalSince1970 / 60))
        recent = recent?.mapValues { $0.filter { $0.key >= firstMinute } }
        if let from = recentFrom, from < oldest { recentFrom = oldest }
        if caughtUp == true, claudeResponses != nil {
            let firstDay = Int(floor(cutoff.timeIntervalSince1970 / 86400)) - 1
            claudeResponses = claudeResponses?.filter { $0.value >= firstDay }
        }
        for key in sessions.keys { sessions[key]!.hours = sessions[key]!.hours.filter { $0.key >= hourCutoff } }
    }
    /// Drops days older than the kept window. Call after the archive has taken them, and only after the
    /// first pass: until then a day's files can be spread over several slices.
    public mutating func pruneDays(now: Date, calendar: Calendar = .current) {
        guard caughtUp == true else { return }
        let firstDay = ActivityArchive.key(now.addingTimeInterval(-Double(Self.keepDays) * 86400), calendar: calendar)
        daily = daily.filter { $0.key >= firstDay }
    }

    /// Weighted tokens of one provider's sessions in a period, by whole hours.
    /// By minute when the period lies within the last six hours the ledger saw, by whole hours before.
    public func weight(_ provider: ProviderID, from start: Date, to end: Date) -> Double {
        if let recentFrom, start >= recentFrom {
            let first = Int(floor(start.timeIntervalSince1970 / 60)), last = Int(floor(end.timeIntervalSince1970 / 60))
            return (recent?[provider.rawValue] ?? [:]).reduce(0) { $1.key >= first && $1.key <= last ? $0 + $1.value : $0 }
        }
        return sessions.values.reduce(0) { $1.provider == provider ? $0 + $1.weight(from: start, to: end) : $0 }
    }

    /// A session's estimated share of a limit window: the window's used percent split by weighted tokens.
    /// Use outside the command line (a chat in the Claude app) is not in the logs, so this can run high.
    public func limitPercent(of session: SessionTokens, window: QuotaWindow?, now: Date) -> Double? {
        guard let window, let resets = window.resetsAt, window.usedPercent > 0 else { return nil }
        let start = resets.addingTimeInterval(-Double(window.durationMinutes) * 60)
        let total = weight(session.provider, from: start, to: now)
        guard total > 0 else { return nil }
        return window.usedPercent * session.weight(from: start, to: now) / total
    }

    private static let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private static let whole = ISO8601DateFormatter()
    static func date(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/token-ledger.json")
    }
    public static func load(from url: URL = fileURL) throws -> TokenLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return TokenLedger() }
        let value = try JSONDecoder().decode(Self.self, from: LocalStateRecovery.read(from: url, maximumBytes: 64_000_000))
        // A newer or unknown layout is read again from the logs rather than trusted.
        return value.version == currentVersion ? value : TokenLedger()
    }
    public func save(to url: URL = fileURL) throws {
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LocalStateRecovery.write(JSONEncoder().encode(self), to: url, synchronize: false)
    }
}
