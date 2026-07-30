import Foundation
import Observation

@MainActor
@Observable
public final class MonitorStore {
    public let diskHealth = DiskHealthStore()
    public private(set) var points: [ThroughputPoint] = []
    public private(set) var systemPoints: [SystemResourcePoint] = []
    public private(set) var disks: [DiskActivity] = []
    public private(set) var volumes: [VolumeInfo] = []
    public private(set) var processes: [ProcessActivity] = []
    public private(set) var health: MonitorHealth = .starting
    public private(set) var isCollecting = false
    public private(set) var startedAt: Date?
    public private(set) var lastUpdatedAt: Date?
    public private(set) var lastError: String?
    public private(set) var visibleProcessCount = 0
    public private(set) var activeApplicationCount = 0
    public private(set) var isDiskAvailable = false
    public private(set) var isSystemCPUAvailable = false
    public private(set) var isSystemNetworkAvailable = false
    public private(set) var isProcessNetworkAvailable = false
    public private(set) var selectedCoverage: Double = 0
    public var selectedRange: SampleRange = .minute {
        didSet {
            guard selectedRange != oldValue else { return }
            scheduleProcessSummaryRebuild(
                at: lastUpdatedAt ?? Date(),
                priority: .userInitiated
            )
        }
    }
    public var isFollowingLive = true
    public static let defaultSamplingInterval: TimeInterval = 3
    public static let samplingIntervalRange: ClosedRange<TimeInterval> = 1...60
    public private(set) var samplingInterval = defaultSamplingInterval

    private static let elevatedDeviceWriteRate = 20_000_000.0
    private static let elevatedProcessWriteRate = 5_000_000.0

    public var currentReadRate: Double {
        recentDiskAverage(\.readBytesPerSecond)
    }
    public var currentWriteRate: Double {
        recentDiskAverage(\.writeBytesPerSecond)
    }
    public var currentCPUPercent: Double {
        recentSystemAverage(\.cpuPercent)
    }
    public var currentNetworkReceiveRate: Double {
        recentSystemAverage(\.networkReceiveBytesPerSecond)
    }
    public var currentNetworkSendRate: Double {
        recentSystemAverage(\.networkSendBytesPerSecond)
    }
    public var topWriter: ProcessActivity? {
        processes
            .filter { !$0.currentUnavailableMetrics.contains(.write) }
            .max { $0.currentWriteBytesPerSecond < $1.currentWriteBytesPerSecond }
    }
    public var topCPUProcess: ProcessActivity? {
        processes
            .filter { !$0.currentUnavailableMetrics.contains(.cpu) }
            .max { $0.currentCPUPercent < $1.currentCPUPercent }
    }
    public var topNetworkProcess: ProcessActivity? {
        processes.filter(\.isNetworkAvailable).max {
            ($0.currentNetworkReceiveBytesPerSecond + $0.currentNetworkSendBytesPerSecond)
                < ($1.currentNetworkReceiveBytesPerSecond + $1.currentNetworkSendBytesPerSecond)
        }
    }

    private func recentDiskAverage(
        _ value: KeyPath<ThroughputPoint, Double?>
    ) -> Double {
        guard let end = points.last?.timestamp else { return 0 }
        return timeWeightedAverage(
            points.compactMap { point in
                point[keyPath: value].map {
                    TimedRate(timestamp: point.timestamp, duration: point.sampleDuration, value: $0)
                }
            },
            endingAt: end
        )
    }

    private func recentSystemAverage(
        _ value: KeyPath<SystemResourcePoint, Double?>
    ) -> Double {
        guard let end = systemPoints.last?.timestamp else { return 0 }
        return timeWeightedAverage(
            systemPoints.compactMap { point in
                point[keyPath: value].map {
                    TimedRate(timestamp: point.timestamp, duration: point.sampleDuration, value: $0)
                }
            },
            endingAt: end
        )
    }

    private struct ProcessKey: Hashable {
        let pid: Int32
        let startAbstime: UInt64
    }

    private struct ProcessTotals {
        let cpuTimeNanoseconds: UInt64?
        let read: UInt64?
        let written: UInt64?
        let networkReceived: UInt64?
        let networkSent: UInt64?
    }

    private struct SystemTotals {
        let cpuUser: UInt64
        let cpuSystem: UInt64
        let cpuNice: UInt64
        let cpuIdle: UInt64
    }

    private struct NetworkInterfaceTotals {
        let received: UInt64
        let sent: UInt64
    }

    private struct DiskTotals {
        let read: UInt64
        let written: UInt64
        let readOperations: UInt64
        let writeOperations: UInt64
    }

    private struct DiskWindowSample {
        let timestamp: Date
        let duration: TimeInterval
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let readOperations: UInt64
        let writeOperations: UInt64
    }

    private struct GroupMetadata: Sendable {
        var name: String
        var path: String
        var appBundlePath: String?
        var bundleIdentifier: String?
        var pids: Set<Int32>
        var sessions: Set<ProcessSession>
        var brand: ProcessBrand?
        var brandIsVerified: Bool
        var lastActivity: Date
    }

    private struct ProcessRateSample: Sendable {
        let timestamp: Date
        let duration: TimeInterval
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let cpuTimeNanoseconds: UInt64
        let networkBytesReceived: UInt64
        let networkBytesSent: UInt64
        let networkAvailable: Bool
        let unavailableMetrics: HistoryApplicationMetricSet
    }

    private struct GroupRates: Sendable {
        var read = 0.0
        var write = 0.0
        var cpu = 0.0
        var networkReceived = 0.0
        var networkSent = 0.0
        var networkAvailable = false
    }

