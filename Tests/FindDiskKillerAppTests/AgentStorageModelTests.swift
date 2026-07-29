import Foundation
import Darwin
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

@Test func agentStorageInactiveRangesUseStrictClampedCutoffs() throws {
    let calendar = Calendar.current
    let reference = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 28,
        hour: 16,
        minute: 30
    )))

    for (range, dayCount) in [
        (AgentStorageTimeRange.oneDay, 1),
        (AgentStorageTimeRange.sevenDays, 7),
        (.thirtyDays, 30),
        (.ninetyDays, 90)
    ] {
        let cutoff = try #require(range.cutoffDate(relativeTo: reference))
        #expect(calendar.dateComponents([.day], from: cutoff, to: reference).day == dayCount)
        #expect(range.includes(updatedAt: cutoff.addingTimeInterval(-1), relativeTo: reference))
        #expect(!range.includes(updatedAt: cutoff, relativeTo: reference))
        #expect(!range.includes(updatedAt: cutoff.addingTimeInterval(1), relativeTo: reference))
    }
    #expect(AgentStorageTimeRange.all.cutoffDate(relativeTo: reference) == nil)
    #expect(AgentStorageTimeRange.all.includes(updatedAt: reference, relativeTo: reference))
    #expect(AgentStorageTimeRange.olderThan(days: 0).inactiveDays == 1)
    #expect(AgentStorageTimeRange.olderThan(days: 45).inactiveDays == 45)
    #expect(AgentStorageTimeRange.olderThan(days: 500).inactiveDays == 365)
}

@Test func agentStorageBatchRangeProtectsRecentAndActiveThreads() throws {
    let reference = Date(timeIntervalSince1970: 10_000_000)
    let recent = makeFamily(
        id: "recent",
        updatedAt: reference.addingTimeInterval(-60 * 60),
        bytes: 10
    )
    let exactCutoff = makeFamily(
        id: "exact-cutoff",
        updatedAt: reference.addingTimeInterval(-30 * 24 * 60 * 60),
        bytes: 20
    )
    let old = makeFamily(
        id: "old",
        updatedAt: reference.addingTimeInterval(-31 * 24 * 60 * 60),
        bytes: 30
    )
    let muchOlder = makeFamily(
        id: "much-older",
        updatedAt: reference.addingTimeInterval(-120 * 24 * 60 * 60),
        bytes: 40
    )
    let families = [recent, exactCutoff, old, muchOlder]

    #expect(AgentStorageBatchSelectionEngine.eligibleFamilyIDs(
        in: families,
        timeRange: .thirtyDays,
        relativeTo: reference
    ) == ["old", "much-older"])
    #expect(AgentStorageBatchSelectionEngine.eligibleFamilyIDs(
        in: families,
        timeRange: .olderThan(days: 90),
        relativeTo: reference
    ) == ["much-older"])
    #expect(AgentStorageBatchSelectionEngine.eligibleFamilyIDs(
        in: families,
        timeRange: .all,
        relativeTo: reference
    ).isEmpty)

    let dataset = AgentStorageProviderDataset(
        provider: .codex,
        families: families,
        globalItems: [],
        unattributedItems: []
    )
    let result = try AgentStorageProjectionEngine.project(AgentStorageProjectionRequest(
        scope: .chats,
        dataset: dataset,
        scannedAt: reference,
        archiveFilter: .all,
        timeRange: .thirtyDays,
        selectedProject: nil,
        selectedGlobalCategory: nil,
        selectedUnattributedReason: nil,
        query: "",
        hidesPrivateDetails: false,
        expandedFamilies: [],
        chatPageIndex: 0,
        chatPageSize: 50,
        chatSortRules: [
            AgentStorageChatSortRule(field: .updatedAt, isReverse: true),
            AgentStorageChatSortRule(field: .id, isReverse: false)
        ],
        globalSortRules: [],
        unattributedSortRules: []
    ))
    guard case .chats(let rows, let summary, _, _) = result.content else {
        Issue.record("Expected a chat projection")
        return
    }
    #expect(rows.map(\.familyID) == ["old", "much-older"])
    #expect(summary.mainThreadCount == 2)
    #expect(summary.chatBytes == 70)
}

