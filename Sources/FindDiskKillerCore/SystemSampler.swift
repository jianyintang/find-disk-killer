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
    public let networkInterfaces: [RawNetworkInterfaceCounter]
    public let cpuStatsAvailable: Bool
    public let networkInterfacesAvailable: Bool
    public let processNetworkAvailable: Bool
}

public actor SystemSampler {
    public static let shared = SystemSampler()
    private var cachedVolumes: [VolumeInfo] = []
    private var lastVolumeRefreshUptime: TimeInterval = -.infinity
    private var volumeRefreshTask: Task<Void, Never>?
    private let diskutilRunner = DiskutilCommandRunner()

    public func collect() -> SystemSnapshot {
        let uptime = ProcessInfo.processInfo.systemUptime
        if volumeRefreshTask == nil,
           uptime - lastVolumeRefreshUptime >= 30 || cachedVolumes.isEmpty {
            lastVolumeRefreshUptime = uptime
            let runner = diskutilRunner
            volumeRefreshTask = Task {
                let volumes = await Self.collectVolumes(using: runner)
                finishVolumeRefresh(volumes)
            }
        }
        let processNetwork = collectProcessNetworkTotals()
        let stats = collectSystemStats()
        let interfaces = collectNetworkInterfaces()
        return SystemSnapshot(
            date: Date(),
            uptime: uptime,
            processes: collectProcesses(networkTotals: processNetwork.totals),
            disks: collectDisks(),
            volumes: cachedVolumes,
            cpuUserTicks: stats.cpuUserTicks,
            cpuSystemTicks: stats.cpuSystemTicks,
            cpuNiceTicks: stats.cpuNiceTicks,
            cpuIdleTicks: stats.cpuIdleTicks,
            networkInterfaces: interfaces.counters,
            cpuStatsAvailable: stats.isAvailable,
            networkInterfacesAvailable: interfaces.isAvailable,
            processNetworkAvailable: processNetwork.isAvailable
        )
    }

    private func collectProcesses(
        networkTotals: [Int32: (received: UInt64, sent: UInt64)]?
    ) -> [RawProcessCounter] {
        let capacity = 8_192
        var buffer = Array(repeating: DMProcessIO(), count: capacity)
        let count = Int(dm_collect_process_io(&buffer, Int32(capacity)))

        return buffer.prefix(max(0, count)).map { raw in
            var sample = raw
            return RawProcessCounter(
                pid: sample.pid,
                startAbstime: sample.start_abstime,
                name: decodeCString(&sample.name),
                path: decodeCString(&sample.path),
                cpuTimeNanoseconds: sample.cpu_time_ns,
                bytesRead: sample.bytes_read,
                bytesWritten: sample.bytes_written,
                networkBytesReceived: networkTotals.map { $0[sample.pid]?.received ?? 0 },
                networkBytesSent: networkTotals.map { $0[sample.pid]?.sent ?? 0 }
            )
        }
    }

    private func collectSystemStats() -> (
        cpuUserTicks: UInt64,
        cpuSystemTicks: UInt64,
        cpuNiceTicks: UInt64,
        cpuIdleTicks: UInt64,
        isAvailable: Bool
    ) {
        var stats = DMSystemStats()
        let isAvailable = dm_collect_system_stats(&stats) != 0
        return (
            stats.cpu_user_ticks,
            stats.cpu_system_ticks,
            stats.cpu_nice_ticks,
            stats.cpu_idle_ticks,
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

    private func collectProcessNetworkTotals() -> (
        totals: [Int32: (received: UInt64, sent: UInt64)]?,
        isAvailable: Bool
    ) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e", "alarm 2; exec @ARGV",
            "/usr/bin/nettop", "-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (nil, false)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return (nil, false) }
        return (ProcessNetworkParser.parse(text), true)
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
        cachedVolumes = volumes
        volumeRefreshTask = nil
    }

    nonisolated private static func collectVolumes(
        using runner: DiskutilCommandRunner
    ) async -> [VolumeInfo] {
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

        let volumes = await withTaskGroup(of: VolumeInfo?.self) { group in
            for url in urls {
                group.addTask {
                    guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                    let total = Int64(values.volumeTotalCapacity ?? 0)
                    let available = Int64(values.volumeAvailableCapacity ?? 0)
                    let stableIdentifier = values.volumeUUIDString
                        ?? values.volumeIdentifier.map { String(describing: $0) }
                    return VolumeInfo(
                        id: stableIdentifier ?? "unidentified:\(url.path)",
                        name: values.volumeName ?? url.lastPathComponent,
                        mountPath: url.path,
                        totalCapacity: total,
                        availableCapacity: available,
                        isLocal: values.volumeIsLocal ?? false,
                        isWritable: !(values.volumeIsReadOnly ?? true),
                        hasStableIdentity: stableIdentifier != nil,
                        isRemovable: values.volumeIsRemovable ?? false,
                        physicalDiskBSDNames: await physicalDiskBSDNames(
                            for: url,
                            using: runner
                        )
                    )
                }
            }
            var results: [VolumeInfo] = []
            for await volume in group {
                if let volume { results.append(volume) }
            }
            return results
        }
        return volumes.sorted { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
    static func parse(_ text: String) -> [Int32: (received: UInt64, sent: UInt64)] {
        var totals: [Int32: (received: UInt64, sent: UInt64)] = [:]
        for line in text.split(whereSeparator: \Character.isNewline).dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 4 else { continue }
            let valueOffset = columns.last?.isEmpty == true ? 1 : 0
            let sentIndex = columns.count - 1 - valueOffset
            let receivedIndex = sentIndex - 1
            let identityEnd = receivedIndex
            let identity = columns[..<identityEnd].joined(separator: ",")
            guard let separator = identity.lastIndex(of: "."),
                  let pid = Int32(identity[identity.index(after: separator)...]),
                  let received = UInt64(columns[receivedIndex]),
                  let sent = UInt64(columns[sentIndex])
            else { continue }
            totals[pid] = (received, sent)
        }
        return totals
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
