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

private final class TraceHelperContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func failAfter(_ duration: Duration) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.resume(with: .failure(TraceHelperClientError.unavailable))
        }
        lock.lock()
        if continuation == nil {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func resume(with result: sending Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

// NSXPCConnection invokes replies on its own queues. Keeping every callback in
// this nonisolated transport prevents Objective-C callbacks from inheriting the
// UI controller's MainActor executor.
final class TraceHelperXPCTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let machServiceName: String
    private let helperCodeSigningRequirement: String

    init(
        machServiceName: String = TraceHelperProtocolConfiguration.machServiceName,
        helperCodeSigningRequirement: String = TraceHelperProtocolConfiguration
            .helperCodeSigningRequirement
    ) {
        self.machServiceName = machServiceName
        self.helperCodeSigningRequirement = helperCodeSigningRequirement
    }

    func ping(
        clientProtocolVersion: Int,
        timeout: Duration = .seconds(5)
    ) async throws -> (Int, String) {
        try await withCheckedThrowingContinuation { continuation in
            let relay = TraceHelperContinuation(continuation)
            relay.failAfter(timeout)
            do {
                let helper = try remoteProxy(relay: relay)
                helper.ping(clientProtocolVersion: NSNumber(value: clientProtocolVersion)) {
                    version, status in
                    relay.resume(with: .success((version.intValue, status as String)))
                }
            } catch {
                relay.resume(with: .failure(error))
            }
        }
    }

    func startTrace(
        maximumDurationSeconds: Int,
        processIdentifiers: [Int32]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let relay = TraceHelperContinuation(continuation)
            relay.failAfter(.seconds(5))
            do {
                let helper = try remoteProxy(relay: relay)
                helper.startTrace(
                    maximumDurationSeconds: NSNumber(value: maximumDurationSeconds),
                    processIdentifiers: processIdentifiers.map(NSNumber.init(value:)) as NSArray
                ) { sessionID, status in
                    let status = status as String
                    guard status == "started" else {
                        relay.resume(with: .failure(TraceHelperClientError.rejected(status)))
                        return
                    }
                    relay.resume(with: .success(sessionID as String))
                }
            } catch {
                relay.resume(with: .failure(error))
            }
        }
    }

    func drainTrace(
        sessionID: String,
        maximumRecordCount: Int
    ) async throws -> TraceHelperDrainPayload {
        try await withCheckedThrowingContinuation { continuation in
            let relay = TraceHelperContinuation(continuation)
            relay.failAfter(.seconds(5))
            do {
                let helper = try remoteProxy(relay: relay)
                helper.drainTrace(
                    sessionID: sessionID as NSString,
                    maximumRecordCount: NSNumber(value: maximumRecordCount)
                ) { data, status in
                    guard status as String == "ready" else {
                        relay.resume(with: .failure(
                            TraceHelperClientError.rejected(status as String)
                        ))
                        return
                    }
                    do {
                        relay.resume(with: .success(
                            try JSONDecoder().decode(
                                TraceHelperDrainPayload.self,
                                from: data as Data
                            )
                        ))
                    } catch {
                        relay.resume(with: .failure(TraceHelperClientError.invalidPayload))
                    }
                }
            } catch {
                relay.resume(with: .failure(error))
            }
        }
    }

    func stopTrace(sessionID: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let relay = TraceHelperContinuation(continuation)
            relay.failAfter(.seconds(3))
            do {
                let helper = try remoteProxy(relay: relay)
                helper.stopTrace(sessionID: sessionID as NSString) { status in
                    guard status as String == "stopped" else {
                        relay.resume(with: .failure(
                            TraceHelperClientError.rejected(status as String)
                        ))
                        return
                    }
                    relay.resume(with: .success(()))
                }
            } catch {
                relay.resume(with: .failure(error))
            }
        }
    }

    func invalidate() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        lock.unlock()
        connection?.invalidate()
    }

    private func remoteProxy<Value: Sendable>(
        relay: TraceHelperContinuation<Value>
    ) throws -> TraceHelperXPCProtocol {
        let connection = activeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            self?.discard(connection)
            relay.resume(with: .failure(TraceHelperClientError.unavailable))
        }
        guard let helper = proxy as? TraceHelperXPCProtocol else {
            discard(connection)
            throw TraceHelperClientError.unavailable
        }
        return helper
    }

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            return connection
        }
        let created = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        created.remoteObjectInterface = NSXPCInterface(with: TraceHelperXPCProtocol.self)
        created.setCodeSigningRequirement(
            helperCodeSigningRequirement
        )
        created.invalidationHandler = { [weak self, weak created] in
            self?.discard(created)
        }
        created.interruptionHandler = { [weak self, weak created] in
            self?.discard(created)
        }
        connection = created
        created.activate()
        return created
    }

    private func discard(_ candidate: NSXPCConnection?) {
        guard let candidate else { return }
        lock.lock()
        if connection === candidate {
            connection = nil
        }
        lock.unlock()
    }
}

