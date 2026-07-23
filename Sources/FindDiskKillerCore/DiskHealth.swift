import Darwin
import Foundation
import Observation

public struct UInt128Value: Comparable, Hashable, Sendable {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.high == rhs.high ? lhs.low < rhs.low : lhs.high < rhs.high
    }

    public func subtracting(_ other: Self) -> Self? {
        guard self >= other else { return nil }
        if low >= other.low {
            return Self(high: high - other.high, low: low - other.low)
        }
        return Self(high: high - other.high - 1, low: low &- other.low)
    }

    public func multipliedReportingOverflow(by factor: UInt64) -> (value: Self, overflow: Bool) {
        let lowProduct = low.multipliedFullWidth(by: factor)
        let highProduct = high.multipliedReportingOverflow(by: factor)
        let combinedHigh = highProduct.partialValue.addingReportingOverflow(lowProduct.high)
        return (
            Self(high: combinedHigh.partialValue, low: lowProduct.low),
            highProduct.overflow || combinedHigh.overflow
        )
    }

    public var approximateDouble: Double {
        Double(high) * 18_446_744_073_709_551_616 + Double(low)
    }
}

public enum DiskHealthConnectionKind: Equatable, Sendable {
    case externalNVMe
    case nvme
    case reported
    case unavailable
}

public struct DiskHealthSnapshot: Identifiable, Sendable {
    public let bsdName: String
    public let model: String
    public let connection: String?
    public let connectionKind: DiskHealthConnectionKind
    public let capacity: UInt64?
    public let isSolidState: Bool?
    public let smartStatus: String?
    public let criticalWarning: UInt64?
    public let dataUnitsRead: UInt128Value?
    public let dataUnitsWritten: UInt128Value?
    public let percentageUsed: UInt64?
    public let availableSpare: UInt64?
    public let availableSpareThreshold: UInt64?
    public let temperatureCelsius: Double?
    public let powerOnHours: UInt128Value?
    public let powerCycles: UInt128Value?
    public let unsafeShutdowns: UInt128Value?
    public let mediaErrors: UInt128Value?
    public let errorLogEntries: UInt128Value?
    public let sampledAt: Date
    public let source: String

    public var id: String { bsdName }

    public var hostBytesWritten: Double? {
        dataUnitsWritten.map { $0.approximateDouble * 512_000 }
    }

    public var hostBytesRead: Double? {
        dataUnitsRead.map { $0.approximateDouble * 512_000 }
    }

    public var hasDetailedMetrics: Bool {
        dataUnitsRead != nil || dataUnitsWritten != nil || percentageUsed != nil
            || availableSpare != nil || availableSpareThreshold != nil
            || temperatureCelsius != nil || powerOnHours != nil || powerCycles != nil
            || unsafeShutdowns != nil || mediaErrors != nil || errorLogEntries != nil
            || criticalWarning != nil
    }

    public var assessment: DiskHealthAssessment {
        if smartStatus?.lowercased().contains("fail") == true { return .criticalSMART }
        if let criticalWarning, criticalWarning & 0x02 != 0 {
            return .temperatureWarning
        }
        if let criticalWarning, criticalWarning & 0x1f != 0 {
            return .criticalDeviceWarning
        }
        if let criticalWarning, criticalWarning & ~UInt64(0x1f) != 0 {
            return .partial
        }
        if let availableSpare, let availableSpareThreshold,
           availableSpare < availableSpareThreshold {
            return .spareBelowThreshold
        }
        if let mediaErrors, mediaErrors.high > 0 || mediaErrors.low > 0 {
            return .mediaErrors
        }
        if smartStatus?.caseInsensitiveCompare("Verified") == .orderedSame {
            return .verified
        }
        return .partial
    }
}

public enum DiskHealthAssessment: Equatable, Sendable {
    case criticalSMART
    case criticalDeviceWarning
    case temperatureWarning
    case spareBelowThreshold
    case mediaErrors
    case verified
    case partial
}

public enum DiskHealthProviderError: Error, Sendable {
    case invalidDevice
    case launchFailed
    case timedOut
    case commandFailed(Int32)
    case outputTooLarge
    case malformedOutput
}

public protocol DiskHealthProviding: Sendable {
    func snapshot(for bsdName: String) async throws -> DiskHealthSnapshot
}

