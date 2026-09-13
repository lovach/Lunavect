import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum MenuBarLimitsProvider: String, Codable, CaseIterable, Identifiable {
    case connected, claude, codex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connected: return L("Все подключённые")
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
    func includes(_ provider: ProviderID) -> Bool { self == .connected || rawValue == provider.rawValue }
}

enum MenuBarLimitsPeriod: String, Codable, CaseIterable, Identifiable {
    case weekly, fiveHour
    var id: String { rawValue }
    var title: String { L(self == .weekly ? "Неделя" : "5 ч") }
    func window(in snapshot: UsageSnapshot) -> QuotaWindow? { self == .weekly ? snapshot.weekly : snapshot.fiveHour }
}

enum MenuBarLimitsStyle: String, Codable, CaseIterable, Identifiable {
    case bars, percentages, rings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: return L("Шкалы и проценты")
        case .percentages: return L("Иконки и проценты")
        case .rings: return L("Кольца")
        }
    }
    var explanation: String {
        switch self {
        case .bars: return L("Проценты и шкала показывают остаток. Подробности — по нажатию.")
        case .percentages: return L("Компактный вид без шкал: иконки и остаток в процентах. Подробности — по нажатию.")
        case .rings: return L("Заполнение кольца показывает остаток. Проценты и время до сброса доступны по нажатию.")
        }
    }
}

enum MenuBarLimitsColor: String, Codable, CaseIterable, Identifiable {
    case system, provider
    var id: String { rawValue }
    var title: String { L(self == .system ? "Системный" : "Цвет сервиса") }
}

struct MenuBarLimitsPreferences: Codable, Equatable {
    var enabled: Bool
    var provider: MenuBarLimitsProvider
    var period: MenuBarLimitsPeriod
    var style: MenuBarLimitsStyle
    var iconColor: MenuBarLimitsColor
    var meterColor: MenuBarLimitsColor
    var showsResetCountdown: Bool
    init(enabled: Bool = false, provider: MenuBarLimitsProvider = .connected,
         period: MenuBarLimitsPeriod = .weekly, style: MenuBarLimitsStyle = .bars,
         iconColor: MenuBarLimitsColor = .system, meterColor: MenuBarLimitsColor = .provider,
         showsResetCountdown: Bool = false) {
        self.enabled = enabled; self.provider = provider; self.period = period; self.style = style
        self.iconColor = iconColor; self.meterColor = meterColor
        self.showsResetCountdown = showsResetCountdown
    }
    private enum CodingKeys: String, CodingKey { case enabled, provider, period, style, iconColor, meterColor, showsResetCountdown }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = try values.decodeIfPresent(MenuBarLimitsProvider.self, forKey: .provider) ?? .connected
        period = try values.decodeIfPresent(MenuBarLimitsPeriod.self, forKey: .period) ?? .weekly
        style = try values.decodeIfPresent(MenuBarLimitsStyle.self, forKey: .style) ?? .bars
        // Preserve the existing monochrome logos and colored meters on upgrade.
        iconColor = try values.decodeIfPresent(MenuBarLimitsColor.self, forKey: .iconColor) ?? .system
        meterColor = try values.decodeIfPresent(MenuBarLimitsColor.self, forKey: .meterColor) ?? .provider
        showsResetCountdown = try values.decodeIfPresent(Bool.self, forKey: .showsResetCountdown) ?? false
    }
}

struct MenuBarLimitEntry: Equatable, Identifiable {
    var id: ProviderID { provider }
    let provider: ProviderID
    let remaining: Double?
    let countdown: String
    let compactCountdown: String
    let resetDate: String?
    let fetchedAt: Date?
    let stale: Bool
    let value: String
    let detail: String

