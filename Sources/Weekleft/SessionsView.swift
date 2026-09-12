import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct SessionsView: View {
    @ObservedObject var store: SessionStore
    var panelState = SessionPanelState(isVisible: true)
    @ObservedObject var updates = AppUpdates.shared
    var awake: KeepAwake = .shared
    var isPreview = false
    var onSettings: () -> Void
    var onConnections: (() -> Void)? = nil
    var onMenuBarSettings: (() -> Void)? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil
    var onReorderingChange: ((Bool) -> Void)? = nil
    @StateObject private var reorder = SessionReorderState()
    @State private var rowRegions: [String: CGRect] = [:]
    @State private var scrollRegion = CGRect.zero
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
        return store.arrangement.arranged(SessionList.filter(store.sessions, query: query, provider: ProviderID(rawValue: provider), activeOnly: activeOnly, now: now)).filter { !attentionOnly || [.permission, .input].contains($0.effectivePhase(now: now)) }
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
        }
            .onChange(of: store.providers) { _, values in
                if values.count < 2 || !values.contains(where: { $0.rawValue == provider }) { provider = "" }
            }
    }
    private var hasFilters: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !provider.isEmpty || activeOnly || attentionOnly }
    private func panelHeight(at now: Date) -> CGFloat {
        if showingHidden { return min(480, max(300, CGFloat(store.hiddenCount) * 62 + 180)) }
        let count = visible(at: now).count
        // Measure the actual controls, including wrapped errors and expanded settings.
        // A minimum panel height would otherwise leave more than one empty row.
        let chrome = (sectionHeights["top"] ?? 142) + (sectionHeights["bottom"] ?? 30)
        let content = count == 0 ? 180 : CGFloat(count) * SessionRow.height + CGFloat(count - 1) * 2 + 8
        return min(480, chrome + content + SessionRow.height)
    }
    private var hiddenList: some View {
        HiddenSessionsView(sessions: store.hiddenSessions,
                           onBack: { showingHidden = false },
                           onRestore: { id in perform { try store.restore(id) } },
                           onRemove: { id in perform { try store.removeHidden(id) } },
                           onRemoveAll: { perform { try store.removeHidden() } })
    }
    private func sessionList(at now: Date) -> some View {
        let rows = visible(at: now)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
            header(at: now).padding(.horizontal, 12).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            if updates.notice != nil { UpdateNoticeView(updates: updates).padding(.horizontal, 12).padding(.bottom, 8) }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    InterfaceIcon(.search).foregroundStyle(.secondary)
                    TextField(L("Найти сессию или проект"), text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("session-search")
                        .focused($focusedSession, equals: "search-field")
                        .onKeyPress(.downArrow) { focusedSession = rows.first?.id; return .handled }
                    if !query.isEmpty {
                        Button { query = "" } label: { InterfaceIcon(.close) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Очистить поиск")).accessibilityLabel(L("Очистить поиск"))
                    }
                }.padding(7).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 14) {
                    if store.providers.count > 1 {
                        Picker(L("Приложение"), selection: $provider) {
                        Text(L("Все")).tag("")
                        ForEach(store.providers) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("session-provider-filter")
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
                        let total = store.sessions.filter { $0.isCurrent(now: now) }.count
                        Text(L("Показано {0} из {1}", String(rows.count), String(total)))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Сбросить фильтры")) { query = ""; provider = ""; activeOnly = false; attentionOnly = false }
                            .buttonStyle(.plain).foregroundStyle(.blue)
                    }.font(.system(size: 10)).padding(.top, 3)
                }
            }.padding(.horizontal, 12).padding(.bottom, 7).disabled(reorder.rows != nil)
            Divider().opacity(0.45)
            }.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SessionPanelSectionHeights.self, value: ["top": geometry.size.height])
                })
            if rows.isEmpty {
                // Only the centre may scroll when translated copy or diagnostics
                // needs more room. Never push the panel controls outside its bounds.
                ScrollView { emptyState.frame(maxWidth: .infinity) }
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { row in
                            SessionRow(session: row, now: now, phase: row.effectivePhase(now: now), swipePresentation: swipePresentation, onHide: { perform { try store.hide(row) } }, onError: { actionIssue = $0 }, isPinned: store.arrangement.pinned.contains(row.id),
                                       onPin: { perform { try store.setPinned(row.id, !store.arrangement.pinned.contains(row.id)) } },
                                       onDragStart: { image, windowFrame, grab in
                                           guard let frame = rowRegions[row.id] else { return }
                                           onReorderingChange?(true)
                                           reorder.begin(row.id, rows: rows, pinned: store.arrangement.pinned)
                                           reorder.lift(image, frame: frame, windowFrame: windowFrame, grab: grab)
                                       },
                                       onDragMove: { reorder.update(windowPoint: $0, regions: rowRegions, viewport: scrollRegion) },
                                       onDragEnd: { point in
                                           if let point {
                                               reorder.update(windowPoint: point, regions: rowRegions, viewport: scrollRegion)
                                               if let id = reorder.id, let target = reorder.target {
                                                   perform { try store.move(id, before: target, after: reorder.insertAfter, visible: rows.map(\.id)) }
                                               }
                                           }
                                           reorder.end(); onReorderingChange?(false)
                                       },
                                       isDragging: reorder.id == row.id, isFocused: focusedSession == row.id)
                                .focusable().focused($focusedSession, equals: row.id)
                                .focusEffectDisabled()
                                .onKeyPress(.return) { open(row); return .handled }
                                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
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
                                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: SessionRowRegions.self, value: [row.id: geometry.frame(in: .named("session-panel"))])
                                })
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }.background(GeometryReader { geometry in
                    Color.clear.preference(key: SessionScrollRegion.self, value: geometry.frame(in: .named("session-panel")))
                })
                .onChange(of: focusedSession) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            // Keep one empty card's space visible even when the list scrolls.
            Color.clear.frame(height: SessionRow.height).contentShape(Rectangle())
                .onTapGesture { focusedSession = nil }.accessibilityHidden(true)
            VStack(spacing: 0) {
            Divider().opacity(0.45)
            footer.padding(.horizontal, 12).padding(.vertical, 7).fixedSize(horizontal: false, vertical: true)
            }.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SessionPanelSectionHeights.self, value: ["bottom": geometry.size.height])
                })
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
        .onPreferenceChange(SessionRowRegions.self) { rowRegions = $0 }
        .onPreferenceChange(SessionScrollRegion.self) { scrollRegion = $0 }
        .onPreferenceChange(SessionPanelSectionHeights.self) { sectionHeights = $0 }
        .background(SessionSwipeView(regions: rowRegions, viewport: scrollRegion, enabled: reorder.rows == nil, onOffset: { id, offset in
            swipePresentation.update(id: id, offset: offset)
        }, onAction: { id, action in
            guard let row = store.sessions.first(where: { $0.id == id }) else { return }
            if action == .hide { perform { try store.hide(row) } }
            else {
                Task { @MainActor in
                    do { try await SessionNavigation.open(row) }
                    catch { actionIssue = (error as? SessionOpeningError)?.errorDescription ?? L("Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…».") }
                }
            }
        }))
        .background {
            Color(nsColor: .windowBackgroundColor).opacity(0.94)
                .contentShape(Rectangle()).onTapGesture { focusedSession = nil }
        }
        .onKeyPress(.escape) {
            guard focusedSession != nil else { return .ignored }
            focusedSession = nil; return .handled
        }
        .alert(L("Не удалось выполнить действие"), isPresented: Binding(get: { actionIssue != nil }, set: { if !$0 { actionIssue = nil } })) {
            Button(L("Понятно")) { actionIssue = nil }
        } message: { Text(L(actionIssue ?? "")) }
    }
    private func header(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let mark = AppArtwork.brandMark { Image(nsImage: mark).resizable().renderingMode(.original).scaledToFit().frame(width: 36, height: 36).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lunavect").font(.system(size: 16, weight: .semibold))
                    Text(isPreview ? L("Проверка · тестовые сессии") : L("Текущие сессии")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                KeepAwakeButton(awake: awake, isExpanded: showingAwake) { showingAwake.toggle() }.disabled(isPreview)
                    .popover(isPresented: $showingAwake) { KeepAwakeControls(awake: awake).padding(10).frame(width: 330) }
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
                metric(store.sessions.filter { $0.effectivePhase(now: now) == .running }.count, L("в работе"), .blue)
                Button { attentionOnly.toggle() } label: {
                    metric(store.sessions.filter { [.permission, .input].contains($0.effectivePhase(now: now)) }.count, L("в ожидании"), .orange)
                        .padding(.vertical, 3).padding(.horizontal, 5)
                        .background(attentionOnly ? Color.orange.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(L("Показать сессии, которым нужен ответ или разрешение"))
                    .accessibilityLabel(L("Только ожидание"))
                    .accessibilityValue(L(attentionOnly ? "Включено" : "Выключено"))
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
            Text(hasFilters ? L("Нет сессий для выбранных фильтров. Сбросьте фильтры, чтобы увидеть остальные сессии.") : L("Приложения ещё не передали живой статус."))
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !loading && !hasFilters && store.providers.isEmpty {
                Button(L("Подключить приложения"), action: onConnections ?? onSettings)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.blue)
            }
        }.padding(24)
    }
    private func open(_ row: AgentSession) {
        Task { @MainActor in
            do { try await SessionNavigation.open(row) }
            catch { actionIssue = (error as? SessionOpeningError)?.errorDescription ?? L("Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…».") }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { try action() }
            else { try withAnimation(.easeOut(duration: 0.2), action) }
        } catch { actionIssue = L("Не удалось сохранить изменение. Попробуйте ещё раз.") }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let hidden = store.lastHidden {
                HStack {
                    Text(L("Убрано: {0}", hidden.title)).lineLimit(1)
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
    static let height: CGFloat = 42
    var session: AgentSession
    var now: Date
    var phase: SessionPhase
    @ObservedObject var swipePresentation: SessionSwipePresentation
    private var swipeOffset: Double { swipePresentation.id == session.id ? swipePresentation.offset : 0 }
    var onHide: () -> Void
    var onError: (String) -> Void
    var isPinned = false
    var onPin: (() -> Void)? = nil
    var onDragStart: ((NSImage, CGRect, CGPoint) -> Void)? = nil
    var onDragMove: ((CGPoint) -> Void)? = nil
    var onDragEnd: ((CGPoint?) -> Void)? = nil
    var isDragging = false
    var isFocused = false
    @StateObject private var dragAnchor = SessionRowDragAnchor()
    @StateObject private var menuAnchor = SessionMenuAnchor()
    @State private var opening = false
    @State private var hovering = false
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
            .buttonStyle(.plain).help(L("Действия с сессией")).accessibilityLabel(L("Действия с сессией"))
            .accessibilityIdentifier("session-actions-" + session.id)
            .background(SessionMenuAnchorView(anchor: menuAnchor))
    }
    private var menuItems: [SessionMenuAnchor.Item] {
        [
            .init(title: L("Открыть сессию"), enabled: !opening, action: openSession),
            session.client == .vscode ? .init(title: L("В VS Code должен быть открыт проект этой сессии."), enabled: false, action: {}) : nil,
            .separator,
            onPin.map { .init(title: L(isPinned ? "Открепить" : "Закрепить"), action: $0) },
            .init(title: L("Убрать из Lunavect"), action: onHide),
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
            do { try await SessionNavigation.open(session) }
            catch { onError((error as? SessionOpeningError)?.errorDescription ?? L("Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…».")) }
        }
    }
    var statusTitle: String {
        guard phase == .running else { return phase.title }
        return L(session.tool?.isEmpty == false ? "Работает" : "Думает")
    }
    private var providerImage: some View {
            ZStack(alignment: .bottomTrailing) {
                ProviderLogo(id: session.provider).scaleEffect(0.58).frame(width: 24, height: 24)
                    .foregroundStyle(session.provider == .claude ? Color.orange : Color.blue)
                if phase == .running {
                    ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 10, height: 10)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle()).offset(x: 3, y: 3)
                }
            }

    }
    private var rowText: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
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
                    .strokeBorder(isFocused ? Color.accentColor : .primary.opacity(hovering ? 0.10 : 0.035), lineWidth: isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())

    }
    private var interactiveRow: some View {
        rowSurface
            .background(SessionRowDragAnchorView(anchor: dragAnchor))
            .help(session.project + " · " + session.client.title + "\n" + session.activityTitle)
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
                swipeAction(L("Убрать"), icon: .hidden, width: max(0, -swipeOffset))
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
            .accessibilityAction(.default, openSession)
            .accessibilityIdentifier("session-row-" + session.id)
            .accessibilityAction(named: Text(L("Открыть сессию")), openSession)
            .accessibilityAction(named: Text(L("Убрать из Lunavect")), onHide)
            .accessibilityHint(L("Нажмите, чтобы открыть сессию. Перетащите строку, чтобы изменить порядок. Правая кнопка или «…» — меню."))
    }
}


struct SessionPanelSectionHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SessionRowRegions: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct SessionScrollRegion: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        // Empty sibling defaults must not erase the ScrollView's measured bounds.
        if !next.isEmpty { value = next }
    }
}

@MainActor final class SessionSwipePresentation: ObservableObject {
    var id: String?
    @Published var offset = 0.0
    func update(id: String, offset: Double) {
        guard self.id != id || self.offset != offset else { return }
        if offset == 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.interpolatingSpring(stiffness: 320, damping: 30)) {
                self.id = id; self.offset = 0
            }
        } else {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { self.id = id; self.offset = offset }
        }
    }
}
