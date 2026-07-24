import Darwin
import Foundation
import Testing
import CFindDiskKillerTrace
import FindDiskKillerTraceProtocol
@testable import FindDiskKillerCore

private actor SwitchingDiskHealthProvider: DiskHealthProviding {
    private var shouldFail = false

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func snapshot(for bsdName: String) async throws -> DiskHealthSnapshot {
        if shouldFail { throw DiskHealthProviderError.launchFailed }
        return fixtureHealthSnapshot(bsdName: bsdName, smartStatus: "Verified")
    }
}

private actor OutOfOrderDiskHealthProvider: DiskHealthProviding {
    private var requestCount = 0

    func snapshot(for bsdName: String) async throws -> DiskHealthSnapshot {
        requestCount += 1
        let request = requestCount
        try await Task.sleep(for: request == 1 ? .milliseconds(180) : .milliseconds(10))
        return fixtureHealthSnapshot(
            bsdName: bsdName,
            model: request == 1 ? "Old Device" : "New Device",
            smartStatus: "Verified"
        )
    }
}

@Test func formatsDecimalRates() {
    #expect(ByteRateFormatter.rate(42_000_000) == "42.0 MB/s")
    #expect(ByteRateFormatter.bytes(2_400_000_000) == "2.40 GB")
}

@Test func formatsCPUPercentages() {
    #expect(PercentFormatter.cpu(0.42) == "0.42%")
    #expect(PercentFormatter.cpu(18.25) == "18.2%")
    #expect(PercentFormatter.cpu(132.8) == "133%")
}

@Test func parsesPerProcessNetworkCounters() {
    let csv = """
    ,bytes_in,bytes_out,
    Codex (Service).85249,641475,872759,
    Example, Helper.42,1200,3400,
    """
    let result = ProcessNetworkParser.parse(csv)
    #expect(result[85249]?.received == 641_475)
    #expect(result[85249]?.sent == 872_759)
    #expect(result[42]?.received == 1_200)
    #expect(result[42]?.sent == 3_400)
}

@Test func networkCounterGapDoesNotCreateRecoverySpike() {
    #expect(optionalCounterDelta(nil, 1_000) == nil)
    #expect(optionalCounterDelta(8_000, nil) == nil)
    #expect(optionalCounterDelta(8_500, 8_000) == 500)
    #expect(optionalCounterDelta(100, 8_000) == 0)
}

@Test func resolvesPartitionAndSnapshotIdentifiersToWholeDisk() {
    #expect(wholeDiskBSDName("disk0s2") == "disk0")
    #expect(wholeDiskBSDName("disk3s1s1") == "disk3")
    #expect(wholeDiskBSDName("disk4") == "disk4")
    #expect(wholeDiskBSDName("not-a-disk") == nil)
}

@Test func classifiesVirtualDiskProtocols() {
    #expect(diskProtocolIsVirtual("Virtual Interface"))
    #expect(diskProtocolIsVirtual("Disk Image"))
    #expect(diskProtocolIsVirtual("Vendor Virtual Storage"))
    #expect(!diskProtocolIsVirtual("Apple Fabric"))
    #expect(!diskProtocolIsVirtual("USB"))
}

@Test func computesFiveSecondTimeWeightedAverage() {
    let end = Date(timeIntervalSinceReferenceDate: 100)
    let samples = [
        TimedRate(timestamp: end.addingTimeInterval(-3), duration: 2, value: 10),
        TimedRate(timestamp: end, duration: 3, value: 20)
    ]
    #expect(timeWeightedAverage(samples, endingAt: end) == 16)

    let partlyOutsideWindow = TimedRate(
        timestamp: end.addingTimeInterval(-4),
        duration: 3,
        value: 100
    )
    #expect(timeWeightedAverage([partlyOutsideWindow], endingAt: end) == 100)
}

@Test func fileAccessTraceParserReadsRequestedBytesWithoutInventingPhysicalIO() throws {
    let day = Date(timeIntervalSinceReferenceDate: 50_000)
    let readLine = "12:34:56.250000 read F=3 B=0x4000 /Users/example/My Project/源文件.swift O=0x0 0.000120 W Google Chrome.9988"
    let writeLine = "12:34:57.500000 pwritev F=7 B=4096 /Users/example/My Project/output.bin O=0x20 0.000080 Builder.44"

    guard case .event(let read) = FileAccessTraceParser.parse(line: readLine, on: day),
          case .event(let write) = FileAccessTraceParser.parse(line: writeLine, on: day)
    else {
        Issue.record("Expected both controlled fs_usage fixtures to parse")
        return
    }

    #expect(read.direction == .read)
    #expect(read.requestedBytes == 16_384)
    #expect(read.fileDescriptor == 3)
    #expect(read.path == "/Users/example/My Project/源文件.swift")
    #expect(read.processLabel == "Google Chrome")
    #expect(read.threadID == 9_988)
    #expect(write.direction == .write)
    #expect(write.requestedBytes == 4_096)
    #expect(write.path == "/Users/example/My Project/output.bin")
}

@Test func fileAccessTraceDescriptorParserMaintainsOnlyCompletePaths() {
    let opened = "12:34:56.250000 open F=17 (R___________) /Users/example/My Project/file.swift 0.000120 Tool.9988"
    #expect(FileAccessTraceDescriptorParser.parse(line: opened) == .opened(
        fileDescriptor: 17,
        path: "/Users/example/My Project/file.swift"
    ))
    #expect(FileAccessTraceDescriptorParser.parse(
        line: "12:34:57.250000 close F=17 0.000010 Tool.9988"
    ) == .closed(fileDescriptor: 17))
    #expect(FileAccessTraceDescriptorParser.parse(
        line: "12:34:58.250000 open F=18 (R___________) .../file.swift 0.000010 Tool.9988"
    ) == nil)
    #expect(FileAccessTraceDescriptorParser.parse(
        line: "12:34:59.250000 open F=19 (RW_____________) private/tmp/file.bin 0.000010 Tool.9988"
    ) == .opened(fileDescriptor: 19, path: "/private/tmp/file.bin"))
}

@Test func fileAccessTraceDescriptorIndexIsolatesProcessAndFDReuse() {
    let first = FileAccessTraceProcessIdentity(pid: 42, startAbstime: 100, displayName: "Tool")
    let replacement = FileAccessTraceProcessIdentity(
        pid: 42,
        startAbstime: 200,
        displayName: "Tool"
    )
    var index = FileAccessTraceDescriptorIndex()
    index.register(path: "/tmp/first", process: first, fileDescriptor: 7)
    #expect(index.path(process: first, fileDescriptor: 7) == "/tmp/first")
    #expect(index.path(process: replacement, fileDescriptor: 7) == nil)
    index.close(process: first, fileDescriptor: 7)
    #expect(index.path(process: first, fileDescriptor: 7) == nil)
    index.register(path: "/tmp/reused", process: first, fileDescriptor: 7)
    #expect(index.path(process: first, fileDescriptor: 7) == "/tmp/reused")
}

@Test func fileAccessTraceParserDoesNotTreatBracketedPathComponentsAsErrno() {
    let day = Date(timeIntervalSinceReferenceDate: 50_000)
    let line = "12:34:56.250000 read F=3 B=64 /tmp/[123]/data.bin O=0x0 0.000120 Tool.9988"
    guard case .event(let event) = FileAccessTraceParser.parse(line: line, on: day) else {
        Issue.record("A bracketed path component must remain a successful event")
        return
    }
    #expect(event.path == "/tmp/[123]/data.bin")
    #expect(event.requestedBytes == 64)
}

@Test func traceHelperContractBoundsRequestsAndRoundTripsOptionalIdentity() throws {
    #expect(TraceHelperProtocolConfiguration.validatedDuration(9) == nil)
    #expect(TraceHelperProtocolConfiguration.validatedDuration(10) == 10)
    #expect(TraceHelperProtocolConfiguration.validatedDuration(3_600) == 3_600)
    #expect(TraceHelperProtocolConfiguration.validatedDuration(3_601) == nil)
    #expect(TraceHelperProtocolConfiguration.boundedDrainRecordCount(0) == 1)
    #expect(TraceHelperProtocolConfiguration.boundedDrainRecordCount(9_999) == 2_048)
    #expect(TraceHelperProtocolConfiguration.maximumDrainSourceBytes == 256 * 1_024)
    #expect(TraceHelperProtocolConfiguration.validatedProcessIdentifiers([1, 2, 2]) == [1, 2])
    #expect(TraceHelperProtocolConfiguration.validatedProcessIdentifiers([]) == nil)
    #expect(TraceHelperProtocolConfiguration.validatedProcessIdentifiers([0]) == nil)
    #expect(TraceHelperProtocolConfiguration.validatedProcessIdentifiers(
        Array(repeating: NSNumber(value: 1), count: 65)
    ) == nil)

    let payload = TraceHelperDrainPayload(
        records: [
            TraceHelperRecord(line: "header", process: nil),
            TraceHelperRecord(
                line: "event",
                process: TraceHelperProcessIdentity(
                    pid: 42,
                    startAbstime: 99,
                    displayName: "Builder"
                )
            )
        ],
        droppedRecordCount: 7,
        isFinished: false,
        exitCode: nil
    )
    let data = try JSONEncoder().encode(payload)
    #expect(try JSONDecoder().decode(TraceHelperDrainPayload.self, from: data) == payload)
}

