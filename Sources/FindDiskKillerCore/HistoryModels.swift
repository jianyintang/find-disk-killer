import Foundation

public enum HistoryRetention: String, CaseIterable, Codable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case oneYear

    public var id: String { rawValue }

    public var cutoffDays: Int {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .oneYear: 365
        }
    }

    public var automaticBudgetBytes: Int64 {
        switch self {
        case .sevenDays: 32_000_000
        case .thirtyDays: 64_000_000
        case .oneYear: 128_000_000
        }
    }

    public var trendResolution: Int {
        switch self {
        case .sevenDays: 900
        case .thirtyDays, .oneYear: 3_600
        }
    }

    public func cutoffDate(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .oneYear:
            let priorYear = calendar.date(byAdding: .year, value: -1, to: today) ?? today
            return calendar.date(byAdding: .day, value: 1, to: priorYear) ?? priorYear
        }
    }
}

public enum HistoryStorageBudget: Int64, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = 0
    case mb32 = 32_000_000
    case mb64 = 64_000_000
    case mb128 = 128_000_000
    case mb160 = 160_000_000

    public var id: Int64 { rawValue }

    public func bytes(for retention: HistoryRetention) -> Int64 {
        self == .automatic ? retention.automaticBudgetBytes : rawValue
    }
}

public struct HistoryConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var retention: HistoryRetention
    public var storageBudget: HistoryStorageBudget
    public var savesApplicationActivity: Bool

    public init(
        isEnabled: Bool = false,
        retention: HistoryRetention = .thirtyDays,
        storageBudget: HistoryStorageBudget = .automatic,
        savesApplicationActivity: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.retention = retention
        self.storageBudget = storageBudget
        self.savesApplicationActivity = savesApplicationActivity
    }

    public var budgetBytes: Int64 { storageBudget.bytes(for: retention) }
}

public struct HistoryApplicationSample: Sendable {
    public let identity: String
    public let name: String
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let cpuTimeNanoseconds: UInt64
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let unavailableMetrics: HistoryApplicationMetricSet

    public init(
        identity: String,
        name: String,
        readBytes: UInt64,
        writeBytes: UInt64,
        cpuTimeNanoseconds: UInt64,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64,
        unavailableMetrics: HistoryApplicationMetricSet = []
    ) {
        self.identity = identity
        self.name = name
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
        self.unavailableMetrics = unavailableMetrics
    }
}

public struct HistoryApplicationMetricSet: OptionSet, Equatable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static let read = Self(rawValue: 1 << 0)
    public static let write = Self(rawValue: 1 << 1)
    public static let cpu = Self(rawValue: 1 << 2)
    public static let networkReceive = Self(rawValue: 1 << 3)
    public static let networkSend = Self(rawValue: 1 << 4)
}

public struct HistoryDeviceSample: Sendable {
    public let identity: String
    public let name: String
    public let readBytes: UInt64
    public let writeBytes: UInt64

    public init(
        identity: String,
        name: String,
        readBytes: UInt64,
        writeBytes: UInt64
    ) {
        self.identity = identity
        self.name = name
        self.readBytes = readBytes
        self.writeBytes = writeBytes
    }
}

public struct HistorySample: Sendable {
    public let timestamp: Date
    public let duration: TimeInterval
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let diskStatsAvailable: Bool
    public let cpuPercent: Double?
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let networkStatsAvailable: Bool
    public let applications: [HistoryApplicationSample]
    public let devices: [HistoryDeviceSample]

    public init(
        timestamp: Date,
        duration: TimeInterval,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        diskStatsAvailable: Bool = true,
        cpuPercent: Double?,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64,
        networkStatsAvailable: Bool = true,
        applications: [HistoryApplicationSample],
        devices: [HistoryDeviceSample]
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.diskStatsAvailable = diskStatsAvailable
        self.cpuPercent = cpuPercent
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
        self.networkStatsAvailable = networkStatsAvailable
        self.applications = applications
        self.devices = devices
    }
}

public struct HistorySummary: Equatable, Sendable {
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let averageCPUPercent: Double?
    public let peakCPUPercent: Double?
    public let observedSeconds: TimeInterval
    public let coverage: Double
    public let diskObservedSeconds: TimeInterval
    public let networkObservedSeconds: TimeInterval
    public let cpuObservedSeconds: TimeInterval
    public let diskCoverage: Double
    public let networkCoverage: Double
    public let cpuCoverage: Double

