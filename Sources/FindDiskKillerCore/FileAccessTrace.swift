import Foundation

public enum FileAccessTraceDirection: Equatable, Sendable {
    case read
    case write
}

public struct FileAccessTraceProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startAbstime: UInt64
    public let displayName: String

    public init(pid: Int32, startAbstime: UInt64, displayName: String) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.displayName = displayName
    }
}

public struct FileAccessTraceParsedEvent: Equatable, Sendable {
    public let timestamp: Date
    public let operation: String
    public let direction: FileAccessTraceDirection
    public let requestedBytes: UInt64
    public let path: String?
    public let pathWasTruncated: Bool
    public let processLabel: String
    public let threadID: UInt64
}

public enum FileAccessTraceLineResult: Equatable, Sendable {
    case event(FileAccessTraceParsedEvent)
    case ignored
    case failedCall
    case unsupportedFormat
}

public enum FileAccessTraceParser {
    private static let readCalls: Set<String> = [
        "read", "pread", "readv", "preadv",
        "read_nocancel", "pread_nocancel", "readv_nocancel", "preadv_nocancel"
    ]
    private static let writeCalls: Set<String> = [
        "write", "pwrite", "writev", "pwritev",
        "write_nocancel", "pwrite_nocancel", "writev_nocancel", "pwritev_nocancel"
    ]
    private static let errnoExpression = try? NSRegularExpression(
        pattern: #"\[\s*\d+\]"#
    )

    public static func recognizesHeader(_ line: String) -> Bool {
        let value = line.uppercased()
        return value.contains("TIMESTAMP")
            && value.contains("CALL")
            && value.contains("BYTE")
            && value.contains("PATHNAME")
            && value.contains("PROCESS")
    }

    public static func parse(
        line: String,
        on day: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> FileAccessTraceLineResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        if recognizesHeader(trimmed) { return .ignored }

        let fields = trimmed.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard fields.count >= 4 else { return .ignored }
        guard let timestamp = parseTimestamp(fields[0], on: day, calendar: calendar) else {
            return fields[0].first?.isNumber == true ? .unsupportedFormat : .ignored
        }

        let operation = normalizedOperation(fields[1])
        let direction: FileAccessTraceDirection
        if readCalls.contains(operation) {
            direction = .read
        } else if writeCalls.contains(operation) {
            direction = .write
        } else {
            return .ignored
        }

        guard let byteIndex = fields.firstIndex(where: { $0.hasPrefix("B=") }),
              let requestedBytes = parseUnsigned(String(fields[byteIndex].dropFirst(2)))
        else { return .unsupportedFormat }
        if containsErrno(fields: fields, after: byteIndex) { return .failedCall }

        guard let durationIndex = fields.indices.reversed().first(where: {
                $0 > byteIndex && $0 < fields.count - 1 && isDuration(fields[$0])
              })
        else { return .unsupportedFormat }
        let processField = fields[(durationIndex + 1)...]
            .filter { $0 != "W" }
            .joined(separator: " ")
        guard let process = parseProcessField(processField) else {
            return .unsupportedFormat
        }

        let detailFields = fields[(byteIndex + 1)..<durationIndex]
        guard !detailFields.contains(where: isUnknownMetadata) else {
            return .unsupportedFormat
        }

        var pathEnd = durationIndex
        if let metadataIndex = detailFields.firstIndex(where: isTrailingMetadata) {
            pathEnd = metadataIndex
        }
        let pathFields = fields[(byteIndex + 1)..<pathEnd].filter { field in
            !(field.hasPrefix("(") && field.hasSuffix(")")) && field != "W"
        }
        let rawPath = pathFields.joined(separator: " ")
        let pathWasTruncated = rawPath.hasPrefix("...") || rawPath.hasPrefix("<truncated>")
        let path = !pathWasTruncated && rawPath.hasPrefix("/") ? rawPath : nil

        return .event(FileAccessTraceParsedEvent(
            timestamp: timestamp,
            operation: operation,
            direction: direction,
            requestedBytes: requestedBytes,
            path: path,
            pathWasTruncated: pathWasTruncated,
            processLabel: process.label,
            threadID: process.threadID
        ))
    }

