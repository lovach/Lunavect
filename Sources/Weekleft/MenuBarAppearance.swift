import AppKit
import SwiftUI
import Combine
#if SWIFT_PACKAGE
import WeekleftCore
#endif

// Stored separately from widget preferences: changing the menu bar must not
// reload WidgetKit or alter the shared quota snapshot.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case system, claude, codex, lunavect
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Стандартный")
        case .claude: return "Claude"
        case .codex: return "ChatGPT / Codex"
        case .lunavect: return "Lunavect"
        }
    }
    var motion: String {
        switch self {
        case .system: return L("Без анимации")
        case .claude: return L("Печатает, гуляет, машет")
        case .codex: return L("Печатает за ноутбуком")
        case .lunavect: return L("Парит, раскрывается и собирается")
        }
    }
}

enum MenuBarStatusStyle: String, CaseIterable, Identifiable {
    case summary, counters, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: return L("Одна строка")
        case .counters: return L("Две строки")
        case .activity: return L("Только активность")
        }
    }
    var explanation: String {
        switch self {
        case .summary: return L("Лёгкий текст без плашки. Во время живой фразы счётчик находится у персонажа.")
        case .counters: return L("Две строки: работающие сессии и ожидающие ответа или разрешения.")
        case .activity: return L("Живые точки в облачке — идёт работа. Янтарное облачко — нужен ответ. В покое остаётся персонаж. Числа доступны при наведении.")
        }
    }
}

// Playful copy, not a report of tools the agent is currently using.
enum ThinkingPhrases {
    static let interval: TimeInterval = 3.5
    static let dotInterval: TimeInterval = 0.5
    static func dotCount(at elapsed: TimeInterval) -> Int {
        Int(max(0, elapsed) / dotInterval) % 3 + 1
    }
    static let all = [
        "vibing", "thinking", "lollygagging", "pondering", "musing",
        "mulling", "cogitating", "contemplating", "ruminating", "reflecting",
        "wondering", "imagining", "dreaming", "daydreaming", "brainstorming",
        "ideating", "exploring", "wandering", "roaming", "meandering",
        "brewing", "percolating", "simmering", "steeping", "marinating",
        "incubating", "hatching", "conjuring", "envisioning", "visualizing",
        "sketching", "doodling", "scribbling", "tinkering", "fiddling",
        "noodling", "puzzling", "untangling", "unraveling", "connecting",
        "weaving", "synthesizing", "distilling", "refining", "polishing",
        "shaping", "sculpting", "crafting", "composing", "orchestrating",
        "harmonizing", "resonating", "attuning", "calibrating", "navigating",
        "orbiting", "stargazing", "moonwalking", "warming up", "finding flow",
        "chasing sparks", "connecting dots", "following clues", "cooking ideas", "letting it cook",
        "plotting", "scheming", "jamming", "freestyling", "tuning in"
    ]
}

struct ThinkingPhraseCycle {
    private var remaining: [String] = []
    private var previous: String?
    private var nextChange: TimeInterval = 0
    private var startedAt: TimeInterval?
    private(set) var current: String?
    private(set) var dotCount = 3

    mutating func update(active: Bool, at time: TimeInterval, rotates: Bool = true) {
        guard active else { current = nil; nextChange = 0; startedAt = nil; dotCount = 3; return }
        if startedAt == nil { startedAt = time }
        dotCount = rotates ? ThinkingPhrases.dotCount(at: time - (startedAt ?? time)) : 3
        guard current == nil || (rotates && time >= nextChange) else { return }
        let wasActive = current != nil
        if remaining.isEmpty {
            remaining = ThinkingPhrases.all.shuffled()
            if remaining.last == previous { remaining.swapAt(0, remaining.count - 1) }
        }
        current = remaining.removeLast()
        previous = current
        nextChange = wasActive ? nextChange + ThinkingPhrases.interval : time + ThinkingPhrases.interval
        if nextChange <= time { nextChange = time + ThinkingPhrases.interval }
    }
}

