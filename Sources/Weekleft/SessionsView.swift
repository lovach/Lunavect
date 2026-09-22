import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct SessionsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var store: SessionStore
    @ObservedObject var panelState = SessionPanelState(isVisible: true)
    @ObservedObject var updates: AppUpdates
    var awake: KeepAwake
    var isPreview = false
    var onSettings: () -> Void
    var onConnections: (() -> Void)? = nil
    var onMenuBarSettings: (() -> Void)? = nil
    var onKeepAwakeSettings: (() -> Void)? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var onReorderingChange: ((Bool) -> Void)? = nil
    @StateObject private var reorder = SessionReorderState()
    @State private var geometry = SessionPanelGeometry()
    @State private var sectionHeights: [String: CGFloat] = [:]
    // Keep per-frame changes out of the panel; only rows observe this object.
    @State private var swipePresentation = SessionSwipePresentation()
    @State var query = ""
    @State var provider = ""
    @State var showingAwake = false
    @State private var activeOnly = false
    @State var attentionOnly = false
    @FocusState private var focusedSession: String?
    @State private var actionIssue: String?
    @State private var showingHidden = false
    private func visible(at now: Date) -> [AgentSession] {
        if let rows = reorder.rows { return rows }
        return filteredSessions(at: now)
    }
    func filteredSessions(at now: Date) -> [AgentSession] {
        panelState.stableOrder(store.arrangement.arranged(SessionList.filter(store.sessions, query: query, provider: ProviderID(rawValue: provider), activeOnly: activeOnly, now: now)))
            .filter { !attentionOnly || [.permission, .input].contains($0.effectivePhase(now: now)) }
    }
    func currentCounts(at now: Date) -> (total: Int, working: Int, waiting: Int) {
        let phases = store.sessions.filter { $0.isCurrent(now: now) }.map { $0.effectivePhase(now: now) }
        return (phases.count, phases.filter { $0 == .running }.count,
                phases.filter { [.permission, .input].contains($0) }.count)
    }
    var body: some View {
        SessionPanelContent(state: panelState) {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let height = panelHeight(at: context.date)
            Group {
                if showingHidden { hiddenList } else { sessionList(at: context.date) }
            }.frame(width: 360, height: height)
                .onChange(of: height, initial: true) { _, value in onHeightChange?(value) }
        }
            .onChange(of: panelState.isVisible, initial: true) { _, visible in
                if visible { panelState.reconcileOrder(store.arrangement.arranged(store.sessions)) }
            }
            .onChange(of: store.sessions) { _, rows in
                panelState.reconcileOrder(store.arrangement.arranged(rows))
            }
        }
            .onChange(of: store.providers) { _, values in
                if values.count < 2 || !values.contains(where: { $0.rawValue == provider }) { provider = "" }
            }
            .onChange(of: showingHidden) { _, hidden in
                if !hidden { focusedSession = SessionKeyboardFocus.search }
            }
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .alert(L("Не удалось выполнить действие"), isPresented: Binding(get: { actionIssue != nil }, set: { if !$0 { actionIssue = nil } })) {
                Button(L("Понятно")) { actionIssue = nil }
            } message: { Text(L(actionIssue ?? "")) }
    }
    private var hasFilters: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !provider.isEmpty || activeOnly || attentionOnly }
    private func panelHeight(at now: Date) -> CGFloat {
        if showingHidden { return min(480, max(300, CGFloat(store.hiddenCount) * 62 + 180)) }
        return listLayout(rowCount: visible(at: now).count).panelHeight
    }
    private func listLayout(rowCount: Int) -> SessionPanelLayout {
        SessionPanelLayout(rowCount: rowCount, topHeight: sectionHeights["top"] ?? 142,
                           bottomHeight: sectionHeights["bottom"] ?? 30)
    }
    private var hiddenList: some View {
        HiddenSessionsView(sessions: store.hiddenSessions,
                           onBack: { showingHidden = false },
                           onRestore: { id in perform { try store.restore(id) } },
                           onRemove: { id in perform { try store.removeHidden(id) } },
                           onRemoveAll: { perform { try store.removeHidden() } },
                           onRestoreMany: restoreHidden)
    }
    func restoreHidden(_ ids: [String]) {
        perform {
            store.undoManager.beginUndoGrouping()
            defer { store.undoManager.endUndoGrouping() }
            for id in ids { try store.restore(id) }
        }
    }
    private func sessionList(at now: Date) -> some View {
        let rows = visible(at: now)
        let layout = listLayout(rowCount: rows.count)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
            header(at: now).padding(.horizontal, 12).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            if let issue = panelState.issue {
                HStack(alignment: .top, spacing: 8) {
                    InterfaceLabel(issue, .warning)
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { panelState.issue = nil } label: {
                        InterfaceIcon(.close).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(L("Закрыть сообщение"))
                }.padding(.horizontal, 12).padding(.bottom, 8)
                    .accessibilityIdentifier("session-navigation-issue")
            }
            if updates.notice != nil { UpdateNoticeView(updates: updates).padding(.horizontal, 12).padding(.bottom, 8) }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    InterfaceIcon(.search).foregroundStyle(.secondary)
                    TextField(L("Найти сессию или проект"), text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("session-search")
                        .focused($focusedSession, equals: "search-field")
                        .onKeyPress(.downArrow) {
                            guard let first = rows.first else { return .ignored }
                            focusedSession = first.id; return .handled
                        }
                    if !query.isEmpty {
                        Button { query = "" } label: { InterfaceIcon(.close).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Очистить поиск")).accessibilityLabel(L("Очистить поиск"))
                    }
                }.padding(7).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 14) {
                    if store.providers.count > 1 {
                        Picker(L("Приложение"), selection: $provider) {
                        Text(L("Все")).tag("")
                        ForEach(store.providers) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("session-provider-filter")
                    } else {
                        Text(store.providers.first?.title ?? L("Сессии")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Toggle(L("Активные"), isOn: $activeOnly).toggleStyle(.checkbox)
                        .font(.system(size: 11)).help(L("Работающие сессии и сессии, ожидающие ответа"))
                        .accessibilityIdentifier("session-active-filter")
                }
                if hasFilters {
                    HStack {
                        let total = currentCounts(at: now).total
                        Text(L("Показано {0} из {1}", String(rows.count), String(total)))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { query = ""; provider = ""; activeOnly = false; attentionOnly = false } label: {
                            Text(L("Сбросить фильтры")).frame(minHeight: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.blue)
                    }.font(.system(size: 12)).padding(.top, 3)
                }
            }.padding(.horizontal, 12).padding(.bottom, 7).disabled(reorder.rows != nil)
            Divider().opacity(contrast == .increased ? 1 : 0.45)
            }.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SessionPanelSectionHeights.self, value: ["top": geometry.size.height])
                })
            if rows.isEmpty {
                // Only the centre may scroll when translated copy or diagnostics
                // needs more room. Never push the panel controls outside its bounds.
                ScrollView { emptyState.frame(maxWidth: .infinity) }
                    .frame(height: layout.viewportHeight).padding(.vertical, SessionPanelLayout.verticalInset)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: SessionPanelLayout.rowSpacing) {
                        ForEach(rows) { row in
                                SessionRow(
                                    session: row, now: now, phase: row.effectivePhase(now: now),
                                    swipePresentation: swipePresentation, onHide: { perform { try store.hide(row) } },
                                    onError: { actionIssue = $0 }, clientResolver: store.clientResolver,
                                    isPinned: store.arrangement.pinned.contains(row.id),
                                    onPin: { perform(userReordered: true) { try store.setPinned(row.id, !store.arrangement.pinned.contains(row.id)) } },
                                       onMove: { movingDown in move(row.id, movingDown: movingDown, rows: rows) },
                                       canMoveUp: SessionReorderState.adjacentTarget(for: row.id, movingDown: false, rows: rows, pinned: store.arrangement.pinned) != nil,
                                       canMoveDown: SessionReorderState.adjacentTarget(for: row.id, movingDown: true, rows: rows, pinned: store.arrangement.pinned) != nil,
                                       onDragStart: { image, windowFrame, grab in
                                           guard let frame = geometry.regions[row.id] else { return }
                                           onReorderingChange?(true)
                                           reorder.begin(row.id, rows: rows, pinned: store.arrangement.pinned)
                                           reorder.lift(image, frame: frame, windowFrame: windowFrame, grab: grab)
                                       },
                                       onDragMove: { reorder.update(windowPoint: $0, regions: geometry.regions, viewport: geometry.viewport) },
                                       onDragEnd: { point in
                                           if let point {
                                               reorder.update(windowPoint: point, regions: geometry.regions, viewport: geometry.viewport)
                                               if let id = reorder.id, let target = reorder.target {
                                                   perform(userReordered: true) { try store.move(id, before: target, after: reorder.insertAfter, visible: rows.map(\.id)) }
                                               }
                                           }
                                           reorder.end(); onReorderingChange?(false)
                                       },
                                       isDragging: reorder.id == row.id, isFocused: focusedSession == row.id)
                                .focusable().focused($focusedSession, equals: row.id)
                                .focusEffectDisabled()
                                .onKeyPress(.return) { open(row); return .handled }
                                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                                    if press.modifiers.contains(.option) {
                                        move(row.id, movingDown: press.key == .downArrow, rows: rows)
                                        return .handled
                                    }
                                    guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return .ignored }
                                    let next = index + (press.key == .downArrow ? 1 : -1)
                                    if rows.indices.contains(next) { focusedSession = rows[next].id }
                                    else if next < 0 { focusedSession = "search-field" }
                                    return .handled
                                }
                                .overlay(alignment: reorder.insertAfter ? .bottom : .top) {
                                    if reorder.target == row.id {
                                        Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 4).allowsHitTesting(false)
                                    }
                                }
                                .transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: SessionRowRegions.self, value: [row.id: geometry.frame(in: .named("session-panel"))])
                                })
                        }
                    }.padding(.horizontal, 8)
                        .background(SessionScrollOffsetReader { [panelState] offset in
                            panelState.observeScrollOffset(offset)
                        })
                }.background(GeometryReader { geometry in
                    Color.clear.preference(key: SessionScrollRegion.self, value: geometry.frame(in: .named("session-panel")))
                })
                .scrollIndicators(.visible)
                .frame(height: layout.viewportHeight).padding(.vertical, SessionPanelLayout.verticalInset)
                .onChange(of: panelState.viewportRequest) { _, request in
                    if let request, rows.contains(where: { $0.id == request.id }) {
                        proxy.scrollTo(request.id, anchor: request.alignToTop ? .top : nil)
                    }
                }
                }.frame(height: layout.viewportHeight + SessionPanelLayout.verticalInset * 2)
            }
            if layout.showsOverflow {
                overflowControl(rows: rows, layout: layout)
            }
            VStack(spacing: 0) {
            Divider().opacity(contrast == .increased ? 1 : 0.45)
            footer.padding(.horizontal, 12).padding(.vertical, 7).fixedSize(horizontal: false, vertical: true)
            }.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SessionPanelSectionHeights.self, value: ["bottom": geometry.size.height])
                })
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            focusedSession = SessionKeyboardFocus.recover(focusedSession, visibleIDs: ids)
        }
        .onChange(of: focusedSession) { old, current in
            panelState.focusChanged(from: old, to: current, visibleIDs: rows.map(\.id))
            // Removing the focused native control can clear FocusState before
            // the changed list is delivered. Recover only when its row vanished.
            if current == nil, let old, old != SessionKeyboardFocus.search, !rows.contains(where: { $0.id == old }) {
                focusedSession = SessionKeyboardFocus.search
            }
        }
        .overlay(alignment: .topLeading) {
            if let image = reorder.image, reorder.id != nil {
                Image(nsImage: image).resizable().frame(width: image.size.width, height: image.size.height)
                    .shadow(color: .black.opacity(0.3), radius: 7, y: 3)
                    .position(reorder.position).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background {
            Button("") { focusedSession = "search-field" }.keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
        }
        .coordinateSpace(name: "session-panel")
        .onPreferenceChange(SessionRowRegions.self) { geometry.regions = $0 }
        .onPreferenceChange(SessionScrollRegion.self) { geometry.viewport = $0 }
        .onPreferenceChange(SessionPanelSectionHeights.self) { sectionHeights = $0 }
        .background(SessionSwipeView(geometry: geometry, enabled: reorder.rows == nil, onOffset: { id, offset in
            swipePresentation.update(id: id, offset: offset, reduceMotion: reduceMotion)
        }, onAction: { id, action in
            guard let row = store.sessions.first(where: { $0.id == id }) else { return }
            if action == .hide { perform { try store.hide(row) } }
            else {
                Task { @MainActor in
                    do { try await SessionNavigation.open(row, resolver: store.clientResolver) }
                            catch {
                                actionIssue =
                                    (error as? SessionOpeningError)?.errorDescription
                                    ?? L(
                                        "Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…»."
                                    )
                            }
                        }
            }
        }))
        .background {
            Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency || contrast == .increased ? 1 : 0.94)
                .contentShape(Rectangle()).onTapGesture { focusedSession = nil }
        }
        .onKeyPress(.escape) {
            guard focusedSession != nil else { return .ignored }
            focusedSession = nil; return .handled
        }
    }
    private func overflowControl(rows: [AgentSession], layout: SessionPanelLayout) -> some View {
        SessionOverflowControl(scrollPosition: panelState.scrollPosition, ids: rows.map(\.id),
                               layout: layout, reordering: reorder.rows != nil) { target in
            panelState.scrollPage(to: target, visibleIDs: rows.map(\.id))
        }
    }
    func header(at now: Date) -> some View {
        let counts = currentCounts(at: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let mark = AppArtwork.brandMark { Image(nsImage: mark).resizable().renderingMode(.original).scaledToFit().frame(width: 36, height: 36).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lunavect").font(.system(size: 16, weight: .semibold))
                    Text(isPreview ? L("Проверка · тестовые сессии") : L("Текущие сессии")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                KeepAwakeButton(awake: awake, isExpanded: showingAwake) { showingAwake.toggle() }.disabled(isPreview)
                    .popover(isPresented: $showingAwake) {
                        KeepAwakeControls(awake: awake, onReviewConditions: {
                            showingAwake = false
                            onKeepAwakeSettings?()
                        }).padding(10).frame(width: 330)
                    }
                Button { Task { await store.refresh() } } label: { InterfaceIcon(.refresh, size: 18) }
                    .buttonStyle(InterfaceToolbarStyle()).disabled(store.refreshing || isPreview).help(L("Обновить сессии"))
                    .accessibilityLabel(L("Обновить сессии"))
                Button(action: onSettings) { InterfaceIcon(.settings, size: 18) }
                    .buttonStyle(InterfaceToolbarStyle())
                    .disabled(isPreview).help(L("Настройки")).accessibilityLabel(L("Настройки"))
                    .accessibilityIdentifier("sessions-settings-button")
                    .contextMenu {
                        Button(L("Статус в строке меню…"), action: onMenuBarSettings ?? onSettings)
                        Divider()
                        Button(L("Все настройки…"), action: onSettings)
                    }
            }
            HStack(spacing: 10) {
                metric(counts.working, L("в работе"), .blue)
                Button { attentionOnly.toggle() } label: {
                    metric(counts.waiting,
                           L(attentionOnly ? "Только ожидание" : "в ожидании"), .orange)
                        .frame(minHeight: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(L("Показать сессии, которым нужен ответ или разрешение"))
                    .disabled(reorder.rows != nil)
                    .accessibilityLabel(L("В ожидании: {0}", String(counts.waiting)))
                    .accessibilityValue(L(attentionOnly ? "Включено" : "Выключено"))
                    .accessibilityAddTraits(attentionOnly ? .isSelected : [])
                    .accessibilityIdentifier("session-attention-filter")
                Spacer()
            }
        }
    }
    private func metric(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }.font(.system(size: 11))
    }
    private var emptyState: some View {
        let loading = store.refreshing && store.updatedAt == nil
        return VStack(spacing: 12) {
            if loading { ProgressView().controlSize(.small) }
            else { InterfaceIcon(hasFilters ? .search : .sessions, size: 29).foregroundStyle(.secondary) }
            Text(loading ? L("Получаем сессии…") : hasFilters ? L("Ничего не найдено") : L("Нет подтверждённых текущих сессий"))
                .font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !loading {
                Text(hasFilters ? L("Нет сессий для выбранных фильтров. Сбросьте фильтры, чтобы увидеть остальные сессии.") : L("Приложения ещё не передали живой статус."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !loading && !hasFilters && store.providers.isEmpty {
                Button(L("Подключить приложения"), action: onConnections ?? onSettings)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.blue)
            }
        }.padding(24)
    }
    private func open(_ row: AgentSession) {
        Task { @MainActor in
            do { try await SessionNavigation.open(row, resolver: store.clientResolver) }
            catch {
                actionIssue =
                    (error as? SessionOpeningError)?.errorDescription
                    ?? L(
                        "Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…»."
                    )
            }
        }
    }
    private func move(_ id: String, movingDown: Bool, rows: [AgentSession]) {
        guard reorder.rows == nil else { return }
        perform(userReordered: true) { _ = try SessionReorderState.move(id, movingDown: movingDown, rows: rows, store: store) }
    }
    private func perform(userReordered: Bool = false, _ action: () throws -> Void) {
        do {
            var transaction = Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.2))
            transaction.disablesAnimations = reduceMotion
            try withTransaction(transaction, action)
            if userReordered {
                panelState.reconcileOrder(store.arrangement.arranged(store.sessions), userReordered: true)
                panelState.scrollAfterReorder(focusedID: focusedSession, visibleIDs: filteredSessions(at: Date()).map(\.id))
            }
        } catch { actionIssue = SessionActionFeedback.message(for: error) }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let hidden = store.lastHidden {
                HStack {
                    Text(L("Скрыто: {0}", hidden.displayTitle)).lineLimit(1)
                    Spacer()
                    Button(L("Отменить")) { perform { try store.undoHide() } }.buttonStyle(.plain).foregroundStyle(.blue)
                }.font(.system(size: 11))
            }
            Button { showingHidden = true } label: {
                HStack {
                    InterfaceLabel(L("Скрытые сессии"), .hidden)
                    Spacer()
                    Text(String(store.hiddenCount)).monospacedDigit()
                    InterfaceIcon(.forward, size: 12)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            if !store.issues.isEmpty {
                Button(action: onConnections ?? onSettings) {
                    InterfaceLabel(L("Проверить подключение") + " · " + store.issues.keys.sorted(by: { $0.rawValue < $1.rawValue }).map(\.title).joined(separator: ", "), .warning)
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).foregroundStyle(.orange)
                    .help(store.issues.values.map { L($0) }.joined(separator: "\n"))
            }
        }
    }
}

struct SessionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    static let height = SessionPanelLayout.rowHeight
    var session: AgentSession
    var now: Date
    var phase: SessionPhase
    @ObservedObject var swipePresentation: SessionSwipePresentation
    private var swipeOffset: Double { swipePresentation.id == session.id ? swipePresentation.offset : 0 }
    var onHide: () -> Void
    var onError: (String) -> Void
    var clientResolver = ClientExecutableResolver()
    var isPinned = false
    var onPin: (() -> Void)? = nil
    var onMove: ((Bool) -> Void)? = nil
    var canMoveUp = false
    var canMoveDown = false
    var onDragStart: ((NSImage, CGRect, CGPoint) -> Void)? = nil
    var onDragMove: ((CGPoint) -> Void)? = nil
    var onDragEnd: ((CGPoint?) -> Void)? = nil
    var isDragging = false
    var isFocused = false
    @StateObject private var dragAnchor = SessionRowDragAnchor()
    @StateObject private var menuAnchor = SessionMenuAnchor()
    @State private var opening = false
    @State private var hovering = false
    var displayTitle: String { session.displayTitle }
    var accessibilityName: String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [displayTitle, session.provider.title, session.project, title.isEmpty ? session.id : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var color: Color {
        switch phase {
        case .permission, .input: return .orange
        case .running: return .blue
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
    private func swipeAction(_ title: String, icon: InterfaceGlyph, width: Double) -> some View {
        ViewThatFits(in: .horizontal) {
            InterfaceLabel(title, icon, size: 13).fixedSize().padding(.horizontal, 8)
            InterfaceIcon(icon, size: 13)
        }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: width, height: 42)
            .clipped()
    }
    private var actionsMenu: some View {
        Button(action: showActions) {
            InterfaceIcon(.more).frame(width: 28, height: 30).contentShape(Rectangle())
        }
            .buttonStyle(.plain).help(L("Действия с сессией")).accessibilityLabel(L("Действия: {0}", accessibilityName))
            .accessibilityIdentifier("session-actions-" + session.id)
            .background(SessionMenuAnchorView(anchor: menuAnchor))
    }
    var reorderMenuItems: [SessionMenuAnchor.Item] {
        guard let onMove else { return [] }
        return [
            .init(title: L("Переместить выше"), enabled: canMoveUp && !isDragging,
                  keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!), keyModifiers: .option, action: { onMove(false) }),
            .init(title: L("Переместить ниже"), enabled: canMoveDown && !isDragging,
                  keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!), keyModifiers: .option, action: { onMove(true) })
        ]
    }
    var accessibilityReorderItems: [SessionMenuAnchor.Item] { reorderMenuItems.filter(\.enabled) }
    var menuItems: [SessionMenuAnchor.Item] {
        [
            .init(title: L("Открыть сессию"), enabled: !opening, action: openSession),
            session.client == .vscode ? .init(title: L("В VS Code должен быть открыт проект этой сессии."), enabled: false, action: {}) : nil,
            .separator,
            onPin.map { .init(title: L(isPinned ? "Открепить" : "Закрепить"), action: $0) },
        ].compactMap { $0 } + reorderMenuItems + [
            .init(title: L("Скрыть в Lunavect"), action: onHide),
            .separator,
            .init(title: L("Открыть папку проекта"), enabled: !session.cwd.isEmpty, action: {
                if !SessionNavigation.revealProject(session) { onError(L("Папка проекта недоступна.")) }
            }),
            .init(title: L("Копировать команду продолжения"), action: { SessionNavigation.copy(session.resumeCommand) }),
            .init(title: L("Копировать ID сессии"), action: { SessionNavigation.copy(session.sessionID) })
        ].compactMap { $0 }
    }
    private func showActions() { menuAnchor.show(menuItems) }
    private func openSession() {
        guard !opening else { return }; opening = true
        Task { @MainActor in
            defer { opening = false }
            do { try await SessionNavigation.open(session, resolver: clientResolver) }
            catch {
                onError(
                    (error as? SessionOpeningError)?.errorDescription
                        ?? L(
                            "Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…»."
                        ))
            }
        }
    }
    var statusTitle: String {
        guard phase == .running else { return phase.title }
        if session.compactionTrigger != nil { return session.activityTitle }
        return L(session.tool?.isEmpty == false ? "Работает" : "Думает")
    }
    private var providerImage: some View {
            ZStack(alignment: .bottomTrailing) {
                ProviderLogo(id: session.provider).scaleEffect(0.58).frame(width: 24, height: 24)
                    .foregroundStyle(session.provider == .claude ? Color.orange : Color.blue)
                if phase == .running && !reduceMotion {
                    ProgressView().controlSize(.mini).tint(color).frame(width: 12, height: 12).accessibilityHidden(true)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle()).offset(x: 3, y: 3)
                }
            }

    }
    private var rowText: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 4, height: 4)
                    Text(statusTitle).lineLimit(1)
                        .layoutPriority(1)
                    if phase == .running, let start = session.turnStartedAt {
                        let seconds = max(0, Int(now.timeIntervalSince(start)))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Text(session.shortProjectPath).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: 128, alignment: .trailing)
                        .help(session.cwd)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }

    }
    private var rowControls: some View {
            HStack(spacing: 2) {
                if isPinned { InterfaceIcon(.pin, size: 11).foregroundStyle(.blue).accessibilityLabel(L("Закреплена")) }
                actionsMenu
            }.foregroundStyle(.secondary)
    }
    private var rowSurface: some View {
            HStack(spacing: 8) {
                providerImage
                rowText
                rowControls
        }.padding(.horizontal, 8).frame(height: Self.height)
            .background(.primary.opacity(hovering ? 0.075 : 0.033), in: RoundedRectangle(cornerRadius: 11))
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isFocused ? Color.accentColor : .primary.opacity(contrast == .increased ? 0.45 : hovering ? 0.10 : 0.035), lineWidth: isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())

    }
    private var interactiveRow: some View {
        rowSurface
            .background(SessionRowDragAnchorView(anchor: dragAnchor))
            .help(displayTitle + "\n" + session.project + " · " + session.client.title + "\n" + session.activityTitle)
            .overlay(alignment: .leading) {
                SessionRowInteraction(session: session, anchor: dragAnchor, onClick: openSession, onMenu: showActions,
                                      onStart: { onDragStart?($0, $1, $2) }, onMove: { onDragMove?($0) }, onEnd: { onDragEnd?($0) })
                    // Keep the native ellipsis button independent of row clicks.
                    .padding(.trailing, 36).accessibilityHidden(true)
            }

    }
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                swipeAction(L("Открыть"), icon: .external, width: max(0, swipeOffset))
                Spacer(minLength: 0)
                swipeAction(L("Скрыть"), icon: .hidden, width: max(0, -swipeOffset))
            }.accessibilityHidden(true)
            interactiveRow
            .offset(x: swipeOffset)
        }
            .frame(height: Self.height)
            .background(swipeOffset > 0 ? Color.blue.opacity(0.25) : swipeOffset < 0 ? Color.orange.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .opacity(isDragging ? 0.2 : 1)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(statusTitle)
            .accessibilityAction(.default, openSession)
            .accessibilityIdentifier("session-row-" + session.id)
            .accessibilityAction(named: Text(L("Открыть сессию")), openSession)
            .accessibilityAction(named: Text(L("Скрыть в Lunavect")), onHide)
            .accessibilityActions {
                ForEach(accessibilityReorderItems.indices, id: \.self) { index in
                    if let action = accessibilityReorderItems[index].action {
                        Button(accessibilityReorderItems[index].title, action: action)
                    }
                }
            }
            .accessibilityHint(L("Нажмите, чтобы открыть сессию. Option и стрелки вверх или вниз меняют порядок. Правая кнопка или «…» — меню."))
    }
}


