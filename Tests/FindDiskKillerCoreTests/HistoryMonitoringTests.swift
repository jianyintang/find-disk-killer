import Foundation
import SQLite3
import Testing
@testable import FindDiskKillerCore

@Test func historyRetentionUsesBoundedAutomaticBudgets() {
    #expect(HistoryRetention.sevenDays.automaticBudgetBytes == 32_000_000)
    #expect(HistoryRetention.thirtyDays.automaticBudgetBytes == 64_000_000)
    #expect(HistoryRetention.oneYear.automaticBudgetBytes == 128_000_000)
    #expect(HistoryRetention.oneYear.cutoffDays == 365)
}

@Test func historyRetentionUsesLocalCalendarDaysAcrossDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 10, hour: 14
    )))
    let cutoff = HistoryRetention.sevenDays.cutoffDate(now: now, calendar: calendar)
    let components = calendar.dateComponents([.year, .month, .day, .hour], from: cutoff)
    #expect(components.year == 2026)
    #expect(components.month == 3)
    #expect(components.day == 4)
    #expect(components.hour == 0)
}

@Test func unavailableMetricsKeepIndependentCoverageInsteadOfRecordingZeroes() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    await recorder.record(HistorySample(
        timestamp: start,
        duration: 60,
        diskReadBytes: 0,
        diskWriteBytes: 0,
        diskStatsAvailable: false,
        cpuPercent: 20,
        networkReceiveBytes: 30,
        networkSendBytes: 40,
        networkStatsAvailable: true,
        applications: [],
        devices: []
    ))
    await recorder.record(HistorySample(
        timestamp: start.addingTimeInterval(60),
        duration: 60,
        diskReadBytes: 10,
        diskWriteBytes: 20,
        diskStatsAvailable: true,
        cpuPercent: nil,
        networkReceiveBytes: 0,
        networkSendBytes: 0,
        networkStatsAvailable: false,
        applications: [],
        devices: []
    ))
    await recorder.flush()

    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(120)
    )
    #expect(report.summary.diskObservedSeconds == 60)
    #expect(report.summary.networkObservedSeconds == 60)
    #expect(report.summary.cpuObservedSeconds == 60)
    #expect(report.trend.reduce(0) { $0 + $1.diskObservedSeconds } == 60)
    #expect(report.trend.reduce(0) { $0 + $1.networkObservedSeconds } == 60)
}

@Test func previousPeriodComparisonRequiresSeventyPercentDiskCoverage() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let partial = [HistoryTrendPoint(
        timestamp: start,
        duration: 60,
        diskObservedSeconds: 60,
        diskReadBytes: 0,
        diskWriteBytes: 10,
        networkObservedSeconds: 60,
        networkReceiveBytes: 0,
        networkSendBytes: 0,
        averageCPUPercent: 10,
        peakCPUPercent: 10
    )]

    #expect(HistoryDatabase.qualifyingPreviousWriteTotal(
        partial,
        requestedSeconds: 100
    ) == nil)
    #expect(HistoryDatabase.qualifyingPreviousWriteTotal(
        partial,
        requestedSeconds: 80
    ) == 10)
}

@Test func sevenDayBudgetCompactsBeforeTheMaintenanceHeadroomWouldPauseWrites() {
    let decision = HistoryDatabase.storagePressureDecision(
        currentSize: 23_600_000,
        budget: 32_000_000
    )
    #expect(decision.shouldCompact)
    #expect(decision.canWrite)
}