@Test func traceThreadResolverUsesTheFSUsageThreadIDNamespace() {
    var threadID: UInt64 = 0
    #expect(pthread_threadid_np(nil, &threadID) == 0)
    var processIdentifier = Int32(getpid())
    var identity = FDKTraceProcessIdentity()
    let resolved = fdk_trace_resolve_thread_in_processes(
        threadID,
        &processIdentifier,
        1,
        &identity
    )
    #expect(resolved == 1)
    #expect(identity.pid == processIdentifier)
    #expect(identity.start_abstime > 0)
}

@Test func fileAccessTraceParserHandlesCallsErrorsAndCoverageGaps() {
    let day = Date(timeIntervalSinceReferenceDate: 60_000)
    let calls: [(String, FileAccessTraceDirection)] = [
        ("read", .read), ("pread", .read), ("readv", .read), ("preadv", .read),
        ("write", .write), ("pwrite", .write), ("writev", .write), ("pwritev", .write)
    ]
    for (call, direction) in calls {
        let line = "01:02:03.000001 \(call) F=4 B=32 /tmp/trace O=0x0 0.000010 Tool.7"
        guard case .event(let event) = FileAccessTraceParser.parse(line: line, on: day) else {
            Issue.record("Expected \(call) to parse")
            continue
        }
        #expect(event.direction == direction)
    }

    let failed = "01:02:03.000001 write F=4 B=32 [ 28] /tmp/trace 0.000010 Tool.7"
    #expect(FileAccessTraceParser.parse(line: failed, on: day) == .failedCall)
    let failedWithoutByteCount = "01:02:03.000001 read F=4 [ 2] 0.000010 Tool.7"
    #expect(FileAccessTraceParser.parse(line: failedWithoutByteCount, on: day) == .failedCall)
    let failedWithAttachedErrno = "01:02:03.000001 writev F=120[ 35] 0.000010 Tool.7"
    #expect(FileAccessTraceParser.parse(line: failedWithAttachedErrno, on: day) == .failedCall)
    let failedWithCompactErrno = "01:02:03.000001 read F=35 [35] 0.000010 Tool.7"
    #expect(FileAccessTraceParser.parse(line: failedWithCompactErrno, on: day) == .failedCall)

    let truncated = "01:02:03.000001 read F=4 B=32 .../tail/file 0.000010 Tool.7"
    guard case .event(let truncatedEvent) = FileAccessTraceParser.parse(
        line: truncated,
        on: day
    ) else {
        Issue.record("Expected a truncated-path event")
        return
    }
    #expect(truncatedEvent.path == nil)
    #expect(truncatedEvent.pathWasTruncated)

    let missingPath = "01:02:03.000001 read F=4 B=32 O=0x0 0.000010 Tool.7"
    guard case .event(let missingPathEvent) = FileAccessTraceParser.parse(
        line: missingPath,
        on: day
    ) else {
        Issue.record("Expected an unlocated event")
        return
    }
    #expect(missingPathEvent.path == nil)

    let malformedBytes = "01:02:03.000001 read F=4 B=unknown /tmp/trace 0.000010 Tool.7"
    #expect(FileAccessTraceParser.parse(line: malformedBytes, on: day) == .unsupportedFormat)
    let unknownColumn = "01:02:03.000001 read F=4 B=32 /tmp/trace X=7 0.000010 Tool.7"
    #expect(FileAccessTraceParser.parse(line: unknownColumn, on: day) == .unsupportedFormat)
    let longPath = "/tmp/" + String(repeating: "长目录 ", count: 80) + "file.swift"
    let longLine = "01:02:03.000001 read F=4 B=32 \(longPath) 0.000010 Tool.7"
    guard case .event(let longPathEvent) = FileAccessTraceParser.parse(
        line: longLine,
        on: day
    ) else {
        Issue.record("Expected a complete long Unicode path to parse")
        return
    }
    #expect(longPathEvent.path == longPath)
    #expect(FileAccessTraceParser.recognizesHeader(
        "TIMESTAMP CALL FILE DESCRIPTOR BYTE COUNT PATHNAME TIME PROCESS"
    ))
}

@Test func fileAccessTraceStreamAcceptsAValidatedRowWhenPipedOutputOmitsTheHeader() {
    let day = Date(timeIntervalSinceReferenceDate: 70_000)
    let line = "01:02:03.000001 read F=4 B=32 /tmp/trace 0.000010 Tool.7"
    var missingHeader = FileAccessTraceStreamParser()
    #expect(missingHeader.consume(
        line: "01:02:03.000000 open F=4 /tmp/trace 0.000005 Tool.7",
        on: day
    ) == .ignored)
    #expect(missingHeader.state == .awaitingHeader)
    guard case .event = missingHeader.consume(line: line, on: day) else {
        Issue.record("Expected a validated row to establish the piped format")
        return
    }
    #expect(missingHeader.state == .parsing)

    #expect(missingHeader.consume(
        line: "01:02:03.000002 read F=4 [ 2] 0.000010 Tool.7",
        on: day
    ) == .failedCall)
    #expect(missingHeader.state == .parsing)

    #expect(missingHeader.consume(
        line: "01:02:03.000003 read F=4 B=unknown /tmp/trace 0.000010 Tool.7",
        on: day
    ) == .unparseableEvent)
    #expect(missingHeader.state == .parsing)
    guard case .event = missingHeader.consume(line: line, on: day) else {
        Issue.record("Expected a valid row to recover after one malformed row")
        return
    }
    #expect(missingHeader.state == .parsing)

    var malformedData = FileAccessTraceStreamParser()
    #expect(malformedData.consume(
        line: "01:02:03.000001 read F=4 B=unknown /tmp/trace 0.000010 Tool.7",
        on: day
    ) == .unsupportedFormat)
    #expect(malformedData.state == .unsupportedFormat)

    var recognized = FileAccessTraceStreamParser()
    #expect(recognized.consume(line: "fs_usage fixture", on: day) == .ignored)
    #expect(recognized.consume(
        line: "TIMESTAMP CALL FILE DESCRIPTOR BYTE COUNT PATHNAME TIME PROCESS",
        on: day
    ) == .ignored)
    #expect(recognized.state == .parsing)
    guard case .event = recognized.consume(line: line, on: day) else {
        Issue.record("Expected a record after the known header")
        return
    }
}

@Test func fileAccessTraceTargetUsesVolumeAndPathComponents() throws {
    let directory = try FileAccessTraceTarget(
        path: "/Volumes/JianDisk/code",
        resolvedPath: "/System/Volumes/Data/Volumes/JianDisk/code",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: true
    )
    #expect(directory.match(
        path: "/Volumes/JianDisk/code/project/file.swift",
        volumeIdentifier: "volume-a"
    ) == .included(relativePath: "project/file.swift"))
    #expect(directory.match(
        path: "/Volumes/JianDisk/code-other/file.swift",
        volumeIdentifier: "volume-a"
    ) == .excluded)
    #expect(directory.match(
        path: "/Volumes/JianDisk/code/file.swift",
        volumeIdentifier: "volume-b"
    ) == .excluded)
    #expect(directory.match(
        path: "/Volumes/JianDisk/code/file.swift",
        volumeIdentifier: nil
    ) == .unverifiable)
    #expect(directory.match(
        path: "/private/var/empty",
        resolvedPath: "/System/Volumes/Data/Volumes/JianDisk/code/link-target",
        volumeIdentifier: "volume-a"
    ) == .included(relativePath: "link-target"))

    let file = try FileAccessTraceTarget(
        path: "/tmp/Report.txt",
        volumeIdentifier: "volume-c",
        kind: .file,
        isCaseSensitive: false
    )
    #expect(file.match(
        path: "/tmp/report.TXT",
        volumeIdentifier: "volume-c"
    ) == .included(relativePath: "report.TXT"))
    #expect(file.match(
        path: "/tmp/report.TXT.backup",
        volumeIdentifier: "volume-c"
    ) == .excluded)
    #expect(throws: FileAccessTraceTargetError.invalidPath) {
        try FileAccessTraceTarget(
            path: "relative/path",
            volumeIdentifier: "volume-c",
            kind: .file,
            isCaseSensitive: true
        )
    }
}