    static func make(snapshots: [UsageSnapshot], providers: [ProviderID], preferences: MenuBarLimitsPreferences,
                     now: Date = Date()) -> [Self] {
        ProviderID.allCases.filter { providers.contains($0) && preferences.provider.includes($0) }.map { provider in
            let snapshot = snapshots.first { $0.provider == provider } ?? UsageSnapshot(provider: provider)
            let window = preferences.period.window(in: snapshot).flatMap { $0.isExpired(at: now) ? nil : $0 }
            let stale = snapshot.isStale(window: window, now: now)
            let percent = window.map { String(Int($0.remaining.rounded())) }
            let value = percent.map { $0 + "%" + (stale ? "*" : "") } ?? "—"
            // This is time until the actual reset, never the duration of the quota window.
            let countdown = window?.countdown(now: now) ?? "—"
            let resetDate = window?.resetsAt?.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))
            var detail = [provider.title + " · " + preferences.period.title,
                          percent.map { L("Осталось {0}%", $0) } ?? L("Нет данных")]
            if let resetDate { detail.append(L("Сброс через {0}", countdown)); detail.append(resetDate) }
            if stale && window != nil { detail.append(L("Показаны последние полученные данные")) }
            if let fetchedAt = snapshot.fetchedAt {
                detail.append(L("Последние данные: {0}", fetchedAt.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))))
            }
            return Self(provider: provider, remaining: window?.remaining, countdown: countdown,
                        compactCountdown: compactCountdown(window: window, now: now), resetDate: resetDate,
                        fetchedAt: snapshot.fetchedAt, stale: stale, value: value, detail: detail.joined(separator: "\n"))
        }
    }
    private static func compactCountdown(window: QuotaWindow?, now: Date) -> String {
        guard let reset = window?.resetsAt, reset > now else { return "—" }
        let minutes = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return L("{0}д {1}ч", String(minutes / 1440), String(minutes % 1440 / 60)) }
        if minutes >= 60 { return L("{0}ч {1}м", String(minutes / 60), String(minutes % 60)) }
        return L("{0}м", String(minutes))
    }
}

