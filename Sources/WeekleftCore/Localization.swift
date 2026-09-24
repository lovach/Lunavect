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
    // Foundation guarantees concurrent access to the same UserDefaults object:
    // https://developer.apple.com/documentation/foundation/userdefaults
    // This immutable reference is created once, never subclassed or replaced.
    // The SDK lacks Sendable here; this exemption covers only that reference.
    // Core callers read a String value; UI preference writes remain MainActor.
    nonisolated(unsafe) public static let defaults: UserDefaults = {
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
    public static var locale: Locale { locale(language: AppLanguage.resolve(selection)) }
    /// The interface language with the user's region, clock and calendar settings,
    /// so times and weeks match the Mac even when the language differs.
    public static func locale(language: String, base: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(locale: base)
        components.languageComponents = Locale.Language.Components(identifier: language)
        components.region = base.region
        return Locale(components: components)
    }
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

/// Whole percentages in the interface language: "72%" or "72 %", as the
/// translations of "{0}%" define. VoiceOver reads the same text and applies
/// its own plural forms, so it is also the accessibility value.
public enum PercentText {
    public static func format(_ value: Int, language: String = L10n.selection) -> String {
        L10n.text("{0}%", language: language, arguments: [String(value)])
    }
    /// The sign with its language-specific spacing, for layouts that set the number apart.
    public static func sign(language: String = L10n.selection) -> String {
        L10n.text("{0}%", language: language, arguments: [""])
    }
}

/// Shared abbreviated units for quotas, activity totals and chart readouts.
/// Quotas round up before calling this; measured activity rounds down.
public enum DurationText {
    public static func minutes(_ minutes: Int, includesDays: Bool = false, language: String = L10n.selection) -> String {
        func text(_ key: String, _ value: Int) -> String { L10n.text(key, language: language, arguments: [String(value)]) }
        let minutes = max(0, minutes)
        if includesDays && minutes >= 1440 {
            let days = text("{0} д", minutes / 1440), hours = minutes % 1440 / 60
            return hours == 0 ? days : days + " " + text("{0} ч", hours)
        }
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return text("{0} мин", remainder) }
        return text("{0} ч", hours) + (remainder == 0 ? "" : " " + text("{0} мин", remainder))
    }
    public static func activity(_ seconds: TimeInterval, language: String = L10n.selection) -> String {
        guard seconds.isFinite, seconds >= 0, seconds / 60 < Double(Int.max) else { return "—" }
        if seconds > 0 && seconds < 60 { return L10n.text("< 1 мин", language: language) }
        return minutes(Int(seconds / 60), language: language)
    }
}
