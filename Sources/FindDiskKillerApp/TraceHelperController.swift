import AppKit
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
    case repairing
    case repairAvailable
    case installationRequired(isDiskImage: Bool)
    case operationFailed(String)
}

enum TraceHelperClientError: Error, Equatable {
    case unavailable
    case busy
    case protocolMismatch
    case approvalRequired
    case installationRequired(isDiskImage: Bool)
    case repairRequired
    case rejected(String)
    case invalidPayload
}

enum TraceHelperActivityStatus: Equatable, Sendable {
    case ready
    case busy
}

enum TraceHelperRecoveryMode: Equatable {
    case automatic
    case userInitiated
}

enum TraceHelperPreparationPhase: Equatable {
    case checking
    case repairing
}

enum TraceHelperRegistrationStatus: Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

@MainActor
protocol TraceHelperServiceManaging: AnyObject {
    var status: TraceHelperRegistrationStatus { get }
    func cleanupLegacyServices() async throws
    func register() throws
    func unregister() throws
    func unregisterAndWait() async throws
    func openSystemSettings()
}

protocol TraceHelperTransporting: AnyObject, Sendable {
    func ping(clientProtocolVersion: Int, timeout: Duration) async throws -> (Int, String)
    func startTrace(
        maximumDurationSeconds: Int,
        processIdentifiers: [Int32]
    ) async throws -> String
    func startSystemTrace(maximumDurationSeconds: Int) async throws -> String
    func drainTrace(
        sessionID: String,
        maximumRecordCount: Int
    ) async throws -> TraceHelperDrainPayload
    func stopTrace(sessionID: String) async throws
    func invalidate()
}

@MainActor
protocol TraceHelperRegistrationPersisting: AnyObject {
    var lastHealthyFingerprint: String? { get set }
    var autoRepairAttemptedFingerprint: String? { get set }
}

private final class TraceHelperServiceManager: TraceHelperServiceManaging {
    private let service = SMAppService.daemon(
        plistName: TraceHelperProtocolConfiguration.launchDaemonPlistName
    )
    private let legacyService = SMAppService.daemon(
        plistName: TraceHelperProtocolConfiguration.legacyLaunchDaemonPlistName
    )

