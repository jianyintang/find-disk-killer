import Foundation

public enum AgentStorageProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }
}

public enum AgentStorageProviderSupportStatus: String, Codable, Hashable, Sendable {
    case supported
    case partial
    case unsupportedFormat
    case noConversationSource
    case notInstalled
}

public enum AgentStorageDatabaseAttributionStatus: String, Codable, Hashable, Sendable {
    case completed
    case unsupportedFormat
    case unsupportedJournalMode
    case temporarilyBusy
    case unavailable
    case unreadable
    case ambiguousOwnership
}

public struct AgentStorageDatabaseAttributionSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let sourceID: String
    public let path: String
    public let physicalBundleBytes: UInt64
    public let attributedBytes: UInt64
    public let residualBytes: UInt64
    public let mappedEstimatedBytes: UInt64
    public let unmappedEstimatedBytes: UInt64
    public let processedRowCount: Int
    public let totalRowCount: Int
    public let status: AgentStorageDatabaseAttributionStatus
    public let diagnosticComponent: String?

    public init(
        id: String,
        provider: AgentStorageProvider,
        sourceID: String,
        path: String,
        physicalBundleBytes: UInt64,
        attributedBytes: UInt64,
        residualBytes: UInt64,
        mappedEstimatedBytes: UInt64,
        unmappedEstimatedBytes: UInt64,
        processedRowCount: Int,
        totalRowCount: Int,
        status: AgentStorageDatabaseAttributionStatus,
        diagnosticComponent: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.sourceID = sourceID
        self.path = path
        self.physicalBundleBytes = physicalBundleBytes
        self.attributedBytes = attributedBytes
        self.residualBytes = residualBytes
        self.mappedEstimatedBytes = mappedEstimatedBytes
        self.unmappedEstimatedBytes = unmappedEstimatedBytes
        self.processedRowCount = processedRowCount
        self.totalRowCount = totalRowCount
        self.status = status
        self.diagnosticComponent = diagnosticComponent
    }
}

public enum AgentStorageGlobalCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case sharedDatabase
    case sharedAgentData
    case crossAgentShared
    case runtime
    case browser
    case tools
    case cache
    case configuration
    case directoryOverhead
    case other
}

public enum AgentStorageUnattributedReason: String, CaseIterable, Codable, Hashable, Sendable {
    case missingThreadMetadata
    case relationshipConflict
    case unverifiedReference
    case managedWorktree
    case pasteCache
    case shellSnapshot
    case unknown
}

public enum AgentStorageArtifactCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case conversation
    case toolResult
    case subagent
    case fileHistory
    case attachment
    case snapshot
    case task
    case workflow
    case other
}

public struct AgentStorageCoverage: Codable, Equatable, Sendable {
    public let measuredBytes: UInt64
    public let classifiedBytes: UInt64
    public let measuredEntryCount: Int
    public let skippedEntryCount: Int
    public let unstableEntryCount: Int
    public let overflowed: Bool
    public let reconciliationDelta: UInt64
    public let isComplete: Bool

    public init(
        measuredBytes: UInt64,
        classifiedBytes: UInt64,
        measuredEntryCount: Int,
        skippedEntryCount: Int,
        unstableEntryCount: Int,
        overflowed: Bool,
        reconciliationDelta: UInt64,
        isComplete: Bool
    ) {
        self.measuredBytes = measuredBytes
        self.classifiedBytes = classifiedBytes
        self.measuredEntryCount = measuredEntryCount
        self.skippedEntryCount = skippedEntryCount
        self.unstableEntryCount = unstableEntryCount
        self.overflowed = overflowed
        self.reconciliationDelta = reconciliationDelta
        self.isComplete = isComplete
    }
}

public struct AgentStorageSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let displayName: String
    public let path: String
    public let isAvailable: Bool
    public let isSessionSource: Bool

    public init(
        id: String,
        provider: AgentStorageProvider,
        displayName: String,
        path: String,
        isAvailable: Bool,
        isSessionSource: Bool
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.path = path
        self.isAvailable = isAvailable
        self.isSessionSource = isSessionSource
    }
}

