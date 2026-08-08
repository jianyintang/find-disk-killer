import Foundation
import FindDiskKillerCore
import Observation

@MainActor
@Observable
final class StorageMapModel {
    enum Phase: Equatable {
        case idle
        case detecting
        case ready
        case scanning
        case stopping
        case failed
    }

    typealias DetectOperation = @Sendable () async -> [StorageSourceCandidate]
    typealias ProgressiveDetectOperation = @Sendable (
        @escaping @Sendable (StorageSourceCandidate) -> Void
    ) async -> [StorageSourceCandidate]
    typealias ScanOperation = @Sendable (
        @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot
    typealias SourceScanOperation = @Sendable (
        StorageSourceID,
        @escaping @Sendable (StorageScanProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot
    typealias RepositoryAccessCheck = @Sendable () -> Bool

    private(set) var phase: Phase = .idle
    private(set) var candidates: [StorageSourceCandidate] = []
    private(set) var snapshot: StorageAnalysisSnapshot?
    private(set) var progress: StorageScanProgress?
    private(set) var progressBySource: [StorageSourceID: StorageScanProgress] = [:]
    private(set) var reanalyzingSourceIDs: Set<StorageSourceID> = []
    private(set) var refreshErrorsBySource: [StorageSourceID: String] = [:]
    private(set) var resultRevisionsBySource: [StorageSourceID: UInt64] = [:]
    private(set) var errorMessage: String?
    private(set) var hasFullDiskRepositoryAccess: Bool

    @ObservationIgnored private let detectOperation: DetectOperation
    @ObservationIgnored private let progressiveDetectOperation: ProgressiveDetectOperation?
    @ObservationIgnored private let scanOperation: ScanOperation
    @ObservationIgnored private let sourceScanOperation: SourceScanOperation
    @ObservationIgnored private let cacheURL: URL?
    @ObservationIgnored private let repositoryAccessCheck: RepositoryAccessCheck
    @ObservationIgnored private let discoveryPresentationInterval: Duration
    @ObservationIgnored private let snapshotCacheWriter = SnapshotCacheWriter<StorageAnalysisSnapshot>()
    @ObservationIgnored private var cacheRevision: UInt64 = 0
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var sourceScanTasks: [StorageSourceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sourceGenerations: [StorageSourceID: UInt64] = [:]
    @ObservationIgnored private var pendingSourceRefreshIDs = Set<StorageSourceID>()
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored nonisolated(unsafe) private var locationChangeObserver: NSObjectProtocol?

    convenience init(
        locationRepository: AgentDataLocationRepository = .shared,
        cacheURL: URL? = StorageMapModel.defaultCacheURL
    ) {
        let repositoryAccessCheck: RepositoryAccessCheck = {
            RepositoryAccessAuthorization.hasFullDiskAccess()
        }
        self.init(
            cacheURL: cacheURL,
            detect: {
                await StorageAnalyzer(configuration: .init(
                    agentDataLocations: locationRepository.locations(),
                    includesPrivacyProtectedRepositoryLocations: repositoryAccessCheck(),
                    discoversCodeRepositories: false
                )).detect()
            },
            progressiveDetect: { progress in
                await StorageAnalyzer(configuration: .init(
                    agentDataLocations: locationRepository.locations(),
                    includesPrivacyProtectedRepositoryLocations: repositoryAccessCheck(),
                    discoversCodeRepositories: false
                )).detect(progress: progress)
            },
            scan: { progress in
                try await StorageAnalyzer(configuration: .init(
                    agentDataLocations: locationRepository.locations(),
                    includesPrivacyProtectedRepositoryLocations: repositoryAccessCheck(),
                    discoversCodeRepositories: false
                )).scan(progress: progress)
            },
            scanSource: { sourceID, progress in
                try await StorageAnalyzer(configuration: .init(
                    agentDataLocations: locationRepository.locations(),
                    includesPrivacyProtectedRepositoryLocations: repositoryAccessCheck(),
                    discoversCodeRepositories: sourceID == .workspace
                )).scan(sourceID: sourceID, progress: progress)
            },
            locationRepository: locationRepository,
            repositoryAccessCheck: repositoryAccessCheck,
            discoveryPresentationInterval: .milliseconds(240)
        )
    }

    init(
        cacheURL: URL?,
        detect: @escaping DetectOperation,
        progressiveDetect: ProgressiveDetectOperation? = nil,
        scan: @escaping ScanOperation,
        scanSource: SourceScanOperation? = nil,
        locationRepository: AgentDataLocationRepository? = nil,
        repositoryAccessCheck: @escaping RepositoryAccessCheck = { false },
        discoveryPresentationInterval: Duration = .zero
    ) {
        self.cacheURL = cacheURL
        detectOperation = detect
        progressiveDetectOperation = progressiveDetect
        scanOperation = scan
        sourceScanOperation = scanSource ?? { _, progress in
            try await scan(progress)
        }
        self.repositoryAccessCheck = repositoryAccessCheck
        self.discoveryPresentationInterval = discoveryPresentationInterval
        hasFullDiskRepositoryAccess = repositoryAccessCheck()
        if let locationRepository {
            locationChangeObserver = NotificationCenter.default.addObserver(
                forName: .agentDataLocationsDidChange,
                object: locationRepository,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.agentDataLocationsChanged()
                }
            }
        }
    }

    deinit {
        if let locationChangeObserver {
            NotificationCenter.default.removeObserver(locationChangeObserver)
        }
    }

    var isWorking: Bool {
        phase == .detecting || phase == .scanning || phase == .stopping
    }

    var hasPreviousResults: Bool {
        snapshot != nil
    }

    var latestDetectedCandidate: StorageSourceCandidate? {
        candidates.last
    }

    var isPresentingLiveResults: Bool {
        if let progress = activeFullProgress,
           Self.hasMeasuredData(progress, sourceSpecific: false) {
            return true
        }
        return reanalyzingSourceIDs.contains { sourceID in
            guard let progress = progressBySource[sourceID] else { return false }
            return Self.hasMeasuredData(progress, sourceSpecific: true)
        }
    }

    var presentationTotalAllocatedBytes: UInt64? {
        if let progress = activeFullProgress,
           Self.hasMeasuredData(progress, sourceSpecific: false) {
            return progress.processedBytes
        }
        guard let snapshot else { return nil }
        return reanalyzingSourceIDs.reduce(snapshot.totalAllocatedBytes) { total, sourceID in
            guard let progress = progressBySource[sourceID],
                  Self.hasMeasuredData(progress, sourceSpecific: true) else { return total }
            let previousBytes = snapshot.result(for: sourceID)?.allocatedBytes ?? 0
            return Self.addingClamped(
                total >= previousBytes ? total - previousBytes : 0,
                progress.sourceProcessedBytes
            )
        }
    }

    var presentationEntryCount: Int? {
        if let progress = activeFullProgress,
           Self.hasMeasuredData(progress, sourceSpecific: false) {
            return progress.processedEntryCount
        }
        guard let snapshot else { return nil }
        return reanalyzingSourceIDs.reduce(snapshot.measuredEntryCount) { total, sourceID in
            guard let progress = progressBySource[sourceID],
                  Self.hasMeasuredData(progress, sourceSpecific: true) else { return total }
            let previousCount = snapshot.result(for: sourceID)?.entryCount ?? 0
            return max(0, total - previousCount) + progress.sourceProcessedEntryCount
        }
    }

    var presentationVolumes: [StorageVolumeSnapshot] {
        if let progress = activeFullProgress,
           !progress.volumes.isEmpty,
           snapshot == nil || Self.hasMeasuredData(progress, sourceSpecific: false) {
            return progress.volumes
        }
        var volumes = snapshot?.volumes ?? []
        for sourceID in reanalyzingSourceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let progress = progressBySource[sourceID],
                  !progress.volumes.isEmpty,
                  Self.hasMeasuredData(progress, sourceSpecific: true) else { continue }
            volumes = Self.replacingSourceUsage(
                in: volumes,
                with: progress.volumes,
                sourceID: sourceID,
                preserveUnmeasuredVolumes: !progress.sourceCompleted
            )
        }
        return volumes
    }

    func presentationAllocatedBytes(for sourceID: StorageSourceID) -> UInt64? {
        if (phase == .scanning || phase == .stopping),
           let progress = progressBySource[sourceID],
           Self.hasMeasuredData(progress, sourceSpecific: true) {
            return progress.sourceProcessedBytes
        }
        if reanalyzingSourceIDs.contains(sourceID),
           let progress = progressBySource[sourceID],
           Self.hasMeasuredData(progress, sourceSpecific: true) {
            return progress.sourceProcessedBytes
        }
        return snapshot?.result(for: sourceID)?.allocatedBytes
    }

    private var activeFullProgress: StorageScanProgress? {
        guard phase == .scanning || phase == .stopping else { return nil }
        return progress
    }

    func isAnalyzingSource(_ sourceID: StorageSourceID) -> Bool {
        if reanalyzingSourceIDs.contains(sourceID) { return true }
        guard phase == .scanning || phase == .stopping else { return false }
        return candidates.contains { $0.id == sourceID && !$0.roots.isEmpty }
    }

    func resultRevision(for sourceID: StorageSourceID) -> UInt64 {
        resultRevisionsBySource[sourceID, default: 0]
    }

    func prepare() async {
        if let preparationTask {
            await preparationTask.value
            return
        }
        if phase == .detecting {
            // A detecting phase without its owning task is incomplete and must be recoverable.
            phase = .idle
        }
        guard phase == .idle else { return }
        phase = .detecting
        errorMessage = nil

        let requestedGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPreparation(generation: requestedGeneration)
        }
        preparationTask = task
        await task.value
    }

    private func performPreparation(generation requestedGeneration: UInt64) async {
        async let cached = Self.loadSnapshot(from: cacheURL)
        let newCandidates: [StorageSourceCandidate]
        if let progressiveDetectOperation {
            newCandidates = await presentProgressiveDetection(
                progressiveDetectOperation,
                generation: requestedGeneration
            )
        } else {
            newCandidates = await detectOperation()
        }
        let cachedSnapshot = await cached
        guard !Task.isCancelled, requestedGeneration == generation else {
            finishPreparation(generation: requestedGeneration)
            return
        }

        candidates = newCandidates
        if snapshot == nil {
            publishSnapshot(
                cachedSnapshot,
                updatedSourceIDs: Set(cachedSnapshot?.results.map(\.id) ?? [])
            )
        }
        phase = .ready
        finishPreparation(generation: requestedGeneration)
    }

    private func finishPreparation(generation requestedGeneration: UInt64) {
        guard requestedGeneration == generation else { return }
        preparationTask = nil
    }

    private func acceptDetectedCandidate(
        _ candidate: StorageSourceCandidate,
        generation: UInt64
    ) {
        guard generation == self.generation, phase == .detecting else { return }
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
    }

    private func presentProgressiveDetection(
        _ operation: @escaping ProgressiveDetectOperation,
        generation: UInt64
    ) async -> [StorageSourceCandidate] {
        let (events, continuation) = AsyncStream<StorageSourceCandidate>.makeStream()
        let detection = Task.detached(priority: .userInitiated) {
            let detected = await operation { candidate in
                continuation.yield(candidate)
            }
            continuation.finish()
            return detected
        }

        var hasPresentedCandidate = false
        for await candidate in events {
            guard !Task.isCancelled,
                  generation == self.generation,
                  phase == .detecting else {
                detection.cancel()
                break
            }
            if hasPresentedCandidate, discoveryPresentationInterval > .zero {
                do {
                    try await Task.sleep(for: discoveryPresentationInterval)
                } catch {
                    detection.cancel()
                    break
                }
            }
            guard !Task.isCancelled,
                  generation == self.generation,
                  phase == .detecting else {
                detection.cancel()
                break
            }
            acceptDetectedCandidate(candidate, generation: generation)
            hasPresentedCandidate = true
        }
        return await detection.value
    }

    func startAnalysis() {
        cancelSourceAnalyses()
        generation &+= 1
        let requestedGeneration = generation
        scanTask?.cancel()
        phase = .scanning
        progress = StorageScanProgress(
            phase: .discovering,
            totalSourceCount: candidates.filter { !$0.roots.isEmpty }.count
        )
        progressBySource = [:]
        refreshErrorsBySource = [:]
        errorMessage = nil

        let scanOperation = self.scanOperation
        scanTask = Task { [weak self] in
            guard let self else { return }
            let progressTarget = self
            do {
                let newSnapshot = try await scanOperation { update in
                    Task { @MainActor in
                        progressTarget.accept(update, generation: requestedGeneration)
                    }
                }
                guard !Task.isCancelled,
                      requestedGeneration == self.generation else { return }
                let committedSnapshot = Self.preservingDeferredWorkspace(
                    previous: self.snapshot,
                    replacement: newSnapshot,
                    candidates: self.candidates
                )
                self.publishSnapshot(
                    committedSnapshot,
                    updatedSourceIDs: Set(newSnapshot.results.map(\.id))
                )
                self.phase = .ready
                self.progress = nil
                self.progressBySource = [:]
                self.scanTask = nil
                await self.persistSnapshot(committedSnapshot)
                self.drainPendingSourceRefreshes()
            } catch is CancellationError {
                guard requestedGeneration == self.generation else { return }
                self.phase = .ready
                self.progress = nil
                self.progressBySource = [:]
                self.scanTask = nil
                self.drainPendingSourceRefreshes()
            } catch {
                guard requestedGeneration == self.generation else { return }
                self.phase = .failed
                self.progress = nil
                self.progressBySource = [:]
                self.errorMessage = L10n.errorDescription(error)
                self.scanTask = nil
                self.drainPendingSourceRefreshes()
            }
        }
    }

    func startAnalysis(sourceID: StorageSourceID) {
        guard phase != .scanning,
              phase != .stopping,
              (snapshot?.result(for: sourceID) != nil || sourceID == .workspace),
              candidates.contains(where: { $0.id == sourceID }),
              !reanalyzingSourceIDs.contains(sourceID) else { return }
        let requestedGeneration = sourceGenerations[sourceID, default: 0] &+ 1
        sourceGenerations[sourceID] = requestedGeneration
        reanalyzingSourceIDs.insert(sourceID)
        refreshErrorsBySource.removeValue(forKey: sourceID)
        progressBySource[sourceID] = StorageScanProgress(
            phase: .discovering,
            sourceID: sourceID,
            totalSourceCount: 1
        )
        let sourceScanOperation = sourceScanOperation
        sourceScanTasks[sourceID] = Task { [weak self] in
            guard let self else { return }
            do {
                let partial = try await sourceScanOperation(sourceID) { update in
                    Task { @MainActor [weak self] in
                        self?.acceptSourceUpdate(
                            update,
                            sourceID: sourceID,
                            generation: requestedGeneration
                        )
                    }
                }
                guard !Task.isCancelled,
                      self.sourceGenerations[sourceID] == requestedGeneration else { return }
                let committedSnapshot = Self.merging(
                    previous: self.snapshot,
                    partial: partial,
                    sourceID: sourceID
                )
                self.publishSnapshot(committedSnapshot, updatedSourceIDs: [sourceID])
                self.reanalyzingSourceIDs.remove(sourceID)
                self.refreshErrorsBySource.removeValue(forKey: sourceID)
                self.progressBySource.removeValue(forKey: sourceID)
                self.sourceScanTasks.removeValue(forKey: sourceID)
                if let snapshot = self.snapshot {
                    await self.persistSnapshot(snapshot)
                }
            } catch is CancellationError {
                self.finishSourceAnalysis(sourceID, generation: requestedGeneration)
            } catch {
                self.finishSourceAnalysis(sourceID, generation: requestedGeneration)
                let message = L10n.errorDescription(error)
                self.errorMessage = message
                self.refreshErrorsBySource[sourceID] = message
            }
        }
    }

    func refreshAfterCleanup(sourceID: StorageSourceID) {
        sourceScanTasks[sourceID]?.cancel()
        sourceScanTasks.removeValue(forKey: sourceID)
        sourceGenerations[sourceID, default: 0] &+= 1
        reanalyzingSourceIDs.remove(sourceID)
        progressBySource.removeValue(forKey: sourceID)
        refreshErrorsBySource.removeValue(forKey: sourceID)
        pendingSourceRefreshIDs.insert(sourceID)
        errorMessage = nil
        drainPendingSourceRefreshes()
    }

    func startAnalysis(including agentStorage: AgentStorageModel) {
        if phase != .scanning, phase != .stopping {
            startAnalysis()
        }
        guard candidates.contains(where: { $0.id.agentStorageProvider != nil }) else {
            return
        }
        if !agentStorage.isScanning {
            agentStorage.startAnalysis()
        }
    }

    func stopAnalysis() {
        guard phase == .scanning else { return }
        generation &+= 1
        let stoppingGeneration = generation
        phase = .stopping
        scanTask?.cancel()
        scanTask = nil

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, self.generation == stoppingGeneration else { return }
            self.phase = .ready
            self.progress = nil
            self.progressBySource = [:]
            self.drainPendingSourceRefreshes()
        }
    }