    var status: TraceHelperRegistrationStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func cleanupLegacyServices() async throws {
        switch legacyService.status {
        case .enabled, .requiresApproval:
            try await unregisterAndWait(legacyService)
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
    }

    func unregister() throws {
        try service.unregister()
    }

    func unregisterAndWait() async throws {
        try await unregisterAndWait(service)
    }

    private func unregisterAndWait(_ service: SMAppService) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private final class TraceHelperRegistrationStore: TraceHelperRegistrationPersisting {
    private enum Key {
        static let lastHealthy = "traceHelper.lastHealthyFingerprint"
        static let autoRepairAttempted = "traceHelper.autoRepairAttemptedFingerprint"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastHealthyFingerprint: String? {
        get { defaults.string(forKey: Key.lastHealthy) }
        set { defaults.set(newValue, forKey: Key.lastHealthy) }
    }

    var autoRepairAttemptedFingerprint: String? {
        get { defaults.string(forKey: Key.autoRepairAttempted) }
        set { defaults.set(newValue, forKey: Key.autoRepairAttempted) }
    }
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
final class TraceHelperXPCTransport: TraceHelperTransporting, @unchecked Sendable {
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

    func startSystemTrace(maximumDurationSeconds: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let relay = TraceHelperContinuation(continuation)
            relay.failAfter(.seconds(5))
            do {
                let helper = try remoteProxy(relay: relay)
                helper.startSystemTrace(
                    maximumDurationSeconds: NSNumber(value: maximumDurationSeconds)
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
    @ObservationIgnored private let transport: any TraceHelperTransporting
    @ObservationIgnored private let service: any TraceHelperServiceManaging
    @ObservationIgnored private let registrationStore: any TraceHelperRegistrationPersisting
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let fingerprint: String
    @ObservationIgnored private let registrationSettleTimeout: Duration
    @ObservationIgnored private let readinessTimeout: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let packagedServicePresenceOverride: Bool?

    init(
        service: any TraceHelperServiceManaging = TraceHelperServiceManager(),
        transport: any TraceHelperTransporting = TraceHelperXPCTransport(),
        registrationStore: any TraceHelperRegistrationPersisting = TraceHelperRegistrationStore(),
        bundleURL: URL = Bundle.main.bundleURL,
        appBundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.jianyintang.FindDiskKiller",
        appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "unknown",
        registrationSettleTimeout: Duration = .seconds(2),
        readinessTimeout: Duration = .seconds(5),
        retryDelay: Duration = .milliseconds(250),
        packagedServicePresenceOverride: Bool? = nil
    ) {
        self.service = service
        self.transport = transport
        self.registrationStore = registrationStore
        self.bundleURL = bundleURL.standardizedFileURL
        fingerprint = [
            appBundleIdentifier,
            appBuild,
            TraceHelperProtocolConfiguration.machServiceName,
            String(TraceHelperProtocolConfiguration.version)
        ].joined(separator: "|")
        self.registrationSettleTimeout = registrationSettleTimeout
        self.readinessTimeout = readinessTimeout
        self.retryDelay = retryDelay
        self.packagedServicePresenceOverride = packagedServicePresenceOverride
    }

    func refreshStatus() {
        guard isInstalledInApplications else {
            state = .installationRequired(isDiskImage: isRunningFromDiskImage)
            return
        }
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
        guard isInstalledInApplications else {
            state = .installationRequired(isDiskImage: isRunningFromDiskImage)
            return
        }
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
            case .notRegistered, .notFound:
                state = registrationNeedsApproval(after: error)
                    ? .requiresApproval
                    : .operationFailed(L10n.errorDescription(error))
            }
        }
    }

    @discardableResult
    func unregister() -> Bool {
        invalidateConnection()
        do {
            try service.unregister()
            refreshStatus()
            return true
        } catch {
            state = .operationFailed(L10n.errorDescription(error))
            return false
        }
    }

    func openLoginItemsSettings() {
        service.openSystemSettings()
    }

    func repairService() async throws {
        guard isInstalledInApplications else {
            let isDiskImage = isRunningFromDiskImage
            state = .installationRequired(isDiskImage: isDiskImage)
            throw TraceHelperClientError.installationRequired(isDiskImage: isDiskImage)
        }
        try await replaceOutdatedService()
        guard service.status != .requiresApproval else {
            state = .requiresApproval
            throw TraceHelperClientError.approvalRequired
        }
        try await waitUntilReachable()
    }

    func prepareForTracing(
        recoveryMode: TraceHelperRecoveryMode,
        onPhaseChange: (TraceHelperPreparationPhase) -> Void = { _ in }
    ) async throws {
        onPhaseChange(.checking)
        guard isInstalledInApplications else {
            let isDiskImage = isRunningFromDiskImage
            state = .installationRequired(isDiskImage: isDiskImage)
            throw TraceHelperClientError.installationRequired(isDiskImage: isDiskImage)
        }
        guard packagedServiceIsPresent else {
            state = .notFound
            throw TraceHelperClientError.unavailable
        }

        refreshStatus()
        var registeredDuringPreparation = false
        switch service.status {
        case .notRegistered, .notFound:
            try await registerWithRetry()
            try await waitForRegisteredStatus()
            registeredDuringPreparation = true
        case .requiresApproval:
            // A pending service is already registered. Registering it again can
            // invalidate the approval the user is currently granting.
            state = .requiresApproval
            throw TraceHelperClientError.approvalRequired
        case .enabled:
            break
        }

        if service.status == .requiresApproval {
            state = .requiresApproval
            throw TraceHelperClientError.approvalRequired
        }
        guard service.status == .enabled else {
            refreshStatus()
            throw TraceHelperClientError.unavailable
        }

        if registeredDuringPreparation {
            state = .connecting
            do {
                try await waitUntilReachable()
                return
            } catch TraceHelperClientError.approvalRequired {
                throw TraceHelperClientError.approvalRequired
            } catch {
                state = .repairAvailable
                throw TraceHelperClientError.repairRequired
            }
        }

        do {
            try await pingAndRecordHealth(timeout: .seconds(2))
            return
        } catch TraceHelperClientError.busy {
            state = .connectionUnavailable
            throw TraceHelperClientError.busy
        } catch TraceHelperClientError.protocolMismatch {
            state = .repairing
            onPhaseChange(.repairing)
            do {
                try await replaceOutdatedService()
                guard service.status != .requiresApproval else {
                    state = .requiresApproval
                    throw TraceHelperClientError.approvalRequired
                }
                try await waitUntilReachable()
                return
            } catch TraceHelperClientError.approvalRequired {
                throw TraceHelperClientError.approvalRequired
            } catch {
                state = .repairAvailable
                throw TraceHelperClientError.repairRequired
            }
        } catch let error as TraceHelperClientError {
            guard shouldRepair(after: error, recoveryMode: recoveryMode) else {
                state = .repairAvailable
                throw TraceHelperClientError.repairRequired
            }
        } catch {
            guard shouldRepair(
                after: .unavailable,
                recoveryMode: recoveryMode
            ) else {
                state = .repairAvailable
                throw TraceHelperClientError.repairRequired
            }
        }

        registrationStore.autoRepairAttemptedFingerprint = fingerprint
        state = .repairing
        onPhaseChange(.repairing)
        do {
            try await refreshRegisteredService()
            try await waitUntilReachable()
            return
        } catch TraceHelperClientError.approvalRequired {
            throw TraceHelperClientError.approvalRequired
        } catch {}

        // An older helper can fail the current code-signing requirement before
        // it can report a protocol mismatch. In that case an in-place register
        // leaves the stale endpoint running, so complete the transactional
        // replacement on the first automatic repair attempt as well.
        do {
            try await replaceOutdatedService()
            if service.status == .requiresApproval {
                state = .requiresApproval
                throw TraceHelperClientError.approvalRequired
            }
            try await waitUntilReachable()
        } catch TraceHelperClientError.approvalRequired {
            throw TraceHelperClientError.approvalRequired
        } catch {
            state = .repairAvailable
            throw TraceHelperClientError.repairRequired
        }
    }

    private func refreshRegisteredService() async throws {
        invalidateConnection()
        try await registerWithRetry()
        try await waitForRegisteredStatus()
        refreshStatus()
        if service.status == .requiresApproval {
            state = .requiresApproval
            throw TraceHelperClientError.approvalRequired
        }
        guard service.status == .enabled else {
            throw TraceHelperClientError.unavailable
        }
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
            case .requiresApproval, .notRegistered:
                // After register() reports Operation not permitted, macOS 26 can
                // keep reporting notRegistered until the user enables the item.
                try await Task.sleep(for: .milliseconds(500))
            case .notFound, .protocolMismatch,
                    .connectionUnavailable, .repairAvailable,
                    .installationRequired, .operationFailed:
                throw TraceHelperClientError.unavailable
            case .repairing:
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw TraceHelperClientError.unavailable
    }

    func ping() async throws {
        try await ping(timeout: .seconds(3))
    }

    func activityStatus(timeout: Duration = .seconds(3)) async throws -> TraceHelperActivityStatus {
        do {
            let result = try await transport.ping(
                clientProtocolVersion: TraceHelperProtocolConfiguration.version,
                timeout: timeout
            )
            guard result.0 == TraceHelperProtocolConfiguration.version else {
                throw TraceHelperClientError.protocolMismatch
            }
            switch result.1 {
            case "ready": return .ready
            case "busy": return .busy
            default: throw TraceHelperClientError.protocolMismatch
            }
        } catch {
            invalidateConnection()
            throw error
        }
    }

    private func ping(timeout: Duration) async throws {
        state = .connecting
        do {
            try await pingAndRecordHealth(timeout: timeout)
        } catch {
            state = .connectionUnavailable
            throw error
        }
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

    func startSystemTrace(maximumDurationSeconds: Int) async throws -> String {
        do {
            try await ping(timeout: .seconds(2))
        } catch {
            refreshStatus()
            if service.status == .requiresApproval {
                throw TraceHelperClientError.approvalRequired
            }
            throw error
        }
        return try await transport.startSystemTrace(
            maximumDurationSeconds: maximumDurationSeconds
        )
    }

    private func replaceOutdatedService() async throws {
        invalidateConnection()
        if service.status != .notRegistered && service.status != .notFound {
            try await unregisterWithRetry()
            try await waitForUnregisteredStatus()
            try await waitForServiceEndpointToDisappear()
        }
        try await registerWithRetry()
        try await waitForRegisteredStatus()
        refreshStatus()
        if service.status == .requiresApproval {
            state = .requiresApproval
            return
        }
        guard service.status == .enabled else {
            throw TraceHelperClientError.unavailable
        }
    }

    private func waitForServiceEndpointToDisappear() async throws {
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        while ContinuousClock.now < deadline {
            invalidateConnection()
            do {
                _ = try await transport.ping(
                    clientProtocolVersion: TraceHelperProtocolConfiguration.version,
                    timeout: .milliseconds(250)
                )
            } catch TraceHelperClientError.unavailable {
                invalidateConnection()
                return
            } catch {
                // A protocol mismatch still proves that the old endpoint is alive.
            }
            try await Task.sleep(for: retryDelay)
        }
        throw TraceHelperClientError.unavailable
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

    func openInstallationLocation() {
        if let mountedVolumeURL {
            NSWorkspace.shared.open(mountedVolumeURL)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    private func shouldRepair(
        after error: TraceHelperClientError,
        recoveryMode: TraceHelperRecoveryMode
    ) -> Bool {
        if recoveryMode == .userInitiated {
            return true
        }
        guard error == .unavailable || error == .protocolMismatch else { return false }
        guard registrationStore.autoRepairAttemptedFingerprint != fingerprint else {
            return false
        }
        return registrationStore.lastHealthyFingerprint != fingerprint
            || error == .protocolMismatch
    }

    private func pingAndRecordHealth(timeout: Duration) async throws {
        let activity: TraceHelperActivityStatus
        do {
            activity = try await activityStatus(timeout: timeout)
        } catch TraceHelperClientError.protocolMismatch {
            state = .protocolMismatch
            throw TraceHelperClientError.protocolMismatch
        }
        guard activity == .ready else {
            state = .connectionUnavailable
            throw TraceHelperClientError.busy
        }
        registrationStore.lastHealthyFingerprint = fingerprint
        state = .ready
    }

    private func waitUntilReachable() async throws {
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        while ContinuousClock.now < deadline {
            guard service.status != .requiresApproval else {
                state = .requiresApproval
                throw TraceHelperClientError.approvalRequired
            }
            if service.status == .enabled {
                do {
                    try await pingAndRecordHealth(timeout: .seconds(1))
                    return
                } catch TraceHelperClientError.protocolMismatch {
                    throw TraceHelperClientError.protocolMismatch
                } catch {
                    invalidateConnection()
                }
            }
            try await Task.sleep(for: retryDelay)
        }
        throw TraceHelperClientError.unavailable
    }

    private func registerWithRetry() async throws {
        try await cleanupLegacyServicesWithRetry()
        var finalError: Error?
        for attempt in 0...1 {
            do {
                try service.register()
                refreshStatus()
                return
            } catch {
                finalError = error
                refreshStatus()
                if service.status == .enabled || service.status == .requiresApproval {
                    return
                }
                if registrationNeedsApproval(after: error) {
                    state = .requiresApproval
                    throw TraceHelperClientError.approvalRequired
                }
                if attempt == 0 {
                    try await Task.sleep(for: retryDelay)
                }
            }
        }
        throw finalError ?? TraceHelperClientError.unavailable
    }

    private func cleanupLegacyServicesWithRetry() async throws {
        var finalError: Error?
        for attempt in 0...1 {
            do {
                try await service.cleanupLegacyServices()
                return
            } catch {
                finalError = error
                if attempt == 0 {
                    try await Task.sleep(for: retryDelay)
                }
            }
        }
        throw finalError ?? TraceHelperClientError.unavailable
    }

    private func registrationNeedsApproval(after error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "SMAppServiceErrorDomain" && error.code == 1
    }

    private func unregisterWithRetry() async throws {
        var finalError: Error?
        for attempt in 0...1 {
            do {
                try await service.unregisterAndWait()
                return
            } catch {
                finalError = error
                if service.status == .notRegistered || service.status == .notFound {
                    return
                }
                if attempt == 0 {
                    try await Task.sleep(for: retryDelay)
                }
            }
        }
        throw finalError ?? TraceHelperClientError.unavailable
    }

    private func waitForUnregisteredStatus() async throws {
        let deadline = ContinuousClock.now.advanced(by: registrationSettleTimeout)
        while ContinuousClock.now < deadline {
            if service.status == .notRegistered || service.status == .notFound {
                return
            }
            try await Task.sleep(for: retryDelay)
        }
        throw TraceHelperClientError.unavailable
    }

    private func waitForRegisteredStatus() async throws {
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        while ContinuousClock.now < deadline {
            switch service.status {
            case .enabled, .requiresApproval:
                refreshStatus()
                return
            case .notRegistered, .notFound:
                try await Task.sleep(for: retryDelay)
            }
        }
        refreshStatus()
        throw TraceHelperClientError.unavailable
    }

    private var packagedServiceIsPresent: Bool {
        if let packagedServicePresenceOverride {
            return packagedServicePresenceOverride
        }
        let directory = bundleURL
            .appending(path: "Contents/Library/LaunchDaemons", directoryHint: .isDirectory)
        let plist = directory.appending(
            path: TraceHelperProtocolConfiguration.launchDaemonPlistName,
            directoryHint: .notDirectory
        )
        let executable = directory.appending(
            path: TraceHelperProtocolConfiguration.helperExecutableName,
            directoryHint: .notDirectory
        )
        return FileManager.default.fileExists(atPath: plist.path)
            && FileManager.default.isExecutableFile(atPath: executable.path)
    }

    private var isInstalledInApplications: Bool {
        let path = bundleURL.path
        return path == "/Applications" || path.hasPrefix("/Applications/")
    }

    private var isRunningFromDiskImage: Bool {
        mountedVolumeURL != nil
    }

    private var mountedVolumeURL: URL? {
        let components = bundleURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(components[2])", isDirectory: true)
    }
}