@Test func unversionedHistorySchemaMigratesTransactionallyAndPreservesTotals() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "legacy.sqlite3")
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let databaseHandle = try #require(handle)
    let legacySQL = """
    CREATE TABLE system_bucket (
      start_epoch INTEGER NOT NULL, resolution_seconds INTEGER NOT NULL,
      observed_seconds REAL NOT NULL, disk_read_bytes INTEGER NOT NULL,
      disk_write_bytes INTEGER NOT NULL, cpu_seconds REAL NOT NULL,
      cpu_observed_seconds REAL NOT NULL, cpu_peak REAL,
      network_receive_bytes INTEGER NOT NULL, network_send_bytes INTEGER NOT NULL,
      PRIMARY KEY (start_epoch, resolution_seconds)
    ) WITHOUT ROWID;
    INSERT INTO system_bucket VALUES (1800000000, 60, 60, 4, 8, 6, 60, 12, 16, 32);
    """
    #expect(sqlite3_exec(databaseHandle, legacySQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(databaseHandle)

    let database = try HistoryDatabase(location: .file(url))
    #expect(try await database.schemaVersionForTesting == 1)
    let report = try await database.report(
        range: .sevenDays,
        now: Date(timeIntervalSince1970: 1_800_000_060)
    )
    #expect(report.summary.diskWriteBytes == 8)
    #expect(report.summary.diskObservedSeconds == 60)
    #expect(report.summary.networkObservedSeconds == 60)

    let reopened = try HistoryDatabase(location: .file(url))
    #expect(try await reopened.schemaVersionForTesting == 1)
}

@Test func failedHistoryMigrationRollsBackSchemaChanges() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "broken-legacy.sqlite3")
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let databaseHandle = try #require(handle)
    let legacySQL = """
    CREATE TABLE system_bucket (
      start_epoch INTEGER NOT NULL, resolution_seconds INTEGER NOT NULL,
      observed_seconds REAL NOT NULL, disk_read_bytes INTEGER NOT NULL,
      disk_write_bytes INTEGER NOT NULL, cpu_seconds REAL NOT NULL,
      cpu_observed_seconds REAL NOT NULL, cpu_peak REAL,
      network_receive_bytes INTEGER NOT NULL, network_send_bytes INTEGER NOT NULL,
      PRIMARY KEY (start_epoch, resolution_seconds)
    ) WITHOUT ROWID;
    CREATE VIEW app_daily AS SELECT 1 AS incompatible_fixture;
    """
    #expect(sqlite3_exec(databaseHandle, legacySQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(databaseHandle)

    #expect(throws: (any Error).self) {
        _ = try HistoryDatabase(location: .file(url))
    }

    var inspectionHandle: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &inspectionHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    let inspection = try #require(inspectionHandle)
    defer { sqlite3_close(inspection) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(
        inspection,
        "SELECT name FROM pragma_table_info('system_bucket') WHERE name = 'disk_observed_seconds'",
        -1,
        &statement,
        nil
    ) == SQLITE_OK)
    let columnStatement = try #require(statement)
    defer { sqlite3_finalize(columnStatement) }
    #expect(sqlite3_step(columnStatement) == SQLITE_DONE)
}

@Test func newerHistorySchemaIsRejectedWithoutBeingModified() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "future.sqlite3")
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let databaseHandle = try #require(handle)
    #expect(sqlite3_exec(databaseHandle, "PRAGMA user_version = 2", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(databaseHandle)

    #expect(throws: (any Error).self) {
        _ = try HistoryDatabase(location: .file(url))
    }

    var inspection: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &inspection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    let inspectionHandle = try #require(inspection)
    defer { sqlite3_close(inspectionHandle) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(inspectionHandle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    let versionStatement = try #require(statement)
    defer { sqlite3_finalize(versionStatement) }
    #expect(sqlite3_step(versionStatement) == SQLITE_ROW)
    #expect(sqlite3_column_int(versionStatement, 0) == 2)
}

@Test func oneSecondSamplesCommitExactlyOncePerMinute() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    for second in 0..<900 {
        await recorder.record(.fixture(
            at: start.addingTimeInterval(TimeInterval(second)),
            duration: 1,
            diskWriteBytes: 10
        ))
    }
    await recorder.flush()

    #expect(await database.commitCount == 15)
    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(900)
    )
    #expect(report.summary.diskWriteBytes == 9_000)
    #expect(report.trend.count == 1)
}

@Test func twoSecondSamplesConserveTheSameTotalsAndTransactions() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    for sample in 0..<450 {
        await recorder.record(.fixture(
            at: start.addingTimeInterval(TimeInterval(sample * 2)),
            duration: 2,
            diskWriteBytes: 20
        ))
    }
    await recorder.flush()

    #expect(await database.commitCount == 15)
    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(900)
    )
    #expect(report.summary.diskWriteBytes == 9_000)
}

