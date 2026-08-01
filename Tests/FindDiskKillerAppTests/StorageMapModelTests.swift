import Foundation
import FindDiskKillerCore
import Testing
@testable import FindDiskKillerApp

@MainActor
@Test func storageMapEntryDetectsSourcesWithoutStartingADeepScan() async {
    let probe = StorageMapScanProbe()
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [candidate = storageMapCandidate()] in [candidate] },
        scan: { progress in try await probe.scan(progress: progress) }
    )

    await model.prepare()

    #expect(model.phase == .ready)
    #expect(model.candidates.map(\.id) == [.npm])
    #expect(await probe.scanCount == 0)
    #expect(model.snapshot == nil)
}

@MainActor
@Test func storageMapPublishesRealCandidatesWhileDiscoveryIsStillRunning() async throws {
    let candidate = storageMapCandidate()
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [candidate] in [candidate] },
        progressiveDetect: { progress in
            progress(candidate)
            try? await Task.sleep(for: .milliseconds(140))
            return [candidate]
        },
        scan: { _ in storageMapSnapshot() }
    )

    let preparation = Task { await model.prepare() }
    try await waitForStorageMapTest {
        model.phase == .detecting && model.candidates.map(\.id) == [.npm]
    }

    #expect(model.latestDetectedCandidate?.id == .npm)
    await preparation.value
    #expect(model.phase == .ready)
}

@MainActor
@Test func storageMapPacesConfirmedCandidatesForVisibleInsertions() async throws {
    let npm = storageMapCandidate()
    let chrome = storageMapChromeCandidate()
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm, chrome] in [npm, chrome] },
        progressiveDetect: { progress in
            progress(npm)
            progress(chrome)
            return [npm, chrome]
        },
        scan: { _ in storageMapSnapshot() },
        discoveryPresentationInterval: .milliseconds(200)
    )

    let preparation = Task { await model.prepare() }
    try await waitForStorageMapTest {
        model.candidates.map(\.id) == [.npm]
    }

    #expect(model.phase == .detecting)
    #expect(model.latestDetectedCandidate?.id == .npm)
    await preparation.value
    #expect(model.phase == .ready)
    #expect(model.candidates.map(\.id) == [.npm, .chrome])
}

@MainActor
@Test func repositoryAuthorizationRefreshReanalyzesOnlyTheWorkspaceOnce() async throws {
    let probe = StorageMapAuthorizationProbe()
    let workspace = storageMapWorkspaceCandidate()
    let model = StorageMapModel(
        cacheURL: nil,
        detect: {
            probe.recordDetection()
            return [storageMapCandidate(), workspace]
        },
        scan: { _ in
            probe.recordScan()
            return storageMapSnapshot()
        },
        scanSource: { sourceID, _ in
            probe.recordSourceScan(sourceID)
            return storageMapWorkspaceSnapshot()
        },
        repositoryAccessCheck: { probe.isGranted }
    )

    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest { model.snapshot != nil && model.phase == .ready }
    let previousSnapshot = try #require(model.snapshot)

    probe.grant()
    #expect(model.refreshRepositoryAuthorization())
    #expect(model.snapshot == previousSnapshot)
    #expect(model.refreshRepositoryAuthorization())
    #expect(model.refreshRepositoryAuthorization())

    try await waitForStorageMapTest {
        !model.reanalyzingSourceIDs.contains(.workspace)
            && probe.workspaceScanCount == 1
    }
    #expect(model.candidates.map(\.id) == [.npm, .workspace])
    #expect(model.snapshot?.result(for: .npm)?.allocatedBytes == 4_096)
    #expect(model.snapshot?.result(for: .workspace)?.allocatedBytes == 16_384)
    #expect(probe.detectionCount == 1)
    #expect(probe.scanCount == 1)
    #expect(probe.workspaceScanCount == 1)
}

@MainActor
@Test func unifiedRefreshPreservesTheDeferredWorkspaceResult() async throws {
    let npm = storageMapCandidate()
    let workspace = storageMapWorkspaceCandidate()
    let sequence = StorageMapSnapshotSequence([
        storageMapSnapshotIncludingWorkspace(),
        storageMapSnapshot()
    ])
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm, workspace] in [npm, workspace] },
        scan: { _ in await sequence.next() }
    )

    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest {
        model.phase == .ready && model.snapshot?.result(for: .workspace) != nil
    }
    model.startAnalysis()
    try await waitForStorageMapTest { await sequence.remainingCount == 0 && model.phase == .ready }

    #expect(model.snapshot?.result(for: .npm)?.allocatedBytes == 4_096)
    #expect(model.snapshot?.result(for: .workspace)?.allocatedBytes == 16_384)
}

@MainActor
@Test func storageMapRejectsLateResultsAfterStop() async {
    let probe = StorageMapScanProbe()
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [candidate = storageMapCandidate()] in [candidate] },
        scan: { progress in try await probe.scanIgnoringCancellation(progress: progress) }
    )
    await model.prepare()

    model.startAnalysis()
    await Task.yield()
    model.stopAnalysis()
    try? await Task.sleep(for: .milliseconds(240))

    #expect(model.phase == .ready)
    #expect(model.snapshot == nil)
}

@MainActor
@Test func storageMapMarksEveryDetectedSourceAsAnalyzingDuringAFullScan() async {
    let probe = StorageMapScanProbe()
    let npm = storageMapCandidate()
    let chromeDescriptor = StorageSourceDescriptor(
        id: .chrome,
        title: "Chrome",
        family: .applications,
        symbol: "globe",
        cleanupCapability: .openOfficialManager
    )
    let chrome = StorageSourceCandidate(
        descriptor: chromeDescriptor,
        roots: [
            StorageSourceRoot(
                id: "chrome.cache",
                sourceID: .chrome,
                displayName: "Chrome cache",
                path: "/tmp/chrome",
                defaultCategory: "浏览器缓存",
                defaultRisk: .rebuildableCache
            )
        ]
    )
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm, chrome] in [npm, chrome] },
        scan: { progress in try await probe.scanIgnoringCancellation(progress: progress) }
    )
    await model.prepare()

    model.startAnalysis()
    await Task.yield()

    #expect(model.isAnalyzingSource(.npm))
    #expect(model.isAnalyzingSource(.chrome))
    model.stopAnalysis()
}

