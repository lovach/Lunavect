import Foundation
import Darwin

public struct ActivityImportResult: Sendable {
    public var intervals: [ActivityInterval] = []
    public var limited = false
    public var report = ActivityImportReport()
    public var details: [ActivityDetailRecord] = []
    public init() {}
}

/// Reads only local journal timing. Historical durations remain approximate wall time.
public enum ActivityHistoryImporter {
    public static let version = ActivityImportReport.currentVersion
    public struct Source: Sendable {
        public let directory: URL
        public let provider: ProviderID
        public init(directory: URL, provider: ProviderID) { self.directory = directory; self.provider = provider }
    }
    public static func localSources(environment: [String: String] = ProcessInfo.processInfo.environment) -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        return [Source(directory: codex.appendingPathComponent("sessions"), provider: .codex),
                Source(directory: codex.appendingPathComponent("archived_sessions"), provider: .codex),
                Source(directory: claude.appendingPathComponent("projects"), provider: .claude)]
    }
    public static func read(sources: [Source] = localSources(), before boundary: Date, now: Date = Date(),
                            maximumBytes: Int = 8 * 1024 * 1024 * 1024, maximumLineBytes: Int = 4 * 1024 * 1024,
                            maximumSeconds: TimeInterval = 90, maximumIntervals: Int = 100_000) -> ActivityImportResult {
        var result = ActivityImportResult(), bytesRead = 0
        let cutoff = now.addingTimeInterval(-35 * 86400), deadline = ProcessInfo.processInfo.systemUptime + maximumSeconds
        let fractional = ISO8601DateFormatter(), whole = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let codexMarkers = ["task_complete", "task_started", "turn_aborted"].map { Data($0.utf8) }
        let claudeMarkers = ["turn_duration", "tool_use", "totalDurationMs", "durationMs", "durationSeconds"].map { Data($0.utf8) }
        var reports = Dictionary(uniqueKeysWithValues: Set(sources.map(\.provider)).map { ($0, ActivityImportReport.Provider(id: $0)) })
        func issue(_ reason: ActivityImportIssue, _ provider: ProviderID, count: Int = 1) { reports[provider]!.issues[reason, default: 0] += count }
        func exhausted() -> Bool { bytesRead >= maximumBytes || result.intervals.count >= maximumIntervals || ProcessInfo.processInfo.systemUptime > deadline || Task.isCancelled }
        func timestamp(_ value: Any?) -> Date? {
            guard let value = value as? String else { return nil }
            return fractional.date(from: value) ?? whole.date(from: value)
        }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func identifier(_ value: Any?) -> String? { guard let value = value as? String, !value.isEmpty else { return nil }; return value }
        @discardableResult func append(start: Date, end: Date, provider: ProviderID, kind: Int) -> Bool {
            guard start < end, end <= now.addingTimeInterval(2), end.timeIntervalSince(start) <= 35 * 86400 else { issue(.invalidTiming, provider); return false }
            let start = max(start, cutoff), end = min(end, boundary)
            guard start < end else { return false }
            guard result.intervals.count < maximumIntervals else { issue(.budget, provider); return false }
            result.intervals.append(ActivityInterval(start: start, end: end, providers: provider == .claude ? 1 : 2, recovered: true))
            reports[provider]!.recordsRecovered += 1
            if kind == 0 { reports[provider]!.taskRecords += 1 }
            else if kind == 1 { reports[provider]!.agentRecords += 1 }
            else { reports[provider]!.toolRecords += 1 }
            return true
        }
        for source in sources {
            let provider = source.provider
            if exhausted() { issue(.budget, provider); continue }
            let root: URLResourceValues
            do { root = try source.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch {
                let error = error as NSError
                let missing = (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
                // The archive directory is optional, but a permissions error is still reported.
                if !missing || source.directory.lastPathComponent != "archived_sessions" { issue(missing ? .missingSource : .unreadable, provider) }
                continue
            }
            guard root.isSymbolicLink != true else { issue(.symlink, provider); continue }
            guard root.isDirectory == true else { issue(.unreadable, provider); continue }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(at: source.directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in issue(.unreadable, provider); return true }) else { issue(.unreadable, provider); continue }
            var files: [(URL, Date)] = [], visited = 0
            for case let file as URL in enumerator {
                visited += 1
                if visited > 100_000 || exhausted() { issue(.budget, provider); break }
                guard let values = try? file.resourceValues(forKeys: Set(keys)) else { issue(.unreadable, provider); continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); issue(.symlink, provider); continue }
                guard values.isRegularFile == true, file.pathExtension == "jsonl" else { continue }
                guard (values.contentModificationDate ?? now) >= cutoff else { continue }
                files.append((file, values.contentModificationDate ?? .distantPast))
                if files.count >= 20_000 { issue(.budget, provider); break }
            }
            files.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
            for (file, _) in files {
                if exhausted() { issue(.budget, provider); break }
                let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { issue(.unreadable, provider); continue }
                var info = stat()
                guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(descriptor); issue(.unreadable, provider); continue }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                reports[provider]!.filesRead += 1
                let firstInterval = result.intervals.count
                var sessionID: String?, cwd = "", title = ""
                var conflictingIdentity = false, conflictingProject = false
                if provider == .claude, UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil { sessionID = file.deletingPathExtension().lastPathComponent }
                var pending: [String: Date] = [:], calls: [String: (String, Date?)] = [:], completedTools = Set<String>()
                var hadTiming = false, reachedEOF = false
                // Read a fixed snapshot: a running client's later appends are picked up on retry.
                var remaining = max(0, Int(info.st_size))
                func consume(_ line: Data, failure: TimingJSONLReader.Failure?, omitted: Int) {
                    reports[provider]!.longStringsOmitted += omitted
                    if let failure { issue(failure == .tooLarge ? .recordTooLarge : .malformed, provider); return }
                    let markers = provider == .claude ? claudeMarkers : codexMarkers
                    guard markers.contains(where: { line.range(of: $0) != nil }) || ["session_meta", "\"cwd\"", "custom-title"].contains(where: { line.range(of: Data($0.utf8)) != nil }) else { return }
                    guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { issue(.malformed, provider); return }
                    let type = record["type"] as? String, stamp = timestamp(record["timestamp"])
                    let metadata = provider == .codex && type == "session_meta" ? (record["payload"] as? [String: Any] ?? [:]) : provider == .claude ? record : [:]
                    if let raw = metadata[provider == .codex ? "id" : "sessionId"] as? String, SessionParser.validID(raw) {
                        if let previousID = sessionID, previousID != raw { conflictingIdentity = true }
                        else { sessionID = raw }
                    }
                    if let path = metadata["cwd"] as? String, path.hasPrefix("/"), path.count <= 4096 {
                        if !cwd.isEmpty, cwd != path { conflictingProject = true }
                        else { cwd = path }
                    }
                    if type == "custom-title", let name = record["customTitle"] as? String { title = String(SessionParser.text(name).prefix(240)) }
                    if provider == .codex {
                        guard type == "event_msg", let payload = record["payload"] as? [String: Any] else { return }
                        let kind = payload["type"] as? String, id = identifier(payload["turn_id"])
                        guard ["task_started", "task_complete", "turn_aborted"].contains(kind ?? "") else { return }
                        // A malformed explicit time must never silently fall back to another clock.
                        for key in ["started_at", "completed_at", "duration_ms"] where payload[key] != nil && number(payload[key]) == nil { issue(.invalidTiming, provider); return }
                        if kind == "task_started", let id, let start = number(payload["started_at"]).map(Date.init(timeIntervalSince1970:)) ?? stamp {
                            if pending.count < 10_000 { pending[id] = start } else { issue(.budget, provider) }
                        } else if kind == "turn_aborted", let id { pending.removeValue(forKey: id) }
                        else if kind == "task_complete" {
                            hadTiming = true
                            let paired = id.flatMap { pending.removeValue(forKey: $0) }
                            guard let end = number(payload["completed_at"]).map(Date.init(timeIntervalSince1970:)) ?? stamp,
                                  let start = number(payload["started_at"]).map(Date.init(timeIntervalSince1970:)) ?? paired else { issue(.incompleteTask, provider); return }
                            if let duration = number(payload["duration_ms"]) {
                                guard duration > 0, abs(end.timeIntervalSince(start) - duration / 1000) < 5 else { issue(.invalidTiming, provider); return }
                                append(start: max(start, end.addingTimeInterval(-duration / 1000)), end: end, provider: provider, kind: 0)
                            } else { append(start: start, end: end, provider: provider, kind: 0) }
                        }
                        return
                    }
                    if type == "system", record["subtype"] as? String == "turn_duration" {
                        hadTiming = true
                        guard let duration = number(record["durationMs"]), duration > 0, let end = stamp else { issue(.invalidTiming, provider); return }
                        append(start: end.addingTimeInterval(-duration / 1000), end: end, provider: provider, kind: 0)
                        return
                    }
                    let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    if type == "assistant" {
                        for block in content where block["type"] as? String == "tool_use" {
                            if let id = identifier(block["id"]), let name = block["name"] as? String {
                                if calls.count < 10_000 { calls[id] = (name, stamp) } else { issue(.budget, provider) }
                            }
                        }
                        return
                    }
                    guard type == "user", let timing = record["toolUseResult"] as? [String: Any] else { return }
                    let results = content.filter { $0["type"] as? String == "tool_result" }
                    guard results.count == 1, let block = results.first, let id = identifier(block["tool_use_id"]) else { return }
                    guard !completedTools.contains(id) else { return }
                    guard completedTools.count < 20_000 else { issue(.budget, provider); return }
                    completedTools.insert(id)
                    let call = calls.removeValue(forKey: id)
                    guard block["is_error"] as? Bool != true else { return }
                    let agent = timing["totalDurationMs"] != nil
                    let duration: Double?
                    if agent {
                        hadTiming = true
                        guard timing["status"] as? String == "completed" else { issue(.incompleteTask, provider); return }
                        // Standalone completed agent metadata survives compaction of its tool call.
                        guard call.map({ ["Agent", "Task"].contains($0.0) }) ?? (identifier(timing["agentId"]) != nil) else { issue(.unmatchedTool, provider); return }
                        duration = number(timing["totalDurationMs"]).map { $0 / 1000 }
                    } else {
                        guard timing["durationMs"] != nil || timing["durationSeconds"] != nil else { return }
                        hadTiming = true
                        guard let call else { issue(.unmatchedTool, provider); return }
                        switch call.0 {
                        case "WebFetch", "Glob": duration = number(timing["durationMs"]).map { $0 / 1000 }
                        case "WebSearch": duration = number(timing["durationSeconds"])
                        default: issue(.unmatchedTool, provider); return
                        }
                    }
                    guard let duration, duration > 0, let end = stamp else { issue(.invalidTiming, provider); return }
                    var start = end.addingTimeInterval(-duration)
                    if let called = call?.1 {
                        guard end >= called, start >= called.addingTimeInterval(-5) else { issue(.invalidTiming, provider); return }
                        start = max(start, called)
                    }
                    append(start: start, end: end, provider: provider, kind: agent ? 1 : 2)
                }
                var reader = TimingJSONLReader(maximumRecordBytes: maximumLineBytes)
                do {
                    while remaining > 0, !exhausted() {
                        let chunk = try handle.read(upToCount: min(256 * 1024, remaining, maximumBytes - bytesRead)) ?? Data()
                        if chunk.isEmpty { break }
                        remaining -= chunk.count; bytesRead += chunk.count; reports[provider]!.bytesRead += chunk.count
                        reader.feed(chunk, consume: consume)
                    }
                    reachedEOF = remaining == 0
                    if reachedEOF { reader.finish(consume: consume) }
                    else { issue(exhausted() ? .budget : .unreadable, provider) }
                } catch { issue(.unreadable, provider) }
                let unfinished = pending.values.filter { $0 < boundary && $0 >= cutoff }.count
                if reachedEOF, unfinished > 0 { issue(.incompleteTask, provider, count: unfinished) }
                if !hadTiming { reports[provider]!.filesWithoutTiming += 1 }
                if let sessionID, !conflictingIdentity, firstInterval < result.intervals.count {
                    result.details.append(ActivityDetailRecord(provider: provider, sessionID: sessionID, title: title, cwd: conflictingProject ? "" : cwd,
                        intervals: ActivityHistory.union(Array(result.intervals[firstInterval...]))))
                }
            }
        }
        result.intervals = ActivityHistory.union(result.intervals)
        for provider in reports.keys {
            let mask = provider == .claude ? 1 : 2
            let spans = result.intervals.filter { $0.providers & mask != 0 }
            reports[provider]!.recoveredSeconds = spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            reports[provider]!.firstRecovered = spans.first?.start; reports[provider]!.lastRecovered = spans.last?.end
            var days = Set<Date>()
            for span in spans {
                var day = Calendar.current.startOfDay(for: span.start)
                while day < span.end {
                    days.insert(day)
                    guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day), next > day else { break }; day = next
                }
            }
            reports[provider]!.daysRecovered = days.count
        }
        result.report.providers = ProviderID.allCases.compactMap { reports[$0] }
        result.limited = result.report.limited
        return result
    }
}

