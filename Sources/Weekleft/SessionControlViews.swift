import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

extension SessionControl {
    var stateTitle: String {
        switch state {
        case .watching:
            if let stop = stopAtWeek { return L("Остановится на {0} недели", PercentText.format(Int(stop.rounded()))) }
            return resumeAt.map { L("Продолжит {0}", SessionControlService.date($0)) } ?? L("Ждёт")
        case .wrappingUp: return L("Заканчивает шаг перед пределом")
        case .stopped: return L("Остановлена на пределе")
        case .continued: return L("Продолжена")
        case .needsYou: return L("Можно продолжить")
        }
    }
    var symbol: String {
        switch state {
        case .stopped: return "hand.raised.fill"
        case .wrappingUp: return "hourglass"
        case .needsYou: return "arrow.clockwise.circle"
        default: return stopAtWeek != nil ? "gauge.with.dots.needle.67percent" : "clock"
        }
    }
    var tint: Color { state == .stopped || state == .wrappingUp || state == .needsYou ? .orange : .secondary }
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
    var onClose: () -> Void
    @State private var stop: Double = 90
    @State private var continueAfter = true
    @State private var message = ""
    @State private var when = SessionControl.Resume.afterFiveHourReset
    @State private var date = Date().addingTimeInterval(3600)
    @State private var loaded = false

    private var snapshot: UsageSnapshot? { store.snapshots.first { $0.provider == session.provider } }
    private var level: Double? { controls.weekLevel(session.provider) }
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
                Label(L("Lunavect не подключён к событиям {0}: без этого сессию не остановить. Включите подключение в настройках.", session.provider.title), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if mode == .limit { limitForm } else { laterForm }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Что написать агенту")).font(.system(size: 12))
                TextField(SessionControl.defaultMessage, text: $message).textFieldStyle(.roundedBorder)
                    .disabled(mode == .limit && !continueAfter)
                Text(canType ? L("Lunavect впишет это в ту же вкладку, где идёт сессия.")
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
        session.client == .terminal && session.terminalTTY != nil && ["Terminal", "iTerm2"].contains(session.terminalApp ?? "")
    }

    @ViewBuilder private var limitForm: some View {
        if let level {
            WeekStopGauge(level: level, stop: stop)
            HStack(spacing: 8) {
                Text(L("Остановить, когда неделя дойдёт до"))
                TextField("", value: $stop, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
                    .onChange(of: stop) { _, value in if value > 100 { stop = 100 } else if value < 1 { stop = 1 } }
                    .accessibilityIdentifier("session-control-stop")
                Stepper("", value: $stop, in: 1...100, step: 1).labelsHidden()
                Text(PercentText.sign())
            }.font(.system(size: 13))
            Slider(value: $stop, in: 1...100, step: 1) { EmptyView() }
            Group {
                if stop <= level {
                    Text(L("Неделя уже на этом уровне: сессия остановится сразу.")).foregroundStyle(.orange)
                } else {
                    Text(L("Это ещё ≈ {0} недели.", TokenMonitorView.percent(stop - level))
                         + (sessionShare.map { " " + L("Эта сессия уже потратила ≈ {0}.", TokenMonitorView.percent($0)) } ?? ""))
                        .foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $continueAfter) {
                Text(L("Когда лимит сбросится, продолжить эту сессию"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(L("Незадолго до предела агент закончит шаг и напишет, что осталось"), systemImage: "text.bubble")
                Label(L("На пределе агент остановится; файлы и разговор останутся как есть"), systemImage: "hand.raised")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Text(L("Недельный лимит {0} пока неизвестен: без него предел не задать.", session.provider.title))
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
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
        else if let level { stop = min(100, (level + 10).rounded()) }
        if let text = existing?.message, text != SessionControl.defaultMessage { message = text }
        continueAfter = existing.map { $0.message != nil } ?? true
    }
    private func apply() {
        if mode == .limit {
            controls.setLimit(for: session, stopAtWeek: stop, continueAfterReset: continueAfter, message: message)
        } else {
            controls.continueLater(session, when: when, at: when == .at ? date : nil, message: message)
        }
        onClose()
    }
}

/// The Tasks tab: sessions with a limit or a planned continuation.
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        ProviderLogo(id: control.provider).scaleEffect(0.5).frame(width: 16, height: 16)
                            .foregroundStyle(control.provider == .claude ? Color.orange : Color.blue)
                        Text(control.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: control.symbol).foregroundStyle(control.tint)
                        Text(control.stateTitle)
                        if control.message != nil, let at = control.resumeAt, control.stopAtWeek != nil {
                            Text("· " + L("продолжит {0}", SessionControlService.date(at)))
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    if let note = control.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 6) {
                        if control.state == .stopped || control.state == .needsYou || control.resumeAt != nil {
                            Button(L("Продолжить сейчас")) { controls.continueNow(control.id) }
                        }
                        Button(L("Снять")) { controls.remove(control.id) }
                    }.controlSize(.small)
                }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .contain)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}
