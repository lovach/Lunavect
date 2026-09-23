import AppKit
import SwiftUI
import Combine
import Carbon
#if SWIFT_PACKAGE
import WeekleftCore
import AwakeService
#endif

/// A status-item popover can remain visible when AppKit's transient dismissal
/// misses activation changes. Monitor other apps only while the panel is open;
/// clicks in its controls, nested popovers and menus stay with AppKit.
@MainActor final class SessionPopoverDismissal {
    private weak var popover: NSPopover?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    func start(for popover: NSPopover) {
        stop()
        self.popover = popover
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover?.performClose(nil) }
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        mouseMonitor = nil
        activationObserver = nil
        popover = nil
    }
}

/// Back from Settings is an ordered transition, unlike opening the panel from
/// the menu bar. A newer window action invalidates its deferred presentation.
@MainActor final class SettingsToSessionsTransition {
    typealias Action = @MainActor @Sendable () -> Void
    private var generation = 0

    func cancel() { generation &+= 1 }
    func start(sessionStatusEnabled: Bool, closeSettings: () -> Void, updateActivationPolicy: () -> Void,
               showSessions: @escaping Action, showFallback: () -> Void,
               enqueue: (@escaping Action) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        cancel()
        guard sessionStatusEnabled else { showFallback(); return }
        let request = generation
        closeSettings()
        updateActivationPolicy()
        // Let AppKit finish the close/policy turn before anchoring a transient
        // popover. No timer, guessed delay, service restart or data refresh here.
        enqueue { [weak self] in
            guard let self, self.generation == request else { return }
            self.cancel()
            showSessions()
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    let environment: AppEnvironment
    var store: AppStore { environment.store }
    var sessions: SessionStore { environment.sessions }
    var menuBarAppearance: MenuBarAppearance { environment.menuBarAppearance }
    init(environment: AppEnvironment) { self.environment = environment; super.init() }
    var menuBarAnimator: MenuBarAnimator?
    var menuBarLimits: MenuBarLimitsController?
    var window: NSWindow?
    var welcomeWindow: NSWindow?
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let popoverDismissal = SessionPopoverDismissal()
    let sessionPanelState = SessionPanelState()
    let settingsReturnTransition = SettingsToSessionsTransition()
    var statusObserver: AnyCancellable?
    var statusVisibilityObserver: AnyCancellable?
    private var sessionOpenedObserver: NSObjectProtocol?
    var limitsObserver: AnyCancellable?
    var languageObserver: AnyCancellable?
    var noticeObserver: AnyCancellable?
    var connectionsObserver: AnyCancellable?
    private var openedFromURL = false
    private var widgetRegistration: WidgetRegistration?
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = AppArtwork.icon { NSApp.applicationIconImage = icon }
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: L("Сессии Lunavect"))
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: LocalizedRoot(language: environment.language) { [sessions, environment, sessionPanelState] in
                SessionsView(
                    store: sessions, panelState: sessionPanelState, updates: environment.updates,
                    awake: environment.awake, isPreview: environment.isPreview,
                    onSettings: { [weak self] in
                        self?.popover.performClose(nil); self?.showSettings()
        }, onConnections: { [weak self] in
            self?.environment.defaults.set(SettingsSection.connections.rawValue, forKey: "settingsSection")
            self?.showSettings()
        }, onMenuBarSettings: { [weak self] in self?.showMenuBarSettings() }, onKeepAwakeSettings: { [weak self] in
            self?.environment.defaults.set(SettingsSection.keepAwake.rawValue, forKey: "settingsSection")
            self?.showSettings()
        }, onHeightChange: { [weak self] height in self?.popover.contentSize = NSSize(width: 360, height: height) }, onReorderingChange: { [weak self] dragging in
            self?.popover.behavior = dragging ? .applicationDefined : .transient
        }) }.defaultAppStorage(environment.defaults))
        menuBarAnimator = MenuBarAnimator(statusItem: statusItem, updates: environment.updates)
        sessionOpenedObserver = NotificationCenter.default.addObserver(forName: .lunavectSessionOpened, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.popover.isShown == true { self?.popover.close() } }
        }
        statusVisibilityObserver = menuBarAppearance.$showsSessionStatus.receive(on: RunLoop.main).sink { [weak self] visible in
            guard let self else { return }
            if !visible { self.popover.performClose(nil) }
            self.menuBarAnimator?.setVisible(visible)
        }
        menuBarLimits = MenuBarLimitsController(onSelectPeriod: { [weak self] in self?.menuBarAppearance.limits.period = $0 },
            onRefresh: { [weak self] in Task { await self?.store.refresh() } },
            onShow: { [weak self] in self?.popover.performClose(nil); self?.menuBarAnimator?.setPopoverOpen(true) },
            onHide: { [weak self] in self?.menuBarAnimator?.setPopoverOpen(self?.popover.isShown == true) },
            onOpenMenu: { [weak self] in self?.showMenuBarSettings() },
            contextMenu: { [weak self] in self?.statusMenu() ?? NSMenu() },
            onOpenLimits: { [weak self] in self?.showLimits() })
        limitsObserver = Publishers.CombineLatest3(store.$snapshots, store.$preferences.map(\.providers).removeDuplicates(), menuBarAppearance.$limits)
            .combineLatest(environment.language.$code, store.$refreshing).receive(on: RunLoop.main).sink { [weak self] state, _, refreshing in
                self?.menuBarLimits?.update(snapshots: state.0, providers: state.1, preferences: state.2, refreshing: refreshing)
            }
        observeSessionStatus()
        languageObserver = environment.language.$code.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.configureMainMenu()
            self?.window?.title = L("Лимиты и настройки — Lunavect")
        }
        if !environment.isPreview {
            environment.awake.onPermissionFinished = { [weak self] origin in
                if origin == .settings { self?.showSettings() } else { self?.showSessions() }
            }
            let features = environment.features
            features.onPermissionFinished = { [weak self] in self?.showSettings() }
            features.onTogglePanel = { [weak self] in
                guard let self else { return }
                if self.popover.isShown { self.popover.performClose(nil) } else { self.showSessions() }
            }
            features.onOpenSession = { [weak self] id in
                Task { @MainActor in
                    guard let self else { return }
                    await self.sessions.refresh()
                    let opened = await self.sessionPanelState.openSession(id: id, rows: self.sessions.sessions) { row in
                        try await SessionNavigation.open(row, resolver: self.store.clientResolver)
                    }
                    if !opened { self.showSessionIssue() }
                }
            }
            features.start()
            let registration = WidgetRegistration(defaults: environment.defaults)
            widgetRegistration = registration
            registration.start()
            environment.updates.start()
            noticeObserver = sessions.observations.sink { observation in
                features.observe(observation.rows, at: observation.date)
            }
        }
        if !environment.isPreview {
            sessions.onObservation = { [weak self] rows, now in
                self?.store.observeActivity(rows, now: now)
                self?.environment.awake.observe(rows)
                self?.environment.observeActivityContinuity(rows, now: now)
            }
            sessions.useProviders(store.providers)
            connectionsObserver = store.$preferences.map(\.providers).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] providers in
                self?.sessions.useProviders(providers)
            }
            store.onNetworkRestored = { [weak self] in await self?.sessions.refresh() }
            store.start()
            sessions.start(clientResolver: { [weak self] in self?.store.clientResolver ?? ClientExecutableResolver() })
        }
        // Launch and reopen use the same small panel as a click on the menu-bar icon.
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !loginLaunch {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.openedFromURL else { return }
                if !self.environment.isPreview && WelcomeProgress.shouldPresent(defaults: self.environment.defaults) { self.showWelcome() }
                else { self.showSessions() }
            }
        }
    }
    func observeSessionStatus() {
        // RunLoop.main schedules in default mode only. Event tracking must not
        // strand an old waiting count after the store already reports work.
        statusObserver = Publishers.CombineLatest4(
            sessions.$sessions, menuBarAppearance.$icon, menuBarAppearance.$onlyWhileWorking, environment.language.$code
        ).combineLatest(
            menuBarAppearance.$systemColor, menuBarAppearance.$automaticIcon,
            menuBarAppearance.$statusStyle.combineLatest(menuBarAppearance.$thinkingPhrases)
        ).receive(on: DispatchQueue.main).sink { [weak self] state, systemColor, _, statusOptions in
            guard let self else { return }
            let (observedRows, _, onlyWhileWorking, _) = state
            let rows = observedRows.filter { $0.isCurrent() }
            let icon = self.menuBarAppearance.resolvedIcon(for: rows)
            let running = rows.filter { $0.effectivePhase() == .running }.count
            let waiting = rows.filter { [.permission, .input].contains($0.effectivePhase()) }.count
            self.menuBarAnimator?.update(
                icon: icon, onlyWhileWorking: onlyWhileWorking, systemColor: systemColor, statusStyle: statusOptions.0,
                thinkingPhrases: statusOptions.1, running: running, waiting: waiting)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        widgetRegistration?.stop()
        menuBarLimits?.stop()
        popoverDismissal.stop()
        environment.stop()
    }
    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Статус в строке меню…"), action: #selector(showMenuBarSettings), keyEquivalent: "")
        menu.addItem(withTitle: L("Открыть сессии"), action: #selector(showSessions), keyEquivalent: "")
        menu.addItem(withTitle: L("Лимиты"), action: #selector(showLimits), keyEquivalent: "")
        menu.addItem(withTitle: L("Настройки Lunavect…"), action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(withTitle: L("Обновить лимиты"), action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: L("Проверить обновления"), action: #selector(showUpdates), keyEquivalent: "")
        menu.addItem(withTitle: L("Показать обучение"), action: #selector(showWelcome), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: L("Завершить Lunavect"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu(); button.performClick(nil); statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showSessions() }
    }
    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Lunavect"); appItem.submenu = appMenu
        let settings = appMenu.addItem(withTitle: L("Настройки Lunavect…"), action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        let updates = appMenu.addItem(withTitle: L("Проверить обновления"), action: #selector(showUpdates), keyEquivalent: ""); updates.target = self
        let welcome = appMenu.addItem(withTitle: L("Показать обучение"), action: #selector(showWelcome), keyEquivalent: ""); welcome.target = self
        appMenu.addItem(.separator())
        let exit = appMenu.addItem(withTitle: L("Завершить Lunavect"), action: #selector(quit), keyEquivalent: "q"); exit.target = self
        main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: L("Правка")); editItem.submenu = edit
        let undo = edit.addItem(withTitle: L("Отменить"), action: #selector(undoEdit), keyEquivalent: "z"); undo.target = self
        let redo = edit.addItem(withTitle: L("Повторить"), action: #selector(redoEdit), keyEquivalent: "Z"); redo.target = self
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(editItem)
        let windowItem = NSMenuItem(); let windows = NSMenu(title: L("Окно")); windowItem.submenu = windows
        windows.addItem(withTitle: L("Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: L("Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowItem); NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
    @objc func showSessions() {
        guard menuBarAppearance.showsSessionStatus else { showMenuBarSettings(); return }
        menuBarLimits?.close()
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
        if !environment.isPreview { Task { await sessions.refresh() } }
    }
    private func showSessionIssue() {
        if menuBarAppearance.showsSessionStatus { showSessions(); return }
        // An intentionally hidden status item cannot anchor the panel. Keep
        // notification failures visible even in a limits-only configuration.
        showSettings()
        guard let window, let issue = sessionPanelState.issue else { return }
        let alert = NSAlert()
        alert.messageText = L("Не удалось открыть сессию.")
        alert.informativeText = issue
        alert.addButton(withTitle: L("Понятно"))
        alert.beginSheetModal(for: window) { [weak self] _ in self?.sessionPanelState.issue = nil }
    }
    var editingUndoManager: UndoManager? {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager }
        return popover.isShown ? sessions.undoManager : nil
    }
    @objc func undoEdit() { editingUndoManager?.undo() }
    @objc func redoEdit() { editingUndoManager?.redo() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undoEdit) { return editingUndoManager?.canUndo == true }
        if item.action == #selector(redoEdit) { return editingUndoManager?.canRedo == true }
        return true
    }
    @objc func showLimits() {
        environment.defaults.set(SettingsSection.limits.rawValue, forKey: "settingsSection")
        showSettings()
    }
    func popoverWillShow(_ notification: Notification) {
        sessionPanelState.isVisible = true
        sessions.setPanelVisible(true)
        popover.behavior = .transient
        menuBarAnimator?.setPopoverOpen(true)
    }
    func popoverDidShow(_ notification: Notification) {
        popoverDismissal.start(for: popover)
    }
    func popoverWillClose(_ notification: Notification) {
        popoverDismissal.stop()
    }
    func popoverDidClose(_ notification: Notification) {
        sessionPanelState.isVisible = false
        sessions.setPanelVisible(false)
        popover.behavior = .transient
        menuBarAnimator?.setPopoverOpen(menuBarLimits?.popover.isShown == true)
    }
    @objc func showSettings() {
        settingsReturnTransition.cancel()
        menuBarLimits?.close()
        popover.performClose(nil)
        if window == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            settings.title = L("Лимиты и настройки — Lunavect"); settings.isReleasedWhenClosed = false
            settings.delegate = self
            settings.contentMinSize = NSSize(width: 800, height: 580)
            settings.contentView = NSHostingView(rootView: LocalizedRoot(language: environment.language) { [store, menuBarAppearance, sessions, environment] in
                SettingsView(store: store, menuBarAppearance: menuBarAppearance, sessions: sessions,
                             updates: environment.updates, awake: environment.awake, features: environment.features, language: environment.language,
                             onShowSessions: { [weak self] in self?.backToSessionsFromSettings() },
                             onShowWelcome: { [weak self] in self?.showWelcome() })
                    .disabled(environment.isPreview)
            }.defaultAppStorage(environment.defaults))
            // The window is released on close; reopen it where the user left it.
            let frameName = "LunavectOrganizedSettings"
            if environment.isPreview || !settings.setFrameUsingName(frameName) { settings.center() }
            if !environment.isPreview { settings.setFrameAutosaveName(frameName) }
            window = settings
        }
        menuBarAppearance.previewVisible = true
        updateActivationPolicy()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func backToSessionsFromSettings() {
        settingsReturnTransition.start(sessionStatusEnabled: menuBarAppearance.showsSessionStatus,
            closeSettings: { [weak self] in
                self?.window?.close()
                self?.menuBarAppearance.previewVisible = false
            },
            updateActivationPolicy: { [weak self] in self?.updateActivationPolicy() },
            showSessions: { [weak self] in self?.showSessions() },
            showFallback: { [weak self] in self?.showMenuBarSettings() })
    }
    @objc func showWelcome() {
        settingsReturnTransition.cancel()
        popover.performClose(nil)
        if welcomeWindow == nil {
            let welcome = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            welcome.title = "Lunavect"; welcome.isReleasedWhenClosed = false; welcome.delegate = self
            welcome.contentView = NSHostingView(rootView: LocalizedRoot(language: environment.language) { [store, sessions, environment] in
                WelcomeView(store: store, sessions: sessions, onFinish: { [weak self] in
                    WelcomeProgress.complete(defaults: environment.defaults)
                    self?.welcomeWindow?.orderOut(nil); self?.welcomeWindow = nil
                    self?.updateActivationPolicy()
                    if self?.window?.isVisible == true { self?.showSettings() } else { self?.showSessions() }
                }, onOpenSessions: { [weak self] in
                    WelcomeProgress.complete(defaults: environment.defaults)
                    self?.welcomeWindow?.orderOut(nil); self?.welcomeWindow = nil
                    self?.updateActivationPolicy()
                    self?.showSessions()
                }, widgetSetup: environment.isPreview ? WidgetSetupStatus(fetch: { [] }) : nil)
                    .disabled(environment.isPreview)
            }.defaultAppStorage(environment.defaults))
            welcome.center(); welcomeWindow = welcome
        }
        updateActivationPolicy()
        welcomeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showUpdates() {
        environment.defaults.set(SettingsSection.updates.rawValue, forKey: "settingsSection")
        showSettings()
        if environment.updates.configured { environment.updates.check() }
    }
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === window {
            menuBarAppearance.previewVisible = false
            // A closed window's SwiftUI content keeps observing the stores and
            // recomputing statistics. Release it; showSettings builds a new one.
            window = nil
        }
        if let closed = notification.object as? NSWindow, closed === welcomeWindow {
            WelcomeProgress.complete(defaults: environment.defaults); welcomeWindow = nil
        }
        updateActivationPolicy(excluding: notification.object as? NSWindow)
    }
    private func updateActivationPolicy(excluding _: NSWindow? = nil) {
        guard !environment.isPreview else { return }
        // Settings and onboarding are windows of the menu-bar utility. Opening
        // or closing them must not create a separate application icon in Dock.
        NSApp.setActivationPolicy(.accessory)
    }
    @objc func refresh() { Task { await store.refresh() } }
    @objc func showMenuBarSettings() {
        environment.defaults.set(SettingsSection.menuBar.rawValue, forKey: "settingsSection")
        popover.performClose(nil)
        showSettings()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "lunavect" else { return }
        openedFromURL = true
        if url.host == "settings", url.path == "/menu-bar" {
            welcomeWindow?.orderOut(nil)
            showMenuBarSettings()
            return
        } else if url.host == "limits" || (url.host == "settings" && url.path == "/limits") {
            welcomeWindow?.orderOut(nil); showLimits(); return
        } else if let period = ActivityPeriod.from(widgetURL: url) {
            environment.defaults.set(period.rawValue, forKey: "statisticsPeriod")
            environment.defaults.set((ActivitySource.from(widgetURL: url) ?? .all).rawValue, forKey: "statisticsSource")
            environment.defaults.set(SettingsSection.statistics.rawValue, forKey: "settingsSection")
        } else {
            environment.defaults.set(SettingsSection.widget.rawValue, forKey: "settingsSection")
        }
        welcomeWindow?.orderOut(nil)
        showSettings()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true || window?.isMiniaturized == true { showSettings() }
        else if welcomeWindow?.isVisible == true { showWelcome() }
        else { showSessions() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main enum WeekleftLauncher {
    @MainActor private static func diagnosticClientResolver() -> ClientExecutableResolver {
        let path = UserDefaults.standard.string(forKey: "codexPath") ?? ""
        let automaticPath = path.isEmpty ? AppStore.discoverCodex() : nil
        return ClientExecutableResolver(codexPath: path, discoverCodex: { automaticPath })
    }
    @MainActor static func main() {
        do {
            #if DEBUG
            let previewsEnabled = true
            #else
            let previewsEnabled = false
            #endif
            if let request = try AppPreviewRequest.parse(CommandLine.arguments, enabled: previewsEnabled) {
                #if DEBUG
                try preview(request)
                #endif
                return
            }
        } catch {
            fputs("Preview requires a Debug build and one valid fixture/output path. No application services were started.\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.contains("--unregister-awake-helper") {
            guard CommandLine.arguments.count == 2 else {
                fputs("Use --unregister-awake-helper without other arguments.\n", stderr)
                exit(2)
            }
            removeAwakeHelper()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--session-hook"), CommandLine.arguments.indices.contains(index + 1),
           let provider = ProviderID(rawValue: CommandLine.arguments[index + 1]) {
            SessionHooks.captureFromStandardInput(provider: provider); return
        }
        if CommandLine.arguments.contains("--session-probe") {
            let resolver = diagnosticClientResolver()
            let signal = DispatchSemaphore(value: 0)
            Task.detached {
                var catalog: [AgentSession] = []
                for provider in ProviderID.allCases {
                    do {
                        catalog += try await (provider == .codex
                            ? SessionSources.codex(resolver: resolver)
                            : SessionSources.claude(path: resolver.resolve(.claude)))
                    } catch { fputs("\(provider.title): \(error.localizedDescription)\n", stderr) }
                }
                let activity = await CodexActivityReader.shared.events(catalog: catalog)
                let result = SessionList.merge(catalog: catalog, events: SessionSources.legacyEvents(catalog: catalog) + SessionHooks.load() + activity)
                if let data = try? JSONEncoder().encode(result) { print(String(decoding: data, as: UTF8.self)) }
                signal.signal()
            }
            guard signal.wait(timeout: .now() + 45) == .success else { exit(1) }; return
        }
        if CommandLine.arguments.contains("--claude-statusline") { ClaudeProvider.runStatusLine(); return }
        if CommandLine.arguments.contains("--install-claude-statusline") {
            do { try ClaudeProvider.installStatusLine(executable: SessionHooks.monitorExecutable() ?? CommandLine.arguments[0]); print("Local statusLine bridge installed") }
            catch { fputs("StatusLine setup failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--probe") {
            let resolver = diagnosticClientResolver()
            let signal = DispatchSemaphore(value: 0)
            Task.detached {
                for id in ProviderID.allCases {
                    do {
                        let snapshot = try await (id == .codex ? CodexProvider.fetch(resolver: resolver) : ClaudeProvider.fetch())
                        let data = try JSONEncoder().encode(snapshot)
                        print(String(decoding: data, as: UTF8.self))
                    } catch { print("\(id.title): \((error as? UsageError)?.errorDescription ?? "Не удалось получить данные")") }
                }
                signal.signal()
            }
            _ = signal.wait(timeout: .now() + 60); return
        }
        let instance: AppInstanceLease
        do {
            guard let acquired = try AppInstanceLease.acquire(directory: SnapshotStore.directory) else {
                activateExistingInstance()
                return
            }
            // Also cooperate with older releases that do not hold our lease.
            if activateExistingInstance(onlyFinishedLaunching: true) { return }
            instance = acquired
        } catch {
            let alert = NSAlert()
            alert.messageText = "Lunavect"
            alert.informativeText = L("Не удалось получить доступ к локальным данным. Проверьте права доступа и запустите Lunavect снова.")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        let defaults = UserDefaults.standard
        let savedPreferences = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.weekleft.app") ?? [:]
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: !savedPreferences.isEmpty ||
            FileManager.default.fileExists(atPath: SnapshotStore.directory.appendingPathComponent("snapshot.json").path))
        withExtendedLifetime(instance) { launch(environment: .live()) }
    }
    @discardableResult @MainActor private static func activateExistingInstance(onlyFinishedLaunching: Bool = false) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
              let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: {
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated &&
                    (!onlyFinishedLaunching || $0.isFinishedLaunching)
                }) else { return false }
        existing.activate(options: [])
        return true
    }
    @MainActor private static func removeAwakeHelper() {
        guard Bundle.main.bundleIdentifier == AwakeServiceID.app else {
            fputs("Run this command from the installed Lunavect app bundle.\n", stderr)
            exit(1)
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AwakeServiceID.app)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard others.isEmpty else {
            fputs("Quit Lunavect before removing its Keep Awake helper.\n", stderr)
            exit(1)
        }
        // ServiceManagement/XPC need a live main run loop. No stores, client
        // integrations, login settings or ordinary app environment are started.
        _ = NSApplication.shared
        Task { @MainActor in
            do {
                let client = AwakeServiceClient(refreshAtStartup: false)
                try await client.prepareForRemoval()
                print("Sleep restored and Keep Awake service unregistered.")
                exit(0)
            } catch {
                fputs("Keep Awake removal failed; service retained if recovery is pending: \(error).\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
    @MainActor private static func launch(environment: AppEnvironment) {
        let app = NSApplication.shared
        let delegate = AppDelegate(environment: environment)
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    #if DEBUG
    @MainActor private static func preview(_ request: AppPreviewRequest) throws {
        // Process-only language; neither app nor App Group preferences are read or changed.
        if ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] == nil {
            setenv("LUNAVECT_PREVIEW_LANGUAGE", "en", 1)
        }
        switch request {
        case .sessions(let url):
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: 1_048_577) ?? Data()
            guard bytes.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            let rows = try JSONDecoder().decode([AgentSession].self, from: bytes)
            launch(environment: try .preview(rows: rows, languageCode: L10n.selection))
        case .render(let url):
            // Unknown values are intentional fixture data, never the user's live quotas.
            let state = SharedState()
            var expanded = state.preferences; expanded.showFiveHour = true
            let renderer = ImageRenderer(content: HStack(spacing: 20) {
                WeekleftCard(snapshots: state.snapshots, preferences: state.preferences).background(Color(white: 0.14)).clipShape(RoundedRectangle(cornerRadius: 26))
                WeekleftCard(snapshots: state.snapshots, preferences: expanded).background(Color(white: 0.14)).clipShape(RoundedRectangle(cornerRadius: 26))
            }.padding(24).background(Color(white: 0.08)))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            print("Synthetic native SwiftUI render saved")
        }
    }
    #endif
}
