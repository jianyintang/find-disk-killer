import CFindDiskKillerTrace
import Darwin
import Foundation
import FindDiskKillerTraceProtocol

private enum TraceHelperStatus {
    static let ready = "ready"
    static let started = "started"
    static let stopped = "stopped"
    static let busy = "busy"
    static let invalidSession = "invalid-session"
    static let invalidRequest = "invalid-request"
    static let launchFailed = "launch-failed"
    static let encodingFailed = "encoding-failed"
}

private final class XPCReply<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func callAsFunction(_ value: Value) {
        callback(value)
    }
}

private final class TraceProcessResolver: @unchecked Sendable {
    private struct CachedIdentity {
        let identity: TraceHelperProcessIdentity?
        let expiresAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var cache: [UInt64: CachedIdentity] = [:]
    private let clock = ContinuousClock()
    private let processIdentifiers: [Int32]

    init(processIdentifiers: [Int32]) {
        self.processIdentifiers = processIdentifiers
    }

    func identity(for threadID: UInt64) -> TraceHelperProcessIdentity? {
        let now = clock.now
        lock.lock()
        if let cached = cache[threadID], cached.expiresAt > now {
            lock.unlock()
            return cached.identity
        }
        lock.unlock()

        var raw = FDKTraceProcessIdentity()
        let resolved = processIdentifiers.withUnsafeBufferPointer { identifiers in
            fdk_trace_resolve_thread_in_processes(
                threadID,
                identifiers.baseAddress,
                Int32(identifiers.count),
                &raw
            ) == 1
        }
        let identity: TraceHelperProcessIdentity? = if resolved {
            TraceHelperProcessIdentity(
                pid: raw.pid,
                startAbstime: raw.start_abstime,
                displayName: withUnsafeBytes(of: raw.name) { bytes in
                    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                    return String(decoding: bytes[..<end], as: UTF8.self)
                }
            )
        } else {
            nil
        }

        lock.lock()
        cache[threadID] = CachedIdentity(
            identity: identity,
            expiresAt: now.advanced(by: resolved ? .seconds(30) : .seconds(2))
        )
        if cache.count > 4_096 {
            cache = cache.filter { $0.value.expiresAt > now }
            let excess = cache.count - 4_096
            if excess > 0 {
                for key in cache.keys.prefix(excess) {
                    cache.removeValue(forKey: key)
                }
            }
        }
        lock.unlock()
        return identity
    }
}

protocol TraceSessionManaging: AnyObject, Sendable {
    var id: String { get }
    var isRunning: Bool { get }
    func stop()
    func forceStopIfNeeded()
    func stopAndWait()
    func drain(maximumRecordCount: Int) -> TraceHelperDrainPayload
}

final class TraceSession: TraceSessionManaging, @unchecked Sendable {
    private static let maximumBufferedBytes = 4 * 1_024 * 1_024
    private static let maximumLineBytes = 32 * 1_024

    let id = UUID().uuidString
    let process: Process
    private let output: Pipe
    private let resolver: TraceProcessResolver?
    private let lock = NSLock()
    private var pendingBytes = Data()
    private var records: [TraceHelperRecord] = []
    private var recordHead = 0
    private var bufferedBytes = 0
    private var droppedRecordCount: UInt64 = 0
    private var finished = false
    private var exitCode: Int32?
    private let onTermination: @Sendable (String) -> Void