    private static func normalizedOperation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        ).inverted).lowercased()
    }

    private static func parseTimestamp(
        _ value: String,
        on day: Date,
        calendar: Calendar
    ) -> Date? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute)
        else { return nil }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count == 2,
              let second = Int(secondParts[0]), (0...60).contains(second),
              !secondParts[1].isEmpty,
              secondParts[1].allSatisfy(\.isNumber),
              let fraction = Double("0." + secondParts[1])
        else { return nil }
        let start = calendar.startOfDay(for: day)
        guard let wholeSeconds = calendar.date(
            byAdding: .second,
            value: hour * 3_600 + minute * 60 + min(second, 59),
            to: start
        ) else { return nil }
        let candidate = wholeSeconds.addingTimeInterval(fraction + (second == 60 ? 1 : 0))
        let distance = candidate.timeIntervalSince(day)
        if distance > 12 * 60 * 60 {
            return calendar.date(byAdding: .day, value: -1, to: candidate)
        }
        if distance < -12 * 60 * 60 {
            return calendar.date(byAdding: .day, value: 1, to: candidate)
        }
        return candidate
    }

    private static func parseUnsigned(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }

    private static func containsErrno(fields: [String], after byteIndex: Int) -> Bool {
        guard let expression = errnoExpression else { return true }
        let start = byteIndex + 1
        guard start < fields.count else { return false }
        let end = min(fields.count, start + 2)
        let value = fields[start..<end].joined(separator: " ")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return false }
        return match.range.location == 0
    }

    private static func parseProcessField(_ value: String) -> (label: String, threadID: UInt64)? {
        guard let separator = value.lastIndex(of: "."),
              separator != value.startIndex,
              let threadID = UInt64(value[value.index(after: separator)...])
        else { return nil }
        return (String(value[..<separator]), threadID)
    }

    private static func isDuration(_ value: String) -> Bool {
        let candidate = value.hasSuffix("W") ? String(value.dropLast()) : value
        return candidate.contains(".") && Double(candidate) != nil
    }

    private static func isTrailingMetadata(_ value: String) -> Bool {
        ["A=", "D=", "O=", "S="].contains { value.hasPrefix($0) }
    }

    private static func isUnknownMetadata(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
            return false
        }
        let key = value[..<equals]
        return key.allSatisfy { $0.isASCII && $0.isUppercase }
            && !["A", "D", "O", "S"].contains(String(key))
    }
}

public enum FileAccessTraceStreamState: Equatable, Sendable {
    case awaitingHeader
    case parsing
    case unsupportedFormat
}

public struct FileAccessTraceStreamParser: Sendable {
    public private(set) var state: FileAccessTraceStreamState = .awaitingHeader

    public init() {}

    public mutating func consume(
        line: String,
        on day: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> FileAccessTraceLineResult {
        switch state {
        case .awaitingHeader:
            if FileAccessTraceParser.recognizesHeader(line) {
                state = .parsing
                return .ignored
            }
            let result = FileAccessTraceParser.parse(
                line: line,
                on: day,
                calendar: calendar
            )
            switch result {
            case .event, .failedCall:
                // fs_usage does not guarantee a header when stdout is a pipe.
                // A fully validated read/write row is an equally strong format gate.
                state = .parsing
                return result
            case .unsupportedFormat:
                state = .unsupportedFormat
                return .unsupportedFormat
            case .ignored:
                break
            }
            let uppercase = line.uppercased()
            if uppercase.contains("TIMESTAMP")
                || uppercase.contains("CALL") {
                state = .unsupportedFormat
                return .unsupportedFormat
            }
            // Valid fs_usage output often begins with unrelated filesystem calls
            // such as open or stat. Keep looking for a row whose byte semantics we
            // support instead of treating that ordering as a format error.
            return .ignored
        case .parsing:
            let result = FileAccessTraceParser.parse(
                line: line,
                on: day,
                calendar: calendar
            )
            if result == .unsupportedFormat {
                state = .unsupportedFormat
            }
            return result
        case .unsupportedFormat:
            return .unsupportedFormat
        }
    }
}

public enum FileAccessTraceTargetKind: Equatable, Sendable {
    case file
    case directory
}

public enum FileAccessTracePathMatch: Equatable, Sendable {
    case included(relativePath: String)
    case excluded
    case unverifiable
}

public enum FileAccessTraceTargetError: Error, Equatable, Sendable {
    case invalidPath
    case missingVolumeIdentity
}

public struct FileAccessTraceTarget: Equatable, Sendable {
    public let path: String
    public let resolvedPath: String?
    public let volumeIdentifier: String
    public let kind: FileAccessTraceTargetKind
    public let isCaseSensitive: Bool

