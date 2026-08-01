import Darwin
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

@MainActor
@Test func cleanupRefreshRunsAfterAnInterruptedFullAnalysisAndReplacesStaleDockerData() async throws {
    let npm = storageMapCandidate()
    let initial = storageMapMultiSourceSnapshot(npmBytes: 4_096, chromeBytes: nil)
    let replacement = storageMapMultiSourceSnapshot(npmBytes: 12_288, chromeBytes: nil)
    let probe = StorageMapCleanupRefreshProbe(initial: initial, replacement: replacement)
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm] in [npm] },
        scan: { progress in try await probe.fullScan(progress: progress) },
        scanSource: { sourceID, progress in
            try await probe.sourceScan(sourceID: sourceID, progress: progress)
        }
    )
    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest { model.phase == .ready && model.snapshot != nil }

    model.startAnalysis()
    #expect(model.phase == .scanning)
    model.refreshAfterCleanup(sourceID: .npm)
    #expect(await probe.sourceScanCount == 0)

    model.stopAnalysis()
    try await waitForStorageMapTest {
        await probe.sourceScanCount == 1
            && model.phase == .ready
            && model.reanalyzingSourceIDs.isEmpty
    }

    #expect(model.snapshot?.result(for: .npm)?.allocatedBytes == 12_288)
    #expect(await probe.sourceIDs == [.npm])
}

@MainActor
@Test func cleanupRefreshFailureIsAttachedToTheAffectedSource() async throws {
    let npm = storageMapCandidate()
    let initial = storageMapMultiSourceSnapshot(npmBytes: 4_096, chromeBytes: nil)
    let model = StorageMapModel(
        cacheURL: nil,
        detect: { [npm] in [npm] },
        scan: { _ in initial },
        scanSource: { _, _ in throw CleanupLifecycleTestError.syncFailed }
    )
    await model.prepare()
    model.startAnalysis()
    try await waitForStorageMapTest { model.phase == .ready && model.snapshot != nil }

    model.refreshAfterCleanup(sourceID: .npm)
    try await waitForStorageMapTest {
        !model.reanalyzingSourceIDs.contains(.npm)
            && model.refreshErrorsBySource[.npm] != nil
    }

    #expect(model.snapshot == initial)
    #expect(model.refreshErrorsBySource[.npm] == "同步失败")
}

@Test func storageMapRoutesAgentSourcesToTheirOriginalDeepAnalysis() {
    #expect(StorageSourceDestination.destination(for: .codex) == .agentAnalysis(.codex))
    #expect(StorageSourceDestination.destination(for: .claude) == .agentAnalysis(.claude))
    #expect(StorageSourceDestination.destination(for: .chrome) == .tailoredAnalysis)
    #expect(StorageSourceDestination.destination(for: .go) == .tailoredAnalysis)
    #expect(AgentStorageProvider.codex.storageSourceID == .codex)
    #expect(AgentStorageProvider.claude.storageSourceID == .claude)
    #expect(AgentStorageProvider.openCode.storageSourceID == .openCode)
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

@Test func completedStorageRowsDescribeLargestMeasuredComponents() {
    let descriptor = storageMapCandidate().descriptor
    func component(_ id: String, _ title: String, _ bytes: UInt64) -> StorageComponent {
        StorageComponent(
            id: id,
            title: title,
            rootDisplayName: "npm cache",
            allocatedBytes: bytes,
            logicalBytes: bytes,
            entryCount: 1,
            newestModificationDate: nil,
            risk: .rebuildableCache,
            isProtected: false
        )
    }
    let result = StorageSourceResult(
        descriptor: descriptor,
        availability: .available,
        allocatedBytes: 29_000,
        logicalBytes: 29_000,
        entryCount: 5,
        reclaimableCandidateBytes: 29_000,
        components: [
            component("logs", "调试日志", 3_000),
            component("cache", "内容寻址缓存", 10_000),
            component("cache-copy", "内容寻址缓存", 5_000),
            component("npx", "npx 临时安装", 8_000),
            component("metadata", "包索引元数据", 3_000)
        ]
    )

    #expect(StorageSourceActivityPresentation.completedComposition(for: result) == [
        L10n.text("内容寻址缓存"),
        L10n.text("npx 临时安装"),
        L10n.text("包索引元数据")
    ].joined(separator: L10n.text("、")))
}

@Test func completedAgentRowsDescribeAttributedStorageComposition() {
    let summary = AgentStorageProviderSummary(
        provider: .codex,
        exclusiveBytes: 100,
        chatBytes: 55,
        globalBytes: 35,
        unattributedBytes: 10,
        mainThreadBytes: 40,
        subagentBytes: 15,
        familyOtherBytes: 0,
        threadCount: 2,
        subagentCount: 1,
        sourceCount: 1,
        issueCount: 0
    )

    #expect(StorageSourceActivityPresentation.completedAgentComposition(for: summary) == [
        L10n.text("聊天与子代理"),
        L10n.text("工具全局数据"),
        L10n.text("未归属数据")
    ].joined(separator: L10n.text("、")))
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