@Test func agentStorageBatchCleanupOwnsAnIndependentProtectedScope() {
    let reference = Date(timeIntervalSince1970: 20_000_000)
    let recent = makeFamily(
        id: "recent",
        updatedAt: reference.addingTimeInterval(-2 * 24 * 60 * 60),
        bytes: 10,
        title: "Recent work",
        project: "Current"
    )
    let alpha = makeFamily(
        id: "alpha-old",
        updatedAt: reference.addingTimeInterval(-31 * 24 * 60 * 60),
        bytes: 20,
        title: "Alpha cleanup",
        project: "Alpha"
    )
    let beta = makeFamily(
        id: "beta-old",
        updatedAt: reference.addingTimeInterval(-90 * 24 * 60 * 60),
        bytes: 30,
        title: "Beta archive",
        project: "Beta"
    )

    #expect(AgentStorageBatchCleanupEngine.defaultTimeRange == .thirtyDays)
    let initial = AgentStorageBatchCleanupEngine.project(
        families: [recent, alpha, beta],
        timeRange: AgentStorageBatchCleanupEngine.defaultTimeRange,
        selectedProject: nil,
        query: "",
        relativeTo: reference,
        hidesPrivateDetails: false
    )
    #expect(initial.families.map(\.id) == ["alpha-old", "beta-old"])
    #expect(initial.projects == ["Alpha", "Beta"])

    let projectOnly = AgentStorageBatchCleanupEngine.project(
        families: [recent, alpha, beta],
        timeRange: .thirtyDays,
        selectedProject: "Beta",
        query: "archive",
        relativeTo: reference,
        hidesPrivateDetails: false
    )
    #expect(projectOnly.families.map(\.id) == ["beta-old"])

    let privacyProtected = AgentStorageBatchCleanupEngine.project(
        families: [alpha],
        timeRange: .thirtyDays,
        selectedProject: nil,
        query: "Alpha cleanup",
        relativeTo: reference,
        hidesPrivateDetails: true
    )
    #expect(privacyProtected.families.isEmpty)
}

@Test func agentStorageLargestSubagentsAreRankedByAllocatedSpace() {
    let date = Date(timeIntervalSince1970: 1_000)
    let family = AgentStorageThreadFamily(
        id: "family",
        provider: .codex,
        sourceID: "source",
        nativeThreadID: "root",
        title: "Root",
        project: "Project",
        updatedAt: date,
        isArchived: false,
        mainAllocatedBytes: 1,
        subagentAllocatedBytes: 60,
        familyOtherAllocatedBytes: 0,
        artifactCount: 3,
        path: nil,
        subagents: [
            makeSubagent(id: "recent-small", bytes: 10, updatedAt: date.addingTimeInterval(3)),
            makeSubagent(id: "old-large", bytes: 30, updatedAt: date),
            makeSubagent(id: "middle", bytes: 20, updatedAt: date.addingTimeInterval(2))
        ],
        composition: [:]
    )

    #expect(family.largestSubagents(limit: 2).map(\.id) == ["old-large", "middle"])
}

@Test func agentStorageCleanupValidatorRejectsChangedOrReplacedFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "artifact.jsonl")
    try Data(repeating: 0x41, count: 4_096).write(to: url)

    let original = try cleanupArtifact(at: url)
    #expect(AgentStorageCleanupValidator.isStillEligible(original))

    try Data(repeating: 0x42, count: 8_192).write(to: url)
    #expect(!AgentStorageCleanupValidator.isStillEligible(original))

    try FileManager.default.removeItem(at: url)
    try Data(repeating: 0x41, count: 4_096).write(to: url)
    #expect(!AgentStorageCleanupValidator.isStillEligible(original))
}

