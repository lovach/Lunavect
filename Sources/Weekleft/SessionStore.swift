import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var refreshing = false
    @Published var issues: [ProviderID: String] = [:]
    @Published var hooksInstalled: [ProviderID: Bool] = [:]
    @Published var connectionMessage: String?
    @Published var updatedAt: Date?
    @Published private(set) var providers = ProviderID.allCases
    func useProviders(_ providers: [ProviderID]) {
        guard self.providers != providers else { return }
        self.providers = providers
        catalog = catalog.filter { providers.contains($0.key) }
        issues = issues.filter { providers.contains($0.key) }
        if let row = lastHidden, !providers.contains(row.provider) { lastHidden = nil }
        publishVisible()
    }
    var onObservation: (([AgentSession], Date) -> Void)?
    @Published private(set) var hiddenCount = 0
    @Published private(set) var lastHidden: AgentSession?
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 50
        return manager
    }()
    @Published private(set) var arrangement = SessionArrangement()
    @Published private(set) var hiddenIDs: [String] = []
    @Published private(set) var hiddenSessions: [SessionVisibility.Summary] = []
    @Published var autoHideMinutes: Int {
        didSet {
            defaults.set(autoHideMinutes, forKey: "sessionAutoHideMinutes")
            if autoHideMinutes == 0 { inactiveSince.removeAll() }
        }
    }
    private let defaults: UserDefaults
    // Retain observed inactivity beyond the source's status freshness window.
    // Poll timestamps are deliberately not activity timestamps.
    private var inactiveSince: [String: Date] = [:]
    private var arrangementURL: URL?
    private var visibility: SessionVisibility?
    private var allSessions: [AgentSession] = []
    private var undoDismissTask: Task<Void, Never>?
    private let undoDelay: Duration
    init(directory: URL? = nil, undoDelay: Duration = .seconds(4), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedMinutes = defaults.integer(forKey: "sessionAutoHideMinutes")
        autoHideMinutes = [5, 10, 20].contains(savedMinutes) ? savedMinutes : 0
        self.undoDelay = undoDelay
        let preview = CommandLine.arguments.contains("--session-preview")
        let base = directory ?? (preview ? FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect-preview-" + UUID().uuidString) : SessionHooks.directory)
        arrangementURL = base.appendingPathComponent("arrangement.json")
        if let url = arrangementURL, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SessionArrangement.self, from: data) { arrangement = saved }
        do {
            let file = base.appendingPathComponent("hidden-sessions.json")
            let result = try LocalStateRecovery.load(from: file, empty: Optional<SessionVisibility>.none) { try Optional(SessionVisibility(url: $0)) }
            visibility = try result.value ?? SessionVisibility(url: file)
            if result.backupURL != nil { connectionMessage = L("Повреждённый список скрытых сессий сохранён отдельно. Управление сессиями восстановлено.") }
            // Include old events outside the merge freshness window when repairing history.
            try visibility?.removeUnstartedClaudeLifecycles(SessionHooks.load(at: base))
            hiddenCount = visibility?.hidden.count ?? 0
            hiddenIDs = (visibility?.hidden ?? []).sorted()
            hiddenSessions = visibility?.summaries ?? []
        }
        catch { connectionMessage = error.localizedDescription }
    }
    func hide(_ session: AgentSession) throws {
        guard visibility != nil else { throw SessionError.invalidResponse }
        try visibility?.hide(session)
        registerVisibilityUndo(session, hidden: false)
        if allSessions.isEmpty { allSessions = sessions }
        lastHidden = session
        undoDismissTask?.cancel()
        let delay = undoDelay
        undoDismissTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.lastHidden = nil
        }
        publishVisible()
    }
    func undoHide(now: Date = Date()) throws {
        guard let row = lastHidden else { return }
        if undoManager.canUndo { undoManager.undo() }
        else { try restore(row.id, now: now) }
    }
    func restoreHidden(now: Date = Date()) throws {
        for id in hiddenIDs { inactiveSince[id] = now }
        try visibility?.restoreAll(); undoDismissTask?.cancel(); lastHidden = nil; publishVisible()
    }
    func restore(_ id: String, now: Date = Date()) throws {
        let row = allSessions.first { $0.id == id }
        let wasHidden = hiddenIDs.contains(id)
        try visibility?.setHidden(id, false)
        if wasHidden, let row { registerVisibilityUndo(row, hidden: true) }
        inactiveSince[id] = now
        // A manual restore becomes the newest Undo action. Dismiss an older
        // hide toast so its button cannot undo a different visibility change.
        undoDismissTask?.cancel(); lastHidden = nil
        publishVisible()
    }
    func removeHidden(_ id: String? = nil) throws {
        let ids = id.map { Set([$0]) } ?? Set(hiddenIDs)
        try visibility?.removeHidden(ids)
        // A removed local record must not be recreated by an older Undo entry.
        undoManager.removeAllActions()
        if let lastHidden, ids.contains(lastHidden.id) { undoDismissTask?.cancel(); self.lastHidden = nil }
        publishVisible()
    }
    private func registerVisibilityUndo(_ row: AgentSession, hidden: Bool) {
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            // A new task supersedes the visibility decision for its previous turn.
            guard let current = store.allSessions.first(where: { $0.id == row.id }),
                  current.turnStartedAt == row.turnStartedAt,
                  store.providers.contains(current.provider) else { return }
            do {
                if hidden { try store.hide(current) }
                else { try store.restore(current.id) }
            } catch { store.connectionMessage = L("Не удалось сохранить изменение. Попробуйте ещё раз.") }
        }
        undoManager.setActionName(L(hidden ? "Возврат сессии" : "Скрытие сессии"))
        if grouped { undoManager.endUndoGrouping() }
    }
    func setPinned(_ id: String, _ pinned: Bool) throws {
        var next = arrangement
        if pinned { next.pinned.insert(id) } else { next.pinned.remove(id) }
        try saveArrangement(next)
    }
    func move(_ id: String, before target: String, after: Bool = false, visible: [String]) throws {
        var next = arrangement
        next.move(id, before: target, after: after, visible: visible)
        try saveArrangement(next)
    }
    private func saveArrangement(_ next: SessionArrangement) throws {
        guard let arrangementURL else { throw SessionError.unavailable }
        try next.save(to: arrangementURL); arrangement = next
    }
    private var publishedPhases: [SessionPhase] = []
    private func publishVisible(now: Date = Date()) {
        let visible = (visibility?.visible(allSessions) ?? allSessions).filter { providers.contains($0.provider) }
        let phases = visible.map { $0.effectivePhase(now: now) }
        if sessions != visible || publishedPhases != phases { publishedPhases = phases; sessions = visible }
        let hidden = (visibility?.summaries ?? []).filter { $0.provider.map(providers.contains) ?? false }
        if hiddenSessions != hidden { hiddenSessions = hidden }
        let ids = hidden.map(\.id).sorted()
        if hiddenIDs != ids { hiddenIDs = ids }
        if hiddenCount != ids.count { hiddenCount = ids.count }
        updatePollingTimers()
    }
    private var catalog: [ProviderID: [AgentSession]] = [:]
    private var localTimer: Timer?
    private var sourceTimer: Timer?
    private var eventWatcher: DispatchSourceFileSystemObject?
    private var started = false
    private var panelVisible = false
    private var polling: SessionPolling?
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible; updatePollingTimers()
    }
    private func updatePollingTimers() {
        guard started else { return }
        let policy = SessionPolling(panelVisible: panelVisible, hasActiveSessions: allSessions.contains { $0.effectivePhase().isActive })
        guard polling != policy else { return }
        polling = policy
        localTimer?.invalidate(); sourceTimer?.invalidate()
        localTimer = Timer.scheduledTimer(withTimeInterval: policy.events, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.readEvents() }
        }
        sourceTimer = Timer.scheduledTimer(withTimeInterval: policy.catalog, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        localTimer?.tolerance = 0.1; sourceTimer?.tolerance = 1
        if let localTimer { RunLoop.main.add(localTimer, forMode: .common) }
        if let sourceTimer { RunLoop.main.add(sourceTimer, forMode: .common) }
    }
    func stop() {
        started = false; polling = nil
        localTimer?.invalidate(); localTimer = nil
        sourceTimer?.invalidate(); sourceTimer = nil
        eventWatcher?.cancel(); eventWatcher = nil
    }
    private var desktopTitles: [String: String] = [:]
    private var titlesCheckedAt = Date.distantPast
    private var codexPath: () -> String = { CodexProvider.discoverCLI() ?? "" }
    var currentSessions: [AgentSession] { sessions.filter { $0.isCurrent() } }
    var activeCount: Int { currentSessions.filter { $0.effectivePhase().isActive }.count }
    func start(codexPath: @escaping () -> String) {
        guard !started else { return }; started = true
        self.codexPath = codexPath
        repairMovedConnections()
        updateHookConfiguration()
        Task { await refresh() }
        updatePollingTimers()
        // Atomic hook writes notify the app immediately, including while hidden.
        try? FileManager.default.createDirectory(at: SessionHooks.directory, withIntermediateDirectories: true)
        let fd = Darwin.open(SessionHooks.directory.path, O_EVTONLY)
        if fd >= 0 {
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .global(qos: .utility))
            watcher.setEventHandler { [weak self] in Task { @MainActor in await self?.readEvents() } }
            watcher.setCancelHandler { close(fd) }
            eventWatcher = watcher; watcher.resume()
        }
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        let path = codexPath()
        async let codex = fetchIfEnabled(.codex, path: path)
        async let claude = fetchIfEnabled(.claude, path: path)
        for (provider, result) in await [(ProviderID.codex, codex), (.claude, claude)] {
            guard providers.contains(provider), let result else { continue }
            switch result {
            case .success(let rows): catalog[provider] = rows; issues.removeValue(forKey: provider)
            case .failure(let error):
                issues[provider] = error.localizedDescription
                catalog[provider] = (catalog[provider] ?? []).map { row in var row = row; row.observedAt = .distantPast; return row }
            }
        }
        updatedAt = Date(); await readEvents(); updateHookConfiguration()
    }
    private func fetchIfEnabled(_ id: ProviderID, path: String) async -> Result<[AgentSession], Error>? {
        guard providers.contains(id) else { return nil }
        return await Self.capture {
            if id == .codex { return try await SessionSources.codex(path: path) }
            return try await SessionSources.claude(path: SessionSources.discoverClaude() ?? "")
        }
    }
    private var readingEvents = false
    private func readEvents() async {
        guard !readingEvents else { return }; readingEvents = true
        defer { readingEvents = false }
        guard !providers.isEmpty else { acceptSessions([]); return }
        let rows = catalog.values.flatMap { $0 }
        var events = await Task.detached(priority: .utility) {
            SessionSources.legacyEvents(catalog: rows) + SessionHooks.load()
        }.value
        if providers.contains(.codex) { events += await CodexActivityReader.shared.events(catalog: rows) }
        events = events.filter { providers.contains($0.provider) }
        var merged = SessionList.merge(catalog: catalog.values.flatMap { $0 }, events: events)
        if Date().timeIntervalSince(titlesCheckedAt) >= (polling?.titles ?? 15) {
            let hidden = hiddenIDs
            let missingCodex = Set(hidden.compactMap { id -> String? in
                id.hasPrefix("codex:") ? String(id.dropFirst(6)) : nil
            })
            let savedTitles = await Task.detached(priority: .utility) { CodexSessionMetadata.titles(for: missingCodex) }.value
            let hiddenClaude = hidden.filter { $0.hasPrefix("claude:") }.map { String($0.dropFirst(7)) }
            let ids = Set(merged.filter { $0.provider == .claude }.map(\.sessionID) + hiddenClaude)
            desktopTitles = await Task.detached(priority: .utility) { ClaudeSessionMetadata.titles(for: ids) }.value
            var titles = Dictionary(uniqueKeysWithValues: savedTitles.map { ("codex:" + $0.key, $0.value) })
            for (id, title) in desktopTitles { titles["claude:" + id] = title }
            for row in merged where titles[row.id] == nil { titles[row.id] = row.title }
            do { try visibility?.updateTitles(titles) } catch { connectionMessage = error.localizedDescription }
            titlesCheckedAt = Date()
        }
        for i in merged.indices where merged[i].provider == .claude {
            if let title = desktopTitles[merged[i].sessionID] { merged[i].title = title }
            else if merged[i].title.hasPrefix("scratch-") { merged[i].title = L("Сессия Claude") }
        }
        acceptSessions(merged)
    }
    func acceptSessions(_ rows: [AgentSession], now: Date = Date()) {
        let taskRows = rows.filter { providers.contains($0.provider) && !($0.isUnstartedClaudeLifecycle && $0.phase == .finished) }
        onObservation?(taskRows, now)
        do {
            try visibility?.removeUnstartedClaudeLifecycles(rows)
            let restored = try visibility?.restoreNewTasks(taskRows, now: now) ?? []
            if let lastHidden, restored.contains(lastHidden.id) {
                undoDismissTask?.cancel(); self.lastHidden = nil
            }
            try hideInactiveSessions(taskRows, now: now)
        } catch { connectionMessage = error.localizedDescription }
        allSessions = taskRows; publishVisible(now: now)
    }
    private func hideInactiveSessions(_ rows: [AgentSession], now: Date) throws {
        guard [5, 10, 20].contains(autoHideMinutes), let visibility else { return }
        let visible = visibility.visible(rows)
        let ids = Set(visible.map(\.id))
        inactiveSince = inactiveSince.filter { ids.contains($0.key) }
        for row in visible {
            // Never hide ongoing work, requests for input/permission, or an
            // unconfirmed state merely because its latest event is old.
            guard !row.phase.isActive, row.phase != .unknown, row.runtimeConfirmed != false,
                  !row.isUnstartedClaudeLifecycle else {
                inactiveSince.removeValue(forKey: row.id)
                continue
            }
            if inactiveSince[row.id] == nil {
                // Historical catalog entries must not flood the hidden list.
                guard row.effectivePhase(now: now) != .unknown else { continue }
                inactiveSince[row.id] = min(row.updatedAt, now)
            }
            let since = max(inactiveSince[row.id]!, min(row.updatedAt, now))
            inactiveSince[row.id] = since
            if now.timeIntervalSince(since) >= Double(autoHideMinutes * 60) {
                try self.visibility?.hide(row, now: now)
                inactiveSince.removeValue(forKey: row.id)
            }
        }
    }
    func updateHookConfiguration() {
        for provider in ProviderID.allCases { hooksInstalled[provider] = SessionHooks.installed(provider) }
    }
    private func repairMovedConnections() {
        guard let executable = SessionHooks.monitorExecutable() else { return }
        for provider in providers {
            do {
                if SessionHooks.configured(provider), !SessionHooks.installed(provider) {
                    try SessionHooks.install(provider: provider, executable: executable)
                }
                if provider == .claude, ClaudeProvider.statusLineConfigured(), !ClaudeProvider.statusLineInstalled() {
                    try ClaudeProvider.installStatusLine(executable: executable)
                }
            } catch { connectionMessage = L("Не удалось восстановить подключение после переноса приложения. Откройте «Подключения» и повторите настройку.") }
        }
    }
    func disconnect(_ provider: ProviderID) -> Bool {
        do {
            if provider == .claude { try ClaudeProvider.removeStatusLine() }
            try SessionHooks.remove(provider: provider)
            updateHookConfiguration()
            return true
        } catch {
            connectionMessage = L("Не удалось отключить обработчики. Настройки клиента сохранены; повторите попытку.")
            return false
        }
    }
    func toggleHooks(_ provider: ProviderID) {
        do {
            if hooksInstalled[provider] == true {
                try SessionHooks.remove(provider: provider)
                connectionMessage = L("События {0} отключены. Остальные обработчики сохранены.", provider.title)
            } else {
                guard let executable = SessionHooks.monitorExecutable() else { throw SessionError.unavailable }
                try SessionHooks.install(provider: provider, executable: executable)
                connectionMessage = provider == .codex
                    ? L("Обработчики добавлены. В Codex откройте /hooks и разрешите команды Lunavect. До первого события статус останется неизвестным.")
                    : L("Обработчики добавлены. События появятся при следующем действии в Claude Code; уже открытой сессии может потребоваться перезапуск.")
            }
        } catch { connectionMessage = error.localizedDescription }
        updateHookConfiguration()
    }
    nonisolated private static func capture(_ body: () async throws -> [AgentSession]) async -> Result<[AgentSession], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

