import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

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
                else if snapshots.contains(where: { $0.issue != nil || ($0.fetchedAt != nil && $0.isStale(window: $0.weekly, now: now)) }) {
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
    private func providerRow(_ id: ProviderID) -> some View {
        let snapshot = snapshots.first(where: { $0.provider == id }) ?? UsageSnapshot(provider: id)
        // A past reset does not tell us the new window's usage. Keep the cached
        // record for diagnostics, but never present it as the current allowance.
        let weekly = snapshot.weekly.flatMap { $0.isExpired(at: now) ? nil : $0 }
        let fiveHour = snapshot.fiveHour.flatMap { $0.isExpired(at: now) ? nil : $0 }
        let accent = id == .claude ? Color(red: 1, green: 0.70, blue: 0.47) : Color(red: 0.61, green: 0.84, blue: 1)
        return HStack(alignment: .top, spacing: 9) {
            ProviderLogo(id: id).foregroundStyle(accent).frame(width: 39, height: 39, alignment: .leading).padding(.top, 3)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(id.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 6)
                    if let weekly {
                        HStack(spacing: 4) {
                            Image(systemName: "timer").font(.system(size: 9))
                            Text(weekly.countdown(now: now)).font(.system(size: 11)).monospacedDigit()
                        }.foregroundStyle(WidgetInk(0.84))
                            .help(L("Сброс недельного лимита: ") + resetDescription(weekly))
                            .padding(.trailing, 6)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(weekly.map { String(Int($0.remaining.rounded())) } ?? "—").font(.system(size: 25, weight: .semibold)).monospacedDigit()
                        if weekly != nil { Text(PercentText.sign()).font(.system(size: 12)) }
                    }.opacity(snapshot.isStale(window: snapshot.weekly, now: now) ? 0.6 : 1)
                }.frame(height: 23).lineLimit(1)
                bar(weekly, accent: accent, height: 5).opacity(snapshot.isStale(window: snapshot.weekly, now: now) ? 0.5 : 1).padding(.top, 7)
                HStack(spacing: 6) {
                    if weekly == nil || snapshot.isStale(window: snapshot.weekly, now: now) {
                        Text(widgetQuotaStatus(snapshot, now: now)).font(.system(size: 9))
                            .foregroundStyle(WidgetInk(0.78)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if preferences.showFiveHour {
                        Text(L("5 ч") + " · " + (fiveHour.map { PercentText.format(Int($0.remaining.rounded())) } ?? "—"))
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(WidgetInk(0.78)).fixedSize()
                    }
                    Spacer(minLength: 0)
                    if !demo, snapshot.isStale(window: snapshot.weekly, now: now), let fetched = snapshot.fetchedAt {
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
    private var weekly: QuotaWindow? { snapshot.weekly.flatMap { $0.isExpired(at: now) ? nil : $0 } }
    private var five: QuotaWindow? { snapshot.fiveHour.flatMap { $0.isExpired(at: now) ? nil : $0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.provider.title).font(.system(size: compact ? 13 : 15, weight: .semibold))
                Spacer(minLength: 4)
                if snapshot.issue != nil || (snapshot.fetchedAt != nil && snapshot.isStale(window: snapshot.weekly, now: now)) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ProviderLogo(id: snapshot.provider).foregroundStyle(activityAccent(snapshot.provider)).scaleEffect(0.75).frame(width: 24, height: 24)
            }.frame(height: 24)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(weekly.map { PercentText.format(Int($0.remaining.rounded())) } ?? "—")
                    .font(.system(size: compact ? 28 : 36, weight: .semibold)).monospacedDigit()
                    .opacity(snapshot.isStale(window: snapshot.weekly, now: now) ? 0.6 : 1)
                if !compact { Text(L("Недельный остаток")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.lineLimit(1).minimumScaleFactor(0.8)
            if compact { Text(L("Недельный остаток")).font(.system(size: 9)).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetInk(0.12, increased: 0.3))
                    if let weekly { Capsule().fill(activityAccent(snapshot.provider)).frame(width: geometry.size.width * weekly.remaining / 100) }
                }
            }.frame(height: 5).opacity(snapshot.isStale(window: snapshot.weekly, now: now) ? 0.5 : 1).accessibilityLabel(L("Осталось"))
                .accessibilityValue(weekly.map { PercentText.format(Int($0.remaining.rounded())) } ?? L("Нет данных"))
            if preferences.showFiveHour {
                HStack {
                    Text(L("5 ч"))
                    Spacer()
                    Text(five.map { PercentText.format(Int($0.remaining.rounded())) } ?? "—").monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(
                snapshot.isStale(window: snapshot.weekly, now: now) || weekly == nil
                    ? widgetQuotaStatus(snapshot, now: now)
                    : weekly.map { L("Сброс через {0}", $0.countdown(now: now)) } ?? L("Ждём лимиты")
            )
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            if snapshot.isStale(window: snapshot.weekly, now: now), let fetched = snapshot.fetchedAt {
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

/// A compact state label is always visible, including with five-hour values.
/// The full source and diagnostic remain available to help and accessibility.
func widgetQuotaStatus(_ snapshot: UsageSnapshot, now: Date) -> String {
    guard let weekly = snapshot.weekly, !weekly.isExpired(at: now) else {
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