@Test func sevenDayReportIncludesTheUnrolledMinuteTailExactlyOnce() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    for minute in 0..<16 {
        await recorder.record(.fixture(
            at: start.addingTimeInterval(TimeInterval(minute * 60)),
            duration: 60,
            diskWriteBytes: 1
        ))
    }
    await recorder.flush()

    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(16 * 60)
    )
    #expect(report.summary.diskWriteBytes == 16)
    #expect(report.trend.map(\.diskWriteBytes) == [15, 1])
}

@Test func thirtyDayReportIncludesTheUnrolledMinuteTailExactlyOnce() async throws {
    let database = try HistoryDatabase(location: .memory)
    let configuration = HistoryConfiguration(isEnabled: true, retention: .thirtyDays)
    let recorder = HistoryRecorder(database: database, configuration: configuration)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    for minute in 0..<61 {
        await recorder.record(.fixture(
            at: start.addingTimeInterval(TimeInterval(minute * 60)),
            duration: 60,
            diskWriteBytes: 1
        ))
    }
    await recorder.flush()

    let report = try await database.report(
        range: .thirtyDays,
        now: start.addingTimeInterval(61 * 60)
    )
    #expect(report.summary.diskWriteBytes == 61)
    #expect(report.trend.map(\.diskWriteBytes) == [60, 1])
}

@Test func longerReportsDoNotLoseRecentDataWhenARollupBoundaryWasMissed() async throws {
    let database = try HistoryDatabase(location: .memory)
    let configuration = HistoryConfiguration(isEnabled: true, retention: .oneYear)
    let recorder = HistoryRecorder(database: database, configuration: configuration)
    let reference = Int64(1_800_000_000)
    let hourStart = reference - reference % 3_600

    // Commit one complete hour so an hourly rollup exists, then skip the minute
    // that would have triggered the next hourly rollup, as happens across sleep.
    for minute in 0..<119 {
        await recorder.record(.fixture(
            at: Date(timeIntervalSince1970: TimeInterval(hourStart + Int64(minute * 60))),
            duration: 60,
            diskWriteBytes: 1
        ))
    }
    for minute in 120..<122 {
        await recorder.record(.fixture(
            at: Date(timeIntervalSince1970: TimeInterval(hourStart + Int64(minute * 60))),
            duration: 60,
            diskWriteBytes: 1
        ))
    }
    await recorder.flush()

    let now = Date(timeIntervalSince1970: TimeInterval(hourStart + 122 * 60))
    let sevenDays = try await database.report(range: .sevenDays, now: now)
    let thirtyDays = try await database.report(range: .thirtyDays, now: now)
    let oneYear = try await database.report(range: .oneYear, now: now)

    #expect(sevenDays.summary.diskWriteBytes == 121)
    #expect(thirtyDays.summary.diskWriteBytes == sevenDays.summary.diskWriteBytes)
    #expect(oneYear.summary.diskWriteBytes == thirtyDays.summary.diskWriteBytes)

    for minute in 0..<3 {
        _ = try await database.performRetentionMaintenance(
            configuration: configuration,
            now: now.addingTimeInterval(86_400 + TimeInterval(minute * 60))
        )
    }
    let afterMinuteRetention = now.addingTimeInterval(2 * 86_400)
    _ = try await database.performRetentionMaintenance(
        configuration: configuration,
        now: afterMinuteRetention
    )
    let retainedThirtyDays = try await database.report(
        range: .thirtyDays,
        now: afterMinuteRetention
    )
    #expect(retainedThirtyDays.summary.diskWriteBytes == 121)

    let afterQuarterRetention = now.addingTimeInterval(31 * 86_400)
    _ = try await database.performRetentionMaintenance(
        configuration: configuration,
        now: afterQuarterRetention
    )
    let retainedOneYear = try await database.report(range: .oneYear, now: afterQuarterRetention)
    #expect(retainedOneYear.summary.diskWriteBytes == 121)
}

