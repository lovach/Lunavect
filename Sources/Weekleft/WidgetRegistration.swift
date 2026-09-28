import AppKit
import CoreServices
import Darwin
import OSLog
import SwiftUI
import WidgetKit
#if SWIFT_PACKAGE
import WeekleftCore
#endif

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
/// Every launch of the installed host also reasserts its registration.
/// Restarting the extension (above) or an installer/updater removing the replaced
/// copy can leave the widget host unable to resolve the extension: it then shows
/// placeholders although timelines succeed, until the next registration change.
/// A registration change during that cleanup can itself cause the loss, while
/// one made in a quiet period has always restored it. The first check follows
/// the restart; the check after 2 minutes makes the last change a quiet one.
/// Another installed copy of the bundle is shown in Settings (R3-01). While
/// PlugInKit uses that copy's widget (or cannot say which), a registration change
/// here would be the trigger of that loss: repair and checks leave it alone.
/// Otherwise this copy still repairs and confirms its own registration. Copies
/// in the Trash, on a mounted disk image or no longer on disk are not duplicates,
/// and each check looks again, so an ejected installer does not block the next one.
@MainActor final class WidgetRegistration {
    static let stampKey = "widgetRegistrationStamp"
    /// Waits before each check: at 5 s and 2 min after start.
    static let checkDelays: [Duration] = [.seconds(5), .seconds(115)]
    private let defaults: UserDefaults
    private let target: WidgetRegistrationTarget?
    private let repair: @Sendable (WidgetRegistrationTarget) async -> Bool
    private let reassert: @Sendable (WidgetRegistrationTarget) async -> Bool
    private let reload: () -> Void
    private let pause: () async throws -> Void
    private let settle: (Duration) async throws -> Void
    private let registeredCopies: @Sendable () -> [URL]
    private let widgetHost: @Sendable () -> WidgetHostLookup
    private let fileExists: @Sendable (String) -> Bool
    private let status: WidgetRegistrationStatus
    private var task: Task<Void, Never>?
    private let health: WidgetHealthEnvironment?
    private var healthTask: Task<Void, Never>?
    private let launchedAt: Date
    private var lastRepair: Date?
    private var repairs = 0
    private let logger = Logger(subsystem: "com.weekleft.app", category: "widget-registration")

    init(defaults: UserDefaults, target: WidgetRegistrationTarget? = .installed(),
         repair: @escaping @Sendable (WidgetRegistrationTarget) async -> Bool = { await WidgetRegistrationSystem.repair($0) },
         reassert: @escaping @Sendable (WidgetRegistrationTarget) async -> Bool = { await WidgetRegistrationSystem.reassert($0) },
         reload: @escaping () -> Void = {
             for kind in ["WeekleftWidget", "LunavectActivityWidget", "LunavectOverviewWidget"] {
                 WidgetCenter.shared.reloadTimelines(ofKind: kind)
             }
         }, pause: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
         settle: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         registeredCopies: @escaping @Sendable () -> [URL] = { WidgetRegistrationSystem.registeredCopies() },
         widgetHost: @escaping @Sendable () -> WidgetHostLookup = { WidgetRegistrationSystem.widgetHost() },
         fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         status: WidgetRegistrationStatus? = nil, health: WidgetHealthEnvironment? = nil) {
        self.defaults = defaults; self.target = target; self.repair = repair; self.reassert = reassert
        self.reload = reload; self.pause = pause; self.settle = settle; self.registeredCopies = registeredCopies
        self.widgetHost = widgetHost; self.fileExists = fileExists; self.status = status ?? .shared
        self.health = health; self.launchedAt = health?.now() ?? Date()
    }

