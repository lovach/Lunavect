import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// The camera housing of a screen, read from the screen's own safe area: the
/// menu-bar strips left and right of the housing end where the housing begins.
struct NotchGeometry: Equatable {
    /// The housing in screen coordinates. A screen without one gets a narrow
    /// gap of the menu bar's height at the top centre, between the island's ears.
    let notch: CGRect
    let hasNotch: Bool

    static func make(frame: CGRect, safeTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?,
                     menuBarHeight: CGFloat) -> NotchGeometry {
        if safeTop > 0, let leftArea, let rightArea, rightArea.minX - leftArea.maxX > 40 {
            return NotchGeometry(notch: CGRect(x: leftArea.maxX, y: frame.maxY - safeTop,
                                               width: rightArea.minX - leftArea.maxX, height: safeTop), hasNotch: true)
        }
        let height = max(22, menuBarHeight), width: CGFloat = 8
        return NotchGeometry(notch: CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height),
                             hasNotch: false)
    }

    @MainActor static func make(_ screen: NSScreen) -> NotchGeometry {
        make(frame: screen.frame, safeTop: screen.safeAreaInsets.top, leftArea: screen.auxiliaryTopLeftArea,
             rightArea: screen.auxiliaryTopRightArea, menuBarHeight: NSStatusBar.system.thickness)
    }

    /// The screen with a housing, otherwise the screen with the menu bar.
    @MainActor static var preferredScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } ?? NSScreen.screens.first
    }
}

struct IslandRow: Identifiable, Equatable {
    let id: String
    let title: String
    let activity: String
    let phase: SessionPhase
    let provider: ProviderID
    /// Where the row's clock starts: the turn while working, the request while waiting.
    let since: Date?
    var waiting: Bool { phase == .permission || phase == .input }
}

/// What the island shows: sessions waiting for the owner first, then working
/// ones, then finished answers. Idle and stale sessions stay in the panel only.
struct IslandSummary: Equatable {
    var rows: [IslandRow] = []
    var working = 0, waiting = 0, ready = 0
    /// Something for the closed island's ears to show.
    var hasSignal: Bool { working + waiting + ready > 0 }
    static let shownPhases: Set<SessionPhase> = [.permission, .input, .running, .failed, .ready]

    static func make(_ sessions: [AgentSession], now: Date = Date()) -> IslandSummary {
        let current = sessions.filter { $0.isCurrent(now: now) }
            .map { ($0, $0.effectivePhase(now: now)) }
            .filter { shownPhases.contains($0.1) }
            .sorted { ($0.1.priority, $1.0.updatedAt) < ($1.1.priority, $0.0.updatedAt) }
        var summary = IslandSummary()
        summary.rows = current.map { session, phase in
            let waiting = phase == .permission || phase == .input
            return IslandRow(id: session.id, title: session.displayTitle,
                             activity: phase == session.phase ? session.activityTitle : phase.title,
                             phase: phase, provider: session.provider,
                             since: phase == .running ? session.turnStartedAt : waiting ? session.updatedAt : nil)
        }
        summary.working = current.filter { $0.1 == .running }.count
        summary.waiting = current.filter { $0.1 == .permission || $0.1 == .input }.count
        summary.ready = current.filter { $0.1 == .ready }.count
        return summary
    }
}

/// The week and five-hour remainders, the same values as the menu-bar limits.
struct IslandLimit: Equatable, Identifiable {
    var id: ProviderID { provider }
    let provider: ProviderID
    let week: String
    let fiveHour: String

    static func make(snapshots: [UsageSnapshot], providers: [ProviderID], now: Date = Date()) -> [IslandLimit] {
        var weekly = MenuBarLimitsPreferences(enabled: true); weekly.period = .weekly
        var short = weekly; short.period = .fiveHour
        let five = MenuBarLimitEntry.make(snapshots: snapshots, providers: providers, preferences: short, now: now)
        return MenuBarLimitEntry.make(snapshots: snapshots, providers: providers, preferences: weekly, now: now).map { entry in
            IslandLimit(provider: entry.provider, week: entry.value,
                        fiveHour: five.first { $0.provider == entry.provider }?.value ?? "—")
        }
    }
}

