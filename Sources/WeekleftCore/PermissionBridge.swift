import Foundation
import Darwin

/// Hands a Claude Code permission request from the hook helper to the running
/// app and the owner's answer back (owner's yes 18.11.2026, R1537), over a Unix
/// socket in the user's Application Support folder. Without the app or its
/// island there is no socket: the helper prints nothing and Claude Code shows
/// its own dialog. The app answers within `appWait`, before the helper stops
/// waiting (`helperWait`) and before Claude Code ends the hook (`hookTimeout`).
public enum PermissionBridge {
    public static let hookTimeout = 60
    public static let helperWait: TimeInterval = 55
    public static let appWait: TimeInterval = 50

    public enum Answer: String, Sendable {
        /// `ask` leaves the request to Claude Code's own dialog.
        case allow, always, deny, ask
    }

    /// The owner's reply: an answer and, for a question of the agent, the chosen
    /// option labels by question text (owner's yes 18.11.2026, R1539).
    public struct Reply: Equatable, Sendable {
        public var answer: Answer
        public var answers: [String: String]?
        public init(_ answer: Answer, answers: [String: String]? = nil) { self.answer = answer; self.answers = answers }
        public static let allow = Reply(.allow), always = Reply(.always), deny = Reply(.deny), ask = Reply(.ask)
        /// One line on the socket: the bare answer, or JSON when answers come with it.
        var line: String {
            guard let answers,
                  let data = try? JSONSerialization.data(withJSONObject: ["answer": answer.rawValue, "answers": answers], options: [.sortedKeys])
            else { return answer.rawValue }
            return String(decoding: data, as: UTF8.self)
        }
        init?(line: String) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("{") else {
                guard let answer = Answer(rawValue: text) else { return nil }
                self.init(answer); return
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let answer = (object["answer"] as? String).flatMap(Answer.init(rawValue:)),
                  let answers = object["answers"] as? [String: String] else { return nil }
            self.init(answer, answers: answers)
        }
    }

