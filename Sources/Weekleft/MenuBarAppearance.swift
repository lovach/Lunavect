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
    static let dotInterval: TimeInterval = 0.5
    static let dotsPerCycle = 3
    static let cyclesPerPhrase = 2
    static let interval = dotInterval * Double(dotsPerCycle * cyclesPerPhrase)
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

// Advance only one visible step after a delayed callback. Catching up to a
// wall-clock phase would skip dots and shorten the cycles the user actually saw.
struct ThinkingDotCycle {
    private var step = 0
    private(set) var nextStepAt: TimeInterval?
    private(set) var dotCount = 3

    mutating func update(active: Bool, at time: TimeInterval, rotates: Bool) -> Bool {
        guard active && rotates else {
            step = 0; nextStepAt = nil; dotCount = 3
            return false
        }
        guard let deadline = nextStepAt else {
            step = 0; dotCount = 1; nextStepAt = time + ThinkingPhrases.dotInterval
            return false
        }
        guard time >= deadline else { return false }
        step = (step + 1) % (ThinkingPhrases.dotsPerCycle * ThinkingPhrases.cyclesPerPhrase)
        dotCount = step % ThinkingPhrases.dotsPerCycle + 1
        nextStepAt = time + ThinkingPhrases.dotInterval
        return step == 0
    }
}

struct ThinkingPhraseCycle {
    private var remaining: [String] = []
    private var previous: String?
    private var dots = ThinkingDotCycle()
    private(set) var current: String?
    var dotCount: Int { dots.dotCount }
    var nextStepAt: TimeInterval? { dots.nextStepAt }

    mutating func update(active: Bool, at time: TimeInterval, rotates: Bool = true) {
        let completed = dots.update(active: active, at: time, rotates: rotates)
        guard active else { current = nil; return }
        if current == nil || completed {
            if remaining.isEmpty {
                remaining = ThinkingPhrases.all.shuffled()
                if remaining.last == previous { remaining.swapAt(0, remaining.count - 1) }
            }
            current = remaining.removeLast()
            previous = current
        }
    }
}