@MainActor
@Test func storageMapProgressDoesNotRegressAcrossConcurrentUpdates() async throws {
    let candidate = storageMapCandidate()
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [candidate] in [candidate] },
        scan: { progress in
            progress(.init(
                phase: .measuring,
                sourceID: .npm,
                completedSourceCount: 1,
                totalSourceCount: 2,
                processedEntryCount: 20,
                processedBytes: 20_000
            ))
            try await Task.sleep(for: .milliseconds(30))
            progress(.init(
                phase: .measuring,
                sourceID: .npm,
                completedSourceCount: 0,
                totalSourceCount: 2,
                processedEntryCount: 10,
                processedBytes: 10_000
            ))
            try await Task.sleep(for: .seconds(60))
            return storageMapSnapshot()
        }
    )
    await model.prepare()

    model.startAnalysis()
    try await waitForStorageMapTest {
        model.progress?.processedEntryCount == 20
    }
    try await Task.sleep(for: .milliseconds(80))

    #expect(model.progress?.completedSourceCount == 1)
    #expect(model.progress?.processedEntryCount == 20)
    #expect(model.progress?.processedBytes == 20_000)
    model.stopAnalysis()
}

@MainActor
@Test func storageMapKeepsIndependentProgressForConcurrentSources() async throws {
    let npm = storageMapCandidate()
    let chrome = StorageSourceCandidate(
        descriptor: .init(
            id: .chrome,
            title: "Chrome",
            family: .applications,
            symbol: "globe",
            cleanupCapability: .analysisOnly
        ),
        roots: []
    )
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm, chrome] in [npm, chrome] },
        scan: { progress in
            progress(.init(
                phase: .measuring,
                sourceID: .npm,
                processedEntryCount: 30,
                processedBytes: 30_000,
                sourceProcessedEntryCount: 30,
                sourceProcessedBytes: 30_000,
                currentWork: "npm cache"
            ))
            progress(.init(
                phase: .measuring,
                sourceID: .chrome,
                processedEntryCount: 42,
                processedBytes: 42_000,
                sourceProcessedEntryCount: 12,
                sourceProcessedBytes: 12_000,
                currentWork: "Chrome profiles"
            ))
            progress(.init(
                phase: .measuring,
                sourceID: .npm,
                processedEntryCount: 20,
                processedBytes: 20_000,
                sourceProcessedEntryCount: 20,
                sourceProcessedBytes: 20_000,
                currentWork: "older update"
            ))
            try await Task.sleep(for: .seconds(60))
            return storageMapSnapshot()
        }
    )
    await model.prepare()

    model.startAnalysis()
    try await waitForStorageMapTest { model.progressBySource.count == 2 }

    #expect(model.progressBySource[.npm]?.sourceProcessedEntryCount == 30)
    #expect(model.progressBySource[.npm]?.currentWork == "npm cache")
    #expect(model.progressBySource[.chrome]?.sourceProcessedEntryCount == 12)
    #expect(model.progressBySource[.chrome]?.currentWork == "Chrome profiles")
    model.stopAnalysis()
}

@MainActor
@Test func storageMapPresentsMonotonicLiveVolumeAndSummaryProgress() async throws {
    let candidate = storageMapCandidate()
    let liveVolume: @Sendable (UInt64) -> StorageVolumeSnapshot = { bytes in
        StorageVolumeSnapshot(
            id: "system",
            name: "System",
            mountPath: "/",
            totalCapacity: 1_000_000,
            availableCapacity: 500_000,
            sourceUsages: [.init(sourceID: .npm, allocatedBytes: bytes)]
        )
    }
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [candidate] in [candidate] },
        scan: { progress in
            progress(.init(
                phase: .measuring,
                sourceID: .npm,
                processedEntryCount: 20,
                processedBytes: 20_000,
                sourceProcessedEntryCount: 20,
                sourceProcessedBytes: 20_000,
                volumes: [liveVolume(20_000)]
            ))
            progress(.init(
                phase: .measuring,
                sourceID: .npm,
                processedEntryCount: 10,
                processedBytes: 10_000,
                sourceProcessedEntryCount: 10,
                sourceProcessedBytes: 10_000,
                volumes: [liveVolume(10_000)]
            ))
            try await Task.sleep(for: .seconds(60))
            return storageMapSnapshot()
        }
    )
    await model.prepare()

    model.startAnalysis()
    try await waitForStorageMapTest { model.presentationTotalAllocatedBytes == 20_000 }

    #expect(model.isPresentingLiveResults)
    #expect(model.presentationEntryCount == 20)
    #expect(model.presentationAllocatedBytes(for: .npm) == 20_000)
    #expect(model.presentationVolumes.first?.analyzedBytes == 20_000)
    #expect(model.presentationVolumes.first?.otherBytes == 480_000)
    model.stopAnalysis()
}

@MainActor
@Test func storageMapFullAnalysisAlsoStartsAgentDeepAnalysis() async throws {
    let storageProbe = StorageMapScanProbe()
    let agentProbe = UnifiedAgentStorageScanProbe()
    let codexDescriptor = StorageSourceDescriptor(
        id: .codex,
        title: "Codex",
        family: .aiTools,
        symbol: "terminal",
        cleanupCapability: .analysisOnly
    )
    let codex = StorageSourceCandidate(
        descriptor: codexDescriptor,
        roots: [
            StorageSourceRoot(
                id: "codex.home",
                sourceID: .codex,
                displayName: "Codex Home",
                path: "/tmp/codex",
                defaultCategory: "Codex data",
                defaultRisk: .protectedUserData,
                isProtected: true
            )
        ]
    )
    let storageMap = StorageMapModel(
        cacheURL: nil,
        detect: { [codex] in [codex] },
        scan: { progress in try await storageProbe.scanIgnoringCancellation(progress: progress) }
    )
    let agentStorage = AgentStorageModel { configuration in
        await agentProbe.scan(configuration)
    }
    await storageMap.prepare()

    storageMap.startAnalysis(including: agentStorage)
    try await waitForStorageMapTest {
        let storageCalls = await storageProbe.scanCount
        let agentCalls = await agentProbe.callCount
        return storageCalls == 1 && agentCalls == 1
    }

    #expect(storageMap.isFullAnalysisRunning(including: agentStorage))
    storageMap.stopAnalysis(including: agentStorage)
}