@Test func agentStorageCleanupReviewDeduplicatesPhysicalArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "artifact.jsonl")
    try Data(repeating: 0x41, count: 4_096).write(to: url)
    let artifact = try cleanupArtifact(at: url)
    let family = AgentStorageThreadFamily(
        id: "family",
        provider: .codex,
        sourceID: "source",
        nativeThreadID: "thread",
        title: "Thread",
        project: "Project",
        updatedAt: .now,
        isArchived: false,
        mainAllocatedBytes: artifact.allocatedBytes,
        subagentAllocatedBytes: 0,
        familyOtherAllocatedBytes: 0,
        artifactCount: 1,
        path: url.path,
        subagents: [],
        composition: [.conversation: artifact.allocatedBytes],
        cleanupArtifacts: [artifact, artifact]
    )

    let review = AgentStorageCleanupReview(families: [family])
    #expect(review.artifacts == [artifact])
    #expect(review.reclaimableBytes == artifact.allocatedBytes)
    #expect(review.retainedBytes == 0)
}

@Test func agentStorageCurrentPageSelectionPreservesOtherPages() {
    let firstPage: Set<String> = ["family-1", "family-2"]
    let previousPageSelection: Set<String> = ["family-0"]

    let selected = AgentStorageBatchSelectionEngine.togglingCurrentPage(
        selectedIDs: previousPageSelection,
        pageFamilyIDs: firstPage
    )
    #expect(selected == ["family-0", "family-1", "family-2"])

    let deselected = AgentStorageBatchSelectionEngine.togglingCurrentPage(
        selectedIDs: selected,
        pageFamilyIDs: firstPage
    )
    #expect(deselected == previousPageSelection)
    #expect(AgentStorageBatchSelectionEngine.togglingCurrentPage(
        selectedIDs: previousPageSelection,
        pageFamilyIDs: []
    ) == previousPageSelection)
}

@Test func agentStorageProjectionKeepsSearchedSubagentsUniqueWhenExpanded() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let family = AgentStorageThreadFamily(
        id: "family",
        provider: .codex,
        sourceID: "source",
        nativeThreadID: "root",
        title: "Unrelated root",
        project: "Project",
        updatedAt: date,
        isArchived: false,
        mainAllocatedBytes: 10,
        subagentAllocatedBytes: 20,
        familyOtherAllocatedBytes: 0,
        artifactCount: 2,
        path: nil,
        subagents: [makeSubagent(id: "needle", bytes: 20, updatedAt: date)],
        composition: [:]
    )
    let dataset = AgentStorageProviderDataset(
        provider: .codex,
        families: [family],
        globalItems: [],
        unattributedItems: []
    )

    for expandedFamilies: Set<String> in [[], [family.id]] {
        let result = try AgentStorageProjectionEngine.project(AgentStorageProjectionRequest(
            scope: .chats,
            dataset: dataset,
            scannedAt: date,
            archiveFilter: .all,
            timeRange: .all,
            selectedProject: nil,
            selectedGlobalCategory: nil,
            selectedUnattributedReason: nil,
            query: "needle",
            hidesPrivateDetails: false,
            expandedFamilies: expandedFamilies,
            chatPageIndex: 0,
            chatPageSize: 50,
            chatSortRules: [
                AgentStorageChatSortRule(field: .updatedAt, isReverse: true),
                AgentStorageChatSortRule(field: .id, isReverse: false)
            ],
            globalSortRules: [],
            unattributedSortRules: []
        ))
        guard case .chats(let rows, _, _, _) = result.content else {
            Issue.record("Expected a chat projection")
            continue
        }
        #expect(rows.map(\.id) == [family.id, "needle"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(result.visibleIDs == Set([family.id, "needle"]))
    }
}

