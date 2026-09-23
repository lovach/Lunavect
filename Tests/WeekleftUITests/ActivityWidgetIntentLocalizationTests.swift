import AppIntents
import Foundation
import XCTest
@testable import Weekleft
@testable import WeekleftCore

final class ActivityWidgetIntentLocalizationTests: XCTestCase {
    private let languages = ["en", "ru", "de", "es", "fr", "zh-Hans"]

    // Golden UI labels, separate from the shipping .strings tables. The resources
    // below come from production metadata, not source-code matching.
    private let expected: [String: [String]] = [
        "en": ["Period", "Day", "Week", "Month", "Source", "Select activity point", "Date", "Period", "Source", "Widget"],
        "ru": ["Период", "День", "Неделя", "Месяц", "Источник", "Выбрать точку активности", "Дата", "Период", "Источник", "Виджет"],
        "de": ["Zeitraum", "Tag", "Woche", "Monat", "Quelle", "Aktivitätspunkt wählen", "Datum", "Zeitraum", "Quelle", "Widget"],
        "es": ["Periodo", "Día", "Semana", "Mes", "Fuente", "Elegir punto de actividad", "Fecha", "Periodo", "Fuente", "Widget"],
        "fr": ["Période", "Jour", "Semaine", "Mois", "Source", "Choisir un point d’activité", "Date", "Période", "Source", "Widget"],
        "zh-Hans": ["时段", "日", "周", "月", "来源", "选择活动数据点", "日期", "时段", "来源", "小组件"]
    ]

    func testMetadataResolvesInEverySupportedSystemLanguage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LunavectIntentLocalization-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.weekleft.tests.intent-localization",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": languages
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let shippingResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LunavectWidget/Resources")
        for language in languages {
            try FileManager.default.copyItem(
                at: shippingResources.appendingPathComponent("\(language).lproj"),
                to: resources.appendingPathComponent("\(language).lproj")
            )
        }
        try assertMetadataResolves(in: XCTUnwrap(Bundle(url: directory)))
    }

    // Optional packaging check: pass a JSON array containing unsigned app and
    // appex bundle paths. It opens resource bundles only; it never launches them.
    func testBuiltAppAndWidgetContainResolvableIntentMetadata() throws {
        guard let paths = ProcessInfo.processInfo.environment["LUNAVECT_INTENT_BUNDLE_PATHS"] else {
            throw XCTSkip("Set LUNAVECT_INTENT_BUNDLE_PATHS to a JSON array of built app and widget paths")
        }
        let bundlePaths = try JSONDecoder().decode([String].self, from: Data(paths.utf8))
        XCTAssertEqual(bundlePaths.count, 2, "Check the app and its WidgetKit extension")
        for path in bundlePaths {
            let bundle = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: path)), path)
            try assertMetadataResolves(in: bundle)
        }
    }

    private func assertMetadataResolves(in bundle: Bundle, file: StaticString = #filePath, line: UInt = #line) throws {
        let intent = SelectActivityPointIntent()
        let metadata: [LocalizedStringResource] = [
            ActivityPeriod.typeDisplayRepresentation.name,
            try XCTUnwrap(ActivityPeriod.caseDisplayRepresentations[.day]).title,
            try XCTUnwrap(ActivityPeriod.caseDisplayRepresentations[.week]).title,
            try XCTUnwrap(ActivityPeriod.caseDisplayRepresentations[.month]).title,
            ActivitySource.typeDisplayRepresentation.name,
            SelectActivityPointIntent.title,
            intent.$date.title, intent.$period.title, intent.$source.title, intent.$kind.title
        ]
        let sources = try [ActivitySource.all, .claude, .codex, .comparison].map {
            try XCTUnwrap(ActivitySource.caseDisplayRepresentations[$0]).title
        }
        for language in languages {
            let labels = metadata.map { resolve($0, in: bundle, language: language) }
            XCTAssertEqual(labels, expected[language], "\(bundle.bundleURL.path): \(language)", file: file, line: line)
            XCTAssertEqual(sources.map { resolve($0, in: bundle, language: language) },
                           ["Claude + Codex", "Claude", "Codex", "Claude + Codex"], language, file: file, line: line)
        }
    }

    private func resolve(_ metadata: LocalizedStringResource, in bundle: Bundle, language: String) -> String {
        // The shipped values are literal key/default pairs. Relocate that same
        // deferred reference to an isolated or built bundle, then let Foundation
        // perform the requested system locale lookup exactly as an intent host does.
        let resource = LocalizedStringResource(metadata.defaultValue, table: metadata.table,
                                              locale: Locale(identifier: language), bundle: .atURL(bundle.bundleURL))
        XCTAssertEqual(resource.key, metadata.key)
        return String(localized: resource)
    }
}