@MainActor final class MenuBarAppearance: ObservableObject {
    @Published var showsSessionStatus: Bool {
        didSet { defaults.set(showsSessionStatus, forKey: "menuBarShowsSessionStatus") }
    }
    @Published var limits: MenuBarLimitsPreferences {
        didSet { if let data = try? JSONEncoder().encode(limits) { defaults.set(data, forKey: "menuBarLimits") } }
    }
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
        showsSessionStatus = defaults.object(forKey: "menuBarShowsSessionStatus") as? Bool ?? true
        limits = defaults.data(forKey: "menuBarLimits").flatMap { try? JSONDecoder().decode(MenuBarLimitsPreferences.self, from: $0) } ?? .init()
        thinkingPhrases = defaults.object(forKey: "menuBarThinkingPhrases") as? Bool ?? true
        statusStyle = MenuBarStatusStyle(rawValue: defaults.string(forKey: "menuBarStatusStyle") ?? "") ?? .summary
        automaticIcon = defaults.bool(forKey: "menuBarAutomaticIcon")
        lastResolvedIcon = defaults.string(forKey: "menuBarLastAutomaticIcon").flatMap(MenuBarIcon.init(rawValue:))
        systemColor = defaults.bool(forKey: "menuBarSystemColor")
        icon = MenuBarIcon(rawValue: defaults.string(forKey: "menuBarIcon") ?? "") ?? .system
        onlyWhileWorking = defaults.object(forKey: "menuBarAnimationOnlyWhileWorking") as? Bool ?? true
    }
    func resolvedIcon(for sessions: [AgentSession], now: Date = Date()) -> MenuBarIcon {
        let active = sessions.filter { $0.effectivePhase(now: now).isActive }
        let claude = active.filter { $0.provider == .claude }.count
        let codex = active.filter { $0.provider == .codex }.count
        let resolved: MenuBarIcon
        guard automaticIcon else { return icon }
        if active.isEmpty { return lastResolvedIcon ?? icon }
        if claude > codex { resolved = .claude }
        else if codex > claude { resolved = .codex }
        else { resolved = lastResolvedIcon ?? icon }
        if lastResolvedIcon != resolved {
            lastResolvedIcon = resolved
            defaults.set(resolved.rawValue, forKey: "menuBarLastAutomaticIcon")
        }
        return resolved
    }
    func selectIcon(_ icon: MenuBarIcon) {
        self.icon = icon
        automaticIcon = false
    }
    func restoreDefaults() {
        showsSessionStatus = true; limits = .init()
        thinkingPhrases = false; statusStyle = .summary
        automaticIcon = false; icon = AppDefaultSettings.icon
        onlyWhileWorking = true; systemColor = false
        lastResolvedIcon = nil; defaults.removeObject(forKey: "menuBarLastAutomaticIcon")
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
    var pixelAlignedArtwork = false
    var constrainsSummaryWidth = false
    var style: MenuBarStatusStyle = .summary
    var running = 0
    var waiting = 0
    var thinkingPhrase: String?
    var thinkingDotCount = 3
    var activityDotCount = 3
    var activityBubbleVisible: Bool { style == .activity && (running > 0 || waiting > 0) }
    var activityAttentionSymbol: String? { waiting > 0 ? "!" : nil }
    var activityBubbleFrame: NSRect { NSRect(x: contentOriginX + iconWidth - 1, y: max(1, (bounds.height - 22) / 2), width: 14, height: 11) }
    var activityBubbleColor: NSColor {
        waiting > 0 ? NSColor(srgbRed: 1, green: 0.78, blue: 0.50, alpha: 1)
                    : NSColor(srgbRed: 0.91, green: 0.93, blue: 0.98, alpha: 1)
    }
    var showsThinkingPhrase: Bool { running > 0 && waiting == 0 && thinkingPhrase != nil }
    var language = L10n.selection
    var iconWidth: CGFloat = 24
    // AppKit owns the outer spacing. A native sizing image reserves just our ink
    // width; its image rect supplies the inset for this macOS/menu-bar layout.
    var contentOriginX: CGFloat { nativeContentRect.minX }
    private var nativeContentRect: NSRect {
        guard let button = superview as? NSStatusBarButton,
              let cell = button.cell, button.image != nil else { return bounds }
        return cell.imageRect(forBounds: button.bounds)
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        artwork.imageScaling = .scaleProportionallyDown
        artwork.wantsLayer = true
        addSubview(artwork)
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
    private static let cachedStatusFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let cachedBadgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    private var statusFont: NSFont { Self.cachedStatusFont }
    var displayedThinkingPhrase: String {
        guard let phrase = thinkingPhrase, let first = phrase.first else { return "" }
        return String(first).uppercased() + phrase.dropFirst() + "..."
    }
    var badgeText: NSAttributedString {
        NSAttributedString(string: String(running), attributes: [
            .font: Self.cachedBadgeFont,
            .foregroundColor: summaryForeground
        ])
    }
    var badgeWidth: CGFloat { style == .summary && showsThinkingPhrase ? max(13, ceil(badgeText.size().width) + 6) : 0 }
    var badgeFrame: NSRect {
        let naturalX = contentOriginX + iconWidth
        // An open popover freezes the status-item width, possibly before the
        // first running session arrives. Keep the complete badge inside that
        // existing button, using its trailing inset before overlapping artwork.
        let x = constrainsSummaryWidth ? min(naturalX, max(0, bounds.maxX - badgeWidth - 1)) : naturalX
        return NSRect(x: x, y: max(1, (bounds.height - 24) / 2), width: badgeWidth, height: 13)
    }
    var textOriginX: CGFloat { contentOriginX + iconWidth + (style == .activity ? 13 : badgeWidth) + 6 }
    var summaryText: NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        if showsThinkingPhrase {
            result.append(NSAttributedString(string: displayedThinkingPhrase, attributes: [.font: style == .counters ? labelFont : statusFont, .foregroundColor: NSColor.labelColor]))
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
    var counterSummary: NSAttributedString {
        NSAttributedString(string: "\(labels[0]) \(running) · \(labels[1]) \(waiting)",
                           attributes: [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor])
    }
    var statusWidth: CGFloat {
        switch style {
        case .summary:
            return summaryText.length > 0 ? ceil(summaryText.size().width) + 2 : 0
        case .counters:
            return showsThinkingPhrase
                ? ceil(max(summaryText.size().width, counterSummary.size().width)) + 12
                : labelWidth + numberWidth + 18
        case .activity: return activityBubbleVisible ? 14 : 0
        }
    }
    var preferredWidth: CGFloat {
        if style == .activity { return iconWidth + (activityBubbleVisible ? 13 : 0) + (showsThinkingPhrase ? 6 + ceil(summaryText.size().width) + 2 : 0) }
        return iconWidth + badgeWidth + (statusWidth > 0 ? 6 + statusWidth : 0)
    }
    override func layout() {
        super.layout()
        let height = max(26, artwork.image?.size.height ?? 26)
        let frame = NSRect(x: contentOriginX, y: (bounds.height - height) / 2, width: iconWidth, height: height)
        artwork.frame = pixelAlignedArtwork
            ? backingAlignedRect(frame, options: .alignAllEdgesNearest) : frame
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true; needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true; artwork.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    private func drawStatusText(_ text: NSAttributedString, at origin: NSPoint, width: CGFloat) {
        let bounded = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        bounded.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: bounded.length))
        let available = constrainsSummaryWidth ? min(width, max(0, nativeContentRect.maxX - origin.x)) : width
        bounded.draw(in: NSRect(origin: origin, size: NSSize(width: available, height: ceil(text.size().height))))
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
                bounded.draw(in: NSRect(origin: origin, size: NSSize(width: max(0, nativeContentRect.maxX - x), height: ceil(text.size().height))))
            } else {
                text.draw(at: origin)
            }
            return
        }
        if style == .activity {
            if showsThinkingPhrase {
                let text = summaryText
                drawStatusText(text, at: NSPoint(x: x, y: (bounds.height - text.size().height) / 2), width: ceil(text.size().width) + 2)
            }
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
            if let symbol = activityAttentionSymbol {
                let text = NSAttributedString(string: symbol, attributes: [
                    .font: Self.cachedBadgeFont,
                    .foregroundColor: NSColor(srgbRed: 0.16, green: 0.20, blue: 0.27, alpha: 1)
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                return
            }
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
        if showsThinkingPhrase {
            for (index, text) in [summaryText, counterSummary].enumerated() {
                drawStatusText(text, at: NSPoint(x: x + 6, y: capsule.minY + CGFloat(index) * rowHeight + (rowHeight - text.size().height) / 2), width: statusWidth - 12)
            }
            return
        }
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
    private var activityDots = ThinkingDotCycle()
    private var thinkingPhrases = true
    private var icon = MenuBarIcon.system
    private var onlyWhileWorking = true
    private var systemColor = false
    private var running = 0
    private var waiting = 0
    private var observers: [NSObjectProtocol] = []
    private var asleep = false
    private var displayAsleep = false
    private var sessionActive = true
    private var windowObserver: NSObjectProtocol?
    private var renderAvailable: Bool {
        guard visible && !asleep && !displayAsleep && sessionActive else { return false }
        return canRenderAnimation(button?.window)
    }
    private var visible = true
    private var animationStartedAt: TimeInterval?
    private var lastTextState: String?
    private var openPopoverWidth: CGFloat?
    private var updateObserver: AnyCancellable?
    private var updateNotice: String?
    private var lastDiagnosticState: String?
    private let diagnosticsEnabled: Bool
    private let now: () -> TimeInterval
    private let scheduleTimer: @MainActor (Timer) -> Void
    private let canRenderAnimation: @MainActor (NSWindow?) -> Bool

    func setVisible(_ visible: Bool) {
        self.visible = visible
        statusItem?.isVisible = visible
        updateTimer()
    }

    func setUpdateNotice(_ notice: String?) {
        updateNotice = notice
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
            openPopoverWidth = button?.image?.size.width ?? content.preferredWidth
        } else {
            guard openPopoverWidth != nil else { return }
            openPopoverWidth = nil
        }
        content.constrainsSummaryWidth = open
        lastTextState = nil
        drawFrame()
    }

    init(statusItem: NSStatusItem, updates: AppUpdates? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleTimer: @escaping @MainActor (Timer) -> Void = { RunLoop.main.add($0, forMode: .common) },
         canRenderAnimation: @escaping @MainActor (NSWindow?) -> Bool = { window in
             !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                 && (window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? true)
         },
         diagnosticsEnabled: Bool = ProcessInfo.processInfo.environment["LUNAVECT_MENU_BAR_DIAGNOSTICS"] == "1") {
        self.now = now
        self.scheduleTimer = scheduleTimer
        self.canRenderAnimation = canRenderAnimation
        self.diagnosticsEnabled = diagnosticsEnabled
        self.statusItem = statusItem
        self.button = statusItem.button
        statusItem.length = NSStatusItem.variableLength
        if let button = statusItem.button {
            button.title = ""; button.image = nil
            button.imagePosition = .imageOnly
            content.frame = button.bounds
            content.autoresizingMask = [.width, .height]
            button.addSubview(content)
        }
        if let updates {
            updateObserver = updates.$phase.receive(on: RunLoop.main).sink { [weak self, weak updates] _ in
                self?.setUpdateNotice(updates?.notice)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                let name = event.name
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification { self.asleep = true }
                    if name == NSWorkspace.didWakeNotification { self.asleep = false }
                    if name == NSWorkspace.screensDidSleepNotification { self.displayAsleep = true }
                    if name == NSWorkspace.screensDidWakeNotification { self.displayAsleep = false }
                    if name == NSWorkspace.sessionDidResignActiveNotification { self.sessionActive = false }
                    if name == NSWorkspace.sessionDidBecomeActiveNotification { self.sessionActive = true }
                    self.updateTimer()
                }
            })
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] event in
            guard let window = event.object as? NSWindow else { return }
            let windowID = ObjectIdentifier(window)
            MainActor.assumeIsolated {
                guard let self, let ownWindow = self.button?.window,
                      windowID == ObjectIdentifier(ownWindow) else { return }
                self.updateTimer()
            }
        }
    }
    func update(icon: MenuBarIcon, onlyWhileWorking: Bool, systemColor: Bool = false, statusStyle: MenuBarStatusStyle = .summary, thinkingPhrases: Bool = true, running: Int, waiting: Int) {
        if self.icon != icon {
            animationStartedAt = nil
            timer?.invalidate()
            timer = nil
        }
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
        renderAvailable && icon != .system && (!onlyWhileWorking || running > 0)
    }
    private func updateTimer() {
        updatePhrase()
        let animatedStatus = thinkingPhrases || content.style == .activity
        let rotates = renderAvailable && animatedStatus && running > 0 && waiting == 0
        if rotates && phraseTimer == nil {
            let deadline = thinkingPhrases ? phraseCycle.nextStepAt : activityDots.nextStepAt
            let delay = max(0.001, (deadline ?? (now() + ThinkingPhrases.dotInterval)) - now())
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] fired in
                let identity = ObjectIdentifier(fired)
                MainActor.assumeIsolated {
                    guard let self, self.phraseTimer.map(ObjectIdentifier.init) == identity else { return }
                    self.phraseTimer = nil
                    self.updateTimer()
                }
            }
            timer.tolerance = 0.01
            scheduleTimer(timer)
            phraseTimer = timer
        } else if !rotates { phraseTimer?.invalidate(); phraseTimer = nil }
        if shouldAnimate {
            if animationStartedAt == nil { animationStartedAt = now() }
            scheduleNextFrame()
        } else { timer?.invalidate(); timer = nil; animationStartedAt = nil }
        drawFrame()
    }
    private func scheduleNextFrame() {
        guard shouldAnimate, timer == nil else { return }
        let elapsed = max(0, now() - (animationStartedAt ?? now()))
        let delay: TimeInterval
        switch icon {
        case .codex: delay = CodexAnimation.nextFrameDelay(at: elapsed)
        case .claude: delay = ClawdAnimation.nextFrameDelay(at: elapsed)
        default: delay = MenuBarArtwork.cycleDuration / Double(MenuBarArtwork.frameCount)
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] fired in
            let identity = ObjectIdentifier(fired)
            MainActor.assumeIsolated {
                guard let self, self.timer.map(ObjectIdentifier.init) == identity else { return }
                self.timer = nil
                self.drawFrame()
                self.scheduleNextFrame()
            }
        }
        timer.tolerance = delay * 0.1
        scheduleTimer(timer)
        self.timer = timer
    }
    private func updatePhrase() {
        let now = now()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let activeBubble = visible && content.style == .activity && running > 0 && waiting == 0
        _ = activityDots.update(active: activeBubble, at: now, rotates: renderAvailable && !reduceMotion)
        content.activityDotCount = activeBubble && renderAvailable && !reduceMotion ? activityDots.dotCount : 0
        phraseCycle.update(active: visible && thinkingPhrases && running > 0 && waiting == 0,
                           at: now, rotates: renderAvailable && !reduceMotion)
        content.thinkingPhrase = phraseCycle.current
        content.thinkingDotCount = phraseCycle.dotCount
        if content.style == .activity && phraseCycle.current != nil && renderAvailable && !reduceMotion {
            content.activityDotCount = phraseCycle.dotCount
        }
    }
    func drawFrame() {
        recordPlacementDiagnostics()
        let image: NSImage?
        if icon == .system {
            image = NSImage(systemSymbolName: waiting > 0 ? "exclamationmark.bubble" : running > 0 ? "gearshape.2" : "rectangle.stack", accessibilityDescription: nil)
        } else if icon == .claude && !shouldAnimate && running == 0 && waiting == 0 {
            image = ClawdAnimation.idleImage(size: MenuBarStatusContent.artworkSize(for: .claude,
                barHeight: button?.bounds.height ?? NSStatusBar.system.thickness)).map { MenuBarArtwork.styled($0, systemColor: systemColor) }
        } else {
            let original = MenuBarArtwork.image(
                icon, frame: shouldAnimate ? MenuBarArtwork.frame(at: .now) : 0,
                size: MenuBarStatusContent.artworkSize(
                    for: icon, barHeight: button?.bounds.height ?? NSStatusBar.system.thickness),
                elapsed: shouldAnimate ? max(0, now() - (animationStartedAt ?? now())) : 0)
            image = original.map { MenuBarArtwork.styled($0, systemColor: systemColor) }
        }
        let textState = "\(content.style.rawValue)|\(content.running)|\(content.waiting)|\(content.thinkingPhrase ?? "")|\(content.thinkingDotCount)|\(content.activityDotCount)|\(content.language)"
        let imageChanged = content.artwork.image !== image
        let textChanged = textState != lastTextState
        guard imageChanged || textChanged else { return }
        lastTextState = textState
        if imageChanged {
            content.artwork.image = image
            content.artwork.contentTintColor = image?.isTemplate == true ? .labelColor : nil
        }
        let iconWidth = icon == .system ? 20 : (image?.size.width ?? 24)
        let geometryChanged = content.iconWidth != iconWidth || textChanged
        content.iconWidth = iconWidth
        if geometryChanged {
            let width = openPopoverWidth ?? content.preferredWidth
            if button?.image?.size.width != width {
                // Keep the animated view, native click/highlight behavior and native
                // outer insets. Fixed lengths acquire extra padding on newer macOS.
                button?.image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in true }
            }
            if let button { content.frame = button.bounds }
            content.needsLayout = true
        }
        // The image view invalidates itself. Labels only redraw when their
        // content or geometry changes, not on every character frame.
        if geometryChanged { content.needsDisplay = true }
    }
    private func recordPlacementDiagnostics() {
        guard diagnosticsEnabled else { return }
        let window = button?.window
        let state =
            "enabled=\(visible) itemVisible=\(statusItem?.isVisible ?? false) length=\(statusItem?.length ?? -1) windowVisible=\(window?.isVisible ?? false) occlusion=\(window?.occlusionState.rawValue ?? 0) frame=\(NSStringFromRect(window?.frame ?? .zero)) content=\(NSStringFromRect(content.frame)) attached=\(content.superview === button) artwork=\(content.artwork.image != nil) animating=\(shouldAnimate) screen=\(NSStringFromRect(window?.screen?.frame ?? .zero)) rightArea=\(NSStringFromRect(window?.screen?.auxiliaryTopRightArea ?? .zero))"
        guard state != lastDiagnosticState else { return }
        lastDiagnosticState = state
        fputs("Lunavect menu bar: \(state)\n", stderr)
    }
    isolated deinit {
        timer?.invalidate()
        phraseTimer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}

