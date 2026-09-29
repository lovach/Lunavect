import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

extension AgentTask {
    var stateTitle: String {
        switch state {
        case .queued: return L("В очереди")
        case .running: return L("Работает")
        case .wrappingUp: return L("Сворачивает работу")
        case .paused:
            switch pause {
            case .budget: return L("Пауза: бюджет недели")
            case .fiveHour: return L("Пауза: окно 5 часов")
            case .limitReached: return L("Пауза: лимит исчерпан")
            default: return L("Пауза")
            }
        case .done: return L("Готово")
        case .failed: return L("Ошибка")
        case .needsYou: return L("Нужно ваше участие")
        case .cancelled: return L("Отменена")
        }
    }
    var stateColor: Color {
        switch state {
        case .running: return .blue
        case .wrappingUp, .paused, .queued: return .orange
        case .done: return .green
        case .failed, .needsYou: return .red
        case .cancelled: return .secondary
        }
    }
}

/// The Tasks tab of the sessions panel.
struct TaskListView: View {
    @ObservedObject var tasks: TaskService
    var onNew: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Задачи с бюджетом")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onNew) { Label(L("Новая задача"), systemImage: "plus") }.controlSize(.small)
                    .accessibilityIdentifier("tasks-new")
            }
            if let issue = tasks.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if tasks.tasks.isEmpty {
                Text(L("Задача работает без окна в пределах доли недельного лимита. Когда бюджет заканчивается, агент сворачивает работу, всё сохраняется, а после сброса лимита задача продолжается."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tasks.tasks) { task in TaskCard(task: task, tasks: tasks) }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct TaskCard: View {
    let task: AgentTask
    @ObservedObject var tasks: TaskService
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                ProviderLogo(id: task.provider).scaleEffect(0.5).frame(width: 16, height: 16)
                    .foregroundStyle(task.provider == .claude ? Color.orange : Color.blue)
                Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                Circle().fill(task.stateColor).frame(width: 5, height: 5)
                Text(task.stateTitle)
                if let at = task.resumeAt, task.state == .queued || (task.state == .paused && task.autoResume) {
                    Text("· " + L("продолжит {0}", at.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L10n.locale))))
                }
                Spacer(minLength: 0)
                Text(task.project).lineLimit(1).truncationMode(.head)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.08)).overlay(alignment: .leading) {
                        Capsule().fill(task.budgetUsed >= 1 ? Color.orange : ActivityStatisticsCards.heat)
                            .frame(width: geometry.size.width * CGFloat(task.budgetUsed))
                    }
                }.frame(height: 5)
                Text(L("{0} из {1} недели", TokenMonitorView.percent(task.spent),
                       task.weekBudget == task.weekBudget.rounded() ? PercentText.format(Int(task.weekBudget)) : TokenMonitorView.percent(task.weekBudget)))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }.accessibilityElement(children: .combine)
            if let handoff = task.handoff, !task.state.isActive {
                Text(handoff).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).help(handoff)
            }
            if let message = task.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityIdentifier("task-" + task.id.uuidString)
    }
    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            switch task.state {
            case .running, .wrappingUp:
                Button(L("Пауза")) { tasks.pause(task.id) }
                Button(L("Остановить")) { tasks.cancel(task.id) }
            case .queued:
                Button(L("Запустить сейчас")) { tasks.resume(task.id) }
                Button(L("Отменить")) { tasks.cancel(task.id) }
            case .paused, .needsYou, .failed:
                if task.spent >= task.weekBudget { Button(L("Добавить {0} и продолжить", PercentText.format(5))) { tasks.extendBudget(task.id) } }
                else { Button(L("Продолжить")) { tasks.resume(task.id) } }
                if task.sessionID != nil { Button(L("В Терминале")) { tasks.openInTerminal(task.id) } }
            case .done, .cancelled:
                if task.worktree != nil, task.branch != nil { Button(L("Принять изменения")) { Task { await tasks.accept(task.id) } } }
                Button(L("Убрать")) { tasks.remove(task.id) }
            }
            Spacer(minLength: 0)
            if task.worktree != nil {
                Button { tasks.revealCopy(task.id) } label: { Image(systemName: "folder") }.help(L("Показать копию проекта"))
                    .accessibilityLabel(L("Показать копию проекта"))
            }
        }.controlSize(.small)
    }
}

