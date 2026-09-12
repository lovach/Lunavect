import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import Carbon
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct PanelShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

@MainActor protocol FeaturePermissionAccess {
    var loginStatus: SMAppService.Status { get }
    func notificationStatus() async -> UNAuthorizationStatus
    func authorizeNotifications() async throws -> Bool
    func registerLogin() throws
    func unregisterLogin() async throws
    func openNotificationSettings() -> Bool
    func openLoginSettings()
}

@MainActor struct SystemFeaturePermissionAccess: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }
    func notificationStatus() async -> UNAuthorizationStatus {
        guard Bundle.main.bundleIdentifier == "com.weekleft.app" else { return .notDetermined }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func authorizeNotifications() async throws -> Bool {
        guard Bundle.main.bundleIdentifier == "com.weekleft.app" else { throw CocoaError(.featureUnsupported) }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func registerLogin() throws { try SMAppService.mainApp.register() }
    func unregisterLogin() async throws { try await SMAppService.mainApp.unregister() }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func openNotificationSettings() -> Bool {
        // System Settings supports this pane URL; approval is still a user action.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.weekleft.app")!)
    }
}

@MainActor final class AppFeatures: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AppFeatures()
    @Published var banners: Bool { didSet { defaults.set(banners, forKey: "noticeBanners") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "noticeSounds") } }
    @Published var completion: Bool { didSet { defaults.set(completion, forKey: "noticeCompletion") } }
    @Published var permission: Bool { didSet { defaults.set(permission, forKey: "noticePermission") } }
    @Published var input: Bool { didSet { defaults.set(input, forKey: "noticeInput") } }
    @Published var launchStatus: SMAppService.Status = .notRegistered
    @Published var notificationAllowed = false
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    enum PermissionKind { case login, notifications }
    @Published private(set) var waitingPermission: PermissionKind?
    @Published var issue: String?
    @Published var busy = false
    @Published private(set) var shortcut: PanelShortcut?
    var onTogglePanel: (() -> Void)?
    var onOpenSession: ((String) -> Void)?
    var onPermissionFinished: (() -> Void)?
    private let defaults: UserDefaults
    private let permissionAccess: FeaturePermissionAccess
    private let now: () -> Date
    private var permissionTimer: Timer?
    private var permissionDeadline: Date?
    private var permissionGeneration = 0
    private var checkingPermissions = false
    private var tracker = SessionNoticeTracker()
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == "com.weekleft.app" ? .current() : nil
    }
    init(defaults: UserDefaults = .standard, permissionAccess: FeaturePermissionAccess? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.permissionAccess = permissionAccess ?? SystemFeaturePermissionAccess(); self.now = now
        banners = defaults.bool(forKey: "noticeBanners")
        sounds = defaults.bool(forKey: "noticeSounds")
        completion = defaults.object(forKey: "noticeCompletion") as? Bool ?? true
        permission = defaults.object(forKey: "noticePermission") as? Bool ?? true
        input = defaults.object(forKey: "noticeInput") as? Bool ?? true
        shortcut = defaults.data(forKey: "panelShortcut").flatMap { try? JSONDecoder().decode(PanelShortcut.self, from: $0) }
        super.init()
    }
    func start() {
        center?.delegate = self
        if let shortcut { registerShortcut(shortcut, save: false) }
        refreshSystemState()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemState() }
        }
    }
    func refreshSystemState() {
        Task { await checkSystemState() }
    }
    func checkSystemState() async {
        guard !checkingPermissions else { return }
        checkingPermissions = true; defer { checkingPermissions = false }
        let generation = permissionGeneration
        launchStatus = permissionAccess.loginStatus
        notificationAuthorization = await permissionAccess.notificationStatus()
        notificationAllowed = notificationAuthorization == .authorized || notificationAuthorization == .provisional
        guard generation == permissionGeneration, let waiting = waitingPermission else { return }
        guard let deadline = permissionDeadline, now() < deadline else {
            stopPermissionWatch(); issue = L("Ожидание завершено. Можно продолжить настройку в любое время."); return
        }
        if (waiting == .login && launchStatus == .enabled) || (waiting == .notifications && notificationAllowed) {
            if waiting == .notifications { banners = true }
            stopPermissionWatch(); issue = nil; onPermissionFinished?()
        }
    }
    func openPermissionSettings(_ kind: PermissionKind) {
        stopPermissionWatch(); issue = nil
        waitingPermission = kind; permissionDeadline = now().addingTimeInterval(600)
        if kind == .notifications {
            guard permissionAccess.openNotificationSettings() else {
                stopPermissionWatch(); issue = L("Не удалось открыть настройки macOS."); return
            }
        } else { permissionAccess.openLoginSettings() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSystemState() }
        }
        RunLoop.main.add(timer, forMode: .common); permissionTimer = timer
        refreshSystemState()
    }
    private func stopPermissionWatch() {
        permissionGeneration += 1; waitingPermission = nil; permissionDeadline = nil
        permissionTimer?.invalidate(); permissionTimer = nil
    }
    func cancelPermissionWait() async {
        let kind = waitingPermission
        stopPermissionWatch()
        if kind == .notifications { await setBanners(false) }
        else if kind == .login { await setLogin(false) }
    }
    func setBanners(_ enabled: Bool) async {
        guard !busy else { return }
        issue = nil
        guard enabled else {
            if waitingPermission == .notifications { stopPermissionWatch() }
            banners = false; center?.removeAllPendingNotificationRequests(); center?.removeAllDeliveredNotifications(); return
        }
        busy = true; defer { busy = false }
        do {
            notificationAuthorization = await permissionAccess.notificationStatus()
            if notificationAuthorization == .denied { openPermissionSettings(.notifications); return }
            notificationAllowed = try await permissionAccess.authorizeNotifications()
            banners = notificationAllowed
            notificationAuthorization = await permissionAccess.notificationStatus()
            if !notificationAllowed { issue = L("Разрешите уведомления Lunavect в системных настройках macOS.") }
        } catch { issue = L("Не удалось включить уведомления. Проверьте настройки macOS.") }
    }
    func setLogin(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true; issue = nil; defer { busy = false; refreshSystemState() }
        do {
            if enabled {
                if permissionAccess.loginStatus != .enabled && permissionAccess.loginStatus != .requiresApproval { try permissionAccess.registerLogin() }
                if permissionAccess.loginStatus == .requiresApproval { openPermissionSettings(.login) }
            } else {
                if waitingPermission == .login { stopPermissionWatch() }
                try await permissionAccess.unregisterLogin()
            }
        } catch {
            if enabled && permissionAccess.loginStatus == .requiresApproval { openPermissionSettings(.login) }
            else { issue = L("Не удалось изменить автозапуск. Проверьте настройки macOS.") }
        }
    }
    func observe(_ rows: [AgentSession]) {
        let notices = tracker.update(rows)
        guard banners || sounds else { return }
        for notice in notices {
            guard (notice.kind == .completed && completion) || (notice.kind == .permission && permission) || (notice.kind == .input && input) else { continue }
            deliver(title: notice.kind.title, body: notice.session.provider.title + " · " + notice.session.title, sessionID: notice.session.id)
        }
    }
    func testNotification() {
        deliver(title: "Lunavect", body: L("Проверочное уведомление"), sessionID: nil)
    }
    private func deliver(title: String, body: String, sessionID: String?) {
        // Each channel is independent. Sound-only mode doesn't request notification access.
        if banners, notificationAllowed, let center {
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            if sounds { content.sound = .default }
            if let sessionID { content.userInfo = ["sessionID": sessionID] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { [weak self] error in
                if error != nil { Task { @MainActor in self?.issue = L("Не удалось показать уведомление.") } }
            }
        } else if sounds { NSSound(named: "Glass")?.play() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            var options: UNNotificationPresentationOptions = banners ? [.banner, .list] : []
            if sounds { options.insert(.sound) }
            completionHandler(options)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in if let id { onOpenSession?(id) }; completionHandler() }
    }
    func registerShortcut(_ value: PanelShortcut?, save: Bool = true) {
        issue = nil
        if value == shortcut, hotKey != nil { return }
        var candidate: EventHotKeyRef?
        if let value {
            if hotKeyHandler == nil {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                    guard let context else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<AppFeatures>.fromOpaque(context).takeUnretainedValue()
                    Task { @MainActor in owner.onTogglePanel?() }
                    return noErr
                }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
                guard status == noErr else { issue = L("Не удалось зарегистрировать сочетание клавиш."); return }
            }
            let status = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x4C554E41, id: 1), GetApplicationEventTarget(), 0, &candidate)
            guard status == noErr else { issue = L("Это сочетание недоступно. Выберите другое."); return }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; shortcut = value
        if save {
            if let value { defaults.set(try? JSONEncoder().encode(value), forKey: "panelShortcut") }
            else { defaults.removeObject(forKey: "panelShortcut") }
        }
    }
    deinit { permissionTimer?.invalidate() }
}

