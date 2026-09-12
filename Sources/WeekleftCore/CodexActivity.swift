import Foundation

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

    mutating func consume(_ data: Data, sessionID: String) {
        guard let event = try? JSONDecoder().decode(CodexActivityEvent.self, from: data),
              event.type == "event_msg", let type = event.payload.type,
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
    private static func date(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
        var offset: UInt64 = 0
        var pending = Data()
        var state = CodexActivityState()
        var client: SessionClient = .unknown
    }
    private struct Origin: Decodable {
        let type: String
        let payload: Metadata
        struct Metadata: Decodable { let id: String; let originator: String? }
    }
    private var cursors: [String: Cursor] = [:]
    private let root: URL
    public init(home: URL? = nil) {
        let home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        root = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
    }
    public func events(catalog: [AgentSession]) -> [AgentSession] {
        let rows = catalog.filter { $0.provider == .codex }
        let ids = Set(rows.map(\.sessionID))
        cursors = cursors.filter { ids.contains($0.key) }
        return rows.compactMap { row in
            guard let path = row.activityPath,
                  let file = validFile(path, id: row.sessionID),
                  let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let count = attrs.fileSize, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            var cursor = cursors[row.sessionID] ?? Cursor(path: path)
            if cursor.path != path || cursor.offset > count { cursor = Cursor(path: path) }
            do {
                if cursor.offset == 0,
                   let header = try handle.read(upToCount: 1_000_000),
                   let newline = header.firstIndex(of: 10),
                   let origin = try? JSONDecoder().decode(Origin.self, from: Data(header.prefix(upTo: newline))),
                   origin.type == "session_meta", origin.payload.id == row.sessionID,
                   origin.payload.originator == "Codex Desktop" {
                    cursor.client = .desktop
                }
                // Bound startup and recovery reads, then only consume appended bytes.
                let start = max(cursor.offset, UInt64(max(0, count - 8_000_000)))
                let skipped = start > cursor.offset
                if skipped { cursor.pending = Data(); cursor.state = CodexActivityState() }
                try handle.seek(toOffset: start)
                var bytes = try handle.read(upToCount: 8_000_000) ?? Data()
                cursor.offset = start + UInt64(bytes.count)
                if skipped {
                    if let newline = bytes.firstIndex(of: 10) { bytes.removeSubrange(...newline) }
                    else { bytes.removeAll() }
                }
                cursor.pending.append(bytes)
                while let newline = cursor.pending.firstIndex(of: 10) {
                    let line = cursor.pending.prefix(upTo: newline)
                    cursor.state.consume(Data(line), sessionID: row.sessionID)
                    cursor.pending.removeSubrange(...newline)
                }
                if cursor.pending.count > 8_000_000 { cursor.pending.removeAll() }
                cursors[row.sessionID] = cursor
                var event = cursor.state.session(from: row)
                if cursor.client != .unknown { event?.client = cursor.client }
                return event
            } catch { return nil }
        }
    }
    private func validFile(_ path: String, id: String) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), file.pathExtension == "jsonl",
              file.lastPathComponent.hasSuffix("-\(id).jsonl"),
              file.resolvingSymlinksInPath().path == file.path else { return nil }
        return file
    }
}
