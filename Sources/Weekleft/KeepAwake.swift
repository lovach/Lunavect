import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
import AwakeService
#endif

enum AwakeDuration: Int, CaseIterable {
    case fifteenMinutes = 900, oneHour = 3600, fourHours = 14400, untilStopped = 0
    var title: String {
        switch self {
        case .fifteenMinutes: return L("На 15 минут")
        case .oneHour: return L("На 1 час")
        case .fourHours: return L("На 4 часа")
        case .untilStopped: return L("До выключения")
        }
    }
}

enum AwakePermissionOrigin { case sessions, settings }
enum AwakeRecoveryAction { case retryConnection, reviewConditions, none }

@MainActor final class KeepAwake: ObservableObject {
    typealias TimerScheduler = @MainActor (TimeInterval, @escaping @Sendable (Timer) -> Void) -> Timer
    static let shared = KeepAwake(client: AwakeServiceClient())
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var isAvailable: Bool
    @Published private(set) var isAwaitingPermission = false
    @Published private(set) var endsAt: Date?
    @Published var issue: String? {
        didSet { if issue == nil { recoveryAction = .none } }
    }
    @Published private(set) var recoveryAction = AwakeRecoveryAction.none
    @Published var duration: AwakeDuration {
        didSet { defaults.set(duration.rawValue, forKey: "awake.duration") }
    }
    @Published private(set) var safetyPolicy: AwakeSafetyPolicy
    @Published private(set) var idleGraceSeconds: Int
    @Published private(set) var automatic: Bool
    @Published private(set) var idleDeadline: Date?
    private var rows: [AgentSession] = []
    /// Automatic mode after a failed or refused start: no retry loop, but it is
    /// shown, lifted when the stop conditions change and retried after a pause.
    @Published private(set) var automaticSuspended = false
    private var suspendedAt: Date?
    static let suspensionRetry: TimeInterval = 300
    private let defaults: UserDefaults
    private let client: AwakeClient
    private let now: () -> Date
    private let scheduleTimer: TimerScheduler
    private var timer: Timer?
    private var checking = false
    private var generation = 0
    private var permissionTimer: Timer?
    private var permissionDeadline: Date?
    private var permissionDuration: AwakeDuration?
    private var permissionGeneration = 0
    private var permissionOrigin = AwakePermissionOrigin.sessions
    var onPermissionFinished: ((AwakePermissionOrigin) -> Void)?
    /// Worded like the "After sessions finish" choices, not in raw seconds.
    var automaticStopDescription: String {
        switch idleGraceSeconds {
        case 0: return L("Сон вернётся сразу после завершения работы.")
        case 30: return L("Сон вернётся через 30 секунд после завершения работы.")
        case 60: return L("Сон вернётся через 1 минуту после завершения работы.")
        case 120: return L("Сон вернётся через 2 минуты после завершения работы.")
        case 300: return L("Сон вернётся через 5 минут после завершения работы.")
        default: return L("Сон вернётся через {0} с после завершения работы.", String(idleGraceSeconds))
        }
    }
    var protectionDescription: String {
        var parts: [String] = []
        if !safetyPolicy.allowBattery { parts.append(L("Только от зарядки")) }
        if safetyPolicy.batteryProtection { parts.append(L("Остановка при заряде ≤{0}%", String(safetyPolicy.minimumBatteryPercent))) }
        if safetyPolicy.thermalProtection { parts.append(L("Остановка при перегреве")) }
        if parts.isEmpty { parts.append(L("Остановка по заряду и температуре выключена")) }
        return parts.joined(separator: " · ")
    }
    var statusDescription: String {
        if automatic && automaticSuspended && !isEnabled { return L("Приостановлено, повторим через 5 минут") }
        if automatic && endsAt == nil {
            if let idleDeadline { return L("До {0}", idleDeadline.formatted(.dateTime.hour().minute().locale(L10n.locale))) }
            return L(isEnabled ? "Пока работают сессии" : "Ждём работающие сессии")
        }
        return endsAt.map { L("До {0}", $0.formatted(.dateTime.hour().minute().locale(L10n.locale))) }
            ?? L(isEnabled ? "Работает до выключения" : "Экран погаснет, задачи продолжатся")
    }
    init(client: AwakeClient, now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard,
         scheduleTimer: TimerScheduler? = nil) {
        self.client = client; self.now = now; isAvailable = client.isAvailable
        self.scheduleTimer = scheduleTimer ?? { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true, block: action)
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
        self.defaults = defaults; automatic = defaults.bool(forKey: "awake.whileWorking")
        duration = AwakeDuration(rawValue: defaults.integer(forKey: "awake.duration")) ?? .untilStopped
        safetyPolicy = defaults.data(forKey: "awake.safety").flatMap {
            try? JSONDecoder().decode(AwakeSafetyPolicy.self, from: $0)
        }?.normalized ?? .init()
        let grace = defaults.object(forKey: "awake.idleGraceSeconds") as? Int ?? 60
        idleGraceSeconds = [0, 30, 60, 120, 300].contains(grace) ? grace : 60
    }
    func setIdleGrace(_ seconds: Int) {
        guard [0, 30, 60, 120, 300].contains(seconds) else { return }
        if let deadline = idleDeadline { idleDeadline = deadline.addingTimeInterval(Double(seconds - idleGraceSeconds)) }
        idleGraceSeconds = seconds; defaults.set(seconds, forKey: "awake.idleGraceSeconds")
        Task { await reconcileAutomatic() }
    }
    func setSafetyPolicy(_ policy: AwakeSafetyPolicy) async {
        guard !isBusy else { return }
        safetyPolicy = policy.normalized
        if let data = try? JSONEncoder().encode(safetyPolicy) { defaults.set(data, forKey: "awake.safety") }
        if automaticSuspended { liftSuspension(); issue = nil }
        guard isEnabled else { await reconcileAutomatic(); return }
        isBusy = true; defer { isBusy = false }
        do { try await client.configure(policy: safetyPolicy); issue = nil }
        catch {
            suspendAutomatic(); clearState(); client.disconnect()
            issue = message(for: error)
        }
    }
    /// - Returns: false when a start or stop in progress kept the reset from
    ///   applying completely; the caller reports it instead of a silent partial reset.
    @discardableResult func restoreDefaults() async -> Bool {
        guard !isBusy else { return false }
        cancelPermission()
        await setAutomatic(false)
        if isEnabled { await stop() }
        duration = AppDefaultSettings.awakeDuration
        setIdleGrace(AppDefaultSettings.awakeIdleGrace)
        await setSafetyPolicy(.init())
        return !automatic && !isEnabled && !isAwaitingPermission && safetyPolicy == AwakeSafetyPolicy().normalized
    }
    func observe(_ rows: [AgentSession]) {
        self.rows = rows
        guard automatic else { return }
        Task { await reconcileAutomatic() }
    }
    func setAutomatic(_ enabled: Bool) async {
        guard !isBusy else { return }
        automatic = enabled; defaults.set(enabled, forKey: "awake.whileWorking")
        liftSuspension(); idleDeadline = nil; issue = nil
        if enabled { await reconcileAutomatic() }
        else if isEnabled { await stop() }
    }
    private func suspendAutomatic() {
        automaticSuspended = automatic; suspendedAt = automatic ? now() : nil
    }
    private func liftSuspension() { automaticSuspended = false; suspendedAt = nil }
    func reconcileAutomatic() async {
        if automaticSuspended, let suspendedAt, now() < suspendedAt || now().timeIntervalSince(suspendedAt) >= Self.suspensionRetry {
            liftSuspension()
        }
        guard automatic, !automaticSuspended, !isBusy else { return }
        if rows.contains(where: { $0.effectivePhase(now: now()) == .running }) {
            idleDeadline = nil
            if !isEnabled {
                refreshPermission()
                guard isAvailable else { return }
                await start(for: .untilStopped)
            }
        } else if isEnabled {
            if idleDeadline == nil { idleDeadline = now().addingTimeInterval(Double(idleGraceSeconds)) }
            if let idleDeadline, now() >= idleDeadline { await stop() }
        }
    }
    func refreshPermission() { isAvailable = client.isAvailable }
    func requestPermission(from origin: AwakePermissionOrigin = .sessions) {
        guard !isBusy else { return }
        do {
            try client.requestPermission()
            refreshPermission(); issue = nil
            permissionGeneration += 1
            permissionDuration = duration
            permissionOrigin = origin
            permissionDeadline = now().addingTimeInterval(600)
            isAwaitingPermission = true
            if permissionTimer == nil {
                permissionTimer = scheduleTimer(1) { [weak self] _ in
                    Task { @MainActor in await self?.checkPermission() }
                }
            }
            Task { await checkPermission() }
        } catch { cancelPermission(); issue = message(for: error) }
    }
    func cancelPermission() {
        permissionGeneration += 1
        endPermissionWatch()
    }
    private func endPermissionWatch() {
        isAwaitingPermission = false
        permissionTimer?.invalidate(); permissionTimer = nil
        permissionDeadline = nil; permissionDuration = nil
    }
    /// Poll only after the user's explicit "Allow and turn on" action. This
    /// survives a transient popover closing while System Settings is active.
    func checkPermission() async {
        refreshPermission()
        guard isAwaitingPermission else { return }
        guard let deadline = permissionDeadline, now() < deadline else {
            cancelPermission()
            issue = L("Разрешение пока не получено. Нажмите «Разрешить и включить», чтобы повторить.")
            return
        }
        guard isAvailable, let requestedDuration = permissionDuration else { return }
        let attempt = permissionGeneration, origin = permissionOrigin
        endPermissionWatch()
        if automatic { await reconcileAutomatic() }
        else { await start(for: requestedDuration) }
        guard attempt == permissionGeneration else { return }
        onPermissionFinished?(origin)
    }
    func toggle() async {
        if automatic { await setAutomatic(false) }
        else if isEnabled { await stop() } else { await start() }
    }
    func start(for requestedDuration: AwakeDuration? = nil) async {
        guard !isBusy else { return }
        refreshPermission()
        guard isAvailable else { issue = message(for: AwakeFailure.permission); return }
        isBusy = true; defer { isBusy = false }
        generation += 1
        let generation = generation, duration = requestedDuration ?? self.duration
        do {
            try await client.begin(seconds: duration.rawValue, policy: safetyPolicy)
            guard generation == self.generation else { return }
            if !automatic { self.duration = duration }
            endsAt = duration == .untilStopped ? nil : now().addingTimeInterval(TimeInterval(duration.rawValue))
            isEnabled = true; issue = nil
            if timer == nil {
                timer = scheduleTimer(10) { [weak self] _ in
                    Task { @MainActor in await self?.check() }
                }
            }
        } catch { suspendAutomatic(); clearState(); client.disconnect(); refreshPermission(); issue = message(for: error) }
    }
    func stop() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        generation += 1
        timer?.invalidate(); timer = nil
        do { try await client.end(); clearState(); issue = nil }
        catch {
            clearState(); client.disconnect()
            issue = L("Нет подтверждения выключения. Системный помощник вернёт обычный сон после потери связи с приложением.")
        }
    }
    func check() async {
        guard isEnabled, !isBusy, !checking else { return }
        if automatic { await reconcileAutomatic(); guard isEnabled else { return } }
        if let endsAt, now() >= endsAt { await stop(); return }
        checking = true; defer { checking = false }
        let generation = generation
        do { try await client.keepAlive() }
        catch {
            guard generation == self.generation else { return }
            suspendAutomatic()
            clearState(); client.disconnect(); issue = message(for: error)
        }
    }
    /// Invalidation releases the daemon lease even if the UI exits.
    func shutdown() { generation += 1; cancelPermission(); client.disconnect(); clearState() }
    private func clearState() { isEnabled = false; endsAt = nil; idleDeadline = nil; timer?.invalidate(); timer = nil }
    private func message(for error: Error) -> String {
        switch error as? AwakeFailure {
        case .battery, .thermal, .power: recoveryAction = .reviewConditions
        case .permission, .external, .recovery, .expired, .busy: recoveryAction = .none
        default: recoveryAction = .retryConnection
        }
        switch error as? AwakeFailure {
        case .permission: return L("Для работы с закрытой крышкой разрешите Lunavect в настройках macOS.")
        case .external: return L("Сон уже отключён другой программой. Сначала выключите её режим без сна.")
        case .battery: return L("Режим выключен: заряд аккумулятора {0}% или ниже.", String(safetyPolicy.minimumBatteryPercent))
        case .thermal: return L("Режим выключен: Mac слишком нагрелся.")
        case .power: return L("Режим выключен: разрешена работа только от зарядки.")
        case .recovery: return L("Не удалось подтвердить возврат обычного сна. Системный помощник повторяет попытку.")
        case .expired: return L("Время режима без сна истекло.")
        case .busy: return L("Режим уже используется другой копией Lunavect.")
        default: return L("Помощник не ответил. Режим с закрытой крышкой не включён. Повторите подключение помощника.")
        }
    }
    // Timer invalidation stays on the same actor that registered each timer,
    // including when the last reference is released away from the main actor.
    isolated deinit { timer?.invalidate(); permissionTimer?.invalidate() }
}