@MainActor
@Test func storageMapDoesNotRestartPipelinesAlreadyRunningInUnifiedAnalysis() async throws {
    let storageProbe = StorageMapScanProbe()
    let agentProbe = UnifiedAgentStorageScanProbe()
    let codex = storageMapAgentCandidate()
    let storageMap = StorageMapModel(
        cacheURL: nil,
        detect: { [codex] in [codex] },
        scan: { progress in try await storageProbe.scanUntilCancelled(progress: progress) }
    )
    let agentStorage = AgentStorageModel { configuration in
        await agentProbe.scanUntilCancelled(configuration)
    }
    await storageMap.prepare()

    storageMap.startAnalysis(including: agentStorage)
    try await waitForStorageMapTest {
        let storageCalls = await storageProbe.scanCount
        let agentCalls = await agentProbe.callCount
        return storageCalls == 1 && agentCalls == 1
    }
    storageMap.startAnalysis(including: agentStorage)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(await storageProbe.scanCount == 1)
    #expect(await agentProbe.callCount == 1)
    storageMap.stopAnalysis(including: agentStorage)
}

@MainActor
@Test func storageMapReanalyzesOnlyTheSelectedSourceAndMergesItsVolumes() async throws {
    let npm = storageMapCandidate()
    let chrome = storageMapChromeCandidate()
    let initial = storageMapMultiSourceSnapshot(npmBytes: 4_096, chromeBytes: 8_192)
    let replacement = storageMapMultiSourceSnapshot(
        npmBytes: 12_288,
        chromeBytes: nil,
        scannedAt: Date(timeIntervalSince1970: 2_000)
    )
    let probe = StorageMapPartialScanProbe(result: replacement)
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm, chrome] in [npm, chrome] },
        scan: { _ in initial },
        scanSource: { sourceID, progress in
            try await probe.scan(sourceID: sourceID, progress: progress)
        }
    )
    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest { model.phase == .ready && model.snapshot != nil }

    model.startAnalysis(sourceID: .npm)
    try await waitForStorageMapTest {
        model.reanalyzingSourceIDs.contains(.npm)
            && model.progressBySource[.npm]?.currentWork == "npm cache"
    }

    #expect(model.snapshot == initial)
    #expect(!model.reanalyzingSourceIDs.contains(.chrome))
    #expect(model.progressBySource[.chrome] == nil)

    try await waitForStorageMapTest { !model.reanalyzingSourceIDs.contains(.npm) }
    #expect(await probe.sourceIDs == [.npm])
    #expect(model.snapshot?.result(for: .npm)?.allocatedBytes == 12_288)
    #expect(model.snapshot?.result(for: .chrome)?.allocatedBytes == 8_192)
    let systemVolume = try #require(model.snapshot?.volumes.first { $0.id == "system" })
    #expect(systemVolume.sourceUsages.first { $0.sourceID == .npm }?.allocatedBytes == 12_288)
    #expect(systemVolume.sourceUsages.first { $0.sourceID == .chrome }?.allocatedBytes == 8_192)
}

@MainActor
@Test func storageMapPartialReanalysisPresentsOnlyTheSelectedSourcesLiveReplacement() async throws {
    let npm = storageMapCandidate()
    let chrome = storageMapChromeCandidate()
    let initial = storageMapMultiSourceSnapshot(npmBytes: 4_096, chromeBytes: 8_192)
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm, chrome] in [npm, chrome] },
        scan: { _ in initial },
        scanSource: { sourceID, progress in
            progress(.init(
                phase: .measuring,
                sourceID: sourceID,
                sourceProcessedEntryCount: 3,
                sourceProcessedBytes: 12_288,
                currentWork: "npm cache",
                volumes: [
                    StorageVolumeSnapshot(
                        id: "system",
                        name: "System",
                        mountPath: "/",
                        totalCapacity: 1_000_000,
                        availableCapacity: 500_000,
                        sourceUsages: [.init(sourceID: sourceID, allocatedBytes: 12_288)]
                    )
                ]
            ))
            try await Task.sleep(for: .seconds(60))
            return initial
        }
    )
    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest { model.phase == .ready && model.snapshot != nil }

    model.startAnalysis(sourceID: .npm)
    try await waitForStorageMapTest { model.presentationAllocatedBytes(for: .npm) == 12_288 }

    let volume = try #require(model.presentationVolumes.first)
    #expect(model.isPresentingLiveResults)
    #expect(model.presentationTotalAllocatedBytes == 20_480)
    #expect(volume.sourceUsages.first { $0.sourceID == .npm }?.allocatedBytes == 12_288)
    #expect(volume.sourceUsages.first { $0.sourceID == .chrome }?.allocatedBytes == 8_192)
    model.prepareForTermination()
}

@MainActor
@Test func storageMapFullAnalysisCancelsAnActiveSourceReanalysis() async throws {
    let npm = storageMapCandidate()
    let initial = storageMapMultiSourceSnapshot(npmBytes: 4_096, chromeBytes: nil)
    let replacement = storageMapMultiSourceSnapshot(npmBytes: 8_192, chromeBytes: nil)
    let probe = StorageMapPartialScanProbe(result: replacement, delay: .seconds(60))
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm] in [npm] },
        scan: { _ in initial },
        scanSource: { sourceID, progress in
            try await probe.scan(sourceID: sourceID, progress: progress)
        }
    )
    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest { model.phase == .ready && model.snapshot != nil }
    model.startAnalysis(sourceID: .npm)
    try await waitForStorageMapTest { model.reanalyzingSourceIDs.contains(.npm) }

    model.startAnalysis()
    try await waitForStorageMapTest {
        model.phase == .ready && model.reanalyzingSourceIDs.isEmpty
    }

    #expect(model.snapshot == initial)
    #expect(model.progressBySource.isEmpty)
}

