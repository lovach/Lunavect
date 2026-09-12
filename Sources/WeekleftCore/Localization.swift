import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, ru, en, de, es, fr, zhHans = "zh-Hans"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .ru: return "Русский"
        case .en: return "English"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .zhHans: return "简体中文"
        }
    }
    public static func resolve(_ code: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if code != "system", let language = AppLanguage(rawValue: code) { return language.rawValue }
        for value in preferred {
            let base = value.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            if base == "zh" { return "zh-Hans" }
            if ["ru", "en", "de", "es", "fr"].contains(base) { return base }
        }
        return "en"
    }
}

public enum L10n {
    public static let defaults: UserDefaults = {
        if let group = Bundle.main.object(forInfoDictionaryKey: "WeekleftAppGroup") as? String,
           let shared = UserDefaults(suiteName: group) { return shared }
        return .standard
    }()
    public static var selection: String {
        #if DEBUG
        if let preview = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] { return preview }
        #endif
        return defaults.string(forKey: "languageCode") ?? "system"
    }
    public static var locale: Locale { Locale(identifier: AppLanguage.resolve(selection)) }
    public static let translations: [String: [String: String]] = {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "Translations", withExtension: "json")
        #else
        let url = Bundle.main.url(forResource: "Translations", withExtension: "json")
        #endif
        guard let url, let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return result
    }()
    public static func text(_ key: String, language: String, arguments: [String] = []) -> String {
        let code = AppLanguage.resolve(language)
        var value = code == "ru" ? key : translations[key]?[code] ?? translations[key]?["en"] ?? key
        // A single pass prevents an argument containing another placeholder
        // from being treated as part of the translation template.
        let parts = value.components(separatedBy: "{")
        value = parts[0] + parts.dropFirst().map { part in
            guard let end = part.firstIndex(of: "}"), let index = Int(part[..<end]), arguments.indices.contains(index) else { return "{" + part }
            return arguments[index] + part[part.index(after: end)...]
        }.joined()
        return value
    }
}
public func L(_ key: String, _ arguments: String...) -> String {
    L10n.text(key, language: L10n.selection, arguments: arguments)
}
