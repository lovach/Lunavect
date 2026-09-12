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
                else if snapshots.contains(where: { $0.issue != nil || ($0.fetchedAt != nil && $0.isStale(now: now)) }) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        .help(L("Некоторые данные не обновились. Откройте настройки для подробностей."))
                }
            }.foregroundStyle(.white.opacity(0.85)).frame(height: 12).padding(.bottom, 8)
            providerRow(.claude)
            Spacer().frame(height: max(4, min(16, size.height - 154)))
            providerRow(.codex)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .overlay {
            if drawsOutline {
                RoundedRectangle(cornerRadius: 26).stroke(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
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
                    if let date = preferences.subscriptionDates[id.rawValue], !date.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 9))
                            Text(L("до ") + displayDate(date)).font(.system(size: 9)).fixedSize()
                        }.foregroundStyle(.white.opacity(0.78)).padding(.leading, 6)
                            .help(L("Срок подписки указан вручную: {0}", date))
                    }
                    Spacer(minLength: 6)
                    if let weekly {
                        HStack(spacing: 4) {
                            Image(systemName: "timer").font(.system(size: 9))
                            Text(weekly.countdown(now: now)).font(.system(size: 11)).monospacedDigit()
                        }.foregroundStyle(.white.opacity(0.84))
                            .help(L("Сброс недельного лимита: ") + resetDescription(weekly))
                            .padding(.trailing, 6)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(weekly.map { String(Int($0.remaining.rounded())) } ?? "—").font(.system(size: 25, weight: .semibold)).monospacedDigit()
                        if weekly != nil { Text("%").font(.system(size: 12)) }
                    }
                }.frame(height: 23).lineLimit(1)
                bar(weekly, accent: accent, height: 5).padding(.top, 7)
                HStack(spacing: 7) {
                    if preferences.showFiveHour {
                        Text(L("5 ч")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                        bar(fiveHour, accent: accent, height: 2).frame(width: 43)
                        Text(fiveHour.map { "\(Int($0.remaining.rounded()))%" } ?? "—").font(.system(size: 10)).monospacedDigit()
                    } else if weekly == nil {
                        Text(snapshot.fetchedAt == nil ? L("Подключите в настройках") : L("Недельный лимит недоступен")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    if !demo, snapshot.isStale(now: now), let fetched = snapshot.fetchedAt {
                        Text(L("Данные: {0}", fetched.formatted(Calendar.current.isDate(fetched, inSameDayAs: now) ? .dateTime.hour().minute().locale(L10n.locale) : .dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale))))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            .help(L("Показаны последние полученные лимиты. Они обновятся, когда источник передаст новые данные."))
                    }
                }.frame(height: 14).padding(.top, 6)
                    .help(fiveHour.map { L("5-часовой лимит: сброс ") + resetDescription($0) } ?? L("Источник не предоставил 5-часовой лимит"))
            }
        }.frame(height: 55).accessibilityElement(children: .contain)
    }
    private func bar(_ window: QuotaWindow?, accent: Color, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if let window { Capsule().fill(accent).frame(width: geometry.size.width * window.remaining / 100) }
            }
        }.frame(height: height).accessibilityLabel(L("Осталось")).accessibilityValue(window.map { L("{0} процентов", String(Int($0.remaining.rounded()))) } ?? L("Нет данных"))
    }
    private func displayDate(_ iso: String) -> String {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return "—" }
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.setLocalizedDateFormatFromTemplate("MMdd")
        return formatter.string(from: date)
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
                if !compact, let date = preferences.subscriptionDates[snapshot.provider.rawValue] {
                    Text(L("до ") + subscriptionDate(date)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        .help(L("Срок подписки указан вручную: {0}", date))
                }
                Spacer(minLength: 4)
                if snapshot.issue != nil || (snapshot.fetchedAt != nil && snapshot.isStale(now: now)) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ProviderLogo(id: snapshot.provider).foregroundStyle(activityAccent(snapshot.provider)).scaleEffect(0.75).frame(width: 24, height: 24)
            }.frame(height: 24)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .font(.system(size: compact ? 28 : 36, weight: .semibold)).monospacedDigit()
                if !compact { Text(L("Недельный остаток")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.lineLimit(1).minimumScaleFactor(0.8)
            if compact { Text(L("Недельный остаток")).font(.system(size: 9)).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if let weekly { Capsule().fill(activityAccent(snapshot.provider)).frame(width: geometry.size.width * weekly.remaining / 100) }
                }
            }.frame(height: 5).accessibilityLabel(L("Осталось"))
                .accessibilityValue(weekly.map { L("{0} процентов", String(Int($0.remaining.rounded()))) } ?? L("Нет данных"))
            if preferences.showFiveHour {
                HStack {
                    Text(L("5 ч"))
                    Spacer()
                    Text(five.map { "\(Int($0.remaining.rounded()))%" } ?? "—").monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(weekly.map { L("Сброс через {0}", $0.countdown(now: now)) } ?? L("Ждём лимиты"))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            if snapshot.isStale(now: now), let fetched = snapshot.fetchedAt {
                Text(L("Данные: {0}", fetched.formatted(Calendar.current.isDate(fetched, inSameDayAs: now) ? .dateTime.hour().minute().locale(L10n.locale) : .dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale))))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }.padding(14).foregroundStyle(.white)
    }
    private func subscriptionDate(_ value: String) -> String {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return "—" }
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.setLocalizedDateFormatFromTemplate("MMdd")
        return formatter.string(from: date)
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
    private static let images: [ProviderID: NSImage] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { id in
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