@Test func agentStorageProjectionBuildsOnlyTheRequestedThreadPage() throws {
    let families = (0..<125).map { index in
        AgentStorageThreadFamily(
            id: "family-\(index)",
            provider: .codex,
            sourceID: "source",
            nativeThreadID: "root-\(index)",
            title: "Thread \(index)",
            project: "Project",
            updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            isArchived: false,
            mainAllocatedBytes: 1,
            subagentAllocatedBytes: 0,
            familyOtherAllocatedBytes: 0,
            artifactCount: 1,
            path: nil,
            subagents: [],
            composition: [:]
        )
    }
    let dataset = AgentStorageProviderDataset(
        provider: .codex,
        families: families,
        globalItems: [],
        unattributedItems: []
    )
    let result = try AgentStorageProjectionEngine.project(AgentStorageProjectionRequest(
        scope: .chats,
        dataset: dataset,
        scannedAt: Date(timeIntervalSince1970: 1_000),
        archiveFilter: .all,
        timeRange: .all,
        selectedProject: nil,
        selectedGlobalCategory: nil,
        selectedUnattributedReason: nil,
        query: "",
        hidesPrivateDetails: false,
        expandedFamilies: [],
        chatPageIndex: 1,
        chatPageSize: 50,
        chatSortRules: [
            AgentStorageChatSortRule(field: .updatedAt, isReverse: true),
            AgentStorageChatSortRule(field: .id, isReverse: false)
        ],
        globalSortRules: [],
        unattributedSortRules: []
    ))

    guard case .chats(let rows, let summary, _, let pagination) = result.content else {
        Issue.record("Expected a chat projection")
        return
    }
    #expect(rows.count == 50)
    #expect(rows.first?.id == "family-74")
    #expect(rows.last?.id == "family-25")
    #expect(summary.mainThreadCount == 125)
    #expect(pagination == AgentStorageChatPagination(pageIndex: 1, pageSize: 50, totalItems: 125))
    #expect(pagination.totalPages == 3)
    #expect(result.visibleIDs.count == 50)

    let clampedResult = try AgentStorageProjectionEngine.project(AgentStorageProjectionRequest(
        scope: .chats,
        dataset: dataset,
        scannedAt: Date(timeIntervalSince1970: 1_000),
        archiveFilter: .all,
        timeRange: .all,
        selectedProject: nil,
        selectedGlobalCategory: nil,
        selectedUnattributedReason: nil,
        query: "",
        hidesPrivateDetails: false,
        expandedFamilies: [],
        chatPageIndex: 99,
        chatPageSize: 50,
        chatSortRules: [
            AgentStorageChatSortRule(field: .updatedAt, isReverse: true),
            AgentStorageChatSortRule(field: .id, isReverse: false)
        ],
        globalSortRules: [],
        unattributedSortRules: []
    ))
    guard case .chats(let lastRows, _, _, let clampedPagination) = clampedResult.content else {
        Issue.record("Expected a clamped chat projection")
        return
    }
    #expect(clampedPagination.pageIndex == 2)
    #expect(lastRows.count == 25)
    #expect(lastRows.first?.id == "family-24")
    #expect(lastRows.last?.id == "family-0")
}

@Test func agentStorageSnapshotDecodesLegacyCacheWithoutDiagnostics() throws {
    let summary = AgentStorageProviderSummary(
        provider: .claude,
        exclusiveBytes: 0,
        chatBytes: 0,
        globalBytes: 0,
        unattributedBytes: 0,
        mainThreadBytes: 0,
        subagentBytes: 0,
        familyOtherBytes: 0,
        threadCount: 0,
        subagentCount: 0,
        sourceCount: 1,
        issueCount: 2,
        supportStatus: .partial
    )
    let snapshot = AgentStorageSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        families: [],
        globalItems: [],
        unattributedItems: [],
        providers: [summary],
        sources: [],
        coverage: AgentStorageCoverage(
            measuredBytes: 0,
            classifiedBytes: 0,
            measuredEntryCount: 0,
            skippedEntryCount: 0,
            unstableEntryCount: 0,
            overflowed: false,
            reconciliationDelta: 0,
            isComplete: false
        ),
        crossAgentSharedBytes: 0,
        diagnostics: [AgentStorageDiagnostic(
            id: "diagnostic",
            provider: .claude,
            sourceID: "source",
            kind: .sourceUnreadable,
            area: .dataSource,
            impact: .chatDiscovery
        )]
    )
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "diagnostics")
    var providers = try #require(object["providers"] as? [[String: Any]])
    providers[0].removeValue(forKey: "attributionStatus")
    providers[0].removeValue(forKey: "diagnosticCounts")
    providers[0].removeValue(forKey: "knownAffectedBytes")
    object["providers"] = providers

    let decoded = try JSONDecoder().decode(
        AgentStorageSnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.diagnostics.isEmpty)
    #expect(decoded.providers.first?.attributionStatus == .partial)
    #expect(decoded.providers.first?.diagnosticCounts.isEmpty == true)
    #expect(decoded.providers.first?.knownAffectedBytes == 0)
}