@Test func storageMapReanalysisButtonIsPersistentAndActionable() throws {
    let source = try storageMapViewSource()
    let buttonBody = try #require(
        source.split(separator: "private var analysisButton", maxSplits: 1).last?
            .split(separator: "private var isAnalysisRunning", maxSplits: 1).first
    )

    #expect(buttonBody.contains("Text(L10n.text(isAnalysisRunning ? \"停止分析\" : \"重新分析\"))"))
    #expect(buttonBody.contains("storage-map-reanalyze"))
    #expect(buttonBody.contains("idealWidth: 178"))
    #expect(buttonBody.contains("minHeight: 58"))
    #expect(!buttonBody.contains("opacity(isHovering ? 1 : 0)"))
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
    #expect(compactRow.contains("activityContent"))
    #expect(!compactRow.contains("stateBadge"))
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

@Test func storageMapResultAccessDependsOnlyOnTheSelectedSource() {
    let storageSnapshot = storageMapAccessSnapshot(sourceIDs: [.chrome, .codex, .claude, .openCode])

    #expect(StorageSourceResultAccess.resolve(
        sourceID: .chrome,
        storageSnapshot: storageSnapshot,
        agentSnapshot: nil
    ) == .available)
    #expect(StorageSourceResultAccess.resolve(
        sourceID: .codex,
        storageSnapshot: storageSnapshot,
        agentSnapshot: storageMapAgentSnapshot(providers: [.codex])
    ) == .available)
    #expect(StorageSourceResultAccess.resolve(
        sourceID: .claude,
        storageSnapshot: storageSnapshot,
        agentSnapshot: storageMapAgentSnapshot(providers: [.codex])
    ) == .agentResultRequired(.claude))
    #expect(StorageSourceResultAccess.resolve(
        sourceID: .openCode,
        storageSnapshot: storageSnapshot,
        agentSnapshot: nil
    ) == .agentResultRequired(.openCode))

    let completeAgentSnapshot = storageMapAgentSnapshot(providers: [.codex, .claude, .openCode])
    for sourceID in [StorageSourceID.chrome, .codex, .claude, .openCode] {
        #expect(StorageSourceResultAccess.resolve(
            sourceID: sourceID,
            storageSnapshot: storageSnapshot,
            agentSnapshot: completeAgentSnapshot
        ) == .available)
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
    #expect(source.contains("AgentStorageIndexBuilder.build("))
    #expect(source.contains("let worker = Task.detached(priority: .userInitiated)"))
    #expect(source.contains("cleanupBytesByFamilyID[row.familyID]"))
    #expect(!source.contains("rebuildProviderIndexes("))
}

@Test func storageMapDoesNotPresentAResultMissingFromTheUnifiedStorageSnapshot() {
    #expect(StorageSourceResultAccess.resolve(
        sourceID: .claude,
        storageSnapshot: storageMapAccessSnapshot(sourceIDs: [.codex]),
        agentSnapshot: storageMapAgentSnapshot(providers: [.codex, .claude])
    ) == .storageResultRequired)
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
            .split(separator: "private func resultAccess", maxSplits: 1).first
    )

    #expect(!openSourceBody.contains("startAnalysis"))
    #expect(!openSourceBody.contains("startFullAnalysis"))
    #expect(!openSourceBody.contains("agentStorage"))
}

@Test func storageMapSourceRowsKeepNavigationResponsiveAndExplainUnavailableDetails() throws {
    let source = try storageMapViewSource()
    let row = try #require(
        source.split(separator: "private struct StorageSourceWorkbenchRow", maxSplits: 1).last?
            .split(separator: "private struct StorageSourceBrandIcon", maxSplits: 1).first
    )

    #expect(row.contains("Button(action: requestOpen)"))
    #expect(row.contains(".overlay(alignment: .trailing)"))
    #expect(row.contains("await Task.yield()"))
    #expect(row.contains("presentAccessFeedback(unavailableMessage)"))
    #expect(row.contains("accessibilityHint(openAvailability.canPresent"))
    #expect(row.components(separatedBy: ".allowsHitTesting(false)").count >= 3)
    #expect(!row.contains(".disabled(isOpening)"))
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

