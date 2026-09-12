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

@MainActor final class KeepAwake: ObservableObject {
    static let shared = KeepAwake(client: AwakeServiceClient())
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var isAvailable: Bool
    @Published private(set) var isAwaitingPermission = false
    @Published private(set) var endsAt: Date?
    @Published var issue: String?
    @Published var duration: AwakeDuration = .untilStopped
    private let client: AwakeClient
    private let now: () -> Date
    private var timer: Timer?
    private var checking = false
    private var generation = 0
    private var permissionTimer: Timer?
    private var permissionDeadline: Date?
    private var permissionDuration: AwakeDuration?
    private var permissionGeneration = 0
    var onPermissionFinished: (() -> Void)?
    init(client: AwakeClient, now: @escaping () -> Date = Date.init) {
        self.client = client; self.now = now; isAvailable = client.isAvailable
    }
    func refreshPermission() { isAvailable = client.isAvailable }
    func requestPermission() {
        guard !isBusy else { return }
        do {
            try client.requestPermission()
            refreshPermission(); issue = nil
            permissionGeneration += 1
            permissionDuration = duration
            permissionDeadline = now().addingTimeInterval(600)
            isAwaitingPermission = true
            if permissionTimer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.checkPermission() }
                }
                RunLoop.main.add(timer, forMode: .common); permissionTimer = timer
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
        let attempt = permissionGeneration
        endPermissionWatch()
        await start(for: requestedDuration)
        guard attempt == permissionGeneration else { return }
        onPermissionFinished?()
    }
    func toggle() async { if isEnabled { await stop() } else { await start() } }
    func start(for requestedDuration: AwakeDuration? = nil) async {
        guard !isBusy else { return }
        refreshPermission()
        guard isAvailable else { issue = message(for: AwakeFailure.permission); return }
        isBusy = true; defer { isBusy = false }
        generation += 1
        let generation = generation, duration = requestedDuration ?? self.duration
        do {
            try await client.begin(seconds: duration.rawValue)
            guard generation == self.generation else { return }
            self.duration = duration
            endsAt = duration == .untilStopped ? nil : now().addingTimeInterval(TimeInterval(duration.rawValue))
            isEnabled = true; issue = nil
            if timer == nil {
                let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.check() }
                }
                RunLoop.main.add(timer, forMode: .common); self.timer = timer
            }
        } catch { clearState(); client.disconnect(); refreshPermission(); issue = message(for: error) }
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
        if let endsAt, now() >= endsAt { await stop(); return }
        checking = true; defer { checking = false }
        let generation = generation
        do { try await client.keepAlive() }
        catch {
            guard generation == self.generation else { return }
            clearState(); client.disconnect(); issue = message(for: error)
        }
    }
    /// Invalidation releases the daemon lease even if the UI exits.
    func shutdown() { generation += 1; cancelPermission(); client.disconnect(); clearState() }
    private func clearState() { isEnabled = false; endsAt = nil; timer?.invalidate(); timer = nil }
    private func message(for error: Error) -> String {
        switch error as? AwakeFailure {
        case .permission: return L("Для работы с закрытой крышкой разрешите Lunavect в настройках macOS.")
        case .external: return L("Сон уже отключён другой программой. Сначала выключите её режим без сна.")
        case .battery: return L("Режим выключен: заряд аккумулятора 10% или ниже.")
        case .thermal: return L("Режим выключен: Mac слишком нагрелся.")
        case .recovery: return L("Не удалось подтвердить возврат обычного сна. Системный помощник повторяет попытку.")
        case .expired: return L("Время режима без сна истекло.")
        case .busy: return L("Режим уже используется другой копией Lunavect.")
        default: return L("Нет связи с системным помощником. Режим не подтверждён; обычный сон вернётся после потери связи.")
        }
    }
    deinit { timer?.invalidate(); permissionTimer?.invalidate() }
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
        .accessibilityLabel(L("Не спать с закрытой крышкой"))
        .accessibilityValue(awake.isEnabled ? L("Включено") : L("Выключено"))
        .help(L("Не спать с закрытой крышкой") + " · " + (awake.isEnabled ? awake.endsAt.map { L("До {0}", $0.formatted(.dateTime.hour().minute().locale(L10n.locale))) } ?? L("Работает до выключения") : L("Выключено")))
        .alert(L("Режим без сна"), isPresented: Binding(get: { awake.issue != nil }, set: { if !$0 { awake.issue = nil } })) {
            Button(L("Понятно")) { awake.issue = nil }
        } message: { Text(awake.issue ?? "") }
    }
}

struct KeepAwakeControls: View {
    @ObservedObject var awake: KeepAwake
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Не спать с закрытой крышкой")).font(.system(size: 12, weight: .semibold))
                    Text(!awake.isAvailable ? L("Разрешение macOS · один раз") : awake.endsAt.map { L("До {0}", $0.formatted(.dateTime.hour().minute().locale(L10n.locale))) }
                         ?? (awake.isEnabled ? L("Работает до выключения") : L("Экран погаснет, задачи продолжатся")))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if awake.isBusy { ProgressView().controlSize(.small) }
                if awake.isAvailable && !awake.isAwaitingPermission {
                    Toggle(L("Не спать с закрытой крышкой"), isOn: Binding(get: { awake.isEnabled }, set: { value in
                        Task { if value { await awake.start() } else { await awake.stop() } }
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
                    Button(L("Открыть настройки")) { awake.requestPermission() }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("awake-open-settings")
                    Spacer(minLength: 0)
                    Button(L("Отмена")) { awake.cancelPermission() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("awake-cancel-permission")
                }
                Text(L("После подтверждения вернёмся сюда и включим режим."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if awake.isAvailable {
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
                Text(L("Отключится при заряде ≤10% или перегреве. Не убирайте работающий Mac в сумку."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Откроем нужный раздел macOS. Включите Lunavect и подтвердите доступ."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { awake.requestPermission() } label: {
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
