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
    let claudeSummary = try #require(snapshot.providers.first { $0.provider == .claude })
    #expect(claudeSummary.unstableEntryCount > 0)
    #expect(claudeSummary.supportStatus == .partial)
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
    print(
        "agent-storage-live total=\(snapshot.totalBytes) "
            + "families=\(snapshot.families.count) "
            + "subagents=\(snapshot.families.reduce(0) { $0 + $1.subagentCount }) "
            + "measured=\(snapshot.coverage.measuredBytes) "
            + "classified=\(snapshot.coverage.classifiedBytes)"
    )
    #expect(snapshot.totalBytes == snapshot.coverage.classifiedBytes)
    #expect(snapshot.coverage.measuredBytes == snapshot.coverage.classifiedBytes)
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
    rows: [(id: String, rollout: String, title: String, firstUser: String, preview: String, cwd: String)]
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
          archived INTEGER DEFAULT 0
        )
        """)
    for row in rows {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO threads
          (id, rollout_path, updated_at, updated_at_ms, cwd, title, first_user_message, preview, archived)
        VALUES (?, ?, 1785225600, 1785225600123, ?, ?, ?, ?, 0)
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureDatabaseError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        for (index, value) in [row.id, row.rollout, row.cwd, row.title, row.firstUser, row.preview]
            .enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK
            else { throw FixtureDatabaseError.sqliteFailure }
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

private enum FixtureDatabaseError: Error {
    case sqliteFailure
}
