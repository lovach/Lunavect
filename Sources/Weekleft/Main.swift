import AppKit
import SwiftUI
import Combine
import Carbon
#if SWIFT_PACKAGE
import WeekleftCore
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    var previewSessions: [AgentSession]?
    let store = AppStore()
    let sessions = SessionStore()
    let menuBarAppearance = MenuBarAppearance()
    var menuBarAnimator: MenuBarAnimator?
    var window: NSWindow?
    var welcomeWindow: NSWindow?
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let popoverDismissal = SessionPopoverDismissal()
    let sessionPanelState = SessionPanelState()
    var statusObserver: AnyCancellable?
    var languageObserver: AnyCancellable?
    var noticeObserver: AnyCancellable?
    var connectionsObserver: AnyCancellable?
    private var openedFromURL = false
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
        popover.contentViewController = NSHostingController(rootView: LocalizedRoot { [sessions, previewSessions, sessionPanelState] in SessionsView(store: sessions, panelState: sessionPanelState, isPreview: previewSessions != nil, onSettings: { [weak self] in
            self?.popover.performClose(nil); self?.showSettings()
        }, onConnections: { [weak self] in
            UserDefaults.standard.set(SettingsSection.connections.rawValue, forKey: "settingsSection")
            self?.showSettings()
        }, onMenuBarSettings: { [weak self] in self?.showMenuBarSettings() }, onHeightChange: { [weak self] height in self?.popover.contentSize = NSSize(width: 360, height: height) }, onReorderingChange: { [weak self] dragging in
            self?.popover.behavior = dragging ? .applicationDefined : .transient
        }) })
        menuBarAnimator = MenuBarAnimator(statusItem: statusItem)
        statusObserver = Publishers.CombineLatest4(sessions.$sessions, menuBarAppearance.$icon, menuBarAppearance.$onlyWhileWorking, LanguageSettings.shared.$code).combineLatest(menuBarAppearance.$systemColor, menuBarAppearance.$automaticIcon, menuBarAppearance.$statusStyle.combineLatest(menuBarAppearance.$thinkingPhrases)).receive(on: RunLoop.main).sink { [weak self] state, systemColor, _, statusOptions in
            guard let self else { return }
            let (rows, _, onlyWhileWorking, _) = state
            let icon = self.menuBarAppearance.resolvedIcon(for: rows)
            let running = rows.filter { $0.effectivePhase() == .running }.count
            let waiting = rows.filter { [.permission, .input].contains($0.effectivePhase()) }.count
            self.menuBarAnimator?.update(icon: icon, onlyWhileWorking: onlyWhileWorking, systemColor: systemColor, statusStyle: statusOptions.0, thinkingPhrases: statusOptions.1, running: running, waiting: waiting)
        }
        languageObserver = LanguageSettings.shared.$code.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.configureMainMenu()
            self?.window?.title = L("Лимиты и настройки — Lunavect")
        }
        if previewSessions == nil {
            KeepAwake.shared.onPermissionFinished = { [weak self] in self?.showSessions() }
            let features = AppFeatures.shared
            features.onPermissionFinished = { [weak self] in self?.showSettings() }
            features.onTogglePanel = { [weak self] in
                guard let self else { return }
                if self.popover.isShown { self.popover.performClose(nil) } else { self.showSessions() }
            }
            features.onOpenSession = { [weak self] id in
                Task { @MainActor in
                    guard let self else { return }
                    await self.sessions.refresh()
                    guard let row = self.sessions.sessions.first(where: { $0.id == id }) else { self.showSessions(); return }
                    do { try await SessionNavigation.open(row) }
                    catch { features.issue = L("Не удалось открыть сессию."); self.showSessions() }
                }
            }
            features.start()
            AppUpdates.shared.start()
            noticeObserver = sessions.$sessions.sink { rows in features.observe(rows) }
        }
        if let previewSessions {
            sessions.sessions = previewSessions; sessions.updatedAt = Date()
        } else {
            sessions.onObservation = { [weak self] rows, now in self?.store.observeActivity(rows, now: now) }
            sessions.useProviders(store.providers)
            connectionsObserver = store.$preferences.map(\.providers).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] providers in
                self?.sessions.useProviders(providers)
            }
            store.onNetworkRestored = { [weak self] in await self?.sessions.refresh() }
            store.start()
            sessions.start(codexPath: { [weak self] in self?.store.codexPath ?? "" })
        }
        // Launch and reopen use the same small panel as a click on the menu-bar icon.
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !loginLaunch {
            DispatchQueue.main.async { [weak self] in
                guard self?.openedFromURL != true else { return }
                if self?.previewSessions == nil && WelcomeProgress.shouldPresent() { self?.showWelcome() }
                else { self?.showSessions() }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        popoverDismissal.stop()
        sessions.stop()
        KeepAwake.shared.shutdown()
        if previewSessions == nil { store.flushActivity() }
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
        guard let button = statusItem?.button else { return }
        menuBarAppearance.previewVisible = false
        window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
        if previewSessions == nil { Task { await sessions.refresh() } }
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
        UserDefaults.standard.set(SettingsSection.limits.rawValue, forKey: "settingsSection")
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
        menuBarAnimator?.setPopoverOpen(false)
    }
    @objc func showSettings() {
        popover.performClose(nil)
        if window == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            settings.title = L("Лимиты и настройки — Lunavect"); settings.isReleasedWhenClosed = false
            settings.delegate = self
            settings.contentMinSize = NSSize(width: 800, height: 580)
            settings.setFrameAutosaveName("LunavectOrganizedSettings")
            settings.contentView = NSHostingView(rootView: LocalizedRoot { [store, menuBarAppearance, sessions] in
                SettingsView(store: store, menuBarAppearance: menuBarAppearance, sessions: sessions,
                             onShowSessions: { [weak self] in self?.showSessions() },
                             onShowWelcome: { [weak self] in self?.showWelcome() })
            })
            settings.center()
            window = settings
        }
        menuBarAppearance.previewVisible = true
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showWelcome() {
        popover.performClose(nil)
        window?.orderOut(nil)
        if welcomeWindow == nil {
            let welcome = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            welcome.title = "Lunavect"; welcome.isReleasedWhenClosed = false; welcome.delegate = self
            welcome.contentView = NSHostingView(rootView: LocalizedRoot { [store, sessions] in
                WelcomeView(store: store, sessions: sessions) { [weak self] in
                    WelcomeProgress.complete(); self?.welcomeWindow?.orderOut(nil); self?.welcomeWindow = nil; self?.showSessions()
                }
            })
            welcome.center(); welcomeWindow = welcome
        }
        welcomeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showUpdates() {
        UserDefaults.standard.set(SettingsSection.updates.rawValue, forKey: "settingsSection")
        showSettings()
        if AppUpdates.shared.configured { AppUpdates.shared.check() }
    }
    func windowWillClose(_ notification: Notification) {
        menuBarAppearance.previewVisible = false
        if let closed = notification.object as? NSWindow, closed === welcomeWindow {
            WelcomeProgress.complete(); welcomeWindow = nil
        }
    }
    @objc func refresh() { Task { await store.refresh() } }
    @objc func showMenuBarSettings() {
        UserDefaults.standard.set(SettingsSection.menuBar.rawValue, forKey: "settingsSection")
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
            UserDefaults.standard.set(period.rawValue, forKey: "statisticsPeriod")
            UserDefaults.standard.set((ActivitySource.from(widgetURL: url) ?? .all).rawValue, forKey: "statisticsSource")
            UserDefaults.standard.set(SettingsSection.statistics.rawValue, forKey: "settingsSection")
        } else {
            UserDefaults.standard.set(SettingsSection.widget.rawValue, forKey: "settingsSection")
        }
        welcomeWindow?.orderOut(nil)
        showSettings()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSessions(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main enum WeekleftLauncher {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--session-hook"), CommandLine.arguments.indices.contains(index + 1),
           let provider = ProviderID(rawValue: CommandLine.arguments[index + 1]) {
            SessionHooks.captureFromStandardInput(provider: provider); return
        }
        if CommandLine.arguments.contains("--session-probe") {
            let signal = DispatchSemaphore(value: 0)
            Task.detached {
                var catalog: [AgentSession] = []
                for provider in ProviderID.allCases {
                    do {
                        catalog += try await (provider == .codex
                            ? SessionSources.codex(path: CodexProvider.discoverCLI() ?? "")
                            : SessionSources.claude(path: SessionSources.discoverClaude() ?? ""))
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
        if let index = CommandLine.arguments.firstIndex(of: "--render-native"), CommandLine.arguments.indices.contains(index + 1) {
            let state = SnapshotStore.load()
            var compact = state.preferences; compact.showFiveHour = false
            var expanded = state.preferences; expanded.showFiveHour = true
            let renderer = ImageRenderer(content: HStack(spacing: 20) {
                WeekleftCard(snapshots: state.snapshots, preferences: compact).background(Color(white: 0.14)).clipShape(RoundedRectangle(cornerRadius: 26))
                WeekleftCard(snapshots: state.snapshots, preferences: expanded).background(Color(white: 0.14)).clipShape(RoundedRectangle(cornerRadius: 26))
            }.padding(24).background(Color(white: 0.08)))
            renderer.scale = 2
            if let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Native SwiftUI render saved") } catch { fputs("Render write failed\n", stderr) }
            } else { fputs("Native render failed\n", stderr) }
            return
        }
        if CommandLine.arguments.contains("--probe") {
            let signal = DispatchSemaphore(value: 0)
            Task.detached {
                for id in ProviderID.allCases {
                    do {
                        let snapshot = try await (id == .codex ? CodexProvider.fetch(cliPath: CodexProvider.discoverCLI() ?? "") : ClaudeProvider.fetch())
                        let data = try JSONEncoder().encode(snapshot)
                        print(String(decoding: data, as: UTF8.self))
                    } catch { print("\(id.title): \((error as? UsageError)?.errorDescription ?? "Не удалось получить данные")") }
                }
                signal.signal()
            }
            _ = signal.wait(timeout: .now() + 60); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--session-preview"), CommandLine.arguments.indices.contains(index + 1) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])),
                  let rows = try? JSONDecoder().decode([AgentSession].self, from: data) else { exit(1) }
            delegate.previewSessions = rows
        }
        #endif
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
