import Foundation
import FindDiskKillerCore
import FindDiskKillerTraceProtocol
import Observation

struct VolumeAccessTraceSelection: Sendable {
    let volume: VolumeInfo
    let target: VolumeAccessTraceTarget
    let displayName: String
    let mountPath: String

    static func make(volume: VolumeInfo) -> Self {
        let mountURL = URL(fileURLWithPath: volume.mountPath, isDirectory: true)
        let isCaseSensitive = (try? mountURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? true
        return Self(
            volume: volume,
            target: VolumeAccessTraceTarget(
                volume: volume,
                isCaseSensitive: isCaseSensitive
            ),
            displayName: volume.name,
            mountPath: volume.mountPath
        )
    }
}

struct VolumeAccessTraceEngineUpdate: Sendable {
    let snapshot: VolumeAccessTraceSnapshot
    let terminalFailure: Bool
}

actor VolumeAccessTraceEngine {
    typealias DescriptorKindResolver = @Sendable (
        ProcessSession,
        Int32
    ) -> FileDescriptorKind

    private var aggregator: VolumeAccessTraceAggregator
    private var descriptors = FileAccessTraceDescriptorIndex()
    private let descriptorKind: DescriptorKindResolver

    init(
        target: VolumeAccessTraceTarget,
        startedAt: Date,
        sessions: [ProcessSession],
        openFiles: [OpenFileRecord],
        descriptorKind: @escaping DescriptorKindResolver = FileDescriptorInspector.kind
    ) {
        self.descriptorKind = descriptorKind
        aggregator = VolumeAccessTraceAggregator(target: target, startedAt: startedAt)
        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
        for file in openFiles {
            guard let session = sessionsByPID[file.pid] else { continue }
            let process = FileAccessTraceProcessIdentity(
                pid: session.pid,
                startAbstime: session.startAbstime,
                displayName: ""
            )
            descriptors.register(
                path: file.path,
                process: process,
                fileDescriptor: file.fileDescriptor
            )
        }
    }

    func consume(
        _ payload: TraceHelperDrainPayload,
        at now: Date
    ) -> VolumeAccessTraceEngineUpdate {
        if payload.droppedRecordCount > 0 {
            aggregator.markDroppedEvents(payload.droppedRecordCount)
        }
        for record in payload.records {
            let process = record.process.map {
                FileAccessTraceProcessIdentity(
                    pid: $0.pid,
                    startAbstime: $0.startAbstime,
                    displayName: $0.displayName
                )
            }
            if let process,
               let descriptorChange = FileAccessTraceDescriptorParser.parse(line: record.line) {
                apply(descriptorChange, process: process)
            }
            switch VolumeAccessTraceParser.parse(line: record.line, on: now) {
            case .event(let parsed):
                let path = parsed.path ?? descriptorPath(
                    process: process,
                    fileDescriptor: parsed.fileDescriptor
                )
                guard let path else {
                    if parsed.pathWasTruncated {
                        aggregator.markDroppedEvents()
                    } else if parsed.category == .read || parsed.category == .write {
                        aggregator.markDroppedEvents()
                    } else if let tracedProcess = record.process,
                              let fileDescriptor = parsed.fileDescriptor,
                              descriptorKind(
                                  ProcessSession(
                                      pid: tracedProcess.pid,
                                      startAbstime: tracedProcess.startAbstime
                                  ),
                                  fileDescriptor
                              ) != .nonVnode {
                        aggregator.markDroppedEvents()
                    }
                    continue
                }
                let reference = process.map {
                    VolumeAccessTraceProcessReference(
                        pid: $0.pid,
                        startAbstime: $0.startAbstime,
                        displayName: $0.displayName.isEmpty ? parsed.processLabel : $0.displayName
                    )
                } ?? VolumeAccessTraceProcessReference(
                    pid: nil,
                    startAbstime: nil,
                    displayName: parsed.processLabel
                )
                aggregator.ingest(VolumeAccessTraceEvent(
                    timestamp: parsed.timestamp,
                    operation: parsed.operation,
                    category: parsed.category,
                    requestedBytes: parsed.requestedBytes,
                    path: path,
                    process: reference
                ))
            case .unsupportedFormat:
                aggregator.markUnsupportedFormat()
            case .failedCall, .ignored:
                continue
            }
        }
        let terminalFailure = payload.isFinished && payload.exitCode.map { $0 != 0 } == true
        return VolumeAccessTraceEngineUpdate(
            snapshot: aggregator.snapshot(),
            terminalFailure: terminalFailure
        )
    }

    func snapshot() -> VolumeAccessTraceSnapshot {
        aggregator.snapshot()
    }

    func refreshDescriptors(sessions: [ProcessSession], openFiles: [OpenFileRecord]) {
        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
        let refreshedPIDs = Set(openFiles.map(\.pid))
        descriptors.removeAll(processIdentifiers: refreshedPIDs)
        for file in openFiles {
            guard let session = sessionsByPID[file.pid] else { continue }
            let process = FileAccessTraceProcessIdentity(
                pid: session.pid,
                startAbstime: session.startAbstime,
                displayName: ""
            )
            descriptors.register(
                path: file.path,
                process: process,
                fileDescriptor: file.fileDescriptor
            )
        }
    }

    private func descriptorPath(
        process: FileAccessTraceProcessIdentity?,
        fileDescriptor: Int32?
    ) -> String? {
        guard let process, let fileDescriptor else { return nil }
        return descriptors.path(process: process, fileDescriptor: fileDescriptor)
    }

    private func apply(
        _ change: FileAccessTraceDescriptorChange,
        process: FileAccessTraceProcessIdentity
    ) {
        switch change {
        case .opened(let fileDescriptor, let path):
            descriptors.register(
                path: path,
                process: process,
                fileDescriptor: fileDescriptor
            )
        case .closed(let fileDescriptor):
            descriptors.close(process: process, fileDescriptor: fileDescriptor)
        }
    }
}

@MainActor
@Observable
final class VolumeAccessTraceStore {
    private(set) var state: FileAccessTraceRunState = .noTarget
    private(set) var selection: VolumeAccessTraceSelection?
    private(set) var coverage: FileAccessTraceCoverage = .complete
    private(set) var firstEventAt: Date?
    private(set) var lastEventAt: Date?
    private(set) var requestedReadBytes: UInt64?
    private(set) var requestedWriteBytes: UInt64?
    private(set) var metadataEventCount: Int?
    private(set) var sources: [VolumeAccessTraceSourceSummary] = []
    private(set) var events: [VolumeAccessTraceEventSummary] = []
    private(set) var startedAt: Date?
    private(set) var elapsed: TimeInterval = 0