@Test func storageMapRoutesAgentSourcesToTheirOriginalDeepAnalysis() {
    #expect(StorageSourceDestination.destination(for: .codex) == .agentAnalysis(.codex))
    #expect(StorageSourceDestination.destination(for: .claude) == .agentAnalysis(.claude))
    #expect(StorageSourceDestination.destination(for: .chrome) == .tailoredAnalysis)
    #expect(StorageSourceDestination.destination(for: .go) == .tailoredAnalysis)
}

@Test func storageMapUsesDifferentAnalysisBriefsForChromeAndGo() {
    let chrome = StorageSourceDetailProfile.profile(for: .chrome)
    let go = StorageSourceDetailProfile.profile(for: .go)

    #expect(chrome.headline != go.headline)
    #expect(chrome.compositionTitle != go.compositionTitle)
    #expect(chrome.officialAction != nil)
    #expect(go.officialAction == nil)
}

@MainActor
@Test func storageMapEnglishGoAndSimulatorCopyContainsNoCJKText() {
    let defaults = UserDefaults.standard
    let previousLanguage = defaults.object(forKey: "appLanguage")
    defaults.set(AppLanguage.english.rawValue, forKey: "appLanguage")
    defer {
        if let previousLanguage {
            defaults.set(previousLanguage, forKey: "appLanguage")
        } else {
            defaults.removeObject(forKey: "appLanguage")
        }
    }

    let profiles = [
        StorageSourceDetailProfile.profile(for: .go),
        StorageSourceDetailProfile.profile(for: .simulators)
    ]
    var copy = profiles.flatMap {
        [
            $0.headline,
            $0.summary,
            $0.compositionTitle,
            $0.compositionDetail,
            $0.managementTitle,
            $0.managementDetail
        ]
    }
    let categoryTitles = [
        "构建缓存",
        "模块下载缓存",
        "已解压模块",
        "已安装工具",
        "模拟器运行时",
        "模拟器设备",
        "模拟器应用数据",
        "模拟器缓存",
        "模拟器待删除数据"
    ]
    copy.append(contentsOf: categoryTitles.flatMap { title in
        [L10n.text(title), profiles[title.hasPrefix("模拟器") ? 1 : 0].categoryDescription(title)]
    })
    copy.append(contentsOf: [
        "Simulator devices",
        "Simulator user caches",
        "Simulator pending deletion",
        "User-installed Simulator runtimes",
        "Legacy Simulator runtimes",
        "Simulator shared caches",
        "Downloaded Simulator runtimes"
    ].map(L10n.text))

    #expect(copy.allSatisfy { !$0.containsCJKUnifiedIdeograph })
}

@Test func storageMapActivityUsesSourceSpecificWorkAndAgentStage() {
    let npm = storageMapCandidate()
    let regular = StorageSourceActivityPresentation.regular(
        candidate: npm,
        result: nil,
        progress: .init(
            phase: .measuring,
            sourceID: .npm,
            sourceProcessedEntryCount: 24,
            sourceProcessedBytes: 8_192,
            currentWork: "npm cache",
            currentWorkIndex: 1,
            totalWorkCount: 1
        ),
        isFullScanRunning: true
    )
    let codex = StorageSourceActivityPresentation.agent(
        provider: .codex,
        candidate: storageMapAgentCandidate(),
        summary: nil,
        progress: .init(
            phase: .attributingDatabase,
            completedCount: 128,
            provider: .codex,
            databaseStage: .mappingRecords
        ),
        isScanning: true
    )

    #expect(regular.workDetail == "npm cache")
    #expect(regular.processedEntryCount == 24)
    #expect(regular.supportingDetail?.contains("1 / 1") == true)
    #expect(codex.phaseTitle == L10n.text("正在进行日志数据库归因"))
    #expect(codex.workDetail.contains("128"))
}

@Test func deferredWorkspaceNeverPretendsToWaitForAScanWorker() {
    let candidate = storageMapWorkspaceCandidate()
    let cachedResult = storageMapResult(descriptor: candidate.descriptor, bytes: 16_384)

    let ready = StorageSourceActivityPresentation.workspace(
        candidate: candidate,
        result: nil
    )
    let cached = StorageSourceActivityPresentation.workspace(
        candidate: candidate,
        result: cachedResult
    )

    #expect(ready.state == .ready)
    #expect(ready.supportingDetail != L10n.text("等待扫描器释放并发位置"))
    #expect(cached.state == .complete)
    #expect(cached.processedBytes == 16_384)
}

@Test func storageMapUsageOrderingTracksCurrentBytesAndUsesDeterministicTies() {
    #expect(StorageSourceUsageOrdering.precedes(
        lhsID: .go,
        lhsTitle: "Go",
        lhsBytes: 8_192,
        rhsID: .chrome,
        rhsTitle: "Chrome",
        rhsBytes: 4_096
    ))
    #expect(!StorageSourceUsageOrdering.precedes(
        lhsID: .go,
        lhsTitle: "Go",
        lhsBytes: 4_096,
        rhsID: .chrome,
        rhsTitle: "Chrome",
        rhsBytes: 8_192
    ))
    #expect(StorageSourceUsageOrdering.precedes(
        lhsID: .chrome,
        lhsTitle: "Chrome",
        lhsBytes: 4_096,
        rhsID: .go,
        rhsTitle: "Go",
        rhsBytes: 4_096
    ))
}

