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
    private(set) var state: AgentStorageLoadState = .idle
    private(set) var progress = AgentStorageScanProgress(phase: .discoveringSources)
    private(set) var generation = 0
    private(set) var customRootError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scanAction: @Sendable (
        AgentStorageScanner.Configuration,
        @escaping @Sendable (AgentStorageScanProgress) -> Void
    ) async throws -> AgentStorageSnapshot
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var hasEnteredFeature = false
    @ObservationIgnored private var shouldResumeAfterWake = false

    init(
        defaults: UserDefaults = .standard,
        scanAction: @escaping @Sendable (
            AgentStorageScanner.Configuration,
            @escaping @Sendable (AgentStorageScanProgress) -> Void
        ) async throws -> AgentStorageSnapshot = { configuration, progress in
                try await AgentStorageScanner(configuration: configuration).scan(progress: progress)
            }
    ) {
        self.defaults = defaults
        self.scanAction = scanAction
    }

    convenience init(
        defaults: UserDefaults = .standard,
        scanAction: @escaping @Sendable (AgentStorageScanner.Configuration) async throws
            -> AgentStorageSnapshot
    ) {
        self.init(defaults: defaults) { configuration, _ in
            try await scanAction(configuration)
        }
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var customRoots: [URL] {
        AgentStoragePreferences.customRoots(defaults: defaults)
    }

    var automaticallyScans: Bool {
        get {
            guard defaults.object(forKey: AgentStoragePreferences.autoScanKey) != nil else {
                return true
            }
            return defaults.bool(forKey: AgentStoragePreferences.autoScanKey)
        }
        set { defaults.set(newValue, forKey: AgentStoragePreferences.autoScanKey) }
    }

    func enterFeature() {
        hasEnteredFeature = true
        guard snapshot == nil, !isScanning, automaticallyScans else { return }
        refresh()
    }

    func refresh() {
        let previousTask = scanTask
        previousTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        let configuration = AgentStorageScanner.Configuration(
            additionalRoots: customRoots,
            includesDesktopData: true
        )
        progress = AgentStorageScanProgress(phase: .discoveringSources)
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
        guard candidate.phase.rawValue >= progress.phase.rawValue else { return }
        if candidate.phase == progress.phase,
           candidate.completedCount < progress.completedCount {
            return
        }
        progress = candidate
    }

    func addCustomRoot(_ url: URL) {
        guard AgentStoragePreferences.recognizedProvider(at: url) != nil else {
            customRootError = L10n.text("所选目录不是可识别的 Codex 或 Claude Code 数据位置")
            return
        }
        customRootError = nil
        AgentStoragePreferences.add(url, defaults: defaults)
        refresh()
    }

    func removeCustomRoot(_ url: URL) {
        customRootError = nil
        AgentStoragePreferences.remove(url, defaults: defaults)
        refresh()
    }

    func prepareForSleep() async {
        shouldResumeAfterWake = isScanning || hasEnteredFeature
        stop()
        await scanTask?.value
    }

    func resumeAfterWake() {
        guard shouldResumeAfterWake else { return }
        shouldResumeAfterWake = false
        if snapshot != nil { state = .stale }
        if hasEnteredFeature, automaticallyScans { refresh() }
    }

    func prepareForTermination() async {
        generation += 1
        scanTask?.cancel()
        await scanTask?.value
        scanTask = nil
    }
}

enum AgentStoragePreferences {
    static let autoScanKey = "agentStorageAutoScan"
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
        return nil
    }
}
