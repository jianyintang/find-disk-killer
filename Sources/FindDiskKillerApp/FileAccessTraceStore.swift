import Foundation
import FindDiskKillerCore
import FindDiskKillerTraceProtocol
import Observation

enum FileAccessTraceRunState: Equatable {
    case noTarget
    case ready
    case permissionRequired
    case waitingForApproval
    case starting
    case running
    case stopped
    case failed(String)
    case unsupportedFormat
}

struct FileAccessTraceRatePoint: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    var id: Date { timestamp }
}

struct FileAccessTraceSelection: Equatable, Sendable {
    let url: URL
    let target: FileAccessTraceTarget
    let displayName: String
    let privatePath: String
    let kind: FileAccessTraceTargetKind

    static func make(url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey,
            .volumeSupportsCaseSensitiveNamesKey
        ])
        guard let volumeIdentifier = values.volumeIdentifier else {
            throw FileAccessTraceTargetError.missingVolumeIdentity
        }
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let kind: FileAccessTraceTargetKind = values.isDirectory == true ? .directory : .file
        let target = try FileAccessTraceTarget(
            path: standardized.path,
            resolvedPath: resolved.path == standardized.path ? nil : resolved.path,
            volumeIdentifier: String(describing: volumeIdentifier),
            kind: kind,
            isCaseSensitive: values.volumeSupportsCaseSensitiveNames == true
        )
        return Self(
            url: standardized,
            target: target,
            displayName: standardized.lastPathComponent,
            privatePath: privatePath(standardized.path),
            kind: kind
        )
    }

    private static func privatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private struct FileAccessTraceEngineUpdate: Sendable {
    let snapshot: FileAccessTraceSnapshot
    let terminalFailure: Bool
}

private actor FileAccessTraceEngine {
    private var parser = FileAccessTraceStreamParser()
    private var aggregator: FileAccessTraceAggregator
    private let target: FileAccessTraceTarget
    private var descriptors = FileAccessTraceDescriptorIndex()

    init(
        target: FileAccessTraceTarget,
        startedAt: Date,
        sessions: [ProcessSession],
        openFiles: [OpenFileRecord]
    ) {
        self.target = target
        aggregator = FileAccessTraceAggregator(target: target, startedAt: startedAt)
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
    ) -> FileAccessTraceEngineUpdate {
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
            switch parser.consume(line: record.line, on: now) {
            case .event(let parsed):
                let resolvedProcess = process.map {
                    FileAccessTraceProcessIdentity(
                        pid: $0.pid,
                        startAbstime: $0.startAbstime,
                        displayName: $0.displayName.isEmpty ? parsed.processLabel : $0.displayName
                    )
                }
                let path = parsed.path ?? descriptorPath(
                    process: resolvedProcess,
                    fileDescriptor: parsed.fileDescriptor
                )
                let volumeIdentifier = volumeIdentifier(for: path)
                aggregator.ingest(FileAccessTraceEvent(
                    timestamp: parsed.timestamp,
                    direction: parsed.direction,
                    requestedBytes: parsed.requestedBytes,
                    path: path,
                    volumeIdentifier: volumeIdentifier,
                    process: resolvedProcess
                ))
            case .unsupportedFormat:
                aggregator.markUnsupportedFormat()
            case .unparseableEvent:
                aggregator.markDroppedEvents()
            case .ignored, .failedCall:
                continue
            }
        }
        let terminalFailure = payload.isFinished && (
            parser.state == .awaitingHeader || payload.exitCode.map { $0 != 0 } == true
        )
        return FileAccessTraceEngineUpdate(
            snapshot: aggregator.snapshot(at: now),
            terminalFailure: terminalFailure
        )
    }

    func snapshot(at now: Date) -> FileAccessTraceSnapshot {
        aggregator.snapshot(at: now)
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

    private func volumeIdentifier(for path: String?) -> String? {
        path == nil ? nil : target.volumeIdentifier
    }
}

@MainActor
@Observable
final class FileAccessTraceStore {
    private(set) var state: FileAccessTraceRunState = .noTarget
    private(set) var selection: FileAccessTraceSelection?
    private(set) var requestedReadBytes: UInt64?
    private(set) var requestedWriteBytes: UInt64?
    private(set) var currentReadBytesPerSecond: Double?
    private(set) var currentWriteBytesPerSecond: Double?
    private(set) var peakReadBytesPerSecond: UInt64?
    private(set) var peakWriteBytesPerSecond: UInt64?
    private(set) var coverage: FileAccessTraceCoverage = .complete
    private(set) var files: [FileAccessTraceFileSummary] = []
    private(set) var processes: [FileAccessTraceProcessSummary] = []
    private(set) var ratePoints: [FileAccessTraceRatePoint] = []
    private(set) var startedAt: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastEventAt: Date?