@Test func safeCleanupProjectionIncludesVerifiedCachesAndDanglingImages() throws {
    let identity = StoragePathIdentity(device: 11, inode: 22)
    let safeNode = StorageResourceNode(
        id: "go.build-cache",
        kind: .location,
        title: "Build cache",
        symbol: "shippingbox",
        allocatedBytes: 8_192,
        risk: .rebuildableCache,
        evidence: .fileSystemAllocated,
        isProtected: false,
        cleanupTarget: .removePathContents(
            path: "/tmp/go-build",
            identity: identity,
            sourceID: .go,
            rootID: "go.build-cache"
        )
    )
    let protectedNode = StorageResourceNode(
        id: "go.tools",
        kind: .location,
        title: "Installed tools",
        symbol: "hammer",
        allocatedBytes: 4_096,
        risk: .protectedUserData,
        evidence: .fileSystemAllocated,
        isProtected: true,
        cleanupTarget: .removePathContents(
            path: "/tmp/go-tools",
            identity: identity,
            sourceID: .go,
            rootID: "go.tools"
        )
    )
    let dockerNode = StorageResourceNode(
        id: "docker.image",
        kind: .dockerImage,
        title: "Unused image",
        symbol: "shippingbox",
        allocatedBytes: 16_384,
        risk: .rebuildableCache,
        evidence: .providerReported,
        isProtected: false,
        cleanupTarget: .dockerImage(id: "sha256:test")
    )
    let taggedImageNode = StorageResourceNode(
        id: "docker.image.tagged",
        kind: .dockerImage,
        title: "Tagged image",
        symbol: "shippingbox",
        allocatedBytes: 12_288,
        risk: .environmentOrRuntime,
        evidence: .providerReported,
        isProtected: false,
        cleanupTarget: .dockerImage(id: "sha256:tagged")
    )
    let volumeNode = StorageResourceNode(
        id: "docker.volume.data",
        kind: .dockerVolume,
        title: "data",
        symbol: "externaldrive",
        allocatedBytes: 65_536,
        risk: .protectedUserData,
        evidence: .providerReported,
        isProtected: true,
        cleanupTarget: .dockerVolume(name: "data")
    )
    let repositoryNode = StorageResourceNode(
        id: "workspace.repository",
        kind: .repository,
        title: "Repository",
        symbol: "folder.badge.gearshape",
        allocatedBytes: 32_768,
        risk: .rebuildableCache,
        evidence: .fileSystemAllocated,
        isProtected: false,
        cleanupTarget: .trashRepository(path: "/tmp/repository", identity: identity)
    )
    let worktreeNode = StorageResourceNode(
        id: "workspace.worktree",
        kind: .worktree,
        title: "Worktree",
        symbol: "arrow.triangle.branch",
        allocatedBytes: 4_096,
        risk: .rebuildableCache,
        evidence: .fileSystemAllocated,
        isProtected: false,
        cleanupTarget: .removeGitWorktree(
            path: "/tmp/worktree",
            mainRepositoryPath: "/tmp/repository",
            identity: identity
        )
    )

    let requests = StorageSafeCleanupProjection.safeRequests(
        in: [
            safeNode,
            protectedNode,
            dockerNode,
            taggedImageNode,
            volumeNode,
            repositoryNode,
            worktreeNode
        ]
    )

    #expect(requests.map(\.id) == ["docker.image", "go.build-cache"])
    #expect(requests.first?.displayBytes == 16_384)
    guard case .dockerImage = try #require(requests.first).target else {
        Issue.record("Expected a dangling Docker image cleanup target")
        return
    }
    guard case .removePathContents = try #require(requests.last).target else {
        Issue.record("Expected a verified directory cleanup target")
        return
    }
}

@Test func dockerImageCleanupRevalidatesReferencesBeforeUsingOfficialRemoval() async {
    let recorder = DockerCleanupCommandRecorder(referenceOutput: "")
    let executor = StorageResourceCleanupExecutor(dockerCommand: { arguments in
        await recorder.run(arguments)
    })
    let request = StorageCleanupRequest(
        id: "docker.image.test",
        title: "Dangling image",
        displayBytes: 1_024,
        target: .dockerImage(id: "sha256:test")
    )

    let summary = await executor.execute([request])
    let commands = await recorder.commands

    #expect(summary.succeededCount == 1)
    #expect(commands == [
        ["image", "inspect", "sha256:test", "--format", "{{json .RepoTags}}"],
        ["container", "ls", "--all", "--quiet", "--filter", "ancestor=sha256:test"],
        ["image", "rm", "sha256:test"]
    ])
}

@Test func dockerImageCleanupRemovesEveryVerifiedRepositoryReferenceWithoutForce() async {
    let recorder = DockerCleanupCommandRecorder(
        referenceOutput: "",
        inspectOutput: #"["mirror.example/app@sha256:test","registry.example/app@sha256:test"]"#
    )
    let executor = StorageResourceCleanupExecutor(dockerCommand: { arguments in
        await recorder.run(arguments)
    })
    let request = StorageCleanupRequest(
        id: "docker.image.test",
        title: "Digest-only image",
        displayBytes: 1_024,
        target: .dockerImage(id: "sha256:test")
    )

    let summary = await executor.execute([request])
    let commands = await recorder.commands

    #expect(summary.succeededCount == 1)
    #expect(commands == [
        ["image", "inspect", "sha256:test", "--format", "{{json .RepoTags}}"],
        ["container", "ls", "--all", "--quiet", "--filter", "ancestor=sha256:test"],
        ["image", "rm", "mirror.example/app@sha256:test"],
        ["image", "rm", "registry.example/app@sha256:test"]
    ])
    #expect(!commands.flatMap { $0 }.contains("--force"))
}

