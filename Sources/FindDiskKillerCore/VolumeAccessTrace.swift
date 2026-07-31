import Foundation

public enum VolumeAccessTraceOperationCategory: Equatable, Sendable {
    case metadata
    case read
    case write
}

public struct VolumeAccessTraceParsedEvent: Equatable, Sendable {
    public let timestamp: Date
    public let operation: String
    public let category: VolumeAccessTraceOperationCategory
    public let requestedBytes: UInt64?
    public let fileDescriptor: Int32?
    public let path: String?
    public let pathWasTruncated: Bool
    public let processLabel: String
    public let threadID: UInt64
}

public enum VolumeAccessTraceLineResult: Equatable, Sendable {
    case event(VolumeAccessTraceParsedEvent)
    case ignored
    case failedCall
    case unsupportedFormat
}

public enum VolumeAccessTraceParser {
    private static let readCalls: Set<String> = [
        "read", "pread", "readv", "preadv",
        "read_nocancel", "pread_nocancel", "readv_nocancel", "preadv_nocancel"
    ]
    private static let writeCalls: Set<String> = [
        "write", "pwrite", "writev", "pwritev",
        "write_nocancel", "pwrite_nocancel", "writev_nocancel", "pwritev_nocancel"
    ]
    private static let metadataCalls: Set<String> = [
        "access", "eaccess", "faccessat", "fsgetpath",
        "getattrlist", "getattrlistat", "getattrlistbulk",
        "getdirentries", "getdirentries64", "getxattr", "listxattr",
        "lstat", "lstat64", "open", "open_nocancel", "openat", "openat_nocancel",
        "readlink", "readlinkat", "searchfs", "stat", "stat64", "statfs"
    ]