    private var priorProcesses: [ProcessKey: ProcessTotals] = [:]
    private var priorDisks: [UInt64: DiskTotals] = [:]
    private var recentDiskSamples: [UInt64: [DiskWindowSample]] = [:]
    private var priorUptime: TimeInterval?
    private var priorSystemTotals: SystemTotals?
    private var priorNetworkInterfaces: [UInt32: NetworkInterfaceTotals] = [:]
    private var diskSegment = 0
    private var diskWasAvailable = false
    private var cpuSegment = 0
    private var cpuWasAvailable = false
    private var networkSegment = 0
    private var networkWasAvailable = false
    private var groupHistory: [String: [ProcessRateSample]] = [:]
    private var groupMetadata: [String: GroupMetadata] = [:]
    private var elevatedSince: Date?
    private var samplingTask: Task<Void, Never>?
    private var processSummaryTask: Task<Void, Never>?
    private var processSummaryGeneration = 0
    private var lastHistoryTrimAt: Date?
    private var historyRecorder: HistoryRecorder?
    private var historyRecordingTask: Task<Void, Never>?
    private let sampleProvider: @Sendable () async -> SystemSnapshot
    private let historyIdentityProvider: any HistoryIdentityProviding

    public init(historyRecorder: HistoryRecorder? = nil) {
        self.historyRecorder = historyRecorder
        sampleProvider = { await SystemSampler.shared.collect() }
        historyIdentityProvider = HistoryIdentityProvider.shared
    }

    init(
        historyRecorder: HistoryRecorder? = nil,
        sampleProvider: @escaping @Sendable () async -> SystemSnapshot,
        historyIdentityProvider: any HistoryIdentityProviding = HistoryIdentityProvider.shared
    ) {
        self.historyRecorder = historyRecorder
        self.sampleProvider = sampleProvider
        self.historyIdentityProvider = historyIdentityProvider
    }

    public func attachHistoryRecorder(_ recorder: HistoryRecorder) {
        historyRecorder = recorder
    }

    public func start() {
        guard samplingTask == nil else { return }
        isCollecting = true
        health = .starting
        startedAt = startedAt ?? Date()

        startSamplingLoop()
    }

    public func setSamplingInterval(_ interval: TimeInterval) {
        let normalized = Self.normalizedSamplingInterval(interval)
        guard normalized != samplingInterval else { return }
        samplingInterval = normalized
        guard samplingTask != nil else { return }
        samplingTask?.cancel()
        samplingTask = nil
        startSamplingLoop()
    }

