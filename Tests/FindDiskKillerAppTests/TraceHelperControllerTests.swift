import Foundation
import FindDiskKillerCore
import FindDiskKillerTraceProtocol
import Testing
@testable import FindDiskKillerApp

private enum FakeFailure: Error {
    case expected
}

@MainActor
private final class FakeTraceHelperService: TraceHelperServiceManaging {
    private var storedStatus: TraceHelperRegistrationStatus
    private var remainingRegistrationStatusDelayReads = 0
    var status: TraceHelperRegistrationStatus {
        get {
            if remainingRegistrationStatusDelayReads > 0 {
                remainingRegistrationStatusDelayReads -= 1
                return .notRegistered
            }
            return storedStatus
        }
        set { storedStatus = newValue }
    }
    var statusAfterRegistration: TraceHelperRegistrationStatus = .enabled
    var registrationStatusDelayReads = 0
    var registerFailures = 0
    var registerError: Error?
    var unregisterFailures = 0
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0
    var onUnregister: (() -> Void)?

    init(status: TraceHelperRegistrationStatus) {
        storedStatus = status
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        if registerFailures > 0 {
            registerFailures -= 1
            throw FakeFailure.expected
        }
        storedStatus = statusAfterRegistration
        remainingRegistrationStatusDelayReads = registrationStatusDelayReads
    }

    func unregister() throws {
        unregisterCount += 1
        if unregisterFailures > 0 {
            unregisterFailures -= 1
            throw FakeFailure.expected
        }
        storedStatus = .notRegistered
        remainingRegistrationStatusDelayReads = 0
        onUnregister?()
    }

    func unregisterAndWait() async throws {
        try unregister()
        await Task.yield()
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private final class FakeTraceHelperTransport: TraceHelperTransporting, @unchecked Sendable {
    enum PingResponse {
        case ready
        case busy
        case protocolMismatch
        case unavailable
    }

    private let lock = NSLock()
    private var responses: [PingResponse]
    private var startTraceFailures = 0
    private(set) var invalidateCount = 0

    init(_ responses: [PingResponse]) {
        self.responses = responses
    }

    func append(_ newResponses: [PingResponse]) {
        lock.withLock {
            responses.append(contentsOf: newResponses)
        }
    }

    func failNextStartTrace() {
        lock.withLock {
            startTraceFailures += 1
        }
    }

    func ping(clientProtocolVersion: Int, timeout: Duration) async throws -> (Int, String) {
        let response = lock.withLock {
            return responses.isEmpty ? .unavailable : responses.removeFirst()
        }
        switch response {
        case .ready:
            return (TraceHelperProtocolConfiguration.version, "ready")
        case .busy:
            return (TraceHelperProtocolConfiguration.version, "busy")
        case .protocolMismatch:
            return (TraceHelperProtocolConfiguration.version - 1, "protocol-mismatch")
        case .unavailable:
            throw TraceHelperClientError.unavailable
        }
    }

    func startTrace(
        maximumDurationSeconds: Int,
        processIdentifiers: [Int32]
    ) async throws -> String {
        let shouldFail = lock.withLock {
            guard startTraceFailures > 0 else { return false }
            startTraceFailures -= 1
            return true
        }
        if shouldFail {
            throw TraceHelperClientError.unavailable
        }
        return "session"
    }

    func startSystemTrace(maximumDurationSeconds: Int) async throws -> String {
        let shouldFail = lock.withLock {
            guard startTraceFailures > 0 else { return false }
            startTraceFailures -= 1
            return true
        }
        if shouldFail {
            throw TraceHelperClientError.unavailable
        }
        return "system-session"
    }

    func drainTrace(
        sessionID: String,
        maximumRecordCount: Int
    ) async throws -> TraceHelperDrainPayload {
        TraceHelperDrainPayload(records: [], droppedRecordCount: 0, isFinished: false, exitCode: nil)
    }

    func stopTrace(sessionID: String) async throws {}

    func invalidate() {
        lock.withLock {
            invalidateCount += 1
        }
    }
}

@MainActor
private final class FakeRegistrationStore: TraceHelperRegistrationPersisting {
    var lastHealthyFingerprint: String?
    var autoRepairAttemptedFingerprint: String?
}

@MainActor
private func makeController(
    service: FakeTraceHelperService,
    transport: FakeTraceHelperTransport,
    store: FakeRegistrationStore = FakeRegistrationStore(),
    bundleURL: URL = URL(fileURLWithPath: "/Applications/FindDiskKiller.app"),
    readinessTimeout: Duration = .milliseconds(50)
) -> TraceHelperController {
    TraceHelperController(
        service: service,
        transport: transport,
        registrationStore: store,
        bundleURL: bundleURL,
        appBundleIdentifier: "com.jianyintang.FindDiskKiller",
        appBuild: "103",
        registrationSettleTimeout: .milliseconds(50),
        readinessTimeout: readinessTimeout,
        retryDelay: .milliseconds(1),
        packagedServicePresenceOverride: true
    )
}

@Test @MainActor
func freshInstallRegistersAndBecomesHealthy() async throws {
    let service = FakeTraceHelperService(status: .notRegistered)
    let transport = FakeTraceHelperTransport([.ready])
    let store = FakeRegistrationStore()
    let controller = makeController(service: service, transport: transport, store: store)

    try await controller.prepareForTracing(recoveryMode: .automatic)

    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 0)
    #expect(controller.state == .ready)
    #expect(store.lastHealthyFingerprint?.contains("|103|") == true)
}

@Test @MainActor
func freshRegistrationWaitsForBootstrapWithoutReplacingTheService() async throws {
    let service = FakeTraceHelperService(status: .notRegistered)
    let transport = FakeTraceHelperTransport([.unavailable, .ready])
    let controller = makeController(
        service: service,
        transport: transport,
        readinessTimeout: .seconds(2)
    )

    try await controller.prepareForTracing(recoveryMode: .automatic)

    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 0)
    #expect(controller.state == .ready)
}

