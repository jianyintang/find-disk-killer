import Foundation
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

@Test func agentStorageNaturalDayRangesIncludeExactlyTheirNamedDayCount() throws {
    let calendar = Calendar.current
    let reference = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 28,
        hour: 16,
        minute: 30
    )))

    for (range, dayCount) in [
        (AgentStorageTimeRange.sevenDays, 7),
        (.thirtyDays, 30),
        (.ninetyDays, 90)
    ] {
        let interval = try #require(range.dateInterval(relativeTo: reference))
        #expect(calendar.dateComponents([.day], from: interval.lowerBound, to: interval.upperBound).day == dayCount)
        #expect(interval.contains(reference))
        #expect(!interval.contains(interval.upperBound))
    }
    #expect(AgentStorageTimeRange.all.dateInterval(relativeTo: reference) == nil)
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

@MainActor
@Test func agentStorageRefreshWaitsForCancelledScanBeforeStartingAnother() async throws {
    let suiteName = "AgentStorageModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let probe = AgentStorageScanProbe()
    let model = AgentStorageModel(defaults: defaults) { configuration in
        try await probe.scan(configuration)
    }

    model.refresh()
    try await waitUntil { await probe.callCount == 1 }
    model.refresh()
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

    model.refresh()
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

    model.refresh()
    try await waitUntil { await probe.callCount == 1 }
    model.refresh()
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

    model.refresh()
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

    model.refresh()
    try await waitUntil { model.state == .ready }
    try await waitUntil { model.progress.phase == .validatingEntries }

    #expect(model.progress.completedCount == 8)
    #expect(model.progress.totalCount == 10)
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

private func emptySnapshot() -> AgentStorageSnapshot {
    AgentStorageSnapshot(
        scannedAt: Date(),
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