@Test func agentStorageQualityPresentationSeparatesPhysicalAndAttributionProblems() {
    let physical = AgentStorageDiagnostic(
        id: "physical",
        provider: .claude,
        sourceID: "source",
        kind: .changedDuringScan,
        area: .fileSystem,
        impact: .physicalMeasurement,
        affectedAllocatedBytes: 4_096
    )
    let attribution = AgentStorageDiagnostic(
        id: "attribution",
        provider: .claude,
        sourceID: "source",
        kind: .malformedTranscriptRecords,
        area: .mainChat,
        impact: .chatMetadata
    )
    let summary = AgentStorageProviderSummary(
        provider: .claude,
        exclusiveBytes: 4_096,
        chatBytes: 4_096,
        globalBytes: 0,
        unattributedBytes: 0,
        mainThreadBytes: 4_096,
        subagentBytes: 0,
        familyOtherBytes: 0,
        threadCount: 1,
        subagentCount: 0,
        sourceCount: 1,
        issueCount: 2,
        supportStatus: .partial,
        attributionStatus: .partial,
        knownAffectedBytes: 4_096
    )
    let coverage = AgentStorageCoverage(
        measuredBytes: 4_096,
        classifiedBytes: 4_096,
        measuredEntryCount: 1,
        skippedEntryCount: 0,
        unstableEntryCount: 1,
        overflowed: false,
        reconciliationDelta: 0,
        isComplete: false
    )

    let presentation = AgentStorageQualityPresentation(
        coverage: coverage,
        summary: summary,
        diagnostics: [physical, attribution]
    )

    #expect(!presentation.isPhysicalMeasurementComplete)
    #expect(presentation.totalDiagnosticCount == 2)
    #expect(presentation.physicalDiagnosticCount == 1)
    #expect(presentation.attributionDiagnosticCount == 1)
    #expect(presentation.attributionStatus == .partial)
    #expect(presentation.knownAffectedBytes == 4_096)
    #expect(!presentation.hasUnknownAffectedBytes)
}

private func makeSubagent(id: String, bytes: UInt64, updatedAt: Date) -> AgentStorageThreadNode {
    AgentStorageThreadNode(
        id: id,
        nativeID: id,
        parentID: "root",
        depth: 1,
        title: id,
        updatedAt: updatedAt,
        allocatedBytes: bytes,
        artifactCount: 1,
        path: nil
    )
}

private func makeFamily(
    id: String,
    updatedAt: Date,
    bytes: UInt64,
    title: String? = nil,
    project: String = "Project"
) -> AgentStorageThreadFamily {
    AgentStorageThreadFamily(
        id: id,
        provider: .codex,
        sourceID: "source",
        nativeThreadID: id,
        title: title ?? id,
        project: project,
        updatedAt: updatedAt,
        isArchived: false,
        mainAllocatedBytes: bytes,
        subagentAllocatedBytes: 0,
        familyOtherAllocatedBytes: 0,
        artifactCount: 1,
        path: nil,
        subagents: [],
        composition: [.conversation: bytes]
    )
}

private func cleanupArtifact(at url: URL) throws -> AgentStorageCleanupArtifact {
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
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
    )
}

