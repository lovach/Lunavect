import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct HiddenSessionsView: View {
    var sessions: [SessionVisibility.Summary]
    var onBack: () -> Void
    var onRestore: (String) -> Void
    var onRemove: (String) -> Void
    var onRemoveAll: () -> Void
    @State private var confirmRemoval = false
    @State private var removalID: String?
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onBack) { InterfaceLabel(L("К сессиям"), .back) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
                HStack {
                    Text(L("Скрытые сессии")).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(String(sessions.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(L("Новая задача вернёт сессию в активные. Удаление очищает только список Lunavect."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
            Divider()
            if sessions.isEmpty {
                VStack(spacing: 10) {
                    InterfaceIcon(.hidden, size: 24).foregroundStyle(.secondary)
                    Text(L("Нет скрытых сессий")).font(.system(size: 12))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sessions) { row in
                            HStack(spacing: 9) {
                                if let provider = row.provider {
                                    ProviderLogo(id: provider).scaleEffect(0.55).frame(width: 22, height: 22)
                                        .foregroundStyle(provider == .claude ? Color.orange : Color.blue)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title ?? L("Название недоступно")).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text([row.provider?.title, row.project].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { onRestore(row.id) } label: { InterfaceIcon(.restore).frame(width: 24, height: 28) }
                                    .buttonStyle(.plain).foregroundStyle(.blue).help(L("Вернуть")).accessibilityLabel(L("Вернуть"))
                                Button { removalID = row.id; confirmRemoval = true } label: { InterfaceIcon(.trash).frame(width: 28, height: 30) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Удалить из Lunavect")).accessibilityLabel(L("Удалить из Lunavect"))
                            }.padding(9).frame(minHeight: 58)
                                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(8)
                }
            }
            Divider()
            Menu {
                Button(L("Удалить все скрытые из Lunavect"), role: .destructive) { removalID = nil; confirmRemoval = true }
            } label: { InterfaceLabel(L("Управление списком"), .more) }
                .disabled(sessions.isEmpty).padding(10)
        }.background(Color(nsColor: .windowBackgroundColor))
            .alert(L(removalID == nil ? "Удалить все скрытые из Lunavect?" : "Удалить запись из Lunavect?"), isPresented: $confirmRemoval) {
                Button(L("Отмена"), role: .cancel) {}
                Button(L("Удалить"), role: .destructive) {
                    if let removalID { onRemove(removalID) } else { onRemoveAll() }
                }
            } message: { Text(L("Будет очищен только список Lunavect. Чаты и работа агентов останутся у провайдеров. Это действие нельзя отменить.")) }
    }
}
