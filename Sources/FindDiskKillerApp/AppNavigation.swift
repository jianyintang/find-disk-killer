import Foundation
import Observation

enum SettingsPane: String, CaseIterable, Hashable, Identifiable, Sendable {
    case general
    case dataAndPrivacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("通用")
        case .dataAndPrivacy: L10n.text("数据与隐私")
        }
    }
}

enum SidebarDestination: Hashable, Identifiable, Sendable {
    case monitoring(AppSection)
    case settings
    case about

    var id: String {
        switch self {
        case .monitoring(let section): "monitoring.\(section.id)"
        case .settings: "settings"
        case .about: "about"
        }
    }
}

@MainActor
@Observable
final class AppNavigationCoordinator {
    private(set) var destination: SidebarDestination = .monitoring(.overview)
    private(set) var lastMonitoringDestination: AppSection = .overview
    var settingsPane: SettingsPane = .general

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FIND_DISK_KILLER_INITIAL_SECTION"] == "storage-map" {
            destination = .monitoring(.agentStorage)
            lastMonitoringDestination = .agentStorage
        }
        #endif
    }

    func select(_ destination: SidebarDestination) {
        self.destination = destination
        if case .monitoring(let section) = destination {
            lastMonitoringDestination = section
        }
    }

    func showSettings(_ pane: SettingsPane? = nil, preserveCurrentPane: Bool = false) {
        if let pane {
            settingsPane = pane
        } else if !preserveCurrentPane || destination != .settings {
            settingsPane = .general
        }
        destination = .settings
    }

    func showAbout() {
        destination = .about
    }
}
