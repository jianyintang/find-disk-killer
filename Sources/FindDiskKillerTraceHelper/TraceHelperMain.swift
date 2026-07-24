import CFindDiskKillerTrace
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

private final class TraceProcessResolver: @unchecked Sendable {
    private struct CachedIdentity {
        let identity: TraceHelperProcessIdentity?
        let expiresAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var cache: [UInt64: CachedIdentity] = [:]
    private let clock = ContinuousClock()

    func identity(for threadID: UInt64) -> TraceHelperProcessIdentity? {
        let now = clock.now
        lock.lock()
        if let cached = cache[threadID], cached.expiresAt > now {
            lock.unlock()
            return cached.identity
        }
        lock.unlock()

        var raw = FDKTraceProcessIdentity()
        let resolved = fdk_trace_resolve_thread(threadID, &raw) == 1
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

private final class TraceSession: @unchecked Sendable {
    private static let maximumBufferedBytes = 4 * 1_024 * 1_024
    private static let maximumLineBytes = 32 * 1_024

    let id = UUID().uuidString
    let process: Process
    private let output: Pipe
    private let resolver = TraceProcessResolver()
    private let lock = NSLock()
    private var pendingBytes = Data()
    private var records: [TraceHelperRecord] = []
    private var recordHead = 0
    private var bufferedBytes = 0
    private var droppedRecordCount: UInt64 = 0
    private var finished = false
    private var exitCode: Int32?

    init(maximumDurationSeconds: Int) throws {
        process = Process()
        output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fs_usage")
        process.arguments = [
            "-w", "-f", "filesys", "-t", String(maximumDurationSeconds)
        ]
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
        }
        try process.run()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
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
        let processIdentity = Self.threadID(in: line).flatMap(resolver.identity)
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

private final class TraceHelperService: NSObject, TraceHelperXPCProtocol {
    private let queue = DispatchQueue(label: "com.jianyintang.FindDiskKiller.TraceHelper.session")
    private var session: TraceSession?

    func clientDisconnected() {
        queue.async {
            self.session?.stop()
            self.session = nil
        }
    }

    func ping(
        clientProtocolVersion: NSNumber,
        withReply reply: @escaping (NSNumber, NSString) -> Void
    ) {
        let status = clientProtocolVersion.intValue == TraceHelperProtocolConfiguration.version
            ? TraceHelperStatus.ready
            : "protocol-mismatch"
        reply(NSNumber(value: TraceHelperProtocolConfiguration.version), status as NSString)
    }

    func startTrace(
        maximumDurationSeconds: NSNumber,
        withReply reply: @escaping (NSString, NSString) -> Void
    ) {
        queue.async {
            guard let duration = TraceHelperProtocolConfiguration.validatedDuration(
                maximumDurationSeconds.intValue
            ) else {
                reply("" as NSString, TraceHelperStatus.invalidRequest as NSString)
                return
            }
            if let session = self.session, session.process.isRunning {
                reply(session.id as NSString, TraceHelperStatus.busy as NSString)
                return
            }
            self.session?.stop()
            do {
                let session = try TraceSession(maximumDurationSeconds: duration)
                self.session = session
                reply(session.id as NSString, TraceHelperStatus.started as NSString)
            } catch {
                self.session = nil
                reply("" as NSString, TraceHelperStatus.launchFailed as NSString)
            }
        }
    }

    func drainTrace(
        sessionID: NSString,
        maximumRecordCount: NSNumber,
        withReply reply: @escaping (NSData, NSString) -> Void
    ) {
        queue.async {
            guard let session = self.session, session.id == sessionID as String else {
                reply(NSData(), TraceHelperStatus.invalidSession as NSString)
                return
            }
            let count = TraceHelperProtocolConfiguration.boundedDrainRecordCount(
                maximumRecordCount.intValue
            )
            let payload = session.drain(maximumRecordCount: count)
            guard let data = try? JSONEncoder().encode(payload) else {
                reply(NSData(), TraceHelperStatus.encodingFailed as NSString)
                return
            }
            reply(data as NSData, TraceHelperStatus.ready as NSString)
        }
    }

    func stopTrace(
        sessionID: NSString,
        withReply reply: @escaping (NSString) -> Void
    ) {
        queue.async {
            guard let session = self.session, session.id == sessionID as String else {
                reply(TraceHelperStatus.invalidSession as NSString)
                return
            }
            session.stop()
            self.session = nil
            reply(TraceHelperStatus.stopped as NSString)
        }
    }
}

private final class TraceHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = TraceHelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }

        connection.exportedInterface = NSXPCInterface(with: TraceHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak service] in
            service?.clientDisconnected()
        }
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
