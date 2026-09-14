import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import Carbon
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor enum NotificationAudio {
    static let completionFilename = "lunavect-complete.wav"
    static let completionURL = AnimationResources.url(forResource: "lunavect-complete", withExtension: "wav")
    private static let completion = completionURL.flatMap { NSSound(contentsOf: $0, byReference: false) }
    static func play(_ kind: SessionNoticeKind) {
        if kind == .completed { completion?.stop(); completion?.play() }
        else { NSSound(named: "Glass")?.play() }
    }
}

struct PanelShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    var displayLabel: String {
        var prefix = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { prefix += symbol }
        }
        return prefix + Self.keyLabel(keyCode)
    }
    static func keyLabel(_ code: UInt32) -> String {
        let names: [UInt32: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "␣", 50: "`", 51: "⌫", 53: "⎋",
            64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "↖", 116: "⇞",
            117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? L("Клавиша {0}", String(code))
    }
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
    typealias BannerSender = (UNNotificationRequest, @escaping @Sendable (Error?) -> Void) -> Void
    static let shared = AppFeatures()
    @Published var banners: Bool { didSet { defaults.set(banners, forKey: "noticeBanners") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "noticeSounds") } }
    @Published var completion: Bool { didSet { defaults.set(completion, forKey: "noticeCompletion") } }
    @Published var permission: Bool { didSet { defaults.set(permission, forKey: "noticePermission") } }
    @Published var input: Bool { didSet { defaults.set(input, forKey: "noticeInput") } }
    @Published var completionCooldown: Int {
        didSet { defaults.set(completionCooldown, forKey: "noticeCompletionCooldown") }
    }
    @Published var launchStatus: SMAppService.Status = .notRegistered
    @Published var notificationAllowed = false
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    enum PermissionKind { case login, notifications }
    @Published private(set) var waitingPermission: PermissionKind?
    @Published var issue: String?
    @Published private(set) var generalIssue: String?
    @Published private(set) var notificationIssue: String?
    private func setIssue(_ message: String?, for kind: PermissionKind) {
        if kind == .login { generalIssue = message } else { notificationIssue = message }
        // Keep the compatibility summary for callers, without displaying an
        // unrelated operation's error on both settings pages.
        issue = message ?? generalIssue ?? notificationIssue
    }
    @Published var busy = false
    @Published private(set) var shortcut: PanelShortcut?
    var onTogglePanel: (() -> Void)?
    var onOpenSession: ((String) -> Void)?
    var onPermissionFinished: (() -> Void)?
    private let defaults: UserDefaults
    private let isolated: Bool
    private var started = false
    private var stopped = false
    private var lifecycleGeneration = 0
    private var systemStateTask: Task<Void, Never>?
    private var needsSystemStateRefresh = false
    private let permissionAccess: FeaturePermissionAccess
    private let now: () -> Date
    private let playSound: @MainActor (SessionNoticeKind) -> Void
    private let sendBanner: BannerSender?
    private var lastCompletionSoundAt: Date?
    private var permissionTimer: Timer?
    private var permissionDeadline: Date?
    private var permissionGeneration = 0
    private var checkingPermissions = false
    private var tracker = SessionNoticeTracker()
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private var center: UNUserNotificationCenter? {
        !isolated && Bundle.main.bundleIdentifier == "com.weekleft.app" ? .current() : nil
    }
    init(defaults: UserDefaults = .standard, permissionAccess: FeaturePermissionAccess? = nil,
         now: @escaping () -> Date = Date.init,
         playSound: @escaping @MainActor (SessionNoticeKind) -> Void = NotificationAudio.play,
         sendBanner: BannerSender? = nil, isolated: Bool = false) {
        self.defaults = defaults
        self.isolated = isolated
        self.permissionAccess = permissionAccess ?? SystemFeaturePermissionAccess(); self.now = now
        self.playSound = playSound
        self.sendBanner = sendBanner
        banners = defaults.bool(forKey: "noticeBanners")
        sounds = defaults.bool(forKey: "noticeSounds")
        completion = defaults.object(forKey: "noticeCompletion") as? Bool ?? true
        permission = defaults.object(forKey: "noticePermission") as? Bool ?? true
        input = defaults.object(forKey: "noticeInput") as? Bool ?? true
        let cooldown = defaults.object(forKey: "noticeCompletionCooldown") as? Int ?? AppDefaultSettings.soundCooldown
        completionCooldown = [0, 2, 5, 10, 30].contains(cooldown) ? cooldown : AppDefaultSettings.soundCooldown
        shortcut = defaults.data(forKey: "panelShortcut").flatMap { try? JSONDecoder().decode(PanelShortcut.self, from: $0) }
        super.init()
    }
    func start() {
        guard !isolated, !started else { return }
        started = true; stopped = false
        center?.delegate = self
        if let shortcut { registerShortcut(shortcut, save: false) }
        refreshSystemState()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemState() }
        }
    }
    func refreshSystemState() {
        guard !isolated, !stopped else { return }
        needsSystemStateRefresh = true
        scheduleSystemStateRefresh()
    }
    private func scheduleSystemStateRefresh() {
        guard needsSystemStateRefresh, !isolated, !stopped,
              !checkingPermissions, systemStateTask == nil else { return }
        let generation = lifecycleGeneration
        systemStateTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !self.stopped,
                  self.lifecycleGeneration == generation else { return }
            self.needsSystemStateRefresh = false
            await self.checkSystemState()
            guard self.lifecycleGeneration == generation else { return }
            self.systemStateTask = nil
            self.scheduleSystemStateRefresh()
        }
    }
    func checkSystemState() async {
        guard !isolated, !stopped, !Task.isCancelled, !checkingPermissions else { return }
        checkingPermissions = true
        defer {
            checkingPermissions = false
            // Refreshes arriving during a system query must run after it. Cancelling
            // the old query and starting another while this guard is set loses both.
            scheduleSystemStateRefresh()
        }
        let generation = permissionGeneration
        let login = permissionAccess.loginStatus
        let authorization = await permissionAccess.notificationStatus()
        guard !stopped, !Task.isCancelled, generation == permissionGeneration else { return }
        launchStatus = login
        notificationAuthorization = authorization
        notificationAllowed = notificationAuthorization == .authorized || notificationAuthorization == .provisional
        guard generation == permissionGeneration, let waiting = waitingPermission else { return }
        guard let deadline = permissionDeadline, now() < deadline else {
            stopPermissionWatch(); setIssue(L("Ожидание завершено. Можно продолжить настройку в любое время."), for: waiting); return
        }
        if (waiting == .login && launchStatus == .enabled) || (waiting == .notifications && notificationAllowed) {
            if waiting == .notifications { banners = true }
            stopPermissionWatch(); setIssue(nil, for: waiting); onPermissionFinished?()
        }
    }
    func openPermissionSettings(_ kind: PermissionKind) {
        guard !isolated, !stopped else { return }
        stopPermissionWatch(); setIssue(nil, for: kind)
        waitingPermission = kind; permissionDeadline = now().addingTimeInterval(600)
        if kind == .notifications {
            guard permissionAccess.openNotificationSettings() else {
                stopPermissionWatch(); setIssue(L("Не удалось открыть настройки macOS."), for: kind); return
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
        guard !isolated, !stopped, !busy else { return }
        setIssue(nil, for: .notifications)
        guard enabled else {
            if waitingPermission == .notifications { stopPermissionWatch() }
            banners = false; center?.removeAllPendingNotificationRequests(); center?.removeAllDeliveredNotifications(); return
        }
        busy = true; defer { busy = false }
        let generation = lifecycleGeneration
        do {
            let authorization = await permissionAccess.notificationStatus()
            guard !stopped, !Task.isCancelled, generation == lifecycleGeneration else { return }
            notificationAuthorization = authorization
            if notificationAuthorization == .denied { openPermissionSettings(.notifications); return }
            let allowed = try await permissionAccess.authorizeNotifications()
            guard !stopped, !Task.isCancelled, generation == lifecycleGeneration else { return }
            notificationAllowed = allowed
            banners = notificationAllowed
            let updatedAuthorization = await permissionAccess.notificationStatus()
            guard !stopped, !Task.isCancelled, generation == lifecycleGeneration else { return }
            notificationAuthorization = updatedAuthorization
            if !notificationAllowed { setIssue(L("Разрешите уведомления Lunavect в системных настройках macOS."), for: .notifications) }
        } catch {
            guard !stopped, !Task.isCancelled, generation == lifecycleGeneration else { return }
            setIssue(L("Не удалось включить уведомления. Проверьте настройки macOS."), for: .notifications)
        }
    }
    func setLogin(_ enabled: Bool) async {
        guard !isolated, !stopped, !busy else { return }
        busy = true; setIssue(nil, for: .login); defer { busy = false; refreshSystemState() }
        let generation = lifecycleGeneration
        do {
            if enabled {
                if permissionAccess.loginStatus != .enabled && permissionAccess.loginStatus != .requiresApproval { try permissionAccess.registerLogin() }
                if permissionAccess.loginStatus == .requiresApproval { openPermissionSettings(.login) }
            } else {
                if waitingPermission == .login { stopPermissionWatch() }
                try await permissionAccess.unregisterLogin()
            }
        } catch {
            guard !stopped, !Task.isCancelled, generation == lifecycleGeneration else { return }
            if enabled && permissionAccess.loginStatus == .requiresApproval { openPermissionSettings(.login) }
            else { setIssue(L("Не удалось изменить автозапуск. Проверьте настройки macOS."), for: .login) }
        }
    }
    func observe(_ rows: [AgentSession], at date: Date? = nil) {
        guard !isolated, !stopped else { return }
        let notices = tracker.update(rows, now: date ?? now())
        guard banners || sounds else { return }
        for notice in notices {
            guard (notice.kind == .completed && completion) || (notice.kind == .permission && permission) || (notice.kind == .input && input) else { continue }
            deliver(title: notice.kind.title, body: notice.session.provider.title + " · " + notice.session.displayTitle, sessionID: notice.session.id, kind: notice.kind)
        }
    }
    func testNotification() {
        deliver(title: "Lunavect", body: L("Проверочное уведомление"), sessionID: nil, kind: .completed, bypassSoundCooldown: true)
    }
    func previewCompletionSound() { if !isolated && !stopped { playSound(.completed) } }
    func restoreDefaults() async {
        await setBanners(false)
        sounds = false; completion = true; permission = true; input = true
        completionCooldown = AppDefaultSettings.soundCooldown
        registerShortcut(nil)
        if permissionAccess.loginStatus != .notRegistered { await setLogin(false) }
    }
    private func reserveSound(_ kind: SessionNoticeKind, bypassCooldown: Bool) -> Bool {
        guard sounds else { return false }
        guard kind == .completed, !bypassCooldown else { return true }
        let date = now()
        if let previous = lastCompletionSoundAt {
            let elapsed = date.timeIntervalSince(previous)
            if elapsed >= 0 && elapsed < Double(completionCooldown) { return false }
        }
        // Reserve before enqueueing a banner, so its asynchronous failure cannot
        // restart every suppressed sound in a batch. Clock changes reset the gate.
        lastCompletionSoundAt = date
        return true
    }
    private func deliver(title: String, body: String, sessionID: String?, kind: SessionNoticeKind, bypassSoundCooldown: Bool = false) {
        guard !isolated, !stopped else { return }
        let shouldPlaySound = reserveSound(kind, bypassCooldown: bypassSoundCooldown)
        let sender = sendBanner ?? center.map { center in
            { (request: UNNotificationRequest, callback: @escaping @Sendable (Error?) -> Void) in
                center.add(request, withCompletionHandler: callback)
            }
        }
        // Each channel is independent. Sound-only mode doesn't request notification access.
        if banners, notificationAllowed, let sender {
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            if shouldPlaySound { content.sound = kind == .completed ? UNNotificationSound(named: UNNotificationSoundName(NotificationAudio.completionFilename)) : .default }
            if let sessionID { content.userInfo = ["sessionID": sessionID] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            let generation = lifecycleGeneration
            sender(request) { [weak self] error in
                if error != nil { Task { @MainActor in
                    guard let self, !self.stopped, generation == self.lifecycleGeneration else { return }
                    self.setIssue(L("Не удалось показать уведомление."), for: .notifications)
                    // Permission may have been revoked in System Settings while running.
                    self.refreshSystemState()
                    if shouldPlaySound && self.sounds { self.playSound(kind) }
                } }
            }
        } else if shouldPlaySound { playSound(kind) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let hasSound = notification.request.content.sound != nil
        return await notificationPresentationOptions(hasSound: hasSound)
    }
    func notificationPresentationOptions(hasSound: Bool) -> UNNotificationPresentationOptions {
        guard !stopped, !isolated else { return [] }
        var options: UNNotificationPresentationOptions = banners ? [.banner, .list] : []
        if sounds && hasSound { options.insert(.sound) }
        return options
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Only a copied, Sendable identifier crosses onto the app's actor.
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        await receiveNotificationResponse(sessionID: id)
    }
    func receiveNotificationResponse(sessionID: String?) {
        guard !stopped, !isolated, let sessionID else { return }
        onOpenSession?(sessionID)
    }
    func registerShortcut(_ value: PanelShortcut?, save: Bool = true) {
        guard !isolated, !stopped else { return }
        setIssue(nil, for: .login)
        if value == shortcut, hotKey != nil { return }
        var candidate: EventHotKeyRef?
        if let value {
            if hotKeyHandler == nil {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                    guard let context else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<AppFeatures>.fromOpaque(context).takeUnretainedValue()
                    Task { @MainActor in if !owner.stopped { owner.onTogglePanel?() } }
                    return noErr
                }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
                guard status == noErr else { setIssue(L("Не удалось зарегистрировать сочетание клавиш."), for: .login); return }
            }
            let status = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x4C554E41, id: 1), GetApplicationEventTarget(), 0, &candidate)
            guard status == noErr else { setIssue(L("Это сочетание недоступно. Выберите другое."), for: .login); return }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; shortcut = value
        if save {
            if let value { defaults.set(try? JSONEncoder().encode(value), forKey: "panelShortcut") }
            else { defaults.removeObject(forKey: "panelShortcut") }
        }
    }
    func stop() {
        lifecycleGeneration += 1
        stopped = true; started = false
        needsSystemStateRefresh = false
        systemStateTask?.cancel(); systemStateTask = nil
        stopPermissionWatch()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
        if center?.delegate === self { center?.delegate = nil }
    }
    isolated deinit {
        permissionTimer?.invalidate(); systemStateTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Запускать при входе в macOS")); Spacer()
                    Toggle(
                        L("Запускать при входе в macOS"),
                        isOn: Binding(
                            get: { features.launchStatus == .enabled || features.launchStatus == .requiresApproval },
                            set: { value in Task { await features.setLogin(value) } })
                    )
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
                    Button(recording ? L("Нажмите сочетание…") : features.shortcut?.displayLabel ?? L("Назначить клавиши")) { beginRecording() }
                        .accessibilityLabel(L("Открыть панель сессий"))
                        .accessibilityValue(features.shortcut?.displayLabel ?? L("Назначить клавиши"))
                    if features.shortcut != nil {
                        Button { features.registerShortcut(nil) } label: { InterfaceIcon(.close).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
                            .buttonStyle(.plain).help(L("Убрать сочетание")).accessibilityLabel(L("Убрать сочетание"))
                    }
                }
                Text(L("Используйте ⌘, ⌃ или ⌥ вместе с клавишей. Esc отменяет ввод."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let issue = features.generalIssue { Text(issue).font(.system(size: 11)).foregroundStyle(.orange) }
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
            guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
            let character = PanelShortcut.keyLabel(UInt32(event.keyCode))
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
        VStack(alignment: .leading, spacing: InterfaceMetrics.settingsSectionSpacing) {
            GroupBox(L("Способ уведомления")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(get: { features.banners || features.waitingPermission == .notifications }, set: { value in Task { await features.setBanners(value) } })) {
                        Text(L("Всплывающие уведомления")).frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .disabled(features.busy).accessibilityIdentifier("notification-banners")
            if features.waitingPermission == .notifications { PermissionWaitView(features: features, kind: .notifications) }
            else if features.notificationAuthorization == .denied {
                Button(L("Разрешить уведомления в macOS")) { features.openPermissionSettings(.notifications) }
                    .accessibilityIdentifier("notification-settings")
            }
                    Toggle(isOn: $features.sounds) {
                        Text(L("Звуковые уведомления")).frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .accessibilityIdentifier("notification-sounds")
                    Text(L("Звук работает отдельно от баннеров и не требует разрешения на уведомления."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("Завершение сессии")).font(.system(size: 12, weight: .medium))
                            Text("Lunavect · Lift").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { features.previewCompletionSound() } label: { Label(L("Прослушать"), systemImage: "play.fill") }
                            .accessibilityIdentifier("notification-preview-sound")
                    }
                    SettingsRow(L("Пауза между звуками завершения")) {
                    Picker(L("Пауза между звуками завершения"), selection: $features.completionCooldown) {
                        Text(L("Без паузы")).tag(0)
                        ForEach([2, 5, 10, 30], id: \.self) { Text(L("{0} с", String($0))).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("notification-sound-cooldown")
                    }
                }.toggleStyle(.switch).padding(12)
            }
            if !features.banners && !features.sounds {
                Text(L("События можно настроить заранее. Уведомления начнут приходить после включения звука или баннеров."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            GroupBox(L("Когда уведомлять")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("Ответ готов"), isOn: $features.completion)
                    Toggle(L("Нужно разрешение"), isOn: $features.permission)
                    Toggle(L("Ждёт ответа"), isOn: $features.input)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Button(L("Проверить уведомление")) { features.testNotification() }
                .disabled(!features.banners && !features.sounds)
            if let issue = features.notificationIssue { Text(issue).font(.system(size: 12)).foregroundStyle(.orange) }
        }.onAppear { features.refreshSystemState() }
    }
}
