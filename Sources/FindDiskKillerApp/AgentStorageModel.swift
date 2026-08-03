import FindDiskKillerCore
import Foundation
import Observation

enum AgentStorageLoadState: Equatable {
    case idle
    case scanning(startedAt: Date)
    case ready
    case stale
    case stopped
    case failed(String)
}

@MainActor
@Observable
final class AgentStorageModel {
    private(set) var snapshot: AgentStorageSnapshot?
    private(set) var snapshotRevision = 0
    private(set) var resultRevisionsByProvider: [AgentStorageProvider: UInt64] = [:]
    private(set) var state: AgentStorageLoadState
    private(set) var progress = AgentStorageScanProgress(phase: .discoveringSources)
    private(set) var progressByProvider: [AgentStorageProvider: AgentStorageScanProgress] = [:]
    private(set) var reanalyzingProviders: Set<AgentStorageProvider> = []
    private(set) var refreshErrorsByProvider: [AgentStorageProvider: String] = [:]
    private(set) var generation = 0
    private(set) var customRootError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locationRepository: AgentDataLocationRepository
    @ObservationIgnored private let cacheURL: URL?
    @ObservationIgnored private let snapshotCacheWriter = SnapshotCacheWriter<AgentStorageSnapshot>()
    @ObservationIgnored private var cacheRevision: UInt64 = 0
    @ObservationIgnored private let scanAction: @Sendable (
        AgentStorageScanner.Configuration,
        @escaping @Sendable (AgentStorageScanProgress) -> Void
    ) async throws -> AgentStorageSnapshot
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var providerScanTasks: [AgentStorageProvider: Task<Void, Never>] = [:]
    @ObservationIgnored private var providerGenerations: [AgentStorageProvider: Int] = [:]
    @ObservationIgnored private var pendingProviderRefreshes = Set<AgentStorageProvider>()
    @ObservationIgnored private var cacheLoadTask: Task<Void, Never>?
    init(
        defaults: UserDefaults = .standard,
        initialSnapshot: AgentStorageSnapshot? = nil,
        cacheURL: URL? = AgentStorageModel.defaultCacheURL,
        locationRepository: AgentDataLocationRepository? = nil,
        scanAction: @escaping @Sendable (
            AgentStorageScanner.Configuration,
            @escaping @Sendable (AgentStorageScanProgress) -> Void
        ) async throws -> AgentStorageSnapshot = { configuration, progress in
                try await AgentStorageScanner(configuration: configuration).scan(progress: progress)
            }
    ) {
        self.defaults = defaults
        self.locationRepository = locationRepository ?? AgentDataLocationRepository(defaults: defaults)
        self.cacheURL = cacheURL
        snapshot = initialSnapshot
        resultRevisionsByProvider = Dictionary(uniqueKeysWithValues:
            (initialSnapshot?.providers ?? []).map { ($0.provider, 1) }
        )
        state = initialSnapshot == nil ? .idle : .ready
        self.scanAction = scanAction
        if initialSnapshot == nil, cacheURL != nil {
            cacheLoadTask = Task { [weak self] in
                guard let cached = await Self.loadSnapshot(from: cacheURL),
                      let self, self.snapshot == nil, !self.isScanning else { return }
                self.snapshot = cached
                self.snapshotRevision &+= 1
                self.incrementResultRevisions(for: Set(cached.providers.map(\.provider)))
                self.state = .ready
                self.cacheLoadTask = nil
            }
        }
    }