@MainActor
@Test func agentStorageEntryNeverScansWithoutAnExplicitAction() async throws {
    let suiteName = "AgentStorageConsentTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: AgentStoragePreferences.analysisConsentKey)
    defaults.set(true, forKey: AgentStoragePreferences.autoScanKey)
    let probe = ImmediateAgentStorageScanProbe()
    let model = AgentStorageModel(defaults: defaults) { configuration in
        await probe.scan(configuration)
    }

    model.enterFeature()
    model.enterFeature()
    model.resumeAfterWake()
    try await Task.sleep(for: .milliseconds(80))

    #expect(model.state == .idle)
    #expect(model.requiresAnalysis)
    #expect(await probe.callCount == 0)

    model.startAnalysis()
    try await waitUntil { model.state == .ready }

    #expect(!model.requiresAnalysis)
    #expect(await probe.callCount == 1)
}

@MainActor
@Test func agentStorageEntryDisplaysValidCacheWithoutScanning() async throws {
    let suiteName = "AgentStorageAuthorizedEntryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: AgentStoragePreferences.analysisConsentKey)
    defaults.set(true, forKey: AgentStoragePreferences.autoScanKey)
    let probe = ImmediateAgentStorageScanProbe()
    let cachedSnapshot = emptySnapshot(scannedAt: Date(timeIntervalSince1970: 123))
    let model = AgentStorageModel(defaults: defaults, initialSnapshot: cachedSnapshot) { configuration in
        await probe.scan(configuration)
    }

    model.enterFeature()
    model.enterFeature()
    model.resumeAfterWake()
    try await Task.sleep(for: .milliseconds(80))

    #expect(await probe.callCount == 0)
    #expect(model.snapshot == cachedSnapshot)
    #expect(model.state == .ready)
    #expect(!model.requiresAnalysis)
}

@MainActor
@Test func agentStorageWakeCancelsAnActiveAnalysisWithoutResumingIt() async throws {
    let suiteName = "AgentStorageWakeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = AgentStorageScanProbe()
    let cachedSnapshot = emptySnapshot(scannedAt: Date(timeIntervalSince1970: 123))
    let model = AgentStorageModel(defaults: defaults, initialSnapshot: cachedSnapshot) { configuration in
        try await probe.scan(configuration)
    }

    model.startAnalysis()
    try await waitUntil { await probe.callCount == 1 }
    await model.prepareForSleep()
    model.resumeAfterWake()
    model.enterFeature()
    try await Task.sleep(for: .milliseconds(80))

    #expect(await probe.callCount == 1)
    #expect(model.snapshot == cachedSnapshot)
    #expect(model.state == .stale)
}

@MainActor
@Test func agentStorageInvalidatedCacheReturnsToInvitationWithoutScanning() async throws {
    let suiteName = "AgentStorageInvalidationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = ImmediateAgentStorageScanProbe()
    let model = AgentStorageModel(
        defaults: defaults,
        initialSnapshot: emptySnapshot()
    ) { configuration in
        await probe.scan(configuration)
    }

    model.invalidateCachedResults()
    model.enterFeature()
    model.resumeAfterWake()
    try await Task.sleep(for: .milliseconds(80))

    #expect(model.snapshot == nil)
    #expect(model.requiresAnalysis)
    #expect(model.state == .idle)
    #expect(await probe.callCount == 0)
}

@MainActor
@Test func agentStorageCustomRootChangesInvalidateCacheWithoutScanning() async throws {
    let suiteName = "AgentStorageCustomRootTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(
        at: root.appending(path: "sessions", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    let probe = ImmediateAgentStorageScanProbe()
    let model = AgentStorageModel(
        defaults: defaults,
        initialSnapshot: emptySnapshot()
    ) { configuration in
        await probe.scan(configuration)
    }

    model.addCustomRoot(root)
    model.enterFeature()
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.snapshot == nil)
    #expect(await probe.callCount == 0)

    model.startAnalysis()
    try await waitUntil { model.state == .ready }
    model.removeCustomRoot(root)
    model.enterFeature()
    try await Task.sleep(for: .milliseconds(80))
    #expect(model.snapshot == nil)
    #expect(await probe.callCount == 1)
}