@Test func codexFSUsageFixtureResolvesFDAndContinuesAfterAttachedErrno() throws {
    let day = Date(timeIntervalSinceReferenceDate: 60_000)
    let process = FileAccessTraceProcessIdentity(
        pid: 85_623,
        startAbstime: 123,
        displayName: "codex"
    )
    let target = try FileAccessTraceTarget(
        path: "/Volumes/JianDisk/.codex-cc/sessions/2026/07/23",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: true
    )
    var descriptors = FileAccessTraceDescriptorIndex()
    descriptors.register(
        path: "/Volumes/JianDisk/.codex-cc/sessions/2026/07/23/rollout.jsonl",
        process: process,
        fileDescriptor: 39
    )
    var parser = FileAccessTraceStreamParser()
    let lines = [
        "14:10:45.100000 pread F=39 B=0x1000 O=0x1000 0.000002 codex.51508301",
        "14:10:45.200000 writev F=120[ 35] 0.000001 codex.49781806",
        "14:10:45.300000 pwrite F=39 B=0x40 O=0x2000 0.000003 codex.51508301"
    ]
    var events: [FileAccessTraceParsedEvent] = []
    for line in lines {
        switch parser.consume(line: line, on: day) {
        case .event(let event):
            events.append(event)
        case .failedCall:
            continue
        default:
            Issue.record("Unexpected parser result for Codex fixture: \(line)")
        }
    }
    #expect(parser.state == .parsing)
    #expect(events.count == 2)

    var aggregator = FileAccessTraceAggregator(
        target: target,
        startedAt: (events.first?.timestamp ?? day).addingTimeInterval(-1)
    )
    for event in events {
        let path = event.path ?? event.fileDescriptor.flatMap {
            descriptors.path(process: process, fileDescriptor: $0)
        }
        aggregator.ingest(FileAccessTraceEvent(
            timestamp: event.timestamp,
            direction: event.direction,
            requestedBytes: event.requestedBytes,
            path: path,
            volumeIdentifier: "volume-a",
            process: process
        ))
    }
    let snapshot = aggregator.snapshot(
        at: (events.last?.timestamp ?? day).addingTimeInterval(1)
    )
    #expect(snapshot.coverage == .complete)
    #expect(snapshot.requestedReadBytes == 4_096)
    #expect(snapshot.requestedWriteBytes == 64)
    #expect(snapshot.files.first?.path.hasSuffix("rollout.jsonl") == true)
}

@Test func fileAccessTraceAggregatorSeparatesReadWriteFilesAndProcessSessions() throws {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let target = try FileAccessTraceTarget(
        path: "/work",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: true
    )
    let firstSession = FileAccessTraceProcessIdentity(
        pid: 42,
        startAbstime: 10,
        displayName: "Builder"
    )
    let replacementSession = FileAccessTraceProcessIdentity(
        pid: 42,
        startAbstime: 20,
        displayName: "Builder"
    )
    var aggregator = FileAccessTraceAggregator(target: target, startedAt: start)
    aggregator.ingest(traceEvent(
        at: start.addingTimeInterval(0.1),
        direction: .read,
        bytes: 100,
        path: "/work/a.swift",
        process: firstSession
    ))
    aggregator.ingest(traceEvent(
        at: start.addingTimeInterval(0.6),
        direction: .write,
        bytes: 200,
        path: "/work/b.o",
        process: firstSession
    ))
    aggregator.ingest(traceEvent(
        at: start.addingTimeInterval(1.1),
        direction: .write,
        bytes: 300,
        path: "/work/b.o",
        process: replacementSession
    ))

    let snapshot = aggregator.snapshot(at: start.addingTimeInterval(2))
    #expect(snapshot.coverage == .complete)
    #expect(snapshot.requestedReadBytes == 100)
    #expect(snapshot.requestedWriteBytes == 500)
    #expect(snapshot.currentReadBytesPerSecond == 50)
    #expect(snapshot.currentWriteBytesPerSecond == 250)
    #expect(snapshot.peakReadBytesPerSecond == 100)
    #expect(snapshot.peakWriteBytesPerSecond == 300)
    #expect(snapshot.files.first?.path == "/work/b.o")
    #expect(snapshot.files.first?.requestedWriteBytes == 500)
    #expect(snapshot.processes.count == 2)
    #expect(Set(snapshot.processes.map(\.identity.startAbstime)) == [10, 20])
}

@Test func fileAccessTraceAggregatorMakesGapsAndFormatFailuresExplicit() throws {
    let start = Date(timeIntervalSinceReferenceDate: 2_000)
    let target = try FileAccessTraceTarget(
        path: "/work",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: true
    )
    var aggregator = FileAccessTraceAggregator(
        target: target,
        startedAt: start,
        maximumFiles: 1
    )
    aggregator.ingest(traceEvent(
        at: start.addingTimeInterval(0.1),
        direction: .write,
        bytes: 10,
        path: "/work/a",
        process: nil
    ))
    aggregator.ingest(traceEvent(
        at: start.addingTimeInterval(0.2),
        direction: .write,
        bytes: 20,
        path: "/work/b",
        process: FileAccessTraceProcessIdentity(pid: 8, startAbstime: 1, displayName: "Tool")
    ))
    aggregator.ingest(FileAccessTraceEvent(
        timestamp: start.addingTimeInterval(0.3),
        direction: .read,
        requestedBytes: 100,
        path: nil,
        volumeIdentifier: nil,
        process: nil
    ))

    let partial = aggregator.snapshot(at: start.addingTimeInterval(1))
    #expect(partial.coverage == .partial(droppedEventCount: 3))
    #expect(partial.requestedWriteBytes == 30)
    #expect(partial.requestedReadBytes == 0)
    #expect(partial.files.count == 1)

    aggregator.markUnsupportedFormat()
    let unsupported = aggregator.snapshot(at: start.addingTimeInterval(1))
    #expect(unsupported.coverage == .unsupportedFormat)
    #expect(unsupported.requestedReadBytes == nil)
    #expect(unsupported.requestedWriteBytes == nil)
    #expect(unsupported.currentReadBytesPerSecond == nil)
    #expect(unsupported.files.isEmpty)
}

@Test func fileAccessTraceAggregatorKeepsDetailsBoundedDuringAnEventStorm() throws {
    let start = Date(timeIntervalSinceReferenceDate: 3_000)
    let target = try FileAccessTraceTarget(
        path: "/work",
        volumeIdentifier: "volume-a",
        kind: .directory,
        isCaseSensitive: true
    )
    var aggregator = FileAccessTraceAggregator(
        target: target,
        startedAt: start,
        maximumRateBuckets: 20,
        maximumFiles: 8,
        maximumProcesses: 4
    )
    for index in 0..<20_000 {
        aggregator.ingest(traceEvent(
            at: start.addingTimeInterval(Double(index) / 4),
            direction: .write,
            bytes: 1,
            path: "/work/file-\(index)",
            process: FileAccessTraceProcessIdentity(
                pid: Int32(index),
                startAbstime: UInt64(index),
                displayName: "Process \(index)"
            )
        ))
    }

    let snapshot = aggregator.snapshot(at: start.addingTimeInterval(5_000))
    #expect(snapshot.requestedWriteBytes == 20_000)
    #expect(snapshot.files.count == 8)
    #expect(snapshot.processes.count == 4)
    #expect(snapshot.coverage == .partial(droppedEventCount: 19_996))
}

