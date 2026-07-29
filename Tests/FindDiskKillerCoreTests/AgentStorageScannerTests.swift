import Darwin
import Foundation
import SQLite3
import Testing
@testable import FindDiskKillerCore

@Test func unstableEntryTrackerDeduplicatesPhysicalIdentityPerProvider() {
    var tracker = AgentStorageUnstableEntryTracker()

    tracker.mark(device: 7, inode: 42, provider: .codex)
    tracker.mark(device: 7, inode: 42, provider: .codex)
    tracker.mark(device: 7, inode: 42, provider: .claude)
    tracker.mark(device: 7, inode: 43, provider: .claude)

    #expect(tracker.totalCount == 2)
    #expect(tracker.count(for: .codex) == 1)
    #expect(tracker.count(for: .claude) == 2)
}

@Test func agentStorageScannerMarksDirectoryChangesDuringScanAsPartial() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = root.appending(path: ".claude", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: claude.appending(path: "settings.json"))
    let lateFile = claude.appending(path: "created-after-enumeration.txt")

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false,
        beforePhysicalValidation: {
            try? Data("late".utf8).write(to: lateFile)
        }
    )).scan()

    #expect(snapshot.coverage.unstableEntryCount > 0)
    #expect(!snapshot.coverage.isComplete)
    #expect(!snapshot.coverage.isPhysicalMeasurementComplete)
    let claudeSummary = try #require(snapshot.providers.first { $0.provider == .claude })
    #expect(claudeSummary.unstableEntryCount > 0)
    #expect(claudeSummary.supportStatus == .partial)
    #expect(claudeSummary.attributionStatus == .noConversationSource)
    #expect(snapshot.diagnostics.contains {
        $0.provider == .claude
            && $0.kind == .changedDuringScan
            && $0.impact == .physicalMeasurement
    })
}

@Test func agentStorageScannerHandlesNonRepositoryPathsAcrossRepeatedScans() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(
        path: ".claude/projects/-tmp-repeated-scan",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "32000000-0000-0000-0000-000000000001"
    try """
    {"type":"user","sessionId":"\(sessionID)","cwd":"/tmp/repeated-scan"}
    """.data(using: .utf8)!.write(to: project.appending(path: "\(sessionID).jsonl"))
    let scanner = AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    ))

    let first = try await scanner.scan()
    let second = try await scanner.scan()

    #expect(first.coverage.measuredBytes == second.coverage.measuredBytes)
    #expect(first.families.map(\.nativeThreadID) == second.families.map(\.nativeThreadID))
    #expect(second.families.first?.project == "Non-project directory")
    #expect(second.coverage.isPhysicalMeasurementComplete)
}

@Test func agentStorageScannerOnlyOffersStableSingleLinkThreadFilesForCleanup() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(
        path: ".claude/projects/-tmp-cleanup",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "30000000-0000-0000-0000-000000000001"
    let transcript = project.appending(path: "\(sessionID).jsonl")
    try """
    {"type":"user","sessionId":"\(sessionID)","cwd":"/tmp/cleanup"}
    """.data(using: .utf8)!.write(to: transcript)
    let history = root.appending(
        path: ".claude/file-history/\(sessionID)/history.txt"
    )
    try FileManager.default.createDirectory(
        at: history.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(repeating: 0x41, count: 4_096).write(to: history)
    let hardLink = history.deletingLastPathComponent().appending(path: "history-link.txt")
    try FileManager.default.linkItem(at: history, to: hardLink)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    let family = try #require(snapshot.families.first { $0.nativeThreadID == sessionID })
    #expect(family.cleanupArtifacts.map(cleanupIdentity) == [cleanupIdentity(transcript)])
    #expect(!family.cleanupArtifacts.contains {
        cleanupIdentity($0) == cleanupIdentity(history)
            || cleanupIdentity($0) == cleanupIdentity(hardLink)
    })
    #expect(family.reclaimableBytes == family.cleanupArtifacts.reduce(0) { $0 + $1.allocatedBytes })
}

@Test func agentStorageScannerAttributesVerifiedClaudeDesktopSessionsToTheirThread() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = "31000000-0000-0000-0000-000000000001"
    let project = root.appending(
        path: ".claude/projects/-tmp-desktop",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try """
    {"type":"custom-title","sessionId":"\(sessionID)","customTitle":"Desktop fixture"}
    {"type":"user","sessionId":"\(sessionID)","cwd":"/tmp/desktop"}
    """.data(using: .utf8)!.write(
        to: project.appending(path: "\(sessionID).jsonl")
    )

    let desktop = root.appending(
        path: "Library/Application Support/Claude",
        directoryHint: .isDirectory
    )
    let manifests = desktop.appending(
        path: "local-agent-mode-sessions",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
    let manifest = manifests.appending(path: "local_fixture.json")
    try JSONSerialization.data(withJSONObject: ["cliSessionId": sessionID]).write(to: manifest)
    let payloadDirectory = manifests.appending(path: "local_fixture", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
    let payload = payloadDirectory.appending(path: "events.bin")
    try Data(repeating: 0x44, count: 8_192).write(to: payload)
    let unmapped = manifests.appending(path: "local_unmapped.json")
    try JSONSerialization.data(withJSONObject: [
        "cliSessionId": "31000000-0000-0000-0000-000000000099"
    ]).write(to: unmapped)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: true
    )).scan()

    let family = try #require(snapshot.families.first { $0.nativeThreadID == sessionID })
    #expect(family.allocatedBytes >= allocatedBytes(of: manifest) + allocatedBytes(of: payload))
    #expect(family.cleanupArtifacts.map(cleanupIdentity).contains(cleanupIdentity(manifest)))
    let claudeGlobals = snapshot.globalItems.filter { $0.provider == .claude }
    #expect(claudeGlobals.reduce(0) { $0 + $1.allocatedBytes } >= allocatedBytes(of: unmapped))
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
    #expect(snapshot.coverage.reconciliationDelta == 0)
}

@Test func agentStorageScannerDoesNotMutateSQLiteOrActiveWALSidecars() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions/2026/07/28", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "10000000-0000-0000-0000-000000000099"
    let rollout = sessions.appending(path: "rollout-2026-07-28-\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    let databaseURL = codex.appending(path: "state_5.sqlite")
    var writer: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &writer) == SQLITE_OK)
    let writerHandle = try #require(writer)
    defer { sqlite3_close_v2(writerHandle) }
    try executeSQL(writerHandle, "PRAGMA journal_mode = WAL")
    try executeSQL(writerHandle, "PRAGMA wal_autocheckpoint = 0")
    try executeSQL(writerHandle, """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL,
          cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE thread_spawn_edges (
          parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL, status TEXT NOT NULL
        );
        INSERT INTO threads VALUES (
          '\(threadID)', '\(rollout.path)', 1785225600, '/tmp/demo', 'WAL fixture', 0
        );
        """)

    let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
    let before = try [databaseURL, walURL, shmURL].map(fileSystemSignature)
    _ = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    let after = try [databaseURL, walURL, shmURL].map(fileSystemSignature)

    #expect(after == before)
}

@Test func agentStorageScannerDoesNotCreateSQLiteSidecars() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let databaseURL = codex.appending(path: "state_5.sqlite")
    try createCodexCLITitleDatabase(at: databaseURL, rows: [])
    let walPath = databaseURL.path + "-wal"
    let shmPath = databaseURL.path + "-shm"
    #expect(!FileManager.default.fileExists(atPath: walPath))
    #expect(!FileManager.default.fileExists(atPath: shmPath))

    _ = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(!FileManager.default.fileExists(atPath: walPath))
    #expect(!FileManager.default.fileExists(atPath: shmPath))
}

@Test func agentStorageScannerDoesNotCreateCodexLogSidecars() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "10000000-0000-0000-0000-000000000098"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    let logsURL = codex.appending(path: "logs_2.sqlite")
    try createCodexLogsDatabase(at: logsURL, rows: [(threadID, 4_096)])
    let walPath = logsURL.path + "-wal"
    let shmPath = logsURL.path + "-shm"
    try? FileManager.default.removeItem(atPath: walPath)
    try? FileManager.default.removeItem(atPath: shmPath)
    #expect(!FileManager.default.fileExists(atPath: walPath))
    #expect(!FileManager.default.fileExists(atPath: shmPath))

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .unavailable)
    #expect(attribution.attributedBytes == 0)
    #expect(attribution.residualBytes == attribution.physicalBundleBytes)
    #expect(!FileManager.default.fileExists(atPath: walPath))
    #expect(!FileManager.default.fileExists(atPath: shmPath))
}

