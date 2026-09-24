import XCTest
import AppKit
import SwiftUI
import WeekleftCore
@testable import Weekleft

private actor MenuBarAnimatorReferenceOwner {
    private var value: MenuBarAnimator?
    init(_ value: MenuBarAnimator) { self.value = value }
    func release() { value = nil }
}

final class MenuBarStatusTests: XCTestCase {
    @MainActor func testWaitingCounterResumesDuringEventTrackingWithoutOpeningPanel() throws {
        _ = NSApplication.shared
        let instant = Date()
        var row = AgentSession(provider: .claude, sessionID: "tracking-wait", title: "Fixture", cwd: "",
                               phase: .input, updatedAt: instant, observedAt: instant, evidence: .hook)
        let environment = try AppEnvironment.preview(rows: [row], now: instant)
        defer { environment.stop() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let delegate = AppDelegate(environment: environment)
        let animator = MenuBarAnimator(statusItem: item, canRenderAnimation: { _ in false })
        delegate.menuBarAnimator = animator
        delegate.observeSessionStatus()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(animator.content.waiting, 1)
        row.phase = .running
        let resumed = row
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated { environment.sessions.acceptSessions([resumed], now: instant) }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
        XCTAssertEqual(environment.sessions.currentSessions.first?.phase, .running)
        XCTAssertEqual(animator.content.waiting, 0, "The old wait must clear before tracking ends or the panel opens")
        XCTAssertEqual(animator.content.running, 1)
        timer.invalidate()
        // Drain scheduled callbacks before destroying the fixture.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    @MainActor func testIdleClaudeTrimsTransparentCanvasAndRestoresCompactWidthAfterWork() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let animator = MenuBarAnimator(statusItem: item)
        animator.update(icon: .claude, onlyWhileWorking: true, running: 0, waiting: 0)
        try await Task.sleep(for: .milliseconds(100))
        let button = try XCTUnwrap(item.button)
        let idle = try XCTUnwrap(animator.content.artwork.image)
        let original = try XCTUnwrap(ClawdAnimation.image(at: 0, size: idle.size.height))
        XCTAssertLessThan(idle.size.width, original.size.width)
        XCTAssertEqual(idle.size.height, original.size.height)
        func ink(_ image: NSImage) -> [Int] {
            image.representations.compactMap { $0 as? NSBitmapImageRep }.map { rep in
                (0..<rep.pixelsWide).reduce(0) { total, x in
                    total + (0..<rep.pixelsHigh).filter { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0 }.count
                }
            }
        }
        XCTAssertEqual(ink(idle), ink(original), "Every visible source pixel must survive the crop at both scales")
        let width = reservedWidth(of: item)
        animator.update(icon: .claude, onlyWhileWorking: true, running: 2, waiting: 0)
        XCTAssertGreaterThan(reservedWidth(of: item), width)
        animator.update(icon: .claude, onlyWhileWorking: true, running: 0, waiting: 0)
        XCTAssertEqual(reservedWidth(of: item), width)
        button.layoutSubtreeIfNeeded(); animator.content.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            button.appearance = NSAppearance(named: .darkAqua)
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("idle-claude-trimmed.png"))
        }
    }

    func testControlClickOnAMenuBarItemShowsItsMenuLikeARightClick() throws {
        func click(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        XCTAssertTrue(StatusItemClick.opensMenu(try click(.rightMouseUp)))
        XCTAssertTrue(StatusItemClick.opensMenu(try click(.leftMouseUp, .control)))
        XCTAssertFalse(StatusItemClick.opensMenu(try click(.leftMouseUp)))
        XCTAssertFalse(StatusItemClick.opensMenu(try click(.leftMouseUp, .option)), "Only Control asks for the menu")
        XCTAssertFalse(StatusItemClick.opensMenu(nil), "A keyboard shortcut or accessibility press opens the panel")
    }
    @MainActor func testWaitingBubbleHasShapeCueWithMotionDisabled() {
        let content = MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 50, height: 24))
        content.style = .activity
        content.running = 1
        content.activityDotCount = 0
        XCTAssertTrue(content.activityBubbleVisible)
        XCTAssertNil(content.activityAttentionSymbol)
        content.waiting = 1
        XCTAssertEqual(content.activityAttentionSymbol, "!")
    }

    @MainActor func testImageFramePreservesTextDrawingAndNativeAnchor() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var clock = 10.0
        let animator = MenuBarAnimator(statusItem: item, now: { clock })
        animator.update(icon: .codex, onlyWhileWorking: false, thinkingPhrases: false, running: 1, waiting: 0)
        try await Task.sleep(for: .milliseconds(100))
        animator.update(icon: .codex, onlyWhileWorking: false, thinkingPhrases: false, running: 1, waiting: 0)
        let anchor = try XCTUnwrap(item.button?.image)
        let image = animator.content.artwork.image
        animator.content.needsLayout = false
        animator.content.needsDisplay = false
        clock += 0.14
        animator.drawFrame()
        XCTAssertTrue(item.button?.image === anchor, "A frame must not change the popover anchor")
        XCTAssertFalse(animator.content.needsLayout, "Only changing the character must not recompute text layout")
        XCTAssertFalse(animator.content.needsDisplay, "The character owns its layer; the text stays cached")
        if item.button?.window?.occlusionState.contains(.visible) == true,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertFalse(animator.content.artwork.image === image)
        }
    }
    @MainActor func testChangingCharacterDoesNotInheritRestDeadline() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Animation is disabled by the system Reduce Motion preference")
        }
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var clock = 10.0
        let animator = MenuBarAnimator(statusItem: item, now: { clock })
        animator.update(icon: .claude, onlyWhileWorking: false, thinkingPhrases: false, running: 1, waiting: 0)
        try await Task.sleep(for: .milliseconds(100))
        guard item.button?.window?.occlusionState.contains(.visible) == true else {
            throw XCTSkip("A visible status-item window is required to check native frame scheduling")
        }
        clock += ClawdAnimation.cycleDuration - 2.5
        try await Task.sleep(for: .milliseconds(120))
        animator.update(icon: .codex, onlyWhileWorking: false, thinkingPhrases: false, running: 1, waiting: 0)
        let initial = animator.content.artwork.image
        clock += 0.14
        try await Task.sleep(for: .milliseconds(170))
        XCTAssertFalse(animator.content.artwork.image === initial,
                       "Codex must advance after 120ms, without waiting for the previous Claude rest")
    }

    @MainActor func testAnimatorReleasedOffMainInvalidatesScheduledTimers() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var timers: [Timer] = []
        // Timer ownership is independent of the CI host's window occlusion and
        // Reduce Motion preference. Capture timers without scheduling a run loop.
        var animator: MenuBarAnimator? = MenuBarAnimator(statusItem: item,
            scheduleTimer: { timers.append($0) }, canRenderAnimation: { _ in true })
        animator?.update(icon: .codex, onlyWhileWorking: true, running: 1, waiting: 0)
        XCTAssertEqual(timers.count, 2, "Both artwork and phrase timers must be exercised")
        XCTAssertTrue(timers.allSatisfy(\.isValid))
        let owner = MenuBarAnimatorReferenceOwner(try XCTUnwrap(animator))
        animator = nil
        await owner.release()
        // Destruction may hop back from the releasing actor to MainActor.
        for _ in 0..<20 where timers.contains(where: \.isValid) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(timers.allSatisfy { !$0.isValid })
    }

    @MainActor func testAnimationTimersStopWhenRenderingBecomesUnavailable() {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var available = false
        var timers: [Timer] = []
        let animator = MenuBarAnimator(statusItem: item,
            scheduleTimer: { timers.append($0) }, canRenderAnimation: { _ in available })
        animator.update(icon: .codex, onlyWhileWorking: true, running: 1, waiting: 0)
        XCTAssertTrue(timers.isEmpty)
        available = true
        animator.update(icon: .codex, onlyWhileWorking: true, running: 1, waiting: 0)
        XCTAssertEqual(timers.filter(\.isValid).count, 2)
        available = false
        animator.update(icon: .codex, onlyWhileWorking: true, running: 1, waiting: 0)
        XCTAssertTrue(timers.allSatisfy { !$0.isValid })
        available = true
        animator.update(icon: .codex, onlyWhileWorking: true, running: 1, waiting: 0)
        XCTAssertEqual(timers.filter(\.isValid).count, 2)
        animator.setVisible(false)
        XCTAssertTrue(timers.allSatisfy { !$0.isValid }, "A hidden item stays inactive even when the display is available")
    }

    @MainActor private func reservedWidth(of item: NSStatusItem) -> CGFloat {
        item.button?.image?.size.width ?? 0
    }

    @MainActor func testSpacingMatchesNativeStatusItemsWithAndWithoutText() async throws {
        let app = NSApplication.shared
        let oldPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(oldPolicy) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let reference = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer {
            NSStatusBar.system.removeStatusItem(item)
            NSStatusBar.system.removeStatusItem(reference)
        }
        let animator = MenuBarAnimator(statusItem: item)
        let button = try XCTUnwrap(item.button)
        let nativeButton = try XCTUnwrap(reference.button)
        button.appearance = NSAppearance(named: .darkAqua)
        nativeButton.appearance = NSAppearance(named: .darkAqua)
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
        board.wantsLayer = true; board.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        defer { window.contentView = nil }
        for (row, icon) in MenuBarIcon.allCases.enumerated() {
            let label = NSTextField(labelWithString: icon.rawValue)
            label.textColor = .white; label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 12, y: 280 - row * 75, width: 95, height: 20)
            board.addSubview(label)
            for (column, running) in [0, 2].enumerated() {
                animator.update(icon: icon, onlyWhileWorking: true, statusStyle: .summary,
                                thinkingPhrases: false, running: running, waiting: 0)
                try await Task.sleep(for: .milliseconds(150))
                let reserved = try XCTUnwrap(button.image)
                // Compare with native AppKit using the same content dimensions,
                // rather than assuming a padding amount for a particular macOS.
                nativeButton.image = NSImage(size: reserved.size, flipped: false) { _ in true }
                try await Task.sleep(for: .milliseconds(50))
                button.layoutSubtreeIfNeeded()
                nativeButton.layoutSubtreeIfNeeded()
                XCTAssertEqual(item.length, NSStatusItem.variableLength)
                XCTAssertEqual(button.window?.frame.width ?? 0, nativeButton.window?.frame.width ?? -1, accuracy: 1)
                let nativeRect = try XCTUnwrap(nativeButton.cell).imageRect(forBounds: nativeButton.bounds)
                XCTAssertEqual(animator.content.artwork.frame.minX, nativeRect.minX, accuracy: 0.5)
                XCTAssertEqual(reserved.size.width, animator.content.preferredWidth)
                if running == 0 {
                    XCTAssertEqual(reserved.size.width, animator.content.iconWidth, "Idle icons must not reserve an empty label or private padding")
                } else {
                    XCTAssertLessThanOrEqual(animator.content.textOriginX + animator.content.summaryText.size().width, button.bounds.maxX - nativeRect.minX + 1)
                }
                let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                button.cacheDisplay(in: button.bounds, to: bitmap)
                let image = NSImage(size: button.bounds.size); image.addRepresentation(bitmap)
                let preview = NSImageView(frame: NSRect(x: 115 + column * 265, y: 270 - row * 75, width: Int(button.bounds.width), height: Int(button.bounds.height)))
                preview.image = image; preview.imageScaling = .scaleNone
                preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor(white: 0.23, alpha: 1).cgColor
                board.addSubview(preview)
                let caption = NSTextField(labelWithString: "\(running == 0 ? "Icon" : "With text") · \(Int((button.window?.frame.width ?? 0).rounded())) pt")
                caption.textColor = .lightGray; caption.font = .systemFont(ofSize: 11)
                caption.frame = NSRect(x: preview.frame.minX, y: preview.frame.minY - 24, width: 245, height: 18)
                board.addSubview(caption)
            }
        }
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
            board.cacheDisplay(in: board.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("native-spacing.png"))
        }
    }

    @MainActor func testSessionStatusCanHideAndRestoreIndependentlyOfLimits() throws {
        _ = NSApplication.shared
        let suite = "Lunavect.StatusVisibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = MenuBarAppearance(defaults: defaults)
        XCTAssertTrue(appearance.showsSessionStatus, "Existing installations keep their session status")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let animator = MenuBarAnimator(statusItem: item)
        for limitsEnabled in [true, false] {
            appearance.limits.enabled = limitsEnabled
            appearance.showsSessionStatus = false
            animator.setVisible(appearance.showsSessionStatus)
            animator.update(icon: .claude, onlyWhileWorking: true, running: 2, waiting: 1)
            XCTAssertFalse(item.isVisible, "Session updates must not bring a hidden status item back")
            let restored = MenuBarAppearance(defaults: defaults)
            XCTAssertFalse(restored.showsSessionStatus)
            XCTAssertEqual(restored.limits.enabled, limitsEnabled)
            appearance.showsSessionStatus = true
            animator.setVisible(true)
            XCTAssertTrue(item.isVisible)
            XCTAssertTrue(animator.content.superview === item.button, "Restoring the status item must restore the character view")
            XCTAssertNotNil(animator.content.artwork.image)
            XCTAssertGreaterThanOrEqual(reservedWidth(of: item), animator.content.iconWidth + 12)
            XCTAssertEqual(animator.content.running, 2)
            XCTAssertEqual(animator.content.waiting, 1)
            XCTAssertEqual(appearance.limits.enabled, limitsEnabled)
        }
    }

    @MainActor func testSessionPopoverDismissesOnDeactivationAndCanReopen() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: 32)
        let popover = NSPopover()
        popover.animates = false
        // Exercise our fallback independently of AppKit's transient behavior,
        // including the applicationDefined mode used while reordering a row.
        popover.behavior = .applicationDefined
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        let dismissal = SessionPopoverDismissal()
        defer {
            dismissal.stop(); popover.close()
            NSStatusBar.system.removeStatusItem(item)
            app.setActivationPolicy(policy)
        }
        let button = try XCTUnwrap(item.button)
        try await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<2 {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            XCTAssertTrue(popover.isShown)
            dismissal.start(for: popover)
            dismissal.start(for: popover) // Reinstallation must remove old observers.
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
            XCTAssertFalse(popover.isShown)
            dismissal.stop()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        XCTAssertTrue(popover.isShown, "Closing the panel must remove its activation observer")
    }

    @MainActor func testOpenPopoverStaysInPlaceAcrossStatusWidths() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let animator = MenuBarAnimator(statusItem: item)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        defer { popover.close(); NSStatusBar.system.removeStatusItem(item) }
        animator.update(icon: .claude, onlyWhileWorking: true, thinkingPhrases: false, running: 0, waiting: 1)
        let button = try XCTUnwrap(item.button)
        try await Task.sleep(nanoseconds: 100_000_000)
        animator.setPopoverOpen(true)
        // AppKit can attach a status item's popover on a later run-loop turn
        // after earlier tests changed the app activation policy. Wait for the
        // native attachment itself instead of assuming one 100ms delay is enough.
        for _ in 0..<20 where controller.view.window == nil {
            if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let window = try XCTUnwrap(controller.view.window)
        let initialFrame = window.frame
        let initialWidth = reservedWidth(of: item)
        for (running, waiting) in [(999, 999), (0, 0), (1, 7), (25, 9999)] {
            animator.update(icon: .claude, onlyWhileWorking: true, thinkingPhrases: false, running: running, waiting: waiting)
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertEqual(reservedWidth(of: item), initialWidth)
            XCTAssertEqual(window.frame, initialFrame, "The open native popover must not follow changing text widths")
            XCTAssertEqual(animator.content.waiting, waiting)
        }
        // The phrase keeps changing inside the reserved slot; inspect clipping
        // using the production NSView, including its real 13 pt font.
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            animator.content.running = 1; animator.content.waiting = 0
            animator.content.thinkingPhrase = "following the breadcrumbs"
            animator.content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(animator.content.bitmapImageRepForCachingDisplay(in: animator.content.bounds))
            animator.content.cacheDisplay(in: animator.content.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("fixed-open-status.png"))
        }
        popover.close()
        animator.setPopoverOpen(false)
        XCTAssertEqual(reservedWidth(of: item), animator.content.preferredWidth)
        XCTAssertNotEqual(reservedWidth(of: item), initialWidth)
        XCTAssertFalse(animator.content.constrainsSummaryWidth)
        animator.setPopoverOpen(true)
        let reopenedWidth = reservedWidth(of: item)
        animator.setPopoverOpen(true)
        XCTAssertEqual(reservedWidth(of: item), reopenedWidth, "Repeated opening must preserve the same anchor")
        animator.setPopoverOpen(false)
    }

    @MainActor func testRunningBadgeFitsFrozenIconOnlyButtonWithoutWidening() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let animator = MenuBarAnimator(statusItem: item)
        animator.update(icon: .codex, onlyWhileWorking: true, thinkingPhrases: true, running: 0, waiting: 0)
        try await Task.sleep(for: .milliseconds(100))
        let button = try XCTUnwrap(item.button)
        let width = reservedWidth(of: item)
        animator.setPopoverOpen(true)
        animator.update(icon: .codex, onlyWhileWorking: true, thinkingPhrases: true, running: 4, waiting: 0)
        button.layoutSubtreeIfNeeded()
        animator.content.layoutSubtreeIfNeeded()
        XCTAssertTrue(animator.content.showsThinkingPhrase)
        XCTAssertEqual(animator.content.badgeText.string, "4")
        XCTAssertEqual(reservedWidth(of: item), width)
        XCTAssertLessThanOrEqual(animator.content.badgeFrame.maxX, button.bounds.maxX - 1)
        XCTAssertGreaterThanOrEqual(animator.content.badgeFrame.minX, 0)
        XCTAssertGreaterThanOrEqual(animator.content.badgeWidth, animator.content.badgeText.size().width + 6)
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            button.appearance = NSAppearance(named: .darkAqua)
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("frozen-four-badge.png"))
        }
    }

    @MainActor func testWaitingUpdatesStatusAfterCompactIdleClaudeFrame() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let animator = MenuBarAnimator(statusItem: item)
        animator.update(icon: .claude, onlyWhileWorking: true, thinkingPhrases: false, running: 0, waiting: 0)
        let original = try XCTUnwrap(animator.content.artwork.image)
        let initialText = animator.content.summaryText.string
        animator.update(icon: .claude, onlyWhileWorking: true, thinkingPhrases: false, running: 0, waiting: 0)
        XCTAssertTrue(animator.content.artwork.image === original)
        XCTAssertEqual(animator.content.summaryText.string, initialText)
        animator.update(icon: .claude, onlyWhileWorking: true, thinkingPhrases: false, running: 0, waiting: 1)
        let waitingFrame = try XCTUnwrap(animator.content.artwork.image)
        XCTAssertGreaterThanOrEqual(waitingFrame.size.width, original.size.width)
        animator.update(icon: .claude, onlyWhileWorking: true, thinkingPhrases: false, running: 0, waiting: 1)
        XCTAssertTrue(animator.content.artwork.image === waitingFrame)
        XCTAssertNotEqual(animator.content.summaryText.string, initialText)
        XCTAssertEqual(animator.content.waiting, 1)
        XCTAssertEqual(reservedWidth(of: item), animator.content.preferredWidth)
    }

    @MainActor func testLargerCharactersAndTextFitMenuBarHeights() throws {
        _ = NSApplication.shared
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 236))
        board.appearance = NSAppearance(named: .darkAqua)
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        defer { window.contentView = nil }
        for (row, height) in [CGFloat(22), 28, 32].enumerated() {
            for (column, icon) in [MenuBarIcon.claude, .codex].enumerated() {
                let view = MenuBarStatusContent(frame: NSRect(x: 12 + column * 290, y: 178 - row * 68, width: 280, height: Int(height)))
                view.running = 1; view.thinkingPhrase = "finding flow"
                view.pixelAlignedArtwork = icon == .claude
                let size = MenuBarStatusContent.artworkSize(for: icon, barHeight: height)
                let image = try XCTUnwrap(MenuBarArtwork.image(icon, frame: 0, size: size))
                view.artwork.image = image; view.iconWidth = image.size.width
                view.frame.size.width = view.preferredWidth
                board.addSubview(view)
                view.needsLayout = true
                XCTAssertLessThanOrEqual(view.summaryText.size().height, height)
                XCTAssertLessThanOrEqual(view.badgeFrame.maxY, height)
                XCTAssertLessThan(view.badgeFrame.maxX, view.textOriginX)
                XCTAssertLessThanOrEqual(view.textOriginX + view.summaryText.size().width, view.preferredWidth)
                let font = try XCTUnwrap(view.summaryText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.pointSize, 13)
                let label = NSTextField(labelWithString: "\(icon.title) · \(Int(height)) pt")
                label.font = .systemFont(ofSize: 11)
                label.frame = NSRect(x: view.frame.minX, y: view.frame.minY - 22, width: 270, height: 16)
                board.addSubview(label)
            }
        }
        board.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
            board.cacheDisplay(in: board.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("larger-characters.png"))
        }
    }

    @MainActor func testActivityBubbleAnimatesWithoutPhrasesAndPrioritizesWaiting() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        // A controlled clock and captured timers: the result must not depend on the
        // host's menu-bar visibility, display sleep or run-loop timing.
        var clock: TimeInterval = 1_000
        var timers: [Timer] = []
        let animator = MenuBarAnimator(statusItem: item, now: { clock }, scheduleTimer: { timers.append($0) },
                                       canRenderAnimation: { _ in true })
        animator.update(icon: .system, onlyWhileWorking: true, statusStyle: .activity, thinkingPhrases: false, running: 2, waiting: 0)
        let view = animator.content
        XCTAssertTrue(view.activityBubbleVisible)
        XCTAssertFalse(view.showsThinkingPhrase)
        let width = reservedWidth(of: item)
        let workingColor = view.activityBubbleColor
        let dots = view.activityDotCount
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clock += 0.6
            try XCTUnwrap(timers.last(where: \.isValid), "The bubble schedules its own timer").fire()
            XCTAssertNotEqual(view.activityDotCount, dots, "The bubble has its own timer even with a static icon and phrases disabled")
        } else { XCTAssertEqual(dots, 0) }
        XCTAssertEqual(reservedWidth(of: item), width)
        animator.update(icon: .system, onlyWhileWorking: true, statusStyle: .activity, thinkingPhrases: false, running: 2, waiting: 1)
        XCTAssertTrue(view.activityBubbleVisible)
        XCTAssertNotEqual(view.activityBubbleColor, workingColor)
        XCTAssertEqual(view.activityDotCount, 0)
        XCTAssertEqual(reservedWidth(of: item), width)
        XCTAssertLessThanOrEqual(view.activityBubbleFrame.maxX - view.contentOriginX, view.preferredWidth)
        XCTAssertTrue(item.button?.toolTip?.contains("2") == true)
        XCTAssertTrue(item.button?.toolTip?.contains("1") == true)
        animator.update(icon: .system, onlyWhileWorking: true, statusStyle: .activity, running: 0, waiting: 0)
        XCTAssertFalse(view.activityBubbleVisible)
        XCTAssertLessThan(reservedWidth(of: item), width)
    }

    @MainActor func testPhrasesAnimateInEveryStyleAndYieldToWaiting() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var clock = 0.0
        let animator = MenuBarAnimator(statusItem: item, now: { clock })
        for style in MenuBarStatusStyle.allCases {
            animator.update(icon: .system, onlyWhileWorking: true, statusStyle: style, thinkingPhrases: true, running: 2, waiting: 0)
            let view = animator.content
            XCTAssertTrue(view.showsThinkingPhrase, style.rawValue)
            let word = view.thinkingPhrase
            let width = reservedWidth(of: item)
            clock += 0.5
            animator.update(icon: .system, onlyWhileWorking: true, statusStyle: style, thinkingPhrases: true, running: 2, waiting: 0)
            XCTAssertEqual(view.thinkingPhrase, word)
            XCTAssertEqual(reservedWidth(of: item), width)
            XCTAssertTrue(item.button?.toolTip?.contains("2") == true)
            if style == .counters { XCTAssertTrue(view.counterSummary.string.contains("2")) }
            animator.update(icon: .system, onlyWhileWorking: true, statusStyle: style, thinkingPhrases: true, running: 2, waiting: 1)
            XCTAssertFalse(view.showsThinkingPhrase)
            XCTAssertNil(view.thinkingPhrase)
            XCTAssertTrue(item.button?.toolTip?.contains("1") == true)
            animator.update(icon: .system, onlyWhileWorking: true, statusStyle: style, thinkingPhrases: false, running: 2, waiting: 0)
            XCTAssertFalse(view.showsThinkingPhrase)
        }
    }

    @MainActor func testPhraseModesNativeGeometry() throws {
        _ = NSApplication.shared
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        board.appearance = NSAppearance(named: .darkAqua)
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        for (row, style) in MenuBarStatusStyle.allCases.enumerated() {
            let title = NSTextField(labelWithString: style.rawValue)
            title.frame = NSRect(x: 16, y: 223 - row * 80, width: 120, height: 18)
            board.addSubview(title)
            for (column, dots) in [1, 2, 3].enumerated() {
                let view = MenuBarStatusContent(frame: NSRect(x: 16 + column * 150, y: 190 - row * 80, width: 145, height: 24))
                view.style = style; view.running = 2; view.language = "en"
                view.thinkingPhrase = "vibing"; view.thinkingDotCount = dots; view.activityDotCount = dots
                view.artwork.image = MenuBarArtwork.image(.codex, frame: 0, size: 26)
                view.iconWidth = view.artwork.image?.size.width ?? 24
                view.frame.size.width = view.preferredWidth
                XCTAssertLessThanOrEqual(view.preferredWidth, 145)
                if style == .activity { XCTAssertLessThan(view.activityBubbleFrame.maxX, view.textOriginX) }
                board.addSubview(view)
            }
        }
        board.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
            board.cacheDisplay(in: board.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("phrase-modes.png"))
        }
    }

    @MainActor func testAnimatedDotsKeepWordAndGeometrySteady() {
        var cycle = ThinkingPhraseCycle()
        let view = MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 250, height: 22))
        view.running = 1
        cycle.update(active: true, at: 0)
        let word = cycle.current
        view.thinkingPhrase = word
        let width = view.preferredWidth
        for (time, dots) in [(0.0, 1), (0.5, 2), (1.0, 3), (1.5, 1), (2.0, 2), (2.5, 3), (2.99, 3)] {
            cycle.update(active: true, at: time)
            XCTAssertEqual(cycle.current, word)
            XCTAssertEqual(cycle.dotCount, dots)
            view.thinkingDotCount = cycle.dotCount
            XCTAssertEqual(view.preferredWidth, width)
            let text = view.summaryText
            for index in 0..<3 {
                let color = text.attribute(.foregroundColor, at: text.length - 3 + index, effectiveRange: nil) as? NSColor
                XCTAssertEqual(color == .clear, index >= dots)
            }
        }
        cycle.update(active: true, at: 3.0)
        XCTAssertNotEqual(cycle.current, word)
        XCTAssertEqual(cycle.dotCount, 1)
        let secondWord = cycle.current
        cycle.update(active: true, at: 9.7)
        XCTAssertEqual(cycle.current, secondWord, "A delayed callback must not skip the visible cycles")
        XCTAssertEqual(cycle.dotCount, 2)
        for (time, dots) in [(10.2, 3), (10.7, 1), (11.2, 2), (11.7, 3)] {
            cycle.update(active: true, at: time)
            XCTAssertEqual(cycle.current, secondWord)
            XCTAssertEqual(cycle.dotCount, dots)
        }
        cycle.update(active: true, at: 12.2)
        XCTAssertNotEqual(cycle.current, secondWord)
        XCTAssertEqual(cycle.dotCount, 1)
        cycle.update(active: true, at: 13, rotates: false)
        XCTAssertEqual(cycle.dotCount, 3)
        cycle.update(active: false, at: 14)
        XCTAssertNil(cycle.current)
        cycle.update(active: true, at: 15)
        XCTAssertEqual(cycle.dotCount, 1)
    }

    @MainActor func testDelayedPhraseTimerKeepsEveryStepAndReschedulesFromShownFrame() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Reduce Motion") }
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var clock = 0.0
        var timers: [Timer] = []
        let animator = MenuBarAnimator(statusItem: item, now: { clock },
            scheduleTimer: { timers.append($0) }, canRenderAnimation: { _ in true })
        animator.update(icon: .system, onlyWhileWorking: true, running: 1, waiting: 0)
        let phrase = animator.content.thinkingPhrase
        let width = item.button?.image?.size.width
        for (time, count) in [(0.8, 2), (1.3, 3), (2.6, 1), (3.1, 2), (3.6, 3)] {
            clock = time
            try XCTUnwrap(timers.last).fire()
            XCTAssertEqual(animator.content.thinkingPhrase, phrase)
            XCTAssertEqual(animator.content.thinkingDotCount, count)
            XCTAssertEqual(item.button?.image?.size.width, width)
            XCTAssertEqual(try XCTUnwrap(timers.last).fireDate.timeIntervalSinceNow, 0.5, accuracy: 0.08)
        }
        clock = 4.1
        try XCTUnwrap(timers.last).fire()
        XCTAssertNotEqual(animator.content.thinkingPhrase, phrase)
        XCTAssertEqual(animator.content.thinkingDotCount, 1)
    }

    func testThinkingCycleExhaustsDeckAndDoesNotResetOnPolling() {
        XCTAssertEqual(ThinkingPhrases.all.count, 70)
        XCTAssertEqual(Set(ThinkingPhrases.all).count, 70)
        var cycle = ThinkingPhraseCycle()
        cycle.update(active: true, at: 0)
        let first = cycle.current
        for time in [0.5, 1, 1.5, 2, 2.5, 2.99] { cycle.update(active: true, at: time); XCTAssertEqual(cycle.current, first) }
        var seen = [first!]
        for index in 1..<70 {
            let start = Double(index) * ThinkingPhrases.interval
            cycle.update(active: true, at: start)
            seen.append(cycle.current!)
            for step in 1...5 { cycle.update(active: true, at: start + Double(step) * ThinkingPhrases.dotInterval) }
        }
        XCTAssertEqual(Set(seen), Set(ThinkingPhrases.all))
        cycle.update(active: true, at: 70 * ThinkingPhrases.interval)
        XCTAssertNotEqual(cycle.current, seen.last)
        let frozen = cycle.current
        cycle.update(active: true, at: 600, rotates: false)
        XCTAssertEqual(cycle.current, frozen)
        cycle.update(active: false, at: 601)
        XCTAssertNil(cycle.current)
        cycle.update(active: true, at: 602)
        XCTAssertNotNil(cycle.current)
        XCTAssertNotEqual(cycle.current, frozen)
    }

    @MainActor func testPhrasesFitCurrentWordAndYieldToRealStatus() throws {
        let view = MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        view.running = 2; view.thinkingPhrase = "vibing"
        let shortWidth = view.preferredWidth
        view.thinkingPhrase = "connecting dots"
        XCTAssertGreaterThan(view.preferredWidth, shortWidth)
        for phrase in ThinkingPhrases.all {
            view.thinkingPhrase = phrase
            XCTAssertEqual(view.statusWidth, ceil(view.summaryText.size().width) + 2)
            let font = try XCTUnwrap(view.summaryText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertGreaterThan(("www" as NSString).size(withAttributes: [.font: font]).width,
                                 ("iii" as NSString).size(withAttributes: [.font: font]).width)
            XCTAssertEqual(view.preferredWidth - view.textOriginX - view.summaryText.size().width, 2, accuracy: 1)
            XCTAssertEqual(view.summaryText.string, phrase.prefix(1).uppercased() + phrase.dropFirst() + "...")
            XCTAssertNil(view.summaryText.attribute(.shadow, at: 0, effectiveRange: nil))
            XCTAssertEqual(view.badgeText.string, "2")
            XCTAssertFalse(view.summaryText.string.contains("·"))
            XCTAssertLessThanOrEqual(view.summaryText.size().width + 2, view.statusWidth)
        }
        for count in [1, 12, 123] {
            view.running = count
            XCTAssertEqual(view.badgeText.string, String(count))
            XCTAssertGreaterThanOrEqual(view.badgeWidth, view.badgeText.size().width + 6)
            XCTAssertLessThan(view.badgeFrame.maxX, view.textOriginX)
        }
        view.waiting = 1
        XCTAssertEqual(view.badgeWidth, 0)
        XCTAssertFalse(view.showsThinkingPhrase)
        XCTAssertTrue(view.summaryText.string.contains("1"))
        view.waiting = 0; view.running = 0
        XCTAssertEqual(view.statusWidth, 0)
        view.running = 2; view.style = .activity
        XCTAssertTrue(view.showsThinkingPhrase)
        view.thinkingPhrase = nil
        XCTAssertFalse(view.showsThinkingPhrase)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let animator = MenuBarAnimator(statusItem: item)
        animator.update(icon: .system, onlyWhileWorking: true, running: 2, waiting: 0)
        XCTAssertTrue(animator.content.showsThinkingPhrase)
        let tooltip = item.button?.toolTip
        animator.update(icon: .system, onlyWhileWorking: true, thinkingPhrases: false, running: 2, waiting: 0)
        XCTAssertNil(animator.content.thinkingPhrase)
        XCTAssertEqual(item.button?.toolTip, tooltip)
    }

    @MainActor func testStylePersistsWithoutChangingIconOrAnimation() throws {
        let suite = "Lunavect.StatusTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("codex", forKey: "menuBarIcon")
        defaults.set(false, forKey: "menuBarAnimationOnlyWhileWorking")
        let settings = MenuBarAppearance(defaults: defaults)
        XCTAssertTrue(settings.thinkingPhrases)
        settings.thinkingPhrases = false
        XCTAssertEqual(settings.statusStyle, .summary)
        settings.statusStyle = .activity
        let restored = MenuBarAppearance(defaults: defaults)
        XCTAssertFalse(restored.thinkingPhrases)
        XCTAssertEqual(restored.statusStyle, .activity)
        XCTAssertEqual(restored.icon, .codex)
        XCTAssertFalse(restored.onlyWhileWorking)
        defaults.set("unsupported", forKey: "menuBarStatusStyle")
        XCTAssertEqual(MenuBarAppearance(defaults: defaults).statusStyle, .summary)
        defaults.set("counters", forKey: "menuBarStatusStyle")
        XCTAssertEqual(MenuBarAppearance(defaults: defaults).statusStyle, .counters, "The previous layout remains available")
    }

    @MainActor func testNativeButtonKeepsActionsCountsAndTooltipAcrossModes() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let action = NSSelectorFromString("testStatusClick:")
        button.action = action
        let animator = MenuBarAnimator(statusItem: item)
        animator.update(icon: .system, onlyWhileWorking: true, running: 12, waiting: 3)
        XCTAssertEqual(button.action, action)
        XCTAssertNil(animator.content.hitTest(NSPoint(x: 15, y: 10)))
        XCTAssertEqual(animator.content.running, 12)
        XCTAssertEqual(animator.content.waiting, 3)
        let tooltip = try XCTUnwrap(button.toolTip)
        XCTAssertTrue(tooltip.contains("12")); XCTAssertTrue(tooltip.contains("3"))
        let countersWidth = reservedWidth(of: item)
        animator.update(icon: .system, onlyWhileWorking: true, statusStyle: .activity, running: 12, waiting: 3)
        XCTAssertLessThan(reservedWidth(of: item), countersWidth)
        XCTAssertEqual(button.toolTip, tooltip)
        let activeWidth = reservedWidth(of: item)
        animator.update(icon: .system, onlyWhileWorking: true, statusStyle: .activity, running: 0, waiting: 0)
        XCTAssertLessThan(reservedWidth(of: item), activeWidth)
        XCTAssertEqual(button.action, action)
    }

    @MainActor func testSummaryKeepsCountsReadableAndSettingsSectionsReachable() {
        let view = MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 250, height: 22))
        for language in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            view.language = language
            view.running = 12; view.waiting = 3
            XCTAssertTrue(view.summaryText.string.contains("12"))
            XCTAssertTrue(view.summaryText.string.contains("3"))
            view.summaryText.enumerateAttribute(.font, in: NSRange(location: 0, length: view.summaryText.length)) { value, _, _ in
                XCTAssertGreaterThanOrEqual((value as? NSFont)?.pointSize ?? 0, 13)
            }
            view.running = 0; view.waiting = 1
            XCTAssertFalse(view.summaryText.string.contains("0"))
            XCTAssertTrue(view.summaryText.string.contains("1"))
            view.waiting = 0
            XCTAssertEqual(view.statusWidth, 0)
        }
        // Updates is pinned below the scrollable section groups.
        let sections = SettingsSectionGroup.allCases.flatMap(\.sections) + [.updates]
        XCTAssertEqual(Set(sections), Set(SettingsSection.allCases))
        XCTAssertEqual(sections.count, Set(sections).count)
    }

    @MainActor func testRenderReadableSummaryOnWallpapers() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] else { throw XCTSkip("Opt-in native wallpaper rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            let board = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
            board.appearance = NSAppearance(named: theme)
            board.wantsLayer = true
            board.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
            let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = board
            for (index, language) in ["ru", "en", "de", "es", "fr", "zh-Hans"].enumerated() {
                let row = NSView(frame: NSRect(x: 0, y: CGFloat(250 - index * 48), width: 420, height: 44))
                row.wantsLayer = true
                row.layer?.backgroundColor = (index % 2 == 0 ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.04, alpha: 1)).cgColor
                let band = NSView(frame: NSRect(x: 205, y: 0, width: 110, height: 44))
                band.wantsLayer = true; band.layer?.backgroundColor = NSColor(srgbRed: 0.67, green: 0.38, blue: 0.82, alpha: 1).cgColor
                row.addSubview(band)
                let label = NSTextField(labelWithString: language)
                label.font = .systemFont(ofSize: 11); label.textColor = index % 2 == 0 ? .black : .white
                label.frame = NSRect(x: 10, y: 12, width: 60, height: 20); row.addSubview(label)
                let status = MenuBarStatusContent(frame: NSRect(x: 75, y: 11, width: 300, height: 22))
                status.language = language; status.running = 2; status.waiting = 1
                if index < 4 {
                    status.waiting = 0
                    status.thinkingPhrase = ["vibing", "lollygagging", "connecting dots", "brewing"][index]
                    status.thinkingDotCount = index % 3 + 1
                }
                status.artwork.image = MenuBarArtwork.image(.codex, frame: 0, size: 26)
                row.addSubview(status); board.addSubview(row)
                status.frame.size.width = status.preferredWidth; status.needsLayout = true
                // macOS menu items grow toward the left from their right edge.
                status.frame.origin.x = 400 - status.preferredWidth
                XCTAssertLessThan(status.preferredWidth, 340)
            }
            board.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
            board.cacheDisplay(in: board.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("wallpapers-\(theme.rawValue).png"))
            window.contentView = nil
        }
    }

    @MainActor func testRenderNativeStylesAndLanguages() async throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] else {
            throw XCTSkip("Opt-in native menu status rendering")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let languages = ["ru", "en", "de", "es", "fr", "zh-Hans"]
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            for height: CGFloat in [22, 28] {
                let board = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
                board.appearance = NSAppearance(named: theme)
                board.wantsLayer = true
                board.appearance?.performAsCurrentDrawingAppearance {
                    board.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = board
                for (index, language) in languages.enumerated() {
                    let y = CGFloat(365 - index * 54)
                    let label = NSTextField(labelWithString: language)
                    label.frame = NSRect(x: 12, y: y + 4, width: 68, height: 20)
                    board.addSubview(label)
                    for (column, pair) in [(2, 1), (12, 0), (0, 3), (0, 0)].enumerated() {
                        let view = MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 120, height: height))
                        view.language = language; view.running = pair.0; view.waiting = pair.1
                        view.style = column == 0 ? .counters : .activity
                        view.artwork.image = MenuBarArtwork.image(.codex, frame: 0, size: 26)
                        view.frame = NSRect(x: 80 + CGFloat(column * 138), y: y, width: view.preferredWidth, height: height)
                        board.addSubview(view)
                        XCTAssertLessThan(view.preferredWidth, 138, language)
                        view.needsLayout = true
                    }
                }
                board.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
                board.cacheDisplay(in: board.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(theme.rawValue)-\(Int(height)).png"))
                window.contentView = nil
            }
        }
        let suite = "Lunavect.StatusSettingsRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = MenuBarAppearance(defaults: defaults)
        for style in MenuBarStatusStyle.allCases {
            appearance.statusStyle = style
            let host = NSHostingView(rootView: MenuBarAppearanceView(appearance: appearance).padding(16).frame(width: 600)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("settings-\(style.rawValue).png"))
            window.contentView = nil
        }
        defaults.set(SettingsSection.menuBar.rawValue, forKey: "settingsSection")
        appearance.statusStyle = .summary
        // Preview stores are isolated: they never load or save the real support folder.
        let settings = NSHostingView(
            rootView: SettingsView(
                store: uiDependencies.store, menuBarAppearance: appearance, sessions: uiDependencies.sessions,
                updates: uiDependencies.updates, awake: uiDependencies.awake, features: uiDependencies.features,
                language: uiDependencies.language
            )
            .defaultAppStorage(defaults).preferredColorScheme(.dark))
        settings.frame = NSRect(x: 0, y: 0, width: 840, height: 680)
        let window = NSWindow(contentRect: settings.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = settings; settings.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        settings.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
        settings.cacheDisplay(in: settings.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("settings-navigation.png"))
        window.contentView = nil
    }
}