@Test func dockerVolumeCleanupStopsWhenAContainerNowReferencesIt() async {
    let recorder = DockerCleanupCommandRecorder(referenceOutput: "container-id\n")
    let executor = StorageResourceCleanupExecutor(dockerCommand: { arguments in
        await recorder.run(arguments)
    })
    let request = StorageCleanupRequest(
        id: "docker.volume.data",
        title: "data",
        displayBytes: 2_048,
        target: .dockerVolume(name: "data")
    )

    let summary = await executor.execute([request])
    let commands = await recorder.commands

    #expect(summary.failedCount == 1)
    #expect(commands == [
        ["volume", "inspect", "data"],
        ["container", "ls", "--all", "--quiet", "--filter", "volume=data"]
    ])
}

@Test func podmanContainerCleanupUsesPodmanCommand() async {
    let recorder = DockerCleanupCommandRecorder(referenceOutput: "")
    let executor = StorageResourceCleanupExecutor(podmanCommand: { arguments in
        await recorder.run(arguments)
    })
    let request = StorageCleanupRequest(
        id: "podman.container.worker",
        title: "worker",
        displayBytes: 2_048,
        target: .podmanContainer(id: "container-id")
    )

    let summary = await executor.execute([request])
    let commands = await recorder.commands

    #expect(summary.succeededCount == 1)
    #expect(commands == [["container", "rm", "container-id"]])
}

@Test func simulatorCleanupUsesOfficialSimctlCommands() async {
    let recorder = DockerCleanupCommandRecorder(referenceOutput: "")
    let executor = StorageResourceCleanupExecutor(simctlCommand: { arguments in
        await recorder.run(arguments)
    })
    let runtimeURL = FileManager.default.temporaryDirectory
        .appending(path: "FindDiskKiller-runtime-\(UUID().uuidString).simruntime")
    try? FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: runtimeURL) }
    var runtimeStat = stat()
    _ = lstat(runtimeURL.path, &runtimeStat)
    let requests = [
        StorageCleanupRequest(
            id: "simulator.device",
            title: "iPhone 16 Pro",
            displayBytes: 2_048,
            target: .simulatorDevice(identifier: "DEVICE-ONE")
        ),
        StorageCleanupRequest(
            id: "simulator.runtime",
            title: "iOS 18.5",
            displayBytes: 4_096,
            target: .simulatorRuntime(
                identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                path: runtimeURL.path,
                identity: StoragePathIdentity(
                    device: UInt64(runtimeStat.st_dev),
                    inode: UInt64(runtimeStat.st_ino)
                )
            )
        )
    ]

    let summary = await executor.execute(requests)
    let commands = await recorder.commands

    #expect(summary.succeededCount == 2)
    #expect(commands == [
        ["delete", "DEVICE-ONE"],
        ["runtime", "delete", "com.apple.CoreSimulator.SimRuntime.iOS-18-5"]
    ])
}

@Test func missingFileCleanupTargetsAreIdempotentSuccesses() async {
    let missingRoot = FileManager.default.temporaryDirectory
        .appending(path: "FindDiskKiller-missing-\(UUID().uuidString)").path
    let identity = StoragePathIdentity(device: .max, inode: .max)
    let requests = [
        StorageCleanupRequest(
            id: "missing.cache",
            title: "Missing cache",
            displayBytes: 1,
            target: .removePathContents(
                path: missingRoot,
                identity: identity,
                sourceID: .npm,
                rootID: "missing.cache"
            )
        ),
        StorageCleanupRequest(
            id: "missing.repository",
            title: "Missing repository",
            displayBytes: 1,
            target: .trashRepository(path: missingRoot, identity: identity)
        ),
        StorageCleanupRequest(
            id: "missing.worktree",
            title: "Missing worktree",
            displayBytes: 1,
            target: .removeGitWorktree(
                path: missingRoot,
                mainRepositoryPath: missingRoot + "-main",
                identity: identity
            )
        )
    ]

    let summary = await StorageResourceCleanupExecutor().execute(requests)

    #expect(summary.succeededCount == 3)
    #expect(summary.failedCount == 0)
}

@Test func snapshotCacheWriterRejectsAnObsoleteCleanupSnapshot() async throws {
    let cacheURL = FileManager.default.temporaryDirectory
        .appending(path: "FindDiskKiller-snapshot-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let current = storageMapMultiSourceSnapshot(
        npmBytes: 2_048,
        chromeBytes: nil,
        scannedAt: Date(timeIntervalSince1970: 2_000)
    )
    let obsolete = storageMapMultiSourceSnapshot(
        npmBytes: 8_192,
        chromeBytes: nil,
        scannedAt: Date(timeIntervalSince1970: 1_000)
    )
    let writer = SnapshotCacheWriter<StorageAnalysisSnapshot>()

    await writer.save(current, to: cacheURL, revision: 2)
    await writer.save(obsolete, to: cacheURL, revision: 1)

    let restored = try JSONDecoder().decode(
        StorageAnalysisSnapshot.self,
        from: Data(contentsOf: cacheURL)
    )
    #expect(restored == current)
}