    init(
        maximumDurationSeconds: Int,
        processIdentifiers: [Int32]?,
        onTermination: @escaping @Sendable (String) -> Void
    ) throws {
        process = Process()
        output = Pipe()
        resolver = processIdentifiers.map {
            TraceProcessResolver(processIdentifiers: $0)
        }
        self.onTermination = onTermination
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fs_usage")
        process.arguments = [
            "-w", "-f", "filesys", "-t", String(maximumDurationSeconds)
        ] + (processIdentifiers ?? []).map(String.init)
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self.consume(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            self.finished = true
            self.exitCode = process.terminationStatus
            self.lock.unlock()
            self.onTermination(self.id)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    func forceStopIfNeeded() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func stopAndWait() {
        stop()
        let forceStop = DispatchWorkItem { [weak self] in
            self?.forceStopIfNeeded()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(2),
            execute: forceStop
        )
        process.waitUntilExit()
        forceStop.cancel()
    }

    func drain(maximumRecordCount: Int) -> TraceHelperDrainPayload {
        lock.lock()
        defer { lock.unlock() }
        let availableCount = min(maximumRecordCount, records.count - recordHead)
        var count = 0
        var byteCount = 0
        while count < availableCount {
            let nextSize = records[recordHead + count].line.utf8.count + 128
            if count > 0,
               byteCount + nextSize > TraceHelperProtocolConfiguration.maximumDrainSourceBytes {
                break
            }
            byteCount += nextSize
            count += 1
        }
        let end = recordHead + count
        let drained = Array(records[recordHead..<end])
        if count > 0 {
            for record in drained {
                bufferedBytes -= record.line.utf8.count
            }
            recordHead = end
            compactRecordsIfNeeded()
        }
        let dropped = droppedRecordCount
        droppedRecordCount = 0
        return TraceHelperDrainPayload(
            records: drained,
            droppedRecordCount: dropped,
            hasMoreRecords: recordHead < records.count,
            isFinished: finished && recordHead == records.count,
            exitCode: exitCode
        )
    }

    private func consume(_ data: Data) {
        lock.lock()
        pendingBytes.append(data)
        var lines: [Data] = []
        while let newline = pendingBytes.firstIndex(of: 0x0A) {
            lines.append(pendingBytes[..<newline])
            pendingBytes.removeSubrange(...newline)
        }
        if pendingBytes.count > Self.maximumLineBytes {
            pendingBytes.removeAll(keepingCapacity: true)
            droppedRecordCount = adding(droppedRecordCount, 1)
        }
        lock.unlock()

        for data in lines {
            guard data.count <= Self.maximumLineBytes,
                  let line = String(data: data, encoding: .utf8)
            else {
                markDropped()
                continue
            }
            append(line: line)
        }
    }

    private func append(line: String) {
        let processIdentity = resolver.flatMap { resolver in
            Self.threadID(in: line).flatMap(resolver.identity)
        }
        let record = TraceHelperRecord(line: line, process: processIdentity)
        let byteCount = line.utf8.count

        lock.lock()
        while recordHead < records.count,
              bufferedBytes + byteCount > Self.maximumBufferedBytes {
            bufferedBytes -= records[recordHead].line.utf8.count
            recordHead += 1
            droppedRecordCount = adding(droppedRecordCount, 1)
        }
        if byteCount > Self.maximumBufferedBytes {
            droppedRecordCount = adding(droppedRecordCount, 1)
        } else {
            records.append(record)
            bufferedBytes += byteCount
        }
        compactRecordsIfNeeded()
        lock.unlock()
    }

    private func markDropped() {
        lock.lock()
        droppedRecordCount = adding(droppedRecordCount, 1)
        lock.unlock()
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private func compactRecordsIfNeeded() {
        guard recordHead > 4_096,
              recordHead >= records.count / 2
        else { return }
        records.removeFirst(recordHead)
        recordHead = 0
    }

    private static func threadID(in line: String) -> UInt64? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let finalField = trimmed.split(whereSeparator: \Character.isWhitespace).last,
              let separator = finalField.lastIndex(of: ".")
        else { return nil }
        return UInt64(finalField[finalField.index(after: separator)...])
    }
}

final class TraceHelperService: @unchecked Sendable {
    typealias SessionFactory = @Sendable (
        Int,
        [Int32]?,
        @escaping @Sendable (String) -> Void
    ) throws -> any TraceSessionManaging

    private let queue = DispatchQueue(label: "com.jianyintang.FindDiskKiller.TraceHelper.session")
    private let sessionFactory: SessionFactory
    private var session: (any TraceSessionManaging)?
    private var sessionOwnerID: UUID?
    private var stoppingSessionID: String?
    private var pendingStopReplies: [XPCReply<NSString>] = []
    private var forceStopWorkItem: DispatchWorkItem?

    init(sessionFactory: @escaping SessionFactory = { duration, identifiers, onTermination in
        try TraceSession(
            maximumDurationSeconds: duration,
            processIdentifiers: identifiers,
            onTermination: onTermination
        )
    }) {
        self.sessionFactory = sessionFactory
    }

    func clientDisconnected(_ clientID: UUID) {
        queue.async {
            guard self.sessionOwnerID == clientID,
                  let session = self.session else { return }
            self.beginStopping(session)
        }
    }

    func shutdown() {
        let activeSession = queue.sync { session }
        activeSession?.stopAndWait()
    }

    func ping(
        clientProtocolVersion: NSNumber,
        withReply reply: @escaping (NSNumber, NSString) -> Void
    ) {
        let replyBox = XPCReply<(NSNumber, NSString)> { reply($0.0, $0.1) }
        queue.async {
            let status: String
            if clientProtocolVersion.intValue != TraceHelperProtocolConfiguration.version {
                status = "protocol-mismatch"
            } else if self.session != nil || self.stoppingSessionID != nil {
                status = TraceHelperStatus.busy
            } else {
                status = TraceHelperStatus.ready
            }
            replyBox((
                NSNumber(value: TraceHelperProtocolConfiguration.version),
                status as NSString
            ))
        }
    }

    func startTrace(
        clientID: UUID,
        maximumDurationSeconds: NSNumber,
        processIdentifiers: NSArray,
        withReply reply: @escaping (NSString, NSString) -> Void
    ) {
        let requestedDuration = maximumDurationSeconds.intValue
        let rawIdentifiers = processIdentifiers.compactMap { ($0 as? NSNumber)?.int64Value }
        let originalIdentifierCount = processIdentifiers.count
        let replyBox = XPCReply<(NSString, NSString)> { reply($0.0, $0.1) }
        queue.async {
            guard let duration = TraceHelperProtocolConfiguration.validatedDuration(
                requestedDuration
            ), let identifiers = TraceHelperProtocolConfiguration.validatedProcessIdentifiers(
                rawIdentifiers.map(NSNumber.init(value:))
            ), identifiers.count == originalIdentifierCount else {
                replyBox(("" as NSString, TraceHelperStatus.invalidRequest as NSString))
                return
            }
            if let session = self.session {
                replyBox((session.id as NSString, TraceHelperStatus.busy as NSString))
                return
            }
            guard self.stoppingSessionID == nil else {
                replyBox(("" as NSString, TraceHelperStatus.busy as NSString))
                return
            }
            do {
                let session = try self.sessionFactory(
                    duration,
                    identifiers,
                    { [weak self] sessionID in
                        self?.queue.async { [weak self] in
                            self?.sessionDidTerminate(sessionID)
                        }
                    }
                )
                self.session = session
                self.sessionOwnerID = clientID
                replyBox((session.id as NSString, TraceHelperStatus.started as NSString))
            } catch {
                self.session = nil
                replyBox(("" as NSString, TraceHelperStatus.launchFailed as NSString))
            }
        }
    }

    func startSystemTrace(
        clientID: UUID,
        maximumDurationSeconds: NSNumber,
        withReply reply: @escaping (NSString, NSString) -> Void
    ) {
        let requestedDuration = maximumDurationSeconds.intValue
        let replyBox = XPCReply<(NSString, NSString)> { reply($0.0, $0.1) }
        queue.async {
            guard let duration = TraceHelperProtocolConfiguration.validatedDuration(
                requestedDuration
            ) else {
                replyBox(("" as NSString, TraceHelperStatus.invalidRequest as NSString))
                return
            }
            if let session = self.session {
                replyBox((session.id as NSString, TraceHelperStatus.busy as NSString))
                return
            }
            guard self.stoppingSessionID == nil else {
                replyBox(("" as NSString, TraceHelperStatus.busy as NSString))
                return
            }
            do {
                let session = try self.sessionFactory(
                    duration,
                    nil,
                    { [weak self] sessionID in
                        self?.queue.async { [weak self] in
                            self?.sessionDidTerminate(sessionID)
                        }
                    }
                )
                self.session = session
                self.sessionOwnerID = clientID
                replyBox((session.id as NSString, TraceHelperStatus.started as NSString))
            } catch {
                self.session = nil
                replyBox(("" as NSString, TraceHelperStatus.launchFailed as NSString))
            }
        }
    }

    func drainTrace(
        clientID: UUID,
        sessionID: NSString,
        maximumRecordCount: NSNumber,
        withReply reply: @escaping (NSData, NSString) -> Void
    ) {
        let requestedSessionID = sessionID as String
        let requestedRecordCount = maximumRecordCount.intValue
        let replyBox = XPCReply<(NSData, NSString)> { reply($0.0, $0.1) }
        queue.async {
            guard self.sessionOwnerID == clientID,
                  let session = self.session,
                  session.id == requestedSessionID else {
                replyBox((NSData(), TraceHelperStatus.invalidSession as NSString))
                return
            }
            let count = TraceHelperProtocolConfiguration.boundedDrainRecordCount(
                requestedRecordCount
            )
            let payload = session.drain(maximumRecordCount: count)
            guard let data = try? JSONEncoder().encode(payload) else {
                replyBox((NSData(), TraceHelperStatus.encodingFailed as NSString))
                return
            }
            replyBox((data as NSData, TraceHelperStatus.ready as NSString))
            if payload.isFinished, self.stoppingSessionID == nil {
                self.session = nil
                self.sessionOwnerID = nil
            }
        }
    }

    func stopTrace(
        clientID: UUID,
        sessionID: NSString,
        withReply reply: @escaping (NSString) -> Void
    ) {
        let requestedSessionID = sessionID as String
        let replyBox = XPCReply<NSString>(reply)
        queue.async {
            guard self.sessionOwnerID == clientID,
                  let session = self.session,
                  session.id == requestedSessionID else {
                replyBox(TraceHelperStatus.invalidSession as NSString)
                return
            }
            self.pendingStopReplies.append(replyBox)
            self.beginStopping(session)
        }
    }

    private func beginStopping(_ session: any TraceSessionManaging) {
        guard stoppingSessionID == nil else { return }
        stoppingSessionID = session.id
        if session.isRunning {
            session.stop()
            let sessionID = session.id
            let forceStop = DispatchWorkItem { [weak self, weak session] in
                guard let self, let session,
                      self.stoppingSessionID == sessionID else { return }
                session.forceStopIfNeeded()
            }
            forceStopWorkItem = forceStop
            queue.asyncAfter(deadline: .now() + .seconds(2), execute: forceStop)
        } else {
            completeStop(session.id)
        }
    }

    private func sessionDidTerminate(_ sessionID: String) {
        guard session?.id == sessionID else { return }
        guard stoppingSessionID == sessionID else { return }
        completeStop(sessionID)
    }

    private func completeStop(_ sessionID: String) {
        guard session?.id == sessionID, stoppingSessionID == sessionID else { return }
        forceStopWorkItem?.cancel()
        forceStopWorkItem = nil
        session = nil
        sessionOwnerID = nil
        stoppingSessionID = nil
        let replies = pendingStopReplies
        pendingStopReplies.removeAll()
        for reply in replies {
            reply(TraceHelperStatus.stopped as NSString)
        }
    }
}

final class TraceHelperConnection: NSObject, TraceHelperXPCProtocol, @unchecked Sendable {
    let clientID = UUID()
    private let service: TraceHelperService

    init(service: TraceHelperService) {
        self.service = service
    }

    func clientDisconnected() {
        service.clientDisconnected(clientID)
    }

    func ping(
        clientProtocolVersion: NSNumber,
        withReply reply: @escaping (NSNumber, NSString) -> Void
    ) {
        service.ping(clientProtocolVersion: clientProtocolVersion, withReply: reply)
    }

    func startTrace(
        maximumDurationSeconds: NSNumber,
        processIdentifiers: NSArray,
        withReply reply: @escaping (NSString, NSString) -> Void
    ) {
        service.startTrace(
            clientID: clientID,
            maximumDurationSeconds: maximumDurationSeconds,
            processIdentifiers: processIdentifiers,
            withReply: reply
        )
    }

    func startSystemTrace(
        maximumDurationSeconds: NSNumber,
        withReply reply: @escaping (NSString, NSString) -> Void
    ) {
        service.startSystemTrace(
            clientID: clientID,
            maximumDurationSeconds: maximumDurationSeconds,
            withReply: reply
        )
    }

    func drainTrace(
        sessionID: NSString,
        maximumRecordCount: NSNumber,
        withReply reply: @escaping (NSData, NSString) -> Void
    ) {
        service.drainTrace(
            clientID: clientID,
            sessionID: sessionID,
            maximumRecordCount: maximumRecordCount,
            withReply: reply
        )
    }

    func stopTrace(
        sessionID: NSString,
        withReply reply: @escaping (NSString) -> Void
    ) {
        service.stopTrace(clientID: clientID, sessionID: sessionID, withReply: reply)
    }
}

private final class TraceHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = TraceHelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }

        let client = TraceHelperConnection(service: service)
        connection.exportedInterface = NSXPCInterface(with: TraceHelperXPCProtocol.self)
        connection.exportedObject = client
        connection.invalidationHandler = { [client] in
            client.clientDisconnected()
        }
        connection.activate()
        return true
    }

    func shutdown() {
        service.shutdown()
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

        signal(SIGTERM, SIG_IGN)
        let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM)
        terminationSource.setEventHandler {
            delegate.shutdown()
            exit(EXIT_SUCCESS)
        }
        terminationSource.resume()
        withExtendedLifetime(terminationSource) {
            RunLoop.current.run()
        }
    }
}
