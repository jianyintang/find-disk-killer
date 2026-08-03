import Darwin
import Foundation
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

private actor FakeCleanupAdapter: AgentStorageCleanupCapabilityProviding {
    let availabilityValue: AgentStorageCleanupAvailability
    let outcomes: [AgentStorageCleanupOutcome]
    private(set) var deletedIDs: [String] = []
    private(set) var availabilityCallCount = 0

    init(
        availability: AgentStorageCleanupAvailability = .ready,
        outcomes: [AgentStorageCleanupOutcome] = [.succeeded]
    ) {
        availabilityValue = availability
        self.outcomes = outcomes
    }

    func availability(for family: AgentStorageThreadFamily) -> AgentStorageCleanupAvailability {
        availabilityCallCount += 1
        return availabilityValue
    }

    func delete(_ family: AgentStorageThreadFamily) -> AgentStorageCleanupOutcome {
        deletedIDs.append(family.nativeThreadID)
        return outcomes[min(deletedIDs.count - 1, outcomes.count - 1)]
    }
}

private actor TrackingActivityInspector: AgentStorageCleanupActivityInspecting {
    private(set) var callCount = 0
    private(set) var maximumConcurrentCallCount = 0
    private var activeCallCount = 0

    func isActive(
        family: AgentStorageThreadFamily,
        artifacts: [AgentStorageCleanupArtifact]
    ) async throws -> Bool {
        callCount += 1
        activeCallCount += 1
        maximumConcurrentCallCount = max(maximumConcurrentCallCount, activeCallCount)
        try await Task.sleep(for: .milliseconds(30))
        activeCallCount -= 1
        return false
    }
}

private actor PreparationUpdateRecorder {
    private(set) var updates: [[AgentStorageCleanupTarget]] = []

    func record(_ targets: [AgentStorageCleanupTarget]) {
        updates.append(targets)
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

@Test func cleanupPreflightsOnceAndShortCircuitsActivityForUnsupportedSources() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 4)
    defer { fixture.destroy() }
    let adapter = FakeCleanupAdapter(availability: .unsupported("unsupported"))
    let inspector = TrackingActivityInspector()
    let coordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        activityInspector: inspector
    )

    let prepared = await coordinator.prepare(AgentStorageCleanupReview(families: fixture.families))

    #expect(prepared.allSatisfy { $0.availability == .unsupported("unsupported") })
    #expect(await adapter.availabilityCallCount == 1)
    #expect(await inspector.callCount == 0)
}

@Test func cleanupPreparesActivityChecksConcurrentlyAndReportsIncrementalProgress() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 8)
    defer { fixture.destroy() }
    let adapter = FakeCleanupAdapter()
    let inspector = TrackingActivityInspector()
    let recorder = PreparationUpdateRecorder()
    let coordinator = AgentStorageCleanupCoordinator(
        codex: adapter,
        activityInspector: inspector
    )

    let prepared = await coordinator.prepare(
        AgentStorageCleanupReview(families: fixture.families),
        didUpdate: { targets in await recorder.record(targets) }
    )
    let updates = await recorder.updates

    #expect(prepared.allSatisfy { $0.availability == .ready })
    #expect(await adapter.availabilityCallCount == 1)
    #expect(await inspector.callCount == fixture.families.count)
    #expect(await inspector.maximumConcurrentCallCount > 1)
    #expect(updates.first?.count == fixture.families.count)
    #expect(updates.first?.allSatisfy { $0.availability == .checking } == true)
    #expect(updates.contains { targets in
        let checkedCount = targets.count { $0.availability != .checking }
        return checkedCount > 0 && checkedCount < targets.count
    })
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