@MainActor final class MenuBarAppearance: ObservableObject {
    @Published var thinkingPhrases: Bool {
        didSet { defaults.set(thinkingPhrases, forKey: "menuBarThinkingPhrases") }
    }
    @Published var statusStyle: MenuBarStatusStyle {
        didSet { defaults.set(statusStyle.rawValue, forKey: "menuBarStatusStyle") }
    }
    @Published var icon: MenuBarIcon {
        didSet { defaults.set(icon.rawValue, forKey: "menuBarIcon") }
    }
    @Published var onlyWhileWorking: Bool {
        didSet { defaults.set(onlyWhileWorking, forKey: "menuBarAnimationOnlyWhileWorking") }
    }
    @Published var systemColor: Bool {
        didSet { defaults.set(systemColor, forKey: "menuBarSystemColor") }
    }
    @Published var automaticIcon: Bool {
        didSet { defaults.set(automaticIcon, forKey: "menuBarAutomaticIcon") }
    }
    private var lastResolvedIcon: MenuBarIcon?
    @Published var previewVisible = false
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thinkingPhrases = defaults.object(forKey: "menuBarThinkingPhrases") as? Bool ?? true
        statusStyle = MenuBarStatusStyle(rawValue: defaults.string(forKey: "menuBarStatusStyle") ?? "") ?? .summary
        automaticIcon = defaults.bool(forKey: "menuBarAutomaticIcon")
        systemColor = defaults.bool(forKey: "menuBarSystemColor")
        icon = MenuBarIcon(rawValue: defaults.string(forKey: "menuBarIcon") ?? "") ?? .system
        onlyWhileWorking = defaults.object(forKey: "menuBarAnimationOnlyWhileWorking") as? Bool ?? true
    }
    func resolvedIcon(for sessions: [AgentSession], now: Date = Date()) -> MenuBarIcon {
        let active = sessions.filter { $0.effectivePhase(now: now).isActive }
        let claude = active.filter { $0.provider == .claude }.count
        let codex = active.filter { $0.provider == .codex }.count
        let resolved: MenuBarIcon
        if !automaticIcon || active.isEmpty { resolved = icon }
        else if claude > codex { resolved = .claude }
        else if codex > claude { resolved = .codex }
        else { resolved = lastResolvedIcon ?? icon }
        lastResolvedIcon = resolved
        return resolved
    }
    func selectIcon(_ icon: MenuBarIcon) {
        self.icon = icon
        automaticIcon = false
    }
}

@MainActor enum MenuBarArtwork {
    static let frameCount = MenuBarScenes.frameCount
    static let cycleDuration = MenuBarScenes.cycleDuration
    private static var frames: [String: NSImage] = [:]
    private static let templates = NSMapTable<NSImage, NSImage>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func image(_ icon: MenuBarIcon, frame: Int, size: CGFloat = 22, elapsed: TimeInterval? = nil) -> NSImage? {
        if icon == .claude {
            return ClawdAnimation.image(at: elapsed ?? Double(frame) / Double(frameCount) * cycleDuration, size: size)
        }
        if icon == .codex {
            return CodexAnimation.image(at: elapsed ?? Double(frame) / Double(frameCount) * cycleDuration, size: size)
        }
        guard icon != .system else { return NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil) }
        let key = "\(icon.rawValue)-\(frame)-\(size)"
        if let cached = frames[key] { return cached }
        let image = NSImage(size: NSSize(width: size * 1.55, height: size), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scaleX(by: size * 1.55 / 34, yBy: size / 22)
            transform.concat()
            MenuBarScenes.draw(icon, frame: frame)
            return true
        }
        image.isTemplate = false
        frames[key] = image
        return image
    }

    static func styled(_ image: NSImage, systemColor: Bool) -> NSImage {
        guard systemColor else { return image }
        if let cached = templates.object(forKey: image) { return cached }
        // A plain template flattens dark eyes and laptop details into a solid
        // silhouette. Transfer luminance into alpha so those details stay open.
        let rasters = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let targets: [(Int, Int, CGImage?)] = rasters.count == 2
            ? rasters.map { ($0.pixelsWide, $0.pixelsHigh, $0.cgImage) }
            : [(max(1, Int(image.size.width * 2)), max(1, Int(image.size.height * 2)), nil)]
        let template = NSImage(size: image.size)
        for (width, height, source) in targets {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let mask: CGImage? = pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                if let source {
                    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                } else {
                    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                }
                NSGraphicsContext.restoreGraphicsState()
                let bytes = buffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let alpha = Double(bytes[offset + 3])
                    guard alpha > 0 else { continue }
                    let brightness = Double(max(bytes[offset], bytes[offset + 1], bytes[offset + 2])) / alpha
                    bytes[offset + 3] = UInt8(alpha * min(1, max(0, (brightness - 0.08) / 0.5)))
                    bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
                }
                return context.makeImage()
            }
            guard let mask else { return image }
            let rep = NSBitmapImageRep(cgImage: mask); rep.size = image.size
            template.addRepresentation(rep)
        }
        template.isTemplate = true
        templates.setObject(template, forKey: image)
        return template
    }

    static func frame(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration * Double(frameCount))
    }
}