public struct AgentStorageThreadNode: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let nativeID: String
    public let parentID: String?
    public let depth: Int
    public let title: String
    public let updatedAt: Date
    public let allocatedBytes: UInt64
    public let databaseAttributedBytes: UInt64
    public let artifactCount: Int
    public let path: String?
    public let cleanupArtifacts: [AgentStorageCleanupArtifact]

    public init(
        id: String,
        nativeID: String,
        parentID: String?,
        depth: Int,
        title: String,
        updatedAt: Date,
        allocatedBytes: UInt64,
        databaseAttributedBytes: UInt64 = 0,
        artifactCount: Int,
        path: String?,
        cleanupArtifacts: [AgentStorageCleanupArtifact] = []
    ) {
        self.id = id
        self.nativeID = nativeID
        self.parentID = parentID
        self.depth = depth
        self.title = title
        self.updatedAt = updatedAt
        self.allocatedBytes = allocatedBytes
        self.databaseAttributedBytes = databaseAttributedBytes
        self.artifactCount = artifactCount
        self.path = path
        self.cleanupArtifacts = cleanupArtifacts
    }

    public var attributedBytes: UInt64 {
        allocatedBytes.addingClamped(databaseAttributedBytes)
    }
}

public struct AgentStorageCleanupArtifact: Codable, Hashable, Sendable {
    public let path: String
    public let allocatedBytes: UInt64
    public let device: UInt64
    public let inode: UInt64
    public let logicalBytes: Int64
    public let blocks: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public init(
        path: String,
        allocatedBytes: UInt64,
        device: UInt64,
        inode: UInt64,
        logicalBytes: Int64,
        blocks: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64
    ) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.device = device
        self.inode = inode
        self.logicalBytes = logicalBytes
        self.blocks = blocks
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

public struct AgentStorageThreadFamily: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let sourceID: String
    public let nativeThreadID: String
    public let title: String
    public let project: String
    public let updatedAt: Date
    public let isArchived: Bool
    public let mainAllocatedBytes: UInt64
    public let subagentAllocatedBytes: UInt64
    public let familyOtherAllocatedBytes: UInt64
    public let mainDatabaseAttributedBytes: UInt64
    public let subagentDatabaseAttributedBytes: UInt64
    public let artifactCount: Int
    public let path: String?
    public let subagents: [AgentStorageThreadNode]
    public let composition: [AgentStorageArtifactCategory: UInt64]
    public let cleanupArtifacts: [AgentStorageCleanupArtifact]

    public init(
        id: String,
        provider: AgentStorageProvider,
        sourceID: String,
        nativeThreadID: String,
        title: String,
        project: String,
        updatedAt: Date,
        isArchived: Bool,
        mainAllocatedBytes: UInt64,
        subagentAllocatedBytes: UInt64,
        familyOtherAllocatedBytes: UInt64,
        mainDatabaseAttributedBytes: UInt64 = 0,
        subagentDatabaseAttributedBytes: UInt64 = 0,
        artifactCount: Int,
        path: String?,
        subagents: [AgentStorageThreadNode],
        composition: [AgentStorageArtifactCategory: UInt64],
        cleanupArtifacts: [AgentStorageCleanupArtifact] = []
    ) {
        self.id = id
        self.provider = provider
        self.sourceID = sourceID
        self.nativeThreadID = nativeThreadID
        self.title = title
        self.project = project
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.mainAllocatedBytes = mainAllocatedBytes
        self.subagentAllocatedBytes = subagentAllocatedBytes
        self.familyOtherAllocatedBytes = familyOtherAllocatedBytes
        self.mainDatabaseAttributedBytes = mainDatabaseAttributedBytes
        self.subagentDatabaseAttributedBytes = subagentDatabaseAttributedBytes
        self.artifactCount = artifactCount
        self.path = path
        self.subagents = subagents
        self.composition = composition
        self.cleanupArtifacts = cleanupArtifacts
    }

    public var allocatedBytes: UInt64 {
        mainAllocatedBytes
            .addingClamped(subagentAllocatedBytes)
            .addingClamped(familyOtherAllocatedBytes)
    }

    public var databaseAttributedBytes: UInt64 {
        mainDatabaseAttributedBytes.addingClamped(subagentDatabaseAttributedBytes)
    }

    public var attributedBytes: UInt64 {
        allocatedBytes.addingClamped(databaseAttributedBytes)
    }

    public var subagentCount: Int { subagents.count }

    public var reclaimableBytes: UInt64 {
        cleanupArtifacts.reduce(0) { $0.addingClamped($1.allocatedBytes) }
    }
}