    public init(
        path: String,
        resolvedPath: String? = nil,
        volumeIdentifier: String,
        kind: FileAccessTraceTargetKind,
        isCaseSensitive: Bool
    ) throws {
        guard path.hasPrefix("/"),
              resolvedPath?.hasPrefix("/") != false
        else { throw FileAccessTraceTargetError.invalidPath }
        guard !volumeIdentifier.isEmpty else {
            throw FileAccessTraceTargetError.missingVolumeIdentity
        }
        self.path = Self.normalized(path)
        self.resolvedPath = resolvedPath.map(Self.normalized)
        self.volumeIdentifier = volumeIdentifier
        self.kind = kind
        self.isCaseSensitive = isCaseSensitive
    }

    public func match(
        path eventPath: String?,
        resolvedPath eventResolvedPath: String? = nil,
        volumeIdentifier eventVolumeIdentifier: String?
    ) -> FileAccessTracePathMatch {
        guard let eventVolumeIdentifier else { return .unverifiable }
        guard eventVolumeIdentifier == volumeIdentifier else { return .excluded }
        let candidates = [eventPath, eventResolvedPath].compactMap { $0 }.map(Self.normalized)
        guard !candidates.isEmpty else { return .unverifiable }

        let roots = [path, resolvedPath].compactMap { $0 }
        for root in roots {
            for candidate in candidates {
                if let relativePath = relativePath(from: root, to: candidate) {
                    return .included(relativePath: relativePath)
                }
            }
        }
        return .excluded
    }

    private func relativePath(from root: String, to candidate: String) -> String? {
        let rootComponents = URL(fileURLWithPath: root).pathComponents
        let candidateComponents = URL(fileURLWithPath: candidate).pathComponents
        let equals: (String, String) -> Bool = isCaseSensitive
            ? { $0 == $1 }
            : { $0.caseInsensitiveCompare($1) == .orderedSame }

        switch kind {
        case .file:
            guard rootComponents.count == candidateComponents.count,
                  zip(rootComponents, candidateComponents).allSatisfy(equals)
            else { return nil }
            return candidateComponents.last ?? candidate
        case .directory:
            guard candidateComponents.count >= rootComponents.count,
                  zip(rootComponents, candidateComponents).allSatisfy(equals)
            else { return nil }
            let remainder = candidateComponents.dropFirst(rootComponents.count)
            return remainder.isEmpty ? "." : remainder.joined(separator: "/")
        }
    }

    private static func normalized(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }
}

public struct FileAccessTraceEvent: Equatable, Sendable {
    public let timestamp: Date
    public let direction: FileAccessTraceDirection
    public let requestedBytes: UInt64
    public let path: String?
    public let resolvedPath: String?
    public let volumeIdentifier: String?
    public let process: FileAccessTraceProcessIdentity?