@MainActor
@Observable
final class TraceHelperController {
    private(set) var state: TraceHelperServiceState = .notRegistered
    @ObservationIgnored private let transport = TraceHelperXPCTransport()

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

    func repairService() async throws {
        try await replaceOutdatedService()
    }

    func waitUntilAuthorizedAndReady(maximumWait: Duration = .seconds(180)) async throws {
        let deadline = ContinuousClock.now.advanced(by: maximumWait)
        while ContinuousClock.now < deadline {
            refreshStatus()
            switch state {
            case .enabled, .ready, .connecting:
                do {
                    try await ping(timeout: .seconds(1))
                    return
                } catch TraceHelperClientError.protocolMismatch {
                    throw TraceHelperClientError.protocolMismatch
                } catch {
                    invalidateConnection()
                    try await Task.sleep(for: .milliseconds(250))
                }
            case .requiresApproval:
                try await Task.sleep(for: .milliseconds(500))
            case .notRegistered, .notFound, .protocolMismatch,
                    .connectionUnavailable, .operationFailed:
                throw TraceHelperClientError.unavailable
            }
        }
        throw TraceHelperClientError.unavailable
    }

    func ping() async throws {
        try await ping(timeout: .seconds(3))
    }

    private func ping(timeout: Duration) async throws {
        state = .connecting
        let result: (Int, String)
        do {
            result = try await transport.ping(
                clientProtocolVersion: TraceHelperProtocolConfiguration.version,
                timeout: timeout
            )
        } catch {
            state = .connectionUnavailable
            throw error
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
            try await ping(timeout: .seconds(2))
        } catch {
            refreshStatus()
            if service.status == .requiresApproval {
                throw TraceHelperClientError.approvalRequired
            }
            throw error
        }
        return try await transport.startTrace(
            maximumDurationSeconds: maximumDurationSeconds,
            processIdentifiers: processIdentifiers
        )
    }

    private func replaceOutdatedService() async throws {
        invalidateConnection()
        do {
            if service.status != .notRegistered && service.status != .notFound {
                try await service.unregister()
            }
            try service.register()
            refreshStatus()
        } catch {
            refreshStatus()
            if service.status == .requiresApproval {
                state = .requiresApproval
                return
            }
            throw error
        }
        if service.status == .requiresApproval {
            state = .requiresApproval
            return
        }
        guard service.status == .enabled else {
            throw TraceHelperClientError.unavailable
        }
    }

    func drainTrace(
        sessionID: String,
        maximumRecordCount: Int = 1_024
    ) async throws -> TraceHelperDrainPayload {
        try await transport.drainTrace(
            sessionID: sessionID,
            maximumRecordCount: maximumRecordCount
        )
    }

    func stopTrace(sessionID: String) async throws {
        try await transport.stopTrace(sessionID: sessionID)
    }

    private func invalidateConnection() {
        transport.invalidate()
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