@Test func dailyApplicationRankingRemainsExactBeyondMinuteTopK() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var applications: [HistoryApplicationSample] = []
    for index in 0..<20 {
        let ordinal = UInt64(index + 1)
        applications.append(HistoryApplicationSample(
            identity: "app-\(index)",
            name: "Application \(index)",
            readBytes: ordinal,
            writeBytes: ordinal * 10,
            cpuTimeNanoseconds: ordinal * 1_000_000,
            networkReceiveBytes: 0,
            networkSendBytes: 0
        ))
    }
    await recorder.record(HistorySample(
        timestamp: start,
        duration: 60,
        diskReadBytes: 0,
        diskWriteBytes: 2_100,
        cpuPercent: 10,
        networkReceiveBytes: 0,
        networkSendBytes: 0,
        applications: applications,
        devices: []
    ))
    await recorder.flush()

    let report = try await database.report(range: .sevenDays, now: start.addingTimeInterval(60))
    #expect(report.applications.count == 20)
    #expect(report.applications.reduce(UInt64(0)) { $0 + $1.writeBytes } == 2_100)
    #expect(report.applications.first?.name == "Application 19")
}

@Test func trendCompactionConservesTotalsAndPeak() {
    let points = (0..<801).map { index in
        HistoryTrendPoint(
            timestamp: Date(timeIntervalSince1970: TimeInterval(index * 900)),
            duration: 900,
            diskReadBytes: 2,
            diskWriteBytes: 3,
            networkReceiveBytes: 4,
            networkSendBytes: 5,
            averageCPUPercent: 10,
            peakCPUPercent: index == 400 ? 88 : 20
        )
    }
    let compacted = HistoryDatabase.compactTrend(points, maximumPoints: 400)
    #expect(compacted.count <= 400)
    #expect(compacted.reduce(UInt64(0)) { $0 + $1.diskWriteBytes } == 2_403)
    #expect(compacted.compactMap(\.peakCPUPercent).max() == 88)
    #expect(compacted.reduce(0) { $0 + $1.duration } == 720_900)
}

@Test func trendCompactionPreservesMissingTimeAsANewSegment() {
    var points = (0..<500).map { index in
        HistoryTrendPoint(
            timestamp: Date(timeIntervalSince1970: TimeInterval(index * 3_600)),
            duration: 3_600,
            diskReadBytes: 1,
            diskWriteBytes: 1,
            networkReceiveBytes: 1,
            networkSendBytes: 1,
            averageCPUPercent: 10,
            peakCPUPercent: 10
        )
    }
    points.append(contentsOf: (0..<500).map { index in
        HistoryTrendPoint(
            timestamp: Date(timeIntervalSince1970: TimeInterval((index + 512) * 3_600)),
            duration: 3_600,
            diskReadBytes: 1,
            diskWriteBytes: 1,
            networkReceiveBytes: 1,
            networkSendBytes: 1,
            averageCPUPercent: 10,
            peakCPUPercent: 10
        )
    })

    let compacted = HistoryDatabase.compactTrend(points, maximumPoints: 400)

    #expect(compacted.count <= 400)
    #expect(compacted.filter(\.startsNewSegment).count == 1)
    #expect(compacted.reduce(UInt64(0)) { $0 + $1.diskWriteBytes } == 1_000)
}

@Test func trendCompactionKeepsHighlyFragmentedHistoryBounded() {
    let points = (0..<1_000).map { index in
        HistoryTrendPoint(
            timestamp: Date(timeIntervalSince1970: TimeInterval(index * 120)),
            duration: 60,
            diskReadBytes: 1,
            diskWriteBytes: 1,
            networkReceiveBytes: 1,
            networkSendBytes: 1,
            averageCPUPercent: 10,
            peakCPUPercent: 10
        )
    }

    let compacted = HistoryDatabase.compactTrend(points, maximumPoints: 400)

    #expect(compacted.count == 400)
    #expect(compacted.dropFirst().allSatisfy { $0.startsNewSegment })
    #expect(compacted.first?.timestamp == points.first?.timestamp)
    #expect(compacted.last?.timestamp == points.last?.timestamp)
    #expect(compacted.reduce(UInt64(0)) { $0 + $1.diskWriteBytes } == 1_000)
    #expect(compacted.reduce(0) { $0 + $1.duration } == 60_000)
}