struct MenuBarAppearanceView: View {
    @ObservedObject var appearance: MenuBarAppearance
    var snapshots: [UsageSnapshot] = []
    var providers: [ProviderID] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewStartedAt = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceMetrics.settingsSectionSpacing) {
            sessionSettings
            GroupBox(L("Оформление значка")) {
                iconSettings.padding(InterfaceMetrics.settingsContentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("menu-bar-icon-details")
            MenuBarLimitsSettings(appearance: appearance, snapshots: snapshots, providers: providers)
            if !appearance.limits.enabled && !appearance.showsSessionStatus {
                Text(L("Оба индикатора выключены. Включите лимиты или статус сессий здесь, чтобы вернуть значок в строку меню."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var sessionSettings: some View {
        GroupBox(L("Статус сессий")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $appearance.showsSessionStatus) {
                    Text(L("Показывать значок и статус работы")).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("menu-bar-sessions-enabled")
                if appearance.showsSessionStatus {
                    SettingsChoiceRow(L("Статус сессий")) {
                        Picker(L("Статус сессий"), selection: $appearance.statusStyle) {
                            ForEach(MenuBarStatusStyle.allCases) { style in Text(style.title).tag(style) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("menu-bar-status-style")
                    }
                    Text(appearance.statusStyle.explanation)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsToggleRow(title: L("Живые фразы во время работы"), isOn: $appearance.thinkingPhrases,
                                      detail: L("70 английских фраз. После двух циклов троеточия — новая фраза, и точки начинаются заново. Ожидание ответа важнее фразы."))
                        .accessibilityIdentifier("menu-bar-thinking-phrases")
                    statusPreview
                }
            }.padding(InterfaceMetrics.settingsContentInset).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var previewCaption: String {
        L(appearance.statusStyle == .activity || appearance.thinkingPhrases
          ? "Реальный размер · пример: 2 работают" : "Реальный размер · пример: 2 работают, 1 ждёт ответа")
    }
    private var statusPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(
                .animation(
                    minimumInterval: ThinkingPhrases.dotInterval,
                    paused: reduceMotion || !appearance.previewVisible
                        || (appearance.statusStyle != .activity
                            && !appearance.thinkingPhrases)
                )
            ) { context in
                let elapsed = max(0, context.date.timeIntervalSince(previewStartedAt))
                let phrase = ThinkingPhrases.all[reduceMotion ? 0 : Int(elapsed / ThinkingPhrases.interval) % ThinkingPhrases.all.count]
                MenuBarStatusPreview(appearance: appearance, dotCount: reduceMotion ? 0 : ThinkingPhrases.dotCount(at: elapsed), phrase: phrase)
            }
            .frame(height: NSStatusBar.system.thickness)
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: InterfaceMetrics.selectionCornerRadius))
            .accessibilityElement(children: .ignore).accessibilityLabel(previewCaption)
            Text(previewCaption).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
        }
    }
    private var iconSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsChoiceRow(L("Выбор значка")) {
                Picker(L("Выбор значка"), selection: $appearance.automaticIcon) {
                    Text(L("Автоматически")).tag(true)
                    Text(L("Вручную")).tag(false)
                }.pickerStyle(.segmented).accessibilityIdentifier("menu-bar-auto-icon")
            }
            if appearance.automaticIcon {
                Text(L("Показывает Claude или Codex — у кого больше работающих и ожидающих ответа сессий. При равенстве и после завершения задач сохраняется последний значок."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !appearance.previewVisible)) { context in
                HStack(alignment: .top, spacing: 10) {
                    ForEach([MenuBarIcon.claude, .codex, .lunavect]) { icon in
                        Button { appearance.selectIcon(icon) } label: {
                            VStack(spacing: 7) {
                                if let image = MenuBarArtwork.image(
                                    icon, frame: reduceMotion ? 0 : MenuBarArtwork.frame(at: context.date),
                                    size: 36,
                                    elapsed: reduceMotion
                                        ? 0 : max(0, context.date.timeIntervalSince(previewStartedAt)))
                                {
                                    Image(nsImage: MenuBarArtwork.styled(image, systemColor: appearance.systemColor)).frame(width: 58, height: 36).accessibilityHidden(true)
                                }
                                Text(icon.title).font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity).padding(8)
                            .background(!appearance.automaticIcon && appearance.icon == icon ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(!appearance.automaticIcon && appearance.icon == icon ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).help(icon.motion)
                            .accessibilityLabel(icon.title + ", " + icon.motion)
                            .accessibilityValue(!appearance.automaticIcon && appearance.icon == icon ? L("Выбран") : L("Не выбран"))
                            .accessibilityAddTraits(!appearance.automaticIcon && appearance.icon == icon ? .isSelected : [])
                    }
                }
            }
            SettingsToggleRow(title: L("Системный цвет значка"), isOn: $appearance.systemColor,
                              detail: L("Одноцветный значок автоматически подстраивается под светлую и тёмную строку меню."))
            SettingsToggleRow(title: L("Анимировать только во время работы"), isOn: $appearance.onlyWhileWorking,
                              detail: L("В предпросмотре значки движутся всегда. Системная настройка уменьшения движения останавливает анимацию."))
            Button(!appearance.automaticIcon && appearance.icon == .system ? L("Сейчас используется стандартный значок") : L("Вернуть стандартный значок")) { appearance.selectIcon(.system) }
                .buttonStyle(.link).font(.system(size: 11)).disabled(!appearance.automaticIcon && appearance.icon == .system)
        }
    }
}

struct MenuBarStatusPreview: NSViewRepresentable {
    @ObservedObject var appearance: MenuBarAppearance
    var dotCount = 3
    var phrase = "vibing"
    func makeNSView(context: Context) -> MenuBarStatusContent {
        MenuBarStatusContent(frame: NSRect(x: 0, y: 0, width: 180, height: NSStatusBar.system.thickness))
    }
    func updateNSView(_ view: MenuBarStatusContent, context: Context) {
        view.style = appearance.statusStyle; view.running = 2
        view.waiting = appearance.statusStyle == .activity || appearance.thinkingPhrases ? 0 : 1
        view.thinkingPhrase = appearance.thinkingPhrases ? phrase : nil
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
