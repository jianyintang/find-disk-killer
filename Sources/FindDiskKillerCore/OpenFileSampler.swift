import CFindDiskKiller
import Darwin
import Foundation

public enum OpenFileAccessMode: String, Sendable {
    case readOnly
    case writeOnly
    case readWrite
    case eventOnly
    case unknown
}

public enum FileDescriptorKind: Equatable, Sendable {
    case vnode
    case nonVnode
    case unavailable
}

public enum FileDescriptorInspector {
    public static func kind(
        process: ProcessSession,
        fileDescriptor: Int32
    ) -> FileDescriptorKind {
        switch dm_file_descriptor_kind(
            process.pid,
            process.startAbstime,
            fileDescriptor
        ) {
        case 1: .vnode
        case 0: .nonVnode
        default: .unavailable
        }
    }
}

public struct OpenFileRecord: Identifiable, Sendable {
    public let pid: Int32
    public let fileDescriptor: Int32
    public let device: UInt32
    public let inode: UInt64
    public let path: String
    public let fileSize: Int64
    public let vnodeType: Int32
    public let accessMode: OpenFileAccessMode

    public var id: String {
        "\(pid):\(fileDescriptor):\(device):\(inode)"
    }

    public var isDirectory: Bool { vnodeType == 2 }
}

public enum OpenFileSnapshotState: Equatable, Sendable {
    case complete
    case partial
    case processEnded
    case unavailable
}

public struct OpenFileSnapshot: Sendable {
    public let capturedAt: Date
    public let records: [OpenFileRecord]
    public let state: OpenFileSnapshotState
    public let observedVnodeCount: Int
    public let unreadableCount: Int
    public let sampledProcessCount: Int
    public let requestedProcessCount: Int
    public let permissionLimited: Bool
    public let budgetLimited: Bool

    public init(
        capturedAt: Date,
        records: [OpenFileRecord],
        state: OpenFileSnapshotState,
        observedVnodeCount: Int,
        unreadableCount: Int,
        sampledProcessCount: Int,
        requestedProcessCount: Int,
        permissionLimited: Bool,
        budgetLimited: Bool
    ) {
        self.capturedAt = capturedAt
        self.records = records
        self.state = state
        self.observedVnodeCount = observedVnodeCount
        self.unreadableCount = unreadableCount
        self.sampledProcessCount = sampledProcessCount
        self.requestedProcessCount = requestedProcessCount
        self.permissionLimited = permissionLimited
        self.budgetLimited = budgetLimited
    }
}

public actor OpenFileSampler {
    public static let shared = OpenFileSampler()

    public struct Budget: Sendable {
        public let maximumProcesses: Int
        public let maximumFilesPerProcess: Int
        public let maximumDuration: Duration

        public init(
            maximumProcesses: Int = 32,
            maximumFilesPerProcess: Int = 512,
            maximumDuration: Duration = .milliseconds(250)
        ) {
            self.maximumProcesses = min(max(0, maximumProcesses), 4_096)
            self.maximumFilesPerProcess = min(max(1, maximumFilesPerProcess), 8_192)
            self.maximumDuration = max(.zero, maximumDuration)
        }
    }

    private let budget: Budget

    public init(budget: Budget = Budget()) {
        self.budget = budget
    }

    public func sample(sessions: [ProcessSession]) -> OpenFileSnapshot {
        let clock = ContinuousClock()
        let started = clock.now
        let selectedSessions = Array(sessions.prefix(budget.maximumProcesses))
        var records: [OpenFileRecord] = []
        var observedVnodes = 0
        var unreadable = 0
        var sampledProcesses = 0
        var endedProcesses = 0
        var permissionLimited = false
        var budgetLimited = sessions.count > selectedSessions.count

        for session in selectedSessions {
            if started.duration(to: clock.now) >= budget.maximumDuration {
                budgetLimited = true
                break
            }

            var buffer = Array(
                repeating: DMOpenFile(),
                count: budget.maximumFilesPerProcess
            )
            var vnodeCount: Int32 = 0
            var unreadableCount: Int32 = 0
            var processBudgetExhausted: Int32 = 0
            var errorCode: Int32 = 0
            let elapsed = started.duration(to: clock.now)
            let remaining = budget.maximumDuration - elapsed
            let parts = remaining.components
            let remainingNanoseconds = UInt64(max(0, parts.seconds)) * 1_000_000_000
                + UInt64(max(0, parts.attoseconds / 1_000_000_000))
            let count = Int(dm_collect_open_files(
                session.pid,
                session.startAbstime,
                &buffer,
                Int32(buffer.count),
                remainingNanoseconds,
                &vnodeCount,
                &unreadableCount,
                &processBudgetExhausted,
                &errorCode
            ))
            guard count >= 0 else {
                if errorCode == ESRCH { endedProcesses += 1 }
                if errorCode == EPERM || errorCode == EACCES { permissionLimited = true }
                continue
            }

            sampledProcesses += 1
            observedVnodes += Int(vnodeCount)
            unreadable += Int(unreadableCount)
            if processBudgetExhausted != 0 { budgetLimited = true }
            if Int(vnodeCount) > count { budgetLimited = true }
            records.append(contentsOf: buffer.prefix(count).map(Self.record(from:)))
            if started.duration(to: clock.now) >= budget.maximumDuration {
                budgetLimited = true
                break
            }
        }

        let state: OpenFileSnapshotState
        if sampledProcesses == 0, endedProcesses == selectedSessions.count, !selectedSessions.isEmpty {
            state = .processEnded
        } else if sampledProcesses == 0 {
            state = .unavailable
        } else if permissionLimited || budgetLimited || unreadable > 0
                    || sampledProcesses < sessions.count {
            state = .partial
        } else {
            state = .complete
        }

        return OpenFileSnapshot(
            capturedAt: Date(),
            records: records.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            state: state,
            observedVnodeCount: observedVnodes,
            unreadableCount: unreadable,
            sampledProcessCount: sampledProcesses,
            requestedProcessCount: sessions.count,
            permissionLimited: permissionLimited,
            budgetLimited: budgetLimited
        )
    }

    private static func record(from raw: DMOpenFile) -> OpenFileRecord {
        var raw = raw
        return OpenFileRecord(
            pid: raw.pid,
            fileDescriptor: raw.fd,
            device: raw.device,
            inode: raw.inode,
            path: decodeOpenFilePath(&raw.path),
            fileSize: raw.file_size,
            vnodeType: raw.vnode_type,
            accessMode: accessMode(for: raw.open_flags)
        )
    }

    private static func accessMode(for flags: UInt32) -> OpenFileAccessMode {
        if flags & UInt32(O_EVTONLY) != 0 { return .eventOnly }
        let hasRead = flags & 0x0000_0001 != 0 // FREAD in sys/fcntl.h
        let hasWrite = flags & 0x0000_0002 != 0 // FWRITE in sys/fcntl.h
        if hasRead && hasWrite { return .readWrite }
        if hasRead { return .readOnly }
        if hasWrite { return .writeOnly }
        return .unknown
    }
}

private func decodeOpenFilePath<T>(_ value: inout T) -> String {
    withUnsafeBytes(of: &value) { rawBuffer in
        let bytes = rawBuffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
