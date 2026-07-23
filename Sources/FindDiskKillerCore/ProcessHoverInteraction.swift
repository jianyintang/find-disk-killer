import Foundation

public struct ProcessHoverInteractionState: Sendable {
    public enum EnterResult: Equatable, Sendable {
        case suppressed
        case stayed
        case changed(generation: UInt64)
    }

    public enum EndResult: Equatable, Sendable {
        case ignored
        case suppressionCleared
        case scheduleDismiss(generation: UInt64)
    }

    public private(set) var activeProcessID: String?
    public private(set) var suppressedProcessID: String?
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func enter(_ processID: String) -> EnterResult {
        if suppressedProcessID == processID {
            return .suppressed
        }
        if suppressedProcessID != nil {
            suppressedProcessID = nil
        }
        guard activeProcessID != processID else { return .stayed }

        generation &+= 1
        activeProcessID = processID
        return .changed(generation: generation)
    }

    public func publish(processID: String, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration,
              activeProcessID == processID
        else { return false }
        return true
    }

    public mutating func end(_ processID: String) -> EndResult {
        if suppressedProcessID == processID {
            suppressedProcessID = nil
            return .suppressionCleared
        }
        guard activeProcessID == processID else { return .ignored }

        generation &+= 1
        activeProcessID = nil
        return .scheduleDismiss(generation: generation)
    }

    public func dismissIfIdle(generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration,
              activeProcessID == nil
        else { return false }
        return true
    }

    public mutating func suppressUntilExit(_ processID: String) {
        generation &+= 1
        activeProcessID = nil
        suppressedProcessID = processID
    }

    public mutating func clearForSelection() {
        generation &+= 1
        activeProcessID = nil
        suppressedProcessID = nil
    }
}