struct PermissionWaitView: View {
    @ObservedObject var features: AppFeatures
    var kind: AppFeatures.PermissionKind
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Ожидаем разрешение macOS…")).font(.system(size: 12))
            }
            Text(L(kind == .notifications ? "Включите уведомления Lunavect. После подтверждения вернёмся сюда." : "Разрешите автозапуск Lunavect. После подтверждения вернёмся сюда."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Открыть настройки")) { features.openPermissionSettings(kind) }
                Spacer()
                Button(L("Отмена")) { Task { await features.cancelPermissionWait() } }
            }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct AppBehaviorSettings: View {
    @ObservedObject var features = AppFeatures.shared
    @State private var recording = false
    @State private var monitor: Any?
    var body: some View {
        GroupBox(L("Запуск и быстрый доступ")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("Запускать при входе в macOS")); Spacer()
                    Toggle(L("Запускать при входе в macOS"), isOn: Binding(get: { features.launchStatus == .enabled || features.launchStatus == .requiresApproval }, set: { value in Task { await features.setLogin(value) } }))
                        .labelsHidden().toggleStyle(.switch).disabled(features.busy)
                        .accessibilityIdentifier("launch-at-login")
                }
                if features.waitingPermission == .login { PermissionWaitView(features: features, kind: .login) }
                else if features.launchStatus == .requiresApproval {
                    Button(L("Разрешить в настройках macOS")) { features.openPermissionSettings(.login) }
                        .buttonStyle(.link)
                }
                Divider()
                HStack {
                    Text(L("Открыть панель сессий")); Spacer()
                    Button(recording ? L("Нажмите сочетание…") : features.shortcut?.label ?? L("Назначить клавиши")) { beginRecording() }
                    if features.shortcut != nil {
                        Button { features.registerShortcut(nil) } label: { InterfaceIcon(.close) }
                            .buttonStyle(.plain).help(L("Убрать сочетание")).accessibilityLabel(L("Убрать сочетание"))
                    }
                }
                Text(L("Используйте ⌘, ⌃ или ⌥ вместе с клавишей. Esc отменяет ввод."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let issue = features.issue { Text(issue).font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(12)
        }.onAppear { features.refreshSystemState() }.onDisappear { stopRecording() }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false
    }
    private func beginRecording() {
        stopRecording(); recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .control, .option]).isEmpty,
                  let character = event.charactersIgnoringModifiers?.uppercased(), !character.isEmpty else { return nil }
            var modifiers: UInt32 = 0, prefix = ""
            for (flag, carbon, text) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
                if flags.contains(flag) { modifiers |= UInt32(carbon); prefix += text }
            }
            features.registerShortcut(PanelShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: prefix + character))
            stopRecording(); return nil
        }
    }
}