    public static func normalizedSamplingInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultSamplingInterval }
        return min(
            samplingIntervalRange.upperBound,
            max(samplingIntervalRange.lowerBound, interval.rounded())
        )
    }

    private func startSamplingLoop() {
        let sampleProvider = self.sampleProvider
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await sampleProvider()
                guard !Task.isCancelled else { return }
                self?.ingest(snapshot)
                let interval = self?.samplingInterval ?? Self.defaultSamplingInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        processSummaryTask?.cancel()
        processSummaryTask = nil
        isCollecting = false
        health = .stopped
        resetCounterBaselines()
        enqueueHistoryFlush()
    }

    public func restart() {
        stop()
        start()
    }

    public func resetCounterBaselines() {
        priorProcesses.removeAll(keepingCapacity: true)
        priorDisks.removeAll(keepingCapacity: true)
        recentDiskSamples.removeAll(keepingCapacity: true)
        priorUptime = nil
        priorSystemTotals = nil
        priorNetworkInterfaces.removeAll(keepingCapacity: true)
        diskWasAvailable = false
        cpuWasAvailable = false
        networkWasAvailable = false
        isDiskAvailable = false
        isSystemCPUAvailable = false
        isSystemNetworkAvailable = false
        isProcessNetworkAvailable = false
    }

    public func flushHistory() async {
        let pending = historyRecordingTask
        await pending?.value
        guard !Task.isCancelled else { return }
        await historyRecorder?.flush()
    }

    public func clearHistory() {
        processSummaryTask?.cancel()
        processSummaryTask = nil
        processSummaryGeneration += 1

        points.removeAll(keepingCapacity: true)
        systemPoints.removeAll(keepingCapacity: true)
        disks.removeAll(keepingCapacity: true)
        recentDiskSamples.removeAll(keepingCapacity: true)
        groupHistory.removeAll(keepingCapacity: true)
        groupMetadata.removeAll(keepingCapacity: true)
        processes.removeAll(keepingCapacity: true)
        selectedCoverage = 0
        visibleProcessCount = 0
        activeApplicationCount = 0
        isDiskAvailable = false
        isSystemCPUAvailable = false
        isSystemNetworkAvailable = false
        isProcessNetworkAvailable = false
        startedAt = isCollecting ? Date() : nil
        lastUpdatedAt = nil
        lastError = nil
        lastHistoryTrimAt = nil
        elevatedSince = nil
        if isCollecting {
            health = .starting
        }
    }

    func ingest(_ snapshot: SystemSnapshot) {
        let hasPriorSample = priorUptime != nil
        let duration = max(0.1, snapshot.uptime - (priorUptime ?? snapshot.uptime))
        priorUptime = snapshot.uptime
        lastUpdatedAt = snapshot.date
        if !snapshot.volumes.isEmpty || volumes.isEmpty {
            volumes = snapshot.volumes
        }
        visibleProcessCount = snapshot.processes.count
        isProcessNetworkAvailable = snapshot.processNetworkAvailable

        let diskHistory = ingestDisks(snapshot.disks, at: snapshot.date, duration: duration)
        let systemHistory = ingestSystem(snapshot, duration: duration)
        let applicationHistory = ingestProcesses(
            snapshot.processes,
            at: snapshot.date,
            duration: duration
        )
        trimHistoryIfNeeded(at: snapshot.date)
        scheduleProcessSummaryRebuild(at: snapshot.date, priority: .utility)
        updateHealth(at: snapshot.date)

        if case .starting = health, points.count >= 2 {
            health = .normal
        }

        if hasPriorSample, let historyRecorder {
            let historySample = HistorySample(
                timestamp: snapshot.date,
                duration: duration,
                diskReadBytes: diskHistory.read,
                diskWriteBytes: diskHistory.write,
                diskStatsAvailable: isDiskAvailable,
                cpuPercent: systemHistory.cpuPercent,
                networkReceiveBytes: systemHistory.networkReceive,
                networkSendBytes: systemHistory.networkSend,
                networkStatsAvailable: isSystemNetworkAvailable,
                applications: applicationHistory,
                devices: diskHistory.devices
            )
            let pending = historyRecordingTask
            historyRecordingTask = Task {
                await pending?.value
                await historyRecorder.record(historySample)
            }
        }
    }

    private func enqueueHistoryFlush() {
        guard let historyRecorder else { return }
        let pending = historyRecordingTask
        historyRecordingTask = Task {
            await pending?.value
            await historyRecorder.flush()
        }
    }

    private func ingestSystem(
        _ snapshot: SystemSnapshot,
        duration: TimeInterval
    ) -> (cpuPercent: Double?, networkReceive: UInt64, networkSend: UInt64) {
        let current = SystemTotals(
            cpuUser: snapshot.cpuUserTicks,
            cpuSystem: snapshot.cpuSystemTicks,
            cpuNice: snapshot.cpuNiceTicks,
            cpuIdle: snapshot.cpuIdleTicks
        )

        var cpuPercent: Double?
        if snapshot.cpuStatsAvailable, let prior = priorSystemTotals {
            let activeTicks = safeDelta(current.cpuUser, prior.cpuUser)
                + safeDelta(current.cpuSystem, prior.cpuSystem)
                + safeDelta(current.cpuNice, prior.cpuNice)
            let idleTicks = safeDelta(current.cpuIdle, prior.cpuIdle)
            let totalTicks = activeTicks + idleTicks
            if totalTicks > 0 {
                cpuPercent = Double(activeTicks) / Double(totalTicks) * 100
            }
        }
        if snapshot.cpuStatsAvailable {
            priorSystemTotals = current
        } else {
            priorSystemTotals = nil
        }
        isSystemCPUAvailable = cpuPercent != nil
        if isSystemCPUAvailable, !cpuWasAvailable {
            cpuSegment += 1
        }
        cpuWasAvailable = isSystemCPUAvailable

        var receiveRate: Double?
        var sendRate: Double?
        var receivedDeltaForHistory: UInt64 = 0
        var sentDeltaForHistory: UInt64 = 0
        if snapshot.networkInterfacesAvailable {
            var receivedDelta: UInt64 = 0
            var sentDelta: UInt64 = 0
            var matchedInterfaceCount = 0
            for interface in snapshot.networkInterfaces {
                guard let previous = priorNetworkInterfaces[interface.index] else { continue }
                matchedInterfaceCount += 1
                receivedDelta += safeDelta(interface.bytesReceived, previous.received)
                sentDelta += safeDelta(interface.bytesSent, previous.sent)
            }
            priorNetworkInterfaces = Dictionary(uniqueKeysWithValues: snapshot.networkInterfaces.map {
                ($0.index, NetworkInterfaceTotals(received: $0.bytesReceived, sent: $0.bytesSent))
            })
            if matchedInterfaceCount > 0 {
                receivedDeltaForHistory = receivedDelta
                sentDeltaForHistory = sentDelta
                receiveRate = Double(receivedDelta) / duration
                sendRate = Double(sentDelta) / duration
            }
        } else {
            priorNetworkInterfaces.removeAll(keepingCapacity: true)
        }
        isSystemNetworkAvailable = receiveRate != nil && sendRate != nil
        if isSystemNetworkAvailable, !networkWasAvailable {
            networkSegment += 1
        }
        networkWasAvailable = isSystemNetworkAvailable

        systemPoints.append(SystemResourcePoint(
            timestamp: snapshot.date,
            sampleDuration: duration,
            cpuPercent: cpuPercent,
            cpuSegment: cpuSegment,
            networkReceiveBytesPerSecond: receiveRate,
            networkSendBytesPerSecond: sendRate,
            networkSegment: networkSegment
        ))
        if systemPoints.count > 3_600 {
            systemPoints.removeFirst(systemPoints.count - 3_600)
        }
        return (cpuPercent, receivedDeltaForHistory, sentDeltaForHistory)
    }

    private func ingestDisks(
        _ counters: [RawDiskCounter],
        at date: Date,
        duration: TimeInterval
    ) -> (read: UInt64, write: UInt64, devices: [HistoryDeviceSample]) {
        var diskRows: [DiskActivity] = []
        var totalReadRate = 0.0
        var totalWriteRate = 0.0
        var hasPhysicalSample = false
        var totalReadBytes: UInt64 = 0
        var totalWriteBytes: UInt64 = 0
        var historyDevices: [HistoryDeviceSample] = []

        for counter in counters {
            let current = DiskTotals(
                read: counter.bytesRead,
                written: counter.bytesWritten,
                readOperations: counter.readOperations,
                writeOperations: counter.writeOperations
            )
            defer { priorDisks[counter.registryID] = current }
            guard let prior = priorDisks[counter.registryID] else { continue }

            let readDelta = safeDelta(counter.bytesRead, prior.read)
            let writeDelta = safeDelta(counter.bytesWritten, prior.written)
            let readOperations = safeDelta(counter.readOperations, prior.readOperations)
            let writeOperations = safeDelta(counter.writeOperations, prior.writeOperations)
            let readRate = Double(readDelta) / duration
            let writeRate = Double(writeDelta) / duration

            var recent = recentDiskSamples[counter.registryID, default: []]
            recent.append(DiskWindowSample(
                timestamp: date,
                duration: duration,
                bytesRead: readDelta,
                bytesWritten: writeDelta,
                readOperations: readOperations,
                writeOperations: writeOperations
            ))
            recent.removeAll { $0.timestamp < date.addingTimeInterval(-5) }
            recentDiskSamples[counter.registryID] = recent

            if counter.isPhysical {
                hasPhysicalSample = true
                totalReadRate += readRate
                totalWriteRate += writeRate
                totalReadBytes = Self.addingClamped(totalReadBytes, readDelta)
                totalWriteBytes = Self.addingClamped(totalWriteBytes, writeDelta)
                historyDevices.append(HistoryDeviceSample(
                    identity: historyIdentityProvider.deviceIdentity(
                        registryID: counter.registryID,
                        bsdName: counter.bsdName
                    ),
                    name: counter.name,
                    readBytes: readDelta,
                    writeBytes: writeDelta
                ))
            }
            diskRows.append(DiskActivity(
                id: counter.registryID,
                name: counter.name,
                readBytesPerSecond: diskWindowAverage(recent, endingAt: date) {
                    Double($0.bytesRead) / max(0.1, $0.duration)
                },
                writeBytesPerSecond: diskWindowAverage(recent, endingAt: date) {
                    Double($0.bytesWritten) / max(0.1, $0.duration)
                },
                readOperationsPerSecond: diskWindowAverage(recent, endingAt: date) {
                    Double($0.readOperations) / max(0.1, $0.duration)
                },
                writeOperationsPerSecond: diskWindowAverage(recent, endingAt: date) {
                    Double($0.writeOperations) / max(0.1, $0.duration)
                },
                capacity: counter.capacity,
                bsdName: counter.bsdName,
                isPhysical: counter.isPhysical
            ))
        }

        disks = diskRows.sorted { $0.writeBytesPerSecond > $1.writeBytesPerSecond }
        isDiskAvailable = hasPhysicalSample
        if isDiskAvailable, !diskWasAvailable {
            diskSegment += 1
        }
        diskWasAvailable = isDiskAvailable
        points.append(ThroughputPoint(
            timestamp: date,
            sampleDuration: duration,
            readBytesPerSecond: hasPhysicalSample ? totalReadRate : nil,
            writeBytesPerSecond: hasPhysicalSample ? totalWriteRate : nil,
            segment: diskSegment
        ))
        if points.count > 3_600 {
            points.removeFirst(points.count - 3_600)
        }
        return (totalReadBytes, totalWriteBytes, historyDevices)
    }

    private func ingestProcesses(
        _ counters: [RawProcessCounter],
        at date: Date,
        duration: TimeInterval
    ) -> [HistoryApplicationSample] {
        var groupedDeltas: [String: (
            read: UInt64,
            written: UInt64,
            cpu: UInt64,
            networkReceived: UInt64,
            networkSent: UInt64,
            networkAvailable: Bool,
            unavailableMetrics: HistoryApplicationMetricSet
        )] = [:]
        var liveKeys: Set<ProcessKey> = []
        var livePIDsByGroup: [String: Set<Int32>] = [:]
        var liveSessionsByGroup: [String: Set<ProcessSession>] = [:]

        for counter in counters {
            let key = ProcessKey(pid: counter.pid, startAbstime: counter.startAbstime)
            liveKeys.insert(key)
            let current = ProcessTotals(
                cpuTimeNanoseconds: Self.validProcessCounter(counter.cpuTimeNanoseconds),
                read: Self.validProcessCounter(counter.bytesRead),
                written: Self.validProcessCounter(counter.bytesWritten),
                networkReceived: counter.networkBytesReceived.flatMap(Self.validProcessCounter),
                networkSent: counter.networkBytesSent.flatMap(Self.validProcessCounter)
            )
            let prior = priorProcesses[key]
            priorProcesses[key] = current

            let classification = ProcessClassifier.classify(
                name: counter.name,
                executablePath: counter.path
            )
            livePIDsByGroup[classification.groupID, default: []].insert(counter.pid)
            liveSessionsByGroup[classification.groupID, default: []].insert(ProcessSession(
                pid: counter.pid,
                startAbstime: counter.startAbstime
            ))
            var metadata = groupMetadata[classification.groupID] ?? GroupMetadata(
                name: classification.displayName,
                path: counter.path,
                appBundlePath: classification.appBundlePath,
                bundleIdentifier: classification.appBundlePath
                    .flatMap { Bundle(path: $0)?.bundleIdentifier },
                pids: [],
                sessions: [],
                brand: classification.brand,
                brandIsVerified: classification.brandIsVerified,
                lastActivity: date
            )
            groupMetadata[classification.groupID] = metadata

            guard let prior else { continue }
            let readDeltaValue = Self.validProcessDelta(current.read, prior.read)
            let writeDeltaValue = Self.validProcessDelta(current.written, prior.written)
            let cpuDeltaValue = Self.validProcessDelta(
                current.cpuTimeNanoseconds,
                prior.cpuTimeNanoseconds
            )
            let readDelta = readDeltaValue ?? 0
            let writeDelta = writeDeltaValue ?? 0
            let cpuDelta = cpuDeltaValue ?? 0
            let receivedDeltaValue = Self.validProcessDelta(
                current.networkReceived, prior.networkReceived
            )
            let sentDeltaValue = Self.validProcessDelta(
                current.networkSent, prior.networkSent
            )
            let networkAvailable = receivedDeltaValue != nil && sentDeltaValue != nil
            let receivedDelta = receivedDeltaValue ?? 0
            let sentDelta = sentDeltaValue ?? 0
            var unavailableMetrics: HistoryApplicationMetricSet = []
            if readDeltaValue == nil { unavailableMetrics.insert(.read) }
            if writeDeltaValue == nil { unavailableMetrics.insert(.write) }
            if cpuDeltaValue == nil { unavailableMetrics.insert(.cpu) }
            if Self.networkCounterHasGap(
                rawCurrent: counter.networkBytesReceived,
                current: current.networkReceived,
                previous: prior.networkReceived,
                delta: receivedDeltaValue
            ) {
                unavailableMetrics.insert(.networkReceive)
            }
            if Self.networkCounterHasGap(
                rawCurrent: counter.networkBytesSent,
                current: current.networkSent,
                previous: prior.networkSent,
                delta: sentDeltaValue
            ) {
                unavailableMetrics.insert(.networkSend)
            }
            let hasActivity = readDelta > 0 || writeDelta > 0 || cpuDelta > 0
                || receivedDelta > 0 || sentDelta > 0
                || !unavailableMetrics.isEmpty
            guard hasActivity || groupHistory[classification.groupID] != nil else { continue }

            var existing = groupedDeltas[classification.groupID]
                ?? (0, 0, 0, 0, 0, false, [])
            existing.unavailableMetrics.formUnion(unavailableMetrics)
            existing.read = Self.addProcessMetric(
                existing.read, readDelta, metric: .read,
                unavailable: &existing.unavailableMetrics
            )
            existing.written = Self.addProcessMetric(
                existing.written, writeDelta, metric: .write,
                unavailable: &existing.unavailableMetrics
            )
            existing.cpu = Self.addProcessMetric(
                existing.cpu, cpuDelta, metric: .cpu,
                unavailable: &existing.unavailableMetrics
            )
            existing.networkReceived = Self.addProcessMetric(
                existing.networkReceived, receivedDelta, metric: .networkReceive,
                unavailable: &existing.unavailableMetrics
            )
            existing.networkSent = Self.addProcessMetric(
                existing.networkSent, sentDelta, metric: .networkSend,
                unavailable: &existing.unavailableMetrics
            )
            existing.networkAvailable = (
                // nettop omits helpers with no network observations. An app-level sample is
                // usable when any grouped member has a valid counter delta; a source-wide
                // failure is still rejected later through processNetworkAvailable.
                existing.networkAvailable || networkAvailable
            )
            groupedDeltas[classification.groupID] = existing
            if hasActivity {
                metadata.lastActivity = date
                groupMetadata[classification.groupID] = metadata
            }
        }

        priorProcesses = priorProcesses.filter { liveKeys.contains($0.key) }
        for groupID in groupMetadata.keys {
            groupMetadata[groupID]?.pids = livePIDsByGroup[groupID] ?? []
            groupMetadata[groupID]?.sessions = liveSessionsByGroup[groupID] ?? []
        }
        activeApplicationCount = livePIDsByGroup.count

        for (groupID, delta) in groupedDeltas {
            groupHistory[groupID, default: []].append(ProcessRateSample(
                timestamp: date,
                duration: duration,
                bytesRead: delta.read,
                bytesWritten: delta.written,
                cpuTimeNanoseconds: delta.cpu,
                networkBytesReceived: delta.networkReceived,
                networkBytesSent: delta.networkSent,
                networkAvailable: delta.networkAvailable
                    && !delta.unavailableMetrics.contains(.networkReceive)
                    && !delta.unavailableMetrics.contains(.networkSend),
                unavailableMetrics: delta.unavailableMetrics
            ))
        }

        return groupedDeltas.compactMap { groupID, delta in
            guard let metadata = groupMetadata[groupID] else { return nil }
            return HistoryApplicationSample(
                identity: historyIdentityProvider.applicationIdentity(
                    bundleIdentifier: metadata.bundleIdentifier,
                    fallbackIdentity: groupID
                ),
                name: metadata.name,
                readBytes: delta.read,
                writeBytes: delta.written,
                cpuTimeNanoseconds: delta.cpu,
                networkReceiveBytes: delta.networkReceived,
                networkSendBytes: delta.networkSent,
                unavailableMetrics: delta.unavailableMetrics
            )
        }
    }

    nonisolated private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    nonisolated private static func validProcessCounter(_ value: UInt64) -> UInt64? {
        value < UInt64(Int64.max) ? value : nil
    }

    nonisolated private static func validProcessDelta(
        _ current: UInt64?,
        _ previous: UInt64?
    ) -> UInt64? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }

    nonisolated private static func networkCounterHasGap(
        rawCurrent: UInt64?,
        current: UInt64?,
        previous: UInt64?,
        delta: UInt64?
    ) -> Bool {
        // nettop legitimately omits members without observations. Only a supplied
        // counter that is invalid or cannot be rebased creates a metric gap.
        guard rawCurrent != nil else { return false }
        return current == nil || previous == nil || delta == nil
    }

    nonisolated private static func addProcessMetric(
        _ total: UInt64,
        _ value: UInt64,
        metric: HistoryApplicationMetricSet,
        unavailable: inout HistoryApplicationMetricSet
    ) -> UInt64 {
        guard !unavailable.contains(metric) else { return 0 }
        let result = total.addingReportingOverflow(value)
        guard !result.overflow, result.partialValue < UInt64(Int64.max) else {
            unavailable.insert(metric)
            return 0
        }
        return result.partialValue
    }

    private func scheduleProcessSummaryRebuild(
        at date: Date,
        priority: TaskPriority
    ) {
        let observedDuration = min(
            selectedRange.seconds,
            max(1, date.timeIntervalSince(startedAt ?? date))
        )
        selectedCoverage = min(1, observedDuration / selectedRange.seconds)

        processSummaryTask?.cancel()
        processSummaryGeneration += 1
        let generation = processSummaryGeneration
        let historySnapshot = groupHistory
        let metadataSnapshot = groupMetadata
        let range = selectedRange
        let processNetworkAvailable = isProcessNetworkAvailable
        let worker = Task.detached(priority: priority) {
            Self.buildProcessSummaries(
                history: historySnapshot,
                metadata: metadataSnapshot,
                at: date,
                range: range,
                observedDuration: observedDuration,
                processNetworkAvailable: processNetworkAvailable
            )
        }

        processSummaryTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled,
                  generation == processSummaryGeneration,
                  let result
            else { return }
            processes = result
            updateHealth(at: date)
        }
    }

    func waitForPendingProcessSummary() async {
        await processSummaryTask?.value
    }

    nonisolated private static func buildProcessSummaries(
        history groupHistory: [String: [ProcessRateSample]],
        metadata groupMetadata: [String: GroupMetadata],
        at date: Date,
        range: SampleRange,
        observedDuration: TimeInterval,
        processNetworkAvailable: Bool
    ) -> [ProcessActivity]? {
        let cutoff = date.addingTimeInterval(-range.seconds)

        var result: [ProcessActivity] = []
        for (groupID, history) in groupHistory {
            guard !Task.isCancelled else { return nil }
            let startIndex = Self.firstSampleIndex(onOrAfter: cutoff, in: history)
            let selected = history[startIndex...]
            guard !selected.isEmpty, let metadata = groupMetadata[groupID] else { continue }

            var totalRead: UInt64 = 0
            var totalWritten: UInt64 = 0
            var totalReceived: UInt64 = 0
            var totalSent: UInt64 = 0
            var networkReceived: UInt64 = 0
            var networkSent: UInt64 = 0
            var networkObservedDuration = 0.0
            var peakWriteRate = 0.0
            var cpuTotal = 0.0
            var peakCPU = 0.0
            var sampleCount = 0
            var metricNetworkSegment = 0
            var metricNetworkWasAvailable = false
            var intervalUnavailableMetrics: HistoryApplicationMetricSet = []
            var metrics: [ProcessMetricPoint] = []
            let metricIndices = Self.downsampledProcessSampleIndices(
                history,
                range: startIndex..<history.endIndex,
                maxCount: 240
            )
            let metricIndexSet = Set(metricIndices)

            for index in startIndex..<history.endIndex {
                let sample = history[index]
                let duration = max(0.1, sample.duration)
                let readAvailable = !sample.unavailableMetrics.contains(.read)
                let writeAvailable = !sample.unavailableMetrics.contains(.write)
                let cpuAvailable = !sample.unavailableMetrics.contains(.cpu)
                let writeRate = writeAvailable
                    ? Double(sample.bytesWritten) / duration
                    : nil
                let cpu = cpuAvailable
                    ? Double(sample.cpuTimeNanoseconds) / duration / 1_000_000_000 * 100
                    : nil
                intervalUnavailableMetrics.formUnion(sample.unavailableMetrics)
                if readAvailable { totalRead = Self.addingClamped(totalRead, sample.bytesRead) }
                if writeAvailable {
                    totalWritten = Self.addingClamped(totalWritten, sample.bytesWritten)
                    peakWriteRate = max(peakWriteRate, writeRate ?? 0)
                }
                if let cpu {
                    cpuTotal += cpu
                    peakCPU = max(peakCPU, cpu)
                    sampleCount += 1
                }
                if !sample.unavailableMetrics.contains(.networkReceive) {
                    totalReceived = Self.addingClamped(
                        totalReceived, sample.networkBytesReceived
                    )
                }
                if !sample.unavailableMetrics.contains(.networkSend) {
                    totalSent = Self.addingClamped(totalSent, sample.networkBytesSent)
                }
                if sample.networkAvailable {
                    networkReceived += sample.networkBytesReceived
                    networkSent += sample.networkBytesSent
                    networkObservedDuration += sample.duration
                    if !metricNetworkWasAvailable { metricNetworkSegment += 1 }
                }
                metricNetworkWasAvailable = sample.networkAvailable

                if metricIndexSet.contains(index) {
                    metrics.append(ProcessMetricPoint(
                        timestamp: sample.timestamp,
                        readBytesPerSecond: readAvailable
                            ? Double(sample.bytesRead) / duration
                            : nil,
                        writeBytesPerSecond: writeRate,
                        cpuPercent: cpu,
                        networkReceiveBytesPerSecond: sample.networkAvailable
                            ? Double(sample.networkBytesReceived) / duration
                            : nil,
                        networkSendBytesPerSecond: sample.networkAvailable
                            ? Double(sample.networkBytesSent) / duration
                            : nil,
                        networkSegment: metricNetworkSegment
                    ))
                }
            }

            let currentRate = GroupRates(
                read: processWindowAverage(history, endingAt: date) {
                    Double($0.bytesRead) / max(0.1, $0.duration)
                } where: { !$0.unavailableMetrics.contains(.read) },
                write: processWindowAverage(history, endingAt: date) {
                    Double($0.bytesWritten) / max(0.1, $0.duration)
                } where: { !$0.unavailableMetrics.contains(.write) },
                cpu: processWindowAverage(history, endingAt: date) {
                    Double($0.cpuTimeNanoseconds)
                        / max(0.1, $0.duration) / 1_000_000_000 * 100
                } where: { !$0.unavailableMetrics.contains(.cpu) },
                networkReceived: processWindowAverage(
                    history,
                    endingAt: date,
                    where: \.networkAvailable
                ) {
                    Double($0.networkBytesReceived) / max(0.1, $0.duration)
                },
                networkSent: processWindowAverage(
                    history,
                    endingAt: date,
                    where: \.networkAvailable
                ) {
                    Double($0.networkBytesSent) / max(0.1, $0.duration)
                },
                networkAvailable: history.last?.networkAvailable == true
                    && processNetworkAvailable
            )
            result.append(ProcessActivity(
                id: groupID,
                name: metadata.name,
                executablePath: metadata.path,
                appBundlePath: metadata.appBundlePath,
                pids: metadata.pids.sorted(),
                sessions: metadata.sessions.sorted { lhs, rhs in
                    lhs.pid == rhs.pid
                        ? lhs.startAbstime < rhs.startAbstime
                        : lhs.pid < rhs.pid
                },
                memberCount: metadata.pids.count,
                currentReadBytesPerSecond: currentRate.read,
                currentWriteBytesPerSecond: currentRate.write,
                currentCPUPercent: currentRate.cpu,
                currentNetworkReceiveBytesPerSecond: currentRate.networkReceived,
                currentNetworkSendBytesPerSecond: currentRate.networkSent,
                totalReadBytes: totalRead,
                totalWriteBytes: totalWritten,
                totalNetworkReceivedBytes: totalReceived,
                totalNetworkSentBytes: totalSent,
                averageWriteBytesPerSecond: Double(totalWritten) / observedDuration,
                peakWriteBytesPerSecond: peakWriteRate,
                averageCPUPercent: sampleCount > 0 ? cpuTotal / Double(sampleCount) : 0,
                peakCPUPercent: peakCPU,
                averageNetworkReceiveBytesPerSecond: networkObservedDuration > 0
                    ? Double(networkReceived) / networkObservedDuration
                    : 0,
                averageNetworkSendBytesPerSecond: networkObservedDuration > 0
                    ? Double(networkSent) / networkObservedDuration
                    : 0,
                isNetworkAvailable: networkObservedDuration > 0 && currentRate.networkAvailable,
                currentUnavailableMetrics: history.last?.unavailableMetrics ?? [],
                intervalUnavailableMetrics: intervalUnavailableMetrics,
                metrics: metrics,
                brand: metadata.brand,
                brandIsVerified: metadata.brandIsVerified,
                lastActivity: metadata.lastActivity
            ))
        }

        return result
            .sorted {
                activityScore($0) > activityScore($1)
            }
            .prefix(200)
            .map { $0 }
    }

    private func trimHistoryIfNeeded(at date: Date) {
        guard lastHistoryTrimAt.map({ date.timeIntervalSince($0) >= 60 }) ?? true else {
            return
        }
        lastHistoryTrimAt = date
        let cutoff = date.addingTimeInterval(-3_600)
        for groupID in groupHistory.keys {
            guard var history = groupHistory[groupID] else { continue }
            let firstValid = Self.firstSampleIndex(onOrAfter: cutoff, in: history)
            if firstValid == history.endIndex {
                groupHistory.removeValue(forKey: groupID)
                groupMetadata.removeValue(forKey: groupID)
            } else if firstValid > history.startIndex {
                history.removeFirst(firstValid)
                groupHistory[groupID] = history
            }
        }
    }

    private func diskWindowAverage(
        _ samples: [DiskWindowSample],
        endingAt end: Date,
        value: (DiskWindowSample) -> Double
    ) -> Double {
        timeWeightedAverage(
            samples.map {
                TimedRate(timestamp: $0.timestamp, duration: $0.duration, value: value($0))
            },
            endingAt: end
        )
    }

    nonisolated private static func processWindowAverage(
        _ samples: [ProcessRateSample],
        endingAt end: Date,
        where include: KeyPath<ProcessRateSample, Bool>? = nil,
        value: (ProcessRateSample) -> Double
    ) -> Double {
        let windowStart = end.addingTimeInterval(-5)
        var weightedTotal = 0.0
        var observedDuration = 0.0
        for sample in samples.reversed() {
            let sampleEnd = min(sample.timestamp, end)
            let sampleStart = sample.timestamp.addingTimeInterval(-max(0, sample.duration))
            if sampleEnd <= windowStart { break }
            guard include.map({ sample[keyPath: $0] }) ?? true else { continue }
            let overlap = sampleEnd.timeIntervalSince(max(sampleStart, windowStart))
            guard overlap > 0 else { continue }
            weightedTotal += value(sample) * overlap
            observedDuration += overlap
        }
        return observedDuration > 0 ? weightedTotal / observedDuration : 0
    }

    nonisolated private static func processWindowAverage(
        _ samples: [ProcessRateSample],
        endingAt end: Date,
        value: (ProcessRateSample) -> Double,
        where include: (ProcessRateSample) -> Bool
    ) -> Double {
        let windowStart = end.addingTimeInterval(-5)
        var weightedTotal = 0.0
        var observedDuration = 0.0
        for sample in samples.reversed() {
            let sampleEnd = min(sample.timestamp, end)
            let sampleStart = sample.timestamp.addingTimeInterval(-max(0, sample.duration))
            if sampleEnd <= windowStart { break }
            guard include(sample) else { continue }
            let overlap = sampleEnd.timeIntervalSince(max(sampleStart, windowStart))
            guard overlap > 0 else { continue }
            weightedTotal += value(sample) * overlap
            observedDuration += overlap
        }
        return observedDuration > 0 ? weightedTotal / observedDuration : 0
    }

    private func updateHealth(at date: Date) {
        guard isCollecting else {
            health = .stopped
            return
        }

        let elevated = (isDiskAvailable && currentWriteRate >= Self.elevatedDeviceWriteRate)
            || processes.contains {
                !$0.currentUnavailableMetrics.contains(.write)
                    && $0.currentWriteBytesPerSecond >= Self.elevatedProcessWriteRate
            }
        if elevated {
            elevatedSince = elevatedSince ?? date
            health = .elevated(duration: date.timeIntervalSince(elevatedSince ?? date))
        } else {
            elevatedSince = nil
            health = points.count < 2 ? .starting : .normal
        }
    }

    nonisolated private static func firstSampleIndex(
        onOrAfter cutoff: Date,
        in samples: [ProcessRateSample]
    ) -> Int {
        var lower = samples.startIndex
        var upper = samples.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].timestamp < cutoff {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    nonisolated private static func downsampledProcessSampleIndices(
        _ samples: [ProcessRateSample],
        range: Range<Int>,
        maxCount: Int
    ) -> [Int] {
        guard range.count > maxCount, maxCount >= 12 else {
            return Array(range)
        }

        let dimensions = 5
        let bucketCount = max(1, (maxCount - 2) / (dimensions * 2))
        let interiorStart = range.lowerBound + 1
        let interiorEnd = range.upperBound - 1
        let interiorCount = max(0, interiorEnd - interiorStart)
        let bucketSize = max(1, Int(ceil(Double(interiorCount) / Double(bucketCount))))
        var selected: Set<Int> = [range.lowerBound, range.upperBound - 1]

        var previousNetworkAvailability = samples[range.lowerBound].networkAvailable
        for index in (range.lowerBound + 1)..<range.upperBound {
            let available = samples[index].networkAvailable
            if available != previousNetworkAvailability {
                selected.insert(index - 1)
                selected.insert(index)
            }
            previousNetworkAvailability = available
        }

        var bucketStart = interiorStart
        while bucketStart < interiorEnd {
            let bucketEnd = min(interiorEnd, bucketStart + bucketSize)
            var minima = Array(repeating: (value: Double.infinity, index: bucketStart), count: dimensions)
            var maxima = Array(repeating: (value: -Double.infinity, index: bucketStart), count: dimensions)

            for index in bucketStart..<bucketEnd {
                let sample = samples[index]
                let duration = max(0.1, sample.duration)
                let values: [Double?] = [
                    sample.unavailableMetrics.contains(.read)
                        ? nil : Double(sample.bytesRead) / duration,
                    sample.unavailableMetrics.contains(.write)
                        ? nil : Double(sample.bytesWritten) / duration,
                    sample.unavailableMetrics.contains(.cpu)
                        ? nil : Double(sample.cpuTimeNanoseconds) / duration / 1_000_000_000 * 100,
                    sample.networkAvailable ? Double(sample.networkBytesReceived) / duration : nil,
                    sample.networkAvailable ? Double(sample.networkBytesSent) / duration : nil
                ]
                for dimension in values.indices {
                    guard let value = values[dimension] else { continue }
                    if value < minima[dimension].value { minima[dimension] = (value, index) }
                    if value > maxima[dimension].value { maxima[dimension] = (value, index) }
                }
            }

            for dimension in 0..<dimensions where minima[dimension].value.isFinite {
                selected.insert(minima[dimension].index)
                selected.insert(maxima[dimension].index)
            }
            bucketStart = bucketEnd
        }
        return selected.sorted()
    }
}

