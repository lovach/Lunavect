import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

/// Proposals for a user choice, deliberately outside the production navigation.
/// No stores, account access, persistence, permissions, or shown windows are used.
final class NavigationDirectionsRenderingTests: XCTestCase {
    @MainActor func testNativeNavigationDirections() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_NAVIGATION_DIRECTIONS"] else {
            throw XCTSkip("Opt-in isolated native navigation proposals")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] ?? "ru"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-12T14:00:00Z"))
        let fixture = try PresentationFixture(now: now)
        for scheme in [ColorScheme.light, .dark] {
            for direction in NavigationDirection.allCases {
                for onboarding in [false, true] {
                    let filename = "direction-\(direction.rawValue)-\(onboarding ? "onboarding" : "main")-\(language)-\(scheme == .light ? "light" : "dark").png"
                    try render(NavigationDirectionPreview(direction: direction, fixture: fixture,
                                                          words: NavigationSampleWords(language: language), onboarding: onboarding),
                               scheme: scheme, url: directory.appendingPathComponent(filename))
                }
            }
        }
    }

    func testPreviewPracticeIsReversibleAndKeepsSourceFixture() throws {
        let fixture = try PresentationFixture()
        let original = fixture.sessions()
        var practice = NavigationSamplePractice()
        let example = try XCTUnwrap(original.first { $0.phase == .permission })
        practice.hide(example)
        XCTAssertEqual(practice.visible(original).count, original.count - 1)
        XCTAssertTrue(practice.tried)
        XCTAssertEqual(original.filter { $0.phase == .running }.count, 1)
        XCTAssertEqual(original.filter { $0.phase == .permission }.count, 1)
        practice.restore()
        XCTAssertEqual(practice.visible(original), original)
        XCTAssertEqual(fixture.sessions(), original)
    }

    @MainActor private func render<V: View>(_ content: V, scheme: ColorScheme, url: URL) throws {
        let size = CGSize(width: 1040, height: 720)
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height).preferredColorScheme(scheme))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        }
        host.needsDisplay = true; host.displayIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private enum NavigationDirection: String, CaseIterable { case a, b }
private enum NavigationSamplePage: CaseIterable, Hashable { case sessions, limits, statistics, settings }

private struct NavigationSampleWords {
    let language: String
    func callAsFunction(_ ru: String, _ de: String) -> String { language == "de" ? de : ru }
    func title(_ page: NavigationSamplePage) -> String {
        switch page {
        case .sessions: return self("Сессии", "Sitzungen")
        case .limits: return self("Лимиты", "Limits")
        case .statistics: return self("Статистика", "Statistik")
        case .settings: return self("Настройки", "Einstellungen")
        }
    }
    func glyph(_ page: NavigationSamplePage) -> InterfaceGlyph {
        switch page {
        case .sessions: return .sessions
        case .limits: return .limits
        case .statistics: return .activity
        case .settings: return .settings
        }
    }
}

private struct NavigationSamplePractice {
    var hidden: Set<String> = []
    var tried = false
    mutating func hide(_ session: AgentSession) { hidden.insert(session.id); tried = true }
    mutating func restore() { hidden.removeAll() }
    func visible(_ sessions: [AgentSession]) -> [AgentSession] { sessions.filter { !hidden.contains($0.id) } }
}

@MainActor private struct NavigationDirectionPreview: View {
    let direction: NavigationDirection
    let fixture: PresentationFixture
    let words: NavigationSampleWords
    @State var onboarding: Bool
    @State private var page = NavigationSamplePage.sessions
    @State private var waitingOnly = false
    @State private var selectedSession: String?
    @State private var practice = NavigationSamplePractice()
    @State private var onboardingStep = 1
    @State private var settingsRow = ""
    private var samples: [AgentSession] {
        fixture.sessions().enumerated().map { index, original in
            var session = original
            session.title = [words("Собрать новый экран обучения", "Neue Einführung umsetzen"),
                             words("Проверить список перед выпуском", "Checkliste vor Veröffentlichung prüfen"),
                             words("Уточнить тексты настроек", "Texte der Einstellungen überarbeiten")][index]
            return session
        }
    }
    private var visible: [AgentSession] { practice.visible(samples) }
    private var filtered: [AgentSession] { visible.filter { !waitingOnly || $0.phase == .permission || $0.phase == .input } }
    private var chartData: ActivityChartData { ActivityChartData(history: fixture.history, now: fixture.now, providers: [.claude, .codex]) }

