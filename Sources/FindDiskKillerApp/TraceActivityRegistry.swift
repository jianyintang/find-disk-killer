import Foundation
import Observation

enum TraceUpdateInterlockStatus: Equatable, Sendable {
    case idle
    case traceStartingOrRunning
    case traceStopping
    case stopUnconfirmed
    case updatePendingOrRunning
}

enum UpdateInterlockPolicy {
    static func allowsAppcastCheck(while status: TraceUpdateInterlockStatus) -> Bool {
        _ = status
        return true
    }
}

struct TraceActivityLease: Hashable, Sendable {
    fileprivate let id: UUID
}

struct UpdateActivityLease: Hashable, Sendable {
    fileprivate let id: UUID
}

@MainActor
@Observable
final class TraceActivityRegistry {
    private(set) var status: TraceUpdateInterlockStatus = .idle
    private var traceLease: TraceActivityLease?
    private var updateLease: UpdateActivityLease?
    private var helperStateNeedsReconciliation = false

    var canStartTrace: Bool {
        updateLease == nil && traceLease == nil && status == .idle
    }

    // Reading the signed appcast is non-destructive and may run alongside a trace.
    // Installation must wait for a trace owned by this app, but an orphaned
    // helper state cannot stall a verified update forever. Reconciliation still
    // blocks new traces until the helper is known to be idle.
    var canBeginUpdateInstallation: Bool {
        traceLease == nil && updateLease == nil
    }

    var needsHelperReconciliation: Bool {
        helperStateNeedsReconciliation
    }

    func acquireTrace() -> TraceActivityLease? {
        guard canStartTrace else { return nil }
        let lease = TraceActivityLease(id: UUID())
        traceLease = lease
        status = .traceStartingOrRunning
        return lease
    }

    func markTraceRunning(_ lease: TraceActivityLease) {
        guard traceLease == lease else { return }
        status = .traceStartingOrRunning
    }

    func markTraceStopping(_ lease: TraceActivityLease) {
        guard traceLease == lease else { return }
        status = .traceStopping
    }

    func markTraceStopUnconfirmed(_ lease: TraceActivityLease) {
        guard traceLease == lease else { return }
        status = .stopUnconfirmed
    }

    func releaseTrace(_ lease: TraceActivityLease) {
        guard traceLease == lease else { return }
        traceLease = nil
        status = updateLease == nil
            ? (helperStateNeedsReconciliation ? .stopUnconfirmed : .idle)
            : .updatePendingOrRunning
    }

    func reserveUpdateInstallation() -> UpdateActivityLease? {
        guard canBeginUpdateInstallation else { return nil }
        let lease = UpdateActivityLease(id: UUID())
        updateLease = lease
        status = .updatePendingOrRunning
        return lease
    }

    func releaseUpdate(_ lease: UpdateActivityLease) {
        guard updateLease == lease else { return }
        updateLease = nil
        if traceLease == nil {
            status = helperStateNeedsReconciliation ? .stopUnconfirmed : .idle
        }
    }

    func markHelperBusyWithoutLocalLease() {
        guard traceLease == nil, updateLease == nil else { return }
        helperStateNeedsReconciliation = true
        status = .stopUnconfirmed
    }

    func markHelperReadyWithoutLocalLease() {
        helperStateNeedsReconciliation = false
        guard traceLease == nil, updateLease == nil else { return }
        status = .idle
    }
}

@MainActor
final class UpdateInstallationInterlock {
    private let activityRegistry: TraceActivityRegistry
    private var activeLease: UpdateActivityLease?
    private var postponedTask: Task<Void, Never>?

    init(activityRegistry: TraceActivityRegistry) {
        self.activityRegistry = activityRegistry
    }

    var isActive: Bool {
        activeLease != nil || postponedTask != nil
    }

    func postponeIfNeeded(untilReady installHandler: @escaping () -> Void) -> Bool {
        cancelPostponedTask()
        if let lease = activityRegistry.reserveUpdateInstallation() {
            activeLease = lease
            return false
        }

        postponedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let lease = self.activityRegistry.reserveUpdateInstallation() {
                    self.activeLease = lease
                    self.postponedTask = nil
                    installHandler()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return true
    }

    func release() {
        cancelPostponedTask()
        if let activeLease {
            activityRegistry.releaseUpdate(activeLease)
        }
        activeLease = nil
    }

    private func cancelPostponedTask() {
        postponedTask?.cancel()
        postponedTask = nil
    }
}