enum SessionNavigation {
    @MainActor static func open(_ session: AgentSession) async throws {
        if session.client == .terminal || session.client == .background {
            let executable = session.provider == .claude ? SessionSources.discoverClaude() : CodexProvider.discoverCLI()
            guard let executable else { throw SessionOpeningError.missingCLI(session.provider) }
            guard let script = session.terminalScript(executable: executable) else { throw SessionOpeningError.invalidID }
            var directoryExists: ObjCBool = false
            guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directoryExists), directoryExists.boolValue else { throw SessionOpeningError.missingProject }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw SessionOpeningError.missingTerminal }
            let directory = SessionHooks.directory.appendingPathComponent("Openers")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(session.provider.rawValue + "-" + session.sessionID + ".command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            do { _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) }
            catch { throw SessionOpeningError.launchFailed(session.client) }
            return
        }
        let url: URL?
        if session.provider == .codex { url = session.codexURL }
        else if session.client == .vscode { url = session.vscodeURL }
        else {
            let records = await Task.detached { ClaudeSessionMetadata.records(for: [session.sessionID]) }.value
            url = records[session.sessionID].flatMap { session.claudeDesktopURL(desktopID: $0.desktopID) }
        }
        guard let url else { throw session.provider == .claude && session.client != .vscode ? SessionOpeningError.missingDesktopLink : SessionOpeningError.invalidID }
        let clientName = session.client == .vscode ? "VS Code" : session.provider.title
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw SessionOpeningError.missingClient(clientName) }
        guard NSWorkspace.shared.open(url) else { throw SessionOpeningError.launchFailed(session.client) }
    }
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @MainActor static func openCodex(_ session: AgentSession) -> Bool {
        guard let url = session.codexURL else { return false }
        return NSWorkspace.shared.open(url)
    }
    @MainActor static func revealProject(_ session: AgentSession) -> Bool {
        guard session.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: session.cwd) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
    }
}

enum AppArtwork {
    private static func mark(named name: String) -> NSImage? {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: name, withExtension: "png")
        #endif
        return url.flatMap(NSImage.init(contentsOf:))
    }
    static let brandMark = mark(named: "LunavectMark")
    static let brandMarkLeft = mark(named: "LunavectMarkLeft")
    static let brandMarkRight = mark(named: "LunavectMarkRight")
    static var icon: NSImage? {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        #endif
        return url.flatMap(NSImage.init(contentsOf:))
    }
}