// Kept inside the native status button so its click, right-click, highlight and
// accessibility continue to use NSStatusBarButton. Children never consume clicks.
@MainActor final class MenuBarStatusContent: NSView {
    static func artworkSize(for icon: MenuBarIcon, barHeight: CGFloat) -> CGFloat {
        // The characters' source canvases include transparent vertical margins.
        // Retain the compact Codex size on a 22 pt menu bar; taller bars can grow it.
        switch icon {
        case .claude: return min(28, barHeight + 6)
        case .codex: return min(28, barHeight + 4)
        default: return 24
        }
    }
    let artwork = NSImageView()
    let updateBadge = NSView()
    var pixelAlignedArtwork = false
    var constrainsSummaryWidth = false
    var style: MenuBarStatusStyle = .summary
    var running = 0
    var waiting = 0
    var thinkingPhrase: String?
    var thinkingDotCount = 3
    var activityDotCount = 3
    var activityBubbleVisible: Bool { style == .activity && (running > 0 || waiting > 0) }
    var activityBubbleFrame: NSRect { NSRect(x: 6 + iconWidth - 1, y: max(1, (bounds.height - 22) / 2), width: 14, height: 11) }
    var activityBubbleColor: NSColor {
        waiting > 0 ? NSColor(srgbRed: 1, green: 0.78, blue: 0.50, alpha: 1)
                    : NSColor(srgbRed: 0.91, green: 0.93, blue: 0.98, alpha: 1)
    }
    var showsThinkingPhrase: Bool { style == .summary && running > 0 && waiting == 0 && thinkingPhrase != nil }
    var language = L10n.selection
    var iconWidth: CGFloat = 24
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        artwork.imageScaling = .scaleProportionallyDown
        addSubview(artwork)
        updateBadge.wantsLayer = true
        updateBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        updateBadge.layer?.cornerRadius = 3
        updateBadge.frame = NSRect(x: 2, y: 2, width: 6, height: 6)
        updateBadge.isHidden = true
        updateBadge.setAccessibilityElement(false)
        addSubview(updateBadge)
        setAccessibilityElement(false)
        artwork.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var labelFont: NSFont { .systemFont(ofSize: bounds.height >= 26 ? 10.5 : 9, weight: .medium) }
    private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: labelFont.pointSize, weight: .semibold) }
    private var attentionColor: NSColor { NSColor.systemOrange.blended(withFraction: 0.25, of: .labelColor) ?? .systemOrange }
    private var darkAppearance: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var summaryBackground: NSColor { NSColor(white: darkAppearance ? 0.14 : 0.96, alpha: 1) }
    private var summaryForeground: NSColor { NSColor(white: darkAppearance ? 0.96 : 0.12, alpha: 1) }
    private var summaryAttention: NSColor {
        darkAppearance ? NSColor(srgbRed: 1, green: 0.76, blue: 0.44, alpha: 1)
                       : NSColor(srgbRed: 0.55, green: 0.27, blue: 0.02, alpha: 1)
    }
    private var statusFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
    var displayedThinkingPhrase: String {
        guard let phrase = thinkingPhrase, let first = phrase.first else { return "" }
        return String(first).uppercased() + phrase.dropFirst() + "..."
    }
    var badgeText: NSAttributedString {
        NSAttributedString(string: String(running), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: summaryForeground
        ])
    }
    var badgeWidth: CGFloat { showsThinkingPhrase ? max(13, ceil(badgeText.size().width) + 6) : 0 }
    var badgeFrame: NSRect { NSRect(x: 6 + iconWidth, y: max(1, (bounds.height - 24) / 2), width: badgeWidth, height: 13) }
    var textOriginX: CGFloat { 6 + iconWidth + badgeWidth + 6 }
    var summaryText: NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        if showsThinkingPhrase {
            result.append(NSAttributedString(string: displayedThinkingPhrase, attributes: [.font: statusFont, .foregroundColor: NSColor.labelColor]))
            // Hide unused dots without changing the measured word or moving the icon.
            let hidden = 3 - min(3, max(1, thinkingDotCount))
            if hidden > 0 { result.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: result.length - hidden, length: hidden)) }
            return result
        }
        for (count, index) in [(running, 0), (waiting, 1)] where count > 0 {
            if result.length > 0 {
                result.append(NSAttributedString(string: "  ·  ", attributes: [.font: statusFont, .foregroundColor: NSColor.labelColor]))
            }
            let color = index == 1 ? summaryAttention : NSColor.labelColor
            result.append(NSAttributedString(string: labels[index] + " ", attributes: [.font: statusFont, .foregroundColor: color]))
            result.append(NSAttributedString(string: String(count), attributes: [.font: statusFont, .foregroundColor: color]))
        }
        return result
    }
    var labels: [String] {
        [L10n.text("В работе", language: language), L10n.text("Ждут", language: language)]
    }
    private var labelWidth: CGFloat {
        ceil(labels.map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0)
    }
    private var numberWidth: CGFloat {
        ceil(["00", String(running), String(waiting)].map { ($0 as NSString).size(withAttributes: [.font: numberFont]).width }.max() ?? 0)
    }
    var statusWidth: CGFloat {
        switch style {
        case .summary:
            return summaryText.length > 0 ? ceil(summaryText.size().width) + 2 : 0
        case .counters: return labelWidth + numberWidth + 18
        case .activity: return activityBubbleVisible ? 14 : 0
        }
    }
    var preferredWidth: CGFloat {
        if style == .activity { return 12 + iconWidth + (activityBubbleVisible ? 13 : 0) }
        return 12 + iconWidth + badgeWidth + (statusWidth > 0 ? 6 + statusWidth : 0)
    }
    override func layout() {
        super.layout()
        let height = max(26, artwork.image?.size.height ?? 26)
        let frame = NSRect(x: 6, y: (bounds.height - height) / 2, width: iconWidth, height: height)
        artwork.frame = pixelAlignedArtwork
            ? backingAlignedRect(frame, options: .alignAllEdgesNearest) : frame
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true; artwork.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let x = textOriginX
        if style == .summary {
            guard statusWidth > 0 else { return }
            if showsThinkingPhrase {
                summaryBackground.setFill()
                NSBezierPath(roundedRect: badgeFrame, xRadius: 6, yRadius: 6).fill()
                let count = badgeText
                count.draw(at: NSPoint(x: badgeFrame.midX - count.size().width / 2, y: badgeFrame.midY - count.size().height / 2))
            }
            let text = summaryText
            let origin = NSPoint(x: x, y: (bounds.height - text.size().height) / 2)
            if constrainsSummaryWidth {
                let bounded = NSMutableAttributedString(attributedString: text)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                bounded.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: bounded.length))
                bounded.draw(in: NSRect(origin: origin, size: NSSize(width: max(0, bounds.width - x - 2), height: ceil(text.size().height))))
            } else {
                text.draw(at: origin)
            }
            return
        }
        if style == .activity {
            guard activityBubbleVisible else { return }
            let rect = activityBubbleFrame
            let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            shape.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY))
            shape.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY + 2))
            shape.line(to: NSPoint(x: rect.minX + 7, y: rect.maxY))
            shape.close()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 1
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            activityBubbleColor.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            for index in 0..<3 {
                let steady = waiting > 0 || activityDotCount == 0
                let alpha: CGFloat = steady || index == activityDotCount - 1 ? 1 : 0.25
                NSColor(srgbRed: 0.16, green: 0.20, blue: 0.27, alpha: alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 3 + CGFloat(index) * 3, y: rect.midY - 1, width: 2, height: 2)).fill()
            }
            return
        }
        let height = min(26, bounds.height)
        let capsule = NSRect(x: x, y: (bounds.height - height) / 2, width: statusWidth, height: height)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 5, yRadius: 5).fill()
        let rowHeight = height / 2
        for (index, count) in [running, waiting].enumerated() {
            let color: NSColor = count == 0 ? .secondaryLabelColor : (index == 1 ? attentionColor : .labelColor)
            let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
            let textHeight = (labels[index] as NSString).size(withAttributes: attributes).height
            let y = capsule.minY + CGFloat(index) * rowHeight + (rowHeight - textHeight) / 2
            (labels[index] as NSString).draw(at: NSPoint(x: x + 6, y: y), withAttributes: attributes)
            let numberAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: color]
            let text = String(count) as NSString
            text.draw(at: NSPoint(x: capsule.maxX - 6 - text.size(withAttributes: numberAttributes).width, y: y), withAttributes: numberAttributes)
        }
    }
}