public struct AgentStorageGlobalItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider?
    public let category: AgentStorageGlobalCategory
    public let title: String
    public let allocatedBytes: UInt64
    public let physicalAllocatedBytes: UInt64
    public let databaseAttributedBytes: UInt64
    public let logicalBytes: UInt64
    public let artifactCount: Int
    public let path: String?
    public let updatedAt: Date?

    public init(
        id: String,
        provider: AgentStorageProvider?,
        category: AgentStorageGlobalCategory,
        title: String,
        allocatedBytes: UInt64,
        physicalAllocatedBytes: UInt64? = nil,
        databaseAttributedBytes: UInt64 = 0,
        logicalBytes: UInt64,
        artifactCount: Int,
        path: String?,
        updatedAt: Date?
    ) {
        self.id = id
        self.provider = provider
        self.category = category
        self.title = title
        self.allocatedBytes = allocatedBytes
        self.physicalAllocatedBytes = physicalAllocatedBytes ?? allocatedBytes
        self.databaseAttributedBytes = databaseAttributedBytes
        self.logicalBytes = logicalBytes
        self.artifactCount = artifactCount
        self.path = path
        self.updatedAt = updatedAt
    }
}

public struct AgentStorageUnattributedItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let reason: AgentStorageUnattributedReason
    public let title: String
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let artifactCount: Int
    public let path: String?
    public let updatedAt: Date?
    public let evidence: String

    public init(
        id: String,
        provider: AgentStorageProvider,
        reason: AgentStorageUnattributedReason,
        title: String,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        artifactCount: Int,
        path: String?,
        updatedAt: Date?,
        evidence: String
    ) {
        self.id = id
        self.provider = provider
        self.reason = reason
        self.title = title
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.artifactCount = artifactCount
        self.path = path
        self.updatedAt = updatedAt
        self.evidence = evidence
    }
}

public struct AgentStorageProviderSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: AgentStorageProvider { provider }
    public let provider: AgentStorageProvider
    public let exclusiveBytes: UInt64
    public let chatBytes: UInt64
    public let globalBytes: UInt64
    public let unattributedBytes: UInt64
    public let mainThreadBytes: UInt64
    public let subagentBytes: UInt64
    public let familyOtherBytes: UInt64
    public let databaseAttributedBytes: UInt64
    public let threadCount: Int
    public let subagentCount: Int
    public let sourceCount: Int
    public let issueCount: Int
    public let unstableEntryCount: Int
    public let supportStatus: AgentStorageProviderSupportStatus
    public let unsupportedSourceCount: Int
    public let unreadableSourceCount: Int

    public init(
        provider: AgentStorageProvider,
        exclusiveBytes: UInt64,
        chatBytes: UInt64,
        globalBytes: UInt64,
        unattributedBytes: UInt64,
        mainThreadBytes: UInt64,
        subagentBytes: UInt64,
        familyOtherBytes: UInt64,
        databaseAttributedBytes: UInt64 = 0,
        threadCount: Int,
        subagentCount: Int,
        sourceCount: Int,
        issueCount: Int,
        unstableEntryCount: Int = 0,
        supportStatus: AgentStorageProviderSupportStatus = .supported,
        unsupportedSourceCount: Int = 0,
        unreadableSourceCount: Int = 0
    ) {
        self.provider = provider
        self.exclusiveBytes = exclusiveBytes
        self.chatBytes = chatBytes
        self.globalBytes = globalBytes
        self.unattributedBytes = unattributedBytes
        self.mainThreadBytes = mainThreadBytes
        self.subagentBytes = subagentBytes
        self.familyOtherBytes = familyOtherBytes
        self.databaseAttributedBytes = databaseAttributedBytes
        self.threadCount = threadCount
        self.subagentCount = subagentCount
        self.sourceCount = sourceCount
        self.issueCount = issueCount
        self.unstableEntryCount = unstableEntryCount
        self.supportStatus = supportStatus
        self.unsupportedSourceCount = unsupportedSourceCount
        self.unreadableSourceCount = unreadableSourceCount
    }
}

public struct AgentStorageProviderDataset: Identifiable, Codable, Equatable, Sendable {
    public var id: AgentStorageProvider { provider }
    public let provider: AgentStorageProvider
    public let families: [AgentStorageThreadFamily]
    public let globalItems: [AgentStorageGlobalItem]
    public let unattributedItems: [AgentStorageUnattributedItem]

    public init(
        provider: AgentStorageProvider,
        families: [AgentStorageThreadFamily],
        globalItems: [AgentStorageGlobalItem],
        unattributedItems: [AgentStorageUnattributedItem]
    ) {
        self.provider = provider
        self.families = families
        self.globalItems = globalItems
        self.unattributedItems = unattributedItems
    }

