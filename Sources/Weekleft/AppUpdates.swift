import SwiftUI
import Sparkle
import Combine
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdates()
    enum Phase: Equatable { case unavailable, idle, checking, downloading(String), ready(String), available(String), failed }
    @Published var phase: Phase = .unavailable
    @Published var automatic = true
    @Published var canCheck = false
    @Published var lastCheck: Date?
    private var controller: SPUStandardUpdaterController?
    private var observations: [AnyCancellable] = []
    var notice: String? {
        switch phase {
        case .downloading(let version): return L("Скачивается версия {0}", version)
        case .ready(let version): return L("Версия {0} готова к установке", version)
        case .available(let version): return L("Доступна версия {0}", version)
        default: return nil
        }
    }
    var configured: Bool { controller != nil }
    func start(bundle: Bundle = .main) {
        guard controller == nil,
              ReleaseConfiguration(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                   publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        // The updater validates keys, signed feeds and signatures itself. Never
        // start a network check in an unconfigured development build.
        do { try controller.updater.start() } catch { self.controller = nil; phase = .failed; return }
        phase = .idle
        automatic = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).sink { [weak self] in self?.lastCheck = $0 }.store(in: &observations)
    }
    func setAutomatic(_ value: Bool) {
        automatic = value
        controller?.updater.automaticallyChecksForUpdates = value
        controller?.updater.automaticallyDownloadsUpdates = value
    }
    func check() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        if notice == nil { phase = .checking }
        controller.checkForUpdates(nil)
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        phase = state.stage == .notDownloaded ? .available(update.displayVersionString) : .ready(update.displayVersionString)
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { phase = .idle }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { phase = .available(item.displayVersionString) }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) { phase = .downloading(item.displayVersionString) }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        phase = .ready(item.displayVersionString)
        // Normal scheduling remains active; Sparkle installs on ordinary quit.
        // Never invoke the immediate handler or interrupt work automatically.
        return false
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            let error = error as NSError
            phase = error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue ? .idle : .failed
        } else if phase == .checking { phase = .idle }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdates = .shared
    var body: some View {
        GroupBox(L("Обновления")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("Автоматически скачивать новые версии"), isOn: Binding(get: { updates.automatic }, set: updates.setAutomatic))
                    .disabled(!updates.configured)
                Text(L("Lunavect проверяет GitHub каждый час, пока приложение открыто, и скачивает подписанные обновления. О новой версии сообщат отметка в строке меню и карточка в панели сессий. Установка — при выходе или по кнопке."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let notice = updates.notice { InterfaceLabel(notice, .refresh).foregroundStyle(.blue) }
                if !updates.configured {
                    Text(L("Обновления появятся после подключения GitHub-релизов. Эта локальная сборка не проверяет и не скачивает обновления."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if updates.phase == .failed {
                    Text(L("Не удалось проверить или скачать обновление. Повторите попытку позже.")).foregroundStyle(.orange).font(.system(size: 12))
                } else if updates.phase == .checking {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Button(L(updates.notice == nil ? "Проверить обновления" : "Открыть обновление")) { updates.check() }.disabled(!updates.canCheck)
                    if let date = updates.lastCheck { Text(L("Проверено {0}", date.formatted(date: .abbreviated, time: .shortened))).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(L("GitHub получает обычный сетевой запрос. Статистика использования и данные сессий не отправляются."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        }
    }
}

struct UpdateNoticeView: View {
    @ObservedObject var updates: AppUpdates = .shared
    var body: some View {
        if let notice = updates.notice {
            Button { updates.check() } label: {
                HStack(spacing: 8) {
                    InterfaceIcon(.refresh)
                    Text(notice).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if updates.canCheck { InterfaceIcon(.forward, size: 12) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(!updates.canCheck)
        }
    }
}
