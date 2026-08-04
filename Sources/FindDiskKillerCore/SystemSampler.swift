import CFindDiskKiller
import Foundation

public struct RawProcessCounter: Sendable {
    public let pid: Int32
    public let startAbstime: UInt64
    public let name: String
    public let path: String
    public let cpuTimeNanoseconds: UInt64
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    public let networkBytesReceived: UInt64?
    public let networkBytesSent: UInt64?
    public let residentMemoryBytes: UInt64

    public init(
        pid: Int32,
        startAbstime: UInt64,
        name: String,
        path: String,
        cpuTimeNanoseconds: UInt64,
        bytesRead: UInt64,
        bytesWritten: UInt64,
        networkBytesReceived: UInt64?,
        networkBytesSent: UInt64?,
        residentMemoryBytes: UInt64 = 0
    ) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.name = name
        self.path = path
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.networkBytesReceived = networkBytesReceived
        self.networkBytesSent = networkBytesSent
        self.residentMemoryBytes = residentMemoryBytes
    }
}

public struct SystemMemorySnapshot: Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let cachedBytes: UInt64
    public let compressedBytes: UInt64
    public let availableBytes: UInt64

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        cachedBytes: UInt64,
        compressedBytes: UInt64,
        availableBytes: UInt64
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.cachedBytes = cachedBytes
        self.compressedBytes = compressedBytes
        self.availableBytes = availableBytes
    }
}

public struct RawDiskCounter: Sendable {
    public let registryID: UInt64
    public let name: String
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    public let readOperations: UInt64
    public let writeOperations: UInt64
    public let capacity: UInt64
    public let bsdName: String
    public let isPhysical: Bool
}

public struct RawNetworkInterfaceCounter: Sendable {
    public let index: UInt32
    public let name: String
    public let bytesReceived: UInt64
    public let bytesSent: UInt64
}

public struct RawCPUCoreCounter: Sendable {
    public let index: UInt32
    public let userTicks: UInt64
    public let systemTicks: UInt64
    public let niceTicks: UInt64
    public let idleTicks: UInt64

    public init(
        index: UInt32,
        userTicks: UInt64,
        systemTicks: UInt64,
        niceTicks: UInt64,
        idleTicks: UInt64
    ) {
        self.index = index
        self.userTicks = userTicks
        self.systemTicks = systemTicks
        self.niceTicks = niceTicks
        self.idleTicks = idleTicks
    }
}

public struct SystemSnapshot: Sendable {
    public let date: Date
    public let uptime: TimeInterval
    public let processes: [RawProcessCounter]
    public let disks: [RawDiskCounter]
    public let volumes: [VolumeInfo]
    public let cpuUserTicks: UInt64
    public let cpuSystemTicks: UInt64
    public let cpuNiceTicks: UInt64
    public let cpuIdleTicks: UInt64
    public let cpuCores: [RawCPUCoreCounter]
    public let networkInterfaces: [RawNetworkInterfaceCounter]
    public let cpuStatsAvailable: Bool
    public let networkInterfacesAvailable: Bool
    public let processNetworkAvailable: Bool
    public let memory: SystemMemorySnapshot?

    public init(
        date: Date,
        uptime: TimeInterval,
        processes: [RawProcessCounter],
        disks: [RawDiskCounter],
        volumes: [VolumeInfo],
        cpuUserTicks: UInt64,
        cpuSystemTicks: UInt64,
        cpuNiceTicks: UInt64,
        cpuIdleTicks: UInt64,
        cpuCores: [RawCPUCoreCounter] = [],
        networkInterfaces: [RawNetworkInterfaceCounter],
        cpuStatsAvailable: Bool,
        networkInterfacesAvailable: Bool,
        processNetworkAvailable: Bool,
        memory: SystemMemorySnapshot? = nil
    ) {
        self.date = date
        self.uptime = uptime
        self.processes = processes
        self.disks = disks
        self.volumes = volumes
        self.cpuUserTicks = cpuUserTicks
        self.cpuSystemTicks = cpuSystemTicks
        self.cpuNiceTicks = cpuNiceTicks
        self.cpuIdleTicks = cpuIdleTicks
        self.cpuCores = cpuCores
        self.networkInterfaces = networkInterfaces
        self.cpuStatsAvailable = cpuStatsAvailable
        self.networkInterfacesAvailable = networkInterfacesAvailable
        self.processNetworkAvailable = processNetworkAvailable
        self.memory = memory
    }
}