@MainActor final class MenuBarLimitsContent: NSView {
    var entries: [MenuBarLimitEntry] = [] { didSet { needsDisplay = true } }
    var style: MenuBarLimitsStyle = .bars { didSet { needsDisplay = true } }
    var iconColor: MenuBarLimitsColor = .system { didSet { needsDisplay = true } }
    var meterColor: MenuBarLimitsColor = .provider { didSet { needsDisplay = true } }
    var showsResetCountdown = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // Equal provider slots reserve the widest percentage, including its stale marker.
    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: bounds.height >= 26 ? 12 : 10.5, weight: .semibold) }
    private var countdownFont: NSFont { .monospacedDigitSystemFont(ofSize: bounds.height >= 26 ? 9 : 8, weight: .medium) }
    private var logoSize: CGFloat { bounds.height >= 26 ? 16 : 14 }
    private var edgeInset: CGFloat { style == .percentages ? 3 : 4 }
    private var iconTextSpacing: CGFloat { style == .percentages ? 4 : 7 }
    private var providerSpacing: CGFloat { style == .percentages ? 8 : 12 }
    private func countdown(_ entry: MenuBarLimitEntry) -> String { entry.resetDate == nil ? "—" : entry.compactCountdown }
    private var textColumnWidth: CGFloat {
        // Reserve the countdown column even when hidden, so both providers and
        // neighbouring menu bar items keep their positions when it is toggled.
        let longest = entries.map { (countdown($0) as NSString).size(withAttributes: [.font: countdownFont]).width }.max() ?? 0
        let widestValue = ("100%*" as NSString).size(withAttributes: [.font: valueFont]).width
        if style == .percentages { return ceil(widestValue) }
        return ceil(max(longest, widestValue))
    }
    private var barBlockWidth: CGFloat { logoSize + iconTextSpacing + textColumnWidth }
    var slotWidth: CGFloat { style == .rings ? 34 : barBlockWidth + providerSpacing }
    var preferredWidth: CGFloat {
        guard style != .rings, !entries.isEmpty else { return CGFloat(entries.count) * slotWidth }
        return edgeInset * 2 + CGFloat(entries.count) * barBlockWidth + CGFloat(entries.count - 1) * providerSpacing
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    private func accent(_ provider: ProviderID) -> NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return provider == .claude
            ? NSColor(srgbRed: dark ? 0.94 : 0.65, green: dark ? 0.66 : 0.31, blue: dark ? 0.47 : 0.15, alpha: 1)
            : NSColor(srgbRed: dark ? 0.41 : 0.06, green: dark ? 0.76 : 0.44, blue: dark ? 0.99 : 0.73, alpha: 1)
    }
    private func logo(_ provider: ProviderID, in rect: NSRect) {
        guard let original = ProviderLogo.images[provider] else { return }
        let tint = iconColor == .system ? NSColor.labelColor : accent(provider)
        let image = NSImage(size: rect.size, flipped: false) { target in
            original.draw(in: target)
            tint.setFill()
            target.fill(using: .sourceAtop)
            return true
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private func drawText(_ text: String, font: NSFont, color: NSColor = .labelColor, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, entry) in entries.enumerated() {
            let x = CGFloat(index) * slotWidth
            let tint = (meterColor == .system ? NSColor.labelColor : accent(entry.provider))
                .withAlphaComponent(entry.stale ? 0.5 : 1)
            if style == .rings {
                let diameter = min(26, bounds.height - 2)
                let center = NSPoint(x: x + slotWidth / 2, y: bounds.midY)
                let radius = diameter / 2 - 1.5
                let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                track.lineWidth = 2.5
                if entry.remaining == nil || entry.stale { track.setLineDash([1.5, 2], count: 2, phase: 0) }
                NSColor.labelColor.withAlphaComponent(0.18).setStroke(); track.stroke()
                if let remaining = entry.remaining, remaining > 0 {
                    let arc = NSBezierPath(); arc.lineWidth = 2.5
                    arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + CGFloat(remaining) * 3.6)
                    if entry.stale { arc.setLineDash([2, 2], count: 2, phase: 0) }
                    tint.setStroke(); arc.stroke()
                }
                let logoSize = diameter * 0.46
                logo(entry.provider, in: NSRect(x: center.x - logoSize / 2, y: center.y - logoSize / 2, width: logoSize, height: logoSize))
                continue
            }
            if style == .percentages {
                let contentX = x + edgeInset
                logo(entry.provider, in: NSRect(x: contentX, y: bounds.midY - logoSize / 2, width: logoSize, height: logoSize))
                let textHeight = ("100%*" as NSString).size(withAttributes: [.font: valueFont]).height
                drawText(entry.value, font: valueFont,
                         in: NSRect(x: contentX + logoSize + iconTextSpacing, y: bounds.midY - textHeight / 2,
                                    width: textColumnWidth, height: textHeight))
                continue
            }
            let timeFont = countdownFont
            let valueHeight = ("100%*" as NSString).size(withAttributes: [.font: valueFont]).height
            let timeHeight = ("0" as NSString).size(withAttributes: [.font: timeFont]).height
            let trackHeight: CGFloat = bounds.height >= 26 ? 2 : 1.5
            // Keep the same icon center and track baseline with or without time.
            // Text rectangles share unused font leading in a 22-point menu bar.
            let rowOverlap: CGFloat = bounds.height >= 26 ? 2 : 3
            let textHeight = valueHeight + timeHeight - rowOverlap
            let trackGap: CGFloat = 1
            let trackY = min(bounds.height - trackHeight - 0.5,
                             (bounds.height + textHeight + trackGap - trackHeight) / 2)
            let top = trackY - trackGap - textHeight
            let contentX = x + edgeInset
            let textX = contentX + logoSize + iconTextSpacing
            logo(entry.provider, in: NSRect(x: contentX, y: top + (textHeight - logoSize) / 2, width: logoSize, height: logoSize))
            let valueY = showsResetCountdown ? top : top + (textHeight - valueHeight) / 2
            drawText(entry.value, font: valueFont, in: NSRect(x: textX, y: valueY, width: textColumnWidth, height: valueHeight))
            let track = NSRect(x: contentX, y: trackY, width: barBlockWidth, height: trackHeight)
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            if let remaining = entry.remaining {
                if remaining > 0 {
                    tint.setFill()
                    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * remaining / 100, height: track.height), xRadius: 1, yRadius: 1).fill()
                }
            } else {
                NSColor.labelColor.withAlphaComponent(0.38).setFill()
                for offset in stride(from: CGFloat(0), to: track.width, by: 5) {
                    NSRect(x: track.minX + offset, y: track.minY, width: 2, height: track.height).fill()
                }
            }
            if showsResetCountdown {
                drawText(countdown(entry), font: timeFont, color: .secondaryLabelColor,
                         in: NSRect(x: textX, y: top + valueHeight - rowOverlap, width: textColumnWidth, height: timeHeight + 1))
            }
        }
    }
}

