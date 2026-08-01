import Foundation

public struct StorageSourceID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static let chrome = Self(rawValue: "chrome")
    public static let go = Self(rawValue: "go")
    public static let npm = Self(rawValue: "npm")
    public static let pnpm = Self(rawValue: "pnpm")
    public static let bun = Self(rawValue: "bun")
    public static let pip = Self(rawValue: "pip")
    public static let xcode = Self(rawValue: "xcode")
    public static let vscode = Self(rawValue: "vscode")
    public static let simulators = Self(rawValue: "simulators")
    public static let docker = Self(rawValue: "docker")
    public static let podman = Self(rawValue: "podman")
    public static let workspace = Self(rawValue: "workspace")
    public static let codex = Self(rawValue: "codex")
    public static let claude = Self(rawValue: "claude")
    public static let openCode = Self(rawValue: "openCode")
}

public enum StorageSourceFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case applications
    case developerTools
    case containers
    case aiTools
    case workspaces
}

public enum StorageRiskLevel: Int, CaseIterable, Codable, Comparable, Hashable, Sendable {
    case rebuildableCache = 1
    case sharedOrExpensive = 2
    case environmentOrRuntime = 3
    case protectedUserData = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum StorageCleanupCapability: String, Codable, Hashable, Sendable {
    case analysisOnly
    case officialTool
    case verifiedFiles
    case openOfficialManager
}

public enum StorageMeasurementEvidence: String, Codable, Hashable, Sendable {
    case fileSystemAllocated
    case providerReported
    case logicalOnly
}

public enum StorageSourceAvailability: String, Codable, Hashable, Sendable {
    case available
    case permissionLimited
    case unavailable
}

public enum StorageScanPhase: String, Codable, Equatable, Sendable {
    case discovering
    case measuring
    case reconciling
    case finished
}

public struct StorageSourceDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: StorageSourceID
    public let title: String
    public let family: StorageSourceFamily
    public let symbol: String
    public let cleanupCapability: StorageCleanupCapability

    public init(
        id: StorageSourceID,
        title: String,
        family: StorageSourceFamily,
        symbol: String,
        cleanupCapability: StorageCleanupCapability
    ) {
        self.id = id
        self.title = title
        self.family = family
        self.symbol = symbol
        self.cleanupCapability = cleanupCapability
    }
}

public struct StorageSourceRoot: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case directory
        case file
    }

    public let id: String
    public let sourceID: StorageSourceID
    public let displayName: String
    public let path: String
    public let defaultCategory: String
    public let defaultRisk: StorageRiskLevel
    public let isProtected: Bool
    public let kind: Kind
    public let resourceContext: StorageResourceContext?

    public init(
        id: String,
        sourceID: StorageSourceID,
        displayName: String,
        path: String,
        defaultCategory: String,
        defaultRisk: StorageRiskLevel,
        isProtected: Bool = false,
        kind: Kind = .directory,
        resourceContext: StorageResourceContext? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.displayName = displayName
        self.path = path
        self.defaultCategory = defaultCategory
        self.defaultRisk = defaultRisk
        self.isProtected = isProtected
        self.kind = kind
        self.resourceContext = resourceContext
    }
}

public struct StoragePathIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct StorageResourceContext: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case repository
        case worktree
    }

    public let kind: Kind
    public let groupID: String
    public let parentPath: String?
    public let branch: String?
    public let identity: StoragePathIdentity
    public let isCleanupAllowed: Bool

    public init(
        kind: Kind,
        groupID: String,
        parentPath: String? = nil,
        branch: String? = nil,
        identity: StoragePathIdentity,
        isCleanupAllowed: Bool = true
    ) {
        self.kind = kind
        self.groupID = groupID
        self.parentPath = parentPath
        self.branch = branch
        self.identity = identity
        self.isCleanupAllowed = isCleanupAllowed
    }
}

public struct StorageSourceCandidate: Identifiable, Codable, Hashable, Sendable {
    public var id: StorageSourceID { descriptor.id }
    public let descriptor: StorageSourceDescriptor
    public let roots: [StorageSourceRoot]
    public let availability: StorageSourceAvailability
    public let diagnostic: String?

    public init(
        descriptor: StorageSourceDescriptor,
        roots: [StorageSourceRoot],
        availability: StorageSourceAvailability = .available,
        diagnostic: String? = nil
    ) {
        self.descriptor = descriptor
        self.roots = roots
        self.availability = availability
        self.diagnostic = diagnostic
    }
}

