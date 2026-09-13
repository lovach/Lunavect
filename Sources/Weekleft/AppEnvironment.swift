import Foundation
import Combine
import Darwin
#if SWIFT_PACKAGE
import WeekleftCore
import AwakeService
#endif

/// One writer per local data directory, including direct executable launches.
/// The OS releases the lease on exit/crash; the file is never unlinked while held.
final class AppInstanceLease {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(directory: URL) throws -> AppInstanceLease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("app-instance.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var state = stat()
        guard fstat(descriptor, &state) == 0, (state.st_mode & S_IFMT) == S_IFREG,
              state.st_uid == geteuid(), state.st_nlink == 1 else {
            close(descriptor)
            throw POSIXError(.EPERM)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let error = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return AppInstanceLease(descriptor: descriptor)
    }
    deinit { close(descriptor) }
}

/// Protect observation and helper heartbeats from App Nap while requested work
/// is active, without preventing idle system/display sleep.
@MainActor final class ActivityContinuity {
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?
    private var running = false
    private var keepAwake = false

    init(begin: @escaping () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                              reason: "Observe running sessions and maintain Keep Awake")
    }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }
    func setRunning(_ value: Bool) { running = value; reconcile() }
    func setKeepAwake(_ value: Bool) { keepAwake = value; reconcile() }
    private func reconcile() {
        if running || keepAwake {
            if token == nil { token = begin() }
        } else if let token {
            end(token)
            self.token = nil
        }
    }
    func stop() { running = false; keepAwake = false; reconcile() }
    isolated deinit { if let token { end(token) } }
}

/// Parse preview switches before constructing any live store or preparing defaults.
enum AppPreviewRequest: Equatable {
    enum ParseError: Error { case invalidOrUnsupportedArguments }
    case sessions(URL)
    case render(URL)

    static func parse(_ arguments: [String], enabled: Bool) throws -> Self? {
        let flags = ["--session-preview", "--render-native"]
        let indices = arguments.indices.filter { flags.contains(arguments[$0]) }
        guard !indices.isEmpty else { return nil }
        guard enabled, indices.count == 1, let index = indices.first,
              arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--"),
              !arguments[index + 1].isEmpty else { throw ParseError.invalidOrUnsupportedArguments }
        let url = URL(fileURLWithPath: arguments[index + 1])
        return arguments[index] == "--session-preview" ? .sessions(url) : .render(url)
    }
}

/// The live application and previews compose the same views with explicit services.
/// A preview owns its defaults and files, and cannot start integrations.
@MainActor final class AppEnvironment {
    let store: AppStore
    let sessions: SessionStore
    let menuBarAppearance: MenuBarAppearance
    let features: AppFeatures
    let updates: AppUpdates
    let awake: KeepAwake
    let language: LanguageSettings
    let defaults: UserDefaults
    let isPreview: Bool
    private let cleanup: () -> Void
    private let activityContinuity: ActivityContinuity?
    private var awakeObservation: AnyCancellable?

    private init(store: AppStore, sessions: SessionStore, defaults: UserDefaults,
                 menuBarAppearance: MenuBarAppearance, features: AppFeatures,
                 updates: AppUpdates, awake: KeepAwake, language: LanguageSettings,
                 isPreview: Bool, cleanup: @escaping () -> Void = {}) {
        self.store = store; self.sessions = sessions; self.defaults = defaults
        self.menuBarAppearance = menuBarAppearance; self.features = features
        self.updates = updates; self.awake = awake; self.language = language
        self.isPreview = isPreview; self.cleanup = cleanup
        self.activityContinuity = isPreview ? nil : ActivityContinuity()
        if !isPreview {
            awakeObservation = awake.$isEnabled.sink { [weak activityContinuity] enabled in
                activityContinuity?.setKeepAwake(enabled)
            }
        }
    }

    static func live() -> AppEnvironment {
        AppEnvironment(store: AppStore(), sessions: SessionStore(), defaults: .standard,
                       menuBarAppearance: MenuBarAppearance(), features: .shared,
                       updates: .shared, awake: .shared, language: .shared, isPreview: false)
    }

    static func preview(rows: [AgentSession], now: Date = Date(), languageCode: String = "en",
                        state: SharedState = SharedState(), activityHistory: ActivityHistory = ActivityHistory(),
                        activityDetails: ActivityDetails = ActivityDetails()) throws -> AppEnvironment {
        let name = "Lunavect.Preview." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { throw CocoaError(.fileWriteUnknown) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defaults.set(languageCode, forKey: "languageCode")
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: false)
        let store = AppStore(state: state, savesChanges: false, activityHistory: activityHistory,
                             activityDetails: activityDetails, isolated: true, defaults: defaults)
        let sessions = SessionStore(directory: directory, defaults: defaults, isolated: true, now: { now })
        sessions.sessions = rows; sessions.updatedAt = now
        return AppEnvironment(store: store, sessions: sessions, defaults: defaults,
            menuBarAppearance: MenuBarAppearance(defaults: defaults),
            features: AppFeatures(defaults: defaults, isolated: true),
            updates: AppUpdates(defaults: defaults, isolated: true),
            awake: KeepAwake(client: PreviewAwakeClient(), now: { now }, defaults: defaults),
            language: LanguageSettings(defaults: defaults, reloadWidgets: {}), isPreview: true,
            cleanup: {
                defaults.removePersistentDomain(forName: name)
                try? FileManager.default.removeItem(at: directory)
            })
    }

    func observeActivityContinuity(_ rows: [AgentSession], now: Date) {
        activityContinuity?.setRunning(rows.contains { $0.effectivePhase(now: now) == .running })
    }

    func stop() {
        awakeObservation = nil
        activityContinuity?.stop()
        features.stop(); sessions.stop(); store.stop(); awake.shutdown()
        cleanup()
    }
}

@MainActor private final class PreviewAwakeClient: AwakeClient {
    var isAvailable: Bool { false }
    func requestPermission() throws { throw AwakeFailure.unavailable }
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { throw AwakeFailure.unavailable }
    func configure(policy: AwakeSafetyPolicy) async throws { throw AwakeFailure.unavailable }
    func keepAlive() async throws {}
    func end() async throws {}
    func disconnect() {}
}
