import Observation
import ServiceManagement

enum LoginItemEffectiveStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case failed(String)
}

@MainActor
protocol LoginItemServicing {
    var status: LoginItemEffectiveStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct NativeLoginItemService: LoginItemServicing {
    var status: LoginItemEffectiveStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
@Observable
final class LoginItemSettingsModel {
    private(set) var desiredEnabled = false
    private(set) var effectiveStatus: LoginItemEffectiveStatus = .disabled
    private(set) var isTransitioning = false
    private let service: any LoginItemServicing

    init(service: any LoginItemServicing = NativeLoginItemService()) {
        self.service = service
        refresh()
    }

    func setEnabled(_ value: Bool) {
        guard !isTransitioning else { return }
        desiredEnabled = value
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            if value { try service.register() } else { try service.unregister() }
            effectiveStatus = service.status
            desiredEnabled = effectiveStatus == .enabled || effectiveStatus == .requiresApproval
        } catch {
            effectiveStatus = .failed(L10n.errorDescription(error))
            desiredEnabled = !value
        }
    }

    func refresh() {
        effectiveStatus = service.status
        desiredEnabled = effectiveStatus == .enabled || effectiveStatus == .requiresApproval
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