@MainActor
@Test func systemAndProcessNetworkGapsRemainUnavailableUntilRebased() async {
    let store = MonitorStore()
    let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
    var processNetworkAvailability: [Bool] = []

    for index in 0..<5 {
        let networkAvailable = index != 2
        let cpuAvailable = index != 2
        let networkTotal: UInt64? = networkAvailable ? UInt64(1_000 + index * 100) : nil
        store.ingest(SystemSnapshot(
            date: baseDate.addingTimeInterval(Double(index)),
            uptime: Double(index + 1),
            processes: [RawProcessCounter(
                pid: 42,
                startAbstime: 7,
                name: "fixture",
                path: "/usr/bin/fixture",
                cpuTimeNanoseconds: UInt64(index + 1) * 10_000_000,
                bytesRead: UInt64(index) * 100,
                bytesWritten: UInt64(index) * 200,
                networkBytesReceived: networkTotal,
                networkBytesSent: networkTotal
            )],
            disks: [],
            volumes: [],
            cpuUserTicks: UInt64(index + 1) * 10,
            cpuSystemTicks: UInt64(index + 1) * 5,
            cpuNiceTicks: 0,
            cpuIdleTicks: UInt64(index + 1) * 85,
            networkInterfaces: networkAvailable ? [RawNetworkInterfaceCounter(
                index: 1,
                name: "en0",
                bytesReceived: UInt64(1_000 + index * 100),
                bytesSent: UInt64(2_000 + index * 100)
            )] : [],
            cpuStatsAvailable: cpuAvailable,
            networkInterfacesAvailable: networkAvailable,
            processNetworkAvailable: networkAvailable
        ))
        await store.waitForPendingProcessSummary()
        processNetworkAvailability.append(store.processes.first?.isNetworkAvailable ?? false)
    }

    #expect(store.systemPoints.map(\.networkReceiveBytesPerSecond) == [nil, 100, nil, nil, 100])
    #expect(store.systemPoints.map(\.networkSegment) == [0, 1, 1, 1, 2])
    #expect(store.systemPoints.map(\.cpuPercent) == [nil, 15, nil, nil, 15])
    #expect(store.systemPoints.map(\.cpuSegment) == [0, 1, 1, 1, 2])
    let processMetrics = store.processes.first?.metrics ?? []
    #expect(processMetrics.map(\.networkReceiveBytesPerSecond) == [100, nil, nil, 100])
    #expect(processMetrics.map(\.networkSegment) == [1, 1, 1, 2])
    #expect(processNetworkAvailability == [false, true, false, false, true])
}

@MainActor
@Test func processCurrentRatesClipSamplesAtFiveSecondBoundary() async {
    let store = MonitorStore()
    let baseDate = Date(timeIntervalSinceReferenceDate: 1_500)
    let fixtures: [(time: TimeInterval, bytes: UInt64, cpu: UInt64)] = [
        (0, 0, 0),
        (3, 30, 300_000_000),
        (6, 90, 900_000_000)
    ]

    for fixture in fixtures {
        store.ingest(SystemSnapshot(
            date: baseDate.addingTimeInterval(fixture.time),
            uptime: fixture.time + 1,
            processes: [RawProcessCounter(
                pid: 43,
                startAbstime: 8,
                name: "weighted-fixture",
                path: "/usr/bin/weighted-fixture",
                cpuTimeNanoseconds: fixture.cpu,
                bytesRead: fixture.bytes,
                bytesWritten: fixture.bytes,
                networkBytesReceived: fixture.bytes,
                networkBytesSent: fixture.bytes
            )],
            disks: [],
            volumes: [],
            cpuUserTicks: 0,
            cpuSystemTicks: 0,
            cpuNiceTicks: 0,
            cpuIdleTicks: 0,
            networkInterfaces: [],
            cpuStatsAvailable: false,
            networkInterfacesAvailable: false,
            processNetworkAvailable: true
        ))
        await store.waitForPendingProcessSummary()
    }

    let process = store.processes.first
    #expect(process?.currentWriteBytesPerSecond == 16)
    #expect(process?.currentCPUPercent == 16)
    #expect(process?.currentNetworkReceiveBytesPerSecond == 16)
    #expect(process?.isNetworkAvailable == true)
}

@MainActor
@Test func virtualDisksDoNotContributeToPhysicalThroughput() {
    let store = MonitorStore()
    let baseDate = Date(timeIntervalSinceReferenceDate: 2_000)

    for index in 0..<2 {
        store.ingest(SystemSnapshot(
            date: baseDate.addingTimeInterval(Double(index)),
            uptime: Double(index + 1),
            processes: [],
            disks: [RawDiskCounter(
                registryID: 99,
                name: "Disk Image",
                bytesRead: UInt64(index) * 1_000_000,
                bytesWritten: UInt64(index) * 2_000_000,
                readOperations: UInt64(index),
                writeOperations: UInt64(index),
                capacity: 1_000_000,
                bsdName: "disk99",
                isPhysical: false
            )],
            volumes: [],
            cpuUserTicks: 0,
            cpuSystemTicks: 0,
            cpuNiceTicks: 0,
            cpuIdleTicks: 0,
            networkInterfaces: [],
            cpuStatsAvailable: false,
            networkInterfacesAvailable: false,
            processNetworkAvailable: false
        ))
    }

    #expect(!store.isDiskAvailable)
    #expect(store.points.last?.writeBytesPerSecond == nil)
}

@Test func samplerIncludesCallingProcess() async {
    let snapshot = await SystemSampler.shared.collect()
    #expect(snapshot.processes.contains { $0.pid == getpid() })
}

@Test func samplerPublishesMountedVolumeMetadataOnItsFirstCollection() async {
    let sampler = SystemSampler()
    let snapshot = await sampler.collect()

    #expect(snapshot.volumes.contains { $0.mountPath == "/" })
}

@Test func samplerReportsProcessCPUInActivityMonitorUnits() async {
    let first = await SystemSampler.shared.collect()
    guard let firstProcess = first.processes.first(where: { $0.pid == getpid() }) else {
        Issue.record("Calling process was not visible in the first sample")
        return
    }

    let workStarted = Date()
    var checksum: UInt64 = 0
    while Date().timeIntervalSince(workStarted) < 0.3 {
        checksum &+= 1
    }

    let second = await SystemSampler.shared.collect()
    guard let secondProcess = second.processes.first(where: {
        $0.pid == getpid() && $0.startAbstime == firstProcess.startAbstime
    }) else {
        Issue.record("Calling process was not visible in the second sample")
        return
    }

    let elapsed = second.date.timeIntervalSince(first.date)
    let cpuDelta = secondProcess.cpuTimeNanoseconds - firstProcess.cpuTimeNanoseconds
    let cpuPercent = Double(cpuDelta) / elapsed / 1_000_000_000 * 100
    #expect(checksum > 0)
    #expect(cpuPercent > 25)
}

@Test func openFileSamplerFindsAReadOnlyFileHeldByTheCurrentProcess() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("find-disk-killer-open-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fixture.txt")
    try Data("fixture".utf8).write(to: file)
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let writeFile = directory.appendingPathComponent("write.txt")
    let readWriteFile = directory.appendingPathComponent("read-write.txt")
    try Data().write(to: writeFile)
    try Data().write(to: readWriteFile)
    let writeFD = Darwin.open(writeFile.path, O_WRONLY)
    let readWriteFD = Darwin.open(readWriteFile.path, O_RDWR)
    let eventFD = Darwin.open(directory.path, O_EVTONLY)
    #expect(writeFD >= 0)
    #expect(readWriteFD >= 0)
    #expect(eventFD >= 0)
    defer {
        if writeFD >= 0 { Darwin.close(writeFD) }
        if readWriteFD >= 0 { Darwin.close(readWriteFD) }
        if eventFD >= 0 { Darwin.close(eventFD) }
    }

    let system = await SystemSampler.shared.collect()
    guard let process = system.processes.first(where: { $0.pid == getpid() }) else {
        Issue.record("Calling process was not visible")
        return
    }
    let sampler = OpenFileSampler(budget: .init(
        maximumProcesses: 1,
        maximumFilesPerProcess: 1_024,
        maximumDuration: .seconds(1)
    ))
    let snapshot = await sampler.sample(sessions: [ProcessSession(
        pid: process.pid,
        startAbstime: process.startAbstime
    )])
    let expectedPath = file.resolvingSymlinksInPath().path
    let record = snapshot.records.first(where: {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == expectedPath
    })

    #expect(record != nil)
    #expect(record?.accessMode == .readOnly)
    #expect(snapshot.records.first(where: {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
            == writeFile.resolvingSymlinksInPath().path
    })?.accessMode == .writeOnly)
    #expect(snapshot.records.first(where: {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
            == readWriteFile.resolvingSymlinksInPath().path
    })?.accessMode == .readWrite)
    #expect(snapshot.records.first(where: {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
            == directory.resolvingSymlinksInPath().path
    })?.accessMode == .eventOnly)
    #expect(snapshot.state == .complete)
}

@Test func openFileSamplerMarksAnFDBoundedScanAsPartial() async {
    let descriptors = (0..<64).compactMap { _ -> Int32? in
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        return descriptor >= 0 ? descriptor : nil
    }
    defer { descriptors.forEach { Darwin.close($0) } }
    let system = await SystemSampler.shared.collect()
    guard let process = system.processes.first(where: { $0.pid == getpid() }) else {
        Issue.record("Calling process was not visible")
        return
    }
    let sampler = OpenFileSampler(budget: .init(
        maximumProcesses: 1,
        maximumFilesPerProcess: 8,
        maximumDuration: .seconds(1)
    ))
    let snapshot = await sampler.sample(sessions: [ProcessSession(
        pid: process.pid,
        startAbstime: process.startAbstime
    )])

    #expect(snapshot.budgetLimited)
    #expect(snapshot.state == .partial)
    #expect(snapshot.records.count <= 8)
}

