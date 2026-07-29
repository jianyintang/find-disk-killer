import Foundation
import FindDiskKillerCore

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

    static func agentStorageCompatibilityIssueURL(
        provider: AgentStorageProvider,
        component: String
    ) -> URL {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let allowedComponents: Set<String> = [
            "logs",
            "logs.estimated_bytes",
            "threads",
            "thread_spawn_edges",
            "attribution arithmetic",
            "conversation database",
            "conversation index"
        ]
        let safeComponent = allowedComponents.contains(component)
            ? component : "unknown component"
        var components = URLComponents(
            url: URL(string: "https://github.com/jianyintang/find-disk-killer/issues/new")!,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "title",
                value: "[Agent Storage Compatibility] \(provider.rawValue) \(safeComponent)"
            ),
            URLQueryItem(
                name: "body",
                value: """
                The AI storage analyzer found a data format it cannot safely parse.

                - Provider: \(provider.rawValue)
                - Component: \(safeComponent)
                - App version: \(appVersion)
                - macOS: \(osVersion)

                No local paths, task IDs, titles, prompts, or message contents are included.
                """
            )
        ]
        return components.url!
    }
}