@Test @MainActor
func approvedFreshRegistrationThatCannotLaunchOffersRepair() async {
    let service = FakeTraceHelperService(status: .notRegistered)
    let transport = FakeTraceHelperTransport([.unavailable])
    let controller = makeController(service: service, transport: transport)

    await #expect(throws: TraceHelperClientError.repairRequired) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }

    #expect(service.registerCount == 1)
    #expect(controller.state == .repairAvailable)
}

@Test @MainActor
func freshRegistrationWaitsForServiceStatusToSettle() async throws {
    let service = FakeTraceHelperService(status: .notRegistered)
    service.registrationStatusDelayReads = 2
    let transport = FakeTraceHelperTransport([.ready])
    let controller = makeController(
        service: service,
        transport: transport,
        readinessTimeout: .seconds(2)
    )

    try await controller.prepareForTracing(recoveryMode: .automatic)

    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 0)
    #expect(controller.state == .ready)
}

@Test @MainActor
func staleUpgradeRegistrationRefreshesInPlaceAndContinues() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let transport = FakeTraceHelperTransport([.unavailable, .ready])
    let store = FakeRegistrationStore()
    let controller = makeController(service: service, transport: transport, store: store)
    var phases: [TraceHelperPreparationPhase] = []

    try await controller.prepareForTracing(recoveryMode: .automatic) { phases.append($0) }

    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 1)
    #expect(phases == [.checking, .repairing])
    #expect(controller.state == .ready)
    #expect(store.autoRepairAttemptedFingerprint == store.lastHealthyFingerprint)
}

@Test @MainActor
func protocolMismatchRefreshesTheRegisteredHelperInPlace() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let transport = FakeTraceHelperTransport([.protocolMismatch, .ready])
    let controller = makeController(service: service, transport: transport)

    try await controller.prepareForTracing(recoveryMode: .automatic)

    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 1)
    #expect(controller.state == .ready)
}

@Test @MainActor
func healthyHelperDoesNotReregisterAcrossAppBuilds() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let transport = FakeTraceHelperTransport([.ready])
    let store = FakeRegistrationStore()
    store.lastHealthyFingerprint = "older-build"
    let controller = makeController(service: service, transport: transport, store: store)

    try await controller.prepareForTracing(recoveryMode: .automatic)

    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 0)
    #expect(store.lastHealthyFingerprint?.contains("|103|") == true)
}