@Test func codexLocatorFindsCommonInstallationsAndDeduplicatesAliases() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "fdk-codex-locator-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let appRoot = root.appending(path: "Applications", directoryHint: .isDirectory)
    let paths: [(String, CodexRuntimeCandidate.Origin)] = [
        ("path-bin/codex", .path),
        ("home/.npm-global/bin/codex", .npm),
        ("home/.nvm/versions/node/v24/bin/codex", .nvm),
        ("home/.local/share/fnm/node-versions/v22/installation/bin/codex", .fnm),
        ("home/.volta/bin/codex", .volta),
        ("home/.bun/bin/codex", .bun),
        ("Applications/ChatGPT.app/Contents/Resources/codex", .application),
        ("Applications/Codex.app/Contents/Resources/codex", .application)
    ]
    for (relativePath, _) in paths {
        try makeExecutable(at: root.appending(path: relativePath), script: "#!/bin/sh\nexit 0\n")
    }
    let override = root.appending(path: "override-codex")
    try makeExecutable(at: override, script: "#!/bin/sh\nexit 0\n")
    let pathAliasDirectory = root.appending(path: "path-alias", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: pathAliasDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: pathAliasDirectory.appending(path: "codex"),
        withDestinationURL: root.appending(path: "path-bin/codex")
    )

    let candidates = CodexExecutableLocator.locate(
        environment: [
            "PATH": [root.appending(path: "path-bin").path, pathAliasDirectory.path]
                .joined(separator: ":"),
            "FDK_CODEX_APP_SERVER": override.path
        ],
        homeDirectory: home,
        applicationDirectories: [appRoot],
        includeSystemLocations: false
    )

    #expect(candidates.count == paths.count + 1)
    #expect(candidates.first?.origin == .override)
    #expect(Set(candidates.map(\.origin)) == Set(paths.map(\.1)).union([.override]))
    #expect(Set(candidates.map { "\($0.device):\($0.inode)" }).count == candidates.count)
    let pathCanonical = root.appending(path: "path-bin/codex").resolvingSymlinksInPath().path
    #expect(candidates.count(where: { $0.canonicalPath == pathCanonical }) == 1)
}

@Test func codexAvailabilityDoesNotLaunchVersionOrCapabilityProbes() async throws {
    let fixture = try CleanupFixture(
        provider: .codex,
        count: 1,
        usesSymlinkedCodexSource: true
    )
    defer { fixture.destroy() }
    let script = fixture.root.appending(path: "fake-codex")
    let log = fixture.root.appending(path: "requests.log")
    let scriptText = """
    #!/usr/bin/ruby
    require 'json'
    File.open('\(log.path)', 'a') { |file| file.puts(ARGV.join(' ')) }
    reads = 0
    STDIN.each_line do |line|
      request = JSON.parse(line)
      next unless request['id']
      File.open('\(log.path)', 'a') { |file| file.puts(request['method'].to_s + ':' + request.dig('params', 'threadId').to_s) }
      case request['method']
      when 'initialize'
        puts({id: request['id'], result: {userAgent: 'Codex fixture', codexHome: File.realpath(ENV.fetch('CODEX_HOME')), platformFamily: 'unix', platformOs: 'macos'}}.to_json)
      when 'thread/read'
        reads += 1
        if reads == 1
          puts({id: request['id'], result: {thread: {id: request['params']['threadId']}}}.to_json)
        else
          puts({id: request['id'], error: {code: -32600, message: 'thread not loaded: ' + request['params']['threadId']}}.to_json)
        end
      when 'thread/delete'
        puts({id: request['id'], result: {}}.to_json)
      end
      STDOUT.flush
    end
    """
    try makeExecutable(at: script, script: scriptText)

    let adapter = CodexAppServerCleanupAdapter(executableOverride: script.path)
    let availability = await adapter.availability(for: fixture.families[0])
    #expect(availability == .ready)
    #expect(!FileManager.default.fileExists(atPath: log.path))
    let outcome = await adapter.delete(fixture.families[0])
    #expect(outcome == .succeeded)
    let requests = try String(contentsOf: log, encoding: .utf8)
    #expect(!requests.contains("--version"))
    #expect(!requests.contains("find-disk-killer-capability-probe"))
    #expect(requests.contains("thread/read:\(fixture.families[0].nativeThreadID)"))
    #expect(requests.contains("thread/delete:\(fixture.families[0].nativeThreadID)"))
}