@Test func openFileSamplerRejectsAReusedProcessIdentity() async {
    let system = await SystemSampler.shared.collect()
    guard let process = system.processes.first(where: { $0.pid == getpid() }) else {
        Issue.record("Calling process was not visible")
        return
    }
    let sampler = OpenFileSampler()
    let snapshot = await sampler.sample(sessions: [ProcessSession(
        pid: process.pid,
        startAbstime: process.startAbstime &+ 1
    )])
    #expect(snapshot.state == .processEnded)
    #expect(snapshot.records.isEmpty)
}

@Test func openFileBudgetSanitizesInvalidPublicLimits() {
    let budget = OpenFileSampler.Budget(
        maximumProcesses: -1,
        maximumFilesPerProcess: -1,
        maximumDuration: .milliseconds(-1)
    )
    #expect(budget.maximumProcesses == 0)
    #expect(budget.maximumFilesPerProcess == 1)
    #expect(budget.maximumDuration == .zero)
}

@Test func uint128CountersSubtractAndMultiplyWithoutLosingTheHighWord() {
    let value = UInt128Value(high: 3, low: 2)
    let previous = UInt128Value(high: 2, low: UInt64.max)
    #expect(value.subtracting(previous) == UInt128Value(high: 0, low: 3))

    let product = UInt128Value(high: 0, low: UInt64.max)
        .multipliedReportingOverflow(by: 2)
    #expect(product.value == UInt128Value(high: 1, low: UInt64.max - 1))
    #expect(!product.overflow)

    let overflow = UInt128Value(high: UInt64.max, low: 0)
        .multipliedReportingOverflow(by: 2)
    #expect(overflow.overflow)
}

@Test func diskHealthParserUsesOptionalCapabilitiesAndNVMeSemantics() throws {
    let sampledAt = Date(timeIntervalSinceReferenceDate: 9_000)
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk9",
            "WholeDisk": true,
            "MediaName": "Fixture SSD",
            "BusProtocol": "Apple Fabric",
            "TotalSize": UInt64(1_000_000_000_000),
            "SolidState": true,
            "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "DATA_UNITS_WRITTEN_0": UInt64(9_260_388),
                "DATA_UNITS_WRITTEN_1": UInt64(0),
                "PERCENTAGE_USED": UInt64(0),
                "CRITICAL_WARNING": UInt64(2),
                "TEMPERATURE": UInt64(322),
                "MEDIA_ERRORS_0": UInt64(0),
                "MEDIA_ERRORS_1": UInt64(0)
            ]
        ],
        format: .binary,
        options: 0
    )
    let snapshot = try DiskHealthParser.parse(
        data: data,
        bsdName: "disk9",
        sampledAt: sampledAt
    )

    #expect(snapshot.model == "Fixture SSD")
    #expect(snapshot.connectionKind == .nvme)
    #expect(snapshot.dataUnitsWritten == UInt128Value(high: 0, low: 9_260_388))
    #expect(snapshot.percentageUsed == 0)
    #expect(snapshot.criticalWarning == 2)
    #expect(snapshot.assessment == .temperatureWarning)
    #expect(abs((snapshot.temperatureCelsius ?? 0) - 48.85) < 0.001)
    #expect(snapshot.mediaErrors == UInt128Value(high: 0, low: 0))
    #expect(snapshot.sampledAt == sampledAt)
}

@Test func diskHealthParserRecognizesExternalNVMeBehindThunderbolt() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk4",
            "WholeDisk": true,
            "MediaName": "Acer SSD N3500CN 2TB",
            "BusProtocol": "PCI-Express",
            "DeviceTreePath": "IODeviceTree:/arm-io/usb-drd1/IONVMeController/IOBlockStorageDriver",
            "Internal": false,
            "TotalSize": UInt64(2_000_398_934_016),
            "SolidState": true,
            "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "CRITICAL_WARNING": UInt64(0),
                "DATA_UNITS_READ_0": UInt64(1_560_000),
                "DATA_UNITS_READ_1": UInt64(0),
                "DATA_UNITS_WRITTEN_0": UInt64(1_271_484),
                "DATA_UNITS_WRITTEN_1": UInt64(0),
                "PERCENTAGE_USED": UInt64(0),
                "AVAILABLE_SPARE": UInt64(100),
                "AVAILABLE_SPARE_THRESHOLD": UInt64(10),
                "TEMPERATURE": UInt64(313),
                "POWER_ON_HOURS_0": UInt64(34),
                "POWER_ON_HOURS_1": UInt64(0),
                "POWER_CYCLES_0": UInt64(3),
                "POWER_CYCLES_1": UInt64(0),
                "UNSAFE_SHUTDOWNS_0": UInt64(1),
                "UNSAFE_SHUTDOWNS_1": UInt64(0),
                "MEDIA_ERRORS_0": UInt64(0),
                "MEDIA_ERRORS_1": UInt64(0),
                "NUM_ERROR_INFO_LOG_ENTRIES_0": UInt64(0),
                "NUM_ERROR_INFO_LOG_ENTRIES_1": UInt64(0)
            ]
        ],
        format: .binary,
        options: 0
    )
    let snapshot = try DiskHealthParser.parse(
        data: data,
        bsdName: "disk4",
        sampledAt: Date()
    )

    #expect(DiskHealthParser.hasNVMeSemantics(
        busProtocol: "PCI-Express",
        deviceTreePath: "IODeviceTree:/bridge/ionvmecontroller/device"
    ))
    #expect(snapshot.connection == "PCI-Express")
    #expect(snapshot.connectionKind == .externalNVMe)
    #expect(snapshot.dataUnitsRead == UInt128Value(high: 0, low: 1_560_000))
    #expect(snapshot.dataUnitsWritten == UInt128Value(high: 0, low: 1_271_484))
    #expect(snapshot.percentageUsed == 0)
    #expect(snapshot.availableSpare == 100)
    #expect(snapshot.availableSpareThreshold == 10)
    #expect(abs((snapshot.temperatureCelsius ?? 0) - 39.85) < 0.001)
    #expect(snapshot.powerOnHours == UInt128Value(high: 0, low: 34))
    #expect(snapshot.powerCycles == UInt128Value(high: 0, low: 3))
    #expect(snapshot.unsafeShutdowns == UInt128Value(high: 0, low: 1))
    #expect(snapshot.mediaErrors == UInt128Value(high: 0, low: 0))
    #expect(snapshot.errorLogEntries == UInt128Value(high: 0, low: 0))
    #expect(snapshot.hostBytesRead == 798_720_000_000)
    #expect(snapshot.hostBytesWritten == 650_999_808_000)
}

@Test func diskHealthParserDoesNotTreatPlainPCIExpressAsNVMe() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk5",
            "WholeDisk": true,
            "BusProtocol": "PCI-Express",
            "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "DATA_UNITS_WRITTEN_0": UInt64(100),
                "DATA_UNITS_WRITTEN_1": UInt64(0),
                "TEMPERATURE": UInt64(313),
                "PERCENTAGE_USED": UInt64(4)
            ]
        ],
        format: .binary,
        options: 0
    )
    let snapshot = try DiskHealthParser.parse(
        data: data,
        bsdName: "disk5",
        sampledAt: Date()
    )

    #expect(!DiskHealthParser.hasNVMeSemantics(
        busProtocol: "PCI-Express",
        deviceTreePath: nil
    ))
    #expect(snapshot.connectionKind == .reported)
    #expect(snapshot.dataUnitsWritten == nil)
    #expect(snapshot.temperatureCelsius == nil)
    #expect(snapshot.percentageUsed == nil)
}

@Test func diskHealthParserRejectsMissingOrMalformedNVMeFields() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk8",
            "WholeDisk": true,
            "BusProtocol": "NVMe",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "DATA_UNITS_READ_0": "120",
                "DATA_UNITS_READ_1": UInt64(0),
                "AVAILABLE_SPARE": UInt64(101),
                "TEMPERATURE": UInt64(249),
                "POWER_CYCLES_0": UInt64(3)
            ]
        ],
        format: .binary,
        options: 0
    )
    let snapshot = try DiskHealthParser.parse(
        data: data,
        bsdName: "disk8",
        sampledAt: Date()
    )

    #expect(snapshot.connectionKind == .nvme)
    #expect(snapshot.dataUnitsRead == nil)
    #expect(snapshot.dataUnitsWritten == nil)
    #expect(snapshot.availableSpare == nil)
    #expect(snapshot.temperatureCelsius == nil)
    #expect(snapshot.powerCycles == nil)
}

