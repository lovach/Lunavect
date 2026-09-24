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

    /// The app follows the first supported system language; for any other
    /// language macOS, Sparkle and the widget fall back to English, like the app.
    func testUnsupportedSystemLanguagesFallBackToEnglishEverywhere() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Config/App-Info.plist", "Config/Widget-Info.plist"] {
            let info = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent(name)), name)
            XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en", name)
        }
        XCTAssertEqual(AppLanguage.resolve("system", preferred: ["ja-JP"]), "en")
        XCTAssertEqual(AppLanguage.resolve("system", preferred: ["ja-JP", "de-AT"]), "de")
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en"] + languages, forPreferences: ["ja"]).first, "en")
    }

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
        let usedKeys = Set(try intentLabels().map(\.key)).union(widgetOnlyKeys)
        for language in languages {
            try FileManager.default.copyItem(
                at: shippingResources.appendingPathComponent("\(language).lproj"),
                to: resources.appendingPathComponent("\(language).lproj")
            )
            // Every shipped key must be a label the intents use: no dead or missing entries.
            let table = try XCTUnwrap(NSDictionary(contentsOf: shippingResources
                .appendingPathComponent("\(language).lproj/Localizable.strings")) as? [String: String], language)
            XCTAssertEqual(Set(table.keys), usedKeys, language)
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
            try assertPackagedMetadata(in: bundle)
        }
    }

    /// The system reads the extracted Metadata.appintents, not the Swift values.
    /// Require it, its intents, and a translation for every label it shows.
    private func assertPackagedMetadata(in bundle: Bundle) throws {
        let resources = bundle.bundleURL.appendingPathComponent("Contents/Resources")
        let url = resources.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.path)
        let actions = try XCTUnwrap(root["actions"] as? [String: Any], url.path)
        let widget = bundle.bundleURL.pathExtension == "appex"
        XCTAssertNotNil(actions["SelectActivityPointIntent"], url.path)
        XCTAssertEqual(actions["ActivityConfiguration"] != nil, widget, url.path)
        let enums = (root["enums"] as? [[String: Any]] ?? []).compactMap { $0["identifier"] as? String }
        XCTAssertEqual(Set(enums), ["ActivityPeriod", "ActivitySource"], url.path)
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["alternatives"] != nil, let key = object["key"] as? String { keys.insert(key) }
                object.values.forEach(collect)
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        collect(root)
        let brands: Set<String> = ["Claude + Codex", "Claude", "Codex"]
        XCTAssertTrue(keys.isSuperset(of: brands.union(["Period", "Source", "Select activity point"])), url.path)
        for language in languages {
            let table = NSDictionary(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings")) as? [String: String] ?? [:]
            XCTAssertTrue(keys.subtracting(brands).isSubset(of: Set(table.keys)),
                          "\(bundle.bundleURL.lastPathComponent) \(language): untranslated \(keys.subtracting(brands).subtracting(table.keys).sorted())")
        }
    }

    // ActivityConfiguration.title: that intent is compiled only into the widget target.
    private let widgetOnlyKeys: Set<String> = ["Activity statistics"]

    private func intentLabels() throws -> [LocalizedStringResource] {
        let intent = SelectActivityPointIntent()
        return [
            ActivityPeriod.typeDisplayRepresentation.name,
            try XCTUnwrap(ActivityPeriod.caseDisplayRepresentations[.day]).title,
            try XCTUnwrap(ActivityPeriod.caseDisplayRepresentations[.week]).title,
            try XCTUnwrap(ActivityPeriod.caseDisplayRepresentations[.month]).title,
            ActivitySource.typeDisplayRepresentation.name,
            SelectActivityPointIntent.title,
            intent.$date.title, intent.$period.title, intent.$source.title, intent.$kind.title
        ]
    }

    private func assertMetadataResolves(in bundle: Bundle, file: StaticString = #filePath, line: UInt = #line) throws {
        let metadata = try intentLabels()
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