@Test @MainActor
func automaticRepairRunsOnlyOnceForTheCurrentBuild() async {
    let service = FakeTraceHelperService(status: .enabled)
    let store = FakeRegistrationStore()
    let firstController = makeController(
        service: service,
        transport: FakeTraceHelperTransport([.unavailable, .unavailable]),
        store: store
    )

    await #expect(throws: TraceHelperClientError.repairRequired) {
        try await firstController.prepareForTracing(recoveryMode: .automatic)
    }
    let unregisterCount = service.unregisterCount
    #expect(unregisterCount == 0)

    let secondController = makeController(
        service: service,
        transport: FakeTraceHelperTransport([.unavailable]),
        store: store
    )
    await #expect(throws: TraceHelperClientError.repairRequired) {
        try await secondController.prepareForTracing(recoveryMode: .automatic)
    }
    #expect(service.unregisterCount == unregisterCount)
}

@Test @MainActor
func userInitiatedRepairFallsBackToReplacementAfterInPlaceRefreshFails() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let transport = FakeTraceHelperTransport([])
    service.onUnregister = { transport.append([.ready]) }
    let controller = makeController(service: service, transport: transport)

    try await controller.prepareForTracing(recoveryMode: .userInitiated)

    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 2)
    #expect(controller.state == .ready)
}

@Test @MainActor
func userInitiatedRepairIgnoresTheAutomaticAttemptLimit() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let store = FakeRegistrationStore()
    store.autoRepairAttemptedFingerprint = [
        "com.jianyintang.FindDiskKiller",
        "103",
        TraceHelperProtocolConfiguration.machServiceName,
        String(TraceHelperProtocolConfiguration.version)
    ].joined(separator: "|")
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([.unavailable, .ready]),
        store: store
    )

    try await controller.prepareForTracing(recoveryMode: .userInitiated)

    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 1)
    #expect(controller.state == .ready)
}

@Test @MainActor
func registrationApprovalIsSurfacedImmediately() async {
    let service = FakeTraceHelperService(status: .notRegistered)
    service.statusAfterRegistration = .requiresApproval
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([])
    )

    await #expect(throws: TraceHelperClientError.approvalRequired) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }
    #expect(controller.state == .requiresApproval)
}

@Test @MainActor
func pendingApprovalIsNotRegisteredAgain() async {
    let service = FakeTraceHelperService(status: .requiresApproval)
    service.statusAfterRegistration = .requiresApproval
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([])
    )

    await #expect(throws: TraceHelperClientError.approvalRequired) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }

    #expect(service.registerCount == 0)
    #expect(service.unregisterCount == 0)
    #expect(controller.state == .requiresApproval)
}

@Test @MainActor
func operationNotPermittedRegistrationWaitsForSystemApproval() async throws {
    let service = FakeTraceHelperService(status: .notRegistered)
    service.registerError = NSError(
        domain: "SMAppServiceErrorDomain",
        code: 1,
        userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"]
    )
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([.ready])
    )

    await #expect(throws: TraceHelperClientError.approvalRequired) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }
    #expect(controller.state == .requiresApproval)
    #expect(service.registerCount == 1)

    service.registerError = nil
    service.status = .enabled
    try await controller.waitUntilAuthorizedAndReady()

    #expect(controller.state == .ready)
    #expect(service.unregisterCount == 0)
}

@Test @MainActor
func approvalCompletionPingsWithoutRegisteringAgain() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([.ready])
    )

    try await controller.waitUntilAuthorizedAndReady()

    #expect(service.registerCount == 0)
    #expect(service.unregisterCount == 0)
    #expect(controller.state == .ready)
}

@Test @MainActor
func registrationRetriesOnceThenStops() async {
    let service = FakeTraceHelperService(status: .notRegistered)
    service.registerFailures = 2
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([])
    )

    await #expect(throws: FakeFailure.self) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }
    #expect(service.registerCount == 2)
}

@Test @MainActor
func diskImageLaunchNeverRegistersTheHelper() async {
    let service = FakeTraceHelperService(status: .notRegistered)
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([]),
        bundleURL: URL(fileURLWithPath: "/Volumes/FindDiskKiller/FindDiskKiller.app")
    )

    await #expect(throws: TraceHelperClientError.installationRequired(isDiskImage: true)) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }
    #expect(service.registerCount == 0)
    #expect(controller.state == .installationRequired(isDiskImage: true))
}