    convenience init(
        defaults: UserDefaults = .standard,
        initialSnapshot: AgentStorageSnapshot? = nil,
        cacheURL: URL? = AgentStorageModel.defaultCacheURL,
        locationRepository: AgentDataLocationRepository? = nil,
        scanAction: @escaping @Sendable (AgentStorageScanner.Configuration) async throws
            -> AgentStorageSnapshot
    ) {
        self.init(
            defaults: defaults,
            initialSnapshot: initialSnapshot,
            cacheURL: cacheURL,
            locationRepository: locationRepository
        ) { configuration, _ in
            try await scanAction(configuration)
        }
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var scanStartedAt: Date? {
        if case .scanning(let startedAt) = state { return startedAt }
        return nil
    }

    var customRoots: [URL] {
        AgentStoragePreferences.customRoots(defaults: defaults)
    }

    var requiresAnalysis: Bool {
        snapshot == nil && !isScanning
    }

    func resultRevision(for provider: AgentStorageProvider) -> UInt64 {
        resultRevisionsByProvider[provider, default: 0]
    }

    func enterFeature() {
        // Entering or restoring this feature may only reveal the current cache.
    }

    func startAnalysis() {
        cancelProviderAnalyses()
        cacheLoadTask?.cancel()
        cacheLoadTask = nil
        let previousTask = scanTask
        previousTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        let configuration = AgentStorageScanner.Configuration(
            additionalRoots: customRoots,
            includesDesktopData: true,
            agentDataLocations: locationRepository.locations()
        )
        progress = AgentStorageScanProgress(phase: .discoveringSources)
        progressByProvider = Dictionary(uniqueKeysWithValues: AgentStorageProvider.allCases.map {
            ($0, AgentStorageScanProgress(phase: .discoveringSources, provider: $0))
        })
        refreshErrorsByProvider = [:]
        state = .scanning(startedAt: Date())
        scanTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled, self.generation == requestedGeneration else {
                return
            }
            do {
                let snapshot = try await self.scanAction(configuration) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.accept(progress, for: requestedGeneration)
                    }
                }
                guard !Task.isCancelled, self.generation == requestedGeneration else {
                    return
                }
                self.snapshot = snapshot
                self.snapshotRevision &+= 1
                self.incrementResultRevisions(for: Set(snapshot.providers.map(\.provider)))
                self.state = .ready
                self.scanTask = nil
                await self.persistSnapshot(snapshot)
                self.drainPendingProviderRefreshes()
            } catch is CancellationError {
                guard self.generation == requestedGeneration else { return }
                self.state = self.snapshot == nil ? .stopped : .stale
                self.scanTask = nil
                self.drainPendingProviderRefreshes()
            } catch {
                guard self.generation == requestedGeneration else { return }
                self.state = .failed(error.localizedDescription)
                self.scanTask = nil
                self.drainPendingProviderRefreshes()
            }
        }
    }

    func startAnalysis(provider: AgentStorageProvider) {
        guard !isScanning,
              snapshot?.providers.contains(where: { $0.provider == provider }) == true,
              !reanalyzingProviders.contains(provider) else { return }
        let requestedGeneration = providerGenerations[provider, default: 0] + 1
        providerGenerations[provider] = requestedGeneration
        reanalyzingProviders.insert(provider)
        refreshErrorsByProvider.removeValue(forKey: provider)
        progressByProvider[provider] = AgentStorageScanProgress(
            phase: .discoveringSources,
            provider: provider
        )
        let configuration = AgentStorageScanner.Configuration(
            additionalRoots: customRoots,
            includesDesktopData: true,
            providers: [provider],
            agentDataLocations: locationRepository.locations()
        )
        providerScanTasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let partial = try await self.scanAction(configuration) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.providerGenerations[provider] == requestedGeneration,
                              self.reanalyzingProviders.contains(provider),
                              progress.provider == provider else { return }
                        self.progressByProvider[provider] = progress
                    }
                }
                guard !Task.isCancelled,
                      self.providerGenerations[provider] == requestedGeneration else { return }
                self.snapshot = Self.merging(
                    previous: self.snapshot,
                    partial: partial,
                    provider: provider
                )
                self.snapshotRevision &+= 1
                self.incrementResultRevisions(for: [provider])
                self.refreshErrorsByProvider.removeValue(forKey: provider)
                self.state = .ready
                self.finishProviderAnalysis(provider, generation: requestedGeneration)
                if let snapshot = self.snapshot {
                    await self.persistSnapshot(snapshot)
                }
            } catch is CancellationError {
                self.finishProviderAnalysis(provider, generation: requestedGeneration)
            } catch {
                self.finishProviderAnalysis(provider, generation: requestedGeneration)
                self.refreshErrorsByProvider[provider] = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func refreshAfterCleanup(providers: Set<AgentStorageProvider>) {
        for provider in providers {
            providerScanTasks[provider]?.cancel()
            providerScanTasks.removeValue(forKey: provider)
            providerGenerations[provider, default: 0] += 1
            reanalyzingProviders.remove(provider)
            progressByProvider.removeValue(forKey: provider)
            refreshErrorsByProvider.removeValue(forKey: provider)
        }
        pendingProviderRefreshes.formUnion(providers)
        drainPendingProviderRefreshes()
    }

    func isAnalyzing(_ provider: AgentStorageProvider) -> Bool {
        isScanning || reanalyzingProviders.contains(provider)
    }

    func stop() {
        cancelProviderAnalyses()
        generation += 1
        let stoppedGeneration = generation
        let stoppedTask = scanTask
        scanTask?.cancel()
        state = snapshot == nil ? .stopped : .stale
        Task { [weak self] in
            await stoppedTask?.value
            guard let self, self.generation == stoppedGeneration else { return }
            self.scanTask = nil
            self.drainPendingProviderRefreshes()
        }
    }

    private func accept(_ candidate: AgentStorageScanProgress, for requestedGeneration: Int) {
        guard generation == requestedGeneration else { return }
        if let provider = candidate.provider {
            if let current = progressByProvider[provider] {
                guard candidate.phase.rawValue >= current.phase.rawValue else { return }
                if candidate.phase == current.phase,
                   candidate.completedCount < current.completedCount {
                    return
                }
            }
            progressByProvider[provider] = candidate
            progress = aggregateProgress(fallback: candidate)
            return
        }
        if progress.provider != nil {
            progress = candidate
            return
        }
        guard candidate.phase.rawValue >= progress.phase.rawValue else { return }
        if candidate.phase == progress.phase,
           candidate.completedCount < progress.completedCount {
            return
        }
        progress = candidate
    }

    private func aggregateProgress(
        fallback: AgentStorageScanProgress
    ) -> AgentStorageScanProgress {
        progressByProvider.values.min { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase.rawValue < rhs.phase.rawValue }
            return progressFraction(lhs) < progressFraction(rhs)
        } ?? fallback
    }

    private func progressFraction(_ value: AgentStorageScanProgress) -> Double {
        guard let total = value.totalCount, total > 0 else {
            return value.completedCount > 0 ? 0.5 : 0
        }
        return min(1, Double(value.completedCount) / Double(total))
    }

    func addCustomRoot(_ url: URL) {
        guard AgentStoragePreferences.recognizedProvider(at: url) != nil else {
            customRootError = L10n.text("所选目录不是可识别的 Codex、Claude Code 或 OpenCode 数据位置")
            return
        }
        customRootError = nil
        AgentStoragePreferences.add(url, defaults: defaults)
        invalidateCachedResults()
        NotificationCenter.default.post(
            name: .agentDataLocationsDidChange,
            object: locationRepository
        )
    }

    func removeCustomRoot(_ url: URL) {
        customRootError = nil
        AgentStoragePreferences.remove(url, defaults: defaults)
        invalidateCachedResults()
        NotificationCenter.default.post(
            name: .agentDataLocationsDidChange,
            object: locationRepository
        )
    }

    func invalidateCachedResults() {
        cancelProviderAnalyses()
        generation += 1
        scanTask?.cancel()
        snapshot = nil
        snapshotRevision &+= 1
        incrementResultRevisions(for: Set(resultRevisionsByProvider.keys))
        progress = AgentStorageScanProgress(phase: .discoveringSources)
        progressByProvider = [:]
        refreshErrorsByProvider = [:]
        pendingProviderRefreshes = []
        state = .idle
        cacheLoadTask?.cancel()
        cacheLoadTask = nil
        cacheRevision &+= 1
        let revision = cacheRevision
        let cacheWriter = snapshotCacheWriter
        let cacheURL = self.cacheURL
        Task { await cacheWriter.remove(at: cacheURL, revision: revision) }
    }

    func prepareForSleep() async {
        cancelProviderAnalyses()
        guard isScanning else { return }
        stop()
        await scanTask?.value
        scanTask = nil
    }

    private func finishProviderAnalysis(_ provider: AgentStorageProvider, generation: Int) {
        guard providerGenerations[provider] == generation else { return }
        reanalyzingProviders.remove(provider)
        progressByProvider.removeValue(forKey: provider)
        providerScanTasks.removeValue(forKey: provider)
    }

    private func cancelProviderAnalyses() {
        for task in providerScanTasks.values { task.cancel() }
        providerScanTasks = [:]
        reanalyzingProviders = []
        providerGenerations = providerGenerations.mapValues { $0 + 1 }
    }

    private func drainPendingProviderRefreshes() {
        guard !isScanning, scanTask == nil, !pendingProviderRefreshes.isEmpty else { return }
        let providers = pendingProviderRefreshes
        pendingProviderRefreshes = []
        for provider in providers.sorted(by: { $0.rawValue < $1.rawValue }) {
            startAnalysis(provider: provider)
        }
    }

    private func incrementResultRevisions(for providers: Set<AgentStorageProvider>) {
        for provider in providers {
            resultRevisionsByProvider[provider, default: 0] &+= 1
        }
    }

    private static func merging(
        previous: AgentStorageSnapshot?,
        partial: AgentStorageSnapshot,
        provider: AgentStorageProvider
    ) -> AgentStorageSnapshot {
        guard let previous else { return partial }
        let families = previous.families.filter { $0.provider != provider }
            + partial.families.filter { $0.provider == provider }
        let globalItems = previous.globalItems.filter { $0.provider != provider }
            + partial.globalItems.filter { $0.provider == provider }
        let unattributedItems = previous.unattributedItems.filter { $0.provider != provider }
            + partial.unattributedItems.filter { $0.provider == provider }
        let providers = previous.providers.filter { $0.provider != provider }
            + partial.providers.filter { $0.provider == provider }
        let sources = previous.sources.filter { $0.provider != provider }
            + partial.sources.filter { $0.provider == provider }
        let datasets = previous.providerDatasets.filter { $0.provider != provider }
            + partial.providerDatasets.filter { $0.provider == provider }
        let attributions = previous.databaseAttributions.filter { $0.provider != provider }
            + partial.databaseAttributions.filter { $0.provider == provider }
        let diagnostics = previous.diagnostics.filter { $0.provider != provider }
            + partial.diagnostics.filter { $0.provider == provider }
        let oldBytes = previous.providers.first { $0.provider == provider }?.exclusiveBytes ?? 0
        let newBytes = partial.providers.first { $0.provider == provider }?.exclusiveBytes ?? 0
        let retainedBytes = previous.coverage.measuredBytes > oldBytes
            ? previous.coverage.measuredBytes - oldBytes
            : 0
        let measuredBytes = Self.addingClamped(retainedBytes, newBytes)
        let coverage = AgentStorageCoverage(
            measuredBytes: measuredBytes,
            classifiedBytes: measuredBytes,
            measuredEntryCount: previous.coverage.measuredEntryCount,
            skippedEntryCount: previous.coverage.skippedEntryCount,
            unstableEntryCount: previous.coverage.unstableEntryCount,
            overflowed: previous.coverage.overflowed,
            reconciliationDelta: 0,
            isComplete: previous.coverage.isComplete && partial.coverage.isComplete
        )
        return AgentStorageSnapshot(
            scannedAt: partial.scannedAt,
            families: families,
            globalItems: globalItems,
            unattributedItems: unattributedItems,
            providers: providers.sorted { $0.provider.rawValue < $1.provider.rawValue },
            sources: sources.sorted { $0.id < $1.id },
            coverage: coverage,
            crossAgentSharedBytes: previous.crossAgentSharedBytes,
            providerDatasets: datasets.sorted { $0.provider.rawValue < $1.provider.rawValue },
            databaseAttributions: attributions,
            diagnostics: diagnostics
        )
    }

    nonisolated private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    func resumeAfterWake() {
        // Resuming may only show the cache left by the interrupted scan.
    }

    func prepareForTermination() async {
        cancelProviderAnalyses()
        generation += 1
        pendingProviderRefreshes = []
        cacheLoadTask?.cancel()
        cacheLoadTask = nil
        scanTask?.cancel()
        await scanTask?.value
        scanTask = nil
    }

    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "FindDiskKiller", directoryHint: .isDirectory)
            .appending(path: "agent-storage-v2.json", directoryHint: .notDirectory)
    }

    nonisolated private static func loadSnapshot(from url: URL?) async -> AgentStorageSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentStorageSnapshot.self, from: data)
    }

    private func persistSnapshot(_ snapshot: AgentStorageSnapshot) async {
        cacheRevision &+= 1
        await snapshotCacheWriter.save(
            snapshot,
            to: cacheURL,
            revision: cacheRevision
        )
    }
}

enum AgentStoragePreferences {
    // Retained only so older defaults can be ignored and covered by migration tests.
    static let autoScanKey = "agentStorageAutoScan"
    static let analysisConsentKey = "agentStorageAnalysisConsent"
    static let hidePrivateDetailsKey = "agentStorageHidePrivateDetails"
    private static let customRootsKey = "agentStorageCustomRoots"

    static func customRoots(defaults: UserDefaults = .standard) -> [URL] {
        let paths = defaults.stringArray(forKey: customRootsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func add(_ url: URL, defaults: UserDefaults = .standard) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: customRootsKey) ?? []
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths.sorted(), forKey: customRootsKey)
    }

    static func remove(_ url: URL, defaults: UserDefaults = .standard) {
        let path = url.standardizedFileURL.path
        let paths = (defaults.stringArray(forKey: customRootsKey) ?? []).filter { $0 != path }
        defaults.set(paths, forKey: customRootsKey)
    }

    static func recognizedProvider(at url: URL) -> AgentStorageProvider? {
        AgentDataLocationDiscovery.recognizedProvider(at: url)
    }
}