enum IslandLayout {
    static let ear: CGFloat = 48
    static let width: CGFloat = 420
    static let rowHeight: CGFloat = 46
    static let limitsHeight: CGFloat = 24
    static let moreHeight: CGFloat = 26
    static let maxRows = 6
    static let compactFlare: CGFloat = 6
    static let expandedFlare: CGFloat = 12
    /// Room for the open island's shadow.
    static let margin: CGFloat = 18

    static func compact(notch: CGSize, summary: IslandSummary) -> CGSize {
        CGSize(width: notch.width + (summary.hasSignal ? 2 * ear : 0), height: notch.height)
    }
    static func expanded(notch: CGSize, summary: IslandSummary, limits: Int) -> CGSize {
        let rows = CGFloat(max(1, min(maxRows, summary.rows.count)))
        let more: CGFloat = summary.rows.count > maxRows ? moreHeight : 0
        return CGSize(width: max(width, notch.width + 2 * ear),
                      height: notch.height + 6 + (limits > 0 ? limitsHeight : 0) + rows * rowHeight + more + 10)
    }
}

@MainActor final class IslandState: ObservableObject {
    @Published var summary = IslandSummary()
    @Published var limits: [IslandLimit] = []
    @Published var expanded = false
    @Published var notch = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
}

/// The housing's outline: concave top corners that meet the screen edge and
/// rounded bottom corners, so the island reads as part of the notch.
struct IslandShape: Shape {
    var flare: CGFloat
    var radius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 4, rect.height / 2)
        let r = max(0, min(radius, rect.height - f, (rect.width - 2 * f) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @ObservedObject var state: IslandState
    var onOpen: (String) -> Void
    var onOpenPanel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = state.expanded
        let size = expanded ? IslandLayout.expanded(notch: state.notch, summary: state.summary, limits: state.limits.count)
            : IslandLayout.compact(notch: state.notch, summary: state.summary)
        let flare = expanded ? IslandLayout.expandedFlare : IslandLayout.compactFlare
        ZStack(alignment: .top) {
            IslandShape(flare: flare, radius: expanded ? 22 : state.hasNotch ? 10 : size.height / 2)
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 14, y: 6)
            Group {
                if expanded { expandedContent.transition(.opacity) } else { compactContent.transition(.opacity) }
            }.padding(.horizontal, flare)
        }
        .frame(width: size.width + 2 * flare, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82), value: expanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: size)
        .environment(\.colorScheme, .dark)
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            leftEar.frame(width: IslandLayout.ear)
            Color.clear.frame(width: state.notch.width)
            rightEar.frame(width: IslandLayout.ear)
        }
        .frame(height: state.notch.height)
        .opacity(state.summary.hasSignal ? 1 : 0)
        .accessibilityElement(children: .ignore)
    }
    @ViewBuilder private var leftEar: some View {
        if state.summary.working > 0 {
            HStack(spacing: 5) {
                IslandActivityBars(color: .blue, animated: !reduceMotion)
                Text(String(state.summary.working)).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white)
            }
        }
    }
    @ViewBuilder private var rightEar: some View {
        if state.summary.waiting > 0 {
            HStack(spacing: 3) {
                IslandPulse(color: .orange, animated: !reduceMotion)
                Text(String(state.summary.waiting)).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Color.orange)
            }
        } else if state.summary.ready > 0 {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.green)
                Text(String(state.summary.ready)).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var expandedContent: some View {
        let rows = state.summary.rows
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: state.notch.height + 6)
            if !state.limits.isEmpty {
                IslandLimitsLine(limits: state.limits).padding(.horizontal, 12).frame(height: IslandLayout.limitsHeight)
            }
            if rows.isEmpty {
                Text(L("Нет сессий, которые работают или ждут вас")).font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity).frame(height: IslandLayout.rowHeight)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        ForEach(Array(rows.prefix(IslandLayout.maxRows))) { row in
                            IslandRowView(row: row, now: context.date) { onOpen(row.id) }
                        }
                    }
                }
            }
            if rows.count > IslandLayout.maxRows {
                Button(action: onOpenPanel) {
                    Text(L("Ещё {0} в панели", String(rows.count - IslandLayout.maxRows)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity).frame(height: IslandLayout.moreHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }
}

struct IslandRowView: View {
    let row: IslandRow
    let now: Date
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(row.activity + " · " + row.provider.title).font(.system(size: 11))
                        .foregroundStyle(row.waiting ? Color.orange : Color.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let clock {
                    Text(clock).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: IslandLayout.rowHeight)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(row.title + ", " + row.activity)
    }
    private var color: Color {
        switch row.phase {
        case .permission, .input: return .orange
        case .running: return .blue
        case .ready: return .green
        case .failed: return .red
        default: return .gray
        }
    }
    private var clock: String? {
        guard let since = row.since else { return nil }
        let s = max(0, Int(now.timeIntervalSince(since)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct IslandLimitsLine: View {
    let limits: [IslandLimit]
    var body: some View {
        HStack(spacing: 14) {
            Text(L("Осталось:")).foregroundStyle(.white.opacity(0.45))
            ForEach(limits) { limit in
                HStack(spacing: 6) {
                    Text(limit.provider.title).fontWeight(.semibold).foregroundStyle(.white.opacity(0.85))
                    Text(L("Неделя") + " " + limit.week).foregroundStyle(.white.opacity(0.6))
                    Text(L("5 ч") + " " + limit.fiveHour).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).monospacedDigit().lineLimit(1)
    }
}

/// Three bars that rise and fall while sessions work, drawn at 15 frames a second.
struct IslandActivityBars: View {
    var color: Color
    var animated: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(color).frame(width: 3, height: animated ? 5 + 7 * abs(sin(t * 3 + Double(index) * 0.9)) : 8)
                }
            }.frame(height: 12)
        }
    }
}

/// A dot with a fading ring: a session waits for the owner.
struct IslandPulse: View {
    var color: Color
    var animated: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animated)) { context in
            let phase = animated ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 1
            ZStack {
                Circle().fill(color.opacity(0.5 * (1 - phase))).frame(width: 8 + 10 * phase, height: 8 + 10 * phase)
                Circle().fill(color).frame(width: 8, height: 8)
            }.frame(width: 18, height: 18)
        }
    }
}

/// A click on a row of the open island acts at once, without first activating Lunavect.
final class IslandHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless panel around the camera housing. Closed, it lets every click
/// through; the pointer resting on it opens the session list, leaving closes it.
@MainActor final class NotchIslandController {
    let state = IslandState()
    private let onOpen: (String) -> Void
    private let onOpenPanel: () -> Void
    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var refreshTimer: Timer?
    private var trackTimer: Timer?
    private var pendingTimer: Timer?
    private var pendingExpand = false
    private var geometry: NotchGeometry?
    private var screenTop: CGFloat = 0
    private var enabled = false
    private var rows: [AgentSession] = []

    init(onOpen: @escaping (String) -> Void, onOpenPanel: @escaping () -> Void) {
        self.onOpen = onOpen; self.onOpenPanel = onOpenPanel
    }

    func start(sessions: SessionStore, store: AppStore, appearance: MenuBarAppearance) {
        sessions.$sessions.receive(on: DispatchQueue.main).sink { [weak self] rows in
            self?.rows = rows; self?.update()
        }.store(in: &subscriptions)
        store.$snapshots.combineLatest(store.$preferences.map(\.providers).removeDuplicates())
            .receive(on: DispatchQueue.main).sink { [weak self] snapshots, providers in
                guard let self else { return }
                let limits = IslandLimit.make(snapshots: snapshots, providers: providers)
                if limits != self.state.limits { self.state.limits = limits; self.layout() }
            }.store(in: &subscriptions)
        appearance.$showsNotchIsland.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            self?.setEnabled(on)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }.store(in: &subscriptions)
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            if panel == nil { makePanel() }
            installMonitors()
            // Phases expire with time (a stale row turns unknown) without a new store value.
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.update() }
            }
            update()
        } else {
            collapse()
            removeMonitors()
            refreshTimer?.invalidate(); refreshTimer = nil
            panel?.orderOut(nil)
        }
    }

    private func update() {
        let summary = IslandSummary.make(rows)
        if summary != state.summary { state.summary = summary }
        layout()
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let view = IslandView(state: state,
                              onOpen: { [weak self] id in self?.collapse(); self?.onOpen(id) },
                              onOpenPanel: { [weak self] in self?.collapse(); self?.onOpenPanel() })
        panel.contentView = IslandHostingView(rootView: view)
        self.panel = panel
    }

    private func layout() {
        guard enabled, let panel else { return }
        guard let screen = NotchGeometry.preferredScreen else { panel.orderOut(nil); return }
        let geometry = NotchGeometry.make(screen)
        self.geometry = geometry; screenTop = screen.frame.maxY
        if state.notch != geometry.notch.size { state.notch = geometry.notch.size }
        if state.hasNotch != geometry.hasNotch { state.hasNotch = geometry.hasNotch }
        let open = IslandLayout.expanded(notch: geometry.notch.size, summary: state.summary, limits: state.limits.count)
        let width = open.width + 2 * IslandLayout.expandedFlare + 2 * IslandLayout.margin
        let height = open.height + IslandLayout.margin
        let frame = CGRect(x: geometry.notch.midX - width / 2, y: screenTop - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Without a housing an idle island would be a black mark on the menu bar.
        if geometry.hasNotch || state.summary.hasSignal || state.expanded {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else { panel.orderOut(nil) }
    }

    /// The closed island in screen coordinates, the area that opens it.
    private var compactRect: CGRect? {
        guard let geometry, geometry.hasNotch || state.summary.hasSignal else { return nil }
        let size = IslandLayout.compact(notch: geometry.notch.size, summary: state.summary)
        let width = size.width + 2 * IslandLayout.compactFlare
        return CGRect(x: geometry.notch.midX - width / 2, y: screenTop - size.height - 2, width: width, height: size.height + 2)
    }
    private var expandedRect: CGRect? {
        guard let geometry else { return nil }
        let size = IslandLayout.expanded(notch: geometry.notch.size, summary: state.summary, limits: state.limits.count)
        let width = size.width + 2 * IslandLayout.expandedFlare
        return CGRect(x: geometry.notch.midX - width / 2, y: screenTop - size.height, width: width, height: size.height)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.track() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { guard let self else { return }; self.track() }
            return event
        }) { monitors.append(local) }
    }
    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    private func track() {
        guard enabled else { return }
        let point = NSEvent.mouseLocation
        if state.expanded {
            if let rect = expandedRect, rect.insetBy(dx: -8, dy: -8).contains(point) { cancelPending() }
            else { schedule(expand: false, after: 0.25) }
        } else if let rect = compactRect, rect.contains(point) {
            schedule(expand: true, after: 0.12)
        } else { cancelPending() }
    }
    private func schedule(expand: Bool, after delay: TimeInterval) {
        if pendingTimer != nil && pendingExpand == expand { return }
        pendingTimer?.invalidate()
        pendingExpand = expand
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingTimer = nil
                if expand { self.expand() } else { self.collapse() }
            }
        }
    }
    private func cancelPending() { pendingTimer?.invalidate(); pendingTimer = nil }

    private func expand() {
        guard enabled, !state.expanded, let panel else { return }
        layout()
        state.expanded = true
        panel.ignoresMouseEvents = false
        // Mouse events stop while the pointer rests; leaving is also checked on a timer.
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.track() }
        }
    }
    func collapse() {
        cancelPending()
        trackTimer?.invalidate(); trackTimer = nil
        guard state.expanded else { return }
        state.expanded = false
        panel?.ignoresMouseEvents = true
        layout()
    }
}