@Test func applicationRollupPreservesExistingOtherAcrossTopKCompaction() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let reference = Int64(1_800_000_000)
    let startEpoch = reference - reference % 900
    var expectedWriteBytes: UInt64 = 0

    for minute in 0..<15 {
        let applications = (0..<40).map { index -> HistoryApplicationSample in
            let writeBytes = UInt64(index + 1)
            expectedWriteBytes += writeBytes
            return HistoryApplicationSample(
                identity: "app-\(minute)-\(index)",
                name: "Application \(minute)-\(index)",
                readBytes: 0,
                writeBytes: writeBytes,
                cpuTimeNanoseconds: 0,
                networkReceiveBytes: 0,
                networkSendBytes: 0
            )
        }
        await recorder.record(.fixture(
            at: Date(timeIntervalSince1970: TimeInterval(startEpoch + Int64(minute * 60))),
            duration: 60,
            diskWriteBytes: 0,
            applications: applications
        ))
    }
    await recorder.flush()

    let total = try await database.applicationWriteTotalForTesting(
        startEpoch: startEpoch,
        resolution: 900
    )
    #expect(total == expectedWriteBytes)
}

@Test func historyDatabaseReopensWithoutLosingCommittedMinutes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    do {
        let database = try HistoryDatabase(location: .file(url))
        let recorder = HistoryRecorder(database: database)
        await recorder.record(.fixture(at: start, duration: 60, diskWriteBytes: 42))
        await recorder.flush()
    }

    let reopened = try HistoryDatabase(location: .file(url))
    let report = try await reopened.report(range: .sevenDays, now: start.addingTimeInterval(60))
    #expect(report.summary.diskWriteBytes == 42)
    let storage = await reopened.storageInfo(configuration: .init(isEnabled: true))
    #expect(storage.databaseBytes > 0)
    #expect(storage.totalBytes <= 32_000_000)
}

@Test func replayingACommittedMinuteAfterReopenDoesNotDoubleCountDailyApplications() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let sample = HistorySample.fixture(
        at: start,
        duration: 60,
        diskWriteBytes: 10,
        applications: [HistoryApplicationSample(
            identity: "app-id",
            name: "Application",
            readBytes: 0,
            writeBytes: 10,
            cpuTimeNanoseconds: 0,
            networkReceiveBytes: 0,
            networkSendBytes: 0
        )]
    )

    do {
        let database = try HistoryDatabase(location: .file(url))
        let recorder = HistoryRecorder(database: database)
        await recorder.record(sample)
        await recorder.flush()
    }

    let reopened = try HistoryDatabase(location: .file(url))
    let replayRecorder = HistoryRecorder(database: reopened)
    await replayRecorder.record(sample)
    await replayRecorder.flush()

    let report = try await reopened.report(
        range: .sevenDays,
        now: start.addingTimeInterval(60)
    )
    #expect(report.summary.diskWriteBytes == 10)
    #expect(report.applications.first?.writeBytes == 10)
    #expect(await reopened.commitCount == 0)
}

@Test func checkpointFailureAfterCommitDoesNotRetryOrDoubleCountTheMinute() async throws {
    let database = try HistoryDatabase(location: .memory)
    await database.setCheckpointOverrideForTesting {
        throw HistoryDatabaseError(message: "checkpoint fixture", isRetryable: true)
    }
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.fixture(
        at: start,
        duration: 60,
        diskWriteBytes: 10,
        applications: [HistoryApplicationSample(
            identity: "app-id",
            name: "Application",
            readBytes: 0,
            writeBytes: 10,
            cpuTimeNanoseconds: 0,
            networkReceiveBytes: 0,
            networkSendBytes: 0
        )]
    ))

    await recorder.flush()
    await recorder.flush()

    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(60)
    )
    #expect(report.summary.diskWriteBytes == 10)
    #expect(report.applications.first?.writeBytes == 10)
    #expect(await database.commitCount == 1)
    #expect(await database.maintenanceErrorForTesting?.contains("checkpoint fixture") == true)
    let storage = await database.storageInfo(configuration: .init(isEnabled: true))
    #expect(storage.state == .normal)
}