@Test func agentStorageScannerAttributesCodexLogDatabaseAndPreservesPhysicalTotal() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions/2026/07/28", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let mainID = "11000000-0000-0000-0000-000000000001"
    let childID = "11000000-0000-0000-0000-000000000002"
    let unknownID = "11000000-0000-0000-0000-000000000003"
    let mainRollout = sessions.appending(path: "rollout-main-\(mainID).jsonl")
    let childRollout = sessions.appending(path: "rollout-child-\(childID).jsonl")
    try Data("{}\n".utf8).write(to: mainRollout)
    try Data("{}\n".utf8).write(to: childRollout)
    try createCodexStateDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        mainID: mainID,
        childID: childID,
        mainRollout: mainRollout.path,
        childRollout: childRollout.path
    )
    let logsURL = codex.appending(path: "logs_2.sqlite")
    try createCodexLogsDatabase(
        at: logsURL,
        rows: [
            (mainID, 4_096),
            (childID, 8_192),
            (unknownID, 4_096),
            (nil, 4_096)
        ]
    )
    let logsWALPath = logsURL.path + "-wal"
    let logsSHMPath = logsURL.path + "-shm"
    let databaseSignaturesBeforeScan = try [
        logsURL,
        URL(fileURLWithPath: logsWALPath)
    ].map(fileSystemSignature)
    let sharedMemorySignatureBeforeScan = try fileSystemSignature(
        URL(fileURLWithPath: logsSHMPath)
    )
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: ".codex-cc"),
        withDestinationURL: codex
    )

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.databaseAttributions.count == 1)
    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .completed)
    #expect(attribution.processedRowCount == 4)
    #expect(attribution.totalRowCount == 4)
    #expect(attribution.mappedEstimatedBytes == 12_288)
    #expect(attribution.unmappedEstimatedBytes == 8_192)
    #expect(attribution.attributedBytes == 12_288)
    #expect(attribution.attributedBytes + attribution.residualBytes
        == attribution.physicalBundleBytes)

    let family = try #require(snapshot.families.first { $0.nativeThreadID == mainID })
    let child = try #require(family.subagents.first { $0.nativeID == childID })
    #expect(family.mainDatabaseAttributedBytes == 4_096)
    #expect(family.subagentDatabaseAttributedBytes == 8_192)
    #expect(child.databaseAttributedBytes == 8_192)
    #expect(family.attributedBytes == family.allocatedBytes + 12_288)

    let databaseItem = try #require(snapshot.globalItems.first {
        $0.provider == .codex && $0.category == .sharedDatabase
    })
    #expect(databaseItem.databaseAttributedBytes == 12_288)
    #expect(databaseItem.allocatedBytes + databaseItem.databaseAttributedBytes
        == databaseItem.physicalAllocatedBytes)
    #expect(snapshot.sources.filter { $0.provider == .codex }.count == 1)
    #expect(snapshot.totalBytes == snapshot.coverage.measuredBytes)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
    let databaseSignaturesAfterScan = try [
        logsURL,
        URL(fileURLWithPath: logsWALPath)
    ].map(fileSystemSignature)
    let sharedMemorySignatureAfterScan = try fileSystemSignature(
        URL(fileURLWithPath: logsSHMPath)
    )
    #expect(databaseSignaturesAfterScan == databaseSignaturesBeforeScan)
    #expect(sharedMemorySignatureAfterScan.prefix(4) == sharedMemorySignatureBeforeScan.prefix(4))
}

@Test func agentStorageScannerKeepsUnsupportedCodexLogSchemaInSharedStorage() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "12000000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    try createUnsupportedCodexLogsDatabase(at: codex.appending(path: "logs_2.sqlite"))

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.databaseAttributions.count == 1)
    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .unsupportedFormat)
    #expect(attribution.attributedBytes == 0)
    #expect(attribution.residualBytes == attribution.physicalBundleBytes)
    #expect(snapshot.families.allSatisfy { $0.databaseAttributedBytes == 0 })
    let databaseItem = try #require(snapshot.globalItems.first {
        $0.provider == .codex && $0.category == .sharedDatabase
    })
    #expect(databaseItem.databaseAttributedBytes == 0)
    #expect(databaseItem.allocatedBytes == databaseItem.physicalAllocatedBytes)
    let summary = try #require(snapshot.providers.first { $0.provider == .codex })
    #expect(summary.supportStatus == .partial)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
    #expect(snapshot.coverage.isPhysicalMeasurementComplete)
    #expect(snapshot.diagnostics.count == 1)
    let diagnostic = try #require(snapshot.diagnostics.first)
    #expect(diagnostic.kind == .databaseAttributionUnavailable)
    #expect(diagnostic.affectedAllocatedBytes == attribution.physicalBundleBytes)
    #expect(summary.issueCount == 1)
    #expect(summary.diagnosticCounts[.databaseAttributionUnavailable] == 1)
}

@Test func agentStorageDatabaseProgressStaysMonotonicAcrossMultipleCodexHomes() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var additionalRoots: [URL] = []
    for index in 1...2 {
        let codex = root.appending(path: "codex-\(index)", directoryHint: .isDirectory)
        let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let threadID = "13000000-0000-0000-0000-00000000000\(index)"
        let rollout = sessions.appending(path: "\(threadID).jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        try createCodexCLITitleDatabase(
            at: codex.appending(path: "state_5.sqlite"),
            rows: [(threadID, rollout.path, "Fixture \(index)", "", "", "/tmp")]
        )
        try createCodexLogsDatabase(
            at: codex.appending(path: "logs_2.sqlite"),
            rows: [(threadID, UInt64(index * 4_096))]
        )
        additionalRoots.append(codex)
    }
    let recorder = AgentStorageProgressRecorder()

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        additionalRoots: additionalRoots,
        includesDesktopData: false
    )).scan { recorder.append($0) }

    let progress = recorder.values.filter { $0.phase == .attributingDatabase }
    #expect(snapshot.databaseAttributions.count == 2)
    #expect(progress.count >= 3)
    #expect(progress.contains { $0.databaseStage == .preparing })
    #expect(progress.contains {
        $0.databaseStage == .readingRecords && $0.totalCount == nil
    })
    #expect(progress.contains { $0.databaseStage == .mappingRecords })
    #expect(zip(progress, progress.dropFirst()).allSatisfy {
        $0.0.completedCount <= $0.1.completedCount
    })
    let finalProgress = try #require(progress.last)
    #expect(finalProgress.completedCount == 2)
    #expect(finalProgress.totalCount == 2)
    #expect(finalProgress.processedBytes == 12_288)
    #expect(finalProgress.databaseIndex == 2)
    #expect(finalProgress.databaseCount == 2)
}

@Test func agentStorageScannerRejectsDatabaseAttributionWhenThreadGraphChanges() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "14000000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    let stateURL = codex.appending(path: "state_5.sqlite")
    try createCodexCLITitleDatabase(
        at: stateURL,
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    try createCodexLogsDatabase(
        at: codex.appending(path: "logs_2.sqlite"),
        rows: [(threadID, 4_096)]
    )
    let replacer = OneShotFileReplacer(url: stateURL)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan { progress in
        if progress.phase == .attributingDatabase,
           progress.databaseStage == .readingRecords,
           progress.completedCount == 0 {
            replacer.replace()
        }
    }

    #expect(replacer.didReplace)
    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .unavailable)
    #expect(attribution.attributedBytes == 0)
    #expect(attribution.residualBytes == attribution.physicalBundleBytes)
    #expect(snapshot.families.allSatisfy { $0.databaseAttributedBytes == 0 })
    let databaseItem = try #require(snapshot.globalItems.first {
        $0.provider == .codex && $0.category == .sharedDatabase
    })
    #expect(databaseItem.databaseAttributedBytes == 0)
    #expect(databaseItem.allocatedBytes == databaseItem.physicalAllocatedBytes)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
}