    public static func parse(
        line: String,
        on day: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> VolumeAccessTraceLineResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        if FileAccessTraceParser.recognizesHeader(trimmed) { return .ignored }

        let fields = trimmed.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard fields.count >= 4 else { return .ignored }
        guard let timestamp = parseTimestamp(fields[0], on: day, calendar: calendar) else {
            return fields[0].first?.isNumber == true ? .unsupportedFormat : .ignored
        }

        let operation = normalizedOperation(fields[1])
        let category: VolumeAccessTraceOperationCategory
        if readCalls.contains(operation) {
            category = .read
        } else if writeCalls.contains(operation) {
            category = .write
        } else if metadataCalls.contains(operation) {
            category = .metadata
        } else {
            return .ignored
        }

        if containsStandaloneErrno(fields: fields) { return .failedCall }

        let byteIndex = fields.firstIndex(where: { $0.hasPrefix("B=") })
        let requestedBytes = byteIndex.flatMap {
            parseUnsigned(String(fields[$0].dropFirst(2)))
        }
        if category == .read || category == .write, requestedBytes == nil {
            return .unsupportedFormat
        }

        let fileDescriptor = fields.first(where: { $0.hasPrefix("F=") })
            .flatMap { parseFileDescriptor(String($0.dropFirst(2))) }

        guard let durationIndex = fields.indices.reversed().first(where: {
                $0 > 1 && $0 < fields.count - 1 && isDuration(fields[$0])
              })
        else { return .unsupportedFormat }

        let processField = fields[(durationIndex + 1)...]
            .filter { $0 != "W" }
            .joined(separator: " ")
        guard let process = parseProcessField(processField) else {
            return .unsupportedFormat
        }

        let detailFields = fields[2..<durationIndex]
        let path = parsePath(from: Array(detailFields))

        return .event(VolumeAccessTraceParsedEvent(
            timestamp: timestamp,
            operation: operation,
            category: category,
            requestedBytes: requestedBytes,
            fileDescriptor: fileDescriptor,
            path: path.value,
            pathWasTruncated: path.wasTruncated,
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

    private static func parsePath(from fields: [String]) -> (value: String?, wasTruncated: Bool) {
        guard let start = fields.firstIndex(where: {
            $0.hasPrefix("/") || $0.hasPrefix("private/")
                || $0.hasPrefix("...") || $0.hasPrefix("<truncated>")
        }) else {
            return (nil, false)
        }
        let pathFields = fields[start...].filter {
            !$0.hasPrefix("(") && $0 != "W" && !isMetadata($0)
        }
        var rawPath = pathFields.joined(separator: " ")
        if rawPath.hasPrefix("private/") {
            rawPath = "/" + rawPath
        }
        let wasTruncated = rawPath.hasPrefix("...") || rawPath.hasPrefix("<truncated>")
        return (!wasTruncated && rawPath.hasPrefix("/")) ? (rawPath, false) : (nil, wasTruncated)
    }

    private static func parseUnsigned(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }

    private static func parseFileDescriptor(_ value: String) -> Int32? {
        guard let parsed = parseUnsigned(value), parsed <= UInt64(Int32.max) else { return nil }
        return Int32(parsed)
    }

    private static func containsStandaloneErrno(fields: [String]) -> Bool {
        guard fields.count > 2 else { return false }
        for index in 2..<fields.count where fields[index].hasPrefix("F=")
            || fields[index].hasPrefix("B=") {
            var candidate = fields[index]
            var nextIndex: Int
            if !candidate.contains("[") {
                guard index + 1 < fields.count,
                      fields[index + 1].hasPrefix("[")
                else { continue }
                candidate = fields[index + 1]
                nextIndex = index + 2
            } else {
                candidate = String(candidate[candidate.firstIndex(of: "[")!...])
                nextIndex = index + 1
            }
            while !candidate.contains("]"), nextIndex < fields.count,
                  nextIndex <= index + 2 {
                candidate += " " + fields[nextIndex]
                nextIndex += 1
            }
            guard candidate.first == "[", candidate.last == "]" else { continue }
            let code = candidate.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            if !code.isEmpty, code.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
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

    private static func isMetadata(_ value: String) -> Bool {
        if ["A=", "B=", "D=", "F=", "O=", "S="].contains(where: { value.hasPrefix($0) }) {
            return true
        }
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
            return false
        }
        return value[..<equals].allSatisfy { $0.isASCII && $0.isUppercase }
    }
}

public struct VolumeAccessTraceTarget: Equatable, Sendable {
    public let volumeID: String
    public let name: String
    public let mountPath: String
    public let isCaseSensitive: Bool

    public init(
        volumeID: String,
        name: String,
        mountPath: String,
        isCaseSensitive: Bool = true
    ) {
        self.volumeID = volumeID
        self.name = name
        self.mountPath = URL(fileURLWithPath: mountPath).standardizedFileURL.path
        self.isCaseSensitive = isCaseSensitive
    }

    public init(volume: VolumeInfo, isCaseSensitive: Bool = true) {
        self.init(
            volumeID: volume.id,
            name: volume.name,
            mountPath: volume.mountPath,
            isCaseSensitive: isCaseSensitive
        )
    }

    public func contains(path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = mountPath
        let equals: (String, String) -> Bool = isCaseSensitive
            ? { $0 == $1 }
            : { $0.caseInsensitiveCompare($1) == .orderedSame }
        let hasPrefix: (String, String) -> Bool = isCaseSensitive
            ? { $0.hasPrefix($1) }
            : { $0.lowercased().hasPrefix($1.lowercased()) }
        if equals(root, "/") { return true }
        if equals(candidate, root) { return true }
        return candidate.count > root.count
            && hasPrefix(candidate, root + "/")
    }
}

public struct VolumeAccessTraceProcessReference: Hashable, Sendable {
    public let pid: Int32?
    public let startAbstime: UInt64?
    public let displayName: String

    public init(pid: Int32?, startAbstime: UInt64?, displayName: String) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.displayName = displayName
    }

    public var stableID: String {
        if let pid, let startAbstime {
            return "\(pid):\(startAbstime)"
        }
        return "label:\(displayName)"
    }
}

public struct VolumeAccessTraceEvent: Equatable, Sendable {
    public let timestamp: Date
    public let operation: String
    public let category: VolumeAccessTraceOperationCategory
    public let requestedBytes: UInt64?
    public let path: String
    public let process: VolumeAccessTraceProcessReference

    public init(
        timestamp: Date,
        operation: String,
        category: VolumeAccessTraceOperationCategory,
        requestedBytes: UInt64?,
        path: String,
        process: VolumeAccessTraceProcessReference
    ) {
        self.timestamp = timestamp
        self.operation = operation
        self.category = category
        self.requestedBytes = requestedBytes
        self.path = path
        self.process = process
    }
}

public struct VolumeAccessTraceSourceSummary: Identifiable, Equatable, Sendable {
    public let process: VolumeAccessTraceProcessReference
    public let firstEventAt: Date
    public let lastEventAt: Date
    public let firstOperation: String
    public let samplePath: String
    public let metadataEventCount: Int
    public let readEventCount: Int
    public let writeEventCount: Int
    public let requestedReadBytes: UInt64
    public let requestedWriteBytes: UInt64

    public var id: String { process.stableID }
}

public struct VolumeAccessTraceEventSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let operation: String
    public let category: VolumeAccessTraceOperationCategory
    public let requestedBytes: UInt64?
    public let path: String
    public let process: VolumeAccessTraceProcessReference
}

public struct VolumeAccessTraceSnapshot: Equatable, Sendable {
    public let coverage: FileAccessTraceCoverage
    public let firstEventAt: Date?
    public let lastEventAt: Date?
    public let requestedReadBytes: UInt64?
    public let requestedWriteBytes: UInt64?
    public let metadataEventCount: Int?
    public let sources: [VolumeAccessTraceSourceSummary]
    public let events: [VolumeAccessTraceEventSummary]
}

public struct VolumeAccessTraceAggregator: Sendable {
    private struct SourceTotals: Sendable {
        var firstEventAt: Date?
        var lastEventAt: Date?
        var firstOperation = ""
        var samplePath = ""
        var metadataEvents = 0
        var readEvents = 0
        var writeEvents = 0
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
    }

    private let target: VolumeAccessTraceTarget
    private let startedAt: Date
    private let maximumSources: Int
    private let maximumEvents: Int
    private var readBytes: UInt64 = 0
    private var writeBytes: UInt64 = 0
    private var metadataEvents = 0
    private var firstEventAt: Date?
    private var lastEventAt: Date?
    private var sources: [VolumeAccessTraceProcessReference: SourceTotals] = [:]
    private var events: [VolumeAccessTraceEventSummary] = []
    private var droppedEventCount: UInt64 = 0
    private var formatIsUnsupported = false

    public init(
        target: VolumeAccessTraceTarget,
        startedAt: Date,
        maximumSources: Int = 512,
        maximumEvents: Int = 240
    ) {
        self.target = target
        self.startedAt = startedAt
        self.maximumSources = max(1, maximumSources)
        self.maximumEvents = max(1, maximumEvents)
    }

    public mutating func ingest(_ event: VolumeAccessTraceEvent) {
        guard !formatIsUnsupported, event.timestamp >= startedAt else {
            markDroppedEvents()
            return
        }
        guard target.contains(path: event.path) else { return }

        switch event.category {
        case .metadata:
            metadataEvents += 1
        case .read:
            guard let requestedBytes = event.requestedBytes,
                  let updated = adding(readBytes, requestedBytes)
            else {
                formatIsUnsupported = true
                return
            }
            readBytes = updated
        case .write:
            guard let requestedBytes = event.requestedBytes,
                  let updated = adding(writeBytes, requestedBytes)
            else {
                formatIsUnsupported = true
                return
            }
            writeBytes = updated
        }

        firstEventAt = min(firstEventAt ?? event.timestamp, event.timestamp)
        lastEventAt = max(lastEventAt ?? event.timestamp, event.timestamp)

        if sources[event.process] == nil, sources.count >= maximumSources {
            markDroppedEvents()
        } else {
            var totals = sources[event.process, default: SourceTotals()]
            if totals.firstEventAt == nil || event.timestamp < totals.firstEventAt! {
                totals.firstEventAt = event.timestamp
                totals.firstOperation = event.operation
                totals.samplePath = event.path
            }
            totals.lastEventAt = max(totals.lastEventAt ?? event.timestamp, event.timestamp)
            switch event.category {
            case .metadata:
                totals.metadataEvents += 1
            case .read:
                totals.readEvents += 1
                if let bytes = event.requestedBytes {
                    guard let updated = adding(totals.readBytes, bytes) else {
                        formatIsUnsupported = true
                        return
                    }
                    totals.readBytes = updated
                }
            case .write:
                totals.writeEvents += 1
                if let bytes = event.requestedBytes {
                    guard let updated = adding(totals.writeBytes, bytes) else {
                        formatIsUnsupported = true
                        return
                    }
                    totals.writeBytes = updated
                }
            }
            sources[event.process] = totals
        }

        if events.count < maximumEvents {
            events.append(VolumeAccessTraceEventSummary(
                id: "\(event.timestamp.timeIntervalSince1970):\(events.count)",
                timestamp: event.timestamp,
                operation: event.operation,
                category: event.category,
                requestedBytes: event.requestedBytes,
                path: event.path,
                process: event.process
            ))
        } else {
            markDroppedEvents()
        }
    }

    public mutating func markDroppedEvents(_ count: UInt64 = 1) {
        droppedEventCount = adding(droppedEventCount, count) ?? UInt64.max
    }

    public mutating func markUnsupportedFormat() {
        formatIsUnsupported = true
    }

    public func snapshot() -> VolumeAccessTraceSnapshot {
        guard !formatIsUnsupported else {
            return VolumeAccessTraceSnapshot(
                coverage: .unsupportedFormat,
                firstEventAt: firstEventAt,
                lastEventAt: lastEventAt,
                requestedReadBytes: nil,
                requestedWriteBytes: nil,
                metadataEventCount: nil,
                sources: [],
                events: []
            )
        }
        let coverage: FileAccessTraceCoverage = droppedEventCount == 0
            ? .complete
            : .partial(droppedEventCount: droppedEventCount)
        return VolumeAccessTraceSnapshot(
            coverage: coverage,
            firstEventAt: firstEventAt,
            lastEventAt: lastEventAt,
            requestedReadBytes: readBytes,
            requestedWriteBytes: writeBytes,
            metadataEventCount: metadataEvents,
            sources: sources.compactMap { process, totals in
                guard let first = totals.firstEventAt,
                      let last = totals.lastEventAt
                else { return nil }
                return VolumeAccessTraceSourceSummary(
                    process: process,
                    firstEventAt: first,
                    lastEventAt: last,
                    firstOperation: totals.firstOperation,
                    samplePath: totals.samplePath,
                    metadataEventCount: totals.metadataEvents,
                    readEventCount: totals.readEvents,
                    writeEventCount: totals.writeEvents,
                    requestedReadBytes: totals.readBytes,
                    requestedWriteBytes: totals.writeBytes
                )
            }.sorted {
                if $0.firstEventAt != $1.firstEventAt {
                    return $0.firstEventAt < $1.firstEventAt
                }
                return $0.process.displayName.localizedStandardCompare(
                    $1.process.displayName
                ) == .orderedAscending
            },
            events: events.sorted { $0.timestamp < $1.timestamp }
        )
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