private func safeDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
    current >= previous ? current - previous : 0
}

func optionalCounterDelta(_ current: UInt64?, _ previous: UInt64?) -> UInt64? {
    guard let current, let previous else { return nil }
    return safeDelta(current, previous)
}

private func activityScore(_ process: ProcessActivity) -> Double {
    let disk = process.currentUnavailableMetrics.contains(.write)
        ? 0 : process.currentWriteBytesPerSecond / 5_000_000
    let cpu = process.currentUnavailableMetrics.contains(.cpu)
        ? 0 : process.currentCPUPercent / 25
    let network = process.isNetworkAvailable
        ? (process.currentNetworkReceiveBytesPerSecond
            + process.currentNetworkSendBytesPerSecond) / 5_000_000
        : 0
    return max(disk, cpu, network)
}

struct TimedRate: Sendable {
    let timestamp: Date
    let duration: TimeInterval
    let value: Double
}

func timeWeightedAverage(
    _ samples: [TimedRate],
    endingAt end: Date,
    window: TimeInterval = 5
) -> Double {
    let windowStart = end.addingTimeInterval(-window)
    var weightedTotal = 0.0
    var observedDuration = 0.0

    for sample in samples {
        let sampleEnd = min(sample.timestamp, end)
        let sampleStart = sample.timestamp.addingTimeInterval(-max(0, sample.duration))
        let overlapStart = max(sampleStart, windowStart)
        let overlap = sampleEnd.timeIntervalSince(overlapStart)
        guard overlap > 0 else { continue }
        weightedTotal += sample.value * overlap
        observedDuration += overlap
    }
    return observedDuration > 0 ? weightedTotal / observedDuration : 0
}