@MainActor final class MenuBarLimitsPanelModel: ObservableObject {
    @Published var entries: [MenuBarLimitEntry] = []
    @Published var period: MenuBarLimitsPeriod = .weekly
    @Published var iconColor: MenuBarLimitsColor = .system
    @Published var meterColor: MenuBarLimitsColor = .provider
    @Published var refreshing = false
}

@MainActor final class MenuBarLimitsController: NSObject, NSPopoverDelegate {
    private(set) var statusItem: NSStatusItem?
    let content = MenuBarLimitsContent(frame: .zero)
    let popover = NSPopover()
    let panel = MenuBarLimitsPanelModel()
    private let dismissal = SessionPopoverDismissal()
    private var snapshots: [UsageSnapshot] = []
    private var providers: [ProviderID] = []
    private var preferences = MenuBarLimitsPreferences()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let onOpenLimits: () -> Void
    private let onOpenMenu: () -> Void
    private let onSelectPeriod: (MenuBarLimitsPeriod) -> Void
    private let onRefresh: () -> Void
    private let onShow: () -> Void
    private let onHide: () -> Void
    private let contextMenu: (() -> NSMenu)?
    private let autosaveName: String?

    init(onSelectPeriod: @escaping (MenuBarLimitsPeriod) -> Void = { _ in }, onRefresh: @escaping () -> Void = {},
         onShow: @escaping () -> Void = {}, onHide: @escaping () -> Void = {}, onOpenMenu: @escaping () -> Void = {},
         contextMenu: (() -> NSMenu)? = nil,
         autosaveName: String? = "LunavectLimits",
         onOpenLimits: @escaping () -> Void) {
        self.onOpenLimits = onOpenLimits; self.onSelectPeriod = onSelectPeriod; self.onRefresh = onRefresh
        self.onOpenMenu = onOpenMenu
        self.contextMenu = contextMenu
        self.onShow = onShow; self.onHide = onHide; self.autosaveName = autosaveName
        super.init()
        popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarLimitsPopover(model: panel,
            onPeriod: { [weak self] in self?.selectPeriod($0) }, onRefresh: onRefresh,
            onMenu: { [weak self] in self?.close(); self?.onOpenMenu() },
            onSettings: { [weak self] in self?.close(); self?.onOpenLimits() }))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func update(snapshots: [UsageSnapshot], providers: [ProviderID], preferences: MenuBarLimitsPreferences,
                refreshing: Bool = false, now: Date = Date()) {
        self.snapshots = snapshots; self.providers = providers; self.preferences = preferences; panel.refreshing = refreshing
        refresh(now: now)
        if statusItem != nil && timer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            timer.tolerance = 2; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        } else if statusItem == nil { timer?.invalidate(); timer = nil }
    }
    func refresh(now: Date = Date()) {
        let entries = preferences.enabled ? MenuBarLimitEntry.make(snapshots: snapshots, providers: providers, preferences: preferences, now: now) : []
        panel.entries = entries; panel.period = preferences.period
        panel.iconColor = preferences.iconColor; panel.meterColor = preferences.meterColor
        guard !entries.isEmpty else {
            close()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil; content.entries = []; content.removeFromSuperview()
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = autosaveName; item.button?.target = self; item.button?.action = #selector(togglePopover)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            content.autoresizingMask = [.width, .height]; content.setAccessibilityElement(false)
            item.button?.addSubview(content); statusItem = item
        }
        guard let item = statusItem, let button = item.button else { return }
        content.frame = button.bounds; content.entries = entries; content.style = preferences.style
        content.iconColor = preferences.iconColor; content.meterColor = preferences.meterColor
        content.showsResetCountdown = preferences.showsResetCountdown
        if !popover.isShown { item.length = content.preferredWidth }
        content.frame = button.bounds
        button.toolTip = entries.map(\.detail).joined(separator: "\n\n")
        button.setAccessibilityLabel(L("Лимиты") + ". " + entries.map(\.detail).joined(separator: ". "))
        if popover.isShown { sizePopoverToContent() }
    }
    func selectPeriod(_ period: MenuBarLimitsPeriod) {
        preferences.period = period; onSelectPeriod(period); refresh()
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp, let item = statusItem, let menu = contextMenu?() {
            close(); item.menu = menu; item.button?.performClick(nil); item.menu = nil
            return
        }
        guard !popover.isShown else { close(); return }
        guard let button = statusItem?.button else { return }
        onShow()
        sizePopoverToContent()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func sizePopoverToContent() {
        guard let host = popover.contentViewController as? NSHostingController<MenuBarLimitsPopover> else { return }
        // Measure without the current window's size proposal. Translations and
        // saved-data notices can require more height than a fresh English panel.
        let measuringView = NSHostingView(rootView: host.rootView)
        popover.contentSize = NSSize(width: 340, height: ceil(measuringView.fittingSize.height))
    }
    func popoverDidShow(_ notification: Notification) { dismissal.start(for: popover) }
    func popoverDidClose(_ notification: Notification) {
        dismissal.stop(); onHide()
        if let statusItem { statusItem.length = content.preferredWidth }
    }
    func close() { popover.performClose(nil) }
    func stop() {
        close(); dismissal.stop(); timer?.invalidate(); timer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil; content.removeFromSuperview()
    }
    isolated deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

struct MenuBarLimitsPopover: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: MenuBarLimitsPanelModel
    let onPeriod: @MainActor (MenuBarLimitsPeriod) -> Void
    let onRefresh: () -> Void
    let onMenu: () -> Void
    let onSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Осталось")).font(.system(size: 19, weight: .semibold))
                Spacer()
                Button(action: onRefresh) {
                    if model.refreshing { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 18, height: 18) }
                }
                    .buttonStyle(.borderless).disabled(model.refreshing).help(L("Обновить лимиты"))
                    .accessibilityLabel(L("Обновить лимиты")).accessibilityIdentifier("menu-limits-refresh")
                Button(action: onMenu) {
                    Image(systemName: "slider.horizontal.3").frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless).help(L("Строка меню"))
                .accessibilityLabel(L("Строка меню")).accessibilityIdentifier("menu-limits-menu")
            }
            Picker(L("Период"), selection: Binding(get: { model.period }, set: { onPeriod($0) })) {
                ForEach(MenuBarLimitsPeriod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("menu-limits-panel-period")
            ForEach(model.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProviderLogo(id: entry.provider).scaleEffect(0.65).frame(width: 22, height: 22)
                            .foregroundStyle(model.iconColor == .system ? Color.primary : activityAccent(entry.provider, adaptive: true, scheme: scheme))
                        Text(entry.provider.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(entry.value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        Capsule().fill(Color.primary.opacity(0.1))
                        if let remaining = entry.remaining {
                            Capsule().fill((model.meterColor == .system ? Color.primary : activityAccent(entry.provider, adaptive: true, scheme: scheme))
                                .opacity(entry.stale ? 0.5 : 1))
                                .frame(width: geometry.size.width * remaining / 100)
                        }
                    }.frame(height: 6).accessibilityHidden(true)
                    if let resetDate = entry.resetDate {
                        Text(L("Сброс через {0}", entry.countdown)).font(.system(size: 12, weight: .medium))
                        Text(resetDate).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text(L(entry.remaining == nil ? "Нет данных" : "Время сброса неизвестно"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if entry.stale, entry.remaining != nil {
                        Text(L("Показаны последние полученные данные")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            HStack {
                Text(L("Заполнение показывает остаток"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Подробнее"), action: onSettings).buttonStyle(.link).font(.system(size: 11))
            }
        }.padding(18).frame(width: 340, alignment: .topLeading)
    }
}

struct MenuBarLimitsSettings: View {
    @ObservedObject var appearance: MenuBarAppearance
    let snapshots: [UsageSnapshot]
    let providers: [ProviderID]
    var body: some View {
        GroupBox(L("Лимиты в строке меню")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $appearance.limits.enabled) {
                    Text(L("Показывать остаток лимитов")).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("menu-bar-limits-enabled")
                Group {
                    SettingsChoiceRow(L("Формат индикатора")) {
                        Picker(L("Формат индикатора"), selection: $appearance.limits.style) {
                            ForEach(MenuBarLimitsStyle.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("menu-bar-limits-style")
                    }
                    Text(appearance.limits.style.explanation)
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if appearance.limits.style == .bars {
                        Toggle(L("Показывать время до сброса"), isOn: $appearance.limits.showsResetCountdown)
                            .accessibilityIdentifier("menu-bar-limits-countdown")
                    }
                    SettingsRow(L("Сервис")) {
                        Picker(L("Сервис"), selection: $appearance.limits.provider) {
                            ForEach(MenuBarLimitsProvider.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityIdentifier("menu-bar-limits-provider")
                    }
                    SettingsChoiceRow(L("Период")) {
                        Picker(L("Период"), selection: $appearance.limits.period) {
                            ForEach(MenuBarLimitsPeriod.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("menu-bar-limits-period")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        colorPicker("Цвет иконок", selection: $appearance.limits.iconColor, id: "menu-bar-limits-icon-color")
                        if appearance.limits.style != .percentages {
                            colorPicker(appearance.limits.style == .bars ? "Цвет шкал" : "Цвет колец",
                                        selection: $appearance.limits.meterColor, id: "menu-bar-limits-meter-color")
                        }
                    }
                    Text(L("Системный цвет подстраивается под светлую и тёмную строку меню."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let entries = MenuBarLimitEntry.make(snapshots: snapshots, providers: providers, preferences: appearance.limits, now: context.date)
                        if entries.isEmpty {
                            Text(L("Подключите выбранный сервис в настройках подключений.")).font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            MenuBarLimitsPreview(entries: entries, style: appearance.limits.style,
                                                 iconColor: appearance.limits.iconColor, meterColor: appearance.limits.meterColor,
                                                 showsResetCountdown: appearance.limits.showsResetCountdown)
                                .frame(height: NSStatusBar.system.thickness)
                                .padding(10).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    Text(L(appearance.limits.style != .rings
                           ? "Текущие данные. Звёздочка означает сохранённое значение; прочерк — недоступный лимит."
                           : "Прерывистое кольцо означает сохранённые или недоступные данные. Подробности — по нажатию."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(InterfaceMetrics.settingsContentInset).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func colorPicker(_ title: String, selection: Binding<MenuBarLimitsColor>, id: String) -> some View {
        SettingsChoiceRow(L(title)) {
            Picker(L(title), selection: selection) {
                ForEach(MenuBarLimitsColor.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier(id)
        }
    }
}

struct MenuBarLimitsPreview: NSViewRepresentable {
    let entries: [MenuBarLimitEntry]
    var style: MenuBarLimitsStyle = .bars
    var iconColor: MenuBarLimitsColor = .system
    var meterColor: MenuBarLimitsColor = .provider
    var showsResetCountdown = false
    func makeNSView(context: Context) -> MenuBarLimitsContent { MenuBarLimitsContent(frame: NSRect(x: 0, y: 0, width: 192, height: NSStatusBar.system.thickness)) }
    func updateNSView(_ view: MenuBarLimitsContent, context: Context) {
        view.entries = entries; view.style = style; view.iconColor = iconColor; view.meterColor = meterColor
        view.showsResetCountdown = showsResetCountdown
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarLimitsContent, context: Context) -> CGSize? {
        CGSize(width: nsView.preferredWidth, height: NSStatusBar.system.thickness)
    }
}