@Test func agentStorageScannerDoesNotBlockAConcurrentCodexLogWriter() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "15000000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    let logsURL = codex.appending(path: "logs_2.sqlite")
    try createCodexLogsDatabase(
        at: logsURL,
        rows: (1...8_192).map { _ in (threadID, UInt64(64)) },
        feedbackBodyBytes: 0
    )
    let writer = ConcurrentCodexLogWriter(url: logsURL, threadID: threadID)
    let recorder = AgentStorageProgressRecorder()

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan { progress in
        recorder.append(progress)
        if progress.phase == .attributingDatabase,
           progress.databaseStage == .readingRecords,
           progress.completedCount == 0 {
            writer.start()
            writer.waitForCompletionDuringReadSnapshot(timeoutMilliseconds: 2_000)
        }
    }

    #expect(writer.waitForCompletion())
    #expect(writer.didCompleteDuringReadSnapshot)
    #expect(writer.didCommit)
    #expect(writer.sqliteResult == SQLITE_OK)
    #expect(recorder.values.contains {
        $0.phase == .attributingDatabase
            && $0.databaseStage == .readingRecords
            && $0.totalCount == nil
            && $0.completedCount > 0
            && ($0.processedBytes ?? 0) > 0
    })
    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .completed)
    #expect(attribution.processedRowCount == 8_192)
    #expect(attribution.attributedBytes > 0)
    #expect(attribution.attributedBytes + attribution.residualBytes
        == attribution.physicalBundleBytes)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
}

@Test func agentStorageScannerReadsOneCodexLogDatabaseInParallel() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "16000000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    try createCodexLogsDatabase(
        at: codex.appending(path: "logs_2.sqlite"),
        rows: (1...8_192).map { _ in (threadID, UInt64(64)) },
        feedbackBodyBytes: 0
    )
    let probe = AgentStorageDatabaseShardConcurrencyProbe()

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false,
        databaseReadConcurrency: 2,
        databaseShardDidStart: { _ in probe.enterShard() }
    )).scan()

    #expect(probe.didOverlap)
    #expect(probe.maximumConcurrentShardStarts == 2)
    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .completed)
    #expect(attribution.processedRowCount == 8_192)
}

@Test func agentStorageParallelReadersDoNotMutateCodexLogDatabaseOrWALSidecars() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "17000000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    let logsURL = codex.appending(path: "logs_2.sqlite")
    try createCodexLogsDatabase(
        at: logsURL,
        rows: (1...8_192).map { _ in (threadID, UInt64(64)) },
        feedbackBodyBytes: 0
    )
    var writer: OpaquePointer?
    #expect(sqlite3_open_v2(
        logsURL.path,
        &writer,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK)
    let writerHandle = try #require(writer)
    defer { sqlite3_close_v2(writerHandle) }
    try executeSQL(writerHandle, "PRAGMA wal_autocheckpoint = 0")
    try executeSQL(writerHandle, """
        INSERT INTO logs (thread_id, estimated_bytes, feedback_log_body)
        VALUES ('\(threadID)', 64, NULL)
        """)

    let walURL = URL(fileURLWithPath: logsURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: logsURL.path + "-shm")
    let before = try [logsURL, walURL, shmURL].map(fileSystemSignature)
    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    let after = try [logsURL, walURL, shmURL].map(fileSystemSignature)

    #expect(after == before)
    let attribution = try #require(snapshot.databaseAttributions.first)
    #expect(attribution.status == .completed)
    #expect(attribution.processedRowCount == 8_193)
}

@Test func agentStorageCancellationStopsAllParallelCodexLogReaders() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "18000000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [(threadID, rollout.path, "Fixture", "", "", "/tmp")]
    )
    try createCodexLogsDatabase(
        at: codex.appending(path: "logs_2.sqlite"),
        rows: (1...8_192).map { _ in (threadID, UInt64(64)) },
        feedbackBodyBytes: 0
    )
    let probe = AgentStorageDatabaseShardCancellationProbe()
    let scanner = AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false,
        databaseReadConcurrency: 2,
        databaseShardDidStart: { _ in probe.holdReader() }
    ))
    let scanTask = Task { try await scanner.scan() }

    #expect(probe.waitForReaders(2, timeout: 2))
    scanTask.cancel()
    probe.releaseReaders()

    await #expect(throws: CancellationError.self) {
        try await scanTask.value
    }
}

@Test func agentStorageScannerAggregatesSubagentsAndReconcilesPhysicalBytes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let mainID = "10000000-0000-0000-0000-000000000001"
    let childID = "10000000-0000-0000-0000-000000000002"
    let sessions = codex.appending(path: "sessions/2026/07/28", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let mainRollout = sessions.appending(path: "rollout-2026-07-28-\(mainID).jsonl")
    let childRollout = sessions.appending(path: "rollout-2026-07-28-\(childID).jsonl")
    try Data(repeating: 0x41, count: 8_192).write(to: mainRollout)
    try Data(repeating: 0x42, count: 12_288).write(to: childRollout)
    try createCodexStateDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        mainID: mainID,
        childID: childID,
        mainRollout: mainRollout.path,
        childRollout: childRollout.path
    )
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: ".codex-cc"),
        withDestinationURL: codex
    )

    let claude = root.appending(path: ".claude", directoryHint: .isDirectory)
    let project = claude.appending(path: "projects/-tmp-demo", directoryHint: .isDirectory)
    let sessionID = "20000000-0000-0000-0000-000000000001"
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionDirectory = project.appending(path: sessionID, directoryHint: .isDirectory)
    let subagents = sessionDirectory.appending(path: "subagents", directoryHint: .isDirectory)
    let toolResults = sessionDirectory.appending(path: "tool-results", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: toolResults, withIntermediateDirectories: true)
    let mainTool = toolResults.appending(path: "main.txt")
    let childTool = toolResults.appending(path: "child.txt")
    let sharedTool = toolResults.appending(path: "shared.txt")
    let unreferencedTool = toolResults.appending(path: "unreferenced.txt")
    let prefixCollisionTool = toolResults.appending(path: "child.txt-extra")
    try Data(repeating: 0x44, count: 20_480).write(to: mainTool)
    try Data(repeating: 0x45, count: 24_576).write(to: childTool)
    try Data(repeating: 0x46, count: 28_672).write(to: sharedTool)
    try Data(repeating: 0x47, count: 32_768).write(to: unreferencedTool)
    try Data(repeating: 0x48, count: 4_096).write(to: prefixCollisionTool)

    let transcript = project.appending(path: "\(sessionID.uppercased()).jsonl")
    try """
    {"type":"custom-title","sessionId":"\(sessionID)","customTitle":"Fixture chat"}
    {"type":"ai-title","sessionId":"\(sessionID)","aiTitle":"Generated fixture title"}
    {"type":"last-prompt","sessionId":"\(sessionID)","lastPrompt":"Fixture prompt"}
    {"type":"user","sessionId":"\(sessionID)","cwd":"/tmp/demo","timestamp":"2026-07-28T08:00:00.000Z"}
    {"type":"assistant","sessionId":"\(sessionID)","message":{"content":[{"content":"saved at \(mainTool.path), \(sharedTool.path), and \(prefixCollisionTool.path)"}]}}
    """.data(using: .utf8)!.write(to: transcript)

    let reviewJSONL = subagents.appending(path: "agent-review.jsonl")
    let reviewMeta = subagents.appending(path: "agent-review.meta.json")
    try """
    {"sessionId":"\(sessionID)","agentId":"review","message":{"content":[{"content":"saved at \(childTool.path)"}]}}
    """.data(using: .utf8)!.write(to: reviewJSONL)
    try Data("{\"description\":\"review\",\"agentType\":\"  Review\\n agent  \",\"spawnDepth\":1}".utf8)
        .write(to: reviewMeta)

    let workflow = subagents.appending(path: "workflows/wf-1", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    let nestedJSONL = workflow.appending(path: "agent-nested.jsonl")
    try """
    {"sessionId":"\(sessionID)","agentId":"nested","message":{"content":[{"content":"saved at \(sharedTool.path)"}]}}
    """.data(using: .utf8)!.write(to: nestedJSONL)
    let longSubagentTitle = String(repeating: "Nested agent title ", count: 16)
    try JSONSerialization.data(withJSONObject: [
        "description": longSubagentTitle,
        "spawnDepth": 2
    ]).write(to: workflow.appending(path: "agent-nested.meta.json"))

    let otherProject = claude.appending(path: "projects/-tmp-other", directoryHint: .isDirectory)
    let crossSubagents = otherProject
        .appending(path: sessionID.uppercased(), directoryHint: .isDirectory)
        .appending(path: "subagents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: crossSubagents, withIntermediateDirectories: true)
    try """
    {"sessionId":"\(sessionID.uppercased())","agentId":"cross","type":"assistant"}
    """.data(using: .utf8)!.write(to: crossSubagents.appending(path: "agent-cross.jsonl"))

    let scanner = AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    ))
    let snapshot = try await scanner.scan()

    #expect(snapshot.families.count == 2)
    let codexFamily = try #require(snapshot.families.first { $0.provider == .codex })
    let claudeFamily = try #require(snapshot.families.first { $0.provider == .claude })
    #expect(codexFamily.subagentCount == 1)
    #expect(codexFamily.subagentAllocatedBytes > 0)
    #expect(codexFamily.allocatedBytes > codexFamily.subagentAllocatedBytes)
    #expect(claudeFamily.title == "Fixture chat")
    #expect(claudeFamily.subagentCount == 3)
    #expect(claudeFamily.subagentAllocatedBytes > 0)
    #expect(claudeFamily.familyOtherAllocatedBytes > 0)
    let reviewNode = try #require(claudeFamily.subagents.first { $0.nativeID == "review" })
    let nestedNode = try #require(claudeFamily.subagents.first { $0.nativeID == "nested" })
    let crossNode = try #require(claudeFamily.subagents.first { $0.nativeID == "cross" })
    #expect(reviewNode.title == "Review agent")
    #expect(nestedNode.title.count == 161)
    #expect(nestedNode.title.hasSuffix("…"))
    #expect(!crossNode.title.localizedCaseInsensitiveContains("cross"))
    #expect(reviewNode.allocatedBytes >= allocatedBytes(of: reviewJSONL)
        + allocatedBytes(of: reviewMeta)
        + allocatedBytes(of: childTool))
    #expect(nestedNode.depth == 2)
    #expect(claudeFamily.mainAllocatedBytes >= allocatedBytes(of: mainTool))
    #expect(claudeFamily.familyOtherAllocatedBytes >= allocatedBytes(of: sharedTool))
    #expect(claudeFamily.familyOtherAllocatedBytes >= allocatedBytes(of: unreferencedTool))
    let codexSummary = try #require(snapshot.providers.first { $0.provider == .codex })
    let claudeSummary = try #require(snapshot.providers.first { $0.provider == .claude })
    let codexDataset = try #require(snapshot.dataset(for: .codex))
    let claudeDataset = try #require(snapshot.dataset(for: .claude))
    #expect(codexDataset.families.count == 1)
    #expect(codexDataset.families.allSatisfy { $0.provider == .codex })
    #expect(codexDataset.globalItems.allSatisfy { $0.provider == .codex })
    #expect(claudeDataset.families.count == 1)
    #expect(claudeDataset.families.allSatisfy { $0.provider == .claude })
    #expect(claudeDataset.unattributedItems.allSatisfy { $0.provider == .claude })
    #expect(codexSummary.sourceCount == 1)
    #expect(codexSummary.chatBytes == codexFamily.allocatedBytes)
    #expect(codexSummary.mainThreadBytes == codexFamily.mainAllocatedBytes)
    #expect(codexSummary.subagentBytes == codexFamily.subagentAllocatedBytes)
    #expect(claudeSummary.chatBytes == claudeFamily.allocatedBytes)
    #expect(claudeSummary.familyOtherBytes == claudeFamily.familyOtherAllocatedBytes)
    #expect(claudeSummary.exclusiveBytes
        == claudeSummary.chatBytes + claudeSummary.globalBytes + claudeSummary.unattributedBytes)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
    #expect(snapshot.totalBytes == snapshot.coverage.classifiedBytes)
}

