import Foundation

public enum AgentStorageProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }
}

public enum AgentStorageSourceKind: String, Codable, Hashable, Sendable {
    case codexHome
    case codexDesktop
    case claudeCode
    case claudeDesktop
    case claudeDesktopAgent
}

public enum AgentStorageProviderSupportStatus: String, Codable, Hashable, Sendable {
    case supported
    case partial
    case unsupportedFormat
    case noConversationSource
    case notInstalled
}

public enum AgentStorageAttributionStatus: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case unavailable
    case noConversationSource
}

public enum AgentStorageDiagnosticKind: String, Codable, Hashable, Sendable {
    case sourceUnreadable
    case sourceUnsupportedFormat
    case mainTranscriptUnreadable
    case sessionIdentityMismatch
    case malformedTranscriptRecords
    case subagentTranscriptUnverified
    case subagentMetadataOnly
    case ambiguousToolResult
    case databaseRecordUnverified
    case databaseAttributionUnavailable
    case relationshipConflict
    case filesystemEntrySkipped
    case changedDuringScan
}

public enum AgentStorageDiagnosticArea: String, Codable, Hashable, Sendable {
    case mainChat
    case subagent
    case toolResult
    case dataSource
    case database
    case fileSystem
}

public enum AgentStorageDiagnosticImpact: String, Codable, Hashable, Sendable {
    case chatDiscovery
    case chatMetadata
    case threadComposition
    case databaseAttribution
    case physicalMeasurement
}

public struct AgentStorageDiagnostic: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let sourceID: String
    public let sourceKind: AgentStorageSourceKind?
    public let kind: AgentStorageDiagnosticKind
    public let area: AgentStorageDiagnosticArea
    public let impact: AgentStorageDiagnosticImpact
    public let affectedEntityCount: Int
    public let affectedAllocatedBytes: UInt64?
    public let relativePath: String?

    public init(
        id: String,
        provider: AgentStorageProvider,
        sourceID: String,
        sourceKind: AgentStorageSourceKind? = nil,
        kind: AgentStorageDiagnosticKind,
        area: AgentStorageDiagnosticArea,
        impact: AgentStorageDiagnosticImpact,
        affectedEntityCount: Int = 1,
        affectedAllocatedBytes: UInt64? = nil,
        relativePath: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.kind = kind
        self.area = area
        self.impact = impact
        self.affectedEntityCount = max(1, affectedEntityCount)
        self.affectedAllocatedBytes = affectedAllocatedBytes
        self.relativePath = relativePath
    }
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

    public var isPhysicalMeasurementComplete: Bool {
        skippedEntryCount == 0
            && unstableEntryCount == 0
            && !overflowed
            && reconciliationDelta == 0
    }
}

