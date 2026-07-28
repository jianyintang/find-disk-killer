import Foundation
import SQLite3

public enum HistoryDatabaseLocation: Sendable {
    case memory
    case file(URL)
}

protocol HistoryFileOperating: Sendable {
    func createDirectory(at url: URL) throws
    func setPermissions(_ permissions: Int, at url: URL) throws
    func excludeFromBackup(_ url: URL) throws
    func fileExists(at url: URL) -> Bool
    func removeItem(at url: URL) throws
    func fileSize(at url: URL) -> Int64
}

struct LiveHistoryFileOperations: HistoryFileOperating {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func fileSize(at url: URL) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}

public struct HistoryDatabaseError: Error, LocalizedError, Sendable {
    public let message: String
    public let isRetryable: Bool

    public init(message: String, isRetryable: Bool = false) {
        self.message = message
        self.isRetryable = isRetryable
    }

    public var errorDescription: String? { message }
}

private final class SQLiteConnection: @unchecked Sendable {
    private var storedHandle: OpaquePointer?
    var handle: OpaquePointer {
        precondition(storedHandle != nil, "SQLite connection is closed")
        return storedHandle!
    }

    init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw HistoryDatabaseError(message: "Unable to open monitoring history")
        }
        storedHandle = pointer
    }

    func close() throws {
        guard let storedHandle else { return }
        guard sqlite3_close_v2(storedHandle) == SQLITE_OK else {
            throw HistoryDatabaseError(message: "Unable to close monitoring history")
        }
        self.storedHandle = nil
    }

    deinit {
        if let storedHandle { sqlite3_close_v2(storedHandle) }
    }
}

struct HistoryMinuteBucket: Sendable {
    let startEpoch: Int64
    var observedSeconds = 0.0
    var diskObservedSeconds = 0.0
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    var cpuSeconds = 0.0
    var cpuObservedSeconds = 0.0
    var cpuPeak: Double?
    var networkObservedSeconds = 0.0
    var networkReceiveBytes: UInt64 = 0
    var networkSendBytes: UInt64 = 0
    var applications: [String: MutableApplicationBucket] = [:]
    var devices: [String: MutableDeviceBucket] = [:]

    mutating func add(_ sample: HistorySample) {
        let duration = max(0, min(sample.duration, 60))
        observedSeconds += duration
        if sample.diskStatsAvailable {
            diskObservedSeconds += duration
            diskReadBytes = diskReadBytes.addingClamped(sample.diskReadBytes)
            diskWriteBytes = diskWriteBytes.addingClamped(sample.diskWriteBytes)
        }
        if sample.networkStatsAvailable {
            networkObservedSeconds += duration
            networkReceiveBytes = networkReceiveBytes.addingClamped(sample.networkReceiveBytes)
            networkSendBytes = networkSendBytes.addingClamped(sample.networkSendBytes)
        }
        if let cpu = sample.cpuPercent, cpu.isFinite {
            let bounded = max(0, cpu)
            cpuSeconds += bounded / 100 * duration
            cpuObservedSeconds += duration
            cpuPeak = max(cpuPeak ?? bounded, bounded)
        }
        for app in sample.applications {
            var bucket = applications[app.identity] ?? MutableApplicationBucket(name: app.name)
            bucket.add(app)
            applications[app.identity] = bucket
        }
        for device in sample.devices {
            var bucket = devices[device.identity] ?? MutableDeviceBucket(name: device.name)
            bucket.readBytes = bucket.readBytes.addingClamped(device.readBytes)
            bucket.writeBytes = bucket.writeBytes.addingClamped(device.writeBytes)
            devices[device.identity] = bucket
        }
    }
}

struct MutableApplicationBucket: Sendable {
    var name: String
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var cpuTimeNanoseconds: UInt64 = 0
    var networkReceiveBytes: UInt64 = 0
    var networkSendBytes: UInt64 = 0

    var activityScore: UInt64 {
        readBytes.addingClamped(writeBytes)
            .addingClamped(networkReceiveBytes)
            .addingClamped(networkSendBytes)
    }

    mutating func add(_ sample: HistoryApplicationSample) {
        name = sample.name
        readBytes = readBytes.addingClamped(sample.readBytes)
        writeBytes = writeBytes.addingClamped(sample.writeBytes)
        cpuTimeNanoseconds = cpuTimeNanoseconds.addingClamped(sample.cpuTimeNanoseconds)
        networkReceiveBytes = networkReceiveBytes.addingClamped(sample.networkReceiveBytes)
        networkSendBytes = networkSendBytes.addingClamped(sample.networkSendBytes)
    }

    mutating func merge(_ other: Self) {
        readBytes = readBytes.addingClamped(other.readBytes)
        writeBytes = writeBytes.addingClamped(other.writeBytes)
        cpuTimeNanoseconds = cpuTimeNanoseconds.addingClamped(other.cpuTimeNanoseconds)
        networkReceiveBytes = networkReceiveBytes.addingClamped(other.networkReceiveBytes)
        networkSendBytes = networkSendBytes.addingClamped(other.networkSendBytes)
    }
}

struct MutableDeviceBucket: Sendable {
    var name: String
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}

public actor HistoryRecorder {
    private static let maximumPendingBucketCount = 2
    private let database: HistoryDatabase
    private var configuration: HistoryConfiguration
    private var pendingBuckets: [HistoryMinuteBucket] = []
    private var bucket: HistoryMinuteBucket?

    public init(
        database: HistoryDatabase,
        configuration: HistoryConfiguration = .init(isEnabled: true)
    ) {
        self.database = database
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: HistoryConfiguration) async {
        if self.configuration.isEnabled && !configuration.isEnabled {
            await flush()
        }
        self.configuration = configuration
    }

    public func record(_ sample: HistorySample) async {
        guard configuration.isEnabled else { return }
        let minute = Int64(floor(sample.timestamp.timeIntervalSince1970 / 60) * 60)
        if let existing = bucket, existing.startEpoch != minute {
            let pendingDrained = await drainPendingBuckets()
            if !pendingDrained {
                enqueuePending(existing)
            } else if !(await commit(existing)) {
                enqueuePending(existing)
            }
            bucket = nil
        }
        if bucket == nil { bucket = HistoryMinuteBucket(startEpoch: minute) }
        bucket?.add(sample)
    }

    public func flush() async {
        guard await drainPendingBuckets() else { return }
        guard let bucket else { return }
        if await commit(bucket) {
            self.bucket = nil
        }
    }

    public func clear() async throws {
        let wasEnabled = configuration.isEnabled
        configuration.isEnabled = false
        pendingBuckets.removeAll()
        bucket = nil
        do {
            try await database.clear()
            configuration.isEnabled = wasEnabled
        } catch {
            configuration.isEnabled = wasEnabled
            throw error
        }
    }

    var pendingBucketCountForTesting: Int { pendingBuckets.count }

    private func drainPendingBuckets() async -> Bool {
        while let pending = pendingBuckets.first {
            guard await commit(pending) else { return false }
            pendingBuckets.removeFirst()
        }
        return true
    }

    private func enqueuePending(_ bucket: HistoryMinuteBucket) {
        pendingBuckets.append(bucket)
        if pendingBuckets.count > Self.maximumPendingBucketCount {
            pendingBuckets.removeFirst(pendingBuckets.count - Self.maximumPendingBucketCount)
        }
    }

    private func commit(_ bucket: HistoryMinuteBucket) async -> Bool {
        do {
            try await database.write(bucket, configuration: configuration)
            return true
        } catch let error as HistoryDatabaseError where error.isRetryable {
            return false
        } catch {
            // The realtime monitor is fail-open. UI status comes from database.storageInfo().
            return true
        }
    }
}

