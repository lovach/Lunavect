import Foundation
import os
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// How a turn of a task ended.
enum TaskTurnEnd: Equatable {
    case completed, interrupted, limitReached
    case failed(String)
}

/// What a running agent reports to the task service.
enum TaskDriverEvent: Equatable {
    case session(String)
    /// Tokens added since the last report.
    case usage(TokenCounts)
    /// Live used percent of the five-hour and weekly windows (Codex reports them per turn).
    case limits(fiveHour: Double?, week: Double?)
    case text(String)
    case turnEnded(TaskTurnEnd)
    case exited(Int32)
}

/// One task's agent process. Starts it, steers it, stops it softly.
@MainActor protocol TaskDriver: AnyObject {
    var onEvent: ((TaskDriverEvent) -> Void)? { get set }
    func start(_ task: AgentTask, message: String, resume: Bool) throws
    /// A message the agent reads at its next step.
    func steer(_ text: String)
    /// Ends the current step cleanly; the conversation stays resumable.
    func interrupt()
    /// Ends the process after the current step is over.
    func close()
}

/// Environment for a task's agent: the login shell's PATH, so its commands find git, node and the rest.
enum TaskEnvironment {
    private static let lock = OSAllocatedUnfairLock<String?>(initialState: nil)
    static func path() -> String {
        if let cached = lock.withLock({ $0 }) { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        var value = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            else if let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), text.contains("/") { value = text }
        }
        let found = value
        lock.withLock { $0 = found }
        return found
    }
    static func make(executable: String, taskID: UUID) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = directory + ":" + path()
        environment["LUNAVECT_TASK_ID"] = taskID.uuidString
        return environment
    }
}

/// Reads newline-separated JSON from a pipe and hands each object to the main actor.
final class JSONLinePipe: @unchecked Sendable {
    private var buffer = Data()
    private let handler: @MainActor ([String: Any]) -> Void
    init(_ handle: FileHandle, handler: @escaping @MainActor ([String: Any]) -> Void) {
        self.handler = handler
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let send = SendableObject(object)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.handler(send.value) } }
            }
            // A runaway line without a newline is not a message.
            if self.buffer.count > 64 * 1024 * 1024 { self.buffer.removeAll() }
        }
    }
}
struct SendableObject: @unchecked Sendable { let value: [String: Any]; init(_ value: [String: Any]) { self.value = value } }

/// Claude Code in print mode with streamed JSON in and out (`claude -p --input-format stream-json`).
@MainActor final class ClaudeTaskDriver: TaskDriver {
    var onEvent: ((TaskDriverEvent) -> Void)?
    private let executable: String
    private var process: Process?
    private var input: FileHandle?
    private var reader: JSONLinePipe?
    private var seen: [String: TokenCounts] = [:]
    private var interrupting = false
    private var sawLimit = false
    init(executable: String) { self.executable = executable }

    func start(_ task: AgentTask, message: String, resume: Bool) throws {
        guard let sessionID = task.sessionID else { throw CocoaError(.featureUnsupported) }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = TaskCommands.claudeArguments(task, sessionID: sessionID, resume: resume)
        process.currentDirectoryURL = URL(fileURLWithPath: task.workingDirectory)
        process.environment = TaskEnvironment.make(executable: executable, taskID: task.id)
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent?(.exited(status)) } }
        }
        reader = JSONLinePipe(stdout.fileHandleForReading) { [weak self] in self?.handle($0) }
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting
        onEvent?(.session(sessionID))
        send(TaskCommands.claudeUserMessage(message))
    }
    func steer(_ text: String) { send(TaskCommands.claudeUserMessage(text)) }
    func interrupt() { interrupting = true; send(TaskCommands.claudeInterrupt) }
    func close() {
        try? input?.close(); input = nil
        // Stdin closed ends the run after its result; a process that lingers gets SIGINT, which also ends the turn cleanly.
        let process = self.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if process?.isRunning == true { process?.interrupt() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if process?.isRunning == true { process?.terminate() } }
    }
    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.write(contentsOf: data + Data([10]))
    }
    private func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return }
            if let usage = message["usage"] as? [String: Any] {
                func int(_ key: String) -> Int64 { (usage[key] as? NSNumber)?.int64Value ?? 0 }
                let reading = TokenCounts(input: int("input_tokens"), cacheRead: int("cache_read_input_tokens"),
                                          cacheWrite: int("cache_creation_input_tokens"), output: int("output_tokens"))
                let id = message["id"] as? String ?? UUID().uuidString
                let earlier = seen[id] ?? TokenCounts()
                let merged = reading.maximum(earlier)
                seen[id] = merged
                if seen.count > 256 { seen = [id: merged] }
                let added = merged.adding(over: earlier)
                if !added.isEmpty { onEvent?(.usage(added)) }
            }
            let texts = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if let text = texts.last, !text.isEmpty { onEvent?(.text(text)) }
        case "system":
            if object["subtype"] as? String == "api_retry", object["error"] as? String == "rate_limit" { sawLimit = true }
        case "result":
            if let text = object["result"] as? String, !text.isEmpty { onEvent?(.text(text)) }
            let subtype = object["subtype"] as? String ?? ""
            let text = (object["result"] as? String ?? "").lowercased()
            if subtype == "success" && object["is_error"] as? Bool != true { onEvent?(.turnEnded(.completed)) }
            else if interrupting || subtype == "error_during_execution" && interrupting { interrupting = false; onEvent?(.turnEnded(.interrupted)) }
            else if sawLimit || text.contains("usage limit") || text.contains("limit reached") { onEvent?(.turnEnded(.limitReached)) }
            else { onEvent?(.turnEnded(.failed(object["result"] as? String ?? subtype))) }
        default: break
        }
    }
}