@Test func diskHealthCapabilitiesIncludeNonHeadlineCounters() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk6",
            "WholeDisk": true,
            "MediaName": "Counter Fixture",
            "BusProtocol": "Apple Fabric",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "POWER_CYCLES_0": UInt64(3),
                "POWER_CYCLES_1": UInt64(0)
            ]
        ],
        format: .binary,
        options: 0
    )
    let snapshot = try DiskHealthParser.parse(
        data: data,
        bsdName: "disk6",
        sampledAt: Date()
    )
    #expect(snapshot.powerCycles == UInt128Value(high: 0, low: 3))
    #expect(snapshot.hasDetailedMetrics)
}

@Test func diskHealthParserDoesNotInventMissingValuesOrUnknownTemperatureUnits() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk7",
            "WholeDisk": true,
            "MediaName": "USB Fixture",
            "BusProtocol": "USB",
            "SolidState": true,
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "TEMPERATURE": UInt64(322),
                "PERCENTAGE_USED": "0",
                "DATA_UNITS_WRITTEN_0": UInt64(100),
                "DATA_UNITS_WRITTEN_1": UInt64(0)
            ]
        ],
        format: .binary,
        options: 0
    )
    let snapshot = try DiskHealthParser.parse(
        data: data,
        bsdName: "disk7",
        sampledAt: Date()
    )

    #expect(snapshot.smartStatus == nil)
    #expect(snapshot.temperatureCelsius == nil)
    #expect(snapshot.percentageUsed == nil)
    #expect(snapshot.dataUnitsWritten == nil)
    #expect(!snapshot.hasDetailedMetrics)
}

@Test func diskHealthAssessmentNeverUsesAHealthyResultForFailureOrUnknownStatus() {
    #expect(fixtureHealthSnapshot(smartStatus: "Verified").assessment == .verified)
    #expect(fixtureHealthSnapshot(smartStatus: "Failing").assessment == .criticalSMART)
    #expect(fixtureHealthSnapshot(smartStatus: "Unknown").assessment == .partial)
    #expect(fixtureHealthSnapshot(smartStatus: nil).assessment == .partial)
    #expect(fixtureHealthSnapshot(
        smartStatus: "Verified",
        criticalWarning: 0x02
    ).assessment == .temperatureWarning)
    #expect(fixtureHealthSnapshot(
        smartStatus: "Verified",
        criticalWarning: 0x04
    ).assessment == .criticalDeviceWarning)
    #expect(fixtureHealthSnapshot(
        smartStatus: "Verified",
        criticalWarning: 0x80
    ).assessment == .partial)
    #expect(fixtureHealthSnapshot(
        smartStatus: "Verified",
        availableSpare: 8,
        availableSpareThreshold: 10
    ).assessment == .spareBelowThreshold)
    #expect(fixtureHealthSnapshot(
        smartStatus: "Verified",
        mediaErrors: UInt128Value(high: 0, low: 1)
    ).assessment == .mediaErrors)
}

@MainActor
@Test func diskHealthStoreDoesNotReuseASnapshotWhenBSDNameChangesDeviceInstance() async {
    let provider = SwitchingDiskHealthProvider()
    let store = DiskHealthStore(provider: provider)
    await store.refresh(devices: [DiskHealthDeviceReference(
        bsdName: "disk8",
        registryID: 100
    )], force: true)
    #expect(store.state(for: "disk8").snapshot != nil)

    await store.refresh(devices: [], force: true)
    await provider.setShouldFail(true)
    await store.refresh(devices: [DiskHealthDeviceReference(
        bsdName: "disk8",
        registryID: 200
    )], force: true)

    if case .failed(let previous) = store.state(for: "disk8") {
        #expect(previous == nil)
    } else {
        Issue.record("Expected a failed state for the replacement device")
    }
}

@MainActor
@Test func staleDiskHealthRequestCannotOverwriteAReplacementDevice() async {
    let provider = OutOfOrderDiskHealthProvider()
    let store = DiskHealthStore(provider: provider)
    let oldRequest = Task {
        await store.refresh(devices: [DiskHealthDeviceReference(
            bsdName: "disk8",
            registryID: 100
        )], force: true)
    }
    try? await Task.sleep(for: .milliseconds(25))
    let newRequest = Task {
        await store.refresh(devices: [DiskHealthDeviceReference(
            bsdName: "disk8",
            registryID: 200
        )], force: true)
    }
    await newRequest.value
    await oldRequest.value

    #expect(store.state(for: "disk8").snapshot?.model == "New Device")
}

@MainActor
@Test func reconnectedDiskBypassesTheRefreshThrottle() async {
    let store = DiskHealthStore(provider: SwitchingDiskHealthProvider())
    let device = DiskHealthDeviceReference(bsdName: "disk8", registryID: 100)
    await store.refresh(devices: [device], force: true)
    await store.refresh(devices: [])
    await store.refresh(devices: [device])

    if case .available = store.state(for: "disk8") {
        // Expected.
    } else {
        Issue.record("Expected the reconnected device to refresh immediately")
    }
}

@Test func diskutilRunnerEnforcesOutputAndTimeoutLimits() async {
    let runner = DiskutilCommandRunner()
    do {
        _ = try await runner.runForTesting(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            timeout: .seconds(2),
            maximumOutputBytes: 1_024
        )
        Issue.record("Expected output limit failure")
    } catch DiskHealthProviderError.outputTooLarge {
        // Expected.
    } catch {
        Issue.record("Unexpected output-limit error: \(error)")
    }

    let clock = ContinuousClock()
    let started = clock.now
    do {
        _ = try await runner.runForTesting(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: .milliseconds(100),
            maximumOutputBytes: 1_024
        )
        Issue.record("Expected timeout")
    } catch DiskHealthProviderError.timedOut {
        #expect(started.duration(to: clock.now) < .seconds(1))
    } catch {
        Issue.record("Unexpected timeout error: \(error)")
    }
}

@Test func diskHealthParserRejectsPartitionsAndMismatchedDevices() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "DeviceIdentifier": "disk3",
            "WholeDisk": true
        ],
        format: .binary,
        options: 0
    )
    #expect(throws: DiskHealthProviderError.self) {
        try DiskHealthParser.parse(data: data, bsdName: "disk3s1", sampledAt: Date())
    }
    #expect(throws: DiskHealthProviderError.self) {
        try DiskHealthParser.parse(data: data, bsdName: "disk4", sampledAt: Date())
    }
}

@Test func fileChangeWatcherReportsChangesWithoutProcessAttribution() async throws {
    let watcher = FileChangeWatcher()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("find-disk-killer-fsevents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let volume = VolumeInfo(
        id: UUID().uuidString,
        name: "Fixture",
        mountPath: directory.path,
        totalCapacity: 1,
        availableCapacity: 1,
        isLocal: true,
        isWritable: true,
        hasStableIdentity: true,
        isRemovable: false,
        physicalDiskBSDNames: []
    )
    await watcher.configure(volumes: [volume])
    try await Task.sleep(for: .milliseconds(250))
    try Data("change".utf8).write(to: directory.appendingPathComponent("changed.txt"))
    try await Task.sleep(for: .milliseconds(1_500))
    let result = await watcher.recentChanges(for: [directory.path])
    await watcher.injectGapForTesting(volumeID: volume.id)
    let resultAfterGap = await watcher.recentChanges(for: [directory.path])
    let replacement = VolumeInfo(
        id: UUID().uuidString,
        name: "Replacement",
        mountPath: directory.path,
        totalCapacity: 1,
        availableCapacity: 1,
        isLocal: true,
        isWritable: true,
        hasStableIdentity: true,
        isRemovable: false,
        physicalDiskBSDNames: []
    )
    await watcher.configure(volumes: [replacement])
    let replacementResult = await watcher.recentChanges(for: [directory.path])
    await watcher.configure(volumes: [])

    #expect(result.observedSince != nil)
    #expect(result.latestByPath[directory.path] != nil)
    #expect(!result.hasCoverageGap)
    #expect(resultAfterGap.latestByPath[directory.path] != nil)
    #expect(resultAfterGap.hasCoverageGap)
    #expect(replacementResult.latestByPath[directory.path] == nil)
}

