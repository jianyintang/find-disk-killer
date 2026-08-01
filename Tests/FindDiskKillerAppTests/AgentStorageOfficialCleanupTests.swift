import Darwin
import Foundation
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

private actor FakeCleanupAdapter: AgentStorageCleanupCapabilityProviding {
    let availabilityValue: AgentStorageCleanupAvailability
    let outcomes: [AgentStorageCleanupOutcome]
    private(set) var deletedIDs: [String] = []

    init(
        availability: AgentStorageCleanupAvailability = .ready,
        outcomes: [AgentStorageCleanupOutcome] = [.succeeded]
    ) {
        availabilityValue = availability
        self.outcomes = outcomes
    }

    func availability(for family: AgentStorageThreadFamily) -> AgentStorageCleanupAvailability {
        availabilityValue
    }

    func delete(_ family: AgentStorageThreadFamily) -> AgentStorageCleanupOutcome {
        deletedIDs.append(family.nativeThreadID)
        return outcomes[min(deletedIDs.count - 1, outcomes.count - 1)]
    }
}

private struct FakeActivityInspector: AgentStorageCleanupActivityInspecting {
    let hasWriter: Bool
    func isActive(
        family: AgentStorageThreadFamily,
        artifacts: [AgentStorageCleanupArtifact]
    ) async throws -> Bool {
        hasWriter
    }
}

private actor CancellationGate {
    private var checks = 0
    func shouldCancelAfterFirstSubmission() -> Bool {
        defer { checks += 1 }
        return checks > 0
    }
}

@Test func cleanupOfficialFailureNeverFallsBackToFileDeletion() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let adapter = FakeCleanupAdapter(outcomes: [.failed("official failure")])
    let coordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        claude: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let prepared = await coordinator.prepare(AgentStorageCleanupReview(families: fixture.families))
    let result = await coordinator.execute(prepared, shouldCancel: { false }, didUpdate: { _ in })

    #expect(result.failedCount == 1)
    #expect(!result.changedStorage)
    #expect(FileManager.default.fileExists(atPath: fixture.artifactURLs[0].path))
    #expect(try Data(contentsOf: fixture.artifactURLs[0]) == fixture.contents)
}

@Test func cleanupResultInvalidatesTheSnapshotOnlyAfterOfficialSuccess() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let adapter = FakeCleanupAdapter(outcomes: [.succeeded])
    let coordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        claude: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let prepared = await coordinator.prepare(AgentStorageCleanupReview(families: fixture.families))
    let result = await coordinator.execute(prepared, shouldCancel: { false }, didUpdate: { _ in })

    #expect(result.succeededCount == 1)
    #expect(result.changedStorage)
}

@Test func cleanupActivityAndIdentityGatesSkipWithoutProviderCall() async throws {
    let activeFixture = try CleanupFixture(provider: .codex, count: 1)
    defer { activeFixture.destroy() }
    let adapter = FakeCleanupAdapter()
    let activeCoordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        claude: adapter,
        activityInspector: FakeActivityInspector(hasWriter: true)
    )
    let active = await activeCoordinator.prepare(
        AgentStorageCleanupReview(families: activeFixture.families)
    )
    #expect(active.first?.availability == .active)

    let changedFixture = try CleanupFixture(provider: .codex, count: 1)
    defer { changedFixture.destroy() }
    try Data(repeating: 0x42, count: 8_192).write(to: changedFixture.artifactURLs[0])
    let changedCoordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        claude: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let changed = await changedCoordinator.prepare(
        AgentStorageCleanupReview(families: changedFixture.families)
    )
    #expect(changed.first?.availability == .changed)
    #expect(await adapter.deletedIDs.isEmpty)
}

@Test func cleanupDetectsARealOpenWriterWithoutWaitingOrTakingALock() async throws {
    let fixture = try CleanupFixture(provider: .claude, count: 1)
    defer { fixture.destroy() }
    let descriptor = Darwin.open(fixture.artifactURLs[0].path, O_WRONLY | O_APPEND)
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { Darwin.close(descriptor) } }

    let hasWriter = try await AgentStorageLsofActivityInspector().isActive(
        family: fixture.families[0],
        artifacts: fixture.families[0].cleanupArtifacts
    )
    #expect(hasWriter)
}

