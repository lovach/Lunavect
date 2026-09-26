import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

private struct UsageAnalyticsKey: EnvironmentKey {
    static let defaultValue: UsageAnalytics? = nil
}
extension EnvironmentValues {
    var usageAnalytics: UsageAnalytics? {
        get { self[UsageAnalyticsKey.self] }
        set { self[UsageAnalyticsKey.self] = newValue }
    }
}

struct UsageAnalyticsView: View {
    @ObservedObject var analytics: UsageAnalytics
    var invitation = false
    var body: some View {
        if analytics.configured && (!invitation || !analytics.hasDecision) {
            GroupBox(L("Помочь улучшить Lunavect")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Число запусков, версия Lunavect и macOS, тип клиента и результат перехода к сессии. Без постоянного ID, содержимого сессий, названий проектов и путей."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("Обработчик — PostHog EU. Можно отключить в любой момент; приложение работает и без статистики."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if invitation {
                        HStack {
                            Button(L("Нет, спасибо")) { analytics.setEnabled(false) }
                            Button(L("Разрешить статистику")) { analytics.setEnabled(true) }
                        }.buttonStyle(.bordered)
                    } else {
                        Toggle(L("Отправлять техническую статистику"), isOn: Binding(
                            get: { analytics.enabled }, set: { analytics.setEnabled($0) }))
                            .accessibilityIdentifier("usage-analytics-consent")
                    }
                    Link(L("Какие данные отправляются"), destination: URL(string: "https://lovach.github.io/Lunavect/privacy.html#optional-usage-statistics")!)
                        .font(.system(size: 12))
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