@Test func storageResourceTreeCollapsesARepeatedSingleLeafWithoutLosingCleanup() throws {
    let identity = StoragePathIdentity(device: 1, inode: 2)
    let child = StorageResourceNode(
        id: "go.build-cache.category",
        kind: .category,
        title: "构建缓存",
        symbol: "shippingbox",
        allocatedBytes: 8_192,
        logicalBytes: 7_168,
        entryCount: 12,
        risk: .rebuildableCache,
        evidence: .fileSystemAllocated,
        isProtected: false
    )
    let parent = StorageResourceNode(
        id: "go.build-cache",
        kind: .location,
        title: "Build cache",
        symbol: "shippingbox",
        allocatedBytes: 8_192,
        logicalBytes: 7_168,
        entryCount: 12,
        risk: .rebuildableCache,
        evidence: .fileSystemAllocated,
        isProtected: false,
        cleanupTarget: .removePathContents(
            path: "/tmp/go-build",
            identity: identity,
            sourceID: .go,
            rootID: "go.build-cache"
        ),
        children: [child]
    )

    let presented = try #require(
        StorageResourceTreeProjection.presentationNodes([parent]).first
    )

    #expect(presented.children.isEmpty)
    #expect(presented.cleanupTarget == parent.cleanupTarget)
    #expect(StorageResourceTreeProjection.cleanupRequests(in: presented).map(\.id) == [parent.id])
}

@Test func storageResourceTreePreservesMeaningfulChildStructure() {
    func node(
        id: String,
        bytes: UInt64,
        children: [StorageResourceNode] = []
    ) -> StorageResourceNode {
        StorageResourceNode(
            id: id,
            kind: .category,
            title: id,
            symbol: "folder",
            allocatedBytes: bytes,
            logicalBytes: bytes,
            entryCount: 1,
            risk: .environmentOrRuntime,
            evidence: .fileSystemAllocated,
            isProtected: true,
            children: children
        )
    }
    let unequal = node(id: "unequal", bytes: 10, children: [node(id: "partial", bytes: 4)])
    let grouped = node(
        id: "grouped",
        bytes: 10,
        children: [node(id: "first", bytes: 4), node(id: "second", bytes: 6)]
    )

    let presented = StorageResourceTreeProjection.presentationNodes([unequal, grouped])

    #expect(presented[0].children.map(\.id) == ["partial"])
    #expect(presented[1].children.map(\.id) == ["first", "second"])
}

@Test func storageResourceTreeExpandsOnlyAncestorsOfSafeTargets() {
    func node(
        id: String,
        children: [StorageResourceNode] = []
    ) -> StorageResourceNode {
        StorageResourceNode(
            id: id,
            kind: .category,
            title: id,
            symbol: "folder",
            allocatedBytes: 1,
            risk: .environmentOrRuntime,
            evidence: .fileSystemAllocated,
            isProtected: true,
            children: children
        )
    }
    let nodes = [
        node(id: "safe-root", children: [
            node(id: "safe-group", children: [node(id: "safe-target")]),
            node(id: "unrelated-group", children: [node(id: "unrelated-leaf")])
        ]),
        node(id: "closed-root", children: [node(id: "closed-leaf")])
    ]

    let expanded = StorageResourceTreeProjection.expansionIDs(
        to: ["safe-target"],
        in: nodes
    )

    #expect(expanded == ["safe-root", "safe-group"])
}

@Test func storageResourceTreeExpandsWorkspaceParentDirectoriesByDefault() {
    let parent = StorageResourceNode(
        id: "workspace.parent.code",
        kind: .location,
        title: "code",
        symbol: "folder.fill",
        allocatedBytes: 2,
        risk: .environmentOrRuntime,
        evidence: .fileSystemAllocated,
        isProtected: false,
        children: [
            StorageResourceNode(
                id: "workspace.repository.alpha",
                kind: .repository,
                title: "alpha",
                symbol: "folder.badge.gearshape",
                allocatedBytes: 1,
                risk: .protectedUserData,
                evidence: .fileSystemAllocated,
                isProtected: true,
                cleanupTarget: .trashRepository(
                    path: "/tmp/alpha",
                    identity: StoragePathIdentity(device: 1, inode: 1)
                )
            )
        ]
    )

    let index = StorageResourceTreeIndex(nodes: [parent])

    #expect(index.defaultExpandedIDs.contains(parent.id))
}