@MainActor
@Test func agentStorageReanalysisKeepsCachedResultsUntilReplacementCompletes() async throws {
    let suiteName = "AgentStorageReanalysisCacheTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = ControlledAgentStorageScanProbe()
    let cachedSnapshot = emptySnapshot(scannedAt: Date(timeIntervalSince1970: 123))
    let replacement = emptySnapshot(scannedAt: Date(timeIntervalSince1970: 456))
    let model = AgentStorageModel(defaults: defaults, initialSnapshot: cachedSnapshot) { configuration in
        await probe.scan(configuration, result: replacement)
    }

    model.startAnalysis()
    try await waitUntil { await probe.callCount == 1 }

    #expect(model.isScanning)
    #expect(model.snapshot == cachedSnapshot)

    await probe.finish()
    try await waitUntil { model.state == .ready }
    #expect(model.snapshot == replacement)
}

@MainActor
@Test func agentStorageRefreshWaitsForCancelledScanBeforeStartingAnother() async throws {
    let suiteName = "AgentStorageModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = AgentStorageScanProbe()
    let model = AgentStorageModel(defaults: defaults) { configuration in
        try await probe.scan(configuration)
    }

    model.startAnalysis()
    try await waitUntil { await probe.callCount == 1 }
    model.startAnalysis()
    try await waitUntil { model.state == .ready }

    #expect(await probe.callCount == 2)
    #expect(await probe.maximumConcurrentCalls == 1)
    #expect(model.snapshot != nil)
    #expect(model.snapshotRevision == 1)
}

@MainActor
@Test func agentStorageStopRejectsLateResultFromCancelledGeneration() async throws {
    let suiteName = "AgentStorageModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = AgentStorageScanProbe(returnsAfterCancellation: true)
    let model = AgentStorageModel(defaults: defaults) { configuration in
        try await probe.scan(configuration)
    }

    model.startAnalysis()
    try await waitUntil { await probe.callCount == 1 }
    model.stop()
    try await waitUntil { await probe.activeCalls == 0 }

    #expect(model.snapshot == nil)
    #expect(model.snapshotRevision == 0)
    #expect(model.state == .stopped)
}

@MainActor
@Test func agentStorageRefreshRejectsLateProgressFromCancelledGeneration() async throws {
    let suiteName = "AgentStorageProgressTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = LateAgentStorageProgressProbe()
    let model = AgentStorageModel(defaults: defaults) { configuration, progress in
        try await probe.scan(configuration, progress: progress)
    }

    model.startAnalysis()
    try await waitUntil { await probe.callCount == 1 }
    model.startAnalysis()
    try await waitUntil { model.state == .ready }
    try await waitUntil { model.progress.completedCount == 42 }
    try await Task.sleep(for: .milliseconds(250))

    #expect(model.progress.phase == .measuringEntries)
    #expect(model.progress.completedCount == 42)
    #expect(model.progress.totalCount == nil)
}

@MainActor
@Test func agentStorageStopRejectsProgressThatArrivesAfterCancellation() async throws {
    let suiteName = "AgentStorageStoppedProgressTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = LateAgentStorageProgressProbe()
    let model = AgentStorageModel(defaults: defaults) { configuration, progress in
        try await probe.scan(configuration, progress: progress)
    }

    model.startAnalysis()
    try await waitUntil { await probe.callCount == 1 }
    model.stop()
    try await Task.sleep(for: .milliseconds(250))

    #expect(model.state == .stopped)
    #expect(model.progress.completedCount != 999)
}

@MainActor
@Test func agentStorageProgressNeverRegressesWithinTheActiveGeneration() async throws {
    let suiteName = "AgentStorageMonotonicProgressTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = AgentStorageModel(defaults: defaults) { _, progress in
        progress(AgentStorageScanProgress(
            phase: .validatingEntries,
            completedCount: 8,
            totalCount: 10
        ))
        progress(AgentStorageScanProgress(
            phase: .validatingEntries,
            completedCount: 3,
            totalCount: 10
        ))
        progress(AgentStorageScanProgress(
            phase: .measuringEntries,
            completedCount: 999,
            totalCount: 1_000
        ))
        return emptySnapshot()
    }

    model.startAnalysis()
    try await waitUntil { model.state == .ready }
    try await waitUntil { model.progress.phase == .validatingEntries }

    #expect(model.progress.completedCount == 8)
    #expect(model.progress.totalCount == 10)
}

