import Foundation

struct BrandLinks: Equatable, Sendable {
    let website: URL
    let github: URL
    let privacyPolicy: URL
    let support: URL

    static func current(language: AppLanguage = L10n.effectiveLanguage) -> Self {
        let locale = switch language {
        case .simplifiedChinese: "zh-cn"
        case .traditionalChinese: "zh-tw"
        case .brazilianPortuguese: "pt-br"
        case .english: "en"
        case .japanese: "ja"
        case .korean: "ko"
        case .german: "de"
        case .french: "fr"
        case .spanish: "es"
        case .russian: "ru"
        case .system: "en"
        }
        return Self(
            website: URL(string: "https://finddiskkiller.com/\(locale)/")!,
            github: URL(string: "https://github.com/jianyintang/find-disk-killer")!,
            privacyPolicy: URL(
                string: "https://github.com/jianyintang/find-disk-killer/blob/main/PRIVACY.md"
            )!,
            support: URL(
                string: "https://github.com/jianyintang/find-disk-killer/issues"
            )!
        )
    }
}
