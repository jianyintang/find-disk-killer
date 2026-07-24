import Foundation
import FindDiskKillerTraceProtocol
import Observation
import ServiceManagement

enum TraceHelperServiceState: Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case connecting
    case ready
    case protocolMismatch
    case connectionUnavailable
    case operationFailed(String)
}

@MainActor
@Observable
final class TraceHelperController {
    private(set) var state: TraceHelperServiceState = .notRegistered
    private var connection: NSXPCConnection?

    private let service = SMAppService.daemon(
        plistName: TraceHelperProtocolConfiguration.launchDaemonPlistName
    )

    func refreshStatus() {
        state = switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    // Call only from an explicit user action in the future tracing workspace.
    func requestRegistration() {
        do {
            try service.register()
            refreshStatus()
        } catch {
            state = .operationFailed(error.localizedDescription)
        }
    }

    func unregister() {
        invalidateConnection()
        do {
            try service.unregister()
            refreshStatus()
        } catch {
            state = .operationFailed(error.localizedDescription)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func ping() {
        invalidateConnection()
        state = .connecting

        let connection = NSXPCConnection(
            machServiceName: TraceHelperProtocolConfiguration.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: TraceHelperXPCProtocol.self)
        connection.setCodeSigningRequirement(
            TraceHelperProtocolConfiguration.helperCodeSigningRequirement
        )
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.connection = nil
                if self.state == .connecting {
                    self.state = .connectionUnavailable
                }
            }
        }
        self.connection = connection
        connection.activate()

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.state = .connectionUnavailable
                self.invalidateConnection()
            }
        }

        guard let helper = proxy as? TraceHelperXPCProtocol else {
            state = .connectionUnavailable
            invalidateConnection()
            return
        }

        helper.ping(
            clientProtocolVersion: NSNumber(value: TraceHelperProtocolConfiguration.version)
        ) { [weak self] helperVersion, status in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.state = helperVersion.intValue == TraceHelperProtocolConfiguration.version
                    && status == "ready"
                    ? .ready
                    : .protocolMismatch
                self.invalidateConnection()
            }
        }
    }

    private func invalidateConnection() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }
}