    let helper = TraceHelperController()
    @ObservationIgnored private var engine: FileAccessTraceEngine?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var lastListUpdate = Date.distantPast
    @ObservationIgnored private var lastChartPoint = Date.distantPast
    @ObservationIgnored private var hasPendingStartIntent = false
    @ObservationIgnored private var attemptedRegistrationForIntent = false
    @ObservationIgnored private var monitoredSessions: [ProcessSession] = []

    var isRunning: Bool { state == .running || state == .starting }

    func setProcessSessions(_ sessions: [ProcessSession]) {
        guard !isRunning else { return }
        monitoredSessions = Array(sessions.prefix(
            TraceHelperProtocolConfiguration.maximumProcessIdentifierCount
        ))
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

    func select(_ url: URL) {
        guard !isRunning else { return }
        cancelPendingStart()
        do {
            selection = try FileAccessTraceSelection.make(url: url)
            resetMeasurements()
            helper.refreshStatus()
            state = stateForHelper()
        } catch {
            state = .failed(L10n.text("无法读取所选位置的信息"))
        }
    }

    func requestPermission() {
        guard selection != nil, !isRunning else { return }
        hasPendingStartIntent = true
        attemptedRegistrationForIntent = false
        advancePendingStart(allowRegistration: true)
    }

    func openApprovalSettings() {
        helper.openLoginItemsSettings()
    }

    func start() {
        guard selection != nil, !isRunning else { return }
        hasPendingStartIntent = true
        attemptedRegistrationForIntent = false
        advancePendingStart(allowRegistration: true)
    }

    func beginTracing(_ url: URL) {
        guard !isRunning else { return }
        let standardizedURL = url.standardizedFileURL
        if selection?.url.standardizedFileURL.path != standardizedURL.path {
            select(standardizedURL)
        }
        guard selection?.url.standardizedFileURL.path == standardizedURL.path else { return }
        start()
    }

    private func advancePendingStart(allowRegistration: Bool) {
        guard hasPendingStartIntent, selection != nil, !isRunning else { return }
        helper.refreshStatus()
        switch helper.state {
        case .enabled, .ready:
            launchTrace()
        case .requiresApproval:
            state = .waitingForApproval
        case .notRegistered, .notFound:
            guard allowRegistration, !attemptedRegistrationForIntent else {
                state = stateForHelper()
                return
            }
            attemptedRegistrationForIntent = true
            helper.requestRegistration()
            if helper.state == .requiresApproval {
                state = .waitingForApproval
                helper.openLoginItemsSettings()
            } else if helper.state == .enabled || helper.state == .ready {
                launchTrace()
            } else {
                state = stateForHelper()
                if case .failed = state {
                    cancelPendingStart()
                }
            }
        case .connecting:
            state = .ready
        case .protocolMismatch, .connectionUnavailable, .operationFailed:
            state = stateForHelper()
            cancelPendingStart()
        }
    }

    private func launchTrace() {
        guard let selection, hasPendingStartIntent, !isRunning else { return }
        let sessions = monitoredSessions
        let processIdentifiers = sessions.map(\.pid)
        guard !processIdentifiers.isEmpty else {
            state = .failed(L10n.text("应用已经结束"))
            cancelPendingStart()
            return
        }
        hasPendingStartIntent = false
        attemptedRegistrationForIntent = false
        resetMeasurements()
        let now = Date()
        startedAt = now
        requestedReadBytes = 0
        requestedWriteBytes = 0
        currentReadBytesPerSecond = 0
        currentWriteBytesPerSecond = 0
        peakReadBytesPerSecond = 0
        peakWriteBytesPerSecond = 0
        ratePoints = [FileAccessTraceRatePoint(
            timestamp: now,
            readBytesPerSecond: 0,
            writeBytesPerSecond: 0
        )]
        state = .starting
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sessionID = try await helper.startTrace(
                    maximumDurationSeconds: 900,
                    processIdentifiers: processIdentifiers
                )
                guard !Task.isCancelled else {
                    try? await helper.stopTrace(sessionID: sessionID)
                    return
                }
                self.sessionID = sessionID
                let baseline = await OpenFileSampler.shared.sample(sessions: sessions)
                guard !Task.isCancelled else {
                    try? await helper.stopTrace(sessionID: sessionID)
                    return
                }
                self.engine = FileAccessTraceEngine(
                    target: selection.target,
                    startedAt: now,
                    sessions: sessions,
                    openFiles: baseline.records
                )
                self.state = .running
                await self.drain(sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch TraceHelperClientError.approvalRequired {
                self.hasPendingStartIntent = true
                self.state = .waitingForApproval
                self.helper.openLoginItemsSettings()
            } catch {
                self.state = .failed(self.message(for: error))
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        cancelPendingStart()
        let sessionID = sessionID
        drainTask?.cancel()
        drainTask = nil
        self.sessionID = nil
        state = .stopped
        Task {
            if let sessionID {
                try? await helper.stopTrace(sessionID: sessionID)
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

    func endEphemeralSession() {
        cancelPendingStart()
        let activeSessionID = sessionID
        drainTask?.cancel()
        drainTask = nil
        sessionID = nil
        engine = nil
        resetMeasurements()
        state = selection == nil ? .noTarget : stateForHelper()
        if let activeSessionID {
            Task {
                try? await helper.stopTrace(sessionID: activeSessionID)
            }
        }
    }

    func removeTarget() {
        guard !isRunning else { return }
        cancelPendingStart()
        stopDetachedSessionIfNeeded()
        selection = nil
        resetMeasurements()
        state = .noTarget
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
                    let sessions = monitoredSessions
                    let snapshot = await OpenFileSampler.shared.sample(sessions: sessions)
                    await engine.refreshDescriptors(
                        sessions: sessions,
                        openFiles: snapshot.records
                    )
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
                    return
                }
                if payload.isFinished {
                    self.sessionID = nil
                    state = .stopped
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
                self.sessionID = nil
                state = .failed(message(for: error))
                return
            }
        }
    }

    private func publish(_ snapshot: FileAccessTraceSnapshot, at now: Date) {
        coverage = snapshot.coverage
        requestedReadBytes = snapshot.requestedReadBytes
        requestedWriteBytes = snapshot.requestedWriteBytes
        currentReadBytesPerSecond = snapshot.currentReadBytesPerSecond
        currentWriteBytesPerSecond = snapshot.currentWriteBytesPerSecond
        peakReadBytesPerSecond = snapshot.peakReadBytesPerSecond
        peakWriteBytesPerSecond = snapshot.peakWriteBytesPerSecond
        lastEventAt = snapshot.lastEventAt
        elapsed = startedAt.map { now.timeIntervalSince($0) } ?? 0

        if now.timeIntervalSince(lastListUpdate) >= 1 {
            files = snapshot.files
            processes = snapshot.processes
            lastListUpdate = now
        }
        if now.timeIntervalSince(lastChartPoint) >= 1,
           let read = snapshot.currentReadBytesPerSecond,
           let write = snapshot.currentWriteBytesPerSecond {
            ratePoints.append(FileAccessTraceRatePoint(
                timestamp: now,
                readBytesPerSecond: read,
                writeBytesPerSecond: write
            ))
            if ratePoints.count > 900 {
                ratePoints.removeFirst(ratePoints.count - 900)
            }
            lastChartPoint = now
        }
        if snapshot.coverage == .unsupportedFormat {
            let activeSessionID = sessionID
            drainTask?.cancel()
            drainTask = nil
            sessionID = nil
            state = .unsupportedFormat
            if let activeSessionID {
                Task { try? await helper.stopTrace(sessionID: activeSessionID) }
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
        case .operationFailed(let message): .failed(message)
        }
    }

    private func message(for error: Error) -> String {
        switch error as? TraceHelperClientError {
        case .protocolMismatch:
            L10n.text("追踪组件版本不匹配，请重新安装应用")
        case .approvalRequired:
            L10n.text("需要启用文件访问追踪")
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
        requestedReadBytes = nil
        requestedWriteBytes = nil
        currentReadBytesPerSecond = nil
        currentWriteBytesPerSecond = nil
        peakReadBytesPerSecond = nil
        peakWriteBytesPerSecond = nil
        coverage = .complete
        files = []
        processes = []
        ratePoints = []
        startedAt = nil
        elapsed = 0
        lastEventAt = nil
        lastListUpdate = .distantPast
        lastChartPoint = .distantPast
    }

    private func stopDetachedSessionIfNeeded() {
        guard let sessionID else { return }
        self.sessionID = nil
        Task { try? await helper.stopTrace(sessionID: sessionID) }
    }

    private func cancelPendingStart() {
        hasPendingStartIntent = false
        attemptedRegistrationForIntent = false
    }
}
