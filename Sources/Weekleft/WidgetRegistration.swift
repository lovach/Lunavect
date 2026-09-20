import AppKit
import CoreServices
import Darwin
import OSLog
import WidgetKit

/// Only the installed host may repair its own extension. Running a preview,
/// archive or mounted installer must not compete with the user's installation.
struct WidgetRegistrationTarget: Equatable, Sendable {
    let app: URL
    let version: String
    var extensionURL: URL { app.appendingPathComponent("Contents/PlugIns/LunavectWidget.appex") }
    var executable: String { extensionURL.appendingPathComponent("Contents/MacOS/LunavectWidget").path }
    var stamp: String { "1|\(app.path)|\(version)" }

    static func installed(bundle: Bundle = .main, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self? {
        let app = bundle.bundleURL.resolvingSymlinksInPath()
        let allowed = [URL(fileURLWithPath: "/Applications/Lunavect.app"), home.appendingPathComponent("Applications/Lunavect.app")]
        guard allowed.contains(where: { $0.standardizedFileURL == app }),
              bundle.bundleIdentifier == "com.weekleft.app",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !version.isEmpty,
              let widget = Bundle(url: app.appendingPathComponent("Contents/PlugIns/LunavectWidget.appex")),
              widget.bundleIdentifier == "com.weekleft.app.widget",
              widget.object(forInfoDictionaryKey: "CFBundleVersion") as? String == version else { return nil }
        return Self(app: app, version: version)
    }
}

/// A version/path change repairs registration once. Failures remain retryable
/// on the next launch; a failed command is never recorded as successful.
@MainActor final class WidgetRegistration {
    static let stampKey = "widgetRegistrationStamp"
    private let defaults: UserDefaults
    private let target: WidgetRegistrationTarget?
    private let repair: @Sendable (WidgetRegistrationTarget) async -> Bool
    private let reload: () -> Void
    private let pause: () async throws -> Void
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.weekleft.app", category: "widget-registration")

    init(defaults: UserDefaults, target: WidgetRegistrationTarget? = .installed(),
         repair: @escaping @Sendable (WidgetRegistrationTarget) async -> Bool = { await WidgetRegistrationSystem.repair($0) },
         reload: @escaping () -> Void = {
             for kind in ["WeekleftWidget", "LunavectActivityWidget", "LunavectOverviewWidget"] {
                 WidgetCenter.shared.reloadTimelines(ofKind: kind)
             }
         }, pause: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.defaults = defaults; self.target = target; self.repair = repair; self.reload = reload; self.pause = pause
    }

    func start() {
        guard task == nil, let target, defaults.string(forKey: Self.stampKey) != target.stamp else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            for attempt in 0..<2 {
                if attempt > 0 {
                    do { try await self.pause() } catch { return }
                }
                guard !Task.isCancelled else { return }
                let repaired = await self.repair(target)
                guard !Task.isCancelled else { return }
                if repaired {
                    self.defaults.set(target.stamp, forKey: Self.stampKey)
                    self.logger.notice("Widget registration refreshed for build \(target.version, privacy: .public)")
                    self.reload()
                    // LaunchServices propagation is asynchronous. Request again
                    // after it settles, without restarting the extension again.
                    do { try await self.pause() } catch { return }
                    if !Task.isCancelled { self.reload() }
                    return
                }
            }
            self.logger.error("Widget registration failed; will retry on next launch")
        }
    }

    func stop() { task?.cancel() }
    func waitUntilFinished() async { await task?.value }
}

enum WidgetRegistrationSystem {
    static func repair(_ target: WidgetRegistrationTarget) async -> Bool {
        let worker = Task.detached(priority: .utility) { repairSynchronously(target) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func repairSynchronously(_ target: WidgetRegistrationTarget) -> Bool {
        guard !Task.isCancelled, stopExtension(target) else { return false }
        guard !Task.isCancelled, LSRegisterURL(target.app as CFURL, true) == noErr else { return false }
        // Use argv, never a shell; register just the current embedded appex.
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-a", target.extensionURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return false
            }
        }
        return process.terminationStatus == 0
    }

    /// Match the complete executable path immediately before signalling. Other
    /// widgets, other app copies and the system widget host are never stopped.
    @discardableResult static func stopExtension(_ target: WidgetRegistrationTarget) -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 128)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = proc_listallpids(&pids, bytes)
        guard count > 0, count < pids.count else { return false }
        for pid in pids.prefix(Int(count)) where pid > 1 {
            guard executablePath(pid) == target.executable else { continue }
            if kill(pid, SIGTERM) != 0 && errno != ESRCH { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while executablePath(pid) == target.executable {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return true
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