@MainActor final class MenuBarAnimator {
    private weak var button: NSStatusBarButton?
    private weak var statusItem: NSStatusItem?
    let content = MenuBarStatusContent(frame: .zero)
    private var timer: Timer?
    private var phraseTimer: Timer?
    private var phraseCycle = ThinkingPhraseCycle()
    private var activityStartedAt: TimeInterval?
    private var thinkingPhrases = true
    private var icon = MenuBarIcon.system
    private var onlyWhileWorking = true
    private var systemColor = false
    private var running = 0
    private var waiting = 0
    private var observers: [NSObjectProtocol] = []
    private var asleep = false
    private var animationStartedAt: TimeInterval?
    private var lastTextState: String?
    private var openPopoverWidth: CGFloat?
    private var updateObserver: AnyCancellable?
    private var updateNotice: String?

    func setUpdateNotice(_ notice: String?) {
        updateNotice = notice
        content.updateBadge.isHidden = notice == nil
        refreshAccessibility()
    }
    private func refreshAccessibility() {
        let base = L("Lunavect · {0} в работе · {1} в ожидании", String(running), String(waiting))
        button?.toolTip = [base, updateNotice].compactMap { $0 }.joined(separator: "\n")
        button?.setAccessibilityLabel([L("Сессии Lunavect, {0} в работе, {1} в ожидании", String(running), String(waiting)), updateNotice].compactMap { $0 }.joined(separator: ". "))
    }

