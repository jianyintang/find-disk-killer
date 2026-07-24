import Foundation

public enum TraceHelperProtocolConfiguration {
    public static let version = 1
    public static let machServiceName = "com.jianyintang.FindDiskKiller.TraceHelper"
    public static let launchDaemonPlistName = "com.jianyintang.FindDiskKiller.TraceHelper.plist"

    public static let appCodeSigningRequirement = """
    anchor apple generic and identifier "com.jianyintang.FindDiskKiller" and \
    certificate leaf[subject.OU] = "Y3A8BJ4475"
    """

    public static let helperCodeSigningRequirement = """
    anchor apple generic and identifier "com.jianyintang.FindDiskKiller.TraceHelper" and \
    certificate leaf[subject.OU] = "Y3A8BJ4475"
    """
}

@objc(FindDiskKillerTraceHelperXPCProtocol)
public protocol TraceHelperXPCProtocol {
    func ping(
        clientProtocolVersion: NSNumber,
        withReply reply: @escaping (NSNumber, NSString) -> Void
    )
}