    var body: some View {
        Group {
            if direction == .a {
                HStack(spacing: 0) { sidebar; Divider(); workspaceA }
            } else {
                VStack(spacing: 0) { topNavigation; Divider(); workspaceB }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            if let mark = AppArtwork.brandMark { Image(nsImage: mark).resizable().scaledToFit().frame(width: 32, height: 32) }
            Text("Lunavect").font(.system(size: 17, weight: .semibold))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            brand.padding(.top, 6)
            VStack(alignment: .leading, spacing: 7) {
                Text(words("РАБОЧЕЕ ПРОСТРАНСТВО", "ARBEITSBEREICH")).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 3)
                ForEach([NavigationSamplePage.sessions, .limits, .statistics], id: \.self) { item in navigationRow(item) }
            }
            Spacer(minLength: 0)
            Button { onboarding.toggle(); page = .sessions } label: {
                HStack(spacing: 9) {
                    InterfaceIcon(.info, size: 14)
                    Text(words("Короткое обучение", "Kurze Einführung")).font(.system(size: 12))
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Divider()
            navigationRow(.settings)
            Text("Claude + Codex").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 196).background(.primary.opacity(0.025))
    }

    private func navigationRow(_ item: NavigationSamplePage) -> some View {
        Button { page = item; onboarding = false } label: {
            HStack(spacing: 10) {
                InterfaceIcon(words.glyph(item), size: 16).foregroundStyle(page == item ? Color.accentColor : .secondary)
                Text(words.title(item)).font(.system(size: 13, weight: page == item ? .semibold : .regular))
                Spacer(minLength: 0)
                if item == .sessions { Text("\(visible.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 11)
                .background(.primary.opacity(page == item ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var topNavigation: some View {
        HStack(spacing: 26) {
            brand
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach([NavigationSamplePage.sessions, .limits, .statistics], id: \.self) { item in
                    Button { page = item; onboarding = false } label: {
                        Text(words.title(item)).font(.system(size: 12, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(.primary.opacity(page == item ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }.padding(3).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9)).frame(width: 352)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Circle().fill(.blue).frame(width: 5, height: 5); Text("\(visible.filter { $0.phase == .running }.count)")
                Circle().fill(.orange).frame(width: 5, height: 5); Text("\(visible.filter { $0.phase == .permission || $0.phase == .input }.count)")
            }.font(.system(size: 12, weight: .medium)).monospacedDigit()
                .help(words("Работают · Ждут ответа", "Arbeiten · Warten auf Antwort"))
            Button { page = .settings; onboarding = false } label: { InterfaceIcon(.settings, size: 19).frame(width: 28, height: 28) }
                .buttonStyle(.plain).help(words.title(.settings))
        }.padding(.horizontal, 26).frame(height: 76)
    }

    private var workspaceA: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: onboarding ? words("Освойтесь на своей панели", "Lernen Sie Ihre Übersicht kennen") : words.title(page),
                subtitle: onboarding
                    ? words(
                        "Попробуйте привычные действия на учебных сессиях.",
                        "Probieren Sie vertraute Aktionen mit Beispielsitzungen aus.")
                    : words(
                        "Вся работа — по проектам, с нужными данными рядом.",
                        "Ihre Arbeit nach Projekten, mit den wichtigsten Daten daneben."))
            Divider()
            if page == .sessions {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 20) {
                        sessionControls
                        projectQueue
                        if !practice.hidden.isEmpty { restoreRow }
                        Spacer(minLength: 0)
                        Text(
                            onboarding
                                ? words("УЧЕБНЫЙ ПРИМЕР", "ÜBUNGSBEISPIEL")
                                : words(
                                    "Сессий: \(visible.count) · Проектов: \(Set(visible.map(\.project)).count)",
                                    "Sitzungen: \(visible.count) · Projekte: \(Set(visible.map(\.project)).count)")
                        )
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if onboarding { checklist.frame(width: 254) }
                    else { overviewRail.frame(width: 300) }
                }.padding(24)
            } else { destinationContent.padding(24) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var workspaceB: some View {
        Group {
            if onboarding { onboardingB }
            else {
                VStack(alignment: .leading, spacing: 22) {
                    header(title: page == .sessions ? words("Что требует внимания", "Was Ihre Aufmerksamkeit braucht") : words.title(page),
                           subtitle: words("Ответьте ожидающим и вернитесь к текущей работе.", "Beantworten Sie offene Fragen und arbeiten Sie weiter."), padded: false)
                    if page == .sessions {
                        HStack(alignment: .top, spacing: 30) {
                            VStack(alignment: .leading, spacing: 20) {
                                sessionControls
                                priorityQueue
                                if !practice.hidden.isEmpty { restoreRow }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 18) {
                                Text(words("Перед продолжением", "Bevor Sie fortfahren")).font(.system(size: 13, weight: .semibold))
                                Text(words("Ожидающая сессия продолжит работу после вашего ответа в Codex.", "Die wartende Sitzung arbeitet nach Ihrer Antwort in Codex weiter."))
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                                Divider()
                                Text(words("Лимиты и история всегда доступны в верхних вкладках.", "Limits und Verlauf sind jederzeit über die oberen Tabs erreichbar."))
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                                Button(words("Пройти короткое обучение", "Kurze Einführung starten")) { onboarding = true }
                                    .buttonStyle(.link)
                            }.padding(20).frame(width: 280, alignment: .leading)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                        }
                        Spacer(minLength: 0)
                        HStack {
                            InterfaceIcon(.history, size: 13)
                            Text(words("Завершённые сессии остаются под рукой. Скрытые можно вернуть.", "Abgeschlossene Sitzungen bleiben erreichbar. Ausgeblendete lassen sich wiederherstellen."))
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                    } else { destinationContent }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func header(title: String, subtitle: String, padded: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 24, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if onboarding {
                    Text(words("Учебный пример", "Übungsbeispiel")).font(.system(size: 10, weight: .medium)).padding(
                        .horizontal, 9
                    ).padding(.vertical, 5).background(.primary.opacity(0.06), in: Capsule())
                }
            }
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(padded ? 24 : 0)
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 18) {
                counter(visible.filter { $0.phase == .running }.count, words("работает", "arbeitet"), color: .blue)
                counter(visible.filter { $0.phase == .permission || $0.phase == .input }.count, words("ждёт ответа", "wartet auf Antwort"), color: .orange)
            }
            HStack(spacing: 7) {
                filterButton(words("Все", "Alle"), selected: !waitingOnly) { waitingOnly = false }
                filterButton(words("Ждут ответа", "Warten auf Antwort"), selected: waitingOnly) { waitingOnly = true }
            }
        }
    }

    private func counter(_ value: Int, _ label: String, color: Color) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 5, height: 5); Text("\(value) " + label) }
            .font(.system(size: 12, weight: .medium)).monospacedDigit()
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { if selected { InterfaceIcon(.check, size: 11) }; Text(title) }
                .font(.system(size: 11, weight: selected ? .semibold : .regular)).padding(.horizontal, 9).padding(.vertical, 6)
                .background(.primary.opacity(selected ? 0.09 : 0.025), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var projectQueue: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(["Lunavect", "Atlas"], id: \.self) { project in
                let rows = filtered.filter { $0.project == project }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            InterfaceIcon(.sessions, size: 13).foregroundStyle(.secondary)
                            Text(project).font(.system(size: 13, weight: .semibold))
                            Spacer(); Text("\(rows.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(rows) { sampleRow($0) }
                    }
                }
            }
        }
    }

    private var priorityQueue: some View {
        VStack(alignment: .leading, spacing: 22) {
            queueSection(words("НУЖЕН ВАШ ОТВЕТ", "IHRE ANTWORT WIRD BENÖTIGT"), phases: [.permission, .input])
            queueSection(words("В РАБОТЕ", "IN ARBEIT"), phases: [.running])
            queueSection(words("ГОТОВО", "ABGESCHLOSSEN"), phases: [.ready])
        }
    }

    @ViewBuilder private func queueSection(_ title: String, phases: [SessionPhase]) -> some View {
        let rows = filtered.filter { phases.contains($0.phase) }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(rows) { sampleRow($0) }
            }
        }
    }

    private func sampleRow(_ session: AgentSession) -> some View {
        NavigationSafeSessionRow(session: session, now: fixture.now, selected: selectedSession == session.id,
                                 select: { selectedSession = session.id }, hide: { practice.hide(session) })
    }

    private var restoreRow: some View {
        HStack {
            Text(words("Пример скрыт", "Beispiel ausgeblendet")).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button(words("Вернуть", "Wiederherstellen")) { practice.restore() }.controlSize(.small)
        }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private var overviewRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(words("Остаток на неделю", "Diese Woche übrig")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { page = .limits } label: { InterfaceIcon(.forward, size: 12) }.buttonStyle(.plain)
            }
            LimitsProviderSummary(snapshot: fixture.snapshots[0], showFiveHour: false, now: fixture.now)
            LimitsProviderSummary(snapshot: UsageSnapshot(provider: .codex), showFiveHour: false, now: fixture.now)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(words("Активность за неделю", "Aktivität dieser Woche")).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Button { page = .statistics } label: { InterfaceIcon(.forward, size: 12) }.buttonStyle(.plain)
                }
                ActivitySeriesLegend(data: chartData, unavailable: false, foreground: .primary)
                ActivityTrendPlot(data: chartData, selectedDate: nil, foreground: .primary, adaptiveColors: true, cleanContour: true)
                    .frame(height: 88).allowsHitTesting(false).accessibilityHidden(true)
                Text(words("По доступным записям", "Aus verfügbaren Aufzeichnungen")).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(words("Три коротких шага", "Drei kurze Schritte")).font(.system(size: 16, weight: .semibold))
            checklistItem(words("Выберите приложение", "Wählen Sie eine App"),
                          detail: words("Claude или Codex. Достаточно одного.", "Claude oder Codex. Eine App genügt."), done: true)
            checklistItem(words("Попробуйте управление", "Probieren Sie die Bedienung"),
                          detail: words("Скройте пример и верните его в список.", "Blenden Sie ein Beispiel aus und stellen Sie es wieder her."), done: practice.tried)
            if let example = samples.first(where: { $0.phase == .permission }) {
                Button(words(practice.hidden.isEmpty ? "Скрыть пример" : "Вернуть пример", practice.hidden.isEmpty ? "Beispiel ausblenden" : "Beispiel wiederherstellen")) {
                    if practice.hidden.isEmpty { practice.hide(example) } else { practice.restore() }
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            checklistItem(words("Вернитесь к работе", "Arbeiten Sie weiter"),
                          detail: words("Лимиты и статистика уже находятся слева.", "Limits und Statistik finden Sie links."), done: false)
            Divider()
            Text(words("Проба меняет только учебный список.", "Die Übung verändert nur diese Beispielliste."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(words("Открыть рабочую панель", "Arbeitsübersicht öffnen")) { onboarding = false; practice.restore() }
                .controlSize(.small)
        }.padding(18).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func checklistItem(_ title: String, detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            InterfaceIcon(done ? .checkCircle : .circle, size: 17).foregroundStyle(done ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onboardingB: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 0) {
                stepMarker(0, words("Приложение", "App")); Spacer()
                stepMarker(1, words("Проба действия", "Aktion ausprobieren")); Spacer()
                stepMarker(2, words("Готово", "Fertig"))
            }
            Divider()
            HStack(alignment: .top, spacing: 44) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(words("Попробуйте на примере", "Probieren Sie es aus")).font(.system(size: 27, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        words(
                            "Скрыть — значит убрать сессию из списка Lunavect. Сама задача продолжит работу.",
                            "Ausblenden entfernt die Sitzung aus der Lunavect-Liste. Die Aufgabe arbeitet weiter.")
                    )
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        InterfaceLabel(words("1. Скройте учебную строку", "1. Beispielzeile ausblenden"), .hidden, size: 15)
                        InterfaceLabel(words("2. Верните её в список", "2. Zeile wiederherstellen"), .restore, size: 15)
                    }.font(.system(size: 13)).padding(.top, 8)
                }.frame(width: 310, alignment: .leading)
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(words("УЧЕБНАЯ ПАНЕЛЬ", "ÜBUNGSANSICHT")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(words("Можно отменить", "Rückgängig möglich")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let example = samples.first(where: { $0.phase == .permission }) {
                        if practice.hidden.contains(example.id) { restoreRow }
                        else { sampleRow(example) }
                        Button(words(practice.hidden.isEmpty ? "Скрыть пример" : "Вернуть пример", practice.hidden.isEmpty ? "Beispiel ausblenden" : "Beispiel wiederherstellen")) {
                            if practice.hidden.isEmpty { practice.hide(example) } else { practice.restore() }
                        }.buttonStyle(.borderedProminent)
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 9) {
                        InterfaceIcon(.info, size: 15).foregroundStyle(.secondary)
                        Text(words("Учебная проба не открывает приложения и не меняет настоящие сессии.", "Diese Übung öffnet keine Apps und verändert keine echten Sitzungen."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if practice.tried {
                        Text(
                            words(
                                "Получилось. Пример можно вернуть в любой момент.",
                                "Geschafft. Sie können das Beispiel jederzeit wiederherstellen.")
                        ).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button(words("Пропустить обучение", "Einführung überspringen")) { onboarding = false; practice.restore() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text(words("Шаг 2 из 3", "Schritt 2 von 3")).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(words("Открыть сессии", "Sitzungen öffnen")) { onboardingStep = 2; onboarding = false; practice.restore() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stepMarker(_ index: Int, _ title: String) -> some View {
        HStack(spacing: 9) {
            Group {
                if index < onboardingStep { InterfaceIcon(.check, size: 12) }
                else { Text("\(index + 1)").font(.system(size: 12, weight: .semibold)) }
            }.frame(width: 28, height: 28).background(.primary.opacity(index == onboardingStep ? 0.10 : 0.035), in: Circle())
            Text(title).font(.system(size: 12, weight: index == onboardingStep ? .semibold : .regular))
                .foregroundStyle(index == onboardingStep ? .primary : .secondary)
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch page {
        case .limits:
            VStack(alignment: .leading, spacing: 18) {
                LimitsProviderSummary(snapshot: fixture.snapshots[0], showFiveHour: true, now: fixture.now)
                LimitsProviderSummary(snapshot: UsageSnapshot(provider: .codex), showFiveHour: true, now: fixture.now)
            }
        case .statistics:
            ActivityDetailChart(data: chartData, chartHeight: 160, onSelection: { _ in })
        case .settings:
            VStack(alignment: .leading, spacing: 10) {
                ForEach([words("Подключения", "Verbindungen"), words("Оформление", "Darstellung"), words("Уведомления", "Mitteilungen"), words("Виджеты", "Widgets")], id: \.self) { title in
                    Button { settingsRow = title } label: {
                        HStack { Text(title); Spacer(); InterfaceIcon(.forward, size: 12) }
                            .padding(16).background(.primary.opacity(settingsRow == title ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                Button(words("Повторить обучение", "Einführung wiederholen")) { onboarding = true; page = .sessions }
            }.font(.system(size: 13))
        case .sessions: EmptyView()
        }
    }
}

/// Production row appearance; native opening/menu/AX actions are unreachable.
/// The overlay's actions are limited to the proposal's local selection and hidden set.
@MainActor private struct NavigationSafeSessionRow: View {
    let session: AgentSession
    let now: Date
    let selected: Bool
    let select: () -> Void
    let hide: () -> Void
    @StateObject private var swipe = SessionSwipePresentation()
    var body: some View {
        SessionRow(session: session, now: now, phase: session.phase, swipePresentation: swipe,
                   onHide: hide, onError: { _ in }, isFocused: selected)
            .allowsHitTesting(false).accessibilityHidden(true)
            .overlay {
                Button(action: select) { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(session.title)
                    .contextMenu { Button(L("Убрать из Lunavect"), action: hide) }
            }
    }
}
