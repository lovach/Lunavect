// Media-only entry point. Compiled in an isolated copy of the release source.
// Never connects providers, installs hooks, updates the installed app or reads sessions.
import AppKit
import SwiftUI
import WeekleftCore

@MainActor final class DemoState: ObservableObject {
    @Published var stage = 0
    let sessions: SessionStore
    let snapshots: [UsageSnapshot]
    var history = ActivityHistory()
    var preferences = WidgetPreferences()
    let now = Date()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LunavectMedia-" + UUID().uuidString)
    let defaults = UserDefaults(suiteName: "LunavectMedia-" + UUID().uuidString)!
    init() {
        sessions = SessionStore(directory: directory, defaults: defaults)
        preferences.enabledProviders = [.claude, .codex]; preferences.showFiveHour = true
        snapshots = try! [
            UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 32, durationMinutes: 10080, resetsAt: now.addingTimeInterval(259200)), fiveHour: QuotaWindow(usedPercent: 16, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)), fetchedAt: now, source: "Claude Code /usage"),
            UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 46, durationMinutes: 10080, resetsAt: now.addingTimeInterval(432000)), fiveHour: QuotaWindow(usedPercent: 9, durationMinutes: 300, resetsAt: now.addingTimeInterval(14400)), fetchedAt: now, source: "Codex app-server")
        ]
        let today = Calendar.current.startOfDay(for: now)
        _ = history.prepareImport(now: today)
        var intervals: [ActivityInterval] = []
        for day in -6...0 {
            for hour in [9, 10, 14, 15, 16] {
                let start = today.addingTimeInterval(Double(day * 86400 + hour * 3600))
                let end = min(now, start.addingTimeInterval(Double(((day + 8) * (hour + 3) % 35 + 15) * 60)))
                if end > start { intervals.append(.init(start: start, end: end, providers: hour < 12 ? 1 : hour == 15 ? 3 : 2)) }
            }
        }
        history.mergeRecovered(intervals, now: now, limited: false)
        setStage(0)
    }
    func setStage(_ value: Int) {
        stage = value
        let time = Date()
        var working = AgentSession(provider: .claude, sessionID: "sample-onboarding", title: "Build the onboarding flow", cwd: "/Users/demo/Projects/Lunavect", client: .desktop, phase: .running, updatedAt: time, observedAt: time, runtimeConfirmed: true)
        working.turnStartedAt = time.addingTimeInterval(-72)
        let task = AgentSession(provider: .codex, sessionID: "sample-release", title: "Review the release checklist", cwd: "/Users/demo/Projects/Lunavect", client: .desktop, phase: value == 0 ? .running : value == 1 ? .permission : .ready, updatedAt: time, observedAt: time, runtimeConfirmed: true)
        let done = AgentSession(provider: .codex, sessionID: "sample-settings", title: "Polish the settings screen", cwd: "/Users/demo/Projects/Atlas", client: .desktop, phase: .ready, updatedAt: time, observedAt: time, runtimeConfirmed: true)
        sessions.acceptSessions([working, task, done])
    }
}

struct StatusPreview: NSViewRepresentable {
    let stage: Int
    func makeNSView(context: Context) -> MenuBarStatusContent { MenuBarStatusContent(frame: .zero) }
    func updateNSView(_ view: MenuBarStatusContent, context: Context) {
        view.style = .summary; view.running = stage == 0 ? 2 : 1; view.waiting = stage == 1 ? 1 : 0
        view.artwork.image = AppArtwork.brandMark; view.iconWidth = 24
        view.frame.size = CGSize(width: 260, height: 30)
        view.needsLayout = true; view.needsDisplay = true
    }
}

struct DemoScene: View {
    @ObservedObject var state: DemoState
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                HStack(spacing: 10) {
                    if let mark = AppArtwork.brandMark { Image(nsImage: mark).resizable().scaledToFit().frame(width: 34, height: 34) }
                    Text("Lunavect").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                StatusPreview(stage: state.stage).frame(width: 260, height: 30)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .top, spacing: 32) {
                SessionsView(store: state.sessions, onSettings: {}).defaultAppStorage(state.defaults)
                    .frame(width: 360, height: 355).background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 0.5))
                VStack(spacing: 18) {
                    widget(.limits)
                    widget(.activity)
                }
            }
            HStack(alignment: .center) {
                Text(["01  Follow work in progress", "02  See when a session needs you", "03  Know when the response is ready"][state.stage])
                    .font(.system(size: 21, weight: .medium))
                Spacer()
                Text("Native UI · sample data\nWidget previews")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }.frame(height: 48)
        }.padding(40).frame(width: 840, height: 560)
            .background(LinearGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.16), Color(red: 0.14, green: 0.12, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .preferredColorScheme(.dark).environment(\.colorScheme, .dark)
    }
    private func widget(_ content: LunavectWidgetContent) -> some View {
        LunavectWidgetCard(snapshots: state.snapshots, preferences: state.preferences, history: state.history, content: content, family: .medium, now: state.now, source: .comparison)
            .clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
}

@MainActor final class DemoDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var status: NSStatusItem!
    var animator: MenuBarAnimator!
    let popover = NSPopover()
    let state = DemoState()
    var timer: Timer?
    var frame = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppArtwork.icon
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Lunavect Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = appMenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 840, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lunavect — native interface demo"; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: DemoScene(state: state)); window.center(); window.makeKeyAndOrderFront(nil)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        animator = MenuBarAnimator(statusItem: status)
        status.button?.target = self; status.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SessionsView(store: state.sessions, onSettings: {}).defaultAppStorage(state.defaults))
        popover.contentSize = NSSize(width: 360, height: 355)
        updateStatus(); NSApp.activate(ignoringOtherApps: true)
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_DEMO_OUTPUT"] {
            let dir = URL(fileURLWithPath: output); try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.frame == 15 { self.state.setStage(0); self.updateStatus() }
                    if self.frame == 75 { self.state.setStage(1); self.updateStatus() }
                    if self.frame == 135 { self.state.setStage(2); self.updateStatus() }
                    if self.frame >= 15 && self.frame < 195 {
                        self.capture(to: dir.appendingPathComponent(String(format: "%04d.png", self.frame - 15)))
                    }
                    self.frame += 1
                    if self.frame >= 195 { self.timer?.invalidate(); NSApp.terminate(nil) }
                }
            }
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.state.setStage((self.state.stage + 1) % 3); self.updateStatus() }
            }
        }
    }
    func updateStatus() { animator.update(icon: .lunavect, onlyWhileWorking: false, thinkingPhrases: false, running: state.stage == 0 ? 2 : 1, waiting: state.stage == 1 ? 1 : 0) }
    @objc func togglePopover() { if popover.isShown { popover.performClose(nil) } else if let button = status.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) } }
    func capture(to url: URL) {
        guard let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: state.directory) }
}

@main enum DemoMain {
    @MainActor static func main() {
        let app = NSApplication.shared; let delegate = DemoDelegate(); app.delegate = delegate
        app.setActivationPolicy(.regular); withExtendedLifetime(delegate) { app.run() }
    }
}