@Test func storageResourceTreeExpandsContainerObjectGroupsByDefault() {
    let image = StorageResourceNode(
        id: "docker.image.sha256:test",
        kind: .dockerImage,
        title: "example/app:latest",
        symbol: "shippingbox.fill",
        allocatedBytes: 1,
        entryCount: 1,
        risk: .environmentOrRuntime,
        evidence: .providerReported,
        isProtected: true
    )
    let images = StorageResourceNode(
        id: "docker.engine.images",
        kind: .dockerImages,
        title: "镜像",
        symbol: "shippingbox.fill",
        allocatedBytes: 2,
        entryCount: 1,
        risk: .environmentOrRuntime,
        evidence: .providerReported,
        isProtected: true,
        children: [image]
    )
    let engine = StorageResourceNode(
        id: "docker.engine-objects",
        kind: .dockerStorage,
        title: "Docker Engine 资源",
        symbol: "shippingbox.fill",
        allocatedBytes: 3,
        entryCount: 2,
        risk: .environmentOrRuntime,
        evidence: .providerReported,
        isProtected: true,
        children: [images]
    )

    let index = StorageResourceTreeIndex(nodes: [engine])

    #expect(index.defaultExpandedIDs.contains(engine.id))
    #expect(index.defaultExpandedIDs.contains(images.id))
    #expect(index.defaultRows.map(\.id) == [engine.id, images.id, image.id])
}

@Test func storageResourceTreeMigratesCachedRepositoriesIntoParentDirectories() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "FindDiskKiller-WorkspaceProjection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let code = root.appending(path: "Downloads/code")
    let alpha = code.appending(path: "alpha")
    let beta = code.appending(path: "beta")
    try FileManager.default.createDirectory(
        at: alpha.appending(path: ".git"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: beta.appending(path: ".git"),
        withIntermediateDirectories: true
    )

    func cachedRepository(_ name: String, path: String) -> StorageResourceNode {
        StorageResourceNode(
            id: "workspace.repository.\(name)",
            kind: .repository,
            title: name,
            detail: "主仓库 · main · \(path)",
            symbol: "folder.badge.gearshape",
            allocatedBytes: 1,
            risk: .protectedUserData,
            evidence: .fileSystemAllocated,
            isProtected: true
        )
    }

    let presented = StorageResourceTreeProjection.presentationNodes([
        cachedRepository("alpha", path: alpha.path),
        cachedRepository("beta", path: beta.path)
    ])
    let parent = try #require(presented.first)

    #expect(parent.title == "code")
    #expect(parent.children.map(\.title) == ["alpha", "beta"])
    #expect(parent.children.allSatisfy { node in
        if case .trashRepository = node.cleanupTarget { return true }
        return false
    })
}

@Test func storageResourceTreeMigratesRepositoriesInsideCachedWorkspaceNode() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "FindDiskKiller-NestedWorkspaceProjection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let code = root.appending(path: "code")
    let alpha = code.appending(path: "alpha")
    let beta = code.appending(path: "beta")
    try FileManager.default.createDirectory(
        at: alpha.appending(path: ".git"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: beta.appending(path: ".git"),
        withIntermediateDirectories: true
    )

    func cachedRepository(_ name: String, path: String) -> StorageResourceNode {
        StorageResourceNode(
            id: "workspace.repository.nested.\(name)",
            kind: .repository,
            title: name,
            detail: "主仓库 · main · \(path)",
            symbol: "folder.badge.gearshape",
            allocatedBytes: 1,
            risk: .protectedUserData,
            evidence: .fileSystemAllocated,
            isProtected: true
        )
    }

    let workspace = StorageResourceNode(
        id: "workspace.cached-root",
        kind: .location,
        title: "Git Workspaces",
        symbol: "folder.badge.gearshape",
        allocatedBytes: 2,
        risk: .environmentOrRuntime,
        evidence: .fileSystemAllocated,
        isProtected: true,
        children: [
            cachedRepository("alpha", path: alpha.path),
            cachedRepository("beta", path: beta.path)
        ]
    )

    let presented = try #require(
        StorageResourceTreeProjection.presentationNodes([workspace]).first
    )
    let parent = try #require(presented.children.first)

    #expect(parent.title == "code")
    #expect(parent.children.map(\.title) == ["alpha", "beta"])
}

