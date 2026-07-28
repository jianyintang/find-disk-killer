import Foundation
import Observation

enum TraceUpdateInterlockStatus: Equatable, Sendable {
    case idle
    case traceStartingOrRunning
    case traceStopping
    case stopUnconfirmed
    case updatePendingOrRunning
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

    var canStartTrace: Bool {
        updateLease == nil && traceLease == nil && status == .idle
    }

    var canStartUpdate: Bool {
        traceLease == nil && updateLease == nil && status == .idle
    }

    var needsHelperReconciliation: Bool {
        traceLease == nil && updateLease == nil && status == .stopUnconfirmed
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
        status = updateLease == nil ? .idle : .updatePendingOrRunning
    }

    func reserveUpdate() -> UpdateActivityLease? {
        guard canStartUpdate else { return nil }
        let lease = UpdateActivityLease(id: UUID())
        updateLease = lease
        status = .updatePendingOrRunning
        return lease
    }

    func releaseUpdate(_ lease: UpdateActivityLease) {
        guard updateLease == lease else { return }
        updateLease = nil
        status = traceLease == nil ? .idle : status
    }

    func markHelperBusyWithoutLocalLease() {
        guard traceLease == nil, updateLease == nil else { return }
        status = .stopUnconfirmed
    }

    func markHelperReadyWithoutLocalLease() {
        guard traceLease == nil, updateLease == nil else { return }
        status = .idle
    }
}