    // NSPopover follows its status button. Keep that anchor's size unchanged
    // throughout an open panel, then apply the latest desired width on close.
    func setPopoverOpen(_ open: Bool) {
        if open {
            guard openPopoverWidth == nil else { return }
            openPopoverWidth = statusItem?.length ?? content.preferredWidth
        } else {
            guard openPopoverWidth != nil else { return }
            openPopoverWidth = nil
        }
        content.constrainsSummaryWidth = open
        lastTextState = nil
        drawFrame()
    }

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.button = statusItem.button
        if let button = statusItem.button {
            button.title = ""; button.image = nil
            content.frame = button.bounds
            content.autoresizingMask = [.width, .height]
            button.addSubview(content)
        }
        updateObserver = AppUpdates.shared.$phase.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.setUpdateNotice(AppUpdates.shared.notice)
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    if event.name == NSWorkspace.willSleepNotification { self.asleep = true }
                    if event.name == NSWorkspace.didWakeNotification { self.asleep = false }
                    self.updateTimer()
                }
            })
        }
    }
    func update(icon: MenuBarIcon, onlyWhileWorking: Bool, systemColor: Bool = false, statusStyle: MenuBarStatusStyle = .summary, thinkingPhrases: Bool = true, running: Int, waiting: Int) {
        if self.icon != icon { animationStartedAt = nil }
        self.icon = icon; self.onlyWhileWorking = onlyWhileWorking; self.systemColor = systemColor
        content.pixelAlignedArtwork = icon == .claude
        self.running = running; self.waiting = waiting
        self.thinkingPhrases = thinkingPhrases
        content.style = statusStyle; content.running = running; content.waiting = waiting
        content.language = L10n.selection
        refreshAccessibility()
        updateTimer()
    }
    private var shouldAnimate: Bool {
        icon != .system && !asleep && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && (!onlyWhileWorking || running > 0)
    }
    private func updateTimer() {
        updatePhrase()
        let animatedStatus = (thinkingPhrases && content.style == .summary) || content.style == .activity
        let rotates = animatedStatus && running > 0 && waiting == 0 && !asleep && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if rotates && phraseTimer == nil {
            let timer = Timer(timeInterval: ThinkingPhrases.dotInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updatePhrase(); self?.drawFrame() }
            }
            timer.tolerance = 0.025
            RunLoop.main.add(timer, forMode: .common)
            phraseTimer = timer
        } else if !rotates { phraseTimer?.invalidate(); phraseTimer = nil }
        if shouldAnimate {
            if animationStartedAt == nil { animationStartedAt = ProcessInfo.processInfo.systemUptime }
            if timer == nil {
                let timer = Timer(timeInterval: MenuBarArtwork.cycleDuration / Double(MenuBarArtwork.frameCount), repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.drawFrame() }
                }
                timer.tolerance = 0.008
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else { timer?.invalidate(); timer = nil; animationStartedAt = nil }
        drawFrame()
    }
    private func updatePhrase() {
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let activeBubble = content.style == .activity && running > 0 && waiting == 0 && !asleep
        if activeBubble {
            if activityStartedAt == nil { activityStartedAt = now }
        } else { activityStartedAt = nil }
        content.activityDotCount = activeBubble && !reduceMotion ? ThinkingPhrases.dotCount(at: now - (activityStartedAt ?? now)) : 0
        phraseCycle.update(active: thinkingPhrases && content.style == .summary && running > 0 && waiting == 0 && !asleep,
                           at: now, rotates: !reduceMotion)
        content.thinkingPhrase = phraseCycle.current
        content.thinkingDotCount = phraseCycle.dotCount
    }
    private func drawFrame() {
        let image: NSImage?
        if icon == .system {
            image = NSImage(systemSymbolName: waiting > 0 ? "exclamationmark.bubble" : running > 0 ? "gearshape.2" : "rectangle.stack", accessibilityDescription: nil)
        } else {
            let original = MenuBarArtwork.image(icon, frame: shouldAnimate ? MenuBarArtwork.frame(at: .now) : 0, size: MenuBarStatusContent.artworkSize(for: icon, barHeight: button?.bounds.height ?? NSStatusBar.system.thickness),
                                                elapsed: shouldAnimate ? max(0, ProcessInfo.processInfo.systemUptime - (animationStartedAt ?? ProcessInfo.processInfo.systemUptime)) : 0)
            image = original.map { MenuBarArtwork.styled($0, systemColor: systemColor) }
        }
        let textState = "\(content.style.rawValue)|\(content.running)|\(content.waiting)|\(content.thinkingPhrase ?? "")|\(content.thinkingDotCount)|\(content.activityDotCount)|\(content.language)"
        let imageChanged = content.artwork.image !== image
        guard imageChanged || textState != lastTextState else { return }
        lastTextState = textState
        if imageChanged {
            content.artwork.image = image
            content.artwork.contentTintColor = image?.isTemplate == true ? .labelColor : nil
        }
        content.iconWidth = icon == .system ? 20 : (image?.size.width ?? 24)
        let width = openPopoverWidth ?? content.preferredWidth
        if statusItem?.length != width { statusItem?.length = width }
        if let button { content.frame = button.bounds }
        content.needsLayout = true
        content.needsDisplay = true
    }
    deinit {
        timer?.invalidate()
        phraseTimer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

struct MenuBarAppearanceView: View {
    @ObservedObject var appearance: MenuBarAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewStartedAt = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
        GroupBox(L("Статус в строке меню")) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(L("Статус сессий"), selection: $appearance.statusStyle) {
                    ForEach(MenuBarStatusStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("menu-bar-status-style")
                Text(appearance.statusStyle.explanation)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Живые фразы во время работы"), isOn: $appearance.thinkingPhrases)
                    .disabled(appearance.statusStyle != .summary)
                    .accessibilityIdentifier("menu-bar-thinking-phrases")
                Text(L("70 английских фраз, смена раз в 3,5 секунды и живое троеточие. Ожидание ответа важнее фразы."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.animation(minimumInterval: ThinkingPhrases.dotInterval, paused: reduceMotion || !appearance.previewVisible || (appearance.statusStyle != .activity && (!appearance.thinkingPhrases || appearance.statusStyle != .summary)))) { context in
                    MenuBarStatusPreview(appearance: appearance, dotCount: reduceMotion ? 0 : ThinkingPhrases.dotCount(at: context.date.timeIntervalSince(previewStartedAt)))
                }
                    .frame(height: NSStatusBar.system.thickness)
                    .padding(10)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Text(L(appearance.statusStyle == .activity || (appearance.thinkingPhrases && appearance.statusStyle == .summary) ? "Реальный размер · пример: 2 работают" : "Реальный размер · пример: 2 работают, 1 ждёт ответа"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox(L("Персонаж и анимация")) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(L("Выбор значка"), selection: $appearance.automaticIcon) {
                    Text(L("Автоматически")).tag(true)
                    Text(L("Вручную")).tag(false)
                }.pickerStyle(.segmented)
                    .accessibilityIdentifier("menu-bar-auto-icon")
                Text(L("Показывает Claude или Codex — у кого больше работающих и ожидающих ответа сессий. При равенстве значок сохраняется; без активных сессий используется ручной выбор."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                if !appearance.automaticIcon {
                Text(L("Выбор карточки включает ручной режим."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !appearance.previewVisible)) { context in
                    HStack(spacing: 10) {
                        ForEach([MenuBarIcon.claude, .codex, .lunavect]) { icon in
                            Button {
                                appearance.selectIcon(icon)
                            } label: {
                                VStack(spacing: 7) {
                                    if let image = MenuBarArtwork.image(icon, frame: reduceMotion ? 0 : MenuBarArtwork.frame(at: context.date), size: 44, elapsed: reduceMotion ? 0 : max(0, context.date.timeIntervalSince(previewStartedAt))) {
                                        Image(nsImage: MenuBarArtwork.styled(image, systemColor: appearance.systemColor)).frame(width: 69, height: 44).accessibilityHidden(true)
                                    }
                                    Text(icon.title).font(.system(size: 12, weight: .semibold))
                                    Text(icon.motion).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center).lineLimit(2).frame(height: 28, alignment: .top)
                                    InterfaceIcon(!appearance.automaticIcon && appearance.icon == icon ? .checkCircle : .circle)
                                        .foregroundStyle(!appearance.automaticIcon && appearance.icon == icon ? Color.accentColor : Color.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(!appearance.automaticIcon && appearance.icon == icon ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(!appearance.automaticIcon && appearance.icon == icon ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 1))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(icon.title + ", " + icon.motion)
                            .accessibilityValue(!appearance.automaticIcon && appearance.icon == icon ? L("Выбран") : L("Не выбран"))
                        }
                    }
                }
                }
                Toggle(L("Системный цвет значка"), isOn: $appearance.systemColor)
                Text(L("Одноцветный значок автоматически подстраивается под светлую и тёмную строку меню."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle(L("Анимировать только во время работы"), isOn: $appearance.onlyWhileWorking)
                Text(L("В предпросмотре значки движутся всегда. Системная настройка уменьшения движения останавливает анимацию."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(!appearance.automaticIcon && appearance.icon == .system ? L("Сейчас используется стандартный значок") : L("Вернуть стандартный значок")) { appearance.selectIcon(.system) }
                    .buttonStyle(.link).font(.system(size: 11)).disabled(!appearance.automaticIcon && appearance.icon == .system)
            }.padding(8)
        }
        }
    }
}

struct MenuBarStatusPreview: NSViewRepresentable {
    @ObservedObject var appearance: MenuBarAppearance
    var dotCount = 3
    func makeNSView(context: Context) -> MenuBarStatusContent {
        MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 180, height: NSStatusBar.system.thickness))
    }
    func updateNSView(_ view: MenuBarStatusContent, context: Context) {
        view.style = appearance.statusStyle; view.running = 2
        view.waiting = appearance.statusStyle == .activity || (appearance.thinkingPhrases && appearance.statusStyle == .summary) ? 0 : 1
        view.thinkingPhrase = appearance.thinkingPhrases ? "vibing" : nil
        view.thinkingDotCount = dotCount == 0 ? 3 : dotCount
        view.activityDotCount = dotCount
        view.language = L10n.selection
        view.pixelAlignedArtwork = appearance.icon == .claude
        let image = MenuBarArtwork.image(appearance.icon, frame: 0, size: MenuBarStatusContent.artworkSize(for: appearance.icon, barHeight: NSStatusBar.system.thickness))
            .map { MenuBarArtwork.styled($0, systemColor: appearance.systemColor) }
        view.artwork.image = image
        view.artwork.contentTintColor = image?.isTemplate == true ? .labelColor : nil
        view.iconWidth = appearance.icon == .system ? 20 : (image?.size.width ?? 24)
        view.needsLayout = true; view.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarStatusContent, context: Context) -> CGSize? {
        CGSize(width: nsView.preferredWidth, height: NSStatusBar.system.thickness)
    }
}

// Shared by the app and opt-in native previews; the artwork is the same bundle resource.
enum AnimationResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
        #else
        return Bundle.main.url(forResource: name, withExtension: ext)
        #endif
    }
}