@Test func storageVolumeLayoutAdaptsColumnsToCountAndAvailableWidth() {
    #expect(StorageVolumeLayoutPolicy.columnCount(
        width: 1_400,
        itemCount: 1,
        minimumItemWidth: 420,
        spacing: 12
    ) == 1)
    #expect(StorageVolumeLayoutPolicy.columnCount(
        width: 900,
        itemCount: 3,
        minimumItemWidth: 420,
        spacing: 12
    ) == 2)
    #expect(StorageVolumeLayoutPolicy.columnCount(
        width: 1_320,
        itemCount: 4,
        minimumItemWidth: 420,
        spacing: 12
    ) == 3)
    #expect(StorageVolumeLayoutPolicy.columnCount(
        width: 700,
        itemCount: 4,
        minimumItemWidth: 420,
        spacing: 12
    ) == 1)
}

@Test func storageMapListFreezesOrderDuringAnalysisAndAnimatesOnlyTheFinalOrder() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testsURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp/Views/StorageMapView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("id: \\.element.id"))
    #expect(source.contains("value: items.map(\\.id)"))
    #expect(source.contains("@State private var displayedSourceOrder"))
    #expect(source.contains("if isRunning {\n                stabilizeDisplayedOrder()"))
    #expect(source.contains("synchronizeDisplayedOrder(animated: wasRunning)"))
    #expect(source.contains(".snappy(duration: 0.42, extraBounce: 0)"))
    #expect(source.contains(".frame(maxHeight: .infinity, alignment: .topLeading)"))
}

@Test func storageMapSingleRefreshFreezesOrderBeforeStartingWork() throws {
    let source = try storageMapViewSource()
    let reanalyzeBody = try #require(
        source.split(separator: "private func reanalyze", maxSplits: 1).last?
            .split(separator: "private func canReanalyze", maxSplits: 1).first
    )
    let stabilizeOffset = try #require(reanalyzeBody.range(of: "stabilizeDisplayedOrder()"))
    let startOffset = try #require(reanalyzeBody.range(of: "model.startAnalysis(sourceID: sourceID)"))

    #expect(stabilizeOffset.lowerBound < startOffset.lowerBound)
}

@Test func storageMapStableOrderKeepsExistingPositionsAndOnlyAppendsNewSources() {
    #expect(StorageSourceDisplayOrdering.stabilized(
        current: [.claude, .codex, .npm],
        available: [.npm, .openCode, .codex, .claude]
    ) == [.claude, .codex, .npm, .openCode])
    #expect(StorageSourceDisplayOrdering.stabilized(
        current: [.claude, .claude, .go],
        available: [.go, .claude]
    ) == [.claude, .go])
}

@Test func storageMapReanalysisControlNeverSpinsBesideACompletedState() {
    #expect(StorageSourceReanalysisControlState.resolve(
        activityState: .active,
        canReanalyze: false
    ) == .analyzing)
    #expect(StorageSourceReanalysisControlState.resolve(
        activityState: .complete,
        canReanalyze: false
    ) == .hidden)
    #expect(StorageSourceReanalysisControlState.resolve(
        activityState: .queued,
        canReanalyze: false
    ) == .hidden)
    #expect(StorageSourceReanalysisControlState.resolve(
        activityState: .complete,
        canReanalyze: true
    ) == .available)
}

@Test func storageMapDoesNotInstallHoverPopovers() throws {
    let source = try storageMapViewSource()

    #expect(!source.contains("NSPopover"))
    #expect(!source.contains("StorageSourceStatisticsPopover"))
    #expect(!source.contains("hoveredSourceID"))
    #expect(!source.contains("hoverTask"))
}

@Test func storageMapCompactRowsStayInsideTheDetailColumn() throws {
    let source = try storageMapViewSource()
    let compactRow = try #require(
        source.split(separator: "private var compactContent", maxSplits: 1).last?
            .split(separator: "private var identity", maxSplits: 1).first
    )
    let overview = try #require(
        source.split(separator: "private var overview", maxSplits: 1).last?
            .split(separator: "private func sourceWorkspace", maxSplits: 1).first
    )

    #expect(compactRow.contains("frame(minWidth: 0, maxWidth: .infinity"))
    #expect(compactRow.contains("stateBadge\n                    .fixedSize"))
    #expect(compactRow.contains(".clipped()"))
    #expect(overview.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    #expect(overview.contains(".clipped()"))
}

@Test func workspaceRepositoryDiscoveryBelongsToTheDetailView() throws {
    let source = try storageMapViewSource()
    let overview = try #require(
        source.split(separator: "private var overview", maxSplits: 1).last?
            .split(separator: "private var minimumWidthNotice", maxSplits: 1).first
    )
    let detail = try #require(
        source.split(separator: "private struct StorageSourceDetailView", maxSplits: 1).last?
            .split(separator: "private struct StorageSourceDetailSkeleton", maxSplits: 1).first
    )

    #expect(!overview.contains("repositoryAuthorizationBand"))
    #expect(!overview.contains("requestRepositoryAuthorization"))
    #expect(detail.contains("workspace-repository-discovery"))
    #expect(detail.contains("shouldStartWorkspaceAnalysis"))
    #expect(detail.contains("refreshRepositoryAuthorization"))
}

@Test func storageMapStartsItsUnifiedInitialAnalysisAfterDetection() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testsURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp/Views/StorageMapView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let taskBody = try #require(
        source.split(separator: ".task {", maxSplits: 1).last?
            .split(separator: ".onChange", maxSplits: 1).first
    )

    #expect(taskBody.contains("await model.prepare()"))
    #expect(taskBody.contains("shouldStartInitialAnalysis"))
    #expect(taskBody.contains("startFullAnalysis()"))
    #expect(source.contains("model.phase == .ready"))
}

