import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// What a limits card shows for one weekly window: the value, whether it is
/// dimmed as saved data, whether the state sentence replaces the reset
/// countdown and whether the card marks it as not updated. Every card uses
/// the same window status as the menu bar (P-I4, R2-P-05).
struct WidgetQuotaDisplay: Equatable {
    /// The window whose remaining share and reset are shown.
    var window: QuotaWindow?
    var unlimited = false
    var dimmed: Bool
    var showsStatus: Bool
    var needsAttention: Bool
    init(window: QuotaWindow?, unlimited: Bool = false, dimmed: Bool, showsStatus: Bool, needsAttention: Bool) {
        self.window = window; self.unlimited = unlimited; self.dimmed = dimmed
        self.showsStatus = showsStatus; self.needsAttention = needsAttention
    }
    /// No limits, a value, an exhausted window or a passed reset: shown as in the menu bar.
    init(weekly snapshot: UsageSnapshot, now: Date) {
        let status = snapshot.status(of: snapshot.weekly, now: now)
        let window = status.remaining(of: snapshot.weekly) == nil ? nil : snapshot.weekly
        self.init(window: window, unlimited: status == .unlimited, dimmed: status.isStale,
                  showsStatus: window == nil || status.isStale || status.note(now: now) != nil,
                  needsAttention: snapshot.issue != nil || (snapshot.fetchedAt != nil && status.needsAttention))
    }
    var percent: Int? { window.map { Int($0.remaining.rounded()) } }
    /// "∞", the remaining share or a dash.
    var value: String { unlimited ? "∞" : percent.map { PercentText.format($0) } ?? "—" }
    /// The share without its sign, for a layout that sets the sign apart.
    var number: String { unlimited ? "∞" : percent.map(String.init) ?? "—" }
}