@Test func storageResourceTreeIndexResolvesSelectionWithoutRescanningSubtrees() throws {
    let identity = StoragePathIdentity(device: 1, inode: 2)
    let safeLeaf = StorageResourceNode(
        id: "safe-leaf",
        kind: .location,
        title: "Safe leaf",
        symbol: "shippingbox",
        allocatedBytes: 4_096,
        risk: .rebuildableCache,
        evidence: .fileSystemAllocated,
        isProtected: false,
        cleanupTarget: .removePathContents(
            path: "/tmp/safe-leaf",
            identity: identity,
            sourceID: .go,
            rootID: "safe-leaf"
        )
    )
    let manualLeaf = StorageResourceNode(
        id: "manual-leaf",
        kind: .dockerVolume,
        title: "Manual leaf",
        symbol: "externaldrive",
        allocatedBytes: 8_192,
        risk: .protectedUserData,
        evidence: .providerReported,
        isProtected: true,
        cleanupTarget: .dockerVolume(name: "manual")
    )
    let root = StorageResourceNode(
        id: "root",
        kind: .category,
        title: "Root",
        symbol: "folder",
        allocatedBytes: 12_288,
        risk: .environmentOrRuntime,
        evidence: .fileSystemAllocated,
        isProtected: true,
        children: [safeLeaf, manualLeaf]
    )

    let index = StorageResourceTreeIndex(nodes: [root])

    #expect(index.cleanupRequestIDsByNodeID["root"] == ["safe-leaf", "manual-leaf"])
    #expect(index.safeRequestIDs == ["safe-leaf"])
    #expect(index.defaultExpandedIDs == ["root"])
    #expect(index.selectionCounts(for: ["safe-leaf"]) == ["root": 1, "safe-leaf": 1])
    #expect(index.selectedRequests(for: ["manual-leaf"]).map(\.id) == ["manual-leaf"])
}

@Test func safeCleanupIndexCachesScopeAndRequestLookups() {
    let index = StorageSafeCleanupIndex(snapshot: storageSafeCleanupSnapshot())

    #expect(index.groups.map(\.id) == [.go, .npm])
    #expect(index.groups(for: .developerTools).map(\.id) == [.go, .npm])
    #expect(index.requestIDs(for: .developerTools) == ["go.build", "go.module", "npm.cache"])
    #expect(index.requestIDsByGroup[.go] == ["go.build", "go.module"])
    #expect(index.selectedBytes(for: ["go.build", "npm.cache"]) == 10_240)
    #expect(index.selectedEntries(for: ["npm.cache"]).map(\.0) == [.npm])
}

@Test func storageMapInteractionHandlersYieldBeforeDerivedContentWork() throws {
    let storageMapSource = try storageMapViewSource()
    let testsURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testsURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let treeSource = try String(
        contentsOf: repositoryRoot
            .appendingPathComponent("Sources/FindDiskKillerApp/Views/StorageResourceTreeView.swift"),
        encoding: .utf8
    )

    #expect(storageMapSource.contains("isOpening = true"))
    #expect(storageMapSource.contains("await Task.yield()"))
    #expect(storageMapSource.contains("renderedScope = newScope"))
    #expect(storageMapSource.contains("StorageResourceTreeIndex(nodes: nodes)"))
    #expect(storageMapSource.contains("StorageSafeCleanupIndex(snapshot: snapshot)"))
    #expect(treeSource.contains("cleanupRequestIDsByNodeID[row.node.id]"))
    #expect(treeSource.contains("rowUpdateTask = Task"))
    #expect(!treeSource.contains("cleanupRequests(in: row.node)"))
}

@Test func safeCleanupProjectionGroupsBySourceAndSortsByVerifiedBytes() {
    let snapshot = storageSafeCleanupSnapshot()

    let groups = StorageSafeCleanupProjection.groups(in: snapshot)

    #expect(groups.map(\.id) == [.go, .npm])
    #expect(groups.map(\.family) == [.developerTools, .developerTools])
    #expect(groups[0].requests.map(\.id) == ["go.build", "go.module"])
    #expect(groups[0].totalBytes == 12_288)
    #expect(groups[1].totalBytes == 2_048)
    #expect(StorageSafeCleanupProjection.totalBytes(in: groups) == 14_336)
}

@Test func safeCleanupProjectionDoesNotUseCandidateBytesWithoutExecutableTargets() {
    let descriptor = StorageSourceDescriptor(
        id: .chrome,
        title: "Chrome",
        family: .applications,
        symbol: "globe",
        cleanupCapability: .analysisOnly
    )
    let result = StorageSourceResult(
        descriptor: descriptor,
        availability: .available,
        allocatedBytes: 32_768,
        logicalBytes: 32_768,
        entryCount: 1,
        reclaimableCandidateBytes: 32_768,
        components: [],
        resourceTree: []
    )
    let snapshot = StorageAnalysisSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        results: [result],
        totalAllocatedBytes: result.allocatedBytes,
        conflictBytes: 0,
        measuredEntryCount: 1,
        skippedEntryCount: 0
    )

    #expect(StorageSafeCleanupProjection.groups(in: snapshot).isEmpty)
}

@Test func safeCleanupExecutesSelectionWithoutAConfirmationLayer() throws {
    let source = try storageMapViewSource()
    let safeCleanupView = try #require(
        source.split(separator: "private struct StorageSafeCleanupView", maxSplits: 1).last?
            .split(separator: "private struct StorageMapSummaryBand", maxSplits: 1).first
    )

    #expect(safeCleanupView.contains("Button(action: executeSelected)"))
    #expect(safeCleanupView.contains("StorageResourceCleanupExecutor()"))
    #expect(safeCleanupView.contains("accessibilityIdentifier(\"storage-safe-cleanup-execute\")"))
    #expect(!safeCleanupView.contains(".sheet"))
    #expect(!safeCleanupView.contains(".alert"))
    #expect(!safeCleanupView.contains("confirmationDialog"))
}