struct SessionPanelSectionHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SessionRowRegions: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct SessionScrollRegion: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        // Empty sibling defaults must not erase the ScrollView's measured bounds.
        if !next.isEmpty { value = next }
    }
}

@MainActor final class SessionSwipePresentation: ObservableObject {
    var id: String?
    @Published var offset = 0.0
    func update(id: String, offset: Double, reduceMotion: Bool? = nil) {
        guard self.id != id || self.offset != offset else { return }
        let reduceMotion = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let settles = offset == 0 && !reduceMotion
        var transaction = Transaction(animation: settles ? .interpolatingSpring(stiffness: 320, damping: 30) : nil)
        transaction.disablesAnimations = !settles
        withTransaction(transaction) { self.id = id; self.offset = offset }
    }
}

/// Pixel-by-pixel scrolling only invalidates this small control.
private struct SessionOverflowControl: View {
    @ObservedObject var scrollPosition: SessionScrollPosition
    let ids: [String]
    let layout: SessionPanelLayout
    let reordering: Bool
    let onPage: (String) -> Void
    var body: some View {
        let position = SessionOverflowPosition(ids: ids, layout: layout, offset: scrollPosition.offset)
        return Button {
            if let target = position.targetID { onPage(target) }
        } label: {
            HStack(spacing: 5) {
                Text(position.label).monospacedDigit()
                InterfaceIcon(.down, size: 10).rotationEffect(.degrees(position.pointsDown ? 0 : 180))
                    .accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: SessionPanelLayout.overflowHeight)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .frame(height: SessionPanelLayout.overflowHeight)
            .disabled(position.targetID == nil || reordering)
            .help(position.accessibilityLabel)
            .accessibilityLabel(position.accessibilityLabel)
            .accessibilityValue(position.label)
            .accessibilityIdentifier("session-overflow-control")
    }
}