@Test func agentStorageScannerRecognizesClaudeCLITitleRecordsAndFallbacks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let project = root
        .appending(path: ".claude/projects/-tmp-claude-cli", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let aiTitleID = "21000000-0000-0000-0000-000000000001"
    try """
    {"type":"user","sessionId":"\(aiTitleID)","message":{"role":"user","content":"Build the official website"}}
    {"type":"ai-title","sessionId":"\(aiTitleID)","aiTitle":"Build official website"}
    {"type":"ai-title","sessionId":"\(aiTitleID)","aiTitle":"later-agent-name-slug"}
    """.data(using: .utf8)!.write(to: project.appending(path: "\(aiTitleID).jsonl"))

    let promptID = "22000000-0000-0000-0000-000000000002"
    try """
    {"type":"user","sessionId":"\(promptID)","message":{"role":"user","content":"Earlier user text"}}
    {"type":"last-prompt","sessionId":"\(promptID)","lastPrompt":"长沙天气怎么样"}
    {"type":"last-prompt","sessionId":"\(promptID)","lastPrompt":"Later prompt must not replace the first"}
    """.data(using: .utf8)!.write(to: project.appending(path: "\(promptID).jsonl"))

    let userID = "23000000-0000-0000-0000-000000000003"
    try """
    {"type":"user","sessionId":"\(userID)","isMeta":true,"message":{"role":"user","content":"Ignore metadata"}}
    {"type":"user","sessionId":"\(userID)","message":{"role":"user","content":[{"type":"tool_result","content":"Ignore tool output"}]}}
    {"type":"user","sessionId":"\(userID)","message":{"role":"user","content":[{"type":"text","text":"hi from a content block"}]}}
    """.data(using: .utf8)!.write(to: project.appending(path: "\(userID).jsonl"))

    let scanner = AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    ))
    let snapshot = try await scanner.scan()
    let titles = Dictionary(uniqueKeysWithValues: snapshot.families.map {
        ($0.nativeThreadID, $0.title)
    })

    #expect(titles[aiTitleID] == "Build official website")
    #expect(titles[promptID] == "长沙天气怎么样")
    #expect(titles[userID] == "hi from a content block")
}

@Test func agentStorageScannerRecoversCodexCLITitlesWithoutDisplayingThreadIDs() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions/2026/07/28", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let promptID = "51000000-0000-0000-0000-000000000001"
    let rolloutID = "51000000-0000-0000-0000-000000000002"
    let fallbackID = "51000000-0000-0000-0000-000000000003"
    let emptyID = "51000000-0000-0000-0000-000000000004"
    let promptRollout = sessions.appending(path: "rollout-\(promptID).jsonl")
    let eventRollout = sessions.appending(path: "rollout-\(rolloutID).jsonl")
    let fallbackRollout = sessions.appending(path: "rollout-\(fallbackID).jsonl")
    try Data("{}\n".utf8).write(to: promptRollout)
    try Data("{}\n".utf8).write(to: fallbackRollout)
    try """
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\\nignore injected context"}]}}
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Response item fallback"}]}}
    {"type":"event_msg","payload":{"type":"user_message","message":"Explicit CLI request"}}
    """.data(using: .utf8)!.write(to: eventRollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [
            (promptID, promptRollout.path, promptID, "  Build   the CLI\nwith tests  ", "Preview", "/tmp/prompt-project"),
            (rolloutID, eventRollout.path, "", "", "", "/tmp/rollout-project"),
            (fallbackID, fallbackRollout.path, "", "", "", "/tmp/fallback-project"),
            (emptyID, "/missing/rollout.jsonl", "", "", "", "/tmp/empty-project")
        ]
    )
    var database: OpaquePointer?
    let databaseURL = codex.appending(path: "state_5.sqlite")
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let databaseHandle = try #require(database)
    try executeSQL(databaseHandle, "UPDATE threads SET updated_at_ms = NULL WHERE id = '\(fallbackID)'")
    sqlite3_close_v2(databaseHandle)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    let titles = Dictionary(uniqueKeysWithValues: snapshot.families.map {
        ($0.nativeThreadID, $0.title)
    })
    #expect(titles[promptID] == "Build the CLI with tests")
    #expect(titles[rolloutID] == "Explicit CLI request")
    #expect(titles[fallbackID] == "fallback-project · 2026-07-28")
    #expect(titles[emptyID] == nil)
    #expect(titles.values.allSatisfy { ![$0].contains(promptID) })
    let summary = try #require(snapshot.providers.first { $0.provider == .codex })
    #expect(summary.supportStatus == .supported)
}

@Test func agentStorageScannerGroupsCodexWorktreesByRepositoryOrigin() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let firstID = "52000000-0000-0000-0000-000000000001"
    let secondID = "52000000-0000-0000-0000-000000000002"
    let firstRollout = sessions.appending(path: "\(firstID).jsonl")
    let secondRollout = sessions.appending(path: "\(secondID).jsonl")
    try Data("{}\n".utf8).write(to: firstRollout)
    try Data("{}\n".utf8).write(to: secondRollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [
            (firstID, firstRollout.path, "First", "", "", "/code/redeven-feat-a"),
            (secondID, secondRollout.path, "Second", "", "", "/tmp/branch-b")
        ],
        gitOriginURL: "git@github.com:floegence/redeven.git"
    )

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.families.count == 2)
    #expect(Set(snapshot.families.map(\.project)) == ["redeven"])
}