public actor HistoryDatabase {
    private static let currentSchemaVersion: Int32 = 1
    private var connection: SQLiteConnection?
    private let fileURL: URL?
    private let fileOperations: any HistoryFileOperating
    private let identityProvider: any HistoryIdentityProviding
    public private(set) var commitCount = 0
    private var lastSavedAt: Date?
    private var lastError: String?
    private var lastMaintenanceError: String?
    private var isPausedForBudget = false
    private var lastCompactedStart: Date?
    private var lastConfiguration = HistoryConfiguration()
    private var dailyIdentityCache: [Int64: Set<String>] = [:]
    private var globalIdentityCache: Set<String>?
    private var checkpointOverrideForTesting: (@Sendable () throws -> Void)?

    public init(location: HistoryDatabaseLocation) throws {
        let operations = LiveHistoryFileOperations()
        let identityProvider = HistoryIdentityProvider.shared
        try identityProvider.validate()
        let setup = try Self.openDatabase(location: location, fileOperations: operations)
        connection = setup.connection
        fileURL = setup.fileURL
        fileOperations = operations
        self.identityProvider = identityProvider
    }

    init(
        location: HistoryDatabaseLocation,
        fileOperations: any HistoryFileOperating,
        identityProvider: any HistoryIdentityProviding
    ) throws {
        try identityProvider.validate()
        let setup = try Self.openDatabase(
            location: location,
            fileOperations: fileOperations
        )
        connection = setup.connection
        fileURL = setup.fileURL
        self.fileOperations = fileOperations
        self.identityProvider = identityProvider
    }

    private static func openDatabase(
        location: HistoryDatabaseLocation,
        fileOperations: any HistoryFileOperating
    ) throws -> (connection: SQLiteConnection, fileURL: URL?) {
        let path: String
        let fileURL: URL?
        switch location {
        case .memory:
            path = ":memory:"
            fileURL = nil
        case .file(let url):
            let directory = url.deletingLastPathComponent()
            try fileOperations.createDirectory(at: directory)
            try fileOperations.setPermissions(0o700, at: directory)
            try fileOperations.excludeFromBackup(directory)
            path = url.path
            fileURL = url
        }

        let connection = try SQLiteConnection(path: path)
        do {
            try configure(connection.handle)
            try migrate(connection.handle)
            try protectHistoryFiles(at: fileURL, fileOperations: fileOperations)
            return (connection, fileURL)
        } catch {
            try? connection.close()
            throw error
        }
    }

    private static func configure(_ handle: OpaquePointer) throws {
        try execute(on: handle, sql: connectionPragmas)
    }

    private static func migrate(_ handle: OpaquePointer) throws {
        let version = try pragmaInt(on: handle, name: "user_version")
        guard version <= currentSchemaVersion else {
            throw HistoryDatabaseError(message: "Monitoring history was created by a newer app version")
        }
        guard version < currentSchemaVersion else {
            try execute(on: handle, sql: currentSchema)
            return
        }

        try execute(on: handle, sql: "BEGIN IMMEDIATE")
        do {
            if try tableExists("system_bucket", on: handle) {
                if try !columnExists("disk_observed_seconds", in: "system_bucket", on: handle) {
                    try execute(
                        on: handle,
                        sql: "ALTER TABLE system_bucket ADD COLUMN disk_observed_seconds REAL NOT NULL DEFAULT 0"
                    )
                    try execute(
                        on: handle,
                        sql: "UPDATE system_bucket SET disk_observed_seconds = observed_seconds"
                    )
                }
                if try !columnExists("network_observed_seconds", in: "system_bucket", on: handle) {
                    try execute(
                        on: handle,
                        sql: "ALTER TABLE system_bucket ADD COLUMN network_observed_seconds REAL NOT NULL DEFAULT 0"
                    )
                    try execute(
                        on: handle,
                        sql: "UPDATE system_bucket SET network_observed_seconds = observed_seconds"
                    )
                }
            }
            try execute(on: handle, sql: currentSchema)
            try execute(on: handle, sql: "PRAGMA user_version = \(currentSchemaVersion)")
            try execute(on: handle, sql: "COMMIT")
        } catch {
            try? execute(on: handle, sql: "ROLLBACK")
            throw error
        }
    }

    func write(
        _ bucket: HistoryMinuteBucket,
        configuration: HistoryConfiguration
    ) throws {
        lastConfiguration = configuration
        if try isMinuteCommitted(bucket.startEpoch) {
            lastSavedAt = Date(timeIntervalSince1970: TimeInterval(bucket.startEpoch + 60))
            lastError = nil
            isPausedForBudget = false
            return
        }
        let currentSize = totalFileSize()
        let pressure = Self.storagePressureDecision(
            currentSize: currentSize,
            budget: configuration.budgetBytes
        )
        guard pressure.canWrite else {
            isPausedForBudget = true
            throw HistoryDatabaseError(message: "Monitoring history reached its storage budget")
        }
        let shouldCompact = pressure.shouldCompact
        do {
            try execute("BEGIN IMMEDIATE")
            if shouldCompact {
                try compactApplicationDetail(
                    nowEpoch: bucket.startEpoch + 60,
                    retention: configuration.retention
                )
            }
            try insertSystem(bucket, resolution: 60)
            if configuration.savesApplicationActivity {
                try insertApplications(bucket)
                try upsertDailyApplications(bucket)
            }
            try insertDevices(bucket)
            try buildRollups(endingAfter: bucket.startEpoch)
            try applyRetention(nowEpoch: bucket.startEpoch + 60, retention: configuration.retention)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            lastError = String(describing: error)
            throw error
        }

        commitCount += 1
        lastSavedAt = Date(timeIntervalSince1970: TimeInterval(bucket.startEpoch + 60))
        lastError = nil
        isPausedForBudget = false
        if shouldCompact {
            lastCompactedStart = Date(timeIntervalSince1970: TimeInterval(bucket.startEpoch - 6 * 3_600))
        }
        do {
            if let checkpointOverrideForTesting {
                try checkpointOverrideForTesting()
            } else {
                try checkpointIfNeeded(configuration: configuration, force: shouldCompact)
            }
            lastMaintenanceError = nil
        } catch {
            // The minute is already durable. A checkpoint failure must not cause a replay.
            lastMaintenanceError = String(describing: error)
        }
        do {
            try Self.protectHistoryFiles(at: fileURL, fileOperations: fileOperations)
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    public func report(range: HistoryRetention, now: Date = Date()) throws -> HistoryReport {
        let endEpoch = Int64(now.timeIntervalSince1970)
        let startDate = range.cutoffDate(now: now)
        let startEpoch = Int64(startDate.timeIntervalSince1970)
        let resolution = range.trendResolution
        let rawTrend = try loadReportTrend(
            startEpoch: startEpoch,
            endEpoch: endEpoch,
            resolution: resolution
        )
        let summary = summarize(rawTrend, requestedSeconds: now.timeIntervalSince(startDate))
        let trend = Self.compactTrend(rawTrend, maximumPoints: 400)
        let applications = try loadApplications(startEpoch: startEpoch, endEpoch: endEpoch)
        let previous = try previousWriteTotal(
            startEpoch: startEpoch,
            endEpoch: endEpoch,
            resolution: resolution
        )
        return HistoryReport(
            range: range,
            start: Date(timeIntervalSince1970: TimeInterval(startEpoch)),
            end: now,
            summary: summary,
            trend: trend,
            applications: applications,
            previousPeriodDiskWriteBytes: previous
        )
    }

    public func storageInfo(configuration: HistoryConfiguration? = nil) -> HistoryStorageInfo {
        let configuration = configuration ?? lastConfiguration
        let databaseBytes = fileSize(fileURL)
        let walBytes = fileSize(fileURL.map { URL(fileURLWithPath: $0.path + "-wal") })
        let shmBytes = fileSize(fileURL.map { URL(fileURLWithPath: $0.path + "-shm") })
        let total = databaseBytes + walBytes + shmBytes
        let budget = configuration.budgetBytes
        let state: HistoryStorageState
        if isPausedForBudget {
            state = .paused
        } else if let lastError {
            state = .unavailable(lastError)
        } else if let lastCompactedStart {
            state = .compacted(start: lastCompactedStart)
        } else if total >= budget * 3 / 4 {
            state = .nearingLimit
        } else {
            state = .normal
        }
        return HistoryStorageInfo(
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            shmBytes: shmBytes,
            budgetBytes: budget,
            lastSavedAt: lastSavedAt,
            state: state
        )
    }

    public func clear() throws {
        do {
            if fileURL != nil {
                let connection = try requireConnection()
                guard sqlite3_wal_checkpoint_v2(
                    connection.handle,
                    nil,
                    SQLITE_CHECKPOINT_TRUNCATE,
                    nil,
                    nil
                ) == SQLITE_OK else {
                    throw databaseError("Unable to checkpoint monitoring history before clearing")
                }
            }

            try connection?.close()
            connection = nil

            if let fileURL {
                for url in [
                    URL(fileURLWithPath: fileURL.path + "-shm"),
                    URL(fileURLWithPath: fileURL.path + "-wal"),
                    fileURL
                ] where fileOperations.fileExists(at: url) {
                    try fileOperations.removeItem(at: url)
                }
            }

            let location: HistoryDatabaseLocation = fileURL.map(HistoryDatabaseLocation.file)
                ?? .memory
            let setup = try Self.openDatabase(
                location: location,
                fileOperations: fileOperations
            )
            connection = setup.connection
            resetAfterClear()
            try identityProvider.rotate()
        } catch {
            if connection == nil {
                connection = try? Self.openDatabase(
                    location: fileURL.map(HistoryDatabaseLocation.file) ?? .memory,
                    fileOperations: fileOperations
                ).connection
            }
            lastError = String(describing: error)
            throw error
        }
    }

    private func resetAfterClear() {
        lastSavedAt = nil
        lastError = nil
        lastMaintenanceError = nil
        isPausedForBudget = false
        lastCompactedStart = nil
        dailyIdentityCache.removeAll()
        globalIdentityCache = []
    }

    func setCheckpointOverrideForTesting(
        _ operation: (@Sendable () throws -> Void)?
    ) {
        checkpointOverrideForTesting = operation
    }

    var maintenanceErrorForTesting: String? { lastMaintenanceError }

    var schemaVersionForTesting: Int32 {
        get throws {
            try Self.pragmaInt(on: requireConnection().handle, name: "user_version")
        }
    }

    func applicationWriteTotalForTesting(
        startEpoch: Int64,
        resolution: Int
    ) throws -> UInt64 {
        let statement = try prepare(
            """
            SELECT COALESCE(SUM(write_bytes), 0) FROM app_bucket
            WHERE start_epoch = ? AND resolution_seconds = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind([.integer(startEpoch), .integer(Int64(resolution))], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return unsigned(sqlite3_column_int64(statement, 0))
    }

    static func storagePressureDecision(
        currentSize: Int64,
        budget: Int64
    ) -> (shouldCompact: Bool, canWrite: Bool) {
        let maintenanceHeadroom: Int64 = budget <= 32_000_000 ? 8_000_000 : 12_000_000
        let writeAllowance: Int64 = 512_000
        return (
            shouldCompact: currentSize + maintenanceHeadroom + writeAllowance >= budget,
            canWrite: currentSize + writeAllowance < budget
        )
    }

    public func performRetentionMaintenance(
        configuration: HistoryConfiguration,
        now: Date = Date()
    ) throws -> Bool {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let cutoff = Int64(configuration.retention.cutoffDate(now: now).timeIntervalSince1970)
        let minuteCutoff = max(cutoff, nowEpoch - 86_400)
        let recentMonth = Int64(
            HistoryRetention.thirtyDays.cutoffDate(now: now).timeIntervalSince1970
        )
        let quarterCutoff = configuration.retention == .oneYear
            ? max(cutoff, recentMonth)
            : cutoff
        let bucketCutoffs = [minuteCutoff, quarterCutoff, cutoff]
        let expired = try rowCount(
            """
            SELECT
              (SELECT COUNT(*) FROM system_bucket WHERE
                (resolution_seconds = 60 AND start_epoch < ?) OR
                (resolution_seconds = 900 AND start_epoch < ?) OR
                (resolution_seconds = 3600 AND start_epoch < ?)) +
              (SELECT COUNT(*) FROM app_bucket WHERE
                (resolution_seconds = 60 AND start_epoch < ?) OR
                (resolution_seconds = 900 AND start_epoch < ?) OR
                (resolution_seconds = 3600 AND start_epoch < ?)) +
              (SELECT COUNT(*) FROM device_bucket WHERE
                (resolution_seconds = 60 AND start_epoch < ?) OR
                (resolution_seconds = 900 AND start_epoch < ?) OR
                (resolution_seconds = 3600 AND start_epoch < ?)) +
              (SELECT COUNT(*) FROM app_daily WHERE day_epoch < ?)
            """,
            integers: bucketCutoffs + bucketCutoffs + bucketCutoffs
                + [localDayEpoch(containing: cutoff)]
        )
        guard expired > 0 else { return false }
        try execute("BEGIN IMMEDIATE")
        do {
            try repairCompletedSystemRollups(endingBefore: nowEpoch)
            try applyRetention(
                nowEpoch: nowEpoch,
                retention: configuration.retention
            )
            try execute("COMMIT")
            commitCount += 1
            try checkpointIfNeeded(configuration: configuration, force: true)
            try Self.protectHistoryFiles(at: fileURL, fileOperations: fileOperations)
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func insertSystem(_ bucket: HistoryMinuteBucket, resolution: Int) throws {
        try run(
            """
            INSERT OR REPLACE INTO system_bucket
            (start_epoch, resolution_seconds, observed_seconds, disk_observed_seconds,
             disk_read_bytes, disk_write_bytes, cpu_seconds, cpu_observed_seconds, cpu_peak,
             network_observed_seconds, network_receive_bytes, network_send_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .integer(bucket.startEpoch), .integer(Int64(resolution)),
                .double(bucket.observedSeconds), .double(bucket.diskObservedSeconds),
                .integer(sqliteInteger(bucket.diskReadBytes)),
                .integer(sqliteInteger(bucket.diskWriteBytes)), .double(bucket.cpuSeconds),
                .double(bucket.cpuObservedSeconds), bucket.cpuPeak.map(SQLiteValue.double) ?? .null,
                .double(bucket.networkObservedSeconds),
                .integer(sqliteInteger(bucket.networkReceiveBytes)),
                .integer(sqliteInteger(bucket.networkSendBytes))
            ]
        )
    }

    private func insertApplications(_ bucket: HistoryMinuteBucket) throws {
        let sorted = bucket.applications.sorted { $0.value.activityScore > $1.value.activityScore }
        let keep = sorted.prefix(16)
        for (identity, app) in keep {
            try insertApplication(identity: identity, app: app, start: bucket.startEpoch, resolution: 60)
        }
        if sorted.count > 16 {
            var other = MutableApplicationBucket(name: "Other")
            for (_, app) in sorted.dropFirst(16) { other.merge(app) }
            try insertApplication(identity: "other", app: other, start: bucket.startEpoch, resolution: 60)
        }
    }

    private func insertApplication(
        identity: String,
        app: MutableApplicationBucket,
        start: Int64,
        resolution: Int
    ) throws {
        try run(
            """
            INSERT OR REPLACE INTO app_bucket
            (start_epoch, resolution_seconds, app_id, name, read_bytes, write_bytes,
             cpu_time_ns, network_receive_bytes, network_send_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .integer(start), .integer(Int64(resolution)), .text(identity), .text(app.name),
                .integer(sqliteInteger(app.readBytes)), .integer(sqliteInteger(app.writeBytes)),
                .integer(sqliteInteger(app.cpuTimeNanoseconds)),
                .integer(sqliteInteger(app.networkReceiveBytes)),
                .integer(sqliteInteger(app.networkSendBytes))
            ]
        )
    }

    private func upsertDailyApplications(_ bucket: HistoryMinuteBucket) throws {
        let day = localDayEpoch(containing: bucket.startEpoch)
        var dailyIDs = try dailyIdentityCache[day] ?? Set(loadTextColumn(
            "SELECT app_id FROM app_daily WHERE day_epoch = ?",
            values: [.integer(day)]
        ))
        var globalIDs = try globalIdentityCache ?? Set(loadTextColumn(
            "SELECT DISTINCT app_id FROM app_daily",
            values: []
        ))
        for (originalIdentity, originalApp) in bucket.applications {
            let isKnown = dailyIDs.contains(originalIdentity) && globalIDs.contains(originalIdentity)
            let identity = isKnown || (dailyIDs.count < 512 && globalIDs.count < 4_096)
                ? originalIdentity
                : "other"
            var app = originalApp
            if identity == "other" { app.name = "Other" }
            try run(
                """
                INSERT INTO app_daily
                (day_epoch, app_id, name, read_bytes, write_bytes, cpu_time_ns,
                 network_receive_bytes, network_send_bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day_epoch, app_id) DO UPDATE SET
                  name = excluded.name,
                  read_bytes = MIN(9223372036854775807, read_bytes + excluded.read_bytes),
                  write_bytes = MIN(9223372036854775807, write_bytes + excluded.write_bytes),
                  cpu_time_ns = MIN(9223372036854775807, cpu_time_ns + excluded.cpu_time_ns),
                  network_receive_bytes = MIN(9223372036854775807, network_receive_bytes + excluded.network_receive_bytes),
                  network_send_bytes = MIN(9223372036854775807, network_send_bytes + excluded.network_send_bytes)
                """,
                values: [
                    .integer(day), .text(identity), .text(app.name),
                    .integer(sqliteInteger(app.readBytes)), .integer(sqliteInteger(app.writeBytes)),
                    .integer(sqliteInteger(app.cpuTimeNanoseconds)),
                    .integer(sqliteInteger(app.networkReceiveBytes)),
                    .integer(sqliteInteger(app.networkSendBytes))
                ]
            )
            dailyIDs.insert(identity)
            globalIDs.insert(identity)
        }
        dailyIdentityCache[day] = dailyIDs
        globalIdentityCache = globalIDs
    }

    private func insertDevices(_ bucket: HistoryMinuteBucket) throws {
        let sorted = bucket.devices.sorted {
            $0.value.writeBytes > $1.value.writeBytes
        }
        for (identity, device) in sorted.prefix(32) {
            try run(
                "INSERT OR REPLACE INTO device_bucket VALUES (?, 60, ?, ?, ?, ?)",
                values: [
                    .integer(bucket.startEpoch), .text(identity), .text(device.name),
                    .integer(sqliteInteger(device.readBytes)),
                    .integer(sqliteInteger(device.writeBytes))
                ]
            )
        }
    }

    private func buildRollups(endingAfter minute: Int64) throws {
        let end = minute + 60
        if end.isMultiple(of: 900) {
            try aggregateSystem(start: end - 900, end: end, resolution: 900, source: 60)
            try aggregateApplications(start: end - 900, end: end, resolution: 900, source: 60)
            try aggregateDevices(start: end - 900, end: end, resolution: 900, source: 60)
        }
        if end.isMultiple(of: 3_600) {
            try aggregateSystem(start: end - 3_600, end: end, resolution: 3_600, source: 900)
            try aggregateApplications(start: end - 3_600, end: end, resolution: 3_600, source: 900)
            try aggregateDevices(start: end - 3_600, end: end, resolution: 3_600, source: 900)
        }
        try repairCompletedSystemRollups(endingBefore: end)
    }

    private func repairCompletedSystemRollups(endingBefore end: Int64) throws {
        let quarterEnd = end - end % 900
        let repairedQuarters = try repairMissingSystemRollups(
            sourceResolution: 60,
            targetResolution: 900,
            startEpoch: 0,
            endEpoch: quarterEnd
        )

        let hourEnd = end - end % 3_600
        _ = try repairMissingSystemRollups(
            sourceResolution: 900,
            targetResolution: 3_600,
            startEpoch: 0,
            endEpoch: hourEnd
        )

        let affectedHours = Set(repairedQuarters.map {
            Self.alignedDown($0, to: 3_600)
        })
        for hourStart in affectedHours where hourStart < hourEnd {
            try aggregateSystem(
                start: hourStart,
                end: hourStart + 3_600,
                resolution: 3_600,
                source: 900
            )
        }
    }

    private func repairMissingSystemRollups(
        sourceResolution: Int,
        targetResolution: Int,
        startEpoch: Int64,
        endEpoch: Int64
    ) throws -> [Int64] {
        guard startEpoch < endEpoch else { return [] }
        let source = try loadTrend(
            startEpoch: startEpoch,
            endEpoch: endEpoch,
            resolution: sourceResolution
        )
        guard !source.isEmpty else { return [] }
        let sourceStarts = Set(source.map {
            Self.alignedDown(Int64($0.timestamp.timeIntervalSince1970), to: targetResolution)
        })
        let existing = try loadTrend(
            startEpoch: startEpoch - Int64(targetResolution),
            endEpoch: endEpoch,
            resolution: targetResolution
        )
        let existingStarts = Set(existing.map { point in
            Self.alignedDown(Int64(point.timestamp.timeIntervalSince1970), to: targetResolution)
        })
        let missingStarts = sourceStarts.subtracting(existingStarts).sorted()

        for groupStart in missingStarts {
            try aggregateSystem(
                start: groupStart,
                end: groupStart + Int64(targetResolution),
                resolution: targetResolution,
                source: sourceResolution
            )
        }
        return missingStarts
    }

    private func aggregateSystem(start: Int64, end: Int64, resolution: Int, source: Int) throws {
        try run(
            """
            INSERT OR REPLACE INTO system_bucket
            (start_epoch, resolution_seconds, observed_seconds, disk_observed_seconds,
             disk_read_bytes, disk_write_bytes, cpu_seconds, cpu_observed_seconds, cpu_peak,
             network_observed_seconds, network_receive_bytes, network_send_bytes)
            SELECT ?, ?, SUM(observed_seconds), SUM(disk_observed_seconds),
                   SUM(disk_read_bytes), SUM(disk_write_bytes),
                   SUM(cpu_seconds), SUM(cpu_observed_seconds), MAX(cpu_peak),
                   SUM(network_observed_seconds), SUM(network_receive_bytes), SUM(network_send_bytes)
            FROM system_bucket
            WHERE resolution_seconds = ? AND start_epoch >= ? AND start_epoch < ?
            HAVING COUNT(*) > 0
            """,
            values: [.integer(start), .integer(Int64(resolution)), .integer(Int64(source)), .integer(start), .integer(end)]
        )
    }

    private func aggregateApplications(start: Int64, end: Int64, resolution: Int, source: Int) throws {
        let statement = try prepare(
            """
            SELECT app_id, MAX(name), SUM(read_bytes), SUM(write_bytes), SUM(cpu_time_ns),
                   SUM(network_receive_bytes), SUM(network_send_bytes)
            FROM app_bucket
            WHERE resolution_seconds = ? AND start_epoch >= ? AND start_epoch < ?
            GROUP BY app_id
            ORDER BY SUM(read_bytes + write_bytes + network_receive_bytes + network_send_bytes) DESC
            """
        )
        bind([.integer(Int64(source)), .integer(start), .integer(end)], to: statement)
        var rows: [(String, MutableApplicationBucket)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((columnText(statement, 0), MutableApplicationBucket(
                name: columnText(statement, 1),
                readBytes: unsigned(sqlite3_column_int64(statement, 2)),
                writeBytes: unsigned(sqlite3_column_int64(statement, 3)),
                cpuTimeNanoseconds: unsigned(sqlite3_column_int64(statement, 4)),
                networkReceiveBytes: unsigned(sqlite3_column_int64(statement, 5)),
                networkSendBytes: unsigned(sqlite3_column_int64(statement, 6))
            )))
        }
        sqlite3_finalize(statement)
        try run(
            "DELETE FROM app_bucket WHERE start_epoch = ? AND resolution_seconds = ?",
            values: [.integer(start), .integer(Int64(resolution))]
        )
        let limit = resolution == 900 ? 32 : 50
        var other = MutableApplicationBucket(name: "Other")
        for (identity, app) in rows where identity == "other" { other.merge(app) }
        let candidates = rows.filter { $0.0 != "other" }
        for (identity, app) in candidates.prefix(limit) {
            try insertApplication(identity: identity, app: app, start: start, resolution: resolution)
        }
        for (_, app) in candidates.dropFirst(limit) { other.merge(app) }
        if other.activityScore > 0 || other.cpuTimeNanoseconds > 0 {
            try insertApplication(identity: "other", app: other, start: start, resolution: resolution)
        }
    }

    private func aggregateDevices(start: Int64, end: Int64, resolution: Int, source: Int) throws {
        try run(
            """
            INSERT OR REPLACE INTO device_bucket
            SELECT ?, ?, device_id, MAX(name), SUM(read_bytes), SUM(write_bytes)
            FROM device_bucket
            WHERE resolution_seconds = ? AND start_epoch >= ? AND start_epoch < ?
            GROUP BY device_id
            """,
            values: [.integer(start), .integer(Int64(resolution)), .integer(Int64(source)), .integer(start), .integer(end)]
        )
    }

    private func applyRetention(nowEpoch: Int64, retention: HistoryRetention) throws {
        let now = Date(timeIntervalSince1970: TimeInterval(nowEpoch))
        let cutoff = Int64(retention.cutoffDate(now: now).timeIntervalSince1970)
        let minuteCutoff = max(cutoff, nowEpoch - 86_400)
        let recentMonth = Int64(
            HistoryRetention.thirtyDays.cutoffDate(now: now).timeIntervalSince1970
        )
        let quarterCutoff = retention == .oneYear ? max(cutoff, recentMonth) : cutoff
        for table in ["system_bucket", "app_bucket", "device_bucket"] {
            try run(
                "DELETE FROM \(table) WHERE (resolution_seconds = 60 AND start_epoch < ?) OR (resolution_seconds = 900 AND start_epoch < ?) OR (resolution_seconds = 3600 AND start_epoch < ?)",
                values: [.integer(minuteCutoff), .integer(quarterCutoff), .integer(cutoff)]
            )
        }
        let cutoffDay = localDayEpoch(containing: cutoff)
        try run("DELETE FROM app_daily WHERE day_epoch < ?", values: [.integer(cutoffDay)])
        dailyIdentityCache = dailyIdentityCache.filter { $0.key >= cutoffDay }
    }

    private func compactApplicationDetail(nowEpoch: Int64, retention: HistoryRetention) throws {
        try run(
            "DELETE FROM app_bucket WHERE resolution_seconds = 60 AND start_epoch < ?",
            values: [.integer(nowEpoch - 6 * 3_600)]
        )
        if retention != .sevenDays {
            try run(
                "DELETE FROM app_bucket WHERE resolution_seconds = 900 AND start_epoch < ?",
                values: [.integer(nowEpoch - 7 * 86_400)]
            )
        }
        if retention == .oneYear {
            try run(
                "DELETE FROM app_bucket WHERE resolution_seconds = 3600 AND start_epoch < ?",
                values: [.integer(nowEpoch - 30 * 86_400)]
            )
        }
        try execute("PRAGMA incremental_vacuum(128)")
    }

    private func isMinuteCommitted(_ startEpoch: Int64) throws -> Bool {
        try rowCount(
            "SELECT COUNT(*) FROM system_bucket WHERE start_epoch = ? AND resolution_seconds = 60",
            integers: [startEpoch]
        ) > 0
    }

    private func loadReportTrend(
        startEpoch: Int64,
        endEpoch: Int64,
        resolution: Int,
        referenceEpoch: Int64? = nil
    ) throws -> [HistoryTrendPoint] {
        let referenceEpoch = referenceEpoch ?? endEpoch
        let minuteStart = max(startEpoch, alignedUp(referenceEpoch - 86_400, to: 900))
        let quarterRetentionStart = Int64(
            HistoryRetention.thirtyDays
                .cutoffDate(now: Date(timeIntervalSince1970: TimeInterval(referenceEpoch)))
                .timeIntervalSince1970
        )
        let quarterStart = max(startEpoch, alignedUp(quarterRetentionStart, to: 3_600))

        var canonical: [HistoryTrendPoint] = []
        let hourlyEnd = min(endEpoch, quarterStart)
        if startEpoch < hourlyEnd {
            canonical.append(contentsOf: try loadTrend(
                startEpoch: startEpoch,
                endEpoch: hourlyEnd,
                resolution: 3_600
            ))
        }

        let quarterRangeStart = max(startEpoch, quarterStart)
        let quarterEnd = min(endEpoch, minuteStart)
        if quarterRangeStart < quarterEnd {
            canonical.append(contentsOf: try loadTrend(
                startEpoch: quarterRangeStart,
                endEpoch: quarterEnd,
                resolution: 900
            ))
        }

        let minuteRangeStart = max(startEpoch, minuteStart)
        if minuteRangeStart < endEpoch {
            canonical.append(contentsOf: try loadTrend(
                startEpoch: minuteRangeStart,
                endEpoch: endEpoch,
                resolution: 60
            ))
        }
        return Self.aggregateTrend(canonical, resolution: resolution)
    }

    private static func aggregateTrend(
        _ points: [HistoryTrendPoint],
        resolution: Int
    ) -> [HistoryTrendPoint] {
        guard resolution > 60, !points.isEmpty else { return points }
        var result: [HistoryTrendPoint] = []
        var group: [HistoryTrendPoint] = []
        var groupKey: Int64?

        func appendGroup(_ group: [HistoryTrendPoint], to result: inout [HistoryTrendPoint]) {
            guard let first = group.first else { return }
            result.append(aggregateTrendPoints(
                group,
                timestamp: first.timestamp,
                startsNewSegment: false
            ))
        }

        for point in points {
            let epoch = Int64(point.timestamp.timeIntervalSince1970)
            let key = epoch - epoch % Int64(resolution)
            if let groupKey, groupKey != key {
                appendGroup(group, to: &result)
                group.removeAll(keepingCapacity: true)
            }
            groupKey = key
            group.append(point)
        }
        appendGroup(group, to: &result)
        return result
    }

    private func alignedUp(_ epoch: Int64, to resolution: Int64) -> Int64 {
        let remainder = epoch % resolution
        return remainder == 0 ? epoch : epoch + resolution - remainder
    }

    private static func alignedDown(_ epoch: Int64, to resolution: Int) -> Int64 {
        epoch - epoch % Int64(resolution)
    }

    private func loadTrend(startEpoch: Int64, endEpoch: Int64, resolution: Int) throws -> [HistoryTrendPoint] {
        let statement = try prepare(
            """
            SELECT start_epoch, observed_seconds, disk_observed_seconds,
                   disk_read_bytes, disk_write_bytes,
                   cpu_seconds, cpu_observed_seconds, cpu_peak,
                   network_observed_seconds, network_receive_bytes, network_send_bytes
            FROM system_bucket
            WHERE resolution_seconds = ? AND start_epoch >= ? AND start_epoch < ?
            ORDER BY start_epoch
            """
        )
        defer { sqlite3_finalize(statement) }
        bind([.integer(Int64(resolution)), .integer(startEpoch), .integer(endEpoch)], to: statement)
        var result: [HistoryTrendPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let observed = sqlite3_column_double(statement, 1)
            let diskObserved = sqlite3_column_double(statement, 2)
            let cpuObserved = sqlite3_column_double(statement, 6)
            let networkObserved = sqlite3_column_double(statement, 8)
            result.append(HistoryTrendPoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                duration: observed,
                diskObservedSeconds: diskObserved,
                diskReadBytes: unsigned(sqlite3_column_int64(statement, 3)),
                diskWriteBytes: unsigned(sqlite3_column_int64(statement, 4)),
                networkObservedSeconds: networkObserved,
                networkReceiveBytes: unsigned(sqlite3_column_int64(statement, 9)),
                networkSendBytes: unsigned(sqlite3_column_int64(statement, 10)),
                cpuObservedSeconds: cpuObserved,
                averageCPUPercent: cpuObserved > 0 ? sqlite3_column_double(statement, 5) / cpuObserved * 100 : nil,
                peakCPUPercent: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7)
            ))
        }
        return result
    }

    private func summarize(_ trend: [HistoryTrendPoint], requestedSeconds: TimeInterval) -> HistorySummary {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var receive: UInt64 = 0
        var send: UInt64 = 0
        var observed = 0.0
        var diskObserved = 0.0
        var networkObserved = 0.0
        var weightedCPU = 0.0
        var cpuObserved = 0.0
        var peakCPU: Double?
        for point in trend {
            read = read.addingClamped(point.diskReadBytes)
            write = write.addingClamped(point.diskWriteBytes)
            receive = receive.addingClamped(point.networkReceiveBytes)
            send = send.addingClamped(point.networkSendBytes)
            observed += point.duration
            diskObserved += point.diskObservedSeconds
            networkObserved += point.networkObservedSeconds
            if let cpu = point.averageCPUPercent {
                weightedCPU += cpu * point.cpuObservedSeconds
                cpuObserved += point.cpuObservedSeconds
            }
            if let peak = point.peakCPUPercent { peakCPU = max(peakCPU ?? peak, peak) }
        }
        return HistorySummary(
            diskReadBytes: read,
            diskWriteBytes: write,
            networkReceiveBytes: receive,
            networkSendBytes: send,
            averageCPUPercent: cpuObserved > 0 ? weightedCPU / cpuObserved : nil,
            peakCPUPercent: peakCPU,
            observedSeconds: observed,
            coverage: Self.coverage(observed, requestedSeconds: requestedSeconds),
            diskObservedSeconds: diskObserved,
            networkObservedSeconds: networkObserved,
            cpuObservedSeconds: cpuObserved,
            diskCoverage: Self.coverage(diskObserved, requestedSeconds: requestedSeconds),
            networkCoverage: Self.coverage(networkObserved, requestedSeconds: requestedSeconds),
            cpuCoverage: Self.coverage(cpuObserved, requestedSeconds: requestedSeconds)
        )
    }

    private func loadApplications(startEpoch: Int64, endEpoch: Int64) throws -> [HistoryApplicationReport] {
        let startDay = localDayEpoch(containing: startEpoch)
        let endDay = localDayEpoch(containing: endEpoch)
        let statement = try prepare(
            """
            SELECT app_id, MAX(name), SUM(read_bytes), SUM(write_bytes), SUM(cpu_time_ns),
                   SUM(network_receive_bytes), SUM(network_send_bytes)
            FROM app_daily WHERE day_epoch >= ? AND day_epoch <= ?
            GROUP BY app_id ORDER BY SUM(write_bytes) DESC LIMIT 50
            """
        )
        defer { sqlite3_finalize(statement) }
        bind([.integer(startDay), .integer(endDay)], to: statement)
        var result: [HistoryApplicationReport] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(HistoryApplicationReport(
                id: columnText(statement, 0), name: columnText(statement, 1),
                readBytes: unsigned(sqlite3_column_int64(statement, 2)),
                writeBytes: unsigned(sqlite3_column_int64(statement, 3)),
                networkReceiveBytes: unsigned(sqlite3_column_int64(statement, 5)),
                networkSendBytes: unsigned(sqlite3_column_int64(statement, 6)),
                cpuTimeNanoseconds: unsigned(sqlite3_column_int64(statement, 4))
            ))
        }
        return result
    }

    private func previousWriteTotal(startEpoch: Int64, endEpoch: Int64, resolution: Int) throws -> UInt64? {
        let duration = endEpoch - startEpoch
        let previousStart = startEpoch - duration
        let trend = try loadReportTrend(
            startEpoch: previousStart,
            endEpoch: startEpoch,
            resolution: resolution,
            referenceEpoch: endEpoch
        )
        return Self.qualifyingPreviousWriteTotal(
            trend,
            requestedSeconds: TimeInterval(duration)
        )
    }

    static func qualifyingPreviousWriteTotal(
        _ trend: [HistoryTrendPoint],
        requestedSeconds: TimeInterval
    ) -> UInt64? {
        let diskObserved = trend.reduce(0) { $0 + $1.diskObservedSeconds }
        guard coverage(diskObserved, requestedSeconds: requestedSeconds) >= 0.7 else { return nil }
        return trend.reduce(UInt64(0)) { $0.addingClamped($1.diskWriteBytes) }
    }

    private static func coverage(
        _ observedSeconds: TimeInterval,
        requestedSeconds: TimeInterval
    ) -> Double {
        requestedSeconds > 0 ? min(1, observedSeconds / requestedSeconds) : 0
    }

    private func checkpointIfNeeded(
        configuration: HistoryConfiguration,
        force: Bool = false
    ) throws {
        guard let fileURL else { return }
        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        let hardLimit: Int64 = configuration.budgetBytes <= 32_000_000 ? 4 * 1_024 * 1_024 : 8 * 1_024 * 1_024
        guard force || fileSize(walURL) >= hardLimit else { return }
        let connection = try requireConnection()
        guard sqlite3_wal_checkpoint_v2(connection.handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
            throw databaseError("Unable to checkpoint monitoring history")
        }
    }

    private func rowCount(_ sql: String, integers: [Int64]) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(integers.map(SQLiteValue.integer), to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func loadTextColumn(_ sql: String, values: [SQLiteValue]) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(columnText(statement, 0)) }
        return result
    }

    private func requireConnection() throws -> SQLiteConnection {
        guard let connection else {
            throw HistoryDatabaseError(message: "Monitoring history is not open")
        }
        return connection
    }

    private func execute(_ sql: String) throws {
        try Self.execute(on: requireConnection().handle, sql: sql)
    }

    private static func execute(on handle: OpaquePointer?, sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite operation failed"
            sqlite3_free(error)
            let code = sqlite3_errcode(handle)
            throw HistoryDatabaseError(
                message: message,
                isRetryable: isRetryableSQLiteCode(code)
            )
        }
    }

    private static func pragmaInt(on handle: OpaquePointer, name: String) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoryDatabaseError(message: "Unable to read monitoring history schema")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoryDatabaseError(message: "Unable to read monitoring history schema")
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func tableExists(_ name: String, on handle: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw HistoryDatabaseError(message: "Unable to inspect monitoring history schema")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(
            statement,
            1,
            name,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnExists(
        _ column: String,
        in table: String,
        on handle: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoryDatabaseError(message: "Unable to inspect monitoring history columns")
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: text) == column { return true }
        }
        return false
    }

    private func run(_ sql: String, values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError("SQLite write failed") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let connection = try requireConnection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError("SQLite prepare failed") }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func databaseError(_ prefix: String) -> HistoryDatabaseError {
        guard let connection else {
            return HistoryDatabaseError(message: "\(prefix): monitoring history is not open")
        }
        let detail = String(cString: sqlite3_errmsg(connection.handle))
        return HistoryDatabaseError(
            message: "\(prefix): \(detail)",
            isRetryable: Self.isRetryableSQLiteCode(sqlite3_errcode(connection.handle))
        )
    }

    private static func isRetryableSQLiteCode(_ code: Int32) -> Bool {
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_BUSY
            || primaryCode == SQLITE_LOCKED
            || primaryCode == SQLITE_IOERR
            || primaryCode == SQLITE_INTERRUPT
    }

    private func fileSize(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        return fileOperations.fileSize(at: url)
    }

    private func totalFileSize() -> Int64 {
        guard let fileURL else { return 0 }
        return fileSize(fileURL)
            + fileSize(URL(fileURLWithPath: fileURL.path + "-wal"))
            + fileSize(URL(fileURLWithPath: fileURL.path + "-shm"))
    }

    private static func protectHistoryFiles(
        at fileURL: URL?,
        fileOperations: any HistoryFileOperating
    ) throws {
        guard let fileURL else { return }
        for url in [
            fileURL,
            URL(fileURLWithPath: fileURL.path + "-wal"),
            URL(fileURLWithPath: fileURL.path + "-shm")
        ] where fileOperations.fileExists(at: url) {
            try fileOperations.setPermissions(0o600, at: url)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func unsigned(_ value: Int64) -> UInt64 { UInt64(max(0, value)) }
    private func sqliteInteger(_ value: UInt64) -> Int64 { Int64(min(value, UInt64(Int64.max))) }

    private func localDayEpoch(containing epoch: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    static func compactTrend(
        _ points: [HistoryTrendPoint],
        maximumPoints: Int
    ) -> [HistoryTrendPoint] {
        guard points.count > maximumPoints, maximumPoints > 0 else { return points }
        var runs: [[HistoryTrendPoint]] = []
        for point in points {
            if let previous = runs.last?.last {
                let expectedStep = max(previous.duration, point.duration)
                if point.timestamp.timeIntervalSince(previous.timestamp) > expectedStep * 1.8 {
                    runs.append([point])
                } else {
                    runs[runs.count - 1].append(point)
                }
            } else {
                runs.append([point])
            }
        }

        if runs.count > maximumPoints {
            return (0..<maximumPoints).compactMap { outputIndex in
                let lower = outputIndex * runs.count / maximumPoints
                let upper = (outputIndex + 1) * runs.count / maximumPoints
                let group = runs[lower..<max(lower + 1, upper)].flatMap { $0 }
                guard !group.isEmpty else { return nil }
                let preserveTrailingEndpoint = outputIndex == maximumPoints - 1
                return aggregateTrendPoints(
                    group,
                    timestamp: preserveTrailingEndpoint ? group.last!.timestamp : group.first!.timestamp,
                    startsNewSegment: outputIndex > 0
                )
            }
        }

        var groupSize = max(1, Int(ceil(Double(points.count) / Double(maximumPoints))))
        while runs.count <= maximumPoints,
              runs.reduce(0, { $0 + Int(ceil(Double($1.count) / Double(groupSize))) }) > maximumPoints {
            groupSize += 1
        }

        var compacted: [HistoryTrendPoint] = []
        for (runIndex, run) in runs.enumerated() {
            for start in stride(from: 0, to: run.count, by: groupSize) {
                let group = run[start..<min(run.count, start + groupSize)]
                compacted.append(aggregateTrendPoints(
                    Array(group),
                    timestamp: group.first!.timestamp,
                    startsNewSegment: runIndex > 0 && start == 0
                ))
            }
        }
        return compacted
    }

    private static func aggregateTrendPoints(
        _ points: [HistoryTrendPoint],
        timestamp: Date,
        startsNewSegment: Bool
    ) -> HistoryTrendPoint {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var receive: UInt64 = 0
        var send: UInt64 = 0
        var duration = 0.0
        var diskObserved = 0.0
        var networkObserved = 0.0
        var weightedCPU = 0.0
        var cpuObserved = 0.0
        var peakCPU: Double?
        for point in points {
            read = read.addingClamped(point.diskReadBytes)
            write = write.addingClamped(point.diskWriteBytes)
            receive = receive.addingClamped(point.networkReceiveBytes)
            send = send.addingClamped(point.networkSendBytes)
            duration += point.duration
            diskObserved += point.diskObservedSeconds
            networkObserved += point.networkObservedSeconds
            if let cpu = point.averageCPUPercent {
                weightedCPU += cpu * point.cpuObservedSeconds
                cpuObserved += point.cpuObservedSeconds
            }
            if let peak = point.peakCPUPercent { peakCPU = max(peakCPU ?? peak, peak) }
        }
        return HistoryTrendPoint(
            timestamp: timestamp,
            duration: duration,
            diskObservedSeconds: diskObserved,
            diskReadBytes: read,
            diskWriteBytes: write,
            networkObservedSeconds: networkObserved,
            networkReceiveBytes: receive,
            networkSendBytes: send,
            cpuObservedSeconds: cpuObserved,
            averageCPUPercent: cpuObserved > 0 ? weightedCPU / cpuObserved : nil,
            peakCPUPercent: peakCPU,
            startsNewSegment: startsNewSegment
        )
    }

    private enum SQLiteValue {
        case integer(Int64)
        case double(Double)
        case text(String)
        case null
    }

    private static let connectionPragmas = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    PRAGMA busy_timeout=2000;
    PRAGMA wal_autocheckpoint=0;
    PRAGMA auto_vacuum=INCREMENTAL;
    """

    private static let currentSchema = """
    CREATE TABLE IF NOT EXISTS system_bucket (
      start_epoch INTEGER NOT NULL, resolution_seconds INTEGER NOT NULL,
      observed_seconds REAL NOT NULL, disk_observed_seconds REAL NOT NULL,
      disk_read_bytes INTEGER NOT NULL,
      disk_write_bytes INTEGER NOT NULL, cpu_seconds REAL NOT NULL,
      cpu_observed_seconds REAL NOT NULL, cpu_peak REAL,
      network_observed_seconds REAL NOT NULL,
      network_receive_bytes INTEGER NOT NULL, network_send_bytes INTEGER NOT NULL,
      PRIMARY KEY (start_epoch, resolution_seconds)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS app_bucket (
      start_epoch INTEGER NOT NULL, resolution_seconds INTEGER NOT NULL,
      app_id TEXT NOT NULL, name TEXT NOT NULL, read_bytes INTEGER NOT NULL,
      write_bytes INTEGER NOT NULL, cpu_time_ns INTEGER NOT NULL,
      network_receive_bytes INTEGER NOT NULL, network_send_bytes INTEGER NOT NULL,
      PRIMARY KEY (start_epoch, resolution_seconds, app_id)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS app_daily (
      day_epoch INTEGER NOT NULL, app_id TEXT NOT NULL, name TEXT NOT NULL,
      read_bytes INTEGER NOT NULL, write_bytes INTEGER NOT NULL,
      cpu_time_ns INTEGER NOT NULL, network_receive_bytes INTEGER NOT NULL,
      network_send_bytes INTEGER NOT NULL, PRIMARY KEY (day_epoch, app_id)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS device_bucket (
      start_epoch INTEGER NOT NULL, resolution_seconds INTEGER NOT NULL,
      device_id TEXT NOT NULL, name TEXT NOT NULL, read_bytes INTEGER NOT NULL,
      write_bytes INTEGER NOT NULL,
      PRIMARY KEY (start_epoch, resolution_seconds, device_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS system_bucket_resolution_time
      ON system_bucket(resolution_seconds, start_epoch);
    CREATE INDEX IF NOT EXISTS app_daily_time ON app_daily(day_epoch);
    """
}