public struct StorageScanConfiguration: Sendable {
    public let homeDirectory: URL
    public let workspaceRoots: [URL]
    public let agentDataLocations: [AgentDataLocation]?
    public let agentAdditionalRoots: [URL]
    public let environment: [String: String]
    public let repositorySearchRoots: [URL]?
    public let includesPrivacyProtectedRepositoryLocations: Bool
    public let providerInventoryEnabled: Bool
    public let discoversCodeRepositories: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspaceRoots: [URL] = [],
        agentDataLocations: [AgentDataLocation]? = nil,
        agentAdditionalRoots: [URL] = [],
        environment: [String: String]? = nil,
        repositorySearchRoots: [URL]? = nil,
        includesPrivacyProtectedRepositoryLocations: Bool = false,
        providerInventoryEnabled: Bool? = nil,
        discoversCodeRepositories: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.workspaceRoots = workspaceRoots
        self.agentDataLocations = agentDataLocations
        self.agentAdditionalRoots = agentAdditionalRoots
        let requestedHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let currentHome = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        self.environment = environment
            ?? (requestedHome == currentHome ? ProcessInfo.processInfo.environment : [:])
        self.repositorySearchRoots = repositorySearchRoots
            ?? (requestedHome == currentHome ? nil : [homeDirectory])
        self.includesPrivacyProtectedRepositoryLocations =
            includesPrivacyProtectedRepositoryLocations
        self.providerInventoryEnabled = providerInventoryEnabled ?? (requestedHome == currentHome)
        self.discoversCodeRepositories = discoversCodeRepositories
    }
}

public struct StorageScanProgress: Equatable, Sendable {
    public let phase: StorageScanPhase
    public let sourceID: StorageSourceID?
    public let completedSourceCount: Int
    public let totalSourceCount: Int
    public let processedEntryCount: Int
    public let processedBytes: UInt64
    public let sourceProcessedEntryCount: Int
    public let sourceProcessedBytes: UInt64
    public let currentWork: String?
    public let currentWorkIndex: Int?
    public let totalWorkCount: Int?
    public let sourceCompleted: Bool
    public let volumes: [StorageVolumeSnapshot]

    public init(
        phase: StorageScanPhase,
        sourceID: StorageSourceID? = nil,
        completedSourceCount: Int = 0,
        totalSourceCount: Int = 0,
        processedEntryCount: Int = 0,
        processedBytes: UInt64 = 0,
        sourceProcessedEntryCount: Int = 0,
        sourceProcessedBytes: UInt64 = 0,
        currentWork: String? = nil,
        currentWorkIndex: Int? = nil,
        totalWorkCount: Int? = nil,
        sourceCompleted: Bool = false,
        volumes: [StorageVolumeSnapshot] = []
    ) {
        self.phase = phase
        self.sourceID = sourceID
        self.completedSourceCount = completedSourceCount
        self.totalSourceCount = totalSourceCount
        self.processedEntryCount = processedEntryCount
        self.processedBytes = processedBytes
        self.sourceProcessedEntryCount = sourceProcessedEntryCount
        self.sourceProcessedBytes = sourceProcessedBytes
        self.currentWork = currentWork
        self.currentWorkIndex = currentWorkIndex
        self.totalWorkCount = totalWorkCount
        self.sourceCompleted = sourceCompleted
        self.volumes = volumes
    }
}

public struct StorageVolumeSourceUsage: Codable, Equatable, Sendable {
    public let sourceID: StorageSourceID
    public let allocatedBytes: UInt64

    public init(sourceID: StorageSourceID, allocatedBytes: UInt64) {
        self.sourceID = sourceID
        self.allocatedBytes = allocatedBytes
    }
}