@Test func agentStorageScannerLearnsMissingOriginsAndGroupsNonRepositoriesSeparately() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let learnedID = "52100000-0000-0000-0000-000000000001"
    let originID = "52100000-0000-0000-0000-000000000002"
    let temporaryID = "52100000-0000-0000-0000-000000000003"
    let learnedRollout = sessions.appending(path: "\(learnedID).jsonl")
    let originRollout = sessions.appending(path: "\(originID).jsonl")
    let temporaryRollout = sessions.appending(path: "\(temporaryID).jsonl")
    for rollout in [learnedRollout, originRollout, temporaryRollout] {
        try Data("{}\n".utf8).write(to: rollout)
    }
    let removedWorktree = "/private/tmp/removed-redeven-worktree"
    let databaseURL = codex.appending(path: "state_5.sqlite")
    try createCodexCLITitleDatabase(
        at: databaseURL,
        rows: [
            (learnedID, learnedRollout.path, "Learned", "", "", removedWorktree),
            (originID, originRollout.path, "Origin", "", "", removedWorktree),
            (temporaryID, temporaryRollout.path, "Temporary", "", "", "/private/tmp/redeven-demo")
        ]
    )
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let databaseHandle = try #require(database)
    try executeSQL(
        databaseHandle,
        "UPDATE threads SET git_origin_url = 'git@github.com:floegence/redeven.git' WHERE id = '\(originID)'"
    )
    sqlite3_close_v2(databaseHandle)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    let projectsByID = Dictionary(uniqueKeysWithValues: snapshot.families.map {
        ($0.nativeThreadID, $0.project)
    })

    #expect(projectsByID[learnedID] == "redeven")
    #expect(projectsByID[originID] == "redeven")
    #expect(projectsByID[temporaryID] == "Non-project directory")
}

@Test func agentStorageScannerResolvesCodexLinkedWorktreeToMainRepository() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appending(path: "redeven", directoryHint: .isDirectory)
    let gitWorktree = repository.appending(path: ".git/worktrees/feature", directoryHint: .isDirectory)
    let linkedWorktree = root.appending(path: "redeven-feature", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gitWorktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkedWorktree, withIntermediateDirectories: true)
    try Data("gitdir: \(gitWorktree.path)\n".utf8).write(
        to: linkedWorktree.appending(path: ".git")
    )

    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let threadID = "52200000-0000-0000-0000-000000000001"
    let rollout = sessions.appending(path: "\(threadID).jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    try createCodexCLITitleDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        rows: [
            (threadID, rollout.path, "Linked worktree", "", "", linkedWorktree.path)
        ]
    )

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.families.map(\.project) == ["redeven"])
}

@Test func agentStorageScannerGroupsClaudeManagedWorktreesWithTheirMainRepository() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appending(path: "redeven", directoryHint: .isDirectory)
    let gitWorktrees = repository.appending(path: ".git/worktrees", directoryHint: .isDirectory)
    let existingWorktree = repository.appending(
        path: ".claude/worktrees/feat-plugin-ui-redesign",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: gitWorktrees.appending(path: "feat-plugin-ui-redesign"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: existingWorktree, withIntermediateDirectories: true)
    try Data("gitdir: \(gitWorktrees.path)/feat-plugin-ui-redesign\n".utf8).write(
        to: existingWorktree.appending(path: ".git")
    )

    let claudeProject = root.appending(
        path: ".claude/projects/-fixture",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
    let existingID = "53000000-0000-0000-0000-000000000001"
    let removedID = "53000000-0000-0000-0000-000000000002"
    let removedWorktree = repository.appending(
        path: ".claude/worktrees/feat-plugin-ui-redesign-v2",
        directoryHint: .isDirectory
    )
    try """
    {"type":"user","sessionId":"\(existingID)","cwd":"\(existingWorktree.path)","message":{"role":"user","content":"Existing"}}
    """.data(using: .utf8)!.write(to: claudeProject.appending(path: "\(existingID).jsonl"))
    try """
    {"type":"user","sessionId":"\(removedID)","cwd":"\(removedWorktree.path)","message":{"role":"user","content":"Removed"}}
    """.data(using: .utf8)!.write(to: claudeProject.appending(path: "\(removedID).jsonl"))

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.families.count == 2)
    #expect(Set(snapshot.families.map(\.project)) == ["redeven"])
}

@Test func agentStorageScannerReportsUnsupportedCodexSchemaWithoutFailingSnapshot() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    var database: OpaquePointer?
    let databaseURL = codex.appending(path: "state_5.sqlite")
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let handle = try #require(database)
    try executeSQL(handle, "CREATE TABLE threads (id TEXT PRIMARY KEY, future_payload BLOB)")
    sqlite3_close_v2(handle)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    let summary = try #require(snapshot.providers.first { $0.provider == .codex })
    #expect(summary.supportStatus == .unsupportedFormat)
    #expect(summary.unsupportedSourceCount == 1)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
    #expect(!snapshot.coverage.isComplete)
}

@Test func agentStorageScannerAcceptsUnknownClaudeEventsWithValidSessionIdentity() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: ".claude/projects/-tmp-future", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "52000000-0000-0000-0000-000000000001"
    try Data("{\"type\":\"future-event\",\"sessionId\":\"\(sessionID)\",\"timestamp\":\"2026-07-28T08:00:00.000Z\"}\n".utf8)
        .write(to: project.appending(path: "\(sessionID).jsonl"))

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    #expect(snapshot.families.contains { $0.nativeThreadID == sessionID })
    let summary = try #require(snapshot.providers.first { $0.provider == .claude })
    #expect(summary.supportStatus == .supported)
}

@Test func agentStorageScannerDistinguishesUnsupportedAndDamagedClaudeData() async throws {
    let unsupportedRoot = makeTemporaryRoot()
    let damagedRoot = makeTemporaryRoot()
    defer {
        try? FileManager.default.removeItem(at: unsupportedRoot)
        try? FileManager.default.removeItem(at: damagedRoot)
    }
    let unsupportedProject = unsupportedRoot.appending(
        path: ".claude/projects/-tmp-unsupported",
        directoryHint: .isDirectory
    )
    let damagedProject = damagedRoot.appending(
        path: ".claude/projects/-tmp-damaged",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: unsupportedProject, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: damagedProject, withIntermediateDirectories: true)
    let unsupportedID = "53000000-0000-0000-0000-000000000001"
    let damagedID = "53000000-0000-0000-0000-000000000002"
    try Data("{\"type\":\"future-session\",\"conversationKey\":\"new-format\"}\n".utf8)
        .write(to: unsupportedProject.appending(path: "\(unsupportedID).jsonl"))
    try Data("{not-json\n".utf8)
        .write(to: damagedProject.appending(path: "\(damagedID).jsonl"))

    let unsupported = try await AgentStorageScanner(configuration: .init(
        homeDirectory: unsupportedRoot,
        includesDesktopData: false
    )).scan()
    let damaged = try await AgentStorageScanner(configuration: .init(
        homeDirectory: damagedRoot,
        includesDesktopData: false
    )).scan()
    #expect(unsupported.providers.first { $0.provider == .claude }?.supportStatus == .unsupportedFormat)
    #expect(damaged.providers.first { $0.provider == .claude }?.supportStatus == .partial)
    #expect(unsupported.coverage.measuredBytes == unsupported.coverage.classifiedBytes)
    #expect(damaged.coverage.measuredBytes == damaged.coverage.classifiedBytes)
    #expect(unsupported.coverage.isPhysicalMeasurementComplete)
    #expect(damaged.coverage.isPhysicalMeasurementComplete)
    #expect(unsupported.diagnostics.map(\.kind) == [.sourceUnsupportedFormat])
    #expect(damaged.diagnostics.map(\.kind) == [.mainTranscriptUnreadable])
    #expect(damaged.diagnostics.first?.affectedAllocatedBytes == allocatedBytes(
        of: damagedProject.appending(path: "\(damagedID).jsonl")
    ))
    #expect(damaged.providers.first { $0.provider == .claude }?.issueCount == 1)
}