struct NotificationSettingsView: View {
    @ObservedObject var features = AppFeatures.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(L("Способ уведомления")) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L("Всплывающие уведомления"), isOn: Binding(get: { features.banners || features.waitingPermission == .notifications }, set: { value in Task { await features.setBanners(value) } }))
                        .disabled(features.busy).accessibilityIdentifier("notification-banners")
            if features.waitingPermission == .notifications { PermissionWaitView(features: features, kind: .notifications) }
            else if features.notificationAuthorization == .denied {
                Button(L("Разрешить уведомления в macOS")) { features.openPermissionSettings(.notifications) }
                    .accessibilityIdentifier("notification-settings")
            }
                    Toggle(L("Звуковые уведомления"), isOn: $features.sounds)
                    Text(L("Оба способа выключены по умолчанию. Нажатие на уведомление открывает сессию."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.toggleStyle(.switch).padding(12)
            }
            if !features.banners && !features.sounds {
                Text(L("Включите баннеры или звук, чтобы выбрать события.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            GroupBox(L("Когда уведомлять")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("Ответ готов"), isOn: $features.completion)
                    Toggle(L("Нужно разрешение"), isOn: $features.permission)
                    Toggle(L("Ждёт ответа"), isOn: $features.input)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .disabled(!features.banners && !features.sounds)
            }
            Button(L("Проверить уведомление")) { features.testNotification() }
                .disabled(!features.banners && !features.sounds)
            if let issue = features.issue { Text(issue).font(.system(size: 12)).foregroundStyle(.orange) }
        }.onAppear { features.refreshSystemState() }
    }
}