    let helper: TraceHelperController
    @ObservationIgnored private let activityRegistry: TraceActivityRegistry
    @ObservationIgnored private let openFileSampler = OpenFileSampler(budget: .init(
        maximumProcesses: 160,
        maximumFilesPerProcess: 384,
        maximumDuration: .milliseconds(450)
    ))
    @ObservationIgnored private var engine: VolumeAccessTraceEngine?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var activityLease: TraceActivityLease?
    @ObservationIgnored private var lastListUpdate = Date.distantPast
    @ObservationIgnored private var hasPendingStartIntent = false
    @ObservationIgnored private var attemptedRegistrationForIntent = false
    @ObservationIgnored private var monitoredSessions: [ProcessSession] = []

    init(
        helper: TraceHelperController = TraceHelperController(),
        activityRegistry: TraceActivityRegistry = TraceActivityRegistry()
    ) {
        self.helper = helper
        self.activityRegistry = activityRegistry
    }

    var isRunning: Bool {
        switch state {
        case .starting, .repairing, .running, .stopping, .stopUnconfirmed: true
        default: false
        }
    }

    func setProcessSessions(_ sessions: [ProcessSession]) {
        guard !isRunning else { return }
        monitoredSessions = Array(sessions.prefix(512))
    }

    func select(_ volume: VolumeInfo, startImmediately: Bool = false) {
        guard !isRunning else { return }
        cancelPendingStart()
        selection = .make(volume: volume)
        resetMeasurements()
        helper.refreshStatus()
        state = stateForHelper()
        if startImmediately {
            start()
        }
    }

    func refreshPermissionStatus() {
        helper.refreshStatus()
        guard selection != nil, !isRunning else { return }
        if hasPendingStartIntent {
            advancePendingStart(allowRegistration: false)
        } else {
            state = stateForHelper()
        }
    }