    public init(
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64,
        averageCPUPercent: Double?,
        peakCPUPercent: Double?,
        observedSeconds: TimeInterval,
        coverage: Double,
        diskObservedSeconds: TimeInterval? = nil,
        networkObservedSeconds: TimeInterval? = nil,
        cpuObservedSeconds: TimeInterval? = nil,
        diskCoverage: Double? = nil,
        networkCoverage: Double? = nil,
        cpuCoverage: Double? = nil
    ) {
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
        self.averageCPUPercent = averageCPUPercent
        self.peakCPUPercent = peakCPUPercent
        self.observedSeconds = observedSeconds
        self.coverage = coverage
        self.diskObservedSeconds = diskObservedSeconds ?? observedSeconds
        self.networkObservedSeconds = networkObservedSeconds ?? observedSeconds
        self.cpuObservedSeconds = cpuObservedSeconds ?? observedSeconds
        self.diskCoverage = diskCoverage ?? coverage
        self.networkCoverage = networkCoverage ?? coverage
        self.cpuCoverage = cpuCoverage ?? coverage
    }
}

public struct HistoryTrendPoint: Identifiable, Equatable, Sendable {
    public let timestamp: Date
    public let duration: TimeInterval
    public let diskObservedSeconds: TimeInterval
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let networkObservedSeconds: TimeInterval
    public let cpuObservedSeconds: TimeInterval
    public let averageCPUPercent: Double?
    public let peakCPUPercent: Double?
    public let startsNewSegment: Bool

    public var id: Date { timestamp }

    public init(
        timestamp: Date,
        duration: TimeInterval,
        diskObservedSeconds: TimeInterval? = nil,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        networkObservedSeconds: TimeInterval? = nil,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64,
        cpuObservedSeconds: TimeInterval? = nil,
        averageCPUPercent: Double?,
        peakCPUPercent: Double?,
        startsNewSegment: Bool = false
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.diskObservedSeconds = diskObservedSeconds ?? duration
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkObservedSeconds = networkObservedSeconds ?? duration
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
        self.cpuObservedSeconds = cpuObservedSeconds ?? (averageCPUPercent == nil ? 0 : duration)
        self.averageCPUPercent = averageCPUPercent
        self.peakCPUPercent = peakCPUPercent
        self.startsNewSegment = startsNewSegment
    }
}

public struct HistoryApplicationReport: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let cpuTimeNanoseconds: UInt64
    public let unavailableMetrics: HistoryApplicationMetricSet

    public init(
        id: String,
        name: String,
        readBytes: UInt64,
        writeBytes: UInt64,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64,
        cpuTimeNanoseconds: UInt64,
        unavailableMetrics: HistoryApplicationMetricSet = []
    ) {
        self.id = id
        self.name = name
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.unavailableMetrics = unavailableMetrics
    }
}

public struct HistoryReport: Equatable, Sendable {
    public let range: HistoryRetention
    public let start: Date
    public let end: Date
    public let summary: HistorySummary
    public let trend: [HistoryTrendPoint]
    public let applications: [HistoryApplicationReport]
    public let previousPeriodDiskWriteBytes: UInt64?
}

public enum HistoryStorageState: Equatable, Sendable {
    case normal
    case nearingLimit
    case optimizing(progress: Double)
    case compacted(start: Date)
    case paused
    case unavailable(String)
}

public struct HistoryStorageInfo: Equatable, Sendable {
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let shmBytes: Int64
    public let budgetBytes: Int64
    public let lastSavedAt: Date?
    public let state: HistoryStorageState

    public init(
        databaseBytes: Int64,
        walBytes: Int64,
        shmBytes: Int64,
        budgetBytes: Int64,
        lastSavedAt: Date?,
        state: HistoryStorageState
    ) {
        self.databaseBytes = databaseBytes
        self.walBytes = walBytes
        self.shmBytes = shmBytes
        self.budgetBytes = budgetBytes
        self.lastSavedAt = lastSavedAt
        self.state = state
    }

    public var totalBytes: Int64 { databaseBytes + walBytes + shmBytes }
}