@Test func storageMapResultsWaitForEveryDetectedAgentDeepAnalysis() {
    let storageSnapshot = storageMapAccessSnapshot(sourceIDs: [.chrome, .codex, .claude, .openCode])
    let requiredProviders: Set<AgentStorageProvider> = [.codex, .claude, .openCode]

    #expect(!StorageSourceResultAccess.canPresent(
        sourceID: .chrome,
        storageSnapshot: storageSnapshot,
        agentSnapshot: nil,
        requiredAgentProviders: requiredProviders
    ))
    #expect(!StorageSourceResultAccess.canPresent(
        sourceID: .codex,
        storageSnapshot: storageSnapshot,
        agentSnapshot: storageMapAgentSnapshot(providers: [.codex]),
        requiredAgentProviders: requiredProviders
    ))
    #expect(!StorageSourceResultAccess.canPresent(
        sourceID: .claude,
        storageSnapshot: storageSnapshot,
        agentSnapshot: storageMapAgentSnapshot(providers: [.claude]),
        requiredAgentProviders: requiredProviders
    ))
    #expect(!StorageSourceResultAccess.canPresent(
        sourceID: .openCode,
        storageSnapshot: storageSnapshot,
        agentSnapshot: storageMapAgentSnapshot(providers: [.codex, .claude]),
        requiredAgentProviders: requiredProviders
    ))

    let completeAgentSnapshot = storageMapAgentSnapshot(providers: [.codex, .claude, .openCode])
    for sourceID in [StorageSourceID.chrome, .codex, .claude, .openCode] {
        #expect(StorageSourceResultAccess.canPresent(
            sourceID: sourceID,
            storageSnapshot: storageSnapshot,
            agentSnapshot: completeAgentSnapshot,
            requiredAgentProviders: requiredProviders
        ))
    }
}

@Test func storageMapRoutesAllAgentSourcesToTheirExistingDeepAnalyzer() {
    #expect(StorageSourceDestination.destination(for: .codex) == .agentAnalysis(.codex))
    #expect(StorageSourceDestination.destination(for: .claude) == .agentAnalysis(.claude))
    #expect(StorageSourceDestination.destination(for: .openCode) == .agentAnalysis(.openCode))
    #expect(StorageSourceDestination.destination(for: .chrome) == .tailoredAnalysis)
}

@Test func claudeDetailKeepsTheExistingOnDemandNodeRuntimeControlReachable() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FindDiskKillerApp/Views/AgentStorageView.swift"),
        encoding: .utf8
    )
    let primaryContent = try #require(
        source.split(separator: "private var primaryContent", maxSplits: 1).last?
            .split(separator: "private var scopeActionBar", maxSplits: 1).first
    )
    let runtimeControl = try #require(
        source.split(separator: "private struct ClaudeNodeRuntimeBar", maxSplits: 1).last?
            .split(separator: "private struct AgentStorageAgeFilterPopover", maxSplits: 1).first
    )

    #expect(primaryContent.contains("selectedProvider == .claude"))
    #expect(primaryContent.contains("ClaudeNodeRuntimeBar(model: nodeRuntime)"))
    #expect(runtimeControl.contains("model.download()"))
    #expect(runtimeControl.contains("claude-node-runtime"))
}

@Test func agentCleanupKeepsSelectionAndDetailsAvailableInTheMainTable() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FindDiskKillerApp/Views/AgentStorageView.swift"),
        encoding: .utf8
    )

    #expect(source.contains("@State private var cleanupSelectedIDs: Set<String> = []"))
    #expect(!source.contains("@State private var isCleanupMode"))
    #expect(!source.contains("enterCleanupMode"))
    #expect(source.contains("AgentStorageChatSelectionCell("))
    #expect(source.contains("toggleSelection: { toggleCleanupSelection(row.familyID) }"))
    #expect(source.contains("AgentStoragePageSelectionCheckbox("))
    #expect(source.contains("agent-storage-current-page-selection"))
    #expect(source.contains("checkmark.square.fill"))
    #expect(source.contains("AgentStorageTableDetailButton("))
    #expect(source.contains("agent-storage-chat-detail-\\(row.id)"))
    #expect(source.contains("agent-storage-review-cleanup"))
    #expect(source.contains(".sheet(item: $cleanupSession)"))
    #expect(!source.contains(".sheet(item: $batchCleanupContext)"))
    #expect(!source.contains("AgentStorageBatchCleanupSheet("))
}

@Test func storageMapDoesNotPresentAResultMissingFromTheUnifiedStorageSnapshot() {
    #expect(!StorageSourceResultAccess.canPresent(
        sourceID: .claude,
        storageSnapshot: storageMapAccessSnapshot(sourceIDs: [.codex]),
        agentSnapshot: storageMapAgentSnapshot(providers: [.codex, .claude]),
        requiredAgentProviders: [.codex, .claude]
    ))
}

@Test func storageMapDetailRoutingNeverStartsAnalysis() throws {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testsURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp/Views/StorageMapView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let openSourceBody = try #require(
        source.split(separator: "private func openSource", maxSplits: 1).last?
            .split(separator: "private func canPresentResult", maxSplits: 1).first
    )

    #expect(!openSourceBody.contains("startAnalysis"))
    #expect(!openSourceBody.contains("startFullAnalysis"))
    #expect(!openSourceBody.contains("agentStorage"))
}

@Test func storageMapDetailsUseOneNativeBackControlAndOfficialBrandIcon() throws {
    let source = try storageMapViewSource()
    let agentBody = try #require(
        source.split(separator: "private func agentAnalysis", maxSplits: 1).last?
            .split(separator: "private func openSource", maxSplits: 1).first
    )
    let detailBody = try #require(
        source.split(separator: "private struct StorageSourceDetailView", maxSplits: 1).last?
            .split(separator: "private func composition", maxSplits: 1).first
    )

    #expect(agentBody.contains("providerExitAction: { route = .overview }"))
    #expect(!agentBody.contains("HStack"))
    #expect(detailBody.contains("StorageSourceBrandIcon"))
    #expect(detailBody.contains("ToolbarItem(placement: .navigation)"))
    #expect(!detailBody.contains("Button(action: goBack) { Image"))
}