    public static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/permission.sock")
    }

    /// A request the island can answer: a tool to allow or deny, or a question of
    /// the agent whose options fit the island. Other questions stay in the session.
    public static func waits(for object: [String: Any]) -> Bool {
        guard object["hook_event_name"] as? String == "PermissionRequest", object["session_id"] is String,
              let tool = object["tool_name"] as? String, !tool.isEmpty else { return false }
        return tool != "AskUserQuestion" || PermissionQuestion.parse(object["tool_input"]) != nil
    }

    /// Claude Code reads its hooks when a session starts. A session started before
    /// the settings last changed may still allow the helper three seconds: an
    /// answer from the island would arrive after Claude Code stopped listening
    /// (owner's report 18.11.2026, R1538), so such a session asks in its dialog.
    public static func sessionSeesWait(processStart: Date?, settingsChanged: Date?) -> Bool {
        guard let processStart, let settingsChanged else { return true }
        return processStart >= settingsChanged
    }

    /// The hook's output for an answer, or nil when Claude Code should ask in its dialog.
    public static func output(for answer: Answer, payload: [String: Any]) -> String? {
        output(for: Reply(answer), payload: payload)
    }
    /// Answers to a question go back as the tool's input with `answers` by question
    /// text, the way Claude Code reads them; `questions` must stay (it maps over them).
    public static func output(for reply: Reply, payload: [String: Any]) -> String? {
        var decision: [String: Any]
        if let answers = reply.answers, reply.answer == .allow, payload["tool_name"] as? String == "AskUserQuestion" {
            var input = payload["tool_input"] as? [String: Any] ?? [:]
            input["questions"] = input["questions"] ?? [Any]()
            input["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": input]
            let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        // A question is answered only with its options: any other reply leaves it to the session.
        if payload["tool_name"] as? String == "AskUserQuestion" { return nil }
        switch reply.answer {
        case .ask: return nil
        case .allow: decision = ["behavior": "allow"]
        case .always:
            decision = ["behavior": "allow"]
            if let suggestions = payload["permission_suggestions"] as? [Any], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        case .deny: decision = ["behavior": "deny", "message": "The user declined this request in Lunavect."]
        }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Helper side: sends the request and waits for the owner's answer. Any
    /// failure (no app, another user's socket, timeout) is `ask`.
    public static func ask(payload object: [String: Any], socket url: URL = socketURL, wait: TimeInterval = helperWait) -> Reply {
        guard waits(for: object), var message = try? JSONSerialization.data(withJSONObject: object) else { return .ask }
        message.append(0x0A)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .ask }
        defer { close(fd) }
        configure(fd, receiveTimeout: wait)
        guard withAddress(url, { Darwin.connect(fd, $0, $1) }) == 0, sameUser(fd), writeAll(fd, message),
              let line = readLine(fd, limit: 64 << 10) else { return .ask }
        return Reply(line: line) ?? .ask
    }

    // MARK: Socket helpers

    static func configure(_ fd: Int32, receiveTimeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var receive = timeval(tv_sec: Int(receiveTimeout), tv_usec: Int32((receiveTimeout - receiveTimeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
        var send = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
    }

    static func withAddress(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        let path = Array(url.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// The other end runs as this user.
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    @discardableResult static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// One line, without its newline; nil on timeout or an empty close.
    static func readLine(_ fd: Int32, limit: Int) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while buffer.count <= limit {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if let end = buffer.firstIndex(of: 0x0A) { return String(decoding: buffer[..<end], as: UTF8.self) }
            } else if count < 0 && errno == EINTR {
                continue
            } else { break }
        }
        return buffer.isEmpty || buffer.count > limit ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

/// A permission request waiting for the owner's answer in the island.
public struct PermissionPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let tool: String
    /// The command, file or address the request is about, on one line.
    public let detail: String
    public let cwd: String
    /// Claude Code offered a rule ("don't ask again") the answer can keep.
    public let canAlways: Bool
    public let receivedAt: Date
    /// The agent's questions (AskUserQuestion), answered with their options; nil for a tool.
    public let questions: [PermissionQuestion]?
    /// The island row of this request's session.
    public var rowID: String { ProviderID.claude.rawValue + ":" + sessionID }

    public init?(payload object: [String: Any], id: UUID = UUID(), now: Date = Date()) {
        guard PermissionBridge.waits(for: object), let session = object["session_id"] as? String,
              let tool = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        questions = tool == "AskUserQuestion" ? PermissionQuestion.parse(input) : nil
        let named = ["command", "file_path", "notebook_path", "url", "path", "pattern", "description", "prompt"]
            .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
        let text = questions?.first?.text ?? named ?? input.values.lazy.compactMap { $0 as? String }.first ?? ""
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        self.id = id; self.sessionID = session; self.tool = tool
        detail = line.count > 240 ? String(line.prefix(239)) + "…" : line
        cwd = object["cwd"] as? String ?? ""
        canAlways = (object["permission_suggestions"] as? [Any])?.isEmpty == false
        receivedAt = now
    }
}

/// One question of the agent (AskUserQuestion) as the island offers it: the
/// question, its short header and 2 to 4 options, one or several to pick.
public struct PermissionQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let detail: String
    }
    /// Claude Code finds the answer by this text.
    public let text: String
    public let header: String
    public let options: [Option]
    public let multiSelect: Bool

    /// The answer Claude Code reads: the chosen labels, several joined as its own dialog joins them.
    public static func answer(_ labels: [String]) -> String { labels.joined(separator: ", ") }

    /// 1 to 4 questions with distinct texts and 2 to 4 labelled options each, as
    /// the tool defines them; anything else is answered in the session.
    static func parse(_ value: Any?) -> [PermissionQuestion]? {
        guard let items = (value as? [String: Any])?["questions"] as? [[String: Any]], (1...4).contains(items.count) else { return nil }
        var questions: [PermissionQuestion] = []
        for item in items {
            guard let text = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  text.count <= 1000, !questions.contains(where: { $0.text == text }),
                  let raw = item["options"] as? [[String: Any]], (2...4).contains(raw.count) else { return nil }
            var options: [Option] = []
            for option in raw {
                guard let label = option["label"] as? String, !label.isEmpty, label.count <= 200,
                      !options.contains(where: { $0.label == label }) else { return nil }
                options.append(Option(label: label, detail: (option["description"] as? String) ?? ""))
            }
            questions.append(PermissionQuestion(text: text, header: (item["header"] as? String) ?? "", options: options,
                                                multiSelect: item["multiSelect"] as? Bool ?? false))
        }
        return questions
    }
}

/// App side of the bridge: accepts requests, hands them to the island and
/// writes the owner's answer back. A request ends with the answer, at
/// `appWait`, or when Claude Code ends the hook (the session was interrupted).
public final class PermissionBridgeServer: @unchecked Sendable {
    private struct Pending { let fd: Int32; let source: DispatchSourceRead }
    private let url: URL
    private let wait: TimeInterval
    private let queue = DispatchQueue(label: "com.lunavect.permission-bridge")
    private var listener: DispatchSourceRead?
    private var pending: [UUID: Pending] = [:]
    private let onPrompt: (PermissionPrompt) -> Void
    private let onEnd: (UUID) -> Void

    /// `onPrompt` and `onEnd` run on the main queue.
    public init(url: URL = PermissionBridge.socketURL, wait: TimeInterval = PermissionBridge.appWait,
                onPrompt: @escaping (PermissionPrompt) -> Void, onEnd: @escaping (UUID) -> Void) {
        self.url = url; self.wait = wait; self.onPrompt = onPrompt; self.onEnd = onEnd
    }

    public func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            unlink(url.path)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            guard PermissionBridge.withAddress(url, { Darwin.bind(fd, $0, $1) }) == 0, chmod(url.path, 0o600) == 0,
                  Darwin.listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            listener = source
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for id in Array(pending.keys) { finish(id, reply: .ask, notify: false) }
            unlink(url.path)
        }
    }

    /// `delivered` (on the main queue) says whether the helper was still waiting.
    public func answer(_ id: UUID, _ answer: PermissionBridge.Reply, delivered: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [weak self] in
            let done = self?.finish(id, reply: answer, notify: false) ?? false
            DispatchQueue.main.async { delivered(done) }
        }
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            // An accepted socket keeps the listener's non-blocking flag on macOS.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            PermissionBridge.configure(client, receiveTimeout: 2)
            guard PermissionBridge.sameUser(client), let line = PermissionBridge.readLine(client, limit: 4 << 20),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let prompt = PermissionPrompt(payload: object) else { close(client); continue }
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            // The helper sends nothing more while it waits: readable means it closed.
            source.setEventHandler { [weak self] in
                var byte: UInt8 = 0
                let count = recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { self?.finish(prompt.id, reply: nil, notify: true) }
            }
            source.setCancelHandler { close(client) }
            pending[prompt.id] = Pending(fd: client, source: source)
            source.resume()
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.finish(prompt.id, reply: .ask, notify: true) }
            let onPrompt = self.onPrompt
            DispatchQueue.main.async { onPrompt(prompt) }
        }
    }

    @discardableResult private func finish(_ id: UUID, reply: PermissionBridge.Reply?, notify: Bool) -> Bool {
        guard let request = pending.removeValue(forKey: id) else { return false }
        let written = reply.map { PermissionBridge.writeAll(request.fd, Data(($0.line + "\n").utf8)) } ?? false
        request.source.cancel()
        if notify { let onEnd = self.onEnd; DispatchQueue.main.async { onEnd(id) } }
        return written
    }
}