/// The New Task window: what to do, where, and how much of the week it may use.
struct NewTaskView: View {
    @ObservedObject var tasks: TaskService
    @ObservedObject var store: AppStore
    var onClose: () -> Void
    @AppStorage("taskLastFolder") private var folder = ""
    @AppStorage("taskLastProvider") private var providerRaw = ProviderID.claude.rawValue
    @State private var prompt = ""
    @State private var budget = 10.0
    @State private var guardWindow = true
    @State private var guardValue = 90.0
    @State private var start = TaskStart.now
    @State private var isolate = true
    @State private var autoResume = true
    @State private var permission = TaskPermission.careful

    private var provider: ProviderID {
        ProviderID(rawValue: providerRaw).flatMap { store.providers.contains($0) ? $0 : nil } ?? store.providers.first ?? .claude
    }
    private var snapshot: UsageSnapshot? { store.snapshots.first { $0.provider == provider } }

    var body: some View {
        Form {
            if store.providers.count > 1 {
                Picker(L("Агент"), selection: $providerRaw) {
                    ForEach(store.providers) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            LabeledContent(L("Папка проекта")) {
                HStack {
                    Text(folder.isEmpty ? L("Не выбрана") : folder).lineLimit(1).truncationMode(.head).foregroundStyle(folder.isEmpty ? .secondary : .primary)
                    Button(L("Выбрать…"), action: chooseFolder)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Задача"))
                TextEditor(text: $prompt).font(.system(size: 13)).frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.15)))
                    .accessibilityIdentifier("task-prompt")
            }
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $budget, in: 1...50, step: 1) { Text(L("Бюджет")) }
                Text(L("Не больше {0} недельного лимита {1}.", PercentText.format(Int(budget)), provider.title))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let week = snapshot?.weekly {
                    Text(L("Сейчас использовано {0}, свободно {1}.", PercentText.format(Int(week.usedPercent.rounded())), PercentText.format(Int(week.remaining.rounded()))))
                        .font(.system(size: 11)).foregroundStyle(budget > week.remaining ? .orange : .secondary)
                } else {
                    Text(L("Недельный лимит {0} пока неизвестен: без него задача не начнётся.", provider.title)).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Toggle(isOn: $guardWindow) { Text(L("Беречь окно 5 часов: пауза при {0}", PercentText.format(Int(guardValue)))) }
            if guardWindow { Slider(value: $guardValue, in: 50...100, step: 5) { EmptyView() } }
            Picker(L("Когда начать"), selection: $start) {
                Text(L("Сейчас")).tag(TaskStart.now)
                Text(resetTitle(L("После сброса окна 5 часов"), snapshot?.fiveHour?.resetsAt)).tag(TaskStart.afterFiveHourReset)
                Text(resetTitle(L("После сброса недели"), snapshot?.weekly?.resetsAt)).tag(TaskStart.afterWeeklyReset)
            }
            Toggle(isOn: $isolate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Работать в отдельной копии проекта"))
                    Text(L("Для папок с git: ваша папка не меняется, пока вы не примете результат. Перед паузой работа сохраняется коммитом в ветке задачи."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $autoResume) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Продолжать автоматически после сброса лимита"))
                    Text(L("В момент сброса Mac должен не спать, а Lunavect работать; иначе задача продолжится, когда Mac проснётся."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker(L("Разрешения"), selection: $permission) {
                    Text(L("Осторожно")).tag(TaskPermission.careful)
                    Text(L("Авто")).tag(TaskPermission.auto)
                    Text(L("Полный доступ")).tag(TaskPermission.full)
                }.pickerStyle(.segmented)
                Text(permissionNote).font(.system(size: 11)).foregroundStyle(permission == .full ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Отмена"), role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button(start == .now ? L("Запустить") : L("Поставить в очередь"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snapshot?.weekly == nil)
                    .accessibilityIdentifier("task-add")
            }
        }.formStyle(.grouped).frame(minWidth: 520, minHeight: 640)
    }
    private var permissionNote: String {
        switch permission {
        case .careful: return L("Правит файлы в папке задачи и выполняет безопасные команды. Остальное без спроса не делает: ему откажут, и Lunavect покажет это.")
        case .auto: return L("Claude: решения проверяет автоматический классификатор Anthropic. Codex: работа в папке задачи с доступом к сети.")
        case .full: return L("Никаких проверок: агент может выполнить любую команду на этом Mac. Выбирайте только для задач, которым полностью доверяете.")
        }
    }
    private func resetTitle(_ title: String, _ date: Date?) -> String {
        date.map { title + " · " + $0.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L10n.locale)) } ?? title
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
    private func add() {
        let task = AgentTask(provider: provider, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), folder: folder,
                             permission: permission, weekBudget: budget, fiveHourGuard: guardWindow ? guardValue : nil,
                             start: start, isolate: isolate, autoResume: autoResume)
        tasks.add(task)
        onClose()
    }
}
