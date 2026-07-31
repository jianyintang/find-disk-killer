import Foundation
import FindDiskKillerTraceProtocol
import Testing
@testable import FindDiskKillerTraceHelper

private final class FakeTraceSession: TraceSessionManaging, @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private let onTermination: @Sendable (String) -> Void
    private var running = true
    private(set) var stopCount = 0
    private(set) var forceStopCount = 0

    init(onTermination: @escaping @Sendable (String) -> Void) {
        self.onTermination = onTermination
    }

    var isRunning: Bool { lock.withLock { running } }

    func stop() {
        lock.withLock { stopCount += 1 }
    }

    func forceStopIfNeeded() {
        let shouldFinish = lock.withLock {
            forceStopCount += 1
            return running
        }
        if shouldFinish { finish() }
    }

    func stopAndWait() {
        stop()
        finish()
    }

    func drain(maximumRecordCount: Int) -> TraceHelperDrainPayload {
        TraceHelperDrainPayload(
            records: [],
            droppedRecordCount: 0,
            isFinished: !isRunning,
            exitCode: isRunning ? nil : 0
        )
    }

    func finish() {
        let shouldNotify = lock.withLock {
            guard running else { return false }
            running = false
            return true
        }
        if shouldNotify { onTermination(id) }
    }
}

private final class SessionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSession: FakeTraceSession?

    var session: FakeTraceSession? { lock.withLock { storedSession } }

    func make(onTermination: @escaping @Sendable (String) -> Void) -> FakeTraceSession {
        let session = FakeTraceSession(onTermination: onTermination)
        lock.withLock { storedSession = session }
        return session
    }
}

private final class ReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private func makeService() -> (TraceHelperService, SessionHarness) {
    let harness = SessionHarness()
    let service = TraceHelperService { _, _, onTermination in
        harness.make(onTermination: onTermination)
    }
    return (service, harness)
}

private func start(_ connection: TraceHelperConnection) async -> (String, String) {
    await withCheckedContinuation { continuation in
        connection.startTrace(
            maximumDurationSeconds: 60,
            processIdentifiers: [NSNumber(value: 123)]
        ) { sessionID, status in
            continuation.resume(returning: (sessionID as String, status as String))
        }
    }
}

private func startSystem(_ connection: TraceHelperConnection) async -> (String, String) {
    await withCheckedContinuation { continuation in
        connection.startSystemTrace(maximumDurationSeconds: 60) { sessionID, status in
            continuation.resume(returning: (sessionID as String, status as String))
        }
    }
}

private func ping(_ connection: TraceHelperConnection) async -> String {
    await withCheckedContinuation { continuation in
        connection.ping(
            clientProtocolVersion: NSNumber(value: TraceHelperProtocolConfiguration.version)
        ) { _, status in
            continuation.resume(returning: status as String)
        }
    }
}

private func drain(_ connection: TraceHelperConnection, sessionID: String) async -> String {
    await withCheckedContinuation { continuation in
        connection.drainTrace(sessionID: sessionID as NSString, maximumRecordCount: 10) {
            _, status in
            continuation.resume(returning: status as String)
        }
    }
}

@Test
func ownerControlsSession() async throws {
    let (service, harness) = makeService()
    let owner = TraceHelperConnection(service: service)
    let observer = TraceHelperConnection(service: service)
    let started = await start(owner)
    #expect(started.1 == "started")
    #expect(await ping(observer) == "busy")

    #expect(await drain(observer, sessionID: started.0) == "invalid-session")
    observer.clientDisconnected()
    try await Task.sleep(for: .milliseconds(30))
    #expect(harness.session?.stopCount == 0)
    #expect(await ping(owner) == "busy")

    owner.clientDisconnected()
    try await Task.sleep(for: .milliseconds(30))
    #expect(harness.session?.stopCount == 1)
    #expect(await ping(observer) == "busy")
    harness.session?.finish()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await ping(observer) == "ready")
}

@Test
func systemTraceStartsWithoutProcessIdentifiers() async throws {
    let (service, harness) = makeService()
    let owner = TraceHelperConnection(service: service)

    let started = await startSystem(owner)

    #expect(started.1 == "started")
    #expect(harness.session != nil)
    harness.session?.finish()
}

@Test
func stopRepliesWaitForExit() async throws {
    let (service, harness) = makeService()
    let owner = TraceHelperConnection(service: service)
    let started = await start(owner)
    let replies = ReplyRecorder()

    owner.stopTrace(sessionID: started.0 as NSString) { status in
        replies.append(status as String)
    }
    owner.stopTrace(sessionID: started.0 as NSString) { status in
        replies.append(status as String)
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(replies.values.isEmpty)
    #expect(await ping(owner) == "busy")

    harness.session?.finish()
    try await Task.sleep(for: .milliseconds(30))
    #expect(replies.values == ["stopped", "stopped"])
    #expect(await ping(owner) == "ready")
}

@Test
func naturalExitRemainsDrainable() async throws {
    let (service, harness) = makeService()
    let owner = TraceHelperConnection(service: service)
    let started = await start(owner)

    harness.session?.finish()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await ping(owner) == "busy")
    #expect(await drain(owner, sessionID: started.0) == "ready")
    #expect(await ping(owner) == "ready")
}

@Test
func forceStopPrecedesReply() async throws {
    let (service, harness) = makeService()
    let owner = TraceHelperConnection(service: service)
    let started = await start(owner)
    let replies = ReplyRecorder()

    owner.stopTrace(sessionID: started.0 as NSString) { status in
        replies.append(status as String)
    }
    try await Task.sleep(for: .seconds(2.2))

    #expect(harness.session?.forceStopCount == 1)
    #expect(replies.values == ["stopped"])
    #expect(await ping(owner) == "ready")
}