    func stopAnalysis(including agentStorage: AgentStorageModel) {
        stopAnalysis()
        if agentStorage.isScanning {
            agentStorage.stop()
        }
    }

    func isFullAnalysisRunning(including agentStorage: AgentStorageModel) -> Bool {
        phase == .scanning || phase == .stopping || agentStorage.isScanning
    }

    func retryDetection() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        candidates = []
        pendingSourceRefreshIDs = []
        refreshErrorsBySource = [:]
        errorMessage = nil
        Task { [weak self] in
            await self?.prepare()
        }
    }

    @discardableResult
    func refreshRepositoryAuthorization() -> Bool {
        let isGranted = repositoryAccessCheck()
        guard isGranted != hasFullDiskRepositoryAccess else {
            return hasFullDiskRepositoryAccess
        }
        hasFullDiskRepositoryAccess = isGranted
        if isGranted { restartWorkspaceAnalysis() }
        return hasFullDiskRepositoryAccess
    }

    private func restartWorkspaceAnalysis() {
        let sourceID = StorageSourceID.workspace
        sourceScanTasks[sourceID]?.cancel()
        sourceScanTasks.removeValue(forKey: sourceID)
        sourceGenerations[sourceID, default: 0] &+= 1
        reanalyzingSourceIDs.remove(sourceID)
        progressBySource.removeValue(forKey: sourceID)
        startAnalysis(sourceID: sourceID)
    }

    private func agentDataLocationsChanged() {
        cancelSourceAnalyses()
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        scanTask?.cancel()
        scanTask = nil
        publishSnapshot(nil, updatedSourceIDs: Set(snapshot?.results.map(\.id) ?? []))
        progress = nil
        progressBySource = [:]
        pendingSourceRefreshIDs = []
        refreshErrorsBySource = [:]
        candidates = []
        phase = .idle
        cacheRevision &+= 1
        let revision = cacheRevision
        let cacheWriter = snapshotCacheWriter
        let cacheURL = cacheURL
        Task {
            await cacheWriter.remove(at: cacheURL, revision: revision)
            await prepare()
        }
    }

    func prepareForSleep() {
        cancelSourceAnalyses()
        stopAnalysis()
    }

    func prepareForTermination() {
        cancelSourceAnalyses()
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        scanTask?.cancel()
        scanTask = nil
        progress = nil
        progressBySource = [:]
        pendingSourceRefreshIDs = []
        if phase == .detecting {
            phase = .idle
        } else if phase == .scanning || phase == .stopping {
            phase = .ready
        }
    }

    private func acceptSourceUpdate(
        _ update: StorageScanProgress,
        sourceID: StorageSourceID,
        generation: UInt64
    ) {
        guard sourceGenerations[sourceID] == generation,
              reanalyzingSourceIDs.contains(sourceID) else { return }
        let current = progressBySource[sourceID]
        if current == nil
            || Self.progressPhaseOrder(update.phase) > Self.progressPhaseOrder(current!.phase)
            || (update.phase == current!.phase
                && update.sourceProcessedEntryCount >= current!.sourceProcessedEntryCount
                && update.sourceProcessedBytes >= current!.sourceProcessedBytes) {
            progressBySource[sourceID] = update
        }
    }

    private func finishSourceAnalysis(_ sourceID: StorageSourceID, generation: UInt64) {
        guard sourceGenerations[sourceID] == generation else { return }
        reanalyzingSourceIDs.remove(sourceID)
        progressBySource.removeValue(forKey: sourceID)
        sourceScanTasks.removeValue(forKey: sourceID)
    }

    private func cancelSourceAnalyses() {
        for task in sourceScanTasks.values { task.cancel() }
        sourceScanTasks = [:]
        reanalyzingSourceIDs = []
        sourceGenerations = sourceGenerations.mapValues { $0 &+ 1 }
    }

    private func drainPendingSourceRefreshes() {
        guard phase != .scanning, phase != .stopping,
              !pendingSourceRefreshIDs.isEmpty else { return }
        let sourceIDs = pendingSourceRefreshIDs
        pendingSourceRefreshIDs = []
        for sourceID in sourceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            startAnalysis(sourceID: sourceID)
        }
    }

    private func publishSnapshot(
        _ newSnapshot: StorageAnalysisSnapshot?,
        updatedSourceIDs: Set<StorageSourceID>
    ) {
        snapshot = newSnapshot
        for sourceID in updatedSourceIDs {
            resultRevisionsBySource[sourceID, default: 0] &+= 1
        }
    }

    private static func merging(
        previous: StorageAnalysisSnapshot?,
        partial: StorageAnalysisSnapshot,
        sourceID: StorageSourceID
    ) -> StorageAnalysisSnapshot {
        guard let previous else { return partial }
        let replacement = partial.result(for: sourceID)
        var results = previous.results.filter { $0.id != sourceID }
        if let replacement { results.append(replacement) }
        results.sort { $0.descriptor.title.localizedStandardCompare($1.descriptor.title) == .orderedAscending }

        let previousVolumes = Dictionary(uniqueKeysWithValues: previous.volumes.map { ($0.id, $0) })
        let partialVolumes = Dictionary(uniqueKeysWithValues: partial.volumes.map { ($0.id, $0) })
        let volumeIDs = Set(previousVolumes.keys).union(partialVolumes.keys)
        let volumes = volumeIDs.compactMap { volumeID -> StorageVolumeSnapshot? in
            guard let base = partialVolumes[volumeID] ?? previousVolumes[volumeID] else { return nil }
            let oldUsages = previousVolumes[volumeID]?.sourceUsages.filter { $0.sourceID != sourceID } ?? []
            let replacementUsage = partialVolumes[volumeID]?.sourceUsages.first { $0.sourceID == sourceID }
            return StorageVolumeSnapshot(
                id: base.id,
                name: base.name,
                mountPath: base.mountPath,
                totalCapacity: base.totalCapacity,
                availableCapacity: base.availableCapacity,
                sourceUsages: (oldUsages + [replacementUsage].compactMap { $0 }).sorted {
                    $0.allocatedBytes > $1.allocatedBytes
                }
            )
        }
        .sorted {
            if $0.mountPath == "/" { return true }
            if $1.mountPath == "/" { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let total = results.reduce(previous.conflictBytes) {
            Self.addingClamped($0, $1.allocatedBytes)
        }
        return StorageAnalysisSnapshot(
            scannedAt: partial.scannedAt,
            results: results,
            totalAllocatedBytes: total,
            conflictBytes: previous.conflictBytes,
            measuredEntryCount: results.reduce(0) { $0 + $1.entryCount },
            skippedEntryCount: results.reduce(0) { $0 + $1.skippedEntryCount },
            volumes: volumes
        )
    }

    private static func preservingDeferredWorkspace(
        previous: StorageAnalysisSnapshot?,
        replacement: StorageAnalysisSnapshot,
        candidates: [StorageSourceCandidate]
    ) -> StorageAnalysisSnapshot {
        guard candidates.contains(where: { $0.id == .workspace && $0.roots.isEmpty }),
              replacement.result(for: .workspace) == nil,
              let previous,
              let workspaceResult = previous.result(for: .workspace) else {
            return replacement
        }
        var results = replacement.results + [workspaceResult]
        results.sort {
            $0.descriptor.title.localizedStandardCompare($1.descriptor.title) == .orderedAscending
        }
        let previousVolumes = Dictionary(uniqueKeysWithValues: previous.volumes.map { ($0.id, $0) })
        let replacementVolumes = Dictionary(uniqueKeysWithValues: replacement.volumes.map { ($0.id, $0) })
        let volumes: [StorageVolumeSnapshot] = Set(previousVolumes.keys)
            .union(replacementVolumes.keys)
            .compactMap { volumeID -> StorageVolumeSnapshot? in
                guard let base = replacementVolumes[volumeID]
                    ?? previousVolumes[volumeID] else { return nil }
                var usages = replacementVolumes[volumeID]?.sourceUsages ?? []
                if let workspaceUsage = previousVolumes[volumeID]?.sourceUsages.first(where: {
                    $0.sourceID == .workspace
                }) {
                    usages.removeAll { $0.sourceID == .workspace }
                    usages.append(workspaceUsage)
                }
                return StorageVolumeSnapshot(
                    id: base.id,
                    name: base.name,
                    mountPath: base.mountPath,
                    totalCapacity: base.totalCapacity,
                    availableCapacity: base.availableCapacity,
                    sourceUsages: usages.sorted { $0.allocatedBytes > $1.allocatedBytes }
                )
            }
            .sorted {
                if $0.mountPath == "/" { return true }
                if $1.mountPath == "/" { return false }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return StorageAnalysisSnapshot(
            scannedAt: replacement.scannedAt,
            results: results,
            totalAllocatedBytes: results.reduce(replacement.conflictBytes) {
                addingClamped($0, $1.allocatedBytes)
            },
            conflictBytes: replacement.conflictBytes,
            measuredEntryCount: results.reduce(0) { $0 + $1.entryCount },
            skippedEntryCount: results.reduce(0) { $0 + $1.skippedEntryCount },
            volumes: volumes
        )
    }

    nonisolated private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private func accept(_ update: StorageScanProgress, generation: UInt64) {
        guard generation == self.generation, phase == .scanning else { return }
        if let sourceID = update.sourceID {
            let currentSource = progressBySource[sourceID]
            if currentSource == nil
                || Self.progressPhaseOrder(update.phase) > Self.progressPhaseOrder(currentSource!.phase)
                || (update.phase == currentSource!.phase
                    && update.sourceProcessedEntryCount >= currentSource!.sourceProcessedEntryCount
                    && update.sourceProcessedBytes >= currentSource!.sourceProcessedBytes) {
                progressBySource[sourceID] = update
            }
        }
        guard let current = progress else {
            progress = update
            return
        }
        let currentPhase = Self.progressPhaseOrder(current.phase)
        let updatePhase = Self.progressPhaseOrder(update.phase)
        guard updatePhase >= currentPhase else { return }
        progress = StorageScanProgress(
            phase: update.phase,
            sourceID: update.sourceID ?? current.sourceID,
            completedSourceCount: max(
                current.completedSourceCount,
                update.completedSourceCount
            ),
            totalSourceCount: max(current.totalSourceCount, update.totalSourceCount),
            processedEntryCount: max(
                current.processedEntryCount,
                update.processedEntryCount
            ),
            processedBytes: max(current.processedBytes, update.processedBytes),
            volumes: update.volumes.isEmpty
                ? current.volumes
                : Self.mergingProgressVolumes(current.volumes, update.volumes)
        )
    }

    nonisolated private static func hasMeasuredData(
        _ progress: StorageScanProgress,
        sourceSpecific: Bool
    ) -> Bool {
        if progress.phase == .reconciling || progress.phase == .finished { return true }
        if sourceSpecific {
            return progress.sourceCompleted
                || progress.sourceProcessedEntryCount > 0
                || progress.sourceProcessedBytes > 0
        }
        return progress.completedSourceCount > 0
            || progress.processedEntryCount > 0
            || progress.processedBytes > 0
    }

    nonisolated private static func replacingSourceUsage(
        in previous: [StorageVolumeSnapshot],
        with live: [StorageVolumeSnapshot],
        sourceID: StorageSourceID,
        preserveUnmeasuredVolumes: Bool
    ) -> [StorageVolumeSnapshot] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        return Set(previousByID.keys).union(liveByID.keys).compactMap { volumeID in
            guard let base = liveByID[volumeID] ?? previousByID[volumeID] else { return nil }
            var usages = previousByID[volumeID]?.sourceUsages.filter {
                $0.sourceID != sourceID
            } ?? []
            let liveUsage = liveByID[volumeID]?.sourceUsages.first {
                $0.sourceID == sourceID
            }
            let previousUsage = previousByID[volumeID]?.sourceUsages.first {
                $0.sourceID == sourceID
            }
            if let replacement = liveUsage ?? (preserveUnmeasuredVolumes ? previousUsage : nil) {
                usages.append(replacement)
            }
            return StorageVolumeSnapshot(
                id: base.id,
                name: base.name,
                mountPath: base.mountPath,
                totalCapacity: base.totalCapacity,
                availableCapacity: base.availableCapacity,
                sourceUsages: usages.sorted(by: Self.usageOrder)
            )
        }
        .sorted(by: Self.volumeOrder)
    }

    nonisolated private static func mergingProgressVolumes(
        _ current: [StorageVolumeSnapshot],
        _ update: [StorageVolumeSnapshot]
    ) -> [StorageVolumeSnapshot] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let updateByID = Dictionary(uniqueKeysWithValues: update.map { ($0.id, $0) })
        return Set(currentByID.keys).union(updateByID.keys).compactMap { volumeID in
            guard let base = updateByID[volumeID] ?? currentByID[volumeID] else { return nil }
            let currentUsages = Dictionary(uniqueKeysWithValues:
                (currentByID[volumeID]?.sourceUsages ?? []).map { ($0.sourceID, $0.allocatedBytes) }
            )
            let updateUsages = Dictionary(uniqueKeysWithValues:
                (updateByID[volumeID]?.sourceUsages ?? []).map { ($0.sourceID, $0.allocatedBytes) }
            )
            let usages = Set(currentUsages.keys).union(updateUsages.keys).map { sourceID in
                StorageVolumeSourceUsage(
                    sourceID: sourceID,
                    allocatedBytes: max(
                        currentUsages[sourceID, default: 0],
                        updateUsages[sourceID, default: 0]
                    )
                )
            }
            return StorageVolumeSnapshot(
                id: base.id,
                name: base.name,
                mountPath: base.mountPath,
                totalCapacity: base.totalCapacity,
                availableCapacity: base.availableCapacity,
                sourceUsages: usages.sorted(by: Self.usageOrder)
            )
        }
        .sorted(by: Self.volumeOrder)
    }

    nonisolated private static func usageOrder(
        _ lhs: StorageVolumeSourceUsage,
        _ rhs: StorageVolumeSourceUsage
    ) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes {
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
        return lhs.sourceID.rawValue < rhs.sourceID.rawValue
    }

    nonisolated private static func volumeOrder(
        _ lhs: StorageVolumeSnapshot,
        _ rhs: StorageVolumeSnapshot
    ) -> Bool {
        if lhs.mountPath == "/" { return true }
        if rhs.mountPath == "/" { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    nonisolated private static func progressPhaseOrder(_ phase: StorageScanPhase) -> Int {
        switch phase {
        case .discovering: 0
        case .measuring: 1
        case .reconciling: 2
        case .finished: 3
        }
    }

    nonisolated private static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "FindDiskKiller", directoryHint: .isDirectory)
            .appending(path: "storage-map-v10.json", directoryHint: .notDirectory)
    }

    nonisolated private static func loadSnapshot(from url: URL?) async -> StorageAnalysisSnapshot? {
        guard let url,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StorageAnalysisSnapshot.self, from: data)
    }

    private func persistSnapshot(_ snapshot: StorageAnalysisSnapshot) async {
        cacheRevision &+= 1
        await snapshotCacheWriter.save(
            snapshot,
            to: cacheURL,
            revision: cacheRevision
        )
    }
}
