import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
import AwakeService
#endif

/// First-launch profile. Upgrades never reapply it over existing preferences.
enum AppDefaultSettings {
    static let versionKey = "settingsDefaultsVersion"
    static let appearance = InterfaceAppearance.system
    static let icon = MenuBarIcon.lunavect
    static let awakeDuration = AwakeDuration.fifteenMinutes
    static let awakeIdleGrace = 60
    static let soundCooldown = 5
    static var values: [String: Any] {
        ["interfaceAppearance": appearance.rawValue, "menuBarShowsSessionStatus": true,
         "menuBarIcon": icon.rawValue, "menuBarAutomaticIcon": false,
         "menuBarThinkingPhrases": false, "menuBarStatusStyle": MenuBarStatusStyle.summary.rawValue,
         "menuBarAnimationOnlyWhileWorking": true, "menuBarSystemColor": false,
         "menuBarLimits": try! JSONEncoder().encode(MenuBarLimitsPreferences()),
         "noticeBanners": false, "noticeSounds": false, "noticeCompletion": true,
         "noticePermission": true, "noticeInput": true, "noticeCompletionCooldown": soundCooldown,
         "sessionAutoHideMinutes": 0, "awake.whileWorking": false,
         "awake.duration": awakeDuration.rawValue, "awake.idleGraceSeconds": awakeIdleGrace,
         "awake.safety": try! JSONEncoder().encode(AwakeSafetyPolicy()),
         "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": false]
    }
    static func prepare(defaults: UserDefaults, existingInstallation: Bool) {
        guard defaults.object(forKey: versionKey) == nil else { return }
        if existingInstallation {
            // Earlier builds did not persist the selected duration.
            if defaults.object(forKey: "awake.duration") == nil {
                defaults.set(AwakeDuration.untilStopped.rawValue, forKey: "awake.duration")
            }
        } else {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(1, forKey: versionKey)
    }
}

struct BaseSettingsView: View {
    var canRestore = true
    var restore: () async -> Void
    @State private var confirming = false
    @State private var restoring = false
    var body: some View {
        GroupBox(L("Базовые настройки")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("При первом запуске: системная тема, значок Lunavect и статус сессий. Звук, баннеры, автозапуск, Keep Awake и лимиты в строке меню включаются отдельно."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Восстановить базовые настройки")) { confirming = true }
                    .disabled(restoring || !canRestore).accessibilityIdentifier("restore-base-settings")
            }.padding(InterfaceMetrics.settingsContentInset).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(L("Восстановить базовые настройки?"), isPresented: $confirming) {
            Button(L("Восстановить")) {
                restoring = true
                Task { await restore(); restoring = false }
            }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(
                L(
                    "Язык и тема станут системными. Сбросятся оформление строки меню и виджетов, уведомления и звук, сочетание клавиш, автозапуск, автоскрытие сессий и настройки обновлений. Keep Awake выключится, его параметры и ожидание разрешения сбросятся. Подключения, история, скрытые сессии, их порядок и даты подписок сохранятся."
                ))
        }
    }
}

struct KeepAwakeSettingsView: View {
    @ObservedObject var awake: KeepAwake
    var idleGrace: Binding<Int> {
        Binding(get: { awake.idleGraceSeconds }, set: { awake.setIdleGrace($0) })
    }
    private func policyBinding<Value>(_ key: WritableKeyPath<AwakeSafetyPolicy, Value>) -> Binding<Value> {
        Binding(get: { awake.safetyPolicy[keyPath: key] }, set: { value in
            var policy = awake.safetyPolicy; policy[keyPath: key] = value
            Task { await awake.setSafetyPolicy(policy) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceMetrics.settingsSectionSpacing) {
            KeepAwakeControls(awake: awake, showsModeControls: false, permissionOrigin: .settings)
            GroupBox(L("Поведение")) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(get: { awake.automatic }, set: { value in
                        Task { await awake.setAutomatic(value) }
                    })) { settingLabel(L("Автоматически, пока работают сессии")) }
                        .toggleStyle(.switch).accessibilityIdentifier("awake-automatic")
                    Divider()
                    SettingsRow(L("Длительность ручного режима")) {
                    Picker(L("Длительность ручного режима"), selection: $awake.duration) {
                        ForEach(AwakeDuration.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }.labelsHidden().accessibilityIdentifier("awake-default-duration")
                    }
                    Text(L("Применяется при следующем включении ручного режима."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    SettingsRow(L("После завершения сессий")) {
                    Picker(L("После завершения сессий"), selection: idleGrace) {
                        Text(L("Сразу")).tag(0)
                        Text(L("Через 30 секунд")).tag(30)
                        Text(L("Через 1 минуту")).tag(60)
                        Text(L("Через 2 минуты")).tag(120)
                        Text(L("Через 5 минут")).tag(300)
                    }.labelsHidden().accessibilityIdentifier("awake-idle-grace")
                    }
                    Text(L("Задержка автоматического режима. Новая работа отменяет отсчёт."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(InterfaceMetrics.settingsContentInset)
            }
            GroupBox(L("Условия остановки")) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: policyBinding(\.allowBattery)) { settingLabel(L("Разрешать работу от аккумулятора")) }
                        .accessibilityIdentifier("awake-allow-battery")
                    Divider()
                    Toggle(isOn: policyBinding(\.batteryProtection)) { settingLabel(L("Останавливать при низком заряде")) }
                        .accessibilityIdentifier("awake-battery-protection")
                    SettingsRow(L("Порог заряда")) {
                    Picker(L("Порог заряда"), selection: policyBinding(\.minimumBatteryPercent)) {
                        ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }.labelsHidden().disabled(!awake.safetyPolicy.batteryProtection)
                        .accessibilityIdentifier("awake-battery-threshold")
                    }
                    Divider()
                    Toggle(isOn: policyBinding(\.thermalProtection)) { settingLabel(L("Останавливать при перегреве")) }
                        .accessibilityIdentifier("awake-thermal-protection")
                    Text(L("Эти условия управляют только Keep Awake. Системные защиты macOS не изменяются."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !awake.safetyPolicy.thermalProtection || !awake.safetyPolicy.batteryProtection {
                        Text(L("Отключённые условия не остановят Keep Awake при нагреве или разряде. Не убирайте работающий Mac в сумку."))
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch).padding(12)
            }
            Text(L("При потере связи помощник снимает блокировку сна; при сбое повторяет попытку."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(awake.isBusy)
    }
    private func settingLabel(_ title: String) -> some View {
        Text(title).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