struct KeepAwakeButton: View {
    @ObservedObject var awake: KeepAwake
    var isExpanded: Bool
    var onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            InterfaceIcon(.eye, size: 18)
        }
        .buttonStyle(InterfaceToolbarStyle(selected: isExpanded, active: awake.isEnabled))
        .accessibilityIdentifier("keep-awake-controls")
        .accessibilityLabel("Keep Awake")
        .accessibilityValue([awake.isEnabled ? L("Включено") : L("Выключено"), awake.issue].compactMap { $0 }.joined(separator: ". "))
        .help("Keep Awake · " + awake.statusDescription)
        .overlay(alignment: .topTrailing) {
            if awake.issue != nil { Circle().fill(.orange).frame(width: 6, height: 6).allowsHitTesting(false) }
        }
    }
}

struct KeepAwakeControls: View {
    @ObservedObject var awake: KeepAwake
    var showsModeControls = true
    var permissionOrigin = AwakePermissionOrigin.sessions
    var onReviewConditions: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep Awake").font(.system(size: 12, weight: .semibold))
                    Text(!awake.isAvailable ? L("Разрешение macOS · один раз") : awake.statusDescription)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if awake.isBusy { ProgressView().controlSize(.small) }
                if awake.isAvailable && !awake.isAwaitingPermission {
                    Toggle("Keep Awake", isOn: Binding(get: { awake.isEnabled || awake.automatic }, set: { value in
                        Task {
                            if !value && awake.automatic { await awake.setAutomatic(false) }
                            else if value { await awake.start() } else { await awake.stop() }
                        }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.orange)
                    .disabled(awake.isBusy)
                    .accessibilityIdentifier("keep-awake-switch")
                }
            }
            if awake.isAwaitingPermission {
                VStack(alignment: .leading, spacing: 6) {
                    permissionStep("1", L("Включите Lunavect в разделе «Разрешить в фоне»."))
                    permissionStep("2", L("Подтвердите доступ паролем или Touch ID."))
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("Ждём разрешение…")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Открыть настройки")) { awake.requestPermission(from: permissionOrigin) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("awake-open-settings")
                    Spacer(minLength: 0)
                    Button { awake.cancelPermission() } label: {
                        Text(L("Отмена")).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("awake-cancel-permission")
                }
                Text(L("После подтверждения вернёмся сюда и включим режим."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if awake.isAvailable {
                if showsModeControls {
                Toggle(L("Автоматически, пока работают сессии"), isOn: Binding(get: { awake.automatic }, set: { enabled in
                    Task { await awake.setAutomatic(enabled) }
                })).toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                    .disabled(awake.isBusy).accessibilityIdentifier("awake-automatic")
                if awake.automatic {
                    Text(awake.isEnabled ? awake.automaticStopDescription : L("Ждём работающие сессии. Ожидание ввода не удерживает Mac без сна."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                HStack(spacing: 5) {
                    ForEach(AwakeDuration.allCases, id: \.rawValue) { duration in
                        Button {
                            if awake.isEnabled { Task { await awake.start(for: duration) } } else { awake.duration = duration }
                        } label: {
                            Text(shortTitle(duration)).font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 25)
                                .foregroundStyle(awake.duration == duration ? Color.primary : Color.secondary)
                                .background(Color.primary.opacity(awake.duration == duration ? 0.11 : 0.035), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(awake.isBusy)
                            .accessibilityLabel(duration.title)
                            .accessibilityIdentifier("awake-duration-" + String(duration.rawValue))
                            .accessibilityAddTraits(awake.duration == duration ? .isSelected : [])
                            .help(duration.title)
                    }
                }
                }
                }
                Text(awake.protectionDescription)
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Откроем нужный раздел macOS. Включите Lunavect и подтвердите доступ."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { awake.requestPermission(from: permissionOrigin) } label: {
                    HStack {
                        Text(L("Разрешить и включить"))
                        Spacer()
                        InterfaceIcon(.external, size: 12)
                    }.padding(.vertical, 3).frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent).tint(.blue).controlSize(.small)
                    .accessibilityIdentifier("awake-authorize")
                Text(L("Режим также блокирует ручной сон. Не убирайте работающий Mac в сумку."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let issue = awake.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if awake.recoveryAction == .retryConnection {
                Button(L("Повторить подключение")) {
                    if awake.automatic { Task { await awake.setAutomatic(true) } }
                    else { Task { await awake.start() } }
                }.disabled(awake.isBusy).accessibilityIdentifier("awake-retry")
                } else if awake.recoveryAction == .reviewConditions {
                    if let onReviewConditions {
                        Button(L("Условия остановки"), action: onReviewConditions)
                            .accessibilityIdentifier("awake-review-conditions")
                    } else {
                        Text(L("Проверьте условия остановки ниже. Повторное включение доступно после изменения условий."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(11)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .contain).accessibilityIdentifier("keep-awake-panel")
            .task { await awake.checkPermission() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await awake.checkPermission() }
            }
    }
    private func permissionStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number).font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16).background(Color.primary.opacity(0.08), in: Circle())
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func shortTitle(_ duration: AwakeDuration) -> String {
        switch duration {
        case .fifteenMinutes: return L("15 мин")
        case .oneHour: return L("1 ч")
        case .fourHours: return L("4 ч")
        case .untilStopped: return "∞"
        }
    }
}