@Test func recorderRetriesABucketAfterATransactionLockFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let database = try HistoryDatabase(location: .file(url))
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.fixture(at: start, duration: 60, diskWriteBytes: 42))

    var blocker: OpaquePointer?
    #expect(sqlite3_open_v2(
        url.path,
        &blocker,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK)
    let blockerHandle = try #require(blocker)
    defer { sqlite3_close(blockerHandle) }
    #expect(sqlite3_exec(blockerHandle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

    await recorder.flush()
    #expect(sqlite3_exec(blockerHandle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    await recorder.flush()

    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(60)
    )
    #expect(report.summary.diskWriteBytes == 42)
    #expect(await database.commitCount == 1)
}

@Test func recorderAcceptsTheNextMinuteWhileThePreviousMinuteAwaitsRetry() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let database = try HistoryDatabase(location: .file(url))
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.fixture(at: start, duration: 60, diskWriteBytes: 40))

    var blocker: OpaquePointer?
    #expect(sqlite3_open_v2(
        url.path,
        &blocker,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK)
    let blockerHandle = try #require(blocker)
    defer { sqlite3_close(blockerHandle) }
    #expect(sqlite3_exec(blockerHandle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

    await recorder.record(.fixture(
        at: start.addingTimeInterval(60),
        duration: 60,
        diskWriteBytes: 2
    ))
    #expect(sqlite3_exec(blockerHandle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    await recorder.flush()

    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(120)
    )
    #expect(report.summary.diskWriteBytes == 42)
    #expect(await database.commitCount == 2)
}

@Test func recorderBoundsPendingMinutesDuringASustainedWriteFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let database = try HistoryDatabase(location: .file(url))
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.fixture(at: start, duration: 60, diskWriteBytes: 1))

    var blocker: OpaquePointer?
    #expect(sqlite3_open_v2(
        url.path,
        &blocker,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK)
    let blockerHandle = try #require(blocker)
    defer { sqlite3_close(blockerHandle) }
    #expect(sqlite3_exec(blockerHandle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

    for minute in 1...3 {
        await recorder.record(.fixture(
            at: start.addingTimeInterval(TimeInterval(minute * 60)),
            duration: 60,
            diskWriteBytes: 1
        ))
    }
    #expect(await recorder.pendingBucketCountForTesting == 2)

    #expect(sqlite3_exec(blockerHandle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    await recorder.flush()

    let report = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(4 * 60)
    )
    #expect(report.summary.diskWriteBytes == 3)
    #expect(await database.commitCount == 3)
}

@Test func retentionMaintenanceRemovesExpiredFineGrainedBuckets() async throws {
    let database = try HistoryDatabase(location: .memory)
    let configuration = HistoryConfiguration(isEnabled: true, retention: .oneYear)
    let recorder = HistoryRecorder(database: database, configuration: configuration)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    for minute in 0..<15 {
        await recorder.record(.fixture(
            at: start.addingTimeInterval(TimeInterval(minute * 60)),
            duration: 60,
            diskWriteBytes: 1
        ))
    }
    await recorder.flush()

    let removedMinutes = try await database.performRetentionMaintenance(
        configuration: configuration,
        now: start.addingTimeInterval(2 * 86_400)
    )
    let removedQuarterHour = try await database.performRetentionMaintenance(
        configuration: configuration,
        now: start.addingTimeInterval(31 * 86_400)
    )
    let nothingElseExpired = try await database.performRetentionMaintenance(
        configuration: configuration,
        now: start.addingTimeInterval(31 * 86_400)
    )

    #expect(removedMinutes)
    #expect(removedQuarterHour)
    #expect(!nothingElseExpired)
}