    func requestPermission() {
        guard selection != nil, !isRunning else { return }
        guard reserveTraceIntent() else { return }
        hasPendingStartIntent = true
        attemptedRegistrationForIntent = false
        advancePendingStart(allowRegistration: true)
    }

    func openApprovalSettings() {
        helper.openLoginItemsSettings()
    }

    func start() {
        guard selection != nil, !isRunning else { return }
        guard reserveTraceIntent() else { return }
        hasPendingStartIntent = true
        attemptedRegistrationForIntent = false
        advancePendingStart(allowRegistration: true, recoveryMode: .automatic)
    }

    func repairAndRetry() {
        guard selection != nil, !isRunning else { return }
        guard reserveTraceIntent() else { return }
        hasPendingStartIntent = true
        attemptedRegistrationForIntent = true
        launchTrace(recoveryMode: .userInitiated)
    }

    func openInstallationLocation() {
        helper.openInstallationLocation()
    }

    func stop() {
        guard isRunning else { return }
        cancelPendingStart(releaseLease: false)
        state = .stopping
        let activeSessionID = sessionID
        let activeDrainTask = drainTask
        drainTask?.cancel()
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            guard let self else { return }
            if let activeSessionID {
                await self.confirmStop(sessionID: activeSessionID, finalState: .stopped)
            } else {
                await activeDrainTask?.value
                if self.activityLease != nil, self.state == .stopping {
                    self.finishTrace(.stopped)
                }
            }
        }
    }

    func clear() {
        guard !isRunning else { return }
        cancelPendingStart()
        stopDetachedSessionIfNeeded()
        resetMeasurements()
        state = selection == nil ? .noTarget : stateForHelper()
    }

    func removeTarget() {
        guard !isRunning else { return }
        cancelPendingStart()
        stopDetachedSessionIfNeeded()
        selection = nil
        resetMeasurements()
        state = .noTarget
    }

    private func advancePendingStart(
        allowRegistration: Bool,
        recoveryMode: TraceHelperRecoveryMode = .automatic
    ) {
        guard hasPendingStartIntent, selection != nil, !isRunning else { return }
        helper.refreshStatus()
        switch helper.state {
        case .enabled, .ready:
            launchTrace(recoveryMode: recoveryMode)
        case .requiresApproval:
            state = .waitingForApproval
        case .notRegistered, .notFound:
            guard allowRegistration, !attemptedRegistrationForIntent else {
                state = stateForHelper()
                return
            }
            attemptedRegistrationForIntent = true
            launchTrace(recoveryMode: recoveryMode)
        case .connecting:
            state = .ready
        case .repairing:
            state = .repairing
        case .repairAvailable:
            state = .repairAvailable
            cancelPendingStart()
        case .installationRequired(let isDiskImage):
            state = .installationRequired(isDiskImage: isDiskImage)
            cancelPendingStart()
        case .protocolMismatch, .connectionUnavailable, .operationFailed:
            state = stateForHelper()
            cancelPendingStart()
        }
    }