@Test @MainActor
func arbitraryFolderLaunchNeverRegistersTheHelper() async {
    let service = FakeTraceHelperService(status: .notRegistered)
    let controller = makeController(
        service: service,
        transport: FakeTraceHelperTransport([]),
        bundleURL: URL(fileURLWithPath: "/Users/example/Downloads/FindDiskKiller.app")
    )

    await #expect(throws: TraceHelperClientError.installationRequired(isDiskImage: false)) {
        try await controller.prepareForTracing(recoveryMode: .automatic)
    }
    #expect(service.registerCount == 0)
    #expect(controller.state == .installationRequired(isDiskImage: false))
}

@Test @MainActor
func failedReconnectPreservesThePreviousSessionResults() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let transport = FakeTraceHelperTransport([.ready, .ready])
    let controller = makeController(service: service, transport: transport)
    let store = FileAccessTraceStore(helper: controller)
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "find-disk-killer-store-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    store.select(directory)
    store.setProcessSessions([
        ProcessSession(pid: Int32(ProcessInfo.processInfo.processIdentifier), startAbstime: 0)
    ])
    store.start()
    try await waitUntil { store.state == .running }
    store.stop()
    try await waitUntil { store.state == .stopped }
    let previousStart = try #require(store.startedAt)
    #expect(store.requestedReadBytes == 0)

    transport.append([.unavailable])
    store.start()
    try await waitUntil { store.state == .repairAvailable }

    #expect(store.startedAt == previousStart)
    #expect(store.requestedReadBytes == 0)
}

@Test @MainActor
func failedStartPreservesResultsUntilANewSessionIDIsReceived() async throws {
    let service = FakeTraceHelperService(status: .enabled)
    let transport = FakeTraceHelperTransport([.ready, .ready])
    let controller = makeController(service: service, transport: transport)
    let store = FileAccessTraceStore(helper: controller)
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "find-disk-killer-start-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    store.select(directory)
    store.setProcessSessions([
        ProcessSession(pid: Int32(ProcessInfo.processInfo.processIdentifier), startAbstime: 0)
    ])
    store.start()
    try await waitUntil { store.state == .running }
    store.stop()
    try await waitUntil { store.state == .stopped }
    let previousStart = try #require(store.startedAt)

    transport.append([.ready, .ready])
    transport.failNextStartTrace()
    store.start()
    try await waitUntil {
        if case .failed = store.state { return true }
        return false
    }
    #expect(store.startedAt == previousStart)

    try await Task.sleep(for: .milliseconds(10))
    transport.append([.ready, .ready])
    store.start()
    try await waitUntil { store.state == .running }
    #expect(try #require(store.startedAt) > previousStart)
    store.stop()
}

@Test
func electronFSUsageFixtureResolvesOpenDescriptorAndCountsWrite() async throws {
    let process = TraceHelperProcessIdentity(
        pid: 28_104,
        startAbstime: 4_170_074_877_576,
        displayName: "Electron"
    )
    let target = try FileAccessTraceTarget(
        path: "/Users/example/.redeven/local-environment/diagnostics",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: false
    )
    let startedAt = try traceFixtureDate(hour: 15, minute: 47, second: 0)
    let engine = FileAccessTraceEngine(
        target: target,
        startedAt: startedAt,
        sessions: [ProcessSession(pid: process.pid, startAbstime: process.startAbstime)],
        openFiles: [],
        descriptorKind: { _, _ in .unavailable }
    )
    let path = "/Users/example/.redeven/local-environment/diagnostics/desktop-events.jsonl"
    let openLine = "15:47:01.804268 open F=75 (_WCA_______X___) \(path) 0.000150 Electron.18306140"
    let writeLine = "15:47:01.804384 write F=75 B=0x14e 0.000056 Electron.18306139"
    #expect(FileAccessTraceDescriptorParser.parse(line: openLine) == .opened(
        fileDescriptor: 75,
        path: path
    ))
    guard case .event(let parsedWrite) = FileAccessTraceParser.parse(
        line: writeLine,
        on: try traceFixtureDate(hour: 15, minute: 47, second: 2)
    ) else {
        Issue.record("Expected the captured Electron write row to parse")
        return
    }
    #expect(parsedWrite.timestamp >= startedAt)
    let payload = TraceHelperDrainPayload(
        records: [
            TraceHelperRecord(
                line: openLine,
                process: process
            ),
            TraceHelperRecord(
                line: writeLine,
                process: process
            ),
            TraceHelperRecord(
                line: "15:47:01.804527 close F=75 0.000083 Electron.18306137",
                process: process
            )
        ],
        droppedRecordCount: 0,
        isFinished: false,
        exitCode: nil
    )

    let update = await engine.consume(
        payload,
        at: try traceFixtureDate(hour: 15, minute: 47, second: 2)
    )

    #expect(update.snapshot.coverage == .complete)
    #expect(update.snapshot.requestedReadBytes == 0)
    #expect(update.snapshot.requestedWriteBytes == 0x14e)
    #expect(update.snapshot.files.first?.path == path)
    #expect(update.snapshot.processes.first?.identity.pid == process.pid)
}