private actor StorageMapScanProbe {
    private(set) var scanCount = 0

    func scan(
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        scanCount += 1
        progress(.init(phase: .measuring, sourceID: .npm, processedEntryCount: 1))
        return storageMapSnapshot()
    }

    func scanIgnoringCancellation(
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        scanCount += 1
        progress(.init(phase: .measuring, sourceID: .npm, processedEntryCount: 1))
        try? await Task.sleep(for: .milliseconds(120))
        return storageMapSnapshot()
    }

    func scanUntilCancelled(
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        scanCount += 1
        progress(.init(phase: .measuring, sourceID: .npm, processedEntryCount: 1))
        try await Task.sleep(for: .seconds(60))
        return storageMapSnapshot()
    }
}

private final class StorageMapAuthorizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    private var detections = 0
    private var scans = 0
    private var workspaceScans = 0

    var isGranted: Bool {
        lock.withLock { granted }
    }

    var detectionCount: Int {
        lock.withLock { detections }
    }

    var scanCount: Int {
        lock.withLock { scans }
    }

    var workspaceScanCount: Int {
        lock.withLock { workspaceScans }
    }

    func grant() {
        lock.withLock { granted = true }
    }

    func recordDetection() {
        lock.withLock {
            detections += 1
        }
    }

    func recordScan() {
        lock.withLock { scans += 1 }
    }

    func recordSourceScan(_ sourceID: StorageSourceID) {
        lock.withLock {
            if sourceID == .workspace { workspaceScans += 1 }
        }
    }
}

private actor StorageMapSnapshotSequence {
    private var snapshots: [StorageAnalysisSnapshot]

    init(_ snapshots: [StorageAnalysisSnapshot]) {
        self.snapshots = snapshots
    }

    var remainingCount: Int { snapshots.count }

    func next() -> StorageAnalysisSnapshot {
        snapshots.removeFirst()
    }
}

private func storageMapViewSource() throws -> String {
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testsURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/FindDiskKillerApp/Views/StorageMapView.swift"
        ),
        encoding: .utf8
    )
}

private actor StorageMapPartialScanProbe {
    private(set) var sourceIDs: [StorageSourceID] = []
    private let result: StorageAnalysisSnapshot
    private let delay: Duration

    init(
        result: StorageAnalysisSnapshot,
        delay: Duration = .milliseconds(80)
    ) {
        self.result = result
        self.delay = delay
    }

    func scan(
        sourceID: StorageSourceID,
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        sourceIDs.append(sourceID)
        progress(.init(
            phase: .measuring,
            sourceID: sourceID,
            sourceProcessedEntryCount: 1,
            sourceProcessedBytes: 1_024,
            currentWork: "npm cache"
        ))
        try await Task.sleep(for: delay)
        return result
    }
}

private actor UnifiedAgentStorageScanProbe {
    private(set) var callCount = 0

    func scan(_ configuration: AgentStorageScanner.Configuration) async -> AgentStorageSnapshot {
        _ = configuration
        callCount += 1
        try? await Task.sleep(for: .milliseconds(120))
        return AgentStorageSnapshot(
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
            crossAgentSharedBytes: 0,
            diagnostics: []
        )
    }

    func scanUntilCancelled(
        _ configuration: AgentStorageScanner.Configuration
    ) async -> AgentStorageSnapshot {
        _ = configuration
        callCount += 1
        try? await Task.sleep(for: .seconds(60))
        return AgentStorageSnapshot(
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
            crossAgentSharedBytes: 0,
            diagnostics: []
        )
    }
}

@MainActor
private func waitForStorageMapTest(
    timeout: Duration = .seconds(2),
    condition: @escaping () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for storage map test condition")
}

private func storageMapCandidate() -> StorageSourceCandidate {
    let descriptor = StorageSourceDescriptor(
        id: .npm,
        title: "npm",
        family: .developerTools,
        symbol: "shippingbox",
        cleanupCapability: .analysisOnly
    )
    return StorageSourceCandidate(
        descriptor: descriptor,
        roots: [
            StorageSourceRoot(
                id: "npm.cache",
                sourceID: .npm,
                displayName: "npm cache",
                path: "/tmp/npm",
                defaultCategory: "Package cache",
                defaultRisk: .rebuildableCache
            )
        ]
    )
}

private func storageMapChromeCandidate() -> StorageSourceCandidate {
    StorageSourceCandidate(
        descriptor: StorageSourceDescriptor(
            id: .chrome,
            title: "Chrome",
            family: .applications,
            symbol: "globe",
            cleanupCapability: .openOfficialManager
        ),
        roots: [
            StorageSourceRoot(
                id: "chrome.cache",
                sourceID: .chrome,
                displayName: "Chrome cache",
                path: "/tmp/chrome",
                defaultCategory: "Browser cache",
                defaultRisk: .rebuildableCache
            )
        ]
    )
}

private func storageMapWorkspaceCandidate() -> StorageSourceCandidate {
    StorageSourceCandidate(
        descriptor: StorageSourceDescriptor(
            id: .workspace,
            title: "Git Workspaces",
            family: .workspaces,
            symbol: "folder.badge.gearshape",
            cleanupCapability: .analysisOnly
        ),
        roots: [],
        diagnostic: "Repository discovery is available in details"
    )
}

private func storageMapWorkspaceSnapshot() -> StorageAnalysisSnapshot {
    let descriptor = storageMapWorkspaceCandidate().descriptor
    let result = storageMapResult(descriptor: descriptor, bytes: 16_384)
    return StorageAnalysisSnapshot(
        scannedAt: Date(timeIntervalSince1970: 2_000),
        results: [result],
        totalAllocatedBytes: result.allocatedBytes,
        conflictBytes: 0,
        measuredEntryCount: result.entryCount,
        skippedEntryCount: 0,
        volumes: [
            StorageVolumeSnapshot(
                id: "system",
                name: "System",
                mountPath: "/",
                totalCapacity: 1_000_000,
                availableCapacity: 500_000,
                sourceUsages: [.init(sourceID: .workspace, allocatedBytes: result.allocatedBytes)]
            )
        ]
    )
}