@Test func agentStorageScannerKeepsValidClaudeIdentityWhenOneRecordIsDamaged() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(
        path: ".claude/projects/-tmp-partial",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = "54000000-0000-0000-0000-000000000001"
    let transcript = project.appending(path: "\(sessionID).jsonl")
    try Data("""
    {"type":"user","sessionId":"\(sessionID)","cwd":"/tmp/partial","message":{"role":"user","content":"Keep me"}}
    {not-json
    """.utf8).write(to: transcript)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.families.contains { $0.nativeThreadID == sessionID })
    #expect(snapshot.coverage.isPhysicalMeasurementComplete)
    #expect(!snapshot.coverage.isComplete)
    let diagnostic = try #require(snapshot.diagnostics.first)
    #expect(snapshot.diagnostics.count == 1)
    #expect(diagnostic.kind == .malformedTranscriptRecords)
    #expect(diagnostic.impact == .chatMetadata)
    #expect(diagnostic.affectedEntityCount == 1)
    #expect(diagnostic.affectedAllocatedBytes == nil)
    let summary = try #require(snapshot.providers.first { $0.provider == .claude })
    #expect(summary.attributionStatus == .partial)
    #expect(summary.issueCount == 1)
    #expect(summary.knownAffectedBytes == 0)
}

@Test func agentStorageScannerClassifiesClaudeMetadataOnlyAndAmbiguousToolResults() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(
        path: ".claude/projects/-tmp-diagnostics",
        directoryHint: .isDirectory
    )
    let sessionID = "55000000-0000-0000-0000-000000000001"
    let sessionDirectory = project.appending(path: sessionID, directoryHint: .isDirectory)
    let subagents = sessionDirectory.appending(path: "subagents", directoryHint: .isDirectory)
    let toolResults = sessionDirectory.appending(path: "tool-results", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    let firstDirectory = toolResults.appending(path: "first", directoryHint: .isDirectory)
    let secondDirectory = toolResults.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    let mainRecord = "{\"type\":\"user\",\"sessionId\":\"\(sessionID)\",\"cwd\":\"/tmp/diagnostics\"}\n"
    try Data(mainRecord.utf8).write(to: project.appending(path: "\(sessionID).jsonl"))
    try Data("{\"description\":\"Metadata only\",\"spawnDepth\":1}".utf8)
        .write(to: subagents.appending(path: "agent-metadata.meta.json"))
    let firstTool = firstDirectory.appending(path: "duplicate.txt")
    let secondTool = secondDirectory.appending(path: "duplicate.txt")
    try Data(repeating: 0x41, count: 4_096).write(to: firstTool)
    try Data(repeating: 0x42, count: 8_192).write(to: secondTool)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    let diagnostics = Dictionary(uniqueKeysWithValues: snapshot.diagnostics.map { ($0.kind, $0) })
    let metadataOnly = try #require(diagnostics[.subagentMetadataOnly])
    let ambiguousTool = try #require(diagnostics[.ambiguousToolResult])
    #expect(snapshot.diagnostics.count == 2)
    #expect(metadataOnly.area == .subagent)
    #expect(metadataOnly.affectedAllocatedBytes == nil)
    #expect(ambiguousTool.area == .toolResult)
    #expect(ambiguousTool.affectedEntityCount == 2)
    #expect(ambiguousTool.affectedAllocatedBytes
        == allocatedBytes(of: firstTool) + allocatedBytes(of: secondTool))
    #expect(snapshot.coverage.isPhysicalMeasurementComplete)
    #expect(!snapshot.coverage.isComplete)
    let summary = try #require(snapshot.providers.first { $0.provider == .claude })
    #expect(summary.issueCount == 2)
    #expect(summary.attributionStatus == .partial)
    #expect(summary.knownAffectedBytes == ambiguousTool.affectedAllocatedBytes)
}

@Test func agentStorageTimeProjectionIncludesCompleteThreadFamiliesAtBoundary() throws {
    let cutoff = Date(timeIntervalSince1970: 1_000)
    let before = makeFamily(id: "before", updatedAt: cutoff.addingTimeInterval(-1), main: 10, subagent: 5, other: 2)
    let boundary = makeFamily(id: "boundary", updatedAt: cutoff, main: 20, subagent: 7, other: 3)
    let after = makeFamily(id: "after", updatedAt: cutoff.addingTimeInterval(1), main: 30, subagent: 11, other: 4)
    let dataset = AgentStorageProviderDataset(
        provider: .codex,
        families: [before, boundary, after],
        globalItems: [],
        unattributedItems: []
    )

    let upperBound = cutoff.addingTimeInterval(2)
    let future = makeFamily(id: "future", updatedAt: upperBound, main: 40, subagent: 13, other: 5)
    let boundedDataset = AgentStorageProviderDataset(
        provider: .codex,
        families: dataset.families + [future],
        globalItems: [],
        unattributedItems: []
    )
    let projection = boundedDataset.chatProjection(since: cutoff, before: upperBound)
    #expect(projection.families.map(\.id).sorted() == ["after", "boundary"])
    #expect(projection.mainThreadCount == 2)
    #expect(projection.subagentCount == 2)
    #expect(projection.mainThreadBytes == 50)
    #expect(projection.subagentBytes == 18)
    #expect(projection.familyOtherBytes == 7)
    #expect(projection.chatBytes == 75)
}

@Test func agentStorageScannerRejectsMismatchedClaudeSessionIDs() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: ".claude/projects/-tmp-invalid", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let fileID = "30000000-0000-0000-0000-000000000001"
    let otherID = "30000000-0000-0000-0000-000000000002"
    try Data("{\"sessionId\":\"\(otherID)\",\"type\":\"user\"}\n".utf8)
        .write(to: project.appending(path: "\(fileID).jsonl"))

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()

    #expect(snapshot.families.allSatisfy { $0.provider != .claude })
    #expect(snapshot.unattributedItems.contains { $0.provider == .claude && $0.allocatedBytes > 0 })
    #expect(!snapshot.coverage.isComplete)
    #expect(snapshot.coverage.isPhysicalMeasurementComplete)
    let diagnostic = try #require(snapshot.diagnostics.first)
    #expect(snapshot.diagnostics.count == 1)
    #expect(diagnostic.kind == .sessionIdentityMismatch)
    #expect(diagnostic.impact == .chatDiscovery)
    #expect(diagnostic.affectedAllocatedBytes == allocatedBytes(
        of: project.appending(path: "\(fileID).jsonl")
    ))
}

@Test func agentStorageScannerKeepsInvalidCodexRelationshipsUnattributed() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appending(path: ".codex", directoryHint: .isDirectory)
    let sessions = codex.appending(path: "sessions/2026/07/28", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let rootID = "40000000-0000-0000-0000-000000000001"
    let orphanID = "40000000-0000-0000-0000-000000000002"
    let orphanChildID = "40000000-0000-0000-0000-000000000005"
    let cycleA = "40000000-0000-0000-0000-000000000003"
    let cycleB = "40000000-0000-0000-0000-000000000004"
    let ids = [rootID, orphanID, orphanChildID, cycleA, cycleB]
    var paths: [String: String] = [:]
    for id in ids {
        let file = sessions.appending(path: "rollout-2026-07-28-\(id.uppercased()).jsonl")
        try Data(repeating: 0x41, count: 4_096).write(to: file)
        paths[id] = file.path
    }
    try createCodexRelationshipDatabase(
        at: codex.appending(path: "state_5.sqlite"),
        paths: paths,
        rootID: rootID,
        orphanID: orphanID,
        orphanChildID: orphanChildID,
        cycleA: cycleA,
        cycleB: cycleB
    )

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    let codexFamilies = snapshot.families.filter { $0.provider == .codex }
    #expect(codexFamilies.count == 1)
    #expect(codexFamilies[0].nativeThreadID == rootID)
    #expect(codexFamilies[0].subagentCount == 0)
    #expect(snapshot.unattributedItems.contains {
        $0.provider == .codex && $0.reason == .relationshipConflict && $0.artifactCount >= 4
    })
    #expect(!snapshot.coverage.isComplete)
}

@Test func agentStorageScannerDeduplicatesCrossProviderHardLinks() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codexCache = root.appending(path: ".codex/cache", directoryHint: .isDirectory)
    let claudeBackup = root.appending(path: ".claude/backups", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codexCache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeBackup, withIntermediateDirectories: true)
    let original = codexCache.appending(path: "shared.bin")
    let link = claudeBackup.appending(path: "shared.bin")
    try Data(repeating: 0x55, count: 16_384).write(to: original)
    try FileManager.default.linkItem(at: original, to: link)

    let snapshot = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan()
    #expect(snapshot.crossAgentSharedBytes == allocatedBytes(of: original))
    #expect(snapshot.globalItems.filter { $0.category == .crossAgentShared }.count == 1)
    #expect(snapshot.providerDatasets.allSatisfy {
        $0.globalItems.allSatisfy { $0.category != .crossAgentShared }
    })
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
}

