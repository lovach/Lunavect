import SwiftUI
import WidgetKit
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor struct WelcomeView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var sessions: SessionStore
    var onFinish: () -> Void
    @State var step = 0
    @State private var provider: ProviderID?
    @State private var exampleHidden = false
    @State private var exampleOpened = false
    @StateObject var widgetSetup = WidgetSetupStatus()
    private let titles = ["Добро пожаловать в Lunavect", "Подключите приложения", "Добавьте виджет на рабочий стол", "Сессии под рукой"]
    private var visibleSteps: [Int] { widgetSetup.hasWidgets && step != 2 ? [0, 1, 3] : [0, 1, 2, 3] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let mark = AppArtwork.brandMark { Image(nsImage: mark).resizable().scaledToFit().frame(width: 46, height: 46) }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Lunavect").font(.system(size: 23, weight: .semibold))
                    Text(L("Шаг {0} из {1}", String((visibleSteps.firstIndex(of: step) ?? 0) + 1), String(visibleSteps.count))).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(visibleSteps, id: \.self) { index in Capsule().fill(index <= step ? Color.accentColor : .secondary.opacity(0.25)).frame(width: 24, height: 4) }
            }.padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L(titles[step])).font(.system(size: 24, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    page
                }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }
            Divider()
            HStack {
                Button(L("Пропустить обучение"), action: onFinish).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button(L("Назад")) { step = step == 3 && widgetSetup.hasWidgets ? 1 : step - 1 } }
                Button(L(step == 3 ? "Открыть сессии" : "Далее")) { if step == 3 { onFinish() } else { step = widgetSetup.nextStep(after: step) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(24)
        }.frame(width: 640, height: 620).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $provider) { ConnectionSetupView(provider: $0, store: store, sessions: sessions) }
            .task { await widgetSetup.check() }
    }
    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            Text(L("Лимиты Claude и Codex на рабочем столе, текущие сессии — в строке меню. Настроим всё за несколько шагов."))
                .font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                feature(.widget, "Лимиты и активность")
                feature(.sessions, "Быстрый доступ к сессиям")
            }
            ConnectionPrivacyView()
            Text(L("Обучение можно пропустить и открыть снова в настройках."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case 1:
            Text(L("Можно подключить одно приложение или оба. Если клиент уже установлен, повторная установка не понадобится."))
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            ForEach(ProviderID.allCases) { id in
                HStack(spacing: 14) {
                    ProviderLogo(id: id).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(id.title).font(.headline)
                        Text(L(store.providers.contains(id) ? (store.snapshots.first { $0.provider == id }?.connectionQuotaTitle() ?? "Ждём лимиты") : "Не подключён · по желанию"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L(store.providers.contains(id) ? "Настроить" : "Подключить {0}", id.title)) { provider = id }
                        .buttonStyle(.borderedProminent)
                }.padding(18).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(L("Вход открывается в официальном клиенте. Lunavect не просит пароль и не читает хранилище токенов."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case 2:
            WidgetSetupGuide(status: widgetSetup)
            Text(L("Оставляйте Lunavect запущенным в строке меню для обновления данных. macOS сама выбирает момент обновления виджета."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default:
            if exampleHidden {
                HStack {
                    Text(L("Сессия скрыта"))
                    Spacer()
                    Button(L("Отменить")) { exampleHidden = false }
                }.padding(18)
            } else {
            HStack(spacing: 12) {
                InterfaceIcon(.sessions, size: 26).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Пример сессии")).font(.system(size: 14, weight: .semibold))
                    Text(L("Ответ готов")).font(.system(size: 12)).foregroundStyle(.green)
                }
                Spacer()
                Menu {
                    Button(L("Открыть сессию")) { exampleOpened = true }
                    Button(L("Убрать из Lunavect")) { exampleHidden = true }
                } label: { InterfaceIcon(.more) }.menuStyle(.borderlessButton).frame(width: 24)
            }.padding(18).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle()).onTapGesture { exampleOpened = true }
            }
            if exampleOpened {
                Text(L("Это учебный пример. В панели нажатие на строку откроет сессию в её приложении."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            instruction(1, "Нажмите на строку, чтобы открыть сессию. Свайп вправо делает то же самое, влево — скрывает её только в Lunavect.")
            instruction(2, "Перетаскивайте строку вверх или вниз, чтобы изменить порядок. Правая кнопка или «…» открывают меню сессии.")
            instruction(3, "Скрытые сессии доступны внизу панели и возвращаются автоматически при новой задаче.")
            Text(L("Если данные не обновляются: Настройки → Подключения → Проверить подключение."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func feature(_ glyph: InterfaceGlyph, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            InterfaceIcon(glyph, size: 28).foregroundStyle(.blue)
            Text(L(title)).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private func instruction(_ number: Int, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number)).font(.system(size: 12, weight: .semibold)).frame(width: 25, height: 25).background(.blue.opacity(0.15), in: Circle()).foregroundStyle(.blue)
            Text(L(key)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor final class WidgetSetupStatus: ObservableObject {
    enum State { case checking, missing, registered, unavailable }
    @Published private(set) var state: State = .checking
    var hasWidgets: Bool { state == .registered }
    private let fetch: () async throws -> [String]
    private var checking = false
    init(fetch: (() async throws -> [String])? = nil) {
        self.fetch = fetch ?? {
            try await withCheckedThrowingContinuation { continuation in
                WidgetCenter.shared.getCurrentConfigurations { result in
                    continuation.resume(with: result.map { $0.map(\.kind) })
                }
            }
        }
    }
    func check() async {
        guard !checking else { return }; checking = true; defer { checking = false }
        do {
            let kinds = try await fetch()
            guard !Task.isCancelled else { return }
            let supported = Set(["WeekleftWidget", "LunavectActivityWidget", "LunavectOverviewWidget"])
            state = kinds.contains(where: supported.contains) ? .registered : .missing
        } catch { if !Task.isCancelled { state = .unavailable } }
    }
    // Registration does not prove desktop placement or completion of an add action.
    func nextStep(after step: Int) -> Int { min(3, step + 1) }
}

@MainActor struct WidgetSetupGuide: View {
    @ObservedObject var status: WidgetSetupStatus
    var body: some View {
        WidgetGalleryControls()
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("widget-setup-status")
            .task { await status.check() }
    }
}