@Test func cleanupTreatsAClaudeCodeProcessInTheSameProjectAsActive() async throws {
    let fixture = try CleanupFixture(provider: .claude, count: 1)
    defer { fixture.destroy() }
    let project = try #require(fixture.families[0].projectPath)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: project),
        withIntermediateDirectories: true
    )
    let executable = fixture.root.appending(path: "claude")
    try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
    let process = Process()
    process.executableURL = executable
    process.arguments = ["10"]
    process.currentDirectoryURL = URL(fileURLWithPath: project)
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let isActive = try await AgentStorageLsofActivityInspector().isActive(
        family: fixture.families[0],
        artifacts: fixture.families[0].cleanupArtifacts
    )
    #expect(isActive)
}

@Test func cleanupRejectsAChangedMainSubagentRelationship() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let original = fixture.families[0]
    let invalidSubagent = AgentStorageThreadNode(
        id: "subagent",
        nativeID: "00000000-0000-0000-0000-000000000099",
        parentID: "00000000-0000-0000-0000-000000000098",
        depth: 1,
        title: "Subagent",
        updatedAt: original.updatedAt,
        allocatedBytes: 0,
        artifactCount: 0,
        path: nil
    )
    let changed = AgentStorageThreadFamily(
        id: original.id,
        provider: original.provider,
        sourceID: original.sourceID,
        nativeThreadID: original.nativeThreadID,
        title: original.title,
        project: original.project,
        updatedAt: original.updatedAt,
        isArchived: original.isArchived,
        mainAllocatedBytes: original.mainAllocatedBytes,
        subagentAllocatedBytes: original.subagentAllocatedBytes,
        familyOtherAllocatedBytes: original.familyOtherAllocatedBytes,
        artifactCount: original.artifactCount,
        path: original.path,
        subagents: [invalidSubagent],
        composition: original.composition,
        cleanupArtifacts: original.cleanupArtifacts,
        sourceKind: original.sourceKind,
        sourcePath: original.sourcePath,
        projectPath: original.projectPath
    )
    let adapter = FakeCleanupAdapter()
    let coordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        claude: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let prepared = await coordinator.prepare(AgentStorageCleanupReview(families: [changed]))
    #expect(prepared.first?.availability == .changed)
    #expect(await adapter.deletedIDs.isEmpty)
}

@Test func cleanupSerialQueueReportsPartialFailureAndCancelsUnsubmittedTargets() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 3)
    defer { fixture.destroy() }
    let adapter = FakeCleanupAdapter(outcomes: [.failed("first failed"), .succeeded])
    let coordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        claude: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let prepared = await coordinator.prepare(AgentStorageCleanupReview(families: fixture.families))
    let gate = CancellationGate()
    let result = await coordinator.execute(
        prepared,
        shouldCancel: { await gate.shouldCancelAfterFirstSubmission() },
        didUpdate: { _ in }
    )

    #expect(result.failedCount == 1)
    #expect(result.skippedCount == 2)
    #expect(result.providersRequiringRefresh == [.codex])
    #expect(await adapter.deletedIDs == [fixture.families[0].nativeThreadID])
}

@Test func claudeDesktopAndCoworkAreNeverEnabledForInAppDeletion() async throws {
    let fixture = try CleanupFixture(
        provider: .claude,
        count: 1,
        sourceKind: .claudeDesktopAgent
    )
    defer { fixture.destroy() }
    let availability = await ClaudeSDKCleanupAdapter(helperOverride: "/bin/false")
        .availability(for: fixture.families[0])
    #expect(availability == .unsupported("请在 Claude Desktop 中删除"))
}