    public init(
        timestamp: Date,
        direction: FileAccessTraceDirection,
        requestedBytes: UInt64,
        path: String?,
        resolvedPath: String? = nil,
        volumeIdentifier: String?,
        process: FileAccessTraceProcessIdentity?
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.requestedBytes = requestedBytes
        self.path = path
        self.resolvedPath = resolvedPath
        self.volumeIdentifier = volumeIdentifier
        self.process = process
    }
}

public enum FileAccessTraceCoverage: Equatable, Sendable {
    case complete
    case partial(droppedEventCount: UInt64)
    case unsupportedFormat
}

public struct FileAccessTraceFileSummary: Identifiable, Equatable, Sendable {
    public let path: String
    public let requestedReadBytes: UInt64
    public let requestedWriteBytes: UInt64
    public var id: String { path }
}

public struct FileAccessTraceProcessSummary: Identifiable, Equatable, Sendable {
    public let identity: FileAccessTraceProcessIdentity
    public let requestedReadBytes: UInt64
    public let requestedWriteBytes: UInt64
    public var id: String { "\(identity.pid):\(identity.startAbstime)" }
}

public struct FileAccessTraceSnapshot: Equatable, Sendable {
    public let coverage: FileAccessTraceCoverage
    public let requestedReadBytes: UInt64?
    public let requestedWriteBytes: UInt64?
    public let currentReadBytesPerSecond: Double?
    public let currentWriteBytesPerSecond: Double?
    public let peakReadBytesPerSecond: UInt64?
    public let peakWriteBytesPerSecond: UInt64?
    public let lastEventAt: Date?
    public let files: [FileAccessTraceFileSummary]
    public let processes: [FileAccessTraceProcessSummary]
}

public struct FileAccessTraceAggregator: Sendable {
    private struct Totals: Sendable {
        var read: UInt64 = 0
        var write: UInt64 = 0
    }

    private static let bucketsPerSecond: Double = 4
    private let target: FileAccessTraceTarget
    private let startedAt: Date
    private let maximumRateBuckets: Int
    private let maximumFiles: Int
    private let maximumProcesses: Int
    private var totals = Totals()
    private var rateBuckets: [Int64: Totals] = [:]
    private var secondBuckets: [Int64: Totals] = [:]
    private var peakRead: UInt64 = 0
    private var peakWrite: UInt64 = 0
    private var files: [String: Totals] = [:]
    private var processes: [FileAccessTraceProcessIdentity: Totals] = [:]
    private var lastEventAt: Date?
    private var droppedEventCount: UInt64 = 0
    private var formatIsUnsupported = false

    public init(
        target: FileAccessTraceTarget,
        startedAt: Date,
        maximumRateBuckets: Int = 3_604,
        maximumFiles: Int = 4_096,
        maximumProcesses: Int = 1_024
    ) {
        self.target = target
        self.startedAt = startedAt
        self.maximumRateBuckets = max(20, maximumRateBuckets)
        self.maximumFiles = max(1, maximumFiles)
        self.maximumProcesses = max(1, maximumProcesses)
    }

    public mutating func ingest(_ event: FileAccessTraceEvent) {
        guard !formatIsUnsupported, event.timestamp >= startedAt else {
            markDroppedEvents()
            return
        }
        switch target.match(
            path: event.path,
            resolvedPath: event.resolvedPath,
            volumeIdentifier: event.volumeIdentifier
        ) {
        case .included:
            break
        case .excluded:
            return
        case .unverifiable:
            markDroppedEvents()
            return
        }

        guard add(event.requestedBytes, direction: event.direction, to: &totals) else {
            formatIsUnsupported = true
            return
        }

        let rateKey = Int64(floor(
            event.timestamp.timeIntervalSince1970 * Self.bucketsPerSecond
        ))
        var rateBucket = rateBuckets[rateKey, default: Totals()]
        guard add(event.requestedBytes, direction: event.direction, to: &rateBucket) else {
            formatIsUnsupported = true
            return
        }
        rateBuckets[rateKey] = rateBucket
        trimRateBuckets()

        let secondKey = Int64(floor(event.timestamp.timeIntervalSince1970))
        var secondBucket = secondBuckets[secondKey, default: Totals()]
        guard add(event.requestedBytes, direction: event.direction, to: &secondBucket) else {
            formatIsUnsupported = true
            return
        }
        secondBuckets[secondKey] = secondBucket
        peakRead = max(peakRead, secondBucket.read)
        peakWrite = max(peakWrite, secondBucket.write)
        if secondBuckets.count > 2 {
            secondBuckets = secondBuckets.filter { $0.key >= secondKey - 1 }
        }

        var hasCoverageGap = false
        if let path = event.path {
            if files[path] != nil || files.count < maximumFiles {
                var file = files[path, default: Totals()]
                guard add(event.requestedBytes, direction: event.direction, to: &file) else {
                    formatIsUnsupported = true
                    return
                }
                files[path] = file
            } else {
                hasCoverageGap = true
            }
        }

        if let process = event.process {
            if processes[process] != nil || processes.count < maximumProcesses {
                var processTotals = processes[process, default: Totals()]
                guard add(
                    event.requestedBytes,
                    direction: event.direction,
                    to: &processTotals
                ) else {
                    formatIsUnsupported = true
                    return
                }
                processes[process] = processTotals
            } else {
                hasCoverageGap = true
            }
        } else {
            hasCoverageGap = true
        }
        if hasCoverageGap {
            markDroppedEvents()
        }
        lastEventAt = max(lastEventAt ?? event.timestamp, event.timestamp)
    }

