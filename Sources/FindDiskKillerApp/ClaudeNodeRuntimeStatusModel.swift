import Foundation
import Observation

enum ClaudeNodeRuntimeSource: Equatable, Sendable {
    case environmentOverride
    case legacyBundled
    case downloaded
    case system

    var localizedLabel: String {
        switch self {
        case .environmentOverride: L10n.text("环境变量指定")
        case .legacyBundled: L10n.text("旧版内置")
        case .downloaded: L10n.text("已下载")
        case .system: L10n.text("系统安装")
        }
    }
}

struct ClaudeNodeRuntimeAvailability: Equatable, Sendable {
    let path: String
    let version: String?
    let source: ClaudeNodeRuntimeSource
}

/// Drives the Node.js runtime status row in Settings: probes the same
/// resolution order used by the Claude cleanup flow, and lets the user
/// pre-download the pinned official runtime instead of waiting for the
/// first cleanup to trigger it.
@MainActor
@Observable
final class ClaudeNodeRuntimeStatusModel {
    typealias Source = ClaudeNodeRuntimeSource
    typealias Availability = ClaudeNodeRuntimeAvailability

    enum Phase {
        case checking
        case available(Availability)
        case missing
        case downloading
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private var refreshTask: Task<Void, Never>?
    private var isDownloading = false

    /// Re-probes in the background; an already displayed result stays
    /// interactive and is replaced only when the new probe finishes.
    func refresh() {
        guard !isDownloading else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let availability = await Self.probe()
            guard let self, !Task.isCancelled, !self.isDownloading else { return }
            if let availability {
                self.phase = .available(availability)
            } else if case .failed = self.phase {
                // Keep the failure visible until the user retries.
            } else {
                self.phase = .missing
            }
        }
    }

    func download() {
        guard !isDownloading else { return }
        refreshTask?.cancel()
        isDownloading = true
        phase = .downloading
        Task { [weak self] in
            do {
                let path = try await ClaudeNodeRuntime.ensureAvailable()
                let availability = await Self.inspect(path: path)
                guard let self else { return }
                self.isDownloading = false
                self.phase = .available(availability)
            } catch {
                guard let self else { return }
                self.isDownloading = false
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs off the main actor: resolution may spawn `node --version`.
    private nonisolated static func probe() async -> Availability? {
        guard let path = ClaudeNodeRuntime.existingRuntime() else { return nil }
        return await inspect(path: path)
    }

    private nonisolated static func inspect(path: String) async -> Availability {
        let version = ClaudeNodeRuntime.measuredVersionOutput(of: path)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Availability(
            path: path,
            version: (version?.isEmpty ?? true) ? nil : version,
            source: classify(
                path: path,
                environmentOverride: ProcessInfo.processInfo.environment["FDK_NODE_BINARY"],
                bundledPath: ClaudeNodeRuntime.bundledRuntimePath(),
                downloadRoot: ClaudeNodeRuntime.defaultApplicationSupportRoot()
                    .appending(path: "AgentCleanup", directoryHint: .isDirectory).path
            )
        )
    }

    nonisolated static func classify(
        path: String,
        environmentOverride: String?,
        bundledPath: String?,
        downloadRoot: String
    ) -> Source {
        if let environmentOverride, environmentOverride == path {
            return .environmentOverride
        }
        if let bundledPath, bundledPath == path {
            return .legacyBundled
        }
        let root = downloadRoot.hasSuffix("/") ? downloadRoot : downloadRoot + "/"
        if path.hasPrefix(root) {
            return .downloaded
        }
        return .system
    }
}