    private func launchTrace(recoveryMode: TraceHelperRecoveryMode) {
        guard let selection, hasPendingStartIntent, !isRunning else { return }
        hasPendingStartIntent = false
        attemptedRegistrationForIntent = false
        state = .starting
        beginNewMeasurementSession(at: Date())
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            guard let self else { return }
            var startedSessionID: String?
            do {
                try await helper.prepareForTracing(recoveryMode: recoveryMode) { phase in
                    if phase == .repairing {
                        self.state = .repairing
                    }
                }
                activityRegistry.markHelperReadyWithoutLocalLease()
                guard !Task.isCancelled else { return }
                let sessionID = try await helper.startSystemTrace(maximumDurationSeconds: 900)
                startedSessionID = sessionID
                guard !Task.isCancelled else {
                    await self.confirmStop(sessionID: sessionID, finalState: .stopped)
                    return
                }
                let now = Date()
                beginNewMeasurementSession(at: now)
                self.sessionID = sessionID
                self.engine = VolumeAccessTraceEngine(
                    target: selection.target,
                    startedAt: now,
                    sessions: [],
                    openFiles: []
                )
                self.state = .running
                await self.refreshDescriptorBaseline()
                await self.drain(sessionID: sessionID)
            } catch is CancellationError {
                if let startedSessionID {
                    await self.confirmStop(sessionID: startedSessionID, finalState: .stopped)
                } else {
                    self.finishTrace(.stopped)
                }
                return
            } catch TraceHelperClientError.approvalRequired {
                self.hasPendingStartIntent = true
                self.state = .waitingForApproval
                self.helper.openLoginItemsSettings()
            } catch TraceHelperClientError.installationRequired(let isDiskImage) {
                self.state = .installationRequired(isDiskImage: isDiskImage)
                self.releaseTraceLease()
            } catch TraceHelperClientError.repairRequired {
                self.state = .repairAvailable
                self.releaseTraceLease()
            } catch TraceHelperClientError.busy {
                self.state = .stopUnconfirmed
                self.markStopUnconfirmed()
                await self.reconcileStoppedSession(
                    sessionID: nil,
                    finalState: .failed(self.message(for: TraceHelperClientError.busy))
                )
            } catch {
                self.state = helper.state == .repairAvailable
                    ? .repairAvailable
                    : .failed(self.message(for: error))
                self.releaseTraceLease()
            }
        }
    }

    private func drain(sessionID: String) async {
        var lastDescriptorRefresh = Date()
        var lastPublished = Date.distantPast
        while !Task.isCancelled {
            do {
                let payload = try await helper.drainTrace(
                    sessionID: sessionID,
                    maximumRecordCount: TraceHelperProtocolConfiguration.maximumDrainRecordCount
                )
                let now = Date()
                guard let engine else { return }
                if now.timeIntervalSince(lastDescriptorRefresh) >= 2 {
                    await refreshDescriptorBaseline()
                    lastDescriptorRefresh = now
                }
                let update = await engine.consume(payload, at: now)
                if now.timeIntervalSince(lastPublished) >= 0.25
                    || update.terminalFailure || payload.isFinished {
                    publish(update.snapshot, at: now)
                    lastPublished = now
                }
                if update.terminalFailure {
                    self.sessionID = nil
                    state = .failed(L10n.text("系统追踪提前结束，已有结果可能不完整"))
                    releaseTraceLease()
                    return
                }
                if payload.isFinished {
                    self.sessionID = nil
                    state = .stopped
                    releaseTraceLease()
                    return
                }
                if payload.hasMoreRecords {
                    await Task.yield()
                } else {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                return
            } catch {
                await confirmStop(
                    sessionID: sessionID,
                    finalState: .failed(message(for: error))
                )
                return
            }
        }
    }

    private func refreshDescriptorBaseline() async {
        guard let engine else { return }
        let sessions = monitoredSessions
        let snapshot = await openFileSampler.sample(sessions: sessions)
        await engine.refreshDescriptors(sessions: sessions, openFiles: snapshot.records)
    }

    private func publish(_ snapshot: VolumeAccessTraceSnapshot, at now: Date) {
        coverage = snapshot.coverage
        firstEventAt = snapshot.firstEventAt
        lastEventAt = snapshot.lastEventAt
        requestedReadBytes = snapshot.requestedReadBytes
        requestedWriteBytes = snapshot.requestedWriteBytes
        metadataEventCount = snapshot.metadataEventCount
        elapsed = startedAt.map { now.timeIntervalSince($0) } ?? 0

        if now.timeIntervalSince(lastListUpdate) >= 1
            || snapshot.coverage == .unsupportedFormat {
            sources = snapshot.sources
            events = snapshot.events
            lastListUpdate = now
        }
        if snapshot.coverage == .unsupportedFormat {
            let activeSessionID = sessionID
            drainTask?.cancel()
            state = .unsupportedFormat
            if let activeSessionID {
                stopTask?.cancel()
                stopTask = Task { [weak self] in
                    await self?.confirmStop(
                        sessionID: activeSessionID,
                        finalState: .unsupportedFormat
                    )
                }
            } else {
                releaseTraceLease()
            }
        }
    }

    private func stateForHelper() -> FileAccessTraceRunState {
        switch helper.state {
        case .notRegistered: .permissionRequired
        case .requiresApproval: .waitingForApproval
        case .enabled, .ready, .connecting: .ready
        case .notFound: .failed(L10n.text("当前应用构建中没有可用的追踪组件"))
        case .protocolMismatch: .failed(L10n.text("追踪组件版本不匹配，请重新安装应用"))
        case .connectionUnavailable: .failed(L10n.text("无法连接文件访问追踪组件"))
        case .repairing: .repairing
        case .repairAvailable: .repairAvailable
        case .installationRequired(let isDiskImage):
            .installationRequired(isDiskImage: isDiskImage)
        case .operationFailed(let message): .failed(message)
        }
    }

    private func message(for error: Error) -> String {
        switch error as? TraceHelperClientError {
        case .busy:
            L10n.text("已有追踪正在运行或结束中，请稍后重试")
        case .protocolMismatch:
            L10n.text("追踪组件版本不匹配，请重新安装应用")
        case .approvalRequired:
            L10n.text("需要启用文件访问追踪")
        case .installationRequired:
            L10n.text("需要先安装到应用程序文件夹")
        case .repairRequired:
            L10n.text("追踪组件需要修复")
        case .rejected(let status):
            L10n.format("追踪组件未能开始：%@", status)
        case .invalidPayload:
            L10n.text("追踪组件返回了无法识别的数据")
        default:
            L10n.text("无法连接文件访问追踪组件")
        }
    }

    private func resetMeasurements() {
        drainTask?.cancel()
        drainTask = nil
        sessionID = nil
        engine = nil
        clearPublishedMeasurements()
        startedAt = nil
        elapsed = 0
    }

    private func beginNewMeasurementSession(at now: Date) {
        engine = nil
        clearPublishedMeasurements()
        startedAt = now
        elapsed = 0
        requestedReadBytes = 0
        requestedWriteBytes = 0
        metadataEventCount = 0
    }

    private func clearPublishedMeasurements() {
        coverage = .complete
        firstEventAt = nil
        lastEventAt = nil
        requestedReadBytes = nil
        requestedWriteBytes = nil
        metadataEventCount = nil
        sources = []
        events = []
        lastListUpdate = .distantPast
    }

    private func stopDetachedSessionIfNeeded() {
        guard let sessionID else { return }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            await self?.confirmStop(sessionID: sessionID, finalState: .stopped)
        }
    }

    private func cancelPendingStart(releaseLease: Bool = true) {
        hasPendingStartIntent = false
        attemptedRegistrationForIntent = false
        if releaseLease, sessionID == nil, !isRunning {
            releaseTraceLease()
        }
    }

    private func reserveTraceIntent() -> Bool {
        if activityLease != nil { return true }
        guard let lease = activityRegistry.acquireTrace() else {
            state = .failed(traceStartBlockMessage)
            return false
        }
        activityLease = lease
        return true
    }

    private var traceStartBlockMessage: String {
        switch activityRegistry.traceStartBlockReason {
        case .updateInstallation:
            L10n.text("正在检查或安装更新，请稍后再开始追踪")
        case .anotherTrace, nil:
            L10n.text("已有追踪正在运行或结束中，请稍后重试")
        }
    }

    private func markStopUnconfirmed() {
        guard let activityLease else { return }
        activityRegistry.markTraceStopUnconfirmed(activityLease)
    }

    private func releaseTraceLease() {
        guard let activityLease else { return }
        activityRegistry.releaseTrace(activityLease)
        self.activityLease = nil
    }

    private func finishTrace(_ finalState: FileAccessTraceRunState) {
        sessionID = nil
        drainTask = nil
        stopTask = nil
        releaseTraceLease()
        state = selection == nil ? .noTarget : finalState
    }

    private func confirmStop(
        sessionID: String,
        finalState: FileAccessTraceRunState
    ) async {
        if let activityLease {
            activityRegistry.markTraceStopping(activityLease)
        }
        do {
            try await helper.stopTrace(sessionID: sessionID)
            finishTrace(finalState)
        } catch {
            state = .stopUnconfirmed
            markStopUnconfirmed()
            await reconcileStoppedSession(sessionID: sessionID, finalState: finalState)
        }
    }

    private func reconcileStoppedSession(
        sessionID: String?,
        finalState: FileAccessTraceRunState
    ) async {
        while !Task.isCancelled {
            do {
                if try await helper.activityStatus(timeout: .seconds(1)) == .ready {
                    finishTrace(finalState)
                    return
                }
            } catch {
                // A disconnected helper is not proof that fs_usage exited.
            }
            if let sessionID {
                do {
                    try await helper.stopTrace(sessionID: sessionID)
                    finishTrace(finalState)
                    return
                } catch {
                    // Retry after the helper reconnects or finishes the child process.
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