@MainActor
@Test func stoppingMonitoringRebasesCountersBeforeTheNextSample() async {
    let store = MonitorStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    store.ingest(.lifecycleFixture(at: start, uptime: 10, counter: 100))
    store.ingest(.lifecycleFixture(at: start.addingTimeInterval(1), uptime: 11, counter: 200))
    #expect(store.points.last?.writeBytesPerSecond == 100)

    store.stop()
    store.ingest(.lifecycleFixture(at: start.addingTimeInterval(3_600), uptime: 3_610, counter: 10_000))
    await store.waitForPendingProcessSummary()

    #expect(store.points.last?.writeBytesPerSecond == nil)
    #expect(store.systemPoints.last?.cpuPercent == nil)
    #expect(store.systemPoints.last?.networkReceiveBytesPerSecond == nil)

    store.ingest(.lifecycleFixture(at: start.addingTimeInterval(3_601), uptime: 3_611, counter: 10_010))
    await store.waitForPendingProcessSummary()

    #expect(store.points.last?.writeBytesPerSecond == 10)
    #expect(store.systemPoints.last?.networkReceiveBytesPerSecond == 10)
    #expect(store.processes.first?.currentWriteBytesPerSecond == 10)
}

@MainActor
@Test func restartingMonitoringDoesNotBridgeTheStoppedInterval() async {
    let backgroundFixture = SystemSnapshot.lifecycleFixture(
        at: Date(timeIntervalSince1970: 1_900_000_000),
        uptime: 1,
        counter: 1
    )
    let store = MonitorStore(sampleProvider: {
        try? await Task.sleep(for: .seconds(60))
        return backgroundFixture
    })
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    store.ingest(.lifecycleFixture(at: start, uptime: 10, counter: 100))

    store.restart()
    store.ingest(.lifecycleFixture(at: start.addingTimeInterval(3_600), uptime: 3_610, counter: 10_000))

    #expect(store.points.last?.writeBytesPerSecond == nil)
    #expect(store.systemPoints.last?.cpuPercent == nil)
    store.stop()
}

@MainActor
@Test func flushingHistoryWaitsForQueuedSamples() async throws {
    let database = try HistoryDatabase(location: .memory)
    let recorder = HistoryRecorder(database: database)
    let store = MonitorStore(historyRecorder: recorder)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    store.ingest(.lifecycleFixture(at: start, uptime: 10, counter: 100))
    store.ingest(.lifecycleFixture(at: start.addingTimeInterval(1), uptime: 11, counter: 142))
    await store.flushHistory()

    let report = try await database.report(range: .sevenDays, now: start.addingTimeInterval(60))
    #expect(report.summary.diskWriteBytes == 42)
}

private extension HistorySample {
    static func fixture(
        at date: Date,
        duration: TimeInterval,
        diskWriteBytes: UInt64,
        applications: [HistoryApplicationSample] = []
    ) -> Self {
        Self(
            timestamp: date,
            duration: duration,
            diskReadBytes: 0,
            diskWriteBytes: diskWriteBytes,
            cpuPercent: 12,
            networkReceiveBytes: 0,
            networkSendBytes: 0,
            applications: applications,
            devices: []
        )
    }
}

private extension SystemSnapshot {
    static func lifecycleFixture(
        at date: Date,
        uptime: TimeInterval,
        counter: UInt64
    ) -> Self {
        Self(
            date: date,
            uptime: uptime,
            processes: [RawProcessCounter(
                pid: 42,
                startAbstime: 7,
                name: "fixture",
                path: "/usr/bin/fixture",
                cpuTimeNanoseconds: counter * 1_000_000,
                bytesRead: counter,
                bytesWritten: counter,
                networkBytesReceived: counter,
                networkBytesSent: counter
            )],
            disks: [RawDiskCounter(
                registryID: 99,
                name: "Physical Disk",
                bytesRead: counter,
                bytesWritten: counter,
                readOperations: counter,
                writeOperations: counter,
                capacity: 1_000_000,
                bsdName: "disk99",
                isPhysical: true
            )],
            volumes: [],
            cpuUserTicks: counter,
            cpuSystemTicks: 0,
            cpuNiceTicks: 0,
            cpuIdleTicks: counter * 9,
            networkInterfaces: [RawNetworkInterfaceCounter(
                index: 1,
                name: "en0",
                bytesReceived: counter,
                bytesSent: counter
            )],
            cpuStatsAvailable: true,
            networkInterfacesAvailable: true,
            processNetworkAvailable: true
        )
    }
}