@Test func fileChangeWatcherKeepsStreamsUntilTheLastSessionEnds() async {
    let watcher = FileChangeWatcher()
    let directory = FileManager.default.temporaryDirectory
    let volume = fixtureVolume(id: UUID().uuidString, mountPath: directory.path)
    let firstLease = await watcher.beginSession(volumes: [volume])
    let secondLease = await watcher.beginSession(volumes: [])
    let before = await watcher.recentChanges(for: [directory.path])

    await watcher.endSession(firstLease)
    let whileSecondSessionIsActive = await watcher.recentChanges(for: [directory.path])
    await watcher.endSession(secondLease)
    let afterAllSessionsEnd = await watcher.recentChanges(for: [directory.path])

    #expect(before.observedSince != nil)
    #expect(whileSecondSessionIsActive.observedSince == before.observedSince)
    #expect(afterAllSessionsEnd.observedSince == nil)
}

@Test func recentFileChangeRetentionKeepsConfirmedChangesForTheFullWindow() {
    let now = Date(timeIntervalSinceReferenceDate: 20_000)
    let previous = now.addingTimeInterval(-30)
    let newer = now.addingTimeInterval(-10)

    #expect(RecentFileChangeRetention.retainedTimestamp(
        previous: previous,
        observed: nil,
        now: now
    ) == previous)
    #expect(RecentFileChangeRetention.retainedTimestamp(
        previous: previous,
        observed: newer,
        now: now
    ) == newer)
    #expect(RecentFileChangeRetention.retainedTimestamp(
        previous: now.addingTimeInterval(-301),
        observed: nil,
        now: now
    ) == nil)
}

@Test func fileChangeWatcherRebuildsItsBaselineAfterAGap() async throws {
    let watcher = FileChangeWatcher()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("find-disk-killer-fsevents-gap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let volumeID = UUID().uuidString
    let volume = VolumeInfo(
        id: volumeID,
        name: "Gap Fixture",
        mountPath: directory.path,
        totalCapacity: 1,
        availableCapacity: 1,
        isLocal: true,
        isWritable: true,
        hasStableIdentity: true,
        isRemovable: false,
        physicalDiskBSDNames: []
    )
    await watcher.configure(volumes: [volume])
    let before = await watcher.recentChanges(for: [directory.path])
    try await Task.sleep(for: .milliseconds(10))
    await watcher.injectGapForTesting(volumeID: volumeID)
    let after = await watcher.recentChanges(for: [directory.path])
    await watcher.configure(volumes: [])

    #expect(after.hasCoverageGap)
    #expect((after.observedSince ?? .distantPast) > (before.observedSince ?? .distantFuture))
}

@Test func fileChangeWatcherRebuildsWhenAMountPathChanges() async throws {
    let watcher = FileChangeWatcher()
    let first = FileManager.default.temporaryDirectory
        .appendingPathComponent("find-disk-killer-first-\(UUID().uuidString)", isDirectory: true)
    let second = FileManager.default.temporaryDirectory
        .appendingPathComponent("find-disk-killer-second-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let volumeID = UUID().uuidString
    let original = fixtureVolume(id: volumeID, mountPath: first.path)
    await watcher.configure(volumes: [original])
    let before = await watcher.recentChanges(for: [first.path])
    try await Task.sleep(for: .milliseconds(10))
    let moved = fixtureVolume(id: volumeID, mountPath: second.path)
    await watcher.configure(volumes: [moved])
    let oldPath = await watcher.recentChanges(for: [first.path])
    let after = await watcher.recentChanges(for: [second.path])

    #expect(oldPath.observedSince == nil)
    #expect((after.observedSince ?? .distantPast) > (before.observedSince ?? .distantFuture))
}

@Test func fileChangeWatcherMarksHistoryOverflowAsAGap() async {
    let watcher = FileChangeWatcher()
    let directory = FileManager.default.temporaryDirectory
    let volumeID = UUID().uuidString
    await watcher.configure(volumes: [fixtureVolume(id: volumeID, mountPath: directory.path)])
    let before = await watcher.recentChanges(for: [directory.path])
    await watcher.injectHistoryOverflowForTesting(volumeID: volumeID)
    let after = await watcher.recentChanges(for: [directory.path])

    #expect(after.hasCoverageGap)
    #expect((after.observedSince ?? .distantPast) >= (before.observedSince ?? .distantFuture))
}

@Test func fileChangeWatcherSkipsReadOnlyVolumes() async {
    let watcher = FileChangeWatcher()
    let directory = FileManager.default.temporaryDirectory
    var volume = fixtureVolume(id: UUID().uuidString, mountPath: directory.path)
    volume = VolumeInfo(
        id: volume.id,
        name: volume.name,
        mountPath: volume.mountPath,
        totalCapacity: volume.totalCapacity,
        availableCapacity: volume.availableCapacity,
        isLocal: true,
        isWritable: false,
        hasStableIdentity: true,
        isRemovable: false,
        physicalDiskBSDNames: []
    )
    await watcher.configure(volumes: [volume])
    let lookup = await watcher.recentChanges(for: [directory.path])
    #expect(lookup.observedSince == nil)
    #expect(lookup.statusByPath[directory.path] == .unavailable)
}

@Test func fileChangeWatcherSkipsVolumesWithoutAStableIdentity() async {
    let watcher = FileChangeWatcher()
    let directory = FileManager.default.temporaryDirectory
    let stable = fixtureVolume(id: "unidentified:\(directory.path)", mountPath: directory.path)
    let volume = VolumeInfo(
        id: stable.id,
        name: stable.name,
        mountPath: stable.mountPath,
        totalCapacity: stable.totalCapacity,
        availableCapacity: stable.availableCapacity,
        isLocal: true,
        isWritable: true,
        hasStableIdentity: false,
        isRemovable: false,
        physicalDiskBSDNames: []
    )
    await watcher.configure(volumes: [volume])
    let lookup = await watcher.recentChanges(for: [directory.path])
    #expect(lookup.observedSince == nil)
    #expect(lookup.statusByPath[directory.path] == .unavailable)
}

@Test func rootVolumeContainsOrdinaryAbsolutePaths() {
    let root = VolumeInfo(
        id: "root",
        name: "Root",
        mountPath: "/",
        totalCapacity: 1,
        availableCapacity: 1,
        isLocal: true,
        isWritable: true,
        hasStableIdentity: true,
        isRemovable: false,
        physicalDiskBSDNames: ["disk0"]
    )
    #expect(root.contains(path: "/Users/example/project"))
    #expect(root.contains(path: "/"))
    #expect(!root.contains(path: "relative/path"))
}

@Test func volumePathResolverUsesTheMostSpecificMountedVolume() {
    let root = fixtureVolume(id: "root", name: "Macintosh HD", mountPath: "/")
    let external = fixtureVolume(
        id: "external-a",
        name: "JianDisk",
        mountPath: "/Volumes/JianDisk"
    )

    let match = VolumePathResolver.bestMatch(
        for: "/Volumes/JianDisk/code/find-disk-killer",
        in: [root, external]
    )

    #expect(match?.id == external.id)
    #expect(match?.name == "JianDisk")
}

@Test func volumePathResolverDoesNotCrossPathComponentBoundaries() {
    let volume = fixtureVolume(id: "foo", name: "Foo", mountPath: "/Volumes/foo")

    #expect(VolumePathResolver.bestMatch(
        for: "/Volumes/foo/project",
        in: [volume]
    )?.id == volume.id)
    #expect(VolumePathResolver.bestMatch(
        for: "/Volumes/foobar/project",
        in: [volume]
    ) == nil)
}

@Test func volumePathResolverRecoversWhenVolumesArriveOrRemount() {
    let path = "/Volumes/JianDisk/code/find-disk-killer"
    let firstMount = fixtureVolume(
        id: "external-a",
        name: "JianDisk",
        mountPath: "/Volumes/JianDisk"
    )
    let remounted = fixtureVolume(
        id: "external-b",
        name: "JianDisk",
        mountPath: "/Volumes/JianDisk"
    )

    #expect(VolumePathResolver.bestMatch(for: path, in: []) == nil)
    #expect(VolumePathResolver.bestMatch(for: path, in: [firstMount])?.id == "external-a")
    #expect(VolumePathResolver.bestMatch(for: path, in: [remounted])?.id == "external-b")
}

