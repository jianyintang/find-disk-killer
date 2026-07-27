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

    public init(
        identity: String,
        name: String,
        readBytes: UInt64,
        writeBytes: UInt64,
        cpuTimeNanoseconds: UInt64,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64
    ) {
        self.identity = identity
        self.name = name
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
    }
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
    public let cpuPercent: Double?
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let applications: [HistoryApplicationSample]
    public let devices: [HistoryDeviceSample]

    public init(
        timestamp: Date,
        duration: TimeInterval,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        cpuPercent: Double?,
        networkReceiveBytes: UInt64,
        networkSendBytes: UInt64,
        applications: [HistoryApplicationSample],
        devices: [HistoryDeviceSample]
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.cpuPercent = cpuPercent
        self.networkReceiveBytes = networkReceiveBytes
        self.networkSendBytes = networkSendBytes
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
}

public struct HistoryTrendPoint: Identifiable, Equatable, Sendable {
    public let timestamp: Date
    public let duration: TimeInterval
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let averageCPUPercent: Double?
    public let peakCPUPercent: Double?

    public var id: Date { timestamp }
}

public struct HistoryApplicationReport: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkSendBytes: UInt64
    public let cpuTimeNanoseconds: UInt64
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
