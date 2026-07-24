import Foundation

public enum TraceHelperProtocolConfiguration {
    public static let version = 2
    public static let machServiceName = "com.jianyintang.FindDiskKiller.TraceHelper"
    public static let launchDaemonPlistName = "com.jianyintang.FindDiskKiller.TraceHelper.plist"
    public static let minimumDurationSeconds = 10
    public static let maximumDurationSeconds = 3_600
    public static let maximumDrainRecordCount = 2_048
    public static let maximumDrainSourceBytes = 256 * 1_024

    public static func validatedDuration(_ value: Int) -> Int? {
        (minimumDurationSeconds...maximumDurationSeconds).contains(value) ? value : nil
    }

    public static func boundedDrainRecordCount(_ value: Int) -> Int {
        min(max(value, 1), maximumDrainRecordCount)
    }

    public static let appCodeSigningRequirement = """
    anchor apple generic and identifier "com.jianyintang.FindDiskKiller" and \
    certificate leaf[subject.OU] = "Y3A8BJ4475"
    """

    public static let helperCodeSigningRequirement = """
    anchor apple generic and identifier "com.jianyintang.FindDiskKiller.TraceHelper" and \
    certificate leaf[subject.OU] = "Y3A8BJ4475"
    """
}

public struct TraceHelperProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startAbstime: UInt64
    public let displayName: String

    public init(pid: Int32, startAbstime: UInt64, displayName: String) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.displayName = displayName
    }
}

public struct TraceHelperRecord: Codable, Equatable, Sendable {
    public let line: String
    public let process: TraceHelperProcessIdentity?

    public init(line: String, process: TraceHelperProcessIdentity?) {
        self.line = line
        self.process = process
    }
}

public struct TraceHelperDrainPayload: Codable, Equatable, Sendable {
    public let records: [TraceHelperRecord]
    public let droppedRecordCount: UInt64
    public let isFinished: Bool
    public let exitCode: Int32?

    public init(
        records: [TraceHelperRecord],
        droppedRecordCount: UInt64,
        isFinished: Bool,
        exitCode: Int32?
    ) {
        self.records = records
        self.droppedRecordCount = droppedRecordCount
        self.isFinished = isFinished
        self.exitCode = exitCode
    }
}

@objc(FindDiskKillerTraceHelperXPCProtocol)
public protocol TraceHelperXPCProtocol {
    func ping(
        clientProtocolVersion: NSNumber,
        withReply reply: @escaping (NSNumber, NSString) -> Void
    )

    func startTrace(
        maximumDurationSeconds: NSNumber,
        withReply reply: @escaping (NSString, NSString) -> Void
    )

    func drainTrace(
        sessionID: NSString,
        maximumRecordCount: NSNumber,
        withReply reply: @escaping (NSData, NSString) -> Void
    )

    func stopTrace(
        sessionID: NSString,
        withReply reply: @escaping (NSString) -> Void
    )
}
