import SwiftUI

/// A single, small geometric alphabet for controls inside Lunavect.
/// Provider identities and the selected application artwork are separate assets.
enum InterfaceGlyph: CaseIterable {
    case power, refresh, settings, search, history, back, forward, down, close
    case eye, hidden, restore, trash, more, pin, calendar, bell, link, menuBar, widget
    case limits, sessions, check, checkCircle, circle, warning, info, activity, globe, shield, external, open
}

struct InterfaceIcon: View {
    let glyph: InterfaceGlyph
    var size: CGFloat = 16
    init(_ glyph: InterfaceGlyph, size: CGFloat = 16) { self.glyph = glyph; self.size = size }
    var body: some View {
        InterfaceIconShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: max(1.15, size * 0.085), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct InterfaceLabel: View {
    var title: String
    var glyph: InterfaceGlyph
    var size: CGFloat = 14
    init(_ title: String, _ glyph: InterfaceGlyph, size: CGFloat = 14) {
        self.title = title; self.glyph = glyph; self.size = size
    }
    var body: some View { Label { Text(title) } icon: { InterfaceIcon(glyph, size: size) } }
}

struct InterfaceIconShape: Shape {
    let glyph: InterfaceGlyph
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { p.addEllipse(in: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 2.5) {
            p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
        }
        func check() { line([(7.5,12),(10.5,15),(16.5,9)]) }
        switch glyph {
        case .power:
            p.addArc(center: CGPoint(x: 12, y: 13), radius: 8, startAngle: .degrees(-50), endAngle: .degrees(230), clockwise: false)
            line([(12,2.5),(12,12)])
        case .refresh:
            p.addArc(center: CGPoint(x: 12, y: 12), radius: 8, startAngle: .degrees(37), endAngle: .degrees(310), clockwise: false)
            line([(18,3.8),(18,8.2),(13.6,8.2)])
        case .settings:
            line([(4,6),(10,6)]); line([(14,6),(20,6)])
            line([(4,12),(5,12)]); line([(9,12),(20,12)])
            line([(4,18),(14,18)]); line([(18,18),(20,18)])
            circle(12,6,2); circle(7,12,2); circle(16,18,2)
        case .search:
            circle(10.5,10.5,6.5); line([(15.5,15.5),(20.5,20.5)])
        case .history:
            p.addArc(center: CGPoint(x: 12, y: 12), radius: 8.5, startAngle: .degrees(190), endAngle: .degrees(495), clockwise: false)
            line([(3.5,3.5),(3.5,8.5),(8.5,8.5)]); line([(12,7.5),(12,12),(15.5,14)])
        case .back: line([(13,5),(6,12),(13,19)]); line([(6,12),(21,12)])
        case .forward: line([(10,5),(17,12),(10,19)])
        case .down: line([(5,9),(12,16),(19,9)])
        case .close: line([(6,6),(18,18)]); line([(18,6),(6,18)])
        case .eye:
            p.move(to: CGPoint(x: 2, y: 12))
            p.addCurve(to: CGPoint(x: 12, y: 5), control1: CGPoint(x: 3.7, y: 7.7), control2: CGPoint(x: 7.6, y: 5))
            p.addCurve(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 16.4, y: 5), control2: CGPoint(x: 20.3, y: 7.7))
            p.addCurve(to: CGPoint(x: 12, y: 19), control1: CGPoint(x: 20.3, y: 16.3), control2: CGPoint(x: 16.4, y: 19))
            p.addCurve(to: CGPoint(x: 2, y: 12), control1: CGPoint(x: 7.6, y: 19), control2: CGPoint(x: 3.7, y: 16.3))
            p.closeSubpath()
            circle(12,12,3)
        case .hidden:
            p.move(to: CGPoint(x: 3, y: 12)); p.addQuadCurve(to: CGPoint(x: 21, y: 12), control: CGPoint(x: 12, y: -1))
            p.addQuadCurve(to: CGPoint(x: 3, y: 12), control: CGPoint(x: 12, y: 25))
            circle(12,12,3); line([(3,3),(21,21)])
        case .restore:
            line([(8,4),(3,9),(8,14)]); line([(3,9),(14,9)])
            p.addCurve(to: CGPoint(x: 14, y: 21), control1: CGPoint(x: 23, y: 9), control2: CGPoint(x: 23, y: 21))
        case .trash:
            line([(4,6),(20,6)]); line([(9,6),(9,3),(15,3),(15,6)])
            line([(6,6),(7,21),(17,21),(18,6)]); line([(10,10),(10,17)]); line([(14,10),(14,17)])
        case .more: circle(5,12,1); circle(12,12,1); circle(19,12,1)
        case .pin:
            line([(8,3),(16,3),(16,10),(19,14),(5,14),(8,10),(8,3)]); line([(12,14),(12,22)])
        case .calendar:
            box(3,5,18,16); line([(7,2.5),(7,7.5)]); line([(17,2.5),(17,7.5)]); line([(3,10),(21,10)])
            line([(7,14),(10,14)]); line([(14,14),(17,14)]); line([(7,17.5),(10,17.5)])
        case .bell:
            p.move(to: CGPoint(x: 5,y: 16)); p.addQuadCurve(to: CGPoint(x: 6,y: 8), control: CGPoint(x: 6,y: 13))
            p.addCurve(to: CGPoint(x: 18,y: 8), control1: CGPoint(x: 6,y: 0), control2: CGPoint(x: 18,y: 0))
            p.addQuadCurve(to: CGPoint(x: 19,y: 16), control: CGPoint(x: 18,y: 13))
            line([(4,17),(20,17)]); p.move(to: CGPoint(x: 9,y: 20)); p.addQuadCurve(to: CGPoint(x: 15,y: 20), control: CGPoint(x: 12,y: 24))
        case .link:
            line([(10,7),(13,4)])
            p.addCurve(to: CGPoint(x:20,y:11), control1: CGPoint(x:18,y:-1), control2: CGPoint(x:25,y:6))
            p.addLine(to: CGPoint(x:17,y:14))
            line([(7,10),(4,13)])
            p.addCurve(to: CGPoint(x:11,y:20), control1: CGPoint(x:-1,y:18), control2: CGPoint(x:6,y:25))
            p.addLine(to: CGPoint(x:14,y:17)); line([(8,16),(16,8)])
        case .menuBar:
            box(2.5,4,19,16); line([(2.5,9),(21.5,9)]); line([(15,6.5),(18,6.5)])
        case .widget:
            box(3,3,7.5,7.5,2); box(13.5,3,7.5,7.5,2); box(3,13.5,18,7.5,2)
        case .sessions:
            box(3,3,14,13); line([(7,20),(19,20),(21,18),(21,7)]); line([(7,7),(13,7)]); line([(7,11),(11,11)])
        case .check: check()
        case .checkCircle: circle(12,12,9); check()
        case .circle: circle(12,12,9)
        case .warning:
            line([(12,3),(22,21),(2,21),(12,3)]); line([(12,9),(12,14)]); circle(12,17.5,0.45)
        case .info:
            circle(12,12,9); line([(12,11),(12,17)]); circle(12,7,0.45)
        case .limits:
            box(3,5,18,14); line([(7,9),(17,9)]); line([(7,15),(12,15)])
        case .activity: line([(2,12),(6,12),(9,5),(14,20),(17,12),(22,12)])
        case .globe:
            circle(12,12,9); p.addEllipse(in: CGRect(x:8,y:3,width:8,height:18)); line([(3,12),(21,12)])
        case .shield:
            line([(12,2.5),(20,6),(20,13)])
            p.addQuadCurve(to: CGPoint(x:12,y:22), control: CGPoint(x:20,y:18))
            p.addQuadCurve(to: CGPoint(x:4,y:13), control: CGPoint(x:4,y:18))
            line([(4,13),(4,6),(12,2.5)]); check()
        case .external:
            line([(13,3),(21,3),(21,11)]); line([(21,3),(10,14)]); line([(8,4),(3,4),(3,21),(20,21),(20,16)])
        case .open:
            line([(14,3),(4,3),(4,21),(14,21)]); line([(10,12),(22,12)]); line([(17,7),(22,12),(17,17)])
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct InterfaceToolbarStyle: ButtonStyle {
    var selected = false
    var active = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: InterfaceMetrics.compactControlSize, height: InterfaceMetrics.compactControlSize)
            .foregroundStyle(active ? Color.orange : Color.primary.opacity(0.8))
            .background(active ? Color.orange.opacity(0.12) : selected || configuration.isPressed ? Color.primary.opacity(0.09) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(active ? 0 : 0.055), lineWidth: 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
