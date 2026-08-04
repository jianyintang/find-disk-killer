import Foundation

public enum SampleRange: String, CaseIterable, Identifiable, Sendable {
    case minute = "1 分钟"
    case fifteenMinutes = "15 分钟"
    case hour = "1 小时"

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .minute: 60
        case .fifteenMinutes: 15 * 60
        case .hour: 60 * 60
        }
    }
}

public enum MonitorHealth: Equatable, Sendable {
    case starting
    case normal
    case elevated(duration: TimeInterval)
    case stopped
    case unavailable(String)
}

public enum ProcessBrand: String, Sendable {
    case codex
    case claude
}

public struct ThroughputPoint: Identifiable, Sendable {
    public let timestamp: Date
    public let sampleDuration: TimeInterval
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?
    public let segment: Int

    public var id: Date { timestamp }
}

public struct SystemResourcePoint: Identifiable, Sendable {
    public let timestamp: Date
    public let sampleDuration: TimeInterval
    public let cpuPercent: Double?
    public let cpuSegment: Int
    public let networkReceiveBytesPerSecond: Double?
    public let networkSendBytesPerSecond: Double?
    public let networkSegment: Int
    public let memoryUsedBytes: UInt64?
    public let memoryCompressedBytes: UInt64?
    public let memorySegment: Int

    public var id: Date { timestamp }
}

public struct CPUCoreUsage: Identifiable, Equatable, Sendable {
    public let index: UInt32
    public let percent: Double

    public var id: UInt32 { index }

    public init(index: UInt32, percent: Double) {
        self.index = index
        self.percent = percent
    }
}

public struct ProcessMetricPoint: Identifiable, Sendable {
    public let timestamp: Date
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?
    public let cpuPercent: Double?
    public let networkReceiveBytesPerSecond: Double?
    public let networkSendBytesPerSecond: Double?
    public let networkSegment: Int
    public let memoryBytes: UInt64

    public var id: Date { timestamp }
}

public struct DiskActivity: Identifiable, Sendable {
    public let id: UInt64
    public let name: String
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let readOperationsPerSecond: Double
    public let writeOperationsPerSecond: Double
    public let capacity: UInt64
    public let bsdName: String
    public let isPhysical: Bool
}

public struct VolumeInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mountPath: String
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    public let isLocal: Bool
    public let isWritable: Bool
    public let hasStableIdentity: Bool
    public let isRemovable: Bool
    public let physicalDiskBSDNames: [String]

    public var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(totalCapacity - availableCapacity) / Double(totalCapacity)
    }

    public func contains(path: String) -> Bool {
        VolumePathResolver.contains(path: path, in: mountPath)
    }
}

public enum VolumePathResolver {
    public static func bestMatch(
        for path: String,
        in volumes: [VolumeInfo]
    ) -> VolumeInfo? {
        guard path.hasPrefix("/") else { return nil }
        let path = canonicalPath(path)
        return volumes
            .filter { contains(path: path, in: $0.mountPath) }
            .max { canonicalPath($0.mountPath).count < canonicalPath($1.mountPath).count }
    }

    public static func contains(path: String, in mountPath: String) -> Bool {
        guard path.hasPrefix("/"), mountPath.hasPrefix("/") else { return false }
        let path = canonicalPath(path)
        let mountPath = canonicalPath(mountPath)
        if mountPath == "/" { return true }
        return path == mountPath || path.hasPrefix(mountPath + "/")
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public struct ProcessActivity: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let executablePath: String
    public let appBundlePath: String?
    public let pids: [Int32]
    public let sessions: [ProcessSession]
    public let memberCount: Int
    public let currentReadBytesPerSecond: Double
    public let currentWriteBytesPerSecond: Double
    public let currentCPUPercent: Double
    public let currentNetworkReceiveBytesPerSecond: Double
    public let currentNetworkSendBytesPerSecond: Double
    public let currentMemoryBytes: UInt64
    public let totalReadBytes: UInt64
    public let totalWriteBytes: UInt64
    public let totalNetworkReceivedBytes: UInt64
    public let totalNetworkSentBytes: UInt64
    public let averageWriteBytesPerSecond: Double
    public let peakWriteBytesPerSecond: Double
    public let averageCPUPercent: Double
    public let peakCPUPercent: Double
    public let peakMemoryBytes: UInt64
    public let averageNetworkReceiveBytesPerSecond: Double
    public let averageNetworkSendBytesPerSecond: Double
    public let isNetworkAvailable: Bool
    public let currentUnavailableMetrics: HistoryApplicationMetricSet
    public let intervalUnavailableMetrics: HistoryApplicationMetricSet
    public let metrics: [ProcessMetricPoint]
    public let brand: ProcessBrand?
    public let brandIsVerified: Bool
    public let lastActivity: Date
}

public struct SystemLayerActivity: Identifiable, Sendable {
    public static let stableID = "aggregate:macos-storage-layer"

