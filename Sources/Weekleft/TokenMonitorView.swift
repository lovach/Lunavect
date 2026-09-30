import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// One session in the monitor.
struct TokenMonitorRow: Identifiable, Equatable {
    let id: String
    let provider: ProviderID
    let title: String
    let project: String
    let model: String
    let tokens: Int64
    let subagentShare: Double
    /// Estimated percent of the weekly limit; -1 when the limit is unknown.
    let weekPercent: Double
    /// Estimated percent of the weekly limit an hour at the current pace; 0 when quiet.
    let perHour: Double
    let last: Date

    @MainActor static func rows(tokens: TokenService, snapshots: [UsageSnapshot], sessions: [AgentSession], details: ActivityDetails,
                                now: Date, onlyRecent: Bool) -> [TokenMonitorRow] {
        // Titles of live sessions first, then those the activity details remember.
        var titles = Dictionary(details.records.values.map { (TokenLedger.sessionKey($0.provider, $0.sessionID), $0.title) },
                                uniquingKeysWith: { first, _ in first })
        for session in sessions where !session.title.isEmpty { titles[TokenLedger.sessionKey(session.provider, session.sessionID)] = session.displayTitle }
        let weekStart = now.addingTimeInterval(-7 * 86400), hourAgo = now.addingTimeInterval(-3600)
        return tokens.ledger.sessions.values.compactMap { session in
            guard let last = session.last, last >= (onlyRecent ? hourAgo : weekStart) else { return nil }
            let week = snapshots.first { $0.provider == session.provider }?.weekly
            let share = tokens.share(of: session, window: week, now: now)
            let model = session.models.max { $0.value.weight(session.provider) < $1.value.weight(session.provider) }?.key ?? ""
            let weight = session.total.weight(session.provider)
            return TokenMonitorRow(id: session.key, provider: session.provider,
                                   title: titles[session.key].flatMap { $0.isEmpty ? nil : $0 } ?? session.project,
                                   project: session.project, model: TokenLedger.modelTitle(model), tokens: session.total.total,
                                   subagentShare: weight > 0 ? session.subagents.weight(session.provider) / weight : 0,
                                   weekPercent: share?.percent ?? -1, perHour: share?.perHour ?? 0, last: last)
        }
    }
}

/// "Activity Monitor" for agents: which session is spending the limit, and how fast.
struct TokenMonitorView: View {
    @ObservedObject var tokens: TokenService
    @ObservedObject var store: AppStore
    @ObservedObject var sessions: SessionStore
    @AppStorage("monitorRecentOnly") private var recentOnly = false
    @State private var sortOrder = [KeyPathComparator(\TokenMonitorRow.weekPercent, order: .reverse)]
    @State private var selection: TokenMonitorRow.ID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let rows = TokenMonitorRow.rows(tokens: tokens, snapshots: store.snapshots, sessions: sessions.sessions, details: store.activityDetails,
                                            now: context.date, onlyRecent: recentOnly).sorted(using: sortOrder)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(store.providers) { provider in providerTile(provider, rows: rows, now: context.date) }
                }
                HStack {
                    Picker(L("Показать"), selection: $recentOnly) {
                        Text(L("За неделю")).tag(false)
                        Text(L("Последний час")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer()
                    if tokens.catchingUp {
                        ProgressView().controlSize(.small)
                        Text(L("Считаем токены по журналам…")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                table(rows)
                Text(L("≈ — оценка: процент недельного лимита делится между сессиями по их токенам с учётом цены. Чаты в приложениях Claude и ChatGPT в журналы не попадают, поэтому доли сессий могут быть завышены."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }.frame(minWidth: 760, minHeight: 460)
    }

    private func providerTile(_ provider: ProviderID, rows: [TokenMonitorRow], now: Date) -> some View {
        let week = store.snapshots.first { $0.provider == provider }?.weekly
        let pace = rows.filter { $0.provider == provider }.reduce(0) { $0 + $1.perHour }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderLogo(id: provider).scaleEffect(0.5).frame(width: 16, height: 16)
                    .foregroundStyle(provider == .claude ? Color.orange : Color.blue)
                Text(provider.title).font(.system(size: 13, weight: .semibold))
            }
            if let week {
                Text(L("Неделя: {0}", PercentText.format(Int(week.usedPercent.rounded())))).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Text(pace >= 0.05 ? L("Сейчас ≈ {0} в час", Self.percent(pace)) : L("Сейчас не расходуется"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let resets = week.resetsAt {
                    Text(L("Сброс {0}", resets.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L10n.locale))))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text(L("Лимит неизвестен")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }

    private func table(_ rows: [TokenMonitorRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Сессия"), value: \.title) { row in
                HStack(spacing: 6) {
                    ProviderLogo(id: row.provider).scaleEffect(0.42).frame(width: 14, height: 14)
                        .foregroundStyle(row.provider == .claude ? Color.orange : Color.blue)
                    Text(row.title).lineLimit(1).help(row.title)
                }
            }.width(min: 160, ideal: 220)
            TableColumn(L("Проект"), value: \.project) { Text($0.project).lineLimit(1) }.width(min: 80, ideal: 110)
            TableColumn(L("Модель"), value: \.model) { Text($0.model).lineLimit(1) }.width(min: 70, ideal: 90)
            TableColumn(L("Токены"), value: \.tokens) { Text(TokenText.compact($0.tokens)).monospacedDigit() }.width(min: 60, ideal: 70)
            TableColumn(L("Субагенты"), value: \.subagentShare) { row in
                Text(row.subagentShare >= 0.005 ? PercentText.format(Int((row.subagentShare * 100).rounded())) : "—").monospacedDigit()
            }.width(min: 60, ideal: 70)
            TableColumn(L("≈ % недели"), value: \.weekPercent) { row in
                Text(row.weekPercent >= 0 ? Self.percent(row.weekPercent) : "—").monospacedDigit()
            }.width(min: 96, ideal: 104)
            TableColumn(L("Сейчас"), value: \.perHour) { row in
                Text(row.perHour >= 0.05 ? L("{0} в час", Self.percent(row.perHour)) : "—").monospacedDigit()
            }.width(min: 70, ideal: 90)
            TableColumn(L("Активность"), value: \.last) { row in
                Text(row.last.formatted(.relative(presentation: .named).locale(L10n.locale))).foregroundStyle(.secondary)
            }.width(min: 80, ideal: 110)
        }.accessibilityIdentifier("token-monitor-table")
    }

    /// One decimal below 10 %, whole numbers above.
    static func percent(_ value: Double) -> String {
        guard value < 10 else { return PercentText.format(Int(value.rounded())) }
        return L10n.text("{0}%", language: L10n.selection, arguments: [value.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))])
    }
}