/// Bounds memory by omitting long JSON strings (images, messages, tool output), while
/// preserving surrounding structure and short timing/identity fields, even after a huge value.
/// A quote is structural only after an even run of backslashes, including chunk boundaries.
struct TimingJSONLReader {
    enum Failure { case tooLarge, unterminatedString }
    let maximumRecordBytes: Int
    var maximumStringBytes = 4096
    private var record = Data(), string = Data()
    private var inString = false, escaped = false, omittedString = false, tooLarge = false
    private var omitted = 0, hasBytes = false
    init(maximumRecordBytes: Int) { self.maximumRecordBytes = max(0, maximumRecordBytes) }
    private mutating func emit(_ bytes: UnsafeRawBufferPointer) {
        guard !tooLarge else { return }
        if record.count + bytes.count <= maximumRecordBytes { record.append(contentsOf: bytes) }
        else { tooLarge = true; record.removeAll(keepingCapacity: true) }
    }
    private mutating func stringPart(_ bytes: UnsafeRawBufferPointer) {
        guard !omittedString else { return }
        if string.count + bytes.count <= maximumStringBytes { string.append(contentsOf: bytes) }
        else { omittedString = true; omitted += 1; string.removeAll(keepingCapacity: true) }
    }
    mutating func feed(_ data: Data, consume: (Data, Failure?, Int) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var cursor = 0
            while cursor < raw.count {
                let newline = memchr(base.advanced(by: cursor), 10, raw.count - cursor).map { base.distance(to: $0) } ?? raw.count
                process(UnsafeRawBufferPointer(rebasing: raw[cursor..<newline]))
                if newline < raw.count { finish(consume: consume) }
                cursor = newline + 1
            }
        }
    }
    private mutating func process(_ raw: UnsafeRawBufferPointer) {
        guard let base = raw.baseAddress, !raw.isEmpty else { return }
        hasBytes = true
        guard !tooLarge else { return }
        var cursor = 0
        while cursor < raw.count {
            let quote = memchr(base.advanced(by: cursor), 34, raw.count - cursor).map { base.distance(to: $0) } ?? raw.count
            let part = UnsafeRawBufferPointer(rebasing: raw[cursor..<quote])
            if inString {
                stringPart(part)
                var slashes = 0, index = quote - 1
                while index >= cursor, raw[index] == 92 { slashes += 1; index -= 1 }
                let odd = (slashes + (index < cursor && escaped ? 1 : 0)) % 2 == 1
                if quote == raw.count { escaped = odd; break }
                if odd {
                    stringPart(UnsafeRawBufferPointer(rebasing: raw[quote...quote])); escaped = false
                } else {
                    emit(UnsafeRawBufferPointer(rebasing: raw[quote...quote]))
                    if !omittedString { string.withUnsafeBytes { emit($0) } }
                    emit(UnsafeRawBufferPointer(rebasing: raw[quote...quote]))
                    string.removeAll(keepingCapacity: true); inString = false; escaped = false; omittedString = false
                }
            } else {
                emit(part)
                if quote == raw.count { break }
                inString = true; escaped = false
            }
            cursor = quote + 1
        }
    }
    mutating func finish(consume: (Data, Failure?, Int) -> Void) {
        if hasBytes { consume(record, tooLarge ? .tooLarge : inString ? .unterminatedString : nil, omitted) }
        record.removeAll(keepingCapacity: true); string.removeAll(keepingCapacity: true)
        inString = false; escaped = false; omittedString = false; tooLarge = false; omitted = 0; hasBytes = false
    }
}
