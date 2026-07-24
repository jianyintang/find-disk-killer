import Foundation
import FindDiskKillerCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case russian = "ru"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .system: L10n.preferredLanguage.localeIdentifier
        default: rawValue
        }
    }

    var localizedName: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .russian: "Русский"
        }
    }
}

extension SampleRange {
    var localizedTitle: String { L10n.text(rawValue) }
}

extension ProcessActivity {
    var localizedDisplayName: String {
        let marker = "（可能关联）"
        guard name.hasSuffix(marker) else { return name }
        return String(name.dropLast(marker.count)) + L10n.text(marker)
    }
}

enum L10n {
    static var selectedLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static var preferredLanguage: AppLanguage {
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if identifier.hasPrefix("zh-hant") || identifier.hasPrefix("zh-tw")
            || identifier.hasPrefix("zh-hk") { return .traditionalChinese }
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("pt") { return .brazilianPortuguese }
        if identifier.hasPrefix("ru") { return .russian }
        return .english
    }

    static var effectiveLanguage: AppLanguage {
        selectedLanguage == .system ? preferredLanguage : selectedLanguage
    }

    static func text(_ key: String) -> String {
        languageBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(key),
            locale: Locale(identifier: effectiveLanguage.localeIdentifier),
            arguments: arguments
        )
    }

    private static var languageBundle: Bundle {
        languageBundles[effectiveLanguage.rawValue.lowercased()] ?? AppResourceBundle.value
    }

    private static let languageBundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
            guard language != .system else { return nil }
            let resourceName = language.rawValue.lowercased()
            guard let path = AppResourceBundle.value.path(forResource: resourceName, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return nil
            }
            return (resourceName, bundle)
        })
    }()
}

enum AppResourceBundle {
    static var value: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
}
