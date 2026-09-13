import XCTest
@testable import WeekleftCore

final class LocalizationTests: XCTestCase {
    func testCatalogHasEveryLanguageAndPreservesAllPlaceholders() {
        XCTAssertGreaterThan(L10n.translations.count, 150)
        let languages: Set<String> = ["en", "de", "es", "fr", "zh-Hans"]
        let regex = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
        func placeholders(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (key, values) in L10n.translations {
            XCTAssertEqual(Set(values.keys), languages, key)
            for (language, text) in values {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key):\(language)")
                XCTAssertEqual(placeholders(text), placeholders(key), "\(key):\(language)")
                XCTAssertNil(text.range(of: "[А-Яа-яЁё]", options: .regularExpression), "Russian leak in \(key):\(language)")
            }
        }
    }
    func testLanguageResolutionAndLiteralArguments() {
        XCTAssertEqual(AppLanguage.resolve("system", preferred: ["fr-CA", "en"]), "fr")
        XCTAssertEqual(AppLanguage.resolve("system", preferred: ["zh_CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve("system", preferred: ["it"]), "en")
        XCTAssertEqual(AppLanguage.resolve("de", preferred: ["ru"]), "de")
        XCTAssertEqual(L10n.text("Выполняет {0}", language: "fr", arguments: ["test {1}"]), "Exécution de test {1}")
        XCTAssertEqual(L10n.text("Проверено {0}", language: "zh-Hans", arguments: ["12:30"]), "检查于 12:30")
    }
    func testLocalizedCountdownKeepsQuotaSemantics() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let quota = try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: now.addingTimeInterval(3660))
        XCTAssertEqual(quota.countdown(now: now, language: "fr"), "1 h 1 min")
        XCTAssertEqual(quota.countdown(now: now, language: "zh-Hans"), "1小时 1分钟")
        XCTAssertEqual(quota.remaining, 0)
        XCTAssertEqual(quota.countdown(now: now.addingTimeInterval(4000), language: "en"), "refreshing")
        XCTAssertEqual(try QuotaWindow(usedPercent: 5, durationMinutes: 300, resetsAt: nil).countdown(language: "de"), "—")
    }
    func testDurationFormattingUsesConsistentUnitsAndOmitsZeroLowerComponent() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let day = try QuotaWindow(usedPercent: 20, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(day.countdown(now: now, language: "ru"), "3 д")
        XCTAssertEqual(DurationText.activity(8 * 3600, language: "ru"), "8 ч")
        XCTAssertEqual(DurationText.activity(54 * 60, language: "ru"), "54 мин")
        XCTAssertEqual(DurationText.activity(2 * 3600 + 11 * 60, language: "de"), "2 Std. 11 Min.")
        XCTAssertEqual(DurationText.activity(54 * 60, language: "de"), "54 Min.")
        XCTAssertEqual(DurationText.activity(59, language: "en"), "< 1 min")
        XCTAssertEqual(DurationText.activity(0, language: "en"), "0 min")
        XCTAssertEqual(DurationText.activity(.infinity), "—")
        for language in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            let hour = try QuotaWindow(usedPercent: 20, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))
            XCTAssertEqual(hour.countdown(now: now, language: language), DurationText.activity(3600, language: language))
        }
    }

    /// Direct literal calls are exhaustive here. Dynamic L(variable) and
    /// persisted error keys are intentionally retained, never inferred dead.
    func testDirectSourceLookupKeysExistInCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = #"\bL\(\s*"((?:\\.|[^"\\])*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var checked = Set<String>()
        for folder in ["Sources", "Widget"] {
            let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in iterator where file.pathExtension == "swift" {
                let source = try String(contentsOf: file)
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let encoded = String(source[Range(match.range(at: 1), in: source)!])
                    // Swift interpolation isn't a static lookup key.
                    guard !encoded.contains(#"\("#), encoded.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil else { continue }
                    let key = try JSONDecoder().decode(String.self, from: Data(("\"" + encoded + "\"").utf8))
                    XCTAssertNotNil(L10n.translations[key], "Missing translation: \(key) in \(file.lastPathComponent)")
                    checked.insert(key)
                }
            }
        }
        XCTAssertGreaterThan(checked.count, 250, "The scanner must inspect the production source, not an empty directory")
    }

    func testDisabledCodexHooksAreNotReportedAsConfigured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hooks.json")
        try SessionHooks.install(provider: .codex, executable: Bundle.main.executablePath!, configURL: url, backupDirectory: directory.appendingPathComponent("backups"))
        XCTAssertTrue(SessionHooks.installed(.codex, configURL: url))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertFalse(SessionHooks.installed(.codex, configURL: url))
    }
    func testSetupDetectionDoesNotClaimDisabledBridgeIsConnected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let setup = ClientConnection.LocalSetup(provider: .claude, executable: Bundle.main.executablePath!,
            configURL: url, bridgeDirectory: directory.appendingPathComponent("bridge"),
            backupDirectory: directory.appendingPathComponent("backups"))
        try Data(#"{"theme":"dark","statusLine":{"type":"command","command":"echo personal-status"}}"#.utf8).write(to: url)
        XCTAssertTrue(try setup.apply(.connect).connected)
        let before = try Data(contentsOf: url)
        // Exercise the same operation as the Connect button a second time.
        XCTAssertTrue(try setup.apply(.connect).connected)
        XCTAssertEqual(try Data(contentsOf: url), before)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        root["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertFalse(ClaudeProvider.statusLineInstalled(settingsURL: url))
    }
}
