import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

extension SessionControl {
    var stateTitle: String {
        let level = PercentText.format(Int((stopAtWeek ?? 0).rounded()))
        switch state {
        case .watching:
            if stopAtWeek != nil { return L("Остановится на {0} недели", level) }
            return resumeAt.map { L("Продолжит {0}", SessionControlService.date($0)) } ?? L("Ждёт")
        case .wrappingUp: return L("Заканчивает шаг перед пределом")
        case .stopped: return L("Остановлена на {0} недели", level)
        case .resting: return L("Ждёт сброса окна 5 часов")
        case .offered: return pressEnter == true ? L("Лимит сбросился, пока Mac спал") : L("Лимит {0} закончился посреди работы", provider.title)
        case .continued: return L("Продолжена")
        case .needsYou: return L("Можно продолжить")
        }
    }
    var symbol: String {
        switch state {
        case .stopped: return "hand.raised.fill"
        case .wrappingUp, .resting: return "hourglass"
        case .offered: return "exclamationmark.circle.fill"
        case .needsYou: return "arrow.clockwise.circle"
        default: return stopAtWeek != nil ? "gauge.with.dots.needle.67percent" : "clock"
        }
    }
    var tint: Color { [.stopped, .wrappingUp, .needsYou, .offered].contains(state) ? .orange : .secondary }
    /// "Continues at …" beside a stop or a rest.
    var resumeLine: String? {
        guard let resumeAt, [.stopped, .resting].contains(state) else { return nil }
        return L("продолжит {0}", SessionControlService.date(resumeAt))
    }
}

/// The agent's last reply after it stopped: "Done" and "Left" when it wrote them, otherwise its words.
struct SessionSummaryView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Итог агента")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if let parts = SessionControl.summaryParts(text) {
                (Text(L("Сделано:") + " ").bold() + Text(parts.done)).font(.system(size: 11)).lineLimit(3)
                (Text(L("Осталось:") + " ").bold() + Text(parts.left)).font(.system(size: 11)).lineLimit(3)
            } else {
                Text(text).font(.system(size: 11)).lineLimit(5)
            }
        }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .combine)
    }
}