public struct AgentStorageSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let displayName: String
    public let path: String
    public let isAvailable: Bool
    public let isSessionSource: Bool
    public let kind: AgentStorageSourceKind?

    public init(
        id: String,
        provider: AgentStorageProvider,
        displayName: String,
        path: String,
        isAvailable: Bool,
        isSessionSource: Bool,
        kind: AgentStorageSourceKind? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.path = path
        self.isAvailable = isAvailable
        self.isSessionSource = isSessionSource
        self.kind = kind
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
    public let category: AgentStorageArtifactCategory?

    public init(
        path: String,
        allocatedBytes: UInt64,
        device: UInt64,
        inode: UInt64,
        logicalBytes: Int64,
        blocks: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        category: AgentStorageArtifactCategory? = nil
    ) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.device = device
        self.inode = inode
        self.logicalBytes = logicalBytes
        self.blocks = blocks
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.category = category
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
    public let sourceKind: AgentStorageSourceKind?
    public let sourcePath: String?
    public let projectPath: String?

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
        cleanupArtifacts: [AgentStorageCleanupArtifact] = [],
        sourceKind: AgentStorageSourceKind? = nil,
        sourcePath: String? = nil,
        projectPath: String? = nil
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
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.projectPath = projectPath
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
    public let attributionStatus: AgentStorageAttributionStatus
    public let diagnosticCounts: [AgentStorageDiagnosticKind: Int]
    public let knownAffectedBytes: UInt64

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
        unreadableSourceCount: Int = 0,
        attributionStatus: AgentStorageAttributionStatus? = nil,
        diagnosticCounts: [AgentStorageDiagnosticKind: Int] = [:],
        knownAffectedBytes: UInt64 = 0
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
        self.attributionStatus = attributionStatus ?? Self.attributionStatus(for: supportStatus)
        self.diagnosticCounts = diagnosticCounts
        self.knownAffectedBytes = knownAffectedBytes
    }

    private static func attributionStatus(
        for supportStatus: AgentStorageProviderSupportStatus
    ) -> AgentStorageAttributionStatus {
        switch supportStatus {
        case .supported: .complete
        case .partial: .partial
        case .unsupportedFormat, .notInstalled: .unavailable
        case .noConversationSource: .noConversationSource
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider, exclusiveBytes, chatBytes, globalBytes, unattributedBytes
        case mainThreadBytes, subagentBytes, familyOtherBytes, databaseAttributedBytes
        case threadCount, subagentCount, sourceCount, issueCount, unstableEntryCount
        case supportStatus, unsupportedSourceCount, unreadableSourceCount
        case attributionStatus, diagnosticCounts, knownAffectedBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(AgentStorageProvider.self, forKey: .provider)
        exclusiveBytes = try values.decode(UInt64.self, forKey: .exclusiveBytes)
        chatBytes = try values.decode(UInt64.self, forKey: .chatBytes)
        globalBytes = try values.decode(UInt64.self, forKey: .globalBytes)
        unattributedBytes = try values.decode(UInt64.self, forKey: .unattributedBytes)
        mainThreadBytes = try values.decode(UInt64.self, forKey: .mainThreadBytes)
        subagentBytes = try values.decode(UInt64.self, forKey: .subagentBytes)
        familyOtherBytes = try values.decode(UInt64.self, forKey: .familyOtherBytes)
        databaseAttributedBytes = try values.decodeIfPresent(
            UInt64.self,
            forKey: .databaseAttributedBytes
        ) ?? 0
        threadCount = try values.decode(Int.self, forKey: .threadCount)
        subagentCount = try values.decode(Int.self, forKey: .subagentCount)
        sourceCount = try values.decode(Int.self, forKey: .sourceCount)
        issueCount = try values.decode(Int.self, forKey: .issueCount)
        unstableEntryCount = try values.decodeIfPresent(
            Int.self,
            forKey: .unstableEntryCount
        ) ?? 0
        supportStatus = try values.decode(
            AgentStorageProviderSupportStatus.self,
            forKey: .supportStatus
        )
        unsupportedSourceCount = try values.decodeIfPresent(
            Int.self,
            forKey: .unsupportedSourceCount
        ) ?? 0
        unreadableSourceCount = try values.decodeIfPresent(
            Int.self,
            forKey: .unreadableSourceCount
        ) ?? 0
        attributionStatus = try values.decodeIfPresent(
            AgentStorageAttributionStatus.self,
            forKey: .attributionStatus
        ) ?? Self.attributionStatus(for: supportStatus)
        diagnosticCounts = try values.decodeIfPresent(
            [AgentStorageDiagnosticKind: Int].self,
            forKey: .diagnosticCounts
        ) ?? [:]
        knownAffectedBytes = try values.decodeIfPresent(
            UInt64.self,
            forKey: .knownAffectedBytes
        ) ?? 0
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
    public let diagnostics: [AgentStorageDiagnostic]
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
        databaseAttributions: [AgentStorageDatabaseAttributionSummary] = [],
        diagnostics: [AgentStorageDiagnostic] = []
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
        self.diagnostics = diagnostics
        chatBytes = families.reduce(0) { $0.addingClamped($1.attributedBytes) }
        globalBytes = globalItems.reduce(0) { $0.addingClamped($1.allocatedBytes) }
        unattributedBytes = unattributedItems.reduce(0) { $0.addingClamped($1.allocatedBytes) }
        totalBytes = chatBytes.addingClamped(globalBytes).addingClamped(unattributedBytes)
    }

    public func dataset(for provider: AgentStorageProvider) -> AgentStorageProviderDataset? {
        providerDatasets.first { $0.provider == provider }
    }

    public func diagnostics(for provider: AgentStorageProvider) -> [AgentStorageDiagnostic] {
        diagnostics.filter { $0.provider == provider }
    }

    private enum CodingKeys: String, CodingKey {
        case scannedAt, families, globalItems, unattributedItems, providers, sources
        case coverage, crossAgentSharedBytes, providerDatasets, databaseAttributions, diagnostics
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scannedAt: try values.decode(Date.self, forKey: .scannedAt),
            families: try values.decode([AgentStorageThreadFamily].self, forKey: .families),
            globalItems: try values.decode([AgentStorageGlobalItem].self, forKey: .globalItems),
            unattributedItems: try values.decode(
                [AgentStorageUnattributedItem].self,
                forKey: .unattributedItems
            ),
            providers: try values.decode([AgentStorageProviderSummary].self, forKey: .providers),
            sources: try values.decode([AgentStorageSource].self, forKey: .sources),
            coverage: try values.decode(AgentStorageCoverage.self, forKey: .coverage),
            crossAgentSharedBytes: try values.decode(UInt64.self, forKey: .crossAgentSharedBytes),
            providerDatasets: try values.decodeIfPresent(
                [AgentStorageProviderDataset].self,
                forKey: .providerDatasets
            ),
            databaseAttributions: try values.decodeIfPresent(
                [AgentStorageDatabaseAttributionSummary].self,
                forKey: .databaseAttributions
            ) ?? [],
            diagnostics: try values.decodeIfPresent(
                [AgentStorageDiagnostic].self,
                forKey: .diagnostics
            ) ?? []
        )
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}