    func start() {
        guard task == nil, let target else { return }
        startHealthChecks(target)
        let needsRepair = defaults.string(forKey: Self.stampKey) != target.stamp
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            if needsRepair {
                guard await self.mayRegister(target), !Task.isCancelled else { return }
                guard await self.repairOnce(target), !Task.isCancelled else { return }
            }
            for delay in Self.checkDelays {
                do { try await self.settle(delay) } catch { return }
                guard !Task.isCancelled else { return }
                // A later check still runs when this one leaves the registration alone.
                guard await self.mayRegister(target) else { if Task.isCancelled { return } else { continue } }
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

    /// Looks for other installed copies, publishes them for Settings and decides
    /// whether this copy may change its registration now.
    private func mayRegister(_ target: WidgetRegistrationTarget) async -> Bool {
        let lookup = registeredCopies, exists = fileExists, host = widgetHost
        let (others, lookupHost) = await Task.detached(priority: .utility) { () -> ([URL], WidgetHostLookup?) in
            let others = WidgetRegistrationSystem.duplicates(lookup(), than: target, exists: exists)
            // PlugInKit is asked only when another copy exists.
            return (others, others.isEmpty ? nil : host())
        }.value
        guard !Task.isCancelled else { return false }
        let allowed = WidgetRegistrationSystem.mayRegister(target, duplicates: others, host: lookupHost ?? .extensions([]))
        status.update(otherCopies: others, confirmationSkipped: !allowed)
        if !others.isEmpty {
            let paths = others.map(\.path).joined(separator: ", ")
            if allowed {
                logger.warning("Another copy of Lunavect is installed (\(paths, privacy: .public)); its widget is not the registered one, so this copy confirms its own registration")
            } else {
                logger.warning("Widget registration left unchanged: macOS uses the widget of another installed copy (\(paths, privacy: .public)) or could not tell")
            }
        }
        return allowed
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

    func stop() { task?.cancel(); healthTask?.cancel() }
    func waitUntilFinished() async { await task?.value }

    /// Checks at 3 minutes and then every 10 minutes that WidgetKit still accepts
    /// the installed extension, and repairs it silently when it does not.
    private func startHealthChecks(_ target: WidgetRegistrationTarget) {
        guard let health, healthTask == nil else { return }
        healthTask = Task { [weak self] in
            var delay = WidgetHealth.firstCheck
            while !Task.isCancelled {
                do { try await health.wait(delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.checkHealth(target)
                delay = WidgetHealth.checkInterval
            }
        }
    }

    /// One health check. A repair stops the extension (including a process left
    /// from an earlier build), registers the installed copy again and reloads.
    func checkHealth(_ target: WidgetRegistrationTarget) async {
        guard let health, await mayRegister(target), !Task.isCancelled else { return }
        let stale = await Task.detached(priority: .utility) { health.staleProcesses(target) }.value
        let heartbeat = health.heartbeat()
        let facts = WidgetHealth.Facts(staleProcesses: stale, heartbeat: heartbeat, build: target.version,
                                       launchedAt: launchedAt, pendingSince: health.pendingSince(heartbeat),
                                       widgetsPlaced: await health.widgetsPlaced())
        let now = health.now()
        guard !Task.isCancelled, let problem = WidgetHealth.problem(facts, now: now),
              WidgetHealth.mayRepair(lastRepair: lastRepair, repairs: repairs, now: now) else { return }
        repairs += 1; lastRepair = now
        logger.notice("Widget repair without notice: \(problem.rawValue, privacy: .public)")
        guard await repair(target), !Task.isCancelled else { return }
        health.settlePending()
        reload()
    }
}

/// Whether the installed widget needs a silent repair (owner report 28.09: after
/// two updates the limits widget kept 09:37 values for hours). Pure decisions;
/// `WidgetRegistration.checkHealth` gathers the facts.
enum WidgetHealth {
    enum Problem: String, Equatable { case earlierBuildRunning, earlierBuildAnswered, timelinesUnanswered }
    struct Facts: Equatable {
        /// Extension processes started from the installed path whose file an update replaced.
        var staleProcesses: Int
        var heartbeat: WidgetHeartbeat?
        var build: String
        var launchedAt: Date
        /// The oldest reload request no timeline has answered since.
        var pendingSince: Date?
        var widgetsPlaced: Bool
    }
    static let firstCheck: Duration = .seconds(180)
    static let checkInterval: Duration = .seconds(600)
    /// WidgetKit normally answers a reload within minutes; half an hour is a failure.
    static let unansweredAfter: TimeInterval = 1800
    /// A widget that answered this recently is in use; an older one may have been removed.
    static let answeredWithin: TimeInterval = 7 * 86400
    static let repairSpacing: TimeInterval = 3600
    static let repairsPerLaunch = 3

    static func problem(_ facts: Facts, now: Date) -> Problem? {
        if facts.staleProcesses > 0 { return .earlierBuildRunning }
        // An extension of another build answered after this launch had registered its own.
        if let heartbeat = facts.heartbeat, heartbeat.build != facts.build,
           heartbeat.at > facts.launchedAt.addingTimeInterval(60) { return .earlierBuildAnswered }
        if facts.widgetsPlaced, let pending = facts.pendingSince, now.timeIntervalSince(pending) >= unansweredAfter,
           facts.heartbeat.map({ now.timeIntervalSince($0.at) <= answeredWithin }) ?? true { return .timelinesUnanswered }
        return nil
    }

    static func mayRepair(lastRepair: Date?, repairs: Int, now: Date) -> Bool {
        repairs < repairsPerLaunch && (lastRepair.map { now.timeIntervalSince($0) >= repairSpacing } ?? true)
    }
}

/// The system facts a health check reads; tests replace every one.
struct WidgetHealthEnvironment: Sendable {
    var wait: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> Date = { Date() }
    var staleProcesses: @Sendable (WidgetRegistrationTarget) -> Int = { WidgetRegistrationSystem.staleExtensionProcesses($0).count }
    var heartbeat: @Sendable () -> WidgetHeartbeat? = { WidgetHeartbeat.read() }
    var pendingSince: @Sendable (WidgetHeartbeat?) -> Date? = { WidgetReloadLedger.shared.pendingSince(answered: $0) }
    var settlePending: @Sendable () -> Void = { WidgetReloadLedger.shared.reset() }
    var widgetsPlaced: @Sendable () async -> Bool = {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(returning: (try? result.get()).map { !$0.isEmpty } ?? false)
            }
        }
    }
    static let live = WidgetHealthEnvironment()
}

/// The oldest widget reload the app requested that no timeline has answered yet.
final class WidgetReloadLedger: @unchecked Sendable {
    static let shared = WidgetReloadLedger()
    private let lock = NSLock()
    private var pending: Date?
    func noteRequest(at date: Date = Date()) { lock.withLock { if pending == nil { pending = date } } }
    /// A timeline written after the oldest request answers it.
    func pendingSince(answered heartbeat: WidgetHeartbeat?) -> Date? {
        lock.withLock {
            if let current = pending, let heartbeat, heartbeat.at >= current { pending = nil }
            return pending
        }
    }
    func reset() { lock.withLock { pending = nil } }
}

/// Which widget extensions PlugInKit has registered for the widget's identifier
/// (resolved paths), or `unknown` when the lookup failed.
enum WidgetHostLookup: Equatable, Sendable { case extensions([String]), unknown }

/// What Settings shows about other installed copies (R3-01). One per process.
@MainActor final class WidgetRegistrationStatus: ObservableObject {
    static let shared = WidgetRegistrationStatus()
    /// Other installed copies of Lunavect, which the user should remove.
    @Published private(set) var otherCopies: [URL] = []
    /// macOS uses the other copy's widget (or could not tell), so this copy leaves
    /// the registration alone until the other copy is gone.
    @Published private(set) var confirmationSkipped = false
    func update(otherCopies: [URL], confirmationSkipped: Bool) {
        if self.otherCopies != otherCopies { self.otherCopies = otherCopies }
        if self.confirmationSkipped != confirmationSkipped { self.confirmationSkipped = confirmationSkipped }
    }
}

enum WidgetRegistrationSystem {
    static let widgetIdentifier = "com.weekleft.app.widget"

    /// Other installed copies that can compete for the widget: existing paths
    /// outside the Trash and outside mounted volumes (an installer disk image).
    static func duplicates(_ copies: [URL], than target: WidgetRegistrationTarget, exists: (String) -> Bool) -> [URL] {
        let installed = target.app.resolvingSymlinksInPath().standardizedFileURL.path
        var seen = Set<String>(), result: [URL] = []
        for copy in copies {
            let url = copy.resolvingSymlinksInPath().standardizedFileURL, path = url.path
            guard path != installed, seen.insert(path).inserted, !path.hasPrefix("/Volumes/"),
                  !url.pathComponents.contains(".Trash"), exists(path) else { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// With another copy installed, a registration change is safe only while that
    /// copy's widget is not the one registered. An unknown answer counts as the
    /// other copy winning.
    static func mayRegister(_ target: WidgetRegistrationTarget, duplicates: [URL], host: WidgetHostLookup) -> Bool {
        guard !duplicates.isEmpty else { return true }
        guard case .extensions(let registered) = host else { return false }
        let own = target.extensionURL.resolvingSymlinksInPath().standardizedFileURL.path
        return registered.allSatisfy { $0 == own }
    }

    /// `pluginkit -m -v -i com.weekleft.app.widget`: one line per matching plug-in,
    /// the path of its bundle in the last tab-separated field.
    static func hostExtensions(fromPluginKitOutput output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let field = line.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces),
                  field.hasPrefix("/"), field.hasSuffix(".appex") else { return nil }
            return URL(fileURLWithPath: field).resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    /// A listing that names the widget without a readable bundle path is an
    /// answer this code does not understand: unknown, never "none registered".
    static func hostLookup(fromPluginKitOutput output: String) -> WidgetHostLookup {
        let paths = hostExtensions(fromPluginKitOutput: output)
        return paths.isEmpty && output.contains(widgetIdentifier) ? .unknown : .extensions(paths)
    }

    /// Reads which widget extension PlugInKit uses; never changes a registration.
    static func widgetHost() -> WidgetHostLookup {
        guard (try? LiveProcessGuard.check(URL(fileURLWithPath: "/usr/bin/pluginkit"))) != nil else { return .unknown }
        let process = Process(), finished = DispatchSemaphore(value: 0), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-v", "-i", widgetIdentifier]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .unknown }
        // Drain the pipe while the tool runs, so neither a full pipe nor a stuck
        // tool can hold this check longer than its deadline.
        let listing = PluginKitListing(), drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            listing.data = output.fileHandleForReading.readDataToEndOfFile(); drained.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .unknown
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0,
              let data = listing.data, data.count < 65_536 else { return .unknown }
        return hostLookup(fromPluginKitOutput: String(decoding: data, as: UTF8.self))
    }
    private final class PluginKitListing: @unchecked Sendable {
        private let lock = NSLock(); private var stored: Data?
        var data: Data? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }
    /// Every application LaunchServices knows under the host's bundle identifier.
    static func registeredCopies() -> [URL] {
        (LSCopyApplicationURLsForBundleIdentifier("com.weekleft.app" as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
    }

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
        // Also before LSRegisterURL: a test never registers an installed copy (R2-X-03).
        guard (try? LiveProcessGuard.check(URL(fileURLWithPath: "/usr/bin/pluginkit"))) != nil else { return false }
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
    /// A process started from this path whose file an update moved or deleted is
    /// stopped too: `proc_pidpath` no longer names the path, but WidgetKit keeps
    /// asking it and macOS rejects every timeline of the old build (owner report 28.09).
    @discardableResult static func stopExtension(_ target: WidgetRegistrationTarget) -> Bool {
        // Under XCTest only a fixture extension in the temporary folder is signalled (R2-X-03).
        guard (try? LiveProcessGuard.check(URL(fileURLWithPath: target.executable))) != nil else { return false }
        guard let pids = allProcesses() else { return false }
        for pid in pids where runsExtension(pid, target) {
            let started = startTime(pid)
            if kill(pid, SIGTERM) != 0 && errno != ESRCH { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while started != nil, startTime(pid) == started {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return true
    }

    /// Extension processes of an earlier build still running after an update.
    static func staleExtensionProcesses(_ target: WidgetRegistrationTarget) -> [pid_t] {
        guard let pids = allProcesses() else { return [] }
        return pids.filter { pid in
            processName(pid) == extensionName
                && isStale(current: executablePath(pid), launchedAs: ProcessInspection.launchPath(pid), target: target.executable)
        }
    }

    static let extensionName = "LunavectWidget"

    /// Started from the installed extension's path, but no longer running that file.
    static func isStale(current: String?, launchedAs: String?, target: String) -> Bool {
        guard let launchedAs, same(launchedAs, target) else { return false }
        return current.map { !same($0, target) } ?? true
    }

    /// The kernel reports /private/var where a launch may have used /var, and a
    /// moved file no longer exists: compare the real path of the longest existing
    /// folder followed by the remaining components.
    private static func same(_ path: String, _ target: String) -> Bool {
        path == target || canonical(path) == canonical(target)
    }
    static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL, rest: [String] = []
        while url.path != "/" {
            if let real = realpath(url.path, nil) {
                defer { free(real) }
                return ([String(cString: real)] + rest.reversed()).joined(separator: "/")
            }
            rest.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        return path
    }

    private static func runsExtension(_ pid: pid_t, _ target: WidgetRegistrationTarget) -> Bool {
        if executablePath(pid) == target.executable { return true }
        return processName(pid) == extensionName
            && isStale(current: executablePath(pid), launchedAs: ProcessInspection.launchPath(pid), target: target.executable)
    }

    private static func allProcesses() -> [pid_t]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 128)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = proc_listallpids(&pids, bytes)
        guard count > 0, count < pids.count else { return nil }
        return pids.prefix(Int(count)).filter { $0 > 1 }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Identifies this process across PID reuse while waiting for it to exit.
    private static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}

/// Settings → Widgets: another installed copy of Lunavect and what to do about it (R3-01).
struct WidgetDuplicateCopyNotice: View {
    @ObservedObject var status: WidgetRegistrationStatus
    var body: some View {
        if !status.otherCopies.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    InterfaceLabel(L("Установлена ещё одна копия Lunavect"), .warning)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                    Text(L("Пока установлены две копии, виджеты на рабочем столе могут показывать заглушки. Оставьте одну: переместите лишнюю копию в Корзину и перезапустите Lunavect."))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(status.otherCopies, id: \.self) { copy in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(copy.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([copy]) }
                        }
                    }
                    if status.confirmationSkipped {
                        Text(L("macOS показывает виджеты из другой копии, поэтому эта копия не подтверждает их регистрацию, пока другая установлена."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("widget-duplicate-copy")
        }
    }
}