/// The week as a bar: used now, and where the session will stop.
struct WeekStopGauge: View {
    let level: Double
    let stop: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(ActivityStatisticsCards.heat).frame(width: geometry.size.width * CGFloat(min(level, 100) / 100))
                    Rectangle().fill(Color.orange).frame(width: 2.5).offset(x: geometry.size.width * CGFloat(min(stop, 100) / 100) - 1.25)
                }
            }.frame(height: 12).clipShape(Capsule())
            HStack {
                Text(L("сейчас {0}", PercentText.format(Int(level.rounded())))).foregroundStyle(.primary)
                Spacer()
                Text(L("стоп {0}", PercentText.format(Int(stop.rounded())))).foregroundStyle(.orange)
            }.font(.system(size: 11)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

/// «Ограничить расход» and «Продолжить позже» for one session.
struct SessionControlView: View {
    let session: AgentSession
    let mode: SessionControlMode
    @ObservedObject var controls: SessionControlService
    @ObservedObject var store: AppStore
    var hooksReady: Bool
    /// Codex skips Lunavect's hooks until the user trusts them again.
    var hooksUntrusted = false
    var onClose: () -> Void
    @State private var stop: Double = 90
    @State private var fiveHourGuard = true
    @State private var continueAfter = true
    @State private var message = ""
    @State private var when = SessionControl.Resume.afterFiveHourReset
    @State private var date = Date().addingTimeInterval(3600)
    @State private var loaded = false

    private var snapshot: UsageSnapshot? { controls.snapshot(session.provider) }
    private var level: Double? { controls.weekLevel(session.provider) }
    private var suggestion: Double? { level.map { SessionControl.suggestedStop(level: $0, resetsAt: snapshot?.weekly?.resetsAt, now: Date()) } }
    private var sessionShare: Double? {
        guard let tokens = store.tokenService.tokens(session.provider, sessionID: session.sessionID) else { return nil }
        return store.tokenService.share(of: tokens, window: snapshot?.weekly, now: Date())?.percent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L(mode == .limit ? "Ограничить расход" : "Продолжить позже")).font(.system(size: 16, weight: .semibold))
            Text(session.displayTitle + " · " + session.provider.title + " · " + session.project)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            if !hooksReady {
                Label(hooksUntrusted ? L("Codex не запускает обработчики Lunavect: без них сессию не остановить. Как это исправить, написано в Настройки → Подключения.")
                      : L("Lunavect не подключён к событиям {0}: без этого сессию не остановить. Включите подключение в настройках.", session.provider.title),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if mode == .limit { limitForm } else { laterForm }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Что написать агенту")).font(.system(size: 12))
                TextField(SessionControl.defaultMessage, text: $message).textFieldStyle(.roundedBorder)
                    .disabled(mode == .limit && !continueAfter && !fiveHourGuard)
                Text(canType ? L("Lunavect впишет это в ту же вкладку Терминала. Если вкладку закроют, откроет новую и продолжит тот же разговор.")
                     : L("Эта сессия открыта не в Terminal и не в iTerm2: Lunavect пришлёт уведомление, и продолжить нужно будет вручную."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if controls.control(for: session) != nil {
                    Button(L("Снять"), role: .destructive) { controls.remove(TokenLedger.sessionKey(session.provider, session.sessionID)); onClose() }
                }
                Spacer()
                Button(L("Отмена"), role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button(L(mode == .limit ? "Ограничить" : "Запланировать"), action: apply).keyboardShortcut(.defaultAction)
                    .disabled(mode == .limit && (level == nil || !hooksReady))
                    .accessibilityIdentifier("session-control-apply")
            }
        }.padding(18).frame(width: 440)
            .onAppear(perform: load)
    }

    private var canType: Bool {
        session.client == .terminal && ["Terminal", "iTerm2"].contains(session.terminalApp ?? "")
    }

    @ViewBuilder private var limitForm: some View {
        if let level {
            WeekStopGauge(level: level, stop: stop)
            HStack(spacing: 8) {
                Text(L("Остановить, когда неделя дойдёт до"))
                TextField("", value: $stop, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
                    .onChange(of: stop) { _, value in
                        let whole = min(100, max(1, value.rounded()))
                        if whole != value { stop = whole }
                    }
                    .accessibilityIdentifier("session-control-stop")
                Stepper("", value: $stop, in: 1...100, step: 1).labelsHidden()
                Text(PercentText.sign())
            }.font(.system(size: 13))
            Slider(value: $stop, in: 1...100) { EmptyView() }
            if stop <= level {
                Text(L("Неделя уже на этом уровне: сессия остановится сразу.")).font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hint(level)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let suggestion, suggestion != stop {
                            Button(L("Подставить {0}", PercentText.format(Int(suggestion)))) { stop = suggestion }
                                .buttonStyle(.link).accessibilityIdentifier("session-control-suggestion")
                        }
                    }
                }.font(.system(size: 11))
            }
            Divider()
            Toggle(isOn: $fiveHourGuard) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Не обрываться на окне 5 часов"))
                    Text(snapshot?.fiveHour?.resetsAt.map { L("До обрыва агент закончит шаг, после сброса окна ({0}) Lunavect напишет ему «продолжай».", SessionControlService.date($0)) }
                         ?? L("До обрыва агент закончит шаг, после сброса окна Lunavect напишет ему «продолжай»."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("session-control-five-hour")
            Toggle(isOn: $continueAfter) { Text(L("Когда неделя сбросится, продолжить эту сессию")) }
            VStack(alignment: .leading, spacing: 4) {
                Label(L("Незадолго до предела агент закончит шаг и напишет, что осталось"), systemImage: "text.bubble")
                Label(L("На пределе агент остановится; файлы и разговор останутся как есть"), systemImage: "hand.raised")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Text(L("Недельный лимит {0} пока неизвестен: без него предел не задать.", session.provider.title))
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
    }
    /// Today's share of the rest of the week, then what the chosen level leaves and what the session spent.
    private func hint(_ level: Double) -> String {
        var parts: [String] = []
        if let suggestion, let reset = snapshot?.weekly?.resetsAt {
            parts.append(L("{0}: столько приходится на сегодня, если растянуть остаток недели до сброса в {1}.",
                           PercentText.format(Int(suggestion)), SessionControlService.date(reset)))
        }
        parts.append(L("Это ещё ≈ {0} недели.", TokenMonitorView.percent(stop - level)))
        if let sessionShare { parts.append(L("Эта сессия уже потратила ≈ {0}.", TokenMonitorView.percent(sessionShare))) }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private var laterForm: some View {
        Picker(L("Когда"), selection: $when) {
            Text(resetTitle(L("После сброса окна 5 часов"), snapshot?.fiveHour?.resetsAt)).tag(SessionControl.Resume.afterFiveHourReset)
            Text(resetTitle(L("После сброса недели"), snapshot?.weekly?.resetsAt)).tag(SessionControl.Resume.afterWeeklyReset)
            Text(L("В точное время")).tag(SessionControl.Resume.at)
        }.pickerStyle(.radioGroup)
        if when == .at {
            DatePicker(L("Время"), selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
        }
        Text(L("Если в это время агент ещё работает, Lunavect подождёт, пока он закончит."))
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func resetTitle(_ title: String, _ date: Date?) -> String {
        date.map { title + " · " + SessionControlService.date($0) } ?? title
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        let existing = controls.control(for: session)
        if let value = existing?.stopAtWeek { stop = value }
        else if let suggestion { stop = suggestion }
        if let text = existing?.message { message = text }
        if let existing, existing.stopAtWeek != nil {
            fiveHourGuard = existing.fiveHourGuard == true
            continueAfter = existing.continueAfterWeek == true
        }
    }
    private func apply() {
        if mode == .limit {
            controls.setLimit(for: session, stopAtWeek: stop, fiveHourGuard: fiveHourGuard, continueAfterReset: continueAfter, message: message)
        } else {
            controls.continueLater(session, when: when, at: when == .at ? date : nil, message: message)
        }
        onClose()
    }
}

/// The Tasks tab: sessions with a limit, a rest, a question after a cut-off or a planned continuation.
struct SessionControlListView: View {
    @ObservedObject var controls: SessionControlService
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controls.controls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Пока ничего не запланировано")).font(.system(size: 13, weight: .semibold))
                    Text(L("Нажмите двумя пальцами на сессию (или «⋯») и выберите «Ограничить расход…», чтобы она остановилась на нужном проценте недели, или «Продолжить позже…», чтобы Lunavect сам написал ей «продолжай» после сброса лимита."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(controls.controls) { control in
                card(control)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func card(_ control: SessionControl) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                ProviderLogo(id: control.provider).scaleEffect(0.5).frame(width: 16, height: 16)
                    .foregroundStyle(control.provider == .claude ? Color.orange : Color.blue)
                Text(control.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: control.symbol).foregroundStyle(control.tint)
                Text(([control.stateTitle, control.resumeLine,
                       control.state == .watching && control.stopAtWeek != nil && control.fiveHourGuard == true ? L("не обрывается на окне 5 часов") : nil]
                      as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if control.state == .offered {
                Text(control.pressEnter == true ? L("Claude Code ждёт Enter, чтобы продолжить.")
                     : control.resumeAt.map { L("Лимит сбросится в {0}. Продолжить эту сессию тогда?", SessionControlService.date($0)) }
                     ?? L("Продолжить эту сессию, когда лимит сбросится?"))
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            if let note = control.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let summary = control.summary, [.stopped, .resting, .offered, .needsYou].contains(control.state) {
                SessionSummaryView(text: summary)
            }
            HStack(spacing: 6) {
                switch control.state {
                case .offered:
                    Button(control.pressEnter == true ? L("Продолжить")
                           : control.resumeAt.map { L("Продолжить в {0}", SessionControlService.date($0)) } ?? L("Продолжить после сброса")) {
                        controls.accept(control.id)
                    }.buttonStyle(.borderedProminent)
                    Button(L("Не надо")) { controls.decline(control.id) }
                case .stopped:
                    Button(L("Продолжить сейчас")) { controls.continueNow(control.id) }
                    Button("+" + PercentText.format(5)) { controls.raise(control.id) }.help(L("Поднять предел на 5 процентных пунктов и продолжить"))
                    Button(L("Снять")) { controls.remove(control.id) }
                case .needsYou:
                    if TerminalLocation.resumeCommand(provider: control.provider, sessionID: control.sessionID, text: control.text) != nil {
                        Button(L("Продолжить в Терминале")) { controls.openInTerminal(control.id) }
                    }
                    Button(L("Снять")) { controls.remove(control.id) }
                default:
                    if control.state == .resting || control.resumeAt != nil {
                        Button(L("Продолжить сейчас")) { controls.continueNow(control.id) }
                    }
                    Button(L("Снять")) { controls.remove(control.id) }
                }
            }.controlSize(.small)
        }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
    }
}