struct ProcessNetworkCounter: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
}

struct ProcessNetworkSample: Sendable {
    enum Kind: Sendable {
        case cumulative
        case interval(duration: TimeInterval)
    }

    let totals: [Int32: ProcessNetworkCounter]?
    let isAvailable: Bool
    let kind: Kind

    static let unavailable = Self(totals: nil, isAvailable: false, kind: .cumulative)

    static func available(_ totals: [Int32: ProcessNetworkCounter]) -> Self {
        Self(totals: totals, isAvailable: true, kind: .cumulative)
    }

    static func interval(
        _ totals: [Int32: ProcessNetworkCounter],
        duration: TimeInterval
    ) -> Self {
        Self(totals: totals, isAvailable: true, kind: .interval(duration: duration))
    }
}

private struct ProcessNetworkIdentity: Hashable, Sendable {
    let pid: Int32
    let startAbstime: UInt64
}

private struct ProcessDescriptor: Sendable {
    let name: String
    let path: String
}

private struct ProcessNetworkObservation: Sendable {
    let sampledAt: TimeInterval
    let totals: [ProcessNetworkIdentity: ProcessNetworkCounter]
    let kind: ProcessNetworkSample.Kind
}

private struct PendingProcessNetworkDelta: Sendable {
    var received: UInt64
    var sent: UInt64
    var duration: TimeInterval
}

private struct PublishedProcessNetworkCounter: Sendable {
    var received: UInt64
    var sent: UInt64
    var pending: [PendingProcessNetworkDelta] = []
    var lastAdvancedAt: TimeInterval
    var isReady = false