public struct StorageVolumeSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mountPath: String
    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    public let sourceUsages: [StorageVolumeSourceUsage]

    public init(
        id: String,
        name: String,
        mountPath: String,
        totalCapacity: UInt64,
        availableCapacity: UInt64,
        sourceUsages: [StorageVolumeSourceUsage]
    ) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
        self.totalCapacity = totalCapacity
        self.availableCapacity = min(availableCapacity, totalCapacity)
        self.sourceUsages = sourceUsages
    }

    public var usedBytes: UInt64 {
        totalCapacity - availableCapacity
    }

    public var analyzedBytes: UInt64 {
        sourceUsages.reduce(0) { partial, usage in
            let sum = partial.addingReportingOverflow(usage.allocatedBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    public var otherBytes: UInt64 {
        usedBytes > analyzedBytes ? usedBytes - analyzedBytes : 0
    }
}

public struct StorageComponent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let rootDisplayName: String
    public let rootID: String?
    public let rootPath: String?
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let entryCount: Int
    public let newestModificationDate: Date?
    public let risk: StorageRiskLevel
    public let evidence: StorageMeasurementEvidence
    public let isProtected: Bool

    public init(
        id: String,
        title: String,
        rootDisplayName: String,
        rootID: String? = nil,
        rootPath: String? = nil,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        entryCount: Int,
        newestModificationDate: Date?,
        risk: StorageRiskLevel,
        evidence: StorageMeasurementEvidence = .fileSystemAllocated,
        isProtected: Bool
    ) {
        self.id = id
        self.title = title
        self.rootDisplayName = rootDisplayName
        self.rootID = rootID
        self.rootPath = rootPath
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.entryCount = entryCount
        self.newestModificationDate = newestModificationDate
        self.risk = risk
        self.evidence = evidence
        self.isProtected = isProtected
    }
}

public enum StorageResourceKind: String, Codable, Hashable, Sendable {
    case location
    case category
    case repository
    case worktree
    case dockerStorage
    case dockerImages
    case dockerImage
    case dockerContainers
    case dockerContainer
    case dockerVolumes
    case dockerVolume
    case dockerBuildCache
    case dockerBuildCacheRecord
}

public enum StorageResourceCleanupTarget: Codable, Hashable, Sendable {
    case removePathContents(path: String, identity: StoragePathIdentity, sourceID: StorageSourceID, rootID: String)
    case trashRepository(path: String, identity: StoragePathIdentity)
    case removeGitWorktree(path: String, mainRepositoryPath: String, identity: StoragePathIdentity)
    case simulatorDevice(identifier: String)
    case simulatorRuntime(identifier: String, path: String, identity: StoragePathIdentity)
    case simulatorRuntimeAsset(path: String, identity: StoragePathIdentity)
    case dockerImage(id: String)
    case dockerContainer(id: String)
    case dockerVolume(name: String)
    case podmanImage(id: String)
    case podmanContainer(id: String)
    case podmanVolume(name: String)
}

public struct StorageResourceNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: StorageResourceKind
    public let title: String
    public let detail: String?
    public let symbol: String
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let entryCount: Int
    public let risk: StorageRiskLevel
    public let evidence: StorageMeasurementEvidence
    public let isProtected: Bool
    public let cleanupTarget: StorageResourceCleanupTarget?
    public let children: [StorageResourceNode]

    public init(
        id: String,
        kind: StorageResourceKind,
        title: String,
        detail: String? = nil,
        symbol: String,
        allocatedBytes: UInt64,
        logicalBytes: UInt64 = 0,
        entryCount: Int = 0,
        risk: StorageRiskLevel,
        evidence: StorageMeasurementEvidence,
        isProtected: Bool,
        cleanupTarget: StorageResourceCleanupTarget? = nil,
        children: [StorageResourceNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.entryCount = entryCount
        self.risk = risk
        self.evidence = evidence
        self.isProtected = isProtected
        self.cleanupTarget = cleanupTarget
        self.children = children
    }
}

public struct StorageSourceResult: Identifiable, Codable, Equatable, Sendable {
    public var id: StorageSourceID { descriptor.id }
    public let descriptor: StorageSourceDescriptor
    public let availability: StorageSourceAvailability
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let entryCount: Int
    public let reclaimableCandidateBytes: UInt64
    public let components: [StorageComponent]
    public let resourceTree: [StorageResourceNode]
    public let inventoryDiagnostic: String?
    public let skippedEntryCount: Int
    public let unstableEntryCount: Int
    public let diagnostic: String?

    public init(
        descriptor: StorageSourceDescriptor,
        availability: StorageSourceAvailability,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        entryCount: Int,
        reclaimableCandidateBytes: UInt64,
        components: [StorageComponent],
        resourceTree: [StorageResourceNode] = [],
        inventoryDiagnostic: String? = nil,
        skippedEntryCount: Int = 0,
        unstableEntryCount: Int = 0,
        diagnostic: String? = nil
    ) {
        self.descriptor = descriptor
        self.availability = availability
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.entryCount = entryCount
        self.reclaimableCandidateBytes = reclaimableCandidateBytes
        self.components = components
        self.resourceTree = resourceTree
        self.inventoryDiagnostic = inventoryDiagnostic
        self.skippedEntryCount = skippedEntryCount
        self.unstableEntryCount = unstableEntryCount
        self.diagnostic = diagnostic
    }

    public var isComplete: Bool {
        availability == .available && skippedEntryCount == 0 && unstableEntryCount == 0
    }
}

public struct StorageAnalysisSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let scannedAt: Date
    public let results: [StorageSourceResult]
    public let totalAllocatedBytes: UInt64
    public let conflictBytes: UInt64
    public let measuredEntryCount: Int
    public let skippedEntryCount: Int
    public let volumes: [StorageVolumeSnapshot]

    public init(
        id: UUID = UUID(),
        scannedAt: Date,
        results: [StorageSourceResult],
        totalAllocatedBytes: UInt64,
        conflictBytes: UInt64,
        measuredEntryCount: Int,
        skippedEntryCount: Int,
        volumes: [StorageVolumeSnapshot] = []
    ) {
        self.id = id
        self.scannedAt = scannedAt
        self.results = results
        self.totalAllocatedBytes = totalAllocatedBytes
        self.conflictBytes = conflictBytes
        self.measuredEntryCount = measuredEntryCount
        self.skippedEntryCount = skippedEntryCount
        self.volumes = volumes
    }

    public func result(for id: StorageSourceID) -> StorageSourceResult? {
        results.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case scannedAt
        case results
        case totalAllocatedBytes
        case conflictBytes
        case measuredEntryCount
        case skippedEntryCount
        case volumes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        results = try container.decode([StorageSourceResult].self, forKey: .results)
        totalAllocatedBytes = try container.decode(UInt64.self, forKey: .totalAllocatedBytes)
        conflictBytes = try container.decode(UInt64.self, forKey: .conflictBytes)
        measuredEntryCount = try container.decode(Int.self, forKey: .measuredEntryCount)
        skippedEntryCount = try container.decode(Int.self, forKey: .skippedEntryCount)
        volumes = try container.decodeIfPresent(
            [StorageVolumeSnapshot].self,
            forKey: .volumes
        ) ?? []
    }
}