@Test func storageMapKeepsSafeCleanupAndAgentDetailsAsInPageRoutes() throws {
    let source = try storageMapViewSource()
    let rootView = try #require(
        source.split(separator: "struct StorageMapView: View", maxSplits: 1).last?
            .split(separator: "private struct StorageMapFirstRunView", maxSplits: 1).first
    )

    #expect(rootView.contains("case .safeCleanup:"))
    #expect(rootView.contains("route = .safeCleanup"))
    #expect(rootView.contains("storage-map-safe-cleanup-scope"))
    #expect(rootView.contains("case .agentAnalysis(let provider):"))
    #expect(rootView.contains("AgentStorageView("))
    #expect(!rootView.contains("StorageSafeCleanupSheet"))
    #expect(!rootView.contains("StorageSafeCleanupSidebar"))
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

private actor StorageMapCleanupRefreshProbe {
    private let initial: StorageAnalysisSnapshot
    private let replacement: StorageAnalysisSnapshot
    private(set) var fullScanCount = 0
    private(set) var sourceIDs: [StorageSourceID] = []
    var sourceScanCount: Int { sourceIDs.count }

    init(initial: StorageAnalysisSnapshot, replacement: StorageAnalysisSnapshot) {
        self.initial = initial
        self.replacement = replacement
    }

    func fullScan(
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        fullScanCount += 1
        progress(.init(phase: .measuring, sourceID: .npm))
        if fullScanCount > 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return initial
    }

    func sourceScan(
        sourceID: StorageSourceID,
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        sourceIDs.append(sourceID)
        progress(.init(phase: .measuring, sourceID: sourceID))
        return replacement
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

private func storageSafeCleanupSnapshot() -> StorageAnalysisSnapshot {
    let identity = StoragePathIdentity(device: 1, inode: 2)
    func safeNode(
        id: String,
        title: String,
        bytes: UInt64,
        sourceID: StorageSourceID
    ) -> StorageResourceNode {
        StorageResourceNode(
            id: id,
            kind: .location,
            title: title,
            symbol: "shippingbox",
            allocatedBytes: bytes,
            risk: .rebuildableCache,
            evidence: .fileSystemAllocated,
            isProtected: false,
            cleanupTarget: .removePathContents(
                path: "/tmp/\(id)",
                identity: identity,
                sourceID: sourceID,
                rootID: id
            )
        )
    }
    func result(
        id: StorageSourceID,
        title: String,
        nodes: [StorageResourceNode]
    ) -> StorageSourceResult {
        let bytes = nodes.reduce(UInt64.zero) { $0 + $1.allocatedBytes }
        return StorageSourceResult(
            descriptor: StorageSourceDescriptor(
                id: id,
                title: title,
                family: .developerTools,
                symbol: "shippingbox",
                cleanupCapability: .analysisOnly
            ),
            availability: .available,
            allocatedBytes: bytes,
            logicalBytes: bytes,
            entryCount: nodes.count,
            reclaimableCandidateBytes: bytes,
            components: [],
            resourceTree: nodes
        )
    }

    let go = result(
        id: .go,
        title: "Go",
        nodes: [
            safeNode(id: "go.module", title: "Module cache", bytes: 4_096, sourceID: .go),
            safeNode(id: "go.build", title: "Build cache", bytes: 8_192, sourceID: .go)
        ]
    )
    let npm = result(
        id: .npm,
        title: "npm",
        nodes: [safeNode(id: "npm.cache", title: "Cache", bytes: 2_048, sourceID: .npm)]
    )
    return StorageAnalysisSnapshot(
        scannedAt: Date(timeIntervalSince1970: 1_000),
        results: [npm, go],
        totalAllocatedBytes: npm.allocatedBytes + go.allocatedBytes,
        conflictBytes: 0,
        measuredEntryCount: 3,
        skippedEntryCount: 0
    )
}

private enum CleanupLifecycleTestError: LocalizedError {
    case syncFailed

    var errorDescription: String? { "同步失败" }
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

private actor DockerCleanupCommandRecorder {
    private(set) var commands: [[String]] = []
    private let referenceOutput: String
    private let inspectOutput: String

    init(referenceOutput: String, inspectOutput: String = "[]") {
        self.referenceOutput = referenceOutput
        self.inspectOutput = inspectOutput
    }

    func run(_ arguments: [String]) -> String {
        commands.append(arguments)
        if arguments.starts(with: ["container", "ls"]) { return referenceOutput }
        if arguments.starts(with: ["image", "inspect"]) { return inspectOutput }
        return ""
    }
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