@Test func claudeImmediateReleaseExcludesRetainedProjectData() throws {
    let fixture = try CleanupFixture(provider: .claude, count: 1)
    defer { fixture.destroy() }
    let conversation = fixture.families[0].cleanupArtifacts[0]
    let retainedURL = fixture.root.appending(path: "tasks/task.json")
    try FileManager.default.createDirectory(
        at: retainedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try fixture.contents.write(to: retainedURL)
    let retained = try cleanupArtifactForOfficialTest(at: retainedURL, category: .task)
    let original = fixture.families[0]
    let family = AgentStorageThreadFamily(
        id: original.id,
        provider: original.provider,
        sourceID: original.sourceID,
        nativeThreadID: original.nativeThreadID,
        title: original.title,
        project: original.project,
        updatedAt: original.updatedAt,
        isArchived: false,
        mainAllocatedBytes: conversation.allocatedBytes.addingClamped(retained.allocatedBytes),
        subagentAllocatedBytes: 0,
        familyOtherAllocatedBytes: 0,
        artifactCount: 2,
        path: original.path,
        subagents: [],
        composition: [.conversation: conversation.allocatedBytes, .task: retained.allocatedBytes],
        cleanupArtifacts: [conversation, retained],
        sourceKind: .claudeCode,
        sourcePath: original.sourcePath,
        projectPath: original.projectPath
    )
    let review = AgentStorageCleanupReview(families: [family])
    #expect(review.artifacts == [conversation])
    #expect(review.reclaimableBytes == conversation.allocatedBytes)
    #expect(review.retainedBytes == retained.allocatedBytes)
}

@Test func codexVersionGateRejectsIncompatibleProtocol() {
    #expect(CodexExecutableLocator.supportsThreadDelete("codex-cli 0.146.0"))
    #expect(!CodexExecutableLocator.supportsThreadDelete("codex-cli 0.146.0-alpha.3.1"))
    #expect(!CodexExecutableLocator.supportsThreadDelete("codex-cli 0.145.9"))
    #expect(!CodexExecutableLocator.supportsThreadDelete("unexpected"))
}

@Test func codexJSONRPCUsesOfficialDeleteAndVerifiesNotFound() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let script = fixture.root.appending(path: "fake-codex")
    let homeJSON = try #require(String(data: JSONEncoder().encode(fixture.root.path), encoding: .utf8))
    let scriptText = """
    #!/usr/bin/ruby
    require 'json'
    if ARGV == ['--version']
      puts 'codex-cli 0.146.0'
      exit 0
    end
    reads = 0
    STDIN.each_line do |line|
      request = JSON.parse(line)
      next unless request['id']
      case request['method']
      when 'initialize'
        puts({id: request['id'], result: {userAgent: 'Codex fixture', codexHome: \(homeJSON), platformFamily: 'unix', platformOs: 'macos'}}.to_json)
      when 'thread/read'
        reads += 1
        if reads == 1
          puts({id: request['id'], result: {thread: {id: request['params']['threadId']}}}.to_json)
        else
          puts({id: request['id'], error: {code: -32600, message: 'thread not loaded: ' + request['params']['threadId']}}.to_json)
        end
      when 'thread/delete'
        if request['params']['threadId'] == 'find-disk-killer-capability-probe'
          puts({id: request['id'], error: {code: -32600, message: 'invalid thread id: invalid UUID'}}.to_json)
        else
          puts({id: request['id'], result: {}}.to_json)
        end
      end
      STDOUT.flush
    end
    """
    try Data(scriptText.utf8).write(to: script)
    #expect(chmod(script.path, 0o755) == 0)

    let adapter = CodexAppServerCleanupAdapter(executableOverride: script.path)
    let availability = await adapter.availability(for: fixture.families[0])
    #expect(availability == .ready)
    let outcome = await adapter.delete(fixture.families[0])
    #expect(outcome == .succeeded)
}

@Test func openCodeCleanupAcceptsOfficialXDGDataLayout() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "fdk-opencode-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: ".local/share/opencode", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("placeholder".utf8).write(to: source.appending(path: "opencode.db"))

    let adapter = FakeCleanupAdapter()
    let coordinator = AgentStorageCleanupCoordinator(
        openCode: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let family = openCodeFamily(source: source)
    let prepared = await coordinator.prepare(AgentStorageCleanupReview(families: [family]))
    #expect(prepared.first?.availability == .ready)

    let result = await coordinator.execute(prepared, shouldCancel: { false }, didUpdate: { _ in })
    #expect(result.succeededCount == 1)
    #expect(await adapter.deletedIDs == [family.nativeThreadID])
}