    public let id: String
    public let currentCPUPercent: Double?
    public let totalWriteBytes: UInt64?
    public let currentWriteBytesPerSecond: Double?
    public let peakWriteBytesPerSecond: Double?
    public let averageNetworkReceiveBytesPerSecond: Double?
    public let averageNetworkSendBytesPerSecond: Double?

    public init(
        id: String = Self.stableID,
        currentCPUPercent: Double?,
        totalWriteBytes: UInt64?,
        currentWriteBytesPerSecond: Double?,
        peakWriteBytesPerSecond: Double?,
        averageNetworkReceiveBytesPerSecond: Double?,
        averageNetworkSendBytesPerSecond: Double?
    ) {
        self.id = id
        self.currentCPUPercent = currentCPUPercent
        self.totalWriteBytes = totalWriteBytes
        self.currentWriteBytesPerSecond = currentWriteBytesPerSecond
        self.peakWriteBytesPerSecond = peakWriteBytesPerSecond
        self.averageNetworkReceiveBytesPerSecond = averageNetworkReceiveBytesPerSecond
        self.averageNetworkSendBytesPerSecond = averageNetworkSendBytesPerSecond
    }
}

public struct ProcessSession: Hashable, Sendable {
    public let pid: Int32
    public let startAbstime: UInt64

    public init(pid: Int32, startAbstime: UInt64) {
        self.pid = pid
        self.startAbstime = startAbstime
    }
}

public enum PercentFormatter {
    public static func cpu(_ value: Double) -> String {
        if value >= 100 { return formatted("%.0f%%", value) }
        if value >= 10 { return formatted("%.1f%%", value) }
        return formatted("%.2f%%", value)
    }

    private static func formatted(_ format: String, _ value: Double) -> String {
        String(format: format, locale: FindDiskKillerFormatting.locale, arguments: [value])
    }
}

public enum ByteRateFormatter {
    public static func rate(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, suffix: "/s")
    }

    public static func bytes(_ bytes: UInt64) -> String {
        format(Double(bytes), suffix: "")
    }

    public static func approximateBytes(_ bytes: Double) -> String {
        format(bytes, suffix: "")
    }

    private static func format(_ value: Double, suffix: String) -> String {
        let absolute = abs(value)
        let units: [(threshold: Double, divisor: Double, label: String)] = [
            (1_000_000_000, 1_000_000_000, "GB"),
            (1_000_000, 1_000_000, "MB"),
            (1_000, 1_000, "KB")
        ]

        for unit in units where absolute >= unit.threshold {
            let scaled = value / unit.divisor
            let precision = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
            return String(
                format: "%.*f %@%@",
                locale: FindDiskKillerFormatting.locale,
                arguments: [precision, scaled, unit.label, suffix]
            )
        }
        return String(
            format: "%.0f B%@",
            locale: FindDiskKillerFormatting.locale,
            arguments: [value, suffix]
        )
    }
}

private enum FindDiskKillerFormatting {
    static var locale: Locale {
        guard let identifier = UserDefaults.standard.string(forKey: "appLanguage"),
              identifier != "system"
        else { return .current }
        return Locale(identifier: identifier)
    }
}

public enum ProcessClassifier {
    public struct Classification: Sendable {
        public let groupID: String
        public let displayName: String
        public let appBundlePath: String?
        public let brand: ProcessBrand?
        public let brandIsVerified: Bool
    }

    public static func classify(name: String, executablePath: String) -> Classification {
        let appPath = containingApplicationPath(executablePath)
        let lowerPath = executablePath.lowercased()
        let lowerName = name.lowercased()

        if lowerPath.contains("/chatgpt.app/contents/resources/codex")
            || lowerPath.contains("/codex (renderer).app/")
            || lowerPath.contains("/codex (service).app/") {
            return Classification(
                groupID: "brand:codex",
                displayName: "Codex",
                appBundlePath: appPath ?? "/Applications/ChatGPT.app",
                brand: .codex,
                brandIsVerified: true
            )
        }

        if let appPath, appPath.lowercased().contains("/claude.app") {
            return Classification(
                groupID: "brand:claude",
                displayName: "Claude",
                appBundlePath: appPath,
                brand: .claude,
                brandIsVerified: true
            )
        }

        if let appPath {
            let displayName = URL(fileURLWithPath: appPath)
                .deletingPathExtension()
                .lastPathComponent
            return Classification(
                groupID: "app:\(appPath)",
                displayName: displayName,
                appBundlePath: appPath,
                brand: nil,
                brandIsVerified: false
            )
        }

        if lowerName == "codex" || lowerName == "claude" {
            return Classification(
                groupID: "executable:\(executablePath)",
                displayName: "\(name)（可能关联）",
                appBundlePath: nil,
                brand: lowerName == "codex" ? .codex : .claude,
                brandIsVerified: false
            )
        }

        return Classification(
            groupID: "executable:\(executablePath.isEmpty ? name : executablePath)",
            displayName: name,
            appBundlePath: nil,
            brand: nil,
            brandIsVerified: false
        )
    }

    private static func containingApplicationPath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: [.caseInsensitive]) else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
