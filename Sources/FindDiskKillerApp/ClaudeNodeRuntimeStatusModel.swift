import FindDiskKillerNodeRuntime
import Foundation
import Observation

enum ClaudeNodeRuntimeSource: Equatable, Sendable {
    case environmentOverride
    case legacyBundled
    case downloaded
    case system

    init(_ source: NodeRuntimeSource) {
        switch source {
        case .environmentOverride: self = .environmentOverride
        case .legacyBundled: self = .legacyBundled
        case .downloaded: self = .downloaded
        case .system: self = .system
        }
    }

    var localizedLabel: String {
        switch self {
        case .environmentOverride: L10n.text("环境变量指定")
        case .legacyBundled: L10n.text("旧版内置")
        case .downloaded: L10n.text("已下载")
        case .system: L10n.text("本机安装")
        }
    }
}

struct ClaudeNodeRuntimeAvailability: Equatable, Sendable {
    let path: String
    let version: String
    let source: ClaudeNodeRuntimeSource
}

@MainActor
@Observable
final class ClaudeNodeRuntimeStatusModel {
    typealias Source = ClaudeNodeRuntimeSource
    typealias Availability = ClaudeNodeRuntimeAvailability
    typealias ProbeOperation = @Sendable () async throws -> ValidatedNodeRuntime?
    typealias EnsureOperation = @Sendable (
        @escaping @Sendable (ClaudeNodeRuntimeProvisioningPhase) -> Void
    ) async throws -> ValidatedNodeRuntime

    enum Phase: Equatable {
        case checking
        case available(Availability)
        case missing
        case downloading
        case verifying
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isDownloading = false
    @ObservationIgnored private let probeOperation: ProbeOperation
    @ObservationIgnored private let ensureOperation: EnsureOperation

    init(
        probeOperation: @escaping ProbeOperation = {
            try await Task.detached { try ClaudeNodeRuntime.resolvedExistingRuntime() }.value
        },
        ensureOperation: @escaping EnsureOperation = { onPhase in
            try await ClaudeNodeRuntime.ensureResolved(onPhase: onPhase)
        }
    ) {
        self.probeOperation = probeOperation
        self.ensureOperation = ensureOperation
    }

    /// Re-probes in the background; an already displayed result stays
    /// interactive until the new validation has a definitive result.
    func refresh() {
        guard !isDownloading else { return }
        refreshTask?.cancel()
        let probeOperation = self.probeOperation
        refreshTask = Task { [weak self] in
            do {
                let runtime = try await probeOperation()
                guard let self, !Task.isCancelled, !self.isDownloading else { return }
                self.phase = runtime.map { .available(Self.availability(from: $0)) } ?? .missing
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, !self.isDownloading else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func download() {
        guard !isDownloading else { return }
        refreshTask?.cancel()
        isDownloading = true
        phase = .downloading
        let ensureOperation = self.ensureOperation
        Task { [weak self] in
            guard let self else { return }
            do {
                let runtime = try await ensureOperation { phase in
                    Task { @MainActor in self.apply(provisioningPhase: phase) }
                }
                self.isDownloading = false
                self.phase = .available(Self.availability(from: runtime))
            } catch {
                self.isDownloading = false
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(provisioningPhase: ClaudeNodeRuntimeProvisioningPhase) {
        guard isDownloading else { return }
        switch provisioningPhase {
        case .downloading: phase = .downloading
        case .verifying: phase = .verifying
        case .installing: phase = .installing
        }
    }

    nonisolated static func availability(from runtime: ValidatedNodeRuntime) -> Availability {
        Availability(
            path: runtime.path,
            version: runtime.version.nodeOutput,
            source: Source(runtime.source)
        )
    }

    nonisolated static func classify(
        path: String,
        environmentOverride: String?,
        bundledPath: String?,
        downloadRoot: String
    ) -> Source {
        if let environmentOverride, environmentOverride == path { return .environmentOverride }
        if let bundledPath, bundledPath == path { return .legacyBundled }
        let root = downloadRoot.hasSuffix("/") ? downloadRoot : downloadRoot + "/"
        return path.hasPrefix(root) ? .downloaded : .system
    }
}