@MainActor
@Test func agentStorageModelKeepsIndependentProviderProgress() async throws {
    let suiteName = "AgentStorageProviderProgressTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = AgentStorageModel(defaults: defaults) { _, progress in
        progress(AgentStorageScanProgress(
            phase: .attributingDatabase,
            completedCount: 128,
            provider: .codex,
            processedBytes: 4_096,
            databaseStage: .readingRecords
        ))
        progress(AgentStorageScanProgress(
            phase: .organizingResults,
            completedCount: 24,
            totalCount: 24,
            provider: .claude
        ))
        progress(AgentStorageScanProgress(
            phase: .organizingResults,
            completedCount: 0,
            totalCount: 48
        ))
        progress(AgentStorageScanProgress(
            phase: .organizingResults,
            completedCount: 48,
            totalCount: 48
        ))
        return emptySnapshot()
    }

    model.startAnalysis()
    try await waitUntil {
        model.progressByProvider[.codex]?.phase == .attributingDatabase
            && model.progressByProvider[.claude]?.phase == .organizingResults
            && model.progress.provider == nil
            && model.progress.completedCount == 48
    }

    #expect(model.progressByProvider[.codex]?.completedCount == 128)
    #expect(model.progressByProvider[.claude]?.completedCount == 24)
    #expect(model.progress.phase == .organizingResults)
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw AgentStorageModelTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor AgentStorageScanProbe {
    private(set) var callCount = 0
    private(set) var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private let returnsAfterCancellation: Bool

    init(returnsAfterCancellation: Bool = false) {
        self.returnsAfterCancellation = returnsAfterCancellation
    }

    func scan(_ configuration: AgentStorageScanner.Configuration) async throws
        -> AgentStorageSnapshot {
        callCount += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        defer { activeCalls -= 1 }

        if callCount == 1 {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError where returnsAfterCancellation {
                return emptySnapshot()
            }
        }
        return emptySnapshot()
    }
}

private actor ImmediateAgentStorageScanProbe {
    private(set) var callCount = 0

    func scan(_ configuration: AgentStorageScanner.Configuration) -> AgentStorageSnapshot {
        callCount += 1
        return emptySnapshot()
    }
}

private actor ControlledAgentStorageScanProbe {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func scan(
        _ configuration: AgentStorageScanner.Configuration,
        result: AgentStorageSnapshot
    ) async -> AgentStorageSnapshot {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LateAgentStorageProgressProbe {
    private(set) var callCount = 0

    func scan(
        _ configuration: AgentStorageScanner.Configuration,
        progress: @escaping @Sendable (AgentStorageScanProgress) -> Void
    ) async throws -> AgentStorageSnapshot {
        callCount += 1
        if callCount == 1 {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(150))
                    progress(AgentStorageScanProgress(
                        phase: .organizingResults,
                        completedCount: 999,
                        totalCount: 1_000
                    ))
                }
                return emptySnapshot()
            }
        }
        progress(AgentStorageScanProgress(
            phase: .measuringEntries,
            completedCount: 42
        ))
        return emptySnapshot()
    }
}

private func emptySnapshot(scannedAt: Date = Date()) -> AgentStorageSnapshot {
    AgentStorageSnapshot(
        scannedAt: scannedAt,
        families: [],
        globalItems: [],
        unattributedItems: [],
        providers: [],
        sources: [],
        coverage: AgentStorageCoverage(
            measuredBytes: 0,
            classifiedBytes: 0,
            measuredEntryCount: 0,
            skippedEntryCount: 0,
            unstableEntryCount: 0,
            overflowed: false,
            reconciliationDelta: 0,
            isComplete: true
        ),
        crossAgentSharedBytes: 0
    )
}

private enum AgentStorageModelTestError: Error {
    case timeout
}