@Test func codexCleanupFailsOverAfterTheFirstRuntimeCannotStart() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let first = fixture.root.appending(path: "01-codex")
    let second = fixture.root.appending(path: "02-codex")
    try makeExecutable(at: first, script: "#!/bin/sh\nexit 9\n")
    try makeExecutable(at: second, script: successfulCodexScript())

    let adapter = CodexAppServerCleanupAdapter(candidatePaths: [first.path, second.path])
    #expect(await adapter.availability(for: fixture.families[0]) == .ready)
    #expect(await adapter.delete(fixture.families[0]) == .succeeded)
}

@Test func codexCleanupReusesTheSuccessfulRuntimeAndSkipsFailedCandidates() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 2)
    defer { fixture.destroy() }
    let first = fixture.root.appending(path: "01-codex")
    let second = fixture.root.appending(path: "02-codex")
    let firstLog = fixture.root.appending(path: "first.log")
    let secondLog = fixture.root.appending(path: "second.log")
    try makeExecutable(
        at: first,
        script: "#!/bin/sh\necho start >> '\(firstLog.path)'\nexit 9\n"
    )
    let secondScript = successfulCodexScript().replacingOccurrences(
        of: "require 'json'",
        with: "require 'json'\nFile.open('\(secondLog.path)', 'a') { |file| file.puts('start') }"
    )
    try makeExecutable(at: second, script: secondScript)

    let adapter = CodexAppServerCleanupAdapter(candidatePaths: [first.path, second.path])
    #expect(await adapter.delete(fixture.families[0]) == .succeeded)
    #expect(await adapter.delete(fixture.families[1]) == .succeeded)
    let firstStarts = try String(contentsOf: firstLog, encoding: .utf8).split(separator: "\n")
    let secondStarts = try String(contentsOf: secondLog, encoding: .utf8).split(separator: "\n")
    #expect(firstStarts.count == 1)
    #expect(secondStarts.count == 2)
}

@Test func codexCleanupTreatsADeleteWithLostResponseAsIdempotentSuccess() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let first = fixture.root.appending(path: "01-codex")
    let second = fixture.root.appending(path: "02-codex")
    let deletionMarker = fixture.root.appending(path: "deleted.marker")
    try makeExecutable(at: first, script: """
    #!/usr/bin/ruby
    require 'json'
    STDIN.each_line do |line|
      request = JSON.parse(line)
      next unless request['id']
      case request['method']
      when 'initialize'
        puts({id: request['id'], result: {userAgent: 'Codex fixture', codexHome: ENV.fetch('CODEX_HOME')}}.to_json)
      when 'thread/read'
        puts({id: request['id'], result: {thread: {id: request['params']['threadId']}}}.to_json)
      when 'thread/delete'
        File.write('\(deletionMarker.path)', 'deleted')
        exit 0
      end
      STDOUT.flush
    end
    """)
    try makeExecutable(at: second, script: """
    #!/usr/bin/ruby
    require 'json'
    STDIN.each_line do |line|
      request = JSON.parse(line)
      next unless request['id']
      if request['method'] == 'initialize'
        puts({id: request['id'], result: {userAgent: 'Codex fixture', codexHome: ENV.fetch('CODEX_HOME')}}.to_json)
      elsif request['method'] == 'thread/read' && File.exist?('\(deletionMarker.path)')
        puts({id: request['id'], error: {code: -32600, message: 'thread not found: ' + request['params']['threadId']}}.to_json)
      else
        puts({id: request['id'], error: {code: -32600, message: 'unexpected request'}}.to_json)
      end
      STDOUT.flush
    end
    """)

    let adapter = CodexAppServerCleanupAdapter(
        candidatePaths: [first.path, second.path],
        requestTimeout: 2
    )
    #expect(await adapter.delete(fixture.families[0]) == .succeeded)
    #expect(FileManager.default.fileExists(atPath: deletionMarker.path))
}