    public mutating func markDroppedEvents(_ count: UInt64 = 1) {
        droppedEventCount = adding(droppedEventCount, count) ?? UInt64.max
    }

    public mutating func markUnsupportedFormat() {
        formatIsUnsupported = true
    }

    public func snapshot(at date: Date) -> FileAccessTraceSnapshot {
        guard !formatIsUnsupported else {
            return FileAccessTraceSnapshot(
                coverage: .unsupportedFormat,
                requestedReadBytes: nil,
                requestedWriteBytes: nil,
                currentReadBytesPerSecond: nil,
                currentWriteBytesPerSecond: nil,
                peakReadBytesPerSecond: nil,
                peakWriteBytesPerSecond: nil,
                lastEventAt: lastEventAt,
                files: [],
                processes: []
            )
        }

        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let windowDuration = min(5, elapsed)
        let lowerKey = Int64(ceil(
            (date.timeIntervalSince1970 - windowDuration) * Self.bucketsPerSecond
        ))
        let upperKey = Int64(floor(
            date.timeIntervalSince1970 * Self.bucketsPerSecond
        ))
        let windowTotals = rateBuckets.reduce(into: Totals()) { result, entry in
            guard (lowerKey...upperKey).contains(entry.key) else { return }
            result.read = adding(result.read, entry.value.read) ?? UInt64.max
            result.write = adding(result.write, entry.value.write) ?? UInt64.max
        }
        let coverage: FileAccessTraceCoverage = droppedEventCount == 0
            ? .complete
            : .partial(droppedEventCount: droppedEventCount)

        return FileAccessTraceSnapshot(
            coverage: coverage,
            requestedReadBytes: totals.read,
            requestedWriteBytes: totals.write,
            currentReadBytesPerSecond: windowDuration > 0
                ? Double(windowTotals.read) / windowDuration
                : 0,
            currentWriteBytesPerSecond: windowDuration > 0
                ? Double(windowTotals.write) / windowDuration
                : 0,
            peakReadBytesPerSecond: peakRead,
            peakWriteBytesPerSecond: peakWrite,
            lastEventAt: lastEventAt,
            files: files.map { path, value in
                FileAccessTraceFileSummary(
                    path: path,
                    requestedReadBytes: value.read,
                    requestedWriteBytes: value.write
                )
            }.sorted {
                ($0.requestedWriteBytes, $0.requestedReadBytes, $0.path)
                    > ($1.requestedWriteBytes, $1.requestedReadBytes, $1.path)
            },
            processes: processes.map { identity, value in
                FileAccessTraceProcessSummary(
                    identity: identity,
                    requestedReadBytes: value.read,
                    requestedWriteBytes: value.write
                )
            }.sorted {
                ($0.requestedWriteBytes, $0.requestedReadBytes, $0.id)
                    > ($1.requestedWriteBytes, $1.requestedReadBytes, $1.id)
            }
        )
    }

    private mutating func trimRateBuckets() {
        guard rateBuckets.count > maximumRateBuckets,
              let oldest = rateBuckets.keys.min()
        else { return }
        rateBuckets.removeValue(forKey: oldest)
    }

    private func add(
        _ value: UInt64,
        direction: FileAccessTraceDirection,
        to totals: inout Totals
    ) -> Bool {
        switch direction {
        case .read:
            guard let result = adding(totals.read, value) else { return false }
            totals.read = result
        case .write:
            guard let result = adding(totals.write, value) else { return false }
            totals.write = result
        }
        return true
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
