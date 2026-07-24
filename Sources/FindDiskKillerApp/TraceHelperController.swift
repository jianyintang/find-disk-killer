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

enum TraceHelperClientError: Error, Equatable {
    case unavailable
    case protocolMismatch
    case approvalRequired
    case rejected(String)
    case invalidPayload
}

@MainActor
@Observable
final class TraceHelperController {
    private(set) var state: TraceHelperServiceState = .notRegistered
    @ObservationIgnored private var connection: NSXPCConnection?

    private let service = SMAppService.daemon(
        plistName: TraceHelperProtocolConfiguration.launchDaemonPlistName
    )

    func refreshStatus() {
        state = switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // An unregistered embedded daemon can be reported as notFound. Verify the
        // signed bundle payload before deciding that this build is incomplete.
        case .notFound: packagedServiceIsPresent ? .notRegistered : .notFound
        @unknown default: .notFound
        }
    }

    // Registration is only called from the tracing workspace's explicit action.
    func requestRegistration() {
        guard packagedServiceIsPresent else {
            state = .notFound
            return
        }
        do {
            try service.register()
            refreshStatus()
        } catch {
            // register() can race with approval or an earlier registration. The
            // framework status is authoritative when it has already advanced.
            switch service.status {
            case .enabled, .requiresApproval:
                refreshStatus()
            default:
                state = .operationFailed(error.localizedDescription)
            }
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

    func ping() async throws {
        let result: (Int, String) = try await withCheckedThrowingContinuation { continuation in
            do {
                let helper = try remoteProxy { _ in
                    continuation.resume(throwing: TraceHelperClientError.unavailable)
                }
                helper.ping(
                    clientProtocolVersion: NSNumber(value: TraceHelperProtocolConfiguration.version)
                ) { version, status in
                    continuation.resume(returning: (version.intValue, status as String))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard result.0 == TraceHelperProtocolConfiguration.version,
              result.1 == "ready"
        else {
            state = .protocolMismatch
            throw TraceHelperClientError.protocolMismatch
        }
        state = .ready
    }

    func startTrace(
        maximumDurationSeconds: Int,
        processIdentifiers: [Int32]
    ) async throws -> String {
        do {
            try await ping()
        } catch TraceHelperClientError.protocolMismatch {
            try replaceOutdatedService()
            try await ping()
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let helper = try remoteProxy { _ in
                    continuation.resume(throwing: TraceHelperClientError.unavailable)
                }
                helper.startTrace(
                    maximumDurationSeconds: NSNumber(value: maximumDurationSeconds),
                    processIdentifiers: processIdentifiers.map(NSNumber.init(value:)) as NSArray
                ) { sessionID, status in
                    let status = status as String
                    guard status == "started" else {
                        continuation.resume(throwing: TraceHelperClientError.rejected(status))
                        return
                    }
                    continuation.resume(returning: sessionID as String)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func replaceOutdatedService() throws {
        invalidateConnection()
        do {
            try service.unregister()
            try service.register()
            refreshStatus()
        } catch {
            refreshStatus()
            if service.status == .requiresApproval {
                throw TraceHelperClientError.approvalRequired
            }
            throw error
        }
        if service.status == .requiresApproval {
            throw TraceHelperClientError.approvalRequired
        }
        guard service.status == .enabled else {
            throw TraceHelperClientError.unavailable
        }
    }

    func drainTrace(
        sessionID: String,
        maximumRecordCount: Int = 1_024
    ) async throws -> TraceHelperDrainPayload {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let helper = try remoteProxy { _ in
                    continuation.resume(throwing: TraceHelperClientError.unavailable)
                }
                helper.drainTrace(
                    sessionID: sessionID as NSString,
                    maximumRecordCount: NSNumber(value: maximumRecordCount)
                ) { data, status in
                    guard status == "ready" else {
                        continuation.resume(
                            throwing: TraceHelperClientError.rejected(status as String)
                        )
                        return
                    }
                    do {
                        continuation.resume(
                            returning: try JSONDecoder().decode(
                                TraceHelperDrainPayload.self,
                                from: data as Data
                            )
                        )
                    } catch {
                        continuation.resume(throwing: TraceHelperClientError.invalidPayload)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func stopTrace(sessionID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let helper = try remoteProxy { _ in
                    continuation.resume(throwing: TraceHelperClientError.unavailable)
                }
                helper.stopTrace(sessionID: sessionID as NSString) { status in
                    guard status == "stopped" else {
                        continuation.resume(
                            throwing: TraceHelperClientError.rejected(status as String)
                        )
                        return
                    }
                    continuation.resume(returning: ())
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> TraceHelperXPCProtocol {
        let connection: NSXPCConnection
        if let existing = self.connection {
            connection = existing
        } else {
            state = .connecting
            let created = NSXPCConnection(
                machServiceName: TraceHelperProtocolConfiguration.machServiceName,
                options: .privileged
            )
            created.remoteObjectInterface = NSXPCInterface(with: TraceHelperXPCProtocol.self)
            created.setCodeSigningRequirement(
                TraceHelperProtocolConfiguration.helperCodeSigningRequirement
            )
            created.invalidationHandler = { [weak self, weak created] in
                Task { @MainActor in
                    guard let self, let created, self.connection === created else { return }
                    self.connection = nil
                    if self.state == .connecting {
                        self.state = .connectionUnavailable
                    }
                }
            }
            created.interruptionHandler = { [weak self] in
                Task { @MainActor in
                    self?.state = .connectionUnavailable
                }
            }
            self.connection = created
            created.activate()
            connection = created
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.state = .connectionUnavailable
                self?.invalidateConnection()
            }
            errorHandler(error)
        }
        guard let helper = proxy as? TraceHelperXPCProtocol else {
            state = .connectionUnavailable
            invalidateConnection()
            throw TraceHelperClientError.unavailable
        }
        return helper
    }

    private func invalidateConnection() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    private var packagedServiceIsPresent: Bool {
        let directory = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchDaemons", directoryHint: .isDirectory)
        let plist = directory.appending(
            path: TraceHelperProtocolConfiguration.launchDaemonPlistName,
            directoryHint: .notDirectory
        )
        let executable = directory.appending(
            path: TraceHelperProtocolConfiguration.machServiceName,
            directoryHint: .notDirectory
        )
        return FileManager.default.fileExists(atPath: plist.path)
            && FileManager.default.isExecutableFile(atPath: executable.path)
    }
}