@MainActor
@Test func monitorStoreKeepsKnownVolumesAcrossATransientEmptySample() {
    let store = MonitorStore()
    let external = fixtureVolume(
        id: "external-a",
        name: "JianDisk",
        mountPath: "/Volumes/JianDisk"
    )
    let remounted = fixtureVolume(
        id: "external-b",
        name: "JianDisk",
        mountPath: "/Volumes/JianDisk"
    )

    store.ingest(volumeOnlySnapshot(volumes: [], uptime: 1))
    #expect(store.volumes.isEmpty)
    store.ingest(volumeOnlySnapshot(volumes: [external], uptime: 2))
    #expect(store.volumes.map(\.id) == ["external-a"])
    store.ingest(volumeOnlySnapshot(volumes: [], uptime: 3))
    #expect(store.volumes.map(\.id) == ["external-a"])
    store.ingest(volumeOnlySnapshot(volumes: [remounted], uptime: 4))
    #expect(store.volumes.map(\.id) == ["external-b"])
}

private func fixtureHealthSnapshot(
    bsdName: String = "disk9",
    model: String = "Fixture SSD",
    smartStatus: String?,
    criticalWarning: UInt64? = nil,
    availableSpare: UInt64? = nil,
    availableSpareThreshold: UInt64? = nil,
    mediaErrors: UInt128Value? = nil
) -> DiskHealthSnapshot {
    DiskHealthSnapshot(
        bsdName: bsdName,
        model: model,
        connection: "Apple Fabric",
        connectionKind: .nvme,
        capacity: 1_000_000,
        isSolidState: true,
        smartStatus: smartStatus,
        criticalWarning: criticalWarning,
        dataUnitsRead: nil,
        dataUnitsWritten: nil,
        percentageUsed: nil,
        availableSpare: availableSpare,
        availableSpareThreshold: availableSpareThreshold,
        temperatureCelsius: nil,
        powerOnHours: nil,
        powerCycles: nil,
        unsafeShutdowns: nil,
        mediaErrors: mediaErrors,
        errorLogEntries: nil,
        sampledAt: Date(timeIntervalSinceReferenceDate: 10_000),
        source: "fixture"
    )
}

private func fixtureVolume(
    id: String,
    name: String = "Fixture",
    mountPath: String
) -> VolumeInfo {
    VolumeInfo(
        id: id,
        name: name,
        mountPath: mountPath,
        totalCapacity: 1,
        availableCapacity: 1,
        isLocal: true,
        isWritable: true,
        hasStableIdentity: true,
        isRemovable: false,
        physicalDiskBSDNames: []
    )
}

private func volumeOnlySnapshot(volumes: [VolumeInfo], uptime: TimeInterval) -> SystemSnapshot {
    SystemSnapshot(
        date: Date(timeIntervalSinceReferenceDate: uptime),
        uptime: uptime,
        processes: [],
        disks: [],
        volumes: volumes,
        cpuUserTicks: 0,
        cpuSystemTicks: 0,
        cpuNiceTicks: 0,
        cpuIdleTicks: 0,
        networkInterfaces: [],
        cpuStatsAvailable: false,
        networkInterfacesAvailable: false,
        processNetworkAvailable: false
    )
}

private func traceEvent(
    at timestamp: Date,
    direction: FileAccessTraceDirection,
    bytes: UInt64,
    path: String,
    process: FileAccessTraceProcessIdentity?
) -> FileAccessTraceEvent {
    FileAccessTraceEvent(
        timestamp: timestamp,
        direction: direction,
        requestedBytes: bytes,
        path: path,
        volumeIdentifier: "volume-a",
        process: process
    )
}

@Test func localizationResourcesStayInSync() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resources = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp/Resources", isDirectory: true)
    let locales = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko",
        "de", "fr", "es", "pt-BR", "ru"
    ]

    let base = try localizationDictionary(at: resources, locale: "zh-Hans")
    #expect(!base.isEmpty)
    for locale in locales {
        let translation = try localizationDictionary(at: resources, locale: locale)
        #expect(Set(translation.keys) == Set(base.keys), "Mismatched localization keys for \(locale)")
        for key in base.keys {
            #expect(
                formatArguments(in: translation[key] ?? "") == formatArguments(in: base[key] ?? ""),
                "Mismatched format arguments for \(locale): \(key)"
            )
        }
    }
}

private func localizationDictionary(
    at resources: URL,
    locale: String
) throws -> [String: String] {
    let url = resources
        .appendingPathComponent("\(locale).lproj", isDirectory: true)
        .appendingPathComponent("Localizable.strings")
    let data = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.openStep
    let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: &format
    )
    guard let dictionary = propertyList as? [String: String] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    return dictionary
}

private func formatArguments(in value: String) -> [String] {
    let pattern = #"%(?:\d+\$)?(@|d|%)"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        guard let capture = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[capture])
    }.sorted()
}

@Test func classifiesVerifiedCodexHost() {
    let result = ProcessClassifier.classify(
        name: "codex",
        executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"
    )
    #expect(result.displayName == "Codex")
    #expect(result.brand == .codex)
    #expect(result.brandIsVerified)
}

@Test func doesNotBrandExecutableNameAsVerified() {
    let result = ProcessClassifier.classify(
        name: "claude",
        executablePath: "/usr/local/bin/claude"
    )
    #expect(result.brand == .claude)
    #expect(!result.brandIsVerified)
    #expect(result.displayName.contains("可能关联"))
}

@Test func hoverShownAThenLeavesBBeforeDelayDoesNotRetainA() {
    var state = ProcessHoverInteractionState()
    guard case let .changed(generationA) = state.enter("A") else {
        Issue.record("A should start a hover generation")
        return
    }
    let didPublishA = state.publish(processID: "A", generation: generationA)
    #expect(didPublishA)

    guard case .changed = state.enter("B") else {
        Issue.record("B should replace A")
        return
    }
    guard case let .scheduleDismiss(generationB) = state.end("B") else {
        Issue.record("Ending B should schedule dismissal")
        return
    }
    let didDismissB = state.dismissIfIdle(generation: generationB)
    #expect(didDismissB)
}

@Test func staleEndedCannotCancelNewActiveProcess() {
    var state = ProcessHoverInteractionState()
    _ = state.enter("A")
    guard case let .changed(generationB) = state.enter("B") else {
        Issue.record("B should become active")
        return
    }
    #expect(state.end("A") == .ignored)
    #expect(state.activeProcessID == "B")
    let didPublishB = state.publish(processID: "B", generation: generationB)
    #expect(didPublishB)
}

@Test func detailDismissSuppressesOnlyTheOriginalRowUntilExit() {
    var state = ProcessHoverInteractionState()
    state.suppressUntilExit("A")
    #expect(state.enter("A") == .suppressed)
    #expect(state.end("A") == .suppressionCleared)
    #expect(state.suppressedProcessID == nil)
    guard case .changed = state.enter("A") else {
        Issue.record("A should be hoverable after exiting once")
        return
    }
}

@Test func detailDismissAllowsEnteringAnotherRowImmediately() {
    var state = ProcessHoverInteractionState()
    state.suppressUntilExit("A")
    guard case .changed = state.enter("B") else {
        Issue.record("A different row should clear suppression")
        return
    }
    #expect(state.suppressedProcessID == nil)
    #expect(state.activeProcessID == "B")
}

@Test func selectionCancelsPendingHoverGeneration() {
    var state = ProcessHoverInteractionState()
    guard case let .changed(generation) = state.enter("A") else {
        Issue.record("A should start a hover generation")
        return
    }
    state.clearForSelection()
    let didPublishAfterSelection = state.publish(processID: "A", generation: generation)
    #expect(!didPublishAfterSelection)
    #expect(state.activeProcessID == nil)
}

@Test func repeatedMoveWithinOneRowKeepsGenerationStable() {
    var state = ProcessHoverInteractionState()
    guard case let .changed(generation) = state.enter("A") else {
        Issue.record("A should start a hover generation")
        return
    }
    let didPublish = state.publish(processID: "A", generation: generation)
    #expect(didPublish)

    #expect(state.enter("A") == .stayed)
    #expect(state.generation == generation)
}

@Test func staleShowCannotPublishAfterEnteringAnotherRow() {
    var state = ProcessHoverInteractionState()
    guard case let .changed(generationA) = state.enter("A") else {
        Issue.record("A should start a hover generation")
        return
    }
    _ = state.enter("B")

    let staleShowPublished = state.publish(processID: "A", generation: generationA)
    #expect(!staleShowPublished)
    #expect(state.activeProcessID == "B")
}

@Test func staleDismissCannotClearANewerActiveRow() {
    var state = ProcessHoverInteractionState()
    _ = state.enter("A")
    guard case let .scheduleDismiss(dismissGeneration) = state.end("A") else {
        Issue.record("A should schedule dismissal")
        return
    }
    _ = state.enter("B")

    let staleDismissSucceeded = state.dismissIfIdle(generation: dismissGeneration)
    #expect(!staleDismissSucceeded)
    #expect(state.activeProcessID == "B")
}