@Test func liveAgentStorageScannerReconcilesWhenExplicitlyEnabled() async throws {
    guard ProcessInfo.processInfo.environment["RUN_AGENT_STORAGE_LIVE_SCAN"] == "1" else { return }
    let snapshot = try await AgentStorageScanner().scan()
    let databasePhysicalBytes = snapshot.databaseAttributions.reduce(UInt64(0)) {
        $0.addingReportingOverflow($1.physicalBundleBytes).partialValue
    }
    let databaseAttributedBytes = snapshot.databaseAttributions.reduce(UInt64(0)) {
        $0.addingReportingOverflow($1.attributedBytes).partialValue
    }
    let databaseResidualBytes = snapshot.databaseAttributions.reduce(UInt64(0)) {
        $0.addingReportingOverflow($1.residualBytes).partialValue
    }
    print(
        "agent-storage-live total=\(snapshot.totalBytes) "
            + "families=\(snapshot.families.count) "
            + "subagents=\(snapshot.families.reduce(0) { $0 + $1.subagentCount }) "
            + "measured=\(snapshot.coverage.measuredBytes) "
            + "classified=\(snapshot.coverage.classifiedBytes) "
            + "databaseBundles=\(snapshot.databaseAttributions.count) "
            + "databasePhysical=\(databasePhysicalBytes) "
            + "databaseAttributed=\(databaseAttributedBytes) "
            + "databaseResidual=\(databaseResidualBytes)"
    )
    #expect(snapshot.totalBytes == snapshot.coverage.classifiedBytes)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
    #expect(snapshot.databaseAttributions.allSatisfy {
        $0.attributedBytes + $0.residualBytes == $0.physicalBundleBytes
    })
}

@Test func agentStorageScannerReportsMeasuredProgressFromRealEntries() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appending(path: ".codex/sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    for index in 0..<300 {
        try Data([UInt8(index % 255)]).write(
            to: sessions.appending(path: "entry-\(index).bin")
        )
    }

    let recorder = AgentStorageProgressRecorder()
    _ = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan { recorder.append($0) }

    let updates = recorder.values
    #expect(Set(updates.map(\.phase)) == Set(AgentStorageScanPhase.allCases))
    #expect(updates.filter { $0.phase == .measuringEntries }
        .map(\.completedCount).max() ?? 0 >= 300)
    let validatingUpdates = updates.filter { $0.phase == .validatingEntries }
    #expect((validatingUpdates.last?.completedCount ?? 0) > 0)
    #expect(validatingUpdates.last?.completedCount == validatingUpdates.last?.totalCount)
    #expect(zip(validatingUpdates, validatingUpdates.dropFirst()).allSatisfy {
        $0.0.completedCount <= $0.1.completedCount
    })
    #expect(updates.last?.phase == .organizingResults)
    #expect(updates.last?.completedCount == updates.last?.totalCount)
}

@Test func agentStorageProviderPipelinesAdvanceInParallel() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appending(path: ".codex/sessions", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appending(path: ".claude/projects", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    let probe = AgentStorageProviderConcurrencyProbe()

    _ = try await AgentStorageScanner(configuration: .init(
        homeDirectory: root,
        includesDesktopData: false
    )).scan { probe.observe($0) }

    #expect(probe.didOverlap)
    #expect(probe.providers == Set(AgentStorageProvider.allCases))
}

private final class AgentStorageProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentStorageScanProgress] = []

    var values: [AgentStorageScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: AgentStorageScanProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}

private final class AgentStorageProviderConcurrencyProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var observedProviders: Set<AgentStorageProvider> = []
    private var firstProviderIsWaiting = false
    private var overlap = false

    var didOverlap: Bool {
        condition.lock()
        defer { condition.unlock() }
        return overlap
    }

    var providers: Set<AgentStorageProvider> {
        condition.lock()
        defer { condition.unlock() }
        return observedProviders
    }

    func observe(_ progress: AgentStorageScanProgress) {
        guard progress.phase == .measuringEntries,
              progress.completedCount == 0,
              let provider = progress.provider else { return }
        condition.lock()
        guard observedProviders.insert(provider).inserted else {
            condition.unlock()
            return
        }
        if observedProviders.count == 1 {
            firstProviderIsWaiting = true
            _ = condition.wait(until: Date().addingTimeInterval(0.5))
            firstProviderIsWaiting = false
        } else if firstProviderIsWaiting {
            overlap = true
            condition.broadcast()
        }
        condition.unlock()
    }
}

private final class AgentStorageDatabaseShardConcurrencyProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeShardStarts = 0
    private var maximumActiveShardStarts = 0

    var didOverlap: Bool {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveShardStarts > 1
    }

    var maximumConcurrentShardStarts: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveShardStarts
    }

    func enterShard() {
        condition.lock()
        activeShardStarts += 1
        maximumActiveShardStarts = max(maximumActiveShardStarts, activeShardStarts)
        if activeShardStarts == 1 {
            _ = condition.wait(until: Date().addingTimeInterval(1))
        } else {
            condition.broadcast()
        }
        activeShardStarts -= 1
        condition.unlock()
    }
}

private final class AgentStorageDatabaseShardCancellationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readerCount = 0
    private var readersAreReleased = false

    func holdReader() {
        condition.lock()
        readerCount += 1
        condition.broadcast()
        while !readersAreReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitForReaders(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while readerCount < expectedCount {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseReaders() {
        condition.lock()
        readersAreReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class OneShotFileReplacer: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var attempted = false
    private var replaced = false

    init(url: URL) {
        self.url = url
    }

    var didReplace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return replaced
    }

    func replace() {
        lock.lock()
        guard !attempted else {
            lock.unlock()
            return
        }
        attempted = true
        lock.unlock()
        let original = url.appendingPathExtension("original")
        do {
            try FileManager.default.moveItem(at: url, to: original)
            try FileManager.default.copyItem(at: original, to: url)
            lock.lock()
            replaced = true
            lock.unlock()
        } catch {
            try? FileManager.default.moveItem(at: original, to: url)
        }
    }
}

private final class ConcurrentCodexLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let url: URL
    private let threadID: String
    private var started = false
    private var committed = false
    private var completedDuringReadSnapshot = false
    private var result = SQLITE_ERROR

    init(url: URL, threadID: String) {
        self.url = url
        self.threadID = threadID
    }

    var didCommit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    var sqliteResult: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    var didCompleteDuringReadSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completedDuringReadSnapshot
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            var database: OpaquePointer?
            let openResult = sqlite3_open_v2(
                url.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openResult == SQLITE_OK, let database else {
                finish(result: openResult, committed: false)
                return
            }
            defer { sqlite3_close_v2(database) }
            sqlite3_busy_timeout(database, 0)
            let sql = """
            SELECT COUNT(*) FROM logs;
            BEGIN IMMEDIATE;
            INSERT INTO logs (thread_id, estimated_bytes, feedback_log_body)
            VALUES ('\(threadID)', 64, NULL);
            COMMIT;
            """
            let writeResult = sqlite3_exec(database, sql, nil, nil, nil)
            finish(result: writeResult, committed: writeResult == SQLITE_OK)
        }
    }

    func waitForCompletion() -> Bool {
        group.wait(timeout: .now() + 5) == .success
    }

    func waitForCompletionDuringReadSnapshot(timeoutMilliseconds: Int) {
        let completed = group.wait(
            timeout: .now() + .milliseconds(timeoutMilliseconds)
        ) == .success
        lock.lock()
        completedDuringReadSnapshot = completed
        lock.unlock()
    }

    private func finish(result: Int32, committed: Bool) {
        lock.lock()
        self.result = result
        self.committed = committed
        lock.unlock()
    }
}