public protocol DiskHealthCommandRunning: Sendable {
    func runDiskutil(
        bsdName: String,
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> Data
}

public actor DiskutilHealthProvider: DiskHealthProviding {
    private let timeout: Duration
    private let maximumOutputBytes: Int
    private let runner: any DiskHealthCommandRunning

    public init(
        timeout: Duration = .seconds(5),
        maximumOutputBytes: Int = 1_048_576,
        runner: any DiskHealthCommandRunning = DiskutilCommandRunner()
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.runner = runner
    }

    public func snapshot(for bsdName: String) async throws -> DiskHealthSnapshot {
        guard isWholeDiskIdentifier(bsdName) else {
            throw DiskHealthProviderError.invalidDevice
        }
        let data = try await runner.runDiskutil(
            bsdName: bsdName,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        return try DiskHealthParser.parse(data: data, bsdName: bsdName, sampledAt: Date())
    }
}

public actor DiskutilCommandRunner: DiskHealthCommandRunning {
    public init() {}

    public func runDiskutil(
        bsdName: String,
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> Data {
        try await runDiskutilInfo(
            identifier: bsdName,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    func runDiskutilInfo(
        identifier: String,
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> Data {
        try await run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["info", "-plist", identifier],
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    func runForTesting(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> Data {
        try await run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let runState = DiskutilRunState()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DiskHealthProviderError.launchFailed
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var data = Data()
                    for try await byte in output.fileHandleForReading.bytes {
                        data.append(byte)
                        if data.count > maximumOutputBytes {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit()
                            throw DiskHealthProviderError.outputTooLarge
                        }
                    }
                    process.waitUntilExit()
                    if runState.didTimeOut {
                        throw DiskHealthProviderError.timedOut
                    }
                    guard process.terminationStatus == 0 else {
                        throw DiskHealthProviderError.commandFailed(process.terminationStatus)
                    }
                    return data
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    runState.markTimedOut()
                    if process.isRunning { process.terminate() }
                    try? await Task.sleep(for: .milliseconds(200))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw DiskHealthProviderError.timedOut
                }
                guard let data = try await group.next() else {
                    throw DiskHealthProviderError.malformedOutput
                }
                group.cancelAll()
                return data
            }
        } onCancel: {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class DiskutilRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }
}

public enum DiskHealthParser {
    public static func parse(
        data: Data,
        bsdName: String,
        sampledAt: Date
    ) throws -> DiskHealthSnapshot {
        guard isWholeDiskIdentifier(bsdName),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = propertyList as? [String: Any]
        else { throw DiskHealthProviderError.malformedOutput }

        let deviceIdentifier = dictionary["DeviceIdentifier"] as? String
        let wholeDisk = dictionary["WholeDisk"] as? Bool
        guard deviceIdentifier == bsdName, wholeDisk == true else {
            throw DiskHealthProviderError.malformedOutput
        }

        let connection = dictionary["BusProtocol"] as? String
        let deviceTreePath = dictionary["DeviceTreePath"] as? String
        let details = dictionary["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"]
            as? [String: Any]
        let isNVMeSemantics = hasNVMeSemantics(
            busProtocol: connection,
            deviceTreePath: deviceTreePath
        )
        let connectionKind: DiskHealthConnectionKind
        if isNVMeSemantics,
           hasNVMeController(in: deviceTreePath),
           dictionary["Internal"] as? Bool == false {
            connectionKind = .externalNVMe
        } else if isNVMeSemantics {
            connectionKind = .nvme
        } else if connection != nil {
            connectionKind = .reported
        } else {
            connectionKind = .unavailable
        }

        return DiskHealthSnapshot(
            bsdName: bsdName,
            model: (dictionary["MediaName"] as? String)
                ?? (dictionary["IORegistryEntryName"] as? String)
                ?? bsdName,
            connection: connection,
            connectionKind: connectionKind,
            capacity: unsignedInteger(dictionary["TotalSize"] ?? dictionary["Size"]),
            isSolidState: dictionary["SolidState"] as? Bool,
            smartStatus: dictionary["SMARTStatus"] as? String,
            criticalWarning: isNVMeSemantics
                ? boundedUnsigned(details?["CRITICAL_WARNING"], maximum: 255)
                : nil,
            dataUnitsRead: isNVMeSemantics ? wideCounter("DATA_UNITS_READ", in: details) : nil,
            dataUnitsWritten: isNVMeSemantics ? wideCounter("DATA_UNITS_WRITTEN", in: details) : nil,
            percentageUsed: isNVMeSemantics
                ? boundedUnsigned(details?["PERCENTAGE_USED"], maximum: 255)
                : nil,
            availableSpare: isNVMeSemantics
                ? boundedUnsigned(details?["AVAILABLE_SPARE"], maximum: 100)
                : nil,
            availableSpareThreshold: isNVMeSemantics
                ? boundedUnsigned(details?["AVAILABLE_SPARE_THRESHOLD"], maximum: 100)
                : nil,
            temperatureCelsius: temperature(in: details, hasNVMeSemantics: isNVMeSemantics),
            powerOnHours: isNVMeSemantics ? wideCounter("POWER_ON_HOURS", in: details) : nil,
            powerCycles: isNVMeSemantics ? wideCounter("POWER_CYCLES", in: details) : nil,
            unsafeShutdowns: isNVMeSemantics
                ? wideCounter("UNSAFE_SHUTDOWNS", in: details)
                : nil,
            mediaErrors: isNVMeSemantics ? wideCounter("MEDIA_ERRORS", in: details) : nil,
            errorLogEntries: isNVMeSemantics
                ? wideCounter("NUM_ERROR_INFO_LOG_ENTRIES", in: details)
                : nil,
            sampledAt: sampledAt,
            source: "diskutil -plist"
        )
    }

    public static func hasNVMeSemantics(
        busProtocol: String?,
        deviceTreePath: String?
    ) -> Bool {
        if let busProtocol {
            let value = busProtocol.lowercased()
            if value.contains("nvme") || value.contains("apple fabric") {
                return true
            }
        }
        return hasNVMeController(in: deviceTreePath)
    }

    private static func hasNVMeController(in deviceTreePath: String?) -> Bool {
        deviceTreePath?.range(
            of: "IONVMeController",
            options: [.caseInsensitive]
        ) != nil
    }

    private static func wideCounter(
        _ key: String,
        in dictionary: [String: Any]?
    ) -> UInt128Value? {
        guard let low = unsignedInteger(dictionary?["\(key)_0"]),
              let high = unsignedInteger(dictionary?["\(key)_1"])
        else { return nil }
        return UInt128Value(high: high, low: low)
    }

    private static func temperature(
        in dictionary: [String: Any]?,
        hasNVMeSemantics: Bool
    ) -> Double? {
        guard hasNVMeSemantics,
              let kelvin = unsignedInteger(dictionary?["TEMPERATURE"]),
              (250...400).contains(kelvin)
        else { return nil }
        return Double(kelvin) - 273.15
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let text = number.stringValue
        guard !text.hasPrefix("-"), !text.contains("."), !text.lowercased().contains("e") else {
            return nil
        }
        return UInt64(text)
    }

    private static func boundedUnsigned(_ value: Any?, maximum: UInt64) -> UInt64? {
        guard let result = unsignedInteger(value), result <= maximum else { return nil }
        return result
    }
}

public enum DiskHealthState: Sendable {
    case idle
    case loading(previous: DiskHealthSnapshot?)
    case available(DiskHealthSnapshot)
    case unsupported(DiskHealthSnapshot)
    case failed(previous: DiskHealthSnapshot?)
    case disconnected(previous: DiskHealthSnapshot?)

    public var snapshot: DiskHealthSnapshot? {
        switch self {
        case .loading(let value), .failed(let value), .disconnected(let value): value
        case .available(let value), .unsupported(let value): value
        case .idle: nil
        }
    }
}

@MainActor
@Observable
public final class DiskHealthStore {
    public private(set) var states: [String: DiskHealthState] = [:]
    private let provider: any DiskHealthProviding
    private var lastRequestedAt: [String: Date] = [:]
    private var deviceInstances: [String: UInt64] = [:]
    private var requestGenerations: [String: UInt64] = [:]

    public init(provider: any DiskHealthProviding = DiskutilHealthProvider()) {
        self.provider = provider
    }

    public func state(for bsdName: String) -> DiskHealthState {
        states[bsdName] ?? .idle
    }

    public func refresh(devices: [DiskHealthDeviceReference], force: Bool = false) async {
        let current = Set(devices.map(\.bsdName))
        for (name, state) in states where !current.contains(name) {
            requestGenerations[name, default: 0] &+= 1
            states[name] = .disconnected(previous: state.snapshot)
        }

        for device in devices.sorted(by: { $0.bsdName < $1.bsdName }) {
            let bsdName = device.bsdName
            if let oldInstance = deviceInstances[bsdName], oldInstance != device.registryID {
                requestGenerations[bsdName, default: 0] &+= 1
                states[bsdName] = .idle
                lastRequestedAt.removeValue(forKey: bsdName)
            }
            deviceInstances[bsdName] = device.registryID
            if case .disconnected = states[bsdName] {
                lastRequestedAt.removeValue(forKey: bsdName)
            }
            let previous = states[bsdName]?.snapshot
            if case .loading = states[bsdName] { continue }
            if !force, let last = lastRequestedAt[bsdName], Date().timeIntervalSince(last) < 30 {
                continue
            }
            lastRequestedAt[bsdName] = Date()
            states[bsdName] = .loading(previous: previous)
            requestGenerations[bsdName, default: 0] &+= 1
            let generation = requestGenerations[bsdName, default: 0]
            let registryID = device.registryID
            do {
                let snapshot = try await provider.snapshot(for: bsdName)
                guard deviceInstances[bsdName] == registryID,
                      requestGenerations[bsdName] == generation
                else { continue }
                states[bsdName] = snapshot.smartStatus == nil && !snapshot.hasDetailedMetrics
                    ? .unsupported(snapshot)
                    : .available(snapshot)
            } catch {
                guard deviceInstances[bsdName] == registryID,
                      requestGenerations[bsdName] == generation
                else { continue }
                states[bsdName] = .failed(previous: previous)
            }
        }
    }
}

public struct DiskHealthDeviceReference: Hashable, Sendable {
    public let bsdName: String
    public let registryID: UInt64

    public init(bsdName: String, registryID: UInt64) {
        self.bsdName = bsdName
        self.registryID = registryID
    }
}

func isWholeDiskIdentifier(_ value: String) -> Bool {
    guard value.hasPrefix("disk"), value.count > 4 else { return false }
    return value.dropFirst(4).allSatisfy(\.isNumber)
}
