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
    private(set) var state: AgentStorageLoadState
    private(set) var progress = AgentStorageScanProgress(phase: .discoveringSources)
    private(set) var progressByProvider: [AgentStorageProvider: AgentStorageScanProgress] = [:]
    private(set) var generation = 0
    private(set) var customRootError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scanAction: @Sendable (
        AgentStorageScanner.Configuration,
        @escaping @Sendable (AgentStorageScanProgress) -> Void
    ) async throws -> AgentStorageSnapshot
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    init(
        defaults: UserDefaults = .standard,
        initialSnapshot: AgentStorageSnapshot? = nil,
        scanAction: @escaping @Sendable (
            AgentStorageScanner.Configuration,
            @escaping @Sendable (AgentStorageScanProgress) -> Void
        ) async throws -> AgentStorageSnapshot = { configuration, progress in
                try await AgentStorageScanner(configuration: configuration).scan(progress: progress)
            }
    ) {
        self.defaults = defaults
        snapshot = initialSnapshot
        state = initialSnapshot == nil ? .idle : .ready
        self.scanAction = scanAction
    }

    convenience init(
        defaults: UserDefaults = .standard,
        initialSnapshot: AgentStorageSnapshot? = nil,
        scanAction: @escaping @Sendable (AgentStorageScanner.Configuration) async throws
            -> AgentStorageSnapshot
    ) {
        self.init(defaults: defaults, initialSnapshot: initialSnapshot) { configuration, _ in
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

    func enterFeature() {
        // Entering or restoring this feature may only reveal the current cache.
    }

    func startAnalysis() {
        let previousTask = scanTask
        previousTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        let configuration = AgentStorageScanner.Configuration(
            additionalRoots: customRoots,
            includesDesktopData: true
        )
        progress = AgentStorageScanProgress(phase: .discoveringSources)
        progressByProvider = Dictionary(uniqueKeysWithValues: AgentStorageProvider.allCases.map {
            ($0, AgentStorageScanProgress(phase: .discoveringSources, provider: $0))
        })
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
                self.state = .ready
                self.scanTask = nil
            } catch is CancellationError {
                guard self.generation == requestedGeneration else { return }
                self.state = self.snapshot == nil ? .stopped : .stale
                self.scanTask = nil
            } catch {
                guard self.generation == requestedGeneration else { return }
                self.state = .failed(error.localizedDescription)
                self.scanTask = nil
            }
        }
    }

    func stop() {
        generation += 1
        scanTask?.cancel()
        state = snapshot == nil ? .stopped : .stale
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
    }

    func removeCustomRoot(_ url: URL) {
        customRootError = nil
        AgentStoragePreferences.remove(url, defaults: defaults)
        invalidateCachedResults()
    }

    func invalidateCachedResults() {
        generation += 1
        scanTask?.cancel()
        snapshot = nil
        snapshotRevision &+= 1
        progress = AgentStorageScanProgress(phase: .discoveringSources)
        progressByProvider = [:]
        state = .idle
    }

    func prepareForSleep() async {
        guard isScanning else { return }
        stop()
        await scanTask?.value
        scanTask = nil
    }

    func resumeAfterWake() {
        // Resuming may only show the cache left by the interrupted scan.
    }

    func prepareForTermination() async {
        generation += 1
        scanTask?.cancel()
        await scanTask?.value
        scanTask = nil
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
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var paths = defaults.stringArray(forKey: customRootsKey) ?? []
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths.sorted(), forKey: customRootsKey)
    }

    static func remove(_ url: URL, defaults: UserDefaults = .standard) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let paths = (defaults.stringArray(forKey: customRootsKey) ?? []).filter { $0 != path }
        defaults.set(paths, forKey: customRootsKey)
    }

    static func recognizedProvider(at url: URL) -> AgentStorageProvider? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: resolved.appending(path: "state_5.sqlite").path)
            || fileManager.fileExists(atPath: resolved.appending(path: "sessions").path) {
            return .codex
        }
        if fileManager.fileExists(atPath: resolved.appending(path: "projects").path) {
            return .claude
        }
        if fileManager.fileExists(atPath: resolved.appending(path: "opencode.db").path) {
            return .openCode
        }
        return nil
    }
}