@Test func openCodeCleanupRejectsArbitraryOpencodeNamedDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "fdk-opencode-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "custom/opencode", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("placeholder".utf8).write(to: source.appending(path: "opencode.db"))

    let adapter = FakeCleanupAdapter()
    let coordinator = AgentStorageCleanupCoordinator(
        openCode: adapter,
        activityInspector: FakeActivityInspector(hasWriter: false)
    )
    let prepared = await coordinator.prepare(
        AgentStorageCleanupReview(families: [openCodeFamily(source: source)])
    )

    #expect(prepared.first?.availability == .changed)
    #expect(await adapter.deletedIDs.isEmpty)
}

private final class CleanupFixture {
    let root: URL
    let contents = Data(repeating: 0x41, count: 4_096)
    let artifactURLs: [URL]
    let families: [AgentStorageThreadFamily]

    init(
        provider: AgentStorageProvider,
        count: Int,
        sourceKind: AgentStorageSourceKind? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "fdk-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var urls: [URL] = []
        var values: [AgentStorageThreadFamily] = []
        for index in 0..<count {
            let threadID = String(format: "00000000-0000-0000-0000-%012d", index + 1)
            let url = root.appending(path: "projects/project/\(threadID).jsonl")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url)
            let artifact = try cleanupArtifactForOfficialTest(at: url, category: .conversation)
            urls.append(url)
            values.append(AgentStorageThreadFamily(
                id: "family-\(index)",
                provider: provider,
                sourceID: "\(provider.rawValue):\(root.path)",
                nativeThreadID: threadID,
                title: "Thread \(index + 1)",
                project: "Project",
                updatedAt: Date(timeIntervalSince1970: Double(count - index)),
                isArchived: false,
                mainAllocatedBytes: artifact.allocatedBytes,
                subagentAllocatedBytes: 0,
                familyOtherAllocatedBytes: 0,
                artifactCount: 1,
                path: url.path,
                subagents: [],
                composition: [.conversation: artifact.allocatedBytes],
                cleanupArtifacts: [artifact],
                sourceKind: sourceKind ?? (provider == .codex ? .codexHome : .claudeCode),
                sourcePath: root.path,
                projectPath: root.appending(path: "workspace").path
            ))
        }
        artifactURLs = urls
        families = values
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }
}

private func openCodeFamily(source: URL) -> AgentStorageThreadFamily {
    AgentStorageThreadFamily(
        id: "opencode-family",
        provider: .openCode,
        sourceID: "openCode:\(source.path)",
        nativeThreadID: "ses_root",
        title: "OpenCode Session",
        project: "Project",
        updatedAt: Date(timeIntervalSince1970: 1),
        isArchived: false,
        mainAllocatedBytes: 128,
        subagentAllocatedBytes: 0,
        familyOtherAllocatedBytes: 0,
        artifactCount: 0,
        path: source.appending(path: "opencode.db").path,
        subagents: [],
        composition: [.conversation: 128],
        cleanupArtifacts: [],
        sourceKind: .openCode,
        sourcePath: source.path,
        projectPath: "/tmp/opencode-project"
    )
}

private func cleanupArtifactForOfficialTest(
    at url: URL,
    category: AgentStorageArtifactCategory
) throws -> AgentStorageCleanupArtifact {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
    return AgentStorageCleanupArtifact(
        path: url.path,
        allocatedBytes: UInt64(max(0, value.st_blocks)) * 512,
        device: UInt64(value.st_dev),
        inode: UInt64(value.st_ino),
        logicalBytes: Int64(value.st_size),
        blocks: Int64(value.st_blocks),
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
        category: category
    )
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let sum = addingReportingOverflow(other)
        return sum.overflow ? .max : sum.partialValue
    }
}