    mutating func advance(to uptime: TimeInterval) -> Bool {
        let previousReceived = received
        let previousSent = sent
        var elapsed = max(0, uptime - lastAdvancedAt)
        lastAdvancedAt = uptime
        while elapsed > 0, !pending.isEmpty {
            let step = min(elapsed, pending[0].duration)
            let completesDelta = step >= pending[0].duration
            let receivedStep = completesDelta
                ? pending[0].received
                : UInt64(Double(pending[0].received) * step / pending[0].duration)
            let sentStep = completesDelta
                ? pending[0].sent
                : UInt64(Double(pending[0].sent) * step / pending[0].duration)
            received = Self.addingClamped(received, receivedStep)
            sent = Self.addingClamped(sent, sentStep)
            pending[0].received -= receivedStep
            pending[0].sent -= sentStep
            pending[0].duration -= step
            elapsed -= step
            if completesDelta {
                pending.removeFirst()
            }
        }
        return received != previousReceived || sent != previousSent
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

private struct CompletedProcessNetworkRefresh: Sendable {
    let sample: ProcessNetworkSample
    let sampledAt: TimeInterval
    let identitiesByPID: [Int32: ProcessNetworkIdentity]
}

private struct CurrentProcessNetworkState: Sendable {
    let sample: ProcessNetworkSample
    let retiredProcesses: [RawProcessCounter]
}

public actor SystemSampler {
    public static let shared = SystemSampler()
    private static let minimumProcessNetworkRefreshInterval: TimeInterval = 10
    private var cachedVolumes: [VolumeInfo] = []
    private var lastVolumeRefreshUptime: TimeInterval = -.infinity
    private var volumeRefreshTask: Task<Void, Never>?
    private let diskutilRunner = DiskutilCommandRunner()
    private let processNetworkRefreshInterval: TimeInterval
    private let uptimeProvider: @Sendable () -> TimeInterval
    private let processNetworkSampleProvider: @Sendable () -> ProcessNetworkSample
    private let processCounterProvider: @Sendable () -> [RawProcessCounter]
    private var lastProcessNetworkRefreshUptime: TimeInterval = -.infinity
    private var processNetworkRefreshTask: Task<ProcessNetworkSample, Never>?
    private var processNetworkRefreshGeneration = 0
    private var processNetworkRefreshStartedAt: TimeInterval = 0
    private var processNetworkRefreshIdentities: [Int32: ProcessNetworkIdentity] = [:]
    private var completedProcessNetworkRefresh: CompletedProcessNetworkRefresh?
    private var previousProcessNetworkObservation: ProcessNetworkObservation?
    private var publishedProcessNetworkCounters: [ProcessNetworkIdentity: PublishedProcessNetworkCounter] = [:]
    private var cachedProcessCounters: [ProcessNetworkIdentity: RawProcessCounter] = [:]
    private var processDescriptors: [ProcessNetworkIdentity: ProcessDescriptor] = [:]
    private var isProcessNetworkSourceAvailable = false

    public init() {
        processNetworkRefreshInterval = Self.minimumProcessNetworkRefreshInterval
        uptimeProvider = { ProcessInfo.processInfo.systemUptime }
        processNetworkSampleProvider = { Self.collectProcessNetworkTotals() }
        processCounterProvider = { Self.collectProcesses() }
    }

    init(
        processNetworkRefreshInterval: TimeInterval,
        uptimeProvider: @escaping @Sendable () -> TimeInterval,
        processNetworkSampleProvider: @escaping @Sendable () -> ProcessNetworkSample
    ) {
        self.init(
            processNetworkRefreshInterval: processNetworkRefreshInterval,
            uptimeProvider: uptimeProvider,
            processNetworkSampleProvider: processNetworkSampleProvider,
            processCounterProvider: { Self.collectProcesses() }
        )
    }

    init(
        processNetworkRefreshInterval: TimeInterval,
        uptimeProvider: @escaping @Sendable () -> TimeInterval,
        processNetworkSampleProvider: @escaping @Sendable () -> ProcessNetworkSample,
        processCounterProvider: @escaping @Sendable () -> [RawProcessCounter]
    ) {
        self.processNetworkRefreshInterval = processNetworkRefreshInterval.isFinite
            ? max(Self.minimumProcessNetworkRefreshInterval, processNetworkRefreshInterval)
            : Self.minimumProcessNetworkRefreshInterval
        self.uptimeProvider = uptimeProvider
        self.processNetworkSampleProvider = processNetworkSampleProvider
        self.processCounterProvider = processCounterProvider
        cachedVolumes = Self.collectMountedVolumes().map(\.info)
        lastVolumeRefreshUptime = uptimeProvider()
    }

    public func collect() -> SystemSnapshot {
        let uptime = uptimeProvider()
        if cachedVolumes.isEmpty {
            cachedVolumes = Self.collectMountedVolumes().map(\.info)
        }
        if volumeRefreshTask == nil,
           uptime - lastVolumeRefreshUptime >= 30 || cachedVolumes.isEmpty {
            lastVolumeRefreshUptime = uptime
            let runner = diskutilRunner
            volumeRefreshTask = Task {
                let volumes = await Self.collectVolumes(using: runner)
                finishVolumeRefresh(volumes)
            }
        }
        let processes = resolveProcessDescriptors(processCounterProvider())
        let processNetwork = currentProcessNetworkState(at: uptime, processes: processes)
        let stats = collectSystemStats()
        let interfaces = collectNetworkInterfaces()
        return SystemSnapshot(
            date: Date(),
            uptime: uptime,
            processes: attachProcessNetwork(processNetwork, to: processes),
            disks: collectDisks(),
            volumes: cachedVolumes,
            cpuUserTicks: stats.cpuUserTicks,
            cpuSystemTicks: stats.cpuSystemTicks,
            cpuNiceTicks: stats.cpuNiceTicks,
            cpuIdleTicks: stats.cpuIdleTicks,
            cpuCores: collectCPUCoreStats(),
            networkInterfaces: interfaces.counters,
            cpuStatsAvailable: stats.isAvailable,
            networkInterfacesAvailable: interfaces.isAvailable,
            processNetworkAvailable: processNetwork.sample.isAvailable,
            memory: stats.memory
        )
    }

    nonisolated private static func collectProcesses() -> [RawProcessCounter] {
        let capacity = 8_192
        var buffer = Array(repeating: DMProcessIO(), count: capacity)
        let count = Int(dm_collect_process_io(&buffer, Int32(capacity)))

        return buffer.prefix(max(0, count)).map { raw in
            var sample = raw
            return RawProcessCounter(
                pid: sample.pid,
                startAbstime: sample.start_abstime,
                name: decodeCString(&sample.name),
                path: "",
                cpuTimeNanoseconds: sample.cpu_time_ns,
                bytesRead: sample.bytes_read,
                bytesWritten: sample.bytes_written,
                networkBytesReceived: nil,
                networkBytesSent: nil,
                residentMemoryBytes: sample.resident_memory_bytes
            )
        }
    }

    private func resolveProcessDescriptors(
        _ counters: [RawProcessCounter]
    ) -> [RawProcessCounter] {
        var liveIdentities: Set<ProcessNetworkIdentity> = []
        let resolved = counters.map { counter in
            let identity = ProcessNetworkIdentity(
                pid: counter.pid,
                startAbstime: counter.startAbstime
            )
            liveIdentities.insert(identity)
            let descriptor: ProcessDescriptor
            if !counter.path.isEmpty {
                descriptor = ProcessDescriptor(name: counter.name, path: counter.path)
                processDescriptors[identity] = descriptor
            } else if let cached = processDescriptors[identity] {
                descriptor = cached
            } else {
                let path = Self.collectProcessPath(counter.pid)
                let name = counter.name.isEmpty
                    ? Self.processFallbackName(path: path, pid: counter.pid)
                    : counter.name
                descriptor = ProcessDescriptor(name: name, path: path)
                processDescriptors[identity] = descriptor
            }
            return RawProcessCounter(
                pid: counter.pid,
                startAbstime: counter.startAbstime,
                name: descriptor.name,
                path: descriptor.path,
                cpuTimeNanoseconds: counter.cpuTimeNanoseconds,
                bytesRead: counter.bytesRead,
                bytesWritten: counter.bytesWritten,
                networkBytesReceived: counter.networkBytesReceived,
                networkBytesSent: counter.networkBytesSent,
                residentMemoryBytes: counter.residentMemoryBytes
            )
        }
        processDescriptors = processDescriptors.filter { liveIdentities.contains($0.key) }
        return resolved
    }

    nonisolated private static func collectProcessPath(_ pid: Int32) -> String {
        var buffer = Array(repeating: CChar(0), count: Int(DM_PROCESS_PATH_MAX))
        let count = buffer.withUnsafeMutableBufferPointer {
            dm_collect_process_path(pid, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private static func processFallbackName(path: String, pid: Int32) -> String {
        guard !path.isEmpty else { return "PID \(pid)" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func attachProcessNetwork(
        _ state: CurrentProcessNetworkState,
        to processes: [RawProcessCounter]
    ) -> [RawProcessCounter] {
        let current = processes.map { process in
            RawProcessCounter(
                pid: process.pid,
                startAbstime: process.startAbstime,
                name: process.name,
                path: process.path,
                cpuTimeNanoseconds: process.cpuTimeNanoseconds,
                bytesRead: process.bytesRead,
                bytesWritten: process.bytesWritten,
                networkBytesReceived: state.sample.totals?[process.pid]?.received,
                networkBytesSent: state.sample.totals?[process.pid]?.sent,
                residentMemoryBytes: process.residentMemoryBytes
            )
        }
        return current + state.retiredProcesses
    }

    private func collectSystemStats() -> (
        cpuUserTicks: UInt64,
        cpuSystemTicks: UInt64,
        cpuNiceTicks: UInt64,
        cpuIdleTicks: UInt64,
        memory: SystemMemorySnapshot?,
        isAvailable: Bool
    ) {
        var stats = DMSystemStats()
        let isAvailable = dm_collect_system_stats(&stats) != 0
        return (
            stats.cpu_user_ticks,
            stats.cpu_system_ticks,
            stats.cpu_nice_ticks,
            stats.cpu_idle_ticks,
            stats.memory_stats_available != 0
                ? SystemMemorySnapshot(
                    totalBytes: stats.memory_total_bytes,
                    usedBytes: stats.memory_used_bytes,
                    cachedBytes: stats.memory_cached_bytes,
                    compressedBytes: stats.memory_compressed_bytes,
                    availableBytes: stats.memory_available_bytes
                )
                : nil,
            isAvailable
        )
    }

    private func collectNetworkInterfaces() -> (
        counters: [RawNetworkInterfaceCounter],
        isAvailable: Bool
    ) {
        let capacity = 128
        var buffer = Array(repeating: DMNetworkInterface(), count: capacity)
        let count = Int(dm_collect_network_interfaces(&buffer, Int32(capacity)))
        guard count >= 0 else { return ([], false) }
        let counters = buffer.prefix(count).map { raw in
            var sample = raw
            return RawNetworkInterfaceCounter(
                index: sample.interface_index,
                name: decodeCString(&sample.name),
                bytesReceived: sample.bytes_in,
                bytesSent: sample.bytes_out
            )
        }
        return (counters, true)
    }

    private func collectCPUCoreStats() -> [RawCPUCoreCounter] {
        let capacity = 256
        var buffer = Array(repeating: DMCPUCoreStats(), count: capacity)
        let count = Int(dm_collect_cpu_core_stats(&buffer, Int32(capacity)))
        guard count > 0 else { return [] }
        return buffer.prefix(count).map { core in
            RawCPUCoreCounter(
                index: core.index,
                userTicks: core.user_ticks,
                systemTicks: core.system_ticks,
                niceTicks: core.nice_ticks,
                idleTicks: core.idle_ticks
            )
        }
    }

    nonisolated private static func collectProcessNetworkTotals() -> ProcessNetworkSample {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e", "alarm 3; exec @ARGV",
            "/usr/bin/nettop", "-P", "-L", "1",
            "-n", "-x", "-t", "external", "-J", "bytes_in,bytes_out"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let totals = ProcessNetworkParser.parse(text, minimumSampleCount: 1)
        else { return .unavailable }
        return .available(totals)
    }

    private func currentProcessNetworkState(
        at uptime: TimeInterval,
        processes: [RawProcessCounter]
    ) -> CurrentProcessNetworkState {
        let identitiesByPID = Dictionary(uniqueKeysWithValues: processes.map {
            ($0.pid, ProcessNetworkIdentity(pid: $0.pid, startAbstime: $0.startAbstime))
        })
        for process in processes {
            let identity = ProcessNetworkIdentity(pid: process.pid, startAbstime: process.startAbstime)
            cachedProcessCounters[identity] = process
        }

        var advancedIdentities: Set<ProcessNetworkIdentity> = []
        for identity in Array(publishedProcessNetworkCounters.keys) {
            if publishedProcessNetworkCounters[identity]?.advance(to: uptime) == true {
                advancedIdentities.insert(identity)
            }
        }
        if let completedProcessNetworkRefresh {
            // Resolve ownership against the next normal process scan instead of
            // running another full scan when nettop exits. A disappeared PID is
            // still safe to retain as a retired session; only a reused PID is
            // ambiguous and must be discarded.
            let resolvedIdentities = completedProcessNetworkRefresh.identitiesByPID.filter {
                pid, identity in
                guard let current = identitiesByPID[pid] else { return true }
                return current == identity
            }
            applyProcessNetworkRefresh(
                CompletedProcessNetworkRefresh(
                    sample: completedProcessNetworkRefresh.sample,
                    sampledAt: completedProcessNetworkRefresh.sampledAt,
                    identitiesByPID: resolvedIdentities
                ),
                at: uptime
            )
            self.completedProcessNetworkRefresh = nil
        }

        let elapsed = uptime - lastProcessNetworkRefreshUptime
        if processNetworkRefreshTask == nil,
           !lastProcessNetworkRefreshUptime.isFinite || elapsed >= processNetworkRefreshInterval {
            scheduleProcessNetworkRefresh(at: uptime, identitiesByPID: identitiesByPID)
        }

        let latestObservedIdentities = Set(
            previousProcessNetworkObservation?.totals.keys.map { $0 } ?? []
        )
        var totals: [Int32: ProcessNetworkCounter] = [:]
        for (identity, counter) in publishedProcessNetworkCounters
            where counter.isReady
                && identitiesByPID[identity.pid] == identity
                && (latestObservedIdentities.contains(identity)
                    || !counter.pending.isEmpty
                    || advancedIdentities.contains(identity)) {
            totals[identity.pid] = ProcessNetworkCounter(
                received: counter.received,
                sent: counter.sent
            )
        }
        let sample: ProcessNetworkSample = isProcessNetworkSourceAvailable
            ? .available(totals)
            : .unavailable
        let currentIdentities = Set(identitiesByPID.values)
        let retiredProcesses: [RawProcessCounter] = publishedProcessNetworkCounters.compactMap {
            identity, counter in
            guard !currentIdentities.contains(identity),
                  counter.isReady,
                  !counter.pending.isEmpty || advancedIdentities.contains(identity),
                  let process = cachedProcessCounters[identity]
            else { return nil }
            return RawProcessCounter(
                pid: process.pid,
                startAbstime: process.startAbstime,
                name: process.name,
                path: process.path,
                cpuTimeNanoseconds: process.cpuTimeNanoseconds,
                bytesRead: process.bytesRead,
                bytesWritten: process.bytesWritten,
                networkBytesReceived: counter.received,
                networkBytesSent: counter.sent,
                residentMemoryBytes: 0
            )
        }

        publishedProcessNetworkCounters = publishedProcessNetworkCounters.filter { identity, counter in
            currentIdentities.contains(identity) && latestObservedIdentities.contains(identity)
                || !counter.pending.isEmpty
                || advancedIdentities.contains(identity)
        }
        var retainedIdentities = currentIdentities
        retainedIdentities.formUnion(publishedProcessNetworkCounters.keys)
        if let previousProcessNetworkObservation {
            retainedIdentities.formUnion(previousProcessNetworkObservation.totals.keys)
        }
        cachedProcessCounters = cachedProcessCounters.filter { retainedIdentities.contains($0.key) }

        return CurrentProcessNetworkState(
            sample: sample,
            retiredProcesses: sample.isAvailable ? retiredProcesses : []
        )
    }

    private func applyProcessNetworkRefresh(
        _ refresh: CompletedProcessNetworkRefresh,
        at uptime: TimeInterval
    ) {
        guard refresh.sample.isAvailable, let totals = refresh.sample.totals else {
            isProcessNetworkSourceAvailable = false
            previousProcessNetworkObservation = nil
            publishedProcessNetworkCounters.removeAll()
            return
        }

        isProcessNetworkSourceAvailable = true
        let observation = ProcessNetworkObservation(
            sampledAt: refresh.sampledAt,
            totals: Dictionary(uniqueKeysWithValues: totals.compactMap { pid, counter in
                refresh.identitiesByPID[pid].map { ($0, counter) }
            }),
            kind: refresh.sample.kind
        )

        if case .interval(let duration) = refresh.sample.kind {
            let observedDuration = max(0.1, duration)
            for (identity, delta) in observation.totals {
                var published = publishedProcessNetworkCounters[identity]
                    ?? PublishedProcessNetworkCounter(
                        received: 0,
                        sent: 0,
                        lastAdvancedAt: uptime
                    )
                published.pending.append(PendingProcessNetworkDelta(
                    received: delta.received,
                    sent: delta.sent,
                    duration: observedDuration
                ))
                published.isReady = true
                publishedProcessNetworkCounters[identity] = published
            }
        } else if let previousProcessNetworkObservation,
                  case .cumulative = previousProcessNetworkObservation.kind {
            let observedDuration = max(
                0.1,
                observation.sampledAt - previousProcessNetworkObservation.sampledAt
            )
            for (identity, current) in observation.totals {
                guard let previous = previousProcessNetworkObservation.totals[identity],
                      current.received >= previous.received,
                      current.sent >= previous.sent
                else {
                    if var published = publishedProcessNetworkCounters[identity],
                       published.isReady || !published.pending.isEmpty {
                        published.lastAdvancedAt = uptime
                        publishedProcessNetworkCounters[identity] = published
                    } else {
                        publishedProcessNetworkCounters[identity] = PublishedProcessNetworkCounter(
                            received: current.received,
                            sent: current.sent,
                            lastAdvancedAt: uptime
                        )
                    }
                    continue
                }
                var published = publishedProcessNetworkCounters[identity]
                    ?? PublishedProcessNetworkCounter(
                        received: previous.received,
                        sent: previous.sent,
                        lastAdvancedAt: uptime
                    )
                published.pending.append(PendingProcessNetworkDelta(
                    received: current.received - previous.received,
                    sent: current.sent - previous.sent,
                    duration: observedDuration
                ))
                published.isReady = true
                publishedProcessNetworkCounters[identity] = published
            }
        } else {
            publishedProcessNetworkCounters = observation.totals.mapValues { counter in
                PublishedProcessNetworkCounter(
                    received: counter.received,
                    sent: counter.sent,
                    lastAdvancedAt: uptime
                )
            }
        }
        previousProcessNetworkObservation = observation
    }

    private func scheduleProcessNetworkRefresh(
        at uptime: TimeInterval,
        identitiesByPID: [Int32: ProcessNetworkIdentity]
    ) {
        lastProcessNetworkRefreshUptime = uptime
        processNetworkRefreshGeneration += 1
        let generation = processNetworkRefreshGeneration
        processNetworkRefreshStartedAt = uptime
        processNetworkRefreshIdentities = identitiesByPID
        let provider = processNetworkSampleProvider
        let task = Task.detached(priority: .utility) {
            provider()
        }
        processNetworkRefreshTask = task
        Task { [weak self] in
            let sample = await task.value
            await self?.finishProcessNetworkRefresh(
                sample,
                generation: generation,
                sampledAt: uptime,
                identitiesByPID: identitiesByPID
            )
        }
    }

    private func finishProcessNetworkRefresh(
        _ sample: ProcessNetworkSample,
        generation: Int,
        sampledAt: TimeInterval,
        identitiesByPID: [Int32: ProcessNetworkIdentity]
    ) {
        guard generation == processNetworkRefreshGeneration,
              processNetworkRefreshTask != nil
        else { return }
        completedProcessNetworkRefresh = CompletedProcessNetworkRefresh(
            sample: sample,
            sampledAt: sampledAt,
            identitiesByPID: identitiesByPID
        )
        processNetworkRefreshTask = nil
    }

    func waitForPendingProcessNetworkRefreshForTesting() async {
        guard let task = processNetworkRefreshTask else { return }
        let generation = processNetworkRefreshGeneration
        let sampledAt = processNetworkRefreshStartedAt
        let identitiesByPID = processNetworkRefreshIdentities
        let sample = await task.value
        finishProcessNetworkRefresh(
            sample,
            generation: generation,
            sampledAt: sampledAt,
            identitiesByPID: identitiesByPID
        )
    }

    private func collectDisks() -> [RawDiskCounter] {
        let capacity = 64
        var buffer = Array(repeating: DMDiskIO(), count: capacity)
        let count = Int(dm_collect_disk_io(&buffer, Int32(capacity)))

        return buffer.prefix(max(0, count)).map { raw in
            var sample = raw
            return RawDiskCounter(
                registryID: sample.registry_id,
                name: decodeCString(&sample.name),
                bytesRead: sample.bytes_read,
                bytesWritten: sample.bytes_written,
                readOperations: sample.read_operations,
                writeOperations: sample.write_operations,
                capacity: sample.capacity,
                bsdName: decodeCString(&sample.bsd_name),
                isPhysical: sample.is_physical != 0
            )
        }
    }

    private func finishVolumeRefresh(_ volumes: [VolumeInfo]) {
        if !volumes.isEmpty || cachedVolumes.isEmpty {
            cachedVolumes = volumes
        }
        volumeRefreshTask = nil
    }

    private struct MountedVolume: Sendable {
        let url: URL
        let info: VolumeInfo
    }

    nonisolated private static func collectVolumes(
        using runner: DiskutilCommandRunner
    ) async -> [VolumeInfo] {
        let mountedVolumes = collectMountedVolumes()
        let volumes = await withTaskGroup(of: VolumeInfo.self) { group in
            for mountedVolume in mountedVolumes {
                group.addTask {
                    let info = mountedVolume.info
                    return VolumeInfo(
                        id: info.id,
                        name: info.name,
                        mountPath: info.mountPath,
                        totalCapacity: info.totalCapacity,
                        availableCapacity: info.availableCapacity,
                        isLocal: info.isLocal,
                        isWritable: info.isWritable,
                        hasStableIdentity: info.hasStableIdentity,
                        isRemovable: info.isRemovable,
                        physicalDiskBSDNames: await physicalDiskBSDNames(
                            for: mountedVolume.url,
                            using: runner
                        )
                    )
                }
            }
            var results: [VolumeInfo] = []
            for await volume in group {
                results.append(volume)
            }
            return results
        }
        return volumes.sorted(by: volumeSort)
    }

    nonisolated private static func collectMountedVolumes() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeUUIDStringKey,
            .volumeIdentifierKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let stableIdentifier = values?.volumeUUIDString
                ?? values?.volumeIdentifier.map { String(describing: $0) }
            let fallbackName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return MountedVolume(
                url: url,
                info: VolumeInfo(
                    id: stableIdentifier ?? "unidentified:\(url.path)",
                    name: values?.volumeName ?? fallbackName,
                    mountPath: url.standardizedFileURL.path,
                    totalCapacity: Int64(values?.volumeTotalCapacity ?? 0),
                    availableCapacity: Int64(values?.volumeAvailableCapacity ?? 0),
                    isLocal: values?.volumeIsLocal ?? false,
                    isWritable: !(values?.volumeIsReadOnly ?? true),
                    hasStableIdentity: stableIdentifier != nil,
                    isRemovable: values?.volumeIsRemovable ?? false,
                    physicalDiskBSDNames: []
                )
            )
        }
        .sorted { volumeSort($0.info, $1.info) }
    }

    nonisolated private static func volumeSort(_ lhs: VolumeInfo, _ rhs: VolumeInfo) -> Bool {
        if lhs.mountPath == "/" { return true }
        if rhs.mountPath == "/" { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    nonisolated private static func physicalDiskBSDNames(
        for volumeURL: URL,
        using runner: DiskutilCommandRunner
    ) async -> [String] {
        guard let data = try? await runner.runDiskutilInfo(
            identifier: volumeURL.path,
            timeout: .seconds(2),
            maximumOutputBytes: 262_144
        ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return [] }

        var identifiers: [String] = []
        if let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]] {
            identifiers.append(contentsOf: stores.compactMap {
                ($0["APFSPhysicalStore"] ?? $0["DeviceIdentifier"]) as? String
            })
        }
        if identifiers.isEmpty, let parent = dictionary["ParentWholeDisk"] as? String {
            identifiers.append(parent)
        }
        return Array(Set(identifiers.compactMap(wholeDiskBSDName))).sorted()
    }
}

enum ProcessNetworkParser {
    static func parse(_ text: String) -> [Int32: ProcessNetworkCounter] {
        parse(text, minimumSampleCount: 1) ?? [:]
    }

    static func parse(
        _ text: String,
        minimumSampleCount: Int
    ) -> [Int32: ProcessNetworkCounter]? {
        var totals: [Int32: ProcessNetworkCounter] = [:]
        var sampleCount = 0
        for line in text.split(whereSeparator: \Character.isNewline) {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 4 else { continue }
            let valueOffset = columns.last?.isEmpty == true ? 1 : 0
            let sentIndex = columns.count - 1 - valueOffset
            let receivedIndex = sentIndex - 1
            let identityEnd = receivedIndex
            if columns[..<identityEnd].allSatisfy(\.isEmpty),
               columns[receivedIndex] == "bytes_in",
               columns[sentIndex] == "bytes_out" {
                sampleCount += 1
                totals.removeAll(keepingCapacity: true)
                continue
            }
            guard sampleCount > 0 else { continue }
            let identity = columns[..<identityEnd].joined(separator: ",")
            guard let separator = identity.lastIndex(of: "."),
                  let pid = Int32(identity[identity.index(after: separator)...]),
                  let received = UInt64(columns[receivedIndex]),
                  let sent = UInt64(columns[sentIndex])
            else { continue }
            totals[pid] = ProcessNetworkCounter(received: received, sent: sent)
        }
        return sampleCount >= max(1, minimumSampleCount) ? totals : nil
    }
}

private func decodeCString<T>(_ value: inout T) -> String {
    withUnsafeBytes(of: &value) { rawBuffer in
        let bytes = rawBuffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

func wholeDiskBSDName(_ identifier: String) -> String? {
    guard identifier.hasPrefix("disk") else { return nil }
    let digits = identifier.dropFirst(4).prefix(while: \Character.isNumber)
    guard !digits.isEmpty else { return nil }
    return "disk\(digits)"
}

func diskProtocolIsVirtual(_ name: String) -> Bool {
    name.withCString { dm_disk_protocol_is_virtual($0) != 0 }
}