@Test func codexCleanupDoesNotFailOverAroundThreadIdentityChanges() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let first = fixture.root.appending(path: "01-codex")
    let second = fixture.root.appending(path: "02-codex")
    let secondStarted = fixture.root.appending(path: "second-started")
    try makeExecutable(at: first, script: """
    #!/usr/bin/ruby
    require 'json'
    STDIN.each_line do |line|
      request = JSON.parse(line)
      next unless request['id']
      if request['method'] == 'initialize'
        puts({id: request['id'], result: {userAgent: 'Codex fixture', codexHome: ENV.fetch('CODEX_HOME')}}.to_json)
      elsif request['method'] == 'thread/read'
        puts({id: request['id'], result: {thread: {id: request['params']['threadId'], parentThreadId: 'changed-parent'}}}.to_json)
      end
      STDOUT.flush
    end
    """)
    try makeExecutable(at: second, script: "#!/bin/sh\ntouch '\(secondStarted.path)'\nexit 0\n")

    let outcome = await CodexAppServerCleanupAdapter(candidatePaths: [first.path, second.path])
        .delete(fixture.families[0])
    guard case .failed(let reason) = outcome else {
        Issue.record("Expected a safety refusal")
        return
    }
    #expect(reason == L10n.text("Codex 聊天身份或父子关系已变化"))
    #expect(!FileManager.default.fileExists(atPath: secondStarted.path))
}

@Test func codexRedetectionReenumeratesPreviouslyMissingCandidates() async throws {
    let fixture = try CleanupFixture(provider: .codex, count: 1)
    defer { fixture.destroy() }
    let executable = fixture.root.appending(path: "late-codex")
    let adapter = CodexAppServerCleanupAdapter(candidatePaths: [executable.path])

    #expect(await adapter.availability(for: fixture.families[0]) == .unsupported("未找到 Codex 官方执行器"))
    try makeExecutable(at: executable, script: successfulCodexScript())
    #expect(await adapter.availability(for: fixture.families[0]) == .unsupported("未找到 Codex 官方执行器"))
    await adapter.resetDetection()
    #expect(await adapter.availability(for: fixture.families[0]) == .ready)
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
        sourceKind: AgentStorageSourceKind? = nil,
        usesSymlinkedCodexSource: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "fdk-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourcePath: String
        if usesSymlinkedCodexSource {
            let sourceLink = root.appending(path: "linked-codex-home")
            try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: root)
            sourcePath = sourceLink.path
        } else {
            sourcePath = root.path
        }
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
                sourcePath: sourcePath,
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

private func makeExecutable(at url: URL, script: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(script.utf8).write(to: url)
    guard chmod(url.path, 0o755) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func successfulCodexScript() -> String {
    """
    #!/usr/bin/ruby
    require 'json'
    reads = 0
    STDIN.each_line do |line|
      request = JSON.parse(line)
      next unless request['id']
      case request['method']
      when 'initialize'
        puts({id: request['id'], result: {userAgent: 'Codex fixture', codexHome: ENV.fetch('CODEX_HOME')}}.to_json)
      when 'thread/read'
        reads += 1
        if reads == 1
          puts({id: request['id'], result: {thread: {id: request['params']['threadId']}}}.to_json)
        else
          puts({id: request['id'], error: {code: -32600, message: 'thread not found: ' + request['params']['threadId']}}.to_json)
        end
      when 'thread/delete'
        puts({id: request['id'], result: {}}.to_json)
      end
      STDOUT.flush
    end
    """
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let sum = addingReportingOverflow(other)
        return sum.overflow ? .max : sum.partialValue
    }
}