struct WeekleftCard: View {
    let snapshots: [UsageSnapshot]
    let preferences: WidgetPreferences
    var now: Date = Date()
    var drawsOutline = true
    var size = CGSize(width: 344, height: 172)
    var demo = false
    var showSettings: (() -> Void)? = nil
    var body: some View {
        if preferences.providers.isEmpty {
            WidgetConnectionPrompt().frame(width: size.width, height: size.height)
        } else if preferences.providers.count == 1, let id = preferences.providers.first {
            SingleProviderLimitsCard(snapshot: snapshots.first { $0.provider == id } ?? UsageSnapshot(provider: id), preferences: preferences, now: now)
                .frame(width: size.width, height: size.height)
        } else {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Недельный остаток")).font(.system(size: 10, weight: .regular))
                Spacer()
                if demo { Text(L("Демо")).font(.system(size: 9)) }
                else if marksAttention {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        .help(L("Некоторые данные не обновились. Откройте настройки для подробностей."))
                }
            }.foregroundStyle(WidgetInk(0.85)).frame(height: 12).padding(.bottom, 8)
            providerRow(.claude)
            Spacer().frame(height: max(4, min(16, size.height - 154)))
            providerRow(.codex)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .overlay {
            if drawsOutline {
                    RoundedRectangle(cornerRadius: 26).stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .white.opacity(0.08), .clear], startPoint: .topLeading,
                            endPoint: .bottomTrailing), lineWidth: 0.7)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 26))
    }
    }
    func display(_ snapshot: UsageSnapshot) -> WidgetQuotaDisplay { WidgetQuotaDisplay(weekly: snapshot, now: now) }
    var marksAttention: Bool { snapshots.contains { display($0).needsAttention } }
    private func providerRow(_ id: ProviderID) -> some View {
        let snapshot = snapshots.first(where: { $0.provider == id }) ?? UsageSnapshot(provider: id)
        // A past reset does not tell us the new window's usage. Keep the cached
        // record for diagnostics, but never present it as the current allowance.
        let display = display(snapshot)
        let weekly = display.window
        let fiveHour = snapshot.status(of: snapshot.fiveHour, now: now).remaining(of: snapshot.fiveHour) == nil ? nil : snapshot.fiveHour
        let accent = id == .claude ? Color(red: 1, green: 0.70, blue: 0.47) : Color(red: 0.61, green: 0.84, blue: 1)
        return HStack(alignment: .top, spacing: 9) {
            ProviderLogo(id: id).foregroundStyle(accent).frame(width: 39, height: 39, alignment: .leading).padding(.top, 3)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(id.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 6)
                    if let weekly, weekly.resetsAt != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "timer").font(.system(size: 9))
                            Text(weekly.countdown(now: now)).font(.system(size: 11)).monospacedDigit()
                        }.foregroundStyle(WidgetInk(0.84))
                            .help(L("Сброс недельного лимита: ") + resetDescription(weekly))
                            .padding(.trailing, 6)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(display.number).font(.system(size: 25, weight: .semibold)).monospacedDigit()
                        if weekly != nil { Text(PercentText.sign()).font(.system(size: 12)) }
                    }.opacity(display.dimmed ? 0.6 : 1)
                }.frame(height: 23).lineLimit(1)
                bar(weekly, accent: accent, height: 5).opacity(display.dimmed ? 0.5 : 1).padding(.top, 7)
                HStack(spacing: 6) {
                    if display.showsStatus {
                        Text(widgetQuotaStatus(snapshot, now: now)).font(.system(size: 9))
                            .foregroundStyle(WidgetInk(0.78)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if preferences.showFiveHour {
                        Text(L("5 ч") + " · " + (fiveHour.map { PercentText.format(Int($0.remaining.rounded())) } ?? "—"))
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(WidgetInk(0.78)).fixedSize()
                    }
                    ForEach(WidgetModelLimit.lines(snapshot, preferences: preferences, now: now), id: \.name) { limit in
                        Text(limit.name + " · " + limit.value)
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(WidgetInk(0.78)).fixedSize()
                    }
                    Spacer(minLength: 0)
                    if preferences.showPlanEnd, let plan = PlanEndState.of(preferences, provider: id, now: now) {
                        HStack(spacing: 2) {
                            Image(systemName: plan.symbol).font(.system(size: 8))
                            Text(plan.short).font(.system(size: 9)).monospacedDigit()
                        }.foregroundStyle(plan.widgetColor).fixedSize().help(plan.full)
                            .accessibilityElement(children: .ignore).accessibilityLabel(plan.full)
                    }
                    if !demo, display.dimmed, let fetched = snapshot.fetchedAt {
                        Text(widgetQuotaDate(fetched, now: now)).font(.system(size: 9)).foregroundStyle(WidgetInk(0.65)).fixedSize()
                    }
                }.frame(height: 14).padding(.top, 6)
                    .help(widgetQuotaExplanation(snapshot, now: now))
            }
        }.frame(height: 55).accessibilityElement(children: .contain)
            .accessibilityValue(widgetQuotaExplanation(snapshot, now: now))
    }
    private func bar(_ window: QuotaWindow?, accent: Color, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetInk(0.12, increased: 0.3))
                if let window { Capsule().fill(accent).frame(width: geometry.size.width * window.remaining / 100) }
            }
        }.frame(height: height).accessibilityLabel(L("Осталось")).accessibilityValue(window.map { PercentText.format(Int($0.remaining.rounded())) } ?? L("Нет данных"))
    }
    private func resetDescription(_ window: QuotaWindow) -> String {
        guard let date = window.resetsAt else { return L("время неизвестно") }
        return date.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))
    }
}
struct WidgetConnectionPrompt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lunavect").font(.system(size: 15, weight: .semibold))
            Text(L("Подключите Claude или Codex в настройках подключений."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct SingleProviderLimitsCard: View {
    let snapshot: UsageSnapshot
    let preferences: WidgetPreferences
    let now: Date
    var compact = false
    var display: WidgetQuotaDisplay { WidgetQuotaDisplay(weekly: snapshot, now: now) }
    private var weekly: QuotaWindow? { display.window }
    private var five: QuotaWindow? { snapshot.status(of: snapshot.fiveHour, now: now).remaining(of: snapshot.fiveHour) == nil ? nil : snapshot.fiveHour }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.provider.title).font(.system(size: compact ? 13 : 15, weight: .semibold))
                Spacer(minLength: 4)
                if display.needsAttention {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ProviderLogo(id: snapshot.provider).foregroundStyle(activityAccent(snapshot.provider)).scaleEffect(0.75).frame(width: 24, height: 24)
            }.frame(height: 24)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(display.value)
                    .font(.system(size: compact ? 28 : 36, weight: .semibold)).monospacedDigit()
                    .opacity(display.dimmed ? 0.6 : 1)
                if !compact { Text(L("Недельный остаток")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.lineLimit(1).minimumScaleFactor(0.8)
            if compact { Text(L("Недельный остаток")).font(.system(size: 9)).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetInk(0.12, increased: 0.3))
                    if let weekly { Capsule().fill(activityAccent(snapshot.provider)).frame(width: geometry.size.width * weekly.remaining / 100) }
                }
            }.frame(height: 5).opacity(display.dimmed ? 0.5 : 1).accessibilityLabel(L("Осталось"))
                .accessibilityValue(weekly.map { PercentText.format(Int($0.remaining.rounded())) } ?? L("Нет данных"))
            if preferences.showFiveHour {
                HStack {
                    Text(L("5 ч"))
                    Spacer()
                    Text(five.map { PercentText.format(Int($0.remaining.rounded())) } ?? "—").monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if preferences.showPlanEnd, let plan = PlanEndState.of(preferences, provider: snapshot.provider, now: now) {
                HStack {
                    Image(systemName: plan.symbol)
                    Spacer()
                    Text(plan.short).monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(plan.isNormal ? AnyShapeStyle(.secondary) : plan.widgetColor)
                    .help(plan.full).accessibilityElement(children: .ignore).accessibilityLabel(plan.full)
            }
            ForEach(WidgetModelLimit.lines(snapshot, preferences: preferences, now: now).prefix(1), id: \.name) { limit in
                HStack {
                    Text(limit.name).lineLimit(1)
                    Spacer()
                    Text(limit.value).monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(
                display.showsStatus
                    ? widgetQuotaStatus(snapshot, now: now)
                    : weekly.map { L("Сброс через {0}", $0.countdown(now: now)) } ?? L("Ждём лимиты")
            )
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            if display.dimmed, let fetched = snapshot.fetchedAt {
                Text(
                    L(
                        "Данные: {0}",
                        fetched.formatted(
                            Calendar.current.isDate(fetched, inSameDayAs: now)
                                ? .dateTime.hour().minute().locale(L10n.locale)
                                : .dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale)))
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }.padding(14).foregroundStyle(.white).help(widgetQuotaExplanation(snapshot, now: now))
    }
}

struct ProviderLogo: View {
    let id: ProviderID
    var body: some View {
        Group {
            if let image = Self.images[id] {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else { Image(systemName: id == .claude ? "sun.max.fill" : "terminal.fill").resizable().scaledToFit() }
        }.frame(width: id == .claude ? 29 : 25, height: id == .claude ? 29 : 25)
            .padding(.leading, id == .codex ? 2 : 0).accessibilityHidden(true)
    }
    static let images: [ProviderID: NSImage] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { id in
        loadImage(id).map { (id, $0) }
    })
    private static func loadImage(_ id: ProviderID) -> NSImage? {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: id.rawValue, withExtension: "pdf", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: id.rawValue, withExtension: "pdf")
        #endif
        return url.flatMap { url in
            guard let image = NSImage(contentsOf: url) else { return nil }
            image.size = NSSize(width: 128, height: 128)
            return image
        }
    }
}
struct GlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.wantsLayer = true; view.layer?.cornerRadius = 26; view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Claude's weekly model limits (Fable) as widgets show them when the setting is on:
/// the same whole percentage as Settings, "*" for a saved value, a dash without one.
struct WidgetModelLimit: Equatable {
    let name: String
    let value: String
    static func lines(_ snapshot: UsageSnapshot, preferences: WidgetPreferences, now: Date) -> [WidgetModelLimit] {
        guard preferences.showModelLimits, snapshot.provider == .claude else { return [] }
        return (snapshot.modelQuotas ?? []).prefix(2).map { quota in
            let status = quota.status(now: now)
            let value = status.remaining(of: quota.window).map { PercentText.format(Int($0.rounded())) + (status.isStale ? "*" : "") } ?? "—"
            return WidgetModelLimit(name: quota.name, value: value)
        }
    }
}

extension PlanEndState {
    var isNormal: Bool { if case .until = self { return true } else { return false } }
    var widgetColor: AnyShapeStyle {
        switch self {
        case .until: return AnyShapeStyle(WidgetInk(0.78))
        case .soon: return AnyShapeStyle(Color.orange)
        case .expired: return AnyShapeStyle(Color(red: 1, green: 0.42, blue: 0.42))
        }
    }
}

/// A compact state label is always visible, including with five-hour values.
/// The full source and diagnostic remain available to help and accessibility.
func widgetQuotaStatus(_ snapshot: UsageSnapshot, now: Date) -> String {
    // Reset passed, window not started or no limits: the same sentence as the menu bar and settings.
    if let note = snapshot.status(of: snapshot.weekly, now: now).note(now: now) { return note }
    guard snapshot.weekly != nil else {
        return L(snapshot.fetchedAt == nil ? "Ждём лимиты" : "Недельный лимит недоступен")
    }
    return L(snapshot.freshnessVerified ? "Данные устарели" : "Лимиты сохранены")
}
func widgetQuotaDate(_ date: Date, now: Date) -> String {
    date.formatted(Calendar.current.isDate(date, inSameDayAs: now)
        ? .dateTime.hour().minute().locale(L10n.locale)
        : .dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale))
}
func widgetQuotaExplanation(_ snapshot: UsageSnapshot, now: Date) -> String {
    [snapshot.source, snapshot.issue.map { L($0) }, snapshot.fetchedAt.map {
        L("Данные: {0}", $0.formatted(.dateTime.day().month().year().hour().minute().locale(L10n.locale)))
    }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

extension QuotaWindowStatus {
    /// The widget header marks data that did not update: saved values, a passed
    /// reset or a window the source stopped reporting. 0 %, an unstarted window
    /// and "no limits" are current answers.
    var needsAttention: Bool {
        switch self {
        case .unknown, .resetPassed: return true
        case .current(let stale), .inactive(let stale): return stale
        case .exhausted, .unlimited: return false
        }
    }
}