@Test
func electronNonVnodeReadDoesNotCreateAFileCoverageGap() async throws {
    let process = TraceHelperProcessIdentity(
        pid: 28_106,
        startAbstime: 4_170_079_334_674,
        displayName: "Electron Helper"
    )
    let target = try FileAccessTraceTarget(
        path: "/private/var/folders/example/T",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: false
    )
    let startedAt = try traceFixtureDate(hour: 15, minute: 47, second: 0)
    let engine = FileAccessTraceEngine(
        target: target,
        startedAt: startedAt,
        sessions: [ProcessSession(pid: process.pid, startAbstime: process.startAbstime)],
        openFiles: [],
        descriptorKind: { session, fileDescriptor in
            #expect(session.pid == process.pid)
            #expect(fileDescriptor == 23)
            return .nonVnode
        }
    )
    let payload = TraceHelperDrainPayload(
        records: [TraceHelperRecord(
            line: "15:47:02.734963 read F=23 B=0x12 0.000009 Electron Helper.18306121",
            process: process
        )],
        droppedRecordCount: 0,
        isFinished: false,
        exitCode: nil
    )

    let update = await engine.consume(
        payload,
        at: try traceFixtureDate(hour: 15, minute: 47, second: 3)
    )

    #expect(update.snapshot.coverage == .complete)
    #expect(update.snapshot.requestedReadBytes == 0)
    #expect(update.snapshot.requestedWriteBytes == 0)
    #expect(update.snapshot.files.isEmpty)
    #expect(update.snapshot.processes.isEmpty)
}

@Test(arguments: [FileDescriptorKind.vnode, .unavailable])
func electronPathlessFileReadIsNotSilentlyDiscarded(
    descriptorKind: FileDescriptorKind
) async throws {
    let process = TraceHelperProcessIdentity(
        pid: 28_106,
        startAbstime: 4_170_079_334_674,
        displayName: "Electron Helper"
    )
    let target = try FileAccessTraceTarget(
        path: "/private/var/folders/example/T",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: false
    )
    let engine = FileAccessTraceEngine(
        target: target,
        startedAt: try traceFixtureDate(hour: 15, minute: 47, second: 0),
        sessions: [ProcessSession(pid: process.pid, startAbstime: process.startAbstime)],
        openFiles: [],
        descriptorKind: { _, _ in descriptorKind }
    )
    let payload = TraceHelperDrainPayload(
        records: [TraceHelperRecord(
            line: "15:47:02.734963 read F=23 B=0x12 0.000009 Electron Helper.18306121",
            process: process
        )],
        droppedRecordCount: 0,
        isFinished: false,
        exitCode: nil
    )

    let update = await engine.consume(
        payload,
        at: try traceFixtureDate(hour: 15, minute: 47, second: 3)
    )

    #expect(update.snapshot.coverage == .partial(droppedEventCount: 1))
    #expect(update.snapshot.requestedReadBytes == 0)
    #expect(update.snapshot.files.isEmpty)
    #expect(update.snapshot.processes.isEmpty)
}

private func traceFixtureDate(hour: Int, minute: Int, second: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    return try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 27,
        hour: hour,
        minute: minute,
        second: second
    )))
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FakeFailure.expected
}