private func storageMapSnapshotIncludingWorkspace() -> StorageAnalysisSnapshot {
    let npmResult = storageMapResult(descriptor: storageMapCandidate().descriptor, bytes: 4_096)
    let workspaceResult = storageMapResult(
        descriptor: storageMapWorkspaceCandidate().descriptor,
        bytes: 16_384
    )
    return StorageAnalysisSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        results: [npmResult, workspaceResult],
        totalAllocatedBytes: 20_480,
        conflictBytes: 0,
        measuredEntryCount: 2,
        skippedEntryCount: 0,
        volumes: [
            StorageVolumeSnapshot(
                id: "system",
                name: "System",
                mountPath: "/",
                totalCapacity: 1_000_000,
                availableCapacity: 500_000,
                sourceUsages: [
                    .init(sourceID: .workspace, allocatedBytes: 16_384),
                    .init(sourceID: .npm, allocatedBytes: 4_096)
                ]
            )
        ]
    )
}

private func storageMapAgentCandidate() -> StorageSourceCandidate {
    let descriptor = StorageSourceDescriptor(
        id: .codex,
        title: "Codex",
        family: .aiTools,
        symbol: "terminal",
        cleanupCapability: .analysisOnly
    )
    return StorageSourceCandidate(
        descriptor: descriptor,
        roots: [
            StorageSourceRoot(
                id: "codex.home",
                sourceID: .codex,
                displayName: "Codex Home",
                path: "/tmp/codex",
                defaultCategory: "Codex data",
                defaultRisk: .protectedUserData,
                isProtected: true
            )
        ]
    )
}

private func storageMapSnapshot() -> StorageAnalysisSnapshot {
    let candidate = storageMapCandidate()
    let component = StorageComponent(
        id: "npm.cache.package",
        title: "Package cache",
        rootDisplayName: "npm cache",
        allocatedBytes: 4_096,
        logicalBytes: 4_096,
        entryCount: 1,
        newestModificationDate: nil,
        risk: .rebuildableCache,
        isProtected: false
    )
    let result = StorageSourceResult(
        descriptor: candidate.descriptor,
        availability: .available,
        allocatedBytes: 4_096,
        logicalBytes: 4_096,
        entryCount: 1,
        reclaimableCandidateBytes: 4_096,
        components: [component]
    )
    return StorageAnalysisSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        results: [result],
        totalAllocatedBytes: 4_096,
        conflictBytes: 0,
        measuredEntryCount: 1,
        skippedEntryCount: 0
    )
}

private func storageMapMultiSourceSnapshot(
    npmBytes: UInt64?,
    chromeBytes: UInt64?,
    scannedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> StorageAnalysisSnapshot {
    var results: [StorageSourceResult] = []
    var usages: [StorageVolumeSourceUsage] = []
    if let npmBytes {
        results.append(storageMapResult(
            descriptor: storageMapCandidate().descriptor,
            bytes: npmBytes
        ))
        usages.append(.init(sourceID: .npm, allocatedBytes: npmBytes))
    }
    if let chromeBytes {
        results.append(storageMapResult(
            descriptor: storageMapChromeCandidate().descriptor,
            bytes: chromeBytes
        ))
        usages.append(.init(sourceID: .chrome, allocatedBytes: chromeBytes))
    }
    return StorageAnalysisSnapshot(
        scannedAt: scannedAt,
        results: results,
        totalAllocatedBytes: results.reduce(0) { $0 + $1.allocatedBytes },
        conflictBytes: 0,
        measuredEntryCount: results.count,
        skippedEntryCount: 0,
        volumes: [
            StorageVolumeSnapshot(
                id: "system",
                name: "System",
                mountPath: "/",
                totalCapacity: 1_000_000,
                availableCapacity: 500_000,
                sourceUsages: usages
            )
        ]
    )
}

private func storageMapResult(
    descriptor: StorageSourceDescriptor,
    bytes: UInt64
) -> StorageSourceResult {
    StorageSourceResult(
        descriptor: descriptor,
        availability: .available,
        allocatedBytes: bytes,
        logicalBytes: bytes,
        entryCount: 1,
        reclaimableCandidateBytes: bytes,
        components: [
            StorageComponent(
                id: "\(descriptor.id.rawValue).cache",
                title: "Cache",
                rootDisplayName: descriptor.title,
                allocatedBytes: bytes,
                logicalBytes: bytes,
                entryCount: 1,
                newestModificationDate: nil,
                risk: .rebuildableCache,
                isProtected: false
            )
        ]
    )
}

private func storageMapAccessSnapshot(
    sourceIDs: [StorageSourceID]
) -> StorageAnalysisSnapshot {
    let results = sourceIDs.map { sourceID in
        StorageSourceResult(
            descriptor: StorageSourceDescriptor(
                id: sourceID,
                title: sourceID.rawValue,
                family: sourceID == .chrome ? .applications : .aiTools,
                symbol: "externaldrive",
                cleanupCapability: .analysisOnly
            ),
            availability: .available,
            allocatedBytes: 1,
            logicalBytes: 1,
            entryCount: 1,
            reclaimableCandidateBytes: 0,
            components: []
        )
    }
    return StorageAnalysisSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        results: results,
        totalAllocatedBytes: UInt64(results.count),
        conflictBytes: 0,
        measuredEntryCount: results.count,
        skippedEntryCount: 0
    )
}

private func storageMapAgentSnapshot(
    providers: [AgentStorageProvider]
) -> AgentStorageSnapshot {
    AgentStorageSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        families: [],
        globalItems: [],
        unattributedItems: [],
        providers: providers.map { provider in
            AgentStorageProviderSummary(
                provider: provider,
                exclusiveBytes: 0,
                chatBytes: 0,
                globalBytes: 0,
                unattributedBytes: 0,
                mainThreadBytes: 0,
                subagentBytes: 0,
                familyOtherBytes: 0,
                threadCount: 0,
                subagentCount: 0,
                sourceCount: 0,
                issueCount: 0
            )
        },
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

private extension String {
    var containsCJKUnifiedIdeograph: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }
}
