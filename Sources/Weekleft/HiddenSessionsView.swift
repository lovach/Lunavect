import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct HiddenSessionsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var sessions: [SessionVisibility.Summary]
    var onBack: () -> Void
    var onRestore: (String) -> Void
    var onRemove: (String) -> Void
    var onRemoveAll: () -> Void
    var onRestoreMany: (([String]) -> Void)? = nil
    @State var query = ""
    @FocusState private var focusedControl: HiddenSessionKeyboardFocus?
    @State private var confirmRemoval = false
    @State private var removalID: String?
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var showsSearch: Bool { sessions.count >= 6 || !query.isEmpty }
    var showsRestoreMany: Bool { sessions.count > 1 || hasQuery }
    func recoveredFocus(_ current: HiddenSessionKeyboardFocus?) -> HiddenSessionKeyboardFocus? {
        HiddenSessionKeyboardFocus.recover(current, visibleIDs: visibleSessions.map(\.id),
                                          showsSearch: showsSearch, showsRestoreMany: showsRestoreMany)
    }
    static func displayTitle(for row: SessionVisibility.Summary) -> String {
        let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.isEmpty else { return title }
        return row.provider.map { L($0 == .claude ? "Сессия Claude" : "Сессия Codex") } ?? L("Название недоступно")
    }
    static func accessibilityName(for row: SessionVisibility.Summary) -> String {
        let missingTitle = row.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return [displayTitle(for: row), row.provider?.title, row.project, missingTitle ? row.id : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func restoreLabel(for row: SessionVisibility.Summary) -> String { L("Вернуть: {0}", accessibilityName(for: row)) }
    static func removalLabel(for row: SessionVisibility.Summary) -> String { L("Удалить из Lunavect: {0}", accessibilityName(for: row)) }
    var visibleSessions: [SessionVisibility.Summary] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return sessions.filter { row in
            let text = [Self.displayTitle(for: row), row.project, row.provider?.title, row.id].compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }
    func restoreVisible() {
        let ids = visibleSessions.map(\.id)
        if let onRestoreMany { onRestoreMany(ids) }
        else { ids.forEach(onRestore) }
    }
    var body: some View {
        let visible = visibleSessions
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onBack) { InterfaceLabel(L("К сессиям"), .back) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
                    .focused($focusedControl, equals: .back).keyboardShortcut(.cancelAction)
                HStack {
                    Text(L("Скрытые сессии")).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(hasQuery ? L("{0} из {1}", String(visible.count), String(sessions.count)) : String(sessions.count))
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(L("Новая задача вернёт сессию в активные. Удаление очищает только список Lunavect."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if showsSearch {
                    HStack(spacing: 7) {
                        InterfaceIcon(.search).foregroundStyle(.secondary)
                        TextField(L("Найти сессию или проект"), text: $query).textFieldStyle(.plain)
                            .focused($focusedControl, equals: .search).accessibilityIdentifier("hidden-session-search")
                        if !query.isEmpty {
                            Button { query = "" } label: { InterfaceIcon(.close).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(L("Очистить поиск")).accessibilityLabel(L("Очистить поиск"))
                        }
                    }.font(.system(size: 11)).padding(7)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(14)
            Divider()
            if visible.isEmpty {
                VStack(spacing: 10) {
                    InterfaceIcon(hasQuery ? .search : .hidden, size: 24).foregroundStyle(.secondary)
                    Text(L(hasQuery ? "Ничего не найдено" : "Нет скрытых сессий")).font(.system(size: 12))
                    if hasQuery {
                        Button(L("Очистить поиск")) { query = "" }.buttonStyle(.plain).foregroundStyle(.blue).font(.system(size: 11))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visible) { row in
                            HStack(spacing: 9) {
                                if let provider = row.provider {
                                    ProviderLogo(id: provider).scaleEffect(0.55).frame(width: 22, height: 22)
                                        .foregroundStyle(provider == .claude ? Color.orange : Color.blue)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Self.displayTitle(for: row)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text([row.provider?.title, row.project].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { onRestore(row.id) } label: { InterfaceIcon(.restore).frame(width: 24, height: 28) }
                                    .buttonStyle(.plain).foregroundStyle(.blue).help(L("Вернуть"))
                                    .accessibilityLabel(Self.restoreLabel(for: row))
                                    .focused($focusedControl, equals: .restore(row.id))
                                Button { removalID = row.id; confirmRemoval = true } label: { InterfaceIcon(.trash).frame(width: 28, height: 30) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Удалить из Lunavect"))
                                    .accessibilityLabel(Self.removalLabel(for: row))
                                    .focused($focusedControl, equals: .remove(row.id))
                            }.padding(9).frame(minHeight: 58)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0)).allowsHitTesting(false))
                                .accessibilityElement(children: .contain)
                        }
                    }.padding(8)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if showsRestoreMany {
                    Button(action: restoreVisible) {
                        InterfaceLabel(L(hasQuery ? "Вернуть найденные" : "Вернуть все"), .restore)
                    }.disabled(visible.isEmpty).accessibilityIdentifier("hidden-session-restore-visible")
                        .focused($focusedControl, equals: .restoreMany)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(L("Удалить все скрытые из Lunavect"), role: .destructive) { removalID = nil; confirmRemoval = true }
                } label: { Text("…").font(.system(size: 16, weight: .semibold)) }
                    .fixedSize().disabled(sessions.isEmpty)
                    .help(L("Управление списком")).accessibilityLabel(L("Управление списком"))
            }.font(.system(size: 11)).padding(10)
        }.background(Color(nsColor: .windowBackgroundColor))
            .background {
                if showsSearch {
                    Button("") { focusedControl = .search }.keyboardShortcut("f", modifiers: .command)
                        .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
                }
            }
            .onChange(of: visible.map(\.id)) { _, _ in
                focusedControl = recoveredFocus(focusedControl)
            }
            .onChange(of: focusedControl) { old, current in
                guard current == nil, let old else { return }
                let recovered = recoveredFocus(old)
                if recovered != old { focusedControl = recovered }
            }
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .alert(L(removalID == nil ? "Удалить все скрытые из Lunavect?" : "Удалить запись из Lunavect?"), isPresented: $confirmRemoval) {
                Button(L("Отмена"), role: .cancel) {}
                Button(L("Удалить"), role: .destructive) {
                    if let removalID { onRemove(removalID) } else { onRemoveAll() }
                }
            } message: { Text(L("Будет очищен только список Lunavect. Чаты и работа агентов останутся у провайдеров. Это действие нельзя отменить.")) }
    }
}
