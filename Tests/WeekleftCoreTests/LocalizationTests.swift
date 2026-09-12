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
        XCTAssertFalse(ClaudeProvider.statusLineInstalled(settingsURL: url))
        try ClaudeProvider.installStatusLine(executable: Bundle.main.executablePath!, settingsURL: url, bridgeDirectory: directory.appendingPathComponent("bridge"))
        XCTAssertTrue(ClaudeProvider.statusLineInstalled(settingsURL: url))
        let before = try Data(contentsOf: url)
        // The simple Connect flow must not rewrite an already installed command.
        if !ClaudeProvider.statusLineInstalled(settingsURL: url) { XCTFail("Would rewrite an existing bridge") }
        XCTAssertEqual(try Data(contentsOf: url), before)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        root["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertFalse(ClaudeProvider.statusLineInstalled(settingsURL: url))
    }
}