private func createCodexStateDatabase(
    at url: URL,
    mainID: String,
    childID: String,
    mainRollout: String,
    childRollout: String
) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let handle = try #require(database)
    defer { sqlite3_close_v2(handle) }
    let statements = [
        """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          rollout_path TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          cwd TEXT NOT NULL,
          title TEXT NOT NULL,
          archived INTEGER NOT NULL DEFAULT 0,
          agent_nickname TEXT,
          name TEXT
        )
        """,
        """
        CREATE TABLE thread_spawn_edges (
          parent_thread_id TEXT NOT NULL,
          child_thread_id TEXT NOT NULL PRIMARY KEY,
          status TEXT NOT NULL
        )
        """,
        """
        INSERT INTO threads VALUES
          ('\(mainID)', '\(mainRollout)', 1785225600, '/tmp/demo', 'Main fixture', 0, NULL, NULL),
          ('\(childID)', '\(childRollout)', 1785225660, '/tmp/demo', 'Child fixture', 0, 'Review child', NULL)
        """,
        "INSERT INTO thread_spawn_edges VALUES ('\(mainID)', '\(childID)', 'completed')"
    ]
    for statement in statements {
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
            throw FixtureDatabaseError.sqliteFailure
        }
    }
}

private func createCodexLogsDatabase(
    at url: URL,
    rows: [(threadID: String?, estimatedBytes: UInt64)],
    feedbackBodyBytes: Int = 16_384
) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let handle = try #require(database)
    defer { sqlite3_close_v2(handle) }
    try executeSQL(handle, "PRAGMA journal_mode = WAL")
    try executeSQL(handle, "PRAGMA wal_autocheckpoint = 0")
    try executeSQL(handle, """
        CREATE TABLE logs (
          id INTEGER PRIMARY KEY,
          thread_id TEXT,
          estimated_bytes INTEGER NOT NULL,
          feedback_log_body BLOB
        )
        """)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, row) in rows.enumerated() {
        guard row.estimatedBytes <= UInt64(Int64.max) else {
            throw FixtureDatabaseError.sqliteFailure
        }
        var statement: OpaquePointer?
        let sql = "INSERT INTO logs (id, thread_id, estimated_bytes, feedback_log_body) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureDatabaseError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(index + 1)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, Int64(row.estimatedBytes)) == SQLITE_OK
        else { throw FixtureDatabaseError.sqliteFailure }
        if let threadID = row.threadID {
            guard sqlite3_bind_text(statement, 2, threadID, -1, transient) == SQLITE_OK else {
                throw FixtureDatabaseError.sqliteFailure
            }
        } else {
            guard sqlite3_bind_null(statement, 2) == SQLITE_OK else {
                throw FixtureDatabaseError.sqliteFailure
            }
        }
        let privateBody = Data(
            repeating: UInt8(truncatingIfNeeded: index),
            count: feedbackBodyBytes
        )
        let bodyResult = privateBody.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard bodyResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureDatabaseError.sqliteFailure
        }
    }
    try executeSQL(handle, "PRAGMA wal_checkpoint(TRUNCATE)")
}

private func createUnsupportedCodexLogsDatabase(at url: URL) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let handle = try #require(database)
    defer { sqlite3_close_v2(handle) }
    try executeSQL(handle, "PRAGMA journal_mode = WAL")
    try executeSQL(handle, "CREATE TABLE logs (id INTEGER PRIMARY KEY, thread_id TEXT)")
    try executeSQL(handle, "INSERT INTO logs VALUES (1, 'unsupported')")
}

private func createCodexRelationshipDatabase(
    at url: URL,
    paths: [String: String],
    rootID: String,
    orphanID: String,
    orphanChildID: String,
    cycleA: String,
    cycleB: String
) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let handle = try #require(database)
    defer { sqlite3_close_v2(handle) }
    try executeSQL(handle, """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          rollout_path TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          cwd TEXT NOT NULL,
          title TEXT NOT NULL,
          archived INTEGER NOT NULL DEFAULT 0,
          source TEXT NOT NULL,
          agent_nickname TEXT,
          name TEXT,
          agent_path TEXT,
          agent_role TEXT
        )
        """)
    try executeSQL(handle, """
        CREATE TABLE thread_spawn_edges (
          parent_thread_id TEXT NOT NULL,
          child_thread_id TEXT NOT NULL,
          status TEXT NOT NULL
        )
        """)
    try executeSQL(handle, """
        INSERT INTO threads VALUES
          ('\(rootID.uppercased())', '\(paths[rootID]!)', 1785225600, '/tmp/demo', 'Root', 0, 'cli', NULL, NULL, NULL, NULL),
          ('\(orphanChildID)', '\(paths[orphanChildID]!)', 1785225600, '/tmp/demo', 'Orphan child', 0, '{"subagent":{}}', NULL, NULL, '/root/orphan-child', NULL),
          ('\(orphanID)', '\(paths[orphanID]!)', 1785225600, '/tmp/demo', 'Orphan', 0, '{"subagent":{}}', NULL, NULL, '/root/orphan', NULL),
          ('\(cycleA)', '\(paths[cycleA]!)', 1785225600, '/tmp/demo', 'Cycle A', 0, '{"subagent":{}}', NULL, NULL, '/root/a', NULL),
          ('\(cycleB)', '\(paths[cycleB]!)', 1785225600, '/tmp/demo', 'Cycle B', 0, '{"subagent":{}}', NULL, NULL, '/root/b', NULL)
        """)
    try executeSQL(
        handle,
        "INSERT INTO thread_spawn_edges VALUES ('\(orphanID)', '\(orphanChildID)', 'open'), ('\(cycleB)', '\(cycleA)', 'open'), ('\(cycleA)', '\(cycleB)', 'open')"
    )
}

private func createCodexCLITitleDatabase(
    at url: URL,
    rows: [(id: String, rollout: String, title: String, firstUser: String, preview: String, cwd: String)],
    gitOriginURL: String? = nil
) throws {
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let handle = try #require(database)
    defer { sqlite3_close_v2(handle) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    try executeSQL(handle, """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          rollout_path TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          updated_at_ms INTEGER,
          cwd TEXT,
          title TEXT,
          first_user_message TEXT,
          preview TEXT,
          git_origin_url TEXT,
          archived INTEGER DEFAULT 0
        )
        """)
    for row in rows {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO threads
          (id, rollout_path, updated_at, updated_at_ms, cwd, title, first_user_message, preview, git_origin_url, archived)
        VALUES (?, ?, 1785225600, 1785225600123, ?, ?, ?, ?, ?, 0)
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureDatabaseError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        for (index, value) in [row.id, row.rollout, row.cwd, row.title, row.firstUser, row.preview]
            .enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK
            else { throw FixtureDatabaseError.sqliteFailure }
        }
        if let gitOriginURL {
            guard sqlite3_bind_text(statement, 7, gitOriginURL, -1, transient) == SQLITE_OK else {
                throw FixtureDatabaseError.sqliteFailure
            }
        } else {
            guard sqlite3_bind_null(statement, 7) == SQLITE_OK else {
                throw FixtureDatabaseError.sqliteFailure
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureDatabaseError.sqliteFailure
        }
    }
}

private func makeFamily(
    id: String,
    updatedAt: Date,
    main: UInt64,
    subagent: UInt64,
    other: UInt64
) -> AgentStorageThreadFamily {
    AgentStorageThreadFamily(
        id: id,
        provider: .codex,
        sourceID: "fixture",
        nativeThreadID: id,
        title: id,
        project: "fixture",
        updatedAt: updatedAt,
        isArchived: false,
        mainAllocatedBytes: main,
        subagentAllocatedBytes: subagent,
        familyOtherAllocatedBytes: other,
        artifactCount: 3,
        path: nil,
        subagents: [
            AgentStorageThreadNode(
                id: "\(id)-child",
                nativeID: "\(id)-child",
                parentID: id,
                depth: 1,
                title: "Child",
                updatedAt: updatedAt,
                allocatedBytes: subagent,
                artifactCount: 1,
                path: nil
            )
        ],
        composition: [.conversation: main, .subagent: subagent, .other: other]
    )
}

private func executeSQL(_ database: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw FixtureDatabaseError.sqliteFailure
    }
}

private func makeTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private func allocatedBytes(of url: URL) -> UInt64 {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return 0 }
    return UInt64(max(0, value.st_blocks)) * 512
}

private func fileSystemSignature(_ url: URL) throws -> [Int64] {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw FixtureDatabaseError.sqliteFailure }
    return [
        Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_size), Int64(value.st_blocks),
        Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec)
    ]
}

private func cleanupIdentity(_ artifact: AgentStorageCleanupArtifact) -> [UInt64] {
    [artifact.device, artifact.inode]
}

private func cleanupIdentity(_ url: URL) -> [UInt64] {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return [] }
    return [UInt64(value.st_dev), UInt64(value.st_ino)]
}

private enum FixtureDatabaseError: Error {
    case sqliteFailure
}
