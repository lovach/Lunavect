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
/// Every launch of the installed host also reasserts its registration twice.
/// Restarting the extension (above) or an installer/updater removing the replaced
/// copy can leave the widget host unable to resolve the extension: it then shows
/// placeholders although timelines succeed, until the next registration change.
/// The first check follows the restart closely; the second covers late cleanup.
@MainActor final class WidgetRegistration {
    static let stampKey = "widgetRegistrationStamp"
    static let checkDelays: [Duration] = [.seconds(5), .seconds(25)]
    private let defaults: UserDefaults
    private let target: WidgetRegistrationTarget?
    private let repair: @Sendable (WidgetRegistrationTarget) async -> Bool
    private let reassert: @Sendable (WidgetRegistrationTarget) async -> Bool
    private let reload: () -> Void
    private let pause: () async throws -> Void
    private let settle: (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.weekleft.app", category: "widget-registration")

    init(defaults: UserDefaults, target: WidgetRegistrationTarget? = .installed(),
         repair: @escaping @Sendable (WidgetRegistrationTarget) async -> Bool = { await WidgetRegistrationSystem.repair($0) },
         reassert: @escaping @Sendable (WidgetRegistrationTarget) async -> Bool = { await WidgetRegistrationSystem.reassert($0) },
         reload: @escaping () -> Void = {
             for kind in ["WeekleftWidget", "LunavectActivityWidget", "LunavectOverviewWidget"] {
                 WidgetCenter.shared.reloadTimelines(ofKind: kind)
             }
         }, pause: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
         settle: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.defaults = defaults; self.target = target; self.repair = repair; self.reassert = reassert
        self.reload = reload; self.pause = pause; self.settle = settle
    }

    func start() {
        guard task == nil, let target else { return }
        let needsRepair = defaults.string(forKey: Self.stampKey) != target.stamp
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            if needsRepair {
                guard await self.repairOnce(target), !Task.isCancelled else { return }
            }
            for delay in Self.checkDelays {
                do { try await self.settle(delay) } catch { return }
                guard !Task.isCancelled else { return }
                // Registration only; the running extension keeps serving timelines.
                guard await self.reassert(target), !Task.isCancelled else {
                    if !Task.isCancelled { self.logger.error("Widget registration check failed; will retry on next launch") }
                    return
                }
                self.reload()
            }
        }
    }

    private func repairOnce(_ target: WidgetRegistrationTarget) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                do { try await pause() } catch { return false }
            }
            guard !Task.isCancelled else { return false }
            let repaired = await repair(target)
            guard !Task.isCancelled else { return false }
            if repaired {
                defaults.set(target.stamp, forKey: Self.stampKey)
                logger.notice("Widget registration refreshed for build \(target.version, privacy: .public)")
                reload()
                // LaunchServices propagation is asynchronous. Request again
                // after it settles, without restarting the extension again.
                do { try await pause() } catch { return false }
                if !Task.isCancelled { reload() }
                return true
            }
        }
        logger.error("Widget registration failed; will retry on next launch")
        return false
    }

    func stop() { task?.cancel() }
    func waitUntilFinished() async { await task?.value }
}

enum WidgetRegistrationSystem {
    static func repair(_ target: WidgetRegistrationTarget) async -> Bool {
        let worker = Task.detached(priority: .utility) { !Task.isCancelled && stopExtension(target) && register(target) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// Re-register the host and its extension without restarting the extension.
    static func reassert(_ target: WidgetRegistrationTarget) async -> Bool {
        let worker = Task.detached(priority: .utility) { register(target) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func register(_ target: WidgetRegistrationTarget) -> Bool {
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