/// Codex through its app-server: `thread/start` or `thread/resume`, `turn/start`, `turn/steer`, `turn/interrupt`.
@MainActor final class CodexTaskDriver: TaskDriver {
    var onEvent: ((TaskDriverEvent) -> Void)?
    private let executable: String
    private var process: Process?
    private var input: FileHandle?
    private var reader: JSONLinePipe?
    private var nextID = 1
    private var pending: [Int: @MainActor ([String: Any]?, [String: Any]?) -> Void] = [:]
    private var thread: String?
    private var turn: String?
    private var lastTotal = TokenCounts()
    private var interrupting = false
    init(executable: String) { self.executable = executable }

    func start(_ task: AgentTask, message: String, resume: Bool) throws {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: task.workingDirectory)
        process.environment = TaskEnvironment.make(executable: executable, taskID: task.id)
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent?(.exited(status)) } }
        }
        reader = JSONLinePipe(stdout.fileHandleForReading) { [weak self] in self?.handle($0) }
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting
        request("initialize", ["clientInfo": ["name": "lunavect-tasks", "version": "1"]]) { [weak self] _, _ in
            guard let self else { return }
            self.notify("initialized")
            let method = resume ? "thread/resume" : "thread/start"
            self.request(method, TaskCommands.codexThreadParameters(task, resume: resume ? task.sessionID : nil)) { [weak self] result, error in
                guard let self else { return }
                guard let thread = (result?["thread"] as? [String: Any])?["id"] as? String else {
                    self.onEvent?(.turnEnded(.failed(error?["message"] as? String ?? L("Codex не начал задачу.")))); return
                }
                self.thread = thread
                self.onEvent?(.session(thread))
                self.request("turn/start", ["threadId": thread, "input": TaskCommands.codexInput(message)]) { [weak self] result, error in
                    if let turn = (result?["turn"] as? [String: Any])?["id"] as? String { self?.turn = turn }
                    else { self?.onEvent?(.turnEnded(.failed(error?["message"] as? String ?? L("Codex не начал задачу.")))) }
                }
            }
        }
    }
    func steer(_ text: String) {
        guard let thread, let turn else { return }
        request("turn/steer", ["threadId": thread, "expectedTurnId": turn, "input": TaskCommands.codexInput(text)]) { _, _ in }
    }
    func interrupt() {
        guard let thread, let turn else { return }
        interrupting = true
        request("turn/interrupt", ["threadId": thread, "turnId": turn]) { _, _ in }
    }
    func close() {
        try? input?.close(); input = nil
        let process = self.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if process?.isRunning == true { process?.terminate() } }
    }
    private func request(_ method: String, _ parameters: [String: Any], _ completion: @escaping @MainActor ([String: Any]?, [String: Any]?) -> Void) {
        let id = nextID; nextID += 1
        pending[id] = completion
        write(["id": id, "method": method, "params": parameters])
    }
    private func notify(_ method: String) { write(["method": method]) }
    private func write(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.write(contentsOf: data + Data([10]))
    }
    private func handle(_ object: [String: Any]) {
        if let id = (object["id"] as? NSNumber)?.intValue, object["method"] == nil {
            pending.removeValue(forKey: id)?(object["result"] as? [String: Any], object["error"] as? [String: Any]); return
        }
        // A request from the server (an approval) is declined: nobody is there to answer it.
        if let id = object["id"], object["method"] is String {
            write(["id": id, "result": ["decision": "decline"]]); return
        }
        let parameters = object["params"] as? [String: Any] ?? [:]
        switch object["method"] as? String {
        case "thread/tokenUsage/updated":
            guard let usage = (parameters["tokenUsage"] as? [String: Any])?["total"] as? [String: Any] else { return }
            func int(_ key: String) -> Int64 { (usage[key] as? NSNumber)?.int64Value ?? 0 }
            let cached = int("cachedInputTokens"), reasoning = int("reasoningOutputTokens")
            let total = TokenCounts(input: max(0, int("inputTokens") - cached), cacheRead: cached, cacheWrite: int("cacheWriteInputTokens"),
                                    output: max(0, int("outputTokens") - reasoning), reasoning: reasoning)
            let added = total.adding(over: lastTotal); lastTotal = total
            if !added.isEmpty { onEvent?(.usage(added)) }
        case "account/rateLimits/updated":
            guard let limits = parameters["rateLimits"] as? [String: Any] else { return }
            var five: Double?, week: Double?
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
                if minutes == 10080 { week = used } else if minutes == 300 || (minutes == nil && key == "primary") { five = used }
            }
            onEvent?(.limits(fiveHour: five, week: week))
        case "item/completed":
            if let item = parameters["item"] as? [String: Any], item["type"] as? String == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
                onEvent?(.text(text))
            }
        case "turn/started":
            if let id = (parameters["turn"] as? [String: Any])?["id"] as? String { turn = id }
        case "turn/completed":
            let turnValue = parameters["turn"] as? [String: Any] ?? [:]
            switch turnValue["status"] as? String {
            case "completed": onEvent?(.turnEnded(.completed))
            case "interrupted": interrupting = false; onEvent?(.turnEnded(.interrupted))
            default:
                let error = turnValue["error"] as? [String: Any]
                let info = error?["codexErrorInfo"]
                if String(describing: info ?? "").lowercased().contains("usagelimit") { onEvent?(.turnEnded(.limitReached)) }
                else { onEvent?(.turnEnded(.failed(error?["message"] as? String ?? L("Codex остановил задачу с ошибкой.")))) }
            }
        default: break
        }
    }
}
