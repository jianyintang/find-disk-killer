import FindDiskKillerCore
import Foundation

extension Notification.Name {
    static let agentDataLocationsDidChange = Notification.Name("AgentDataLocationsDidChange")
}

final class AgentDataLocationRepository: @unchecked Sendable {
    static let shared = AgentDataLocationRepository()

    private let defaults: UserDefaults
    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func locations() -> [AgentDataLocation] {
        AgentDataLocationDiscovery(configuration: .init(
            homeDirectory: homeDirectory,
            additionalRoots: AgentStoragePreferences.customRoots(defaults: defaults),
            includesDesktopData: true,
            environment: environment
        )).discover()
    }
}