    public func chatProjection(
        since cutoff: Date?,
        before upperBound: Date? = nil
    ) -> AgentStorageChatRangeProjection {
        let matchingFamilies = families.filter { family in
            let isAfterCutoff = cutoff.map { family.updatedAt >= $0 } ?? true
            let isBeforeUpperBound = upperBound.map { family.updatedAt < $0 } ?? true
            return isAfterCutoff && isBeforeUpperBound
        }
        return AgentStorageChatRangeProjection(families: matchingFamilies)
    }
}

public struct AgentStorageChatRangeProjection: Equatable, Sendable {
    public let families: [AgentStorageThreadFamily]
    public let chatBytes: UInt64
    public let mainThreadBytes: UInt64
    public let subagentBytes: UInt64
    public let familyOtherBytes: UInt64
    public let databaseAttributedBytes: UInt64
    public let mainThreadCount: Int
    public let subagentCount: Int

    public init(families: [AgentStorageThreadFamily]) {
        self.families = families
        chatBytes = families.reduce(0) { $0.addingClamped($1.attributedBytes) }
        mainThreadBytes = families.reduce(0) {
            $0.addingClamped($1.mainAllocatedBytes)
                .addingClamped($1.mainDatabaseAttributedBytes)
        }
        subagentBytes = families.reduce(0) {
            $0.addingClamped($1.subagentAllocatedBytes)
                .addingClamped($1.subagentDatabaseAttributedBytes)
        }
        familyOtherBytes = families.reduce(0) {
            $0.addingClamped($1.familyOtherAllocatedBytes)
        }
        databaseAttributedBytes = families.reduce(0) {
            $0.addingClamped($1.databaseAttributedBytes)
        }
        mainThreadCount = families.count
        subagentCount = families.reduce(0) { $0 + $1.subagentCount }
    }
}

public struct AgentStorageSnapshot: Codable, Equatable, Sendable {
    public let scannedAt: Date
    public let families: [AgentStorageThreadFamily]
    public let globalItems: [AgentStorageGlobalItem]
    public let unattributedItems: [AgentStorageUnattributedItem]
    public let providers: [AgentStorageProviderSummary]
    public let sources: [AgentStorageSource]
    public let coverage: AgentStorageCoverage
    public let crossAgentSharedBytes: UInt64
    public let providerDatasets: [AgentStorageProviderDataset]
    public let databaseAttributions: [AgentStorageDatabaseAttributionSummary]
    public let chatBytes: UInt64
    public let globalBytes: UInt64
    public let unattributedBytes: UInt64
    public let totalBytes: UInt64

    public init(
        scannedAt: Date,
        families: [AgentStorageThreadFamily],
        globalItems: [AgentStorageGlobalItem],
        unattributedItems: [AgentStorageUnattributedItem],
        providers: [AgentStorageProviderSummary],
        sources: [AgentStorageSource],
        coverage: AgentStorageCoverage,
        crossAgentSharedBytes: UInt64,
        providerDatasets: [AgentStorageProviderDataset]? = nil,
        databaseAttributions: [AgentStorageDatabaseAttributionSummary] = []
    ) {
        self.scannedAt = scannedAt
        self.families = families
        self.globalItems = globalItems
        self.unattributedItems = unattributedItems
        self.providers = providers
        self.sources = sources
        self.coverage = coverage
        self.crossAgentSharedBytes = crossAgentSharedBytes
        self.providerDatasets = providerDatasets ?? AgentStorageProvider.allCases.map { provider in
            AgentStorageProviderDataset(
                provider: provider,
                families: families.filter { $0.provider == provider },
                globalItems: globalItems.filter { $0.provider == provider },
                unattributedItems: unattributedItems.filter { $0.provider == provider }
            )
        }
        self.databaseAttributions = databaseAttributions
        chatBytes = families.reduce(0) { $0.addingClamped($1.attributedBytes) }
        globalBytes = globalItems.reduce(0) { $0.addingClamped($1.allocatedBytes) }
        unattributedBytes = unattributedItems.reduce(0) { $0.addingClamped($1.allocatedBytes) }
        totalBytes = chatBytes.addingClamped(globalBytes).addingClamped(unattributedBytes)
    }

    public func dataset(for provider: AgentStorageProvider) -> AgentStorageProviderDataset? {
        providerDatasets.first { $0.provider == provider }
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}
