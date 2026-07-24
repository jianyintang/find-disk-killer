import Foundation
import FindDiskKillerTraceProtocol

private final class TraceHelperService: NSObject, TraceHelperXPCProtocol {
    func ping(
        clientProtocolVersion: NSNumber,
        withReply reply: @escaping (NSNumber, NSString) -> Void
    ) {
        let status = clientProtocolVersion.intValue == TraceHelperProtocolConfiguration.version
            ? "ready"
            : "protocol-mismatch"
        reply(NSNumber(value: TraceHelperProtocolConfiguration.version), status as NSString)
    }
}

private final class TraceHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }

        connection.exportedInterface = NSXPCInterface(with: TraceHelperXPCProtocol.self)
        connection.exportedObject = TraceHelperService()
        connection.activate()
        return true
    }
}

@main
private enum TraceHelperMain {
    static func main() {
        let listener = NSXPCListener(
            machServiceName: TraceHelperProtocolConfiguration.machServiceName
        )
        listener.setConnectionCodeSigningRequirement(
            TraceHelperProtocolConfiguration.appCodeSigningRequirement
        )

        let delegate = TraceHelperListenerDelegate()
        listener.delegate = delegate
        listener.activate()
        RunLoop.current.run()
    }
}
