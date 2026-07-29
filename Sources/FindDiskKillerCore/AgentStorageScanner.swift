import Darwin
import Foundation
import SQLite3

public enum AgentStorageScanPhase: Int, Sendable, Equatable, CaseIterable {
    case discoveringSources
    case readingMetadata
    case measuringEntries
    case validatingEntries
    case attributingDatabase
    case organizingResults
}

public enum AgentStorageDatabaseScanStage: Sendable, Equatable {
    case preparing
    case readingRecords
    case mappingRecords
}

public struct AgentStorageScanProgress: Sendable, Equatable {
    public let phase: AgentStorageScanPhase
    public let completedCount: Int
    public let totalCount: Int?
    public let provider: AgentStorageProvider?
    public let activityCount: Int?
    public let processedBytes: UInt64?
    public let databaseStage: AgentStorageDatabaseScanStage?
    public let databaseIndex: Int?
    public let databaseCount: Int?

    public init(
        phase: AgentStorageScanPhase,
        completedCount: Int = 0,
        totalCount: Int? = nil,
        provider: AgentStorageProvider? = nil,
        activityCount: Int? = nil,
        processedBytes: UInt64? = nil,
        databaseStage: AgentStorageDatabaseScanStage? = nil,
        databaseIndex: Int? = nil,
        databaseCount: Int? = nil
    ) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.provider = provider
        self.activityCount = activityCount
        self.processedBytes = processedBytes
        self.databaseStage = databaseStage
        self.databaseIndex = databaseIndex
        self.databaseCount = databaseCount
    }
}

public actor AgentStorageScanner {
    public struct Configuration: Sendable {
        public let homeDirectory: URL
        public let additionalRoots: [URL]
        public let includesDesktopData: Bool
        let beforePhysicalValidation: (@Sendable () -> Void)?
        let databaseReadConcurrency: Int
        let databaseShardDidStart: (@Sendable (String) -> Void)?

        public init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            additionalRoots: [URL] = [],
            includesDesktopData: Bool = true
        ) {
            self.homeDirectory = homeDirectory
            self.additionalRoots = additionalRoots
            self.includesDesktopData = includesDesktopData
            beforePhysicalValidation = nil
            databaseReadConcurrency = Self.defaultDatabaseReadConcurrency
            databaseShardDidStart = nil
        }

        init(
            homeDirectory: URL,
            additionalRoots: [URL] = [],
            includesDesktopData: Bool,
            beforePhysicalValidation: @escaping @Sendable () -> Void
        ) {
            self.homeDirectory = homeDirectory
            self.additionalRoots = additionalRoots
            self.includesDesktopData = includesDesktopData
            self.beforePhysicalValidation = beforePhysicalValidation
            databaseReadConcurrency = Self.defaultDatabaseReadConcurrency
            databaseShardDidStart = nil
        }

        init(
            homeDirectory: URL,
            additionalRoots: [URL] = [],
            includesDesktopData: Bool,
            databaseReadConcurrency: Int,
            databaseShardDidStart: @escaping @Sendable (String) -> Void
        ) {
            self.homeDirectory = homeDirectory
            self.additionalRoots = additionalRoots
            self.includesDesktopData = includesDesktopData
            beforePhysicalValidation = nil
            self.databaseReadConcurrency = max(1, databaseReadConcurrency)
            self.databaseShardDidStart = databaseShardDidStart
        }

        private static let defaultDatabaseReadConcurrency = min(
            4,
            max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        )
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func scan(
        progress: (@Sendable (AgentStorageScanProgress) -> Void)? = nil
    ) async throws -> AgentStorageSnapshot {
        let configuration = configuration
        let interruptRegistry = AgentSQLiteInterruptRegistry()
        let task = Task.detached(priority: .utility) {
            var engine = AgentStorageScanEngine(
                configuration: configuration,
                progressHandler: progress,
                interruptRegistry: interruptRegistry
            )
            return try await engine.scan()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            interruptRegistry.cancelAndInterrupt()
            task.cancel()
        }
    }
}

private final class AgentStorageProgressEmitter: @unchecked Sendable {
    private let handler: (@Sendable (AgentStorageScanProgress) -> Void)?
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var lastEmissionByProvider: [AgentStorageProvider?: ContinuousClock.Instant] = [:]

    init(handler: (@Sendable (AgentStorageScanProgress) -> Void)?) {
        self.handler = handler
    }

    func emit(_ progress: AgentStorageScanProgress, force: Bool = false) {
        let now = clock.now
        lock.lock()
        if !force, let lastEmission = lastEmissionByProvider[progress.provider],
           lastEmission.duration(to: now) < .milliseconds(100) {
            lock.unlock()
            return
        }
        lastEmissionByProvider[progress.provider] = now
        lock.unlock()
        handler?(progress)
    }
}

private final class AgentStorageValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let action: (@Sendable () -> Void)?
    private var didRun = false

    init(action: (@Sendable () -> Void)?) {
        self.action = action
    }

    func runOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRun else { return }
        didRun = true
        action?()
    }
}

private final class AgentStorageMetadataProgressReporter {
    private let emitter: AgentStorageProgressEmitter
    private let completedScopes: Int
    private let totalScopes: Int
    private let provider: AgentStorageProvider
    private(set) var activityCount = 0
    private(set) var processedBytes: UInt64 = 0

    init(
        emitter: AgentStorageProgressEmitter,
        completedScopes: Int,
        totalScopes: Int,
        provider: AgentStorageProvider
    ) {
        self.emitter = emitter
        self.completedScopes = completedScopes
        self.totalScopes = totalScopes
        self.provider = provider
    }

    func setActivityCount(_ count: Int) {
        activityCount = max(activityCount, count)
        publish()
    }

    func didProcessItem() {
        activityCount += 1
        publish()
    }

    func didRead(bytes: Int) {
        processedBytes = processedBytes.addingClamped(UInt64(max(0, bytes)))
        publish()
    }

    private func publish() {
        emitter.emit(AgentStorageScanProgress(
            phase: .readingMetadata,
            completedCount: completedScopes,
            totalCount: totalScopes,
            provider: provider,
            activityCount: activityCount,
            processedBytes: processedBytes
        ))
    }
}

private struct AgentStorageProviderScanResult: @unchecked Sendable {
    var engine: AgentStorageScanEngine
}

private struct AgentStorageScanEngine {
    private let configuration: AgentStorageScanner.Configuration
    private var progressEmitter: AgentStorageProgressEmitter
    private let interruptRegistry: AgentSQLiteInterruptRegistry
    private let fileManager = FileManager.default
    private var scopes: [ScanScope] = []
    private var sources: [AgentStorageSource] = []
    private var families: [String: MutableFamily] = [:]
    private var codexTargets: [String: [String: ThreadTarget]] = [:]
    private var codexRelationshipConflictIDs: [String: Set<String>] = [:]
    private var claudeTargets: [String: [String: String]] = [:]
    private var claudeSubagentTargets: [String: [String: [String: String]]] = [:]
    private var claudeToolResultTargets: [String: [String: ClaimOwnership]] = [:]
    private var claudeDesktopPathTargets: [String: ThreadTarget] = [:]
    private var physicalLedger: [FileIdentity: PhysicalEntry] = [:]
    private var globalAggregates: [String: MutableGlobalAggregate] = [:]
    private var unattributedAggregates: [String: MutableUnattributedAggregate] = [:]
    private var skippedEntryCount = 0
    private var unstableEntries = AgentStorageUnstableEntryTracker()
    private var overflowed = false
    private var providerIssueCounts: [AgentStorageProvider: Int] = [:]
    private var providerMetadataOutcomes: [AgentStorageProvider: ProviderMetadataOutcome] = [:]
    private var diagnosticDrafts: [AgentStorageDiagnosticKey: AgentStorageDiagnosticDraft] = [:]
    private var databaseAttributions: [AgentStorageDatabaseAttributionSummary] = []
    private var pendingDatabaseProjections: [PendingDatabaseAttribution] = []
    private var projectResolver = AgentStorageProjectResolver()
    private var measuredEntryCount = 0
    private var measuredAllocatedBytes: UInt64 = 0

    init(
        configuration: AgentStorageScanner.Configuration,
        progressHandler: (@Sendable (AgentStorageScanProgress) -> Void)?,
        interruptRegistry: AgentSQLiteInterruptRegistry
    ) {
        self.configuration = configuration
        progressEmitter = AgentStorageProgressEmitter(handler: progressHandler)
        self.interruptRegistry = interruptRegistry
    }

    mutating func scan() async throws -> AgentStorageSnapshot {
        reportProgress(.discoveringSources, force: true)
        let progressEmitter = progressEmitter
        let configuration = configuration
        let interruptRegistry = interruptRegistry
        let validationGate = AgentStorageValidationGate(
            action: configuration.beforePhysicalValidation
        )

        try await withThrowingTaskGroup(of: AgentStorageProviderScanResult.self) { group in
            for provider in AgentStorageProvider.allCases {
                group.addTask {
                    var providerEngine = AgentStorageScanEngine(
                        configuration: configuration,
                        progressHandler: nil,
                        interruptRegistry: interruptRegistry
                    )
                    providerEngine.progressEmitter = progressEmitter
                    try await providerEngine.scanProvider(
                        provider,
                        validationGate: validationGate
                    )
                    return AgentStorageProviderScanResult(engine: providerEngine)
                }
            }
            for try await result in group {
                try Task.checkCancellation()
                merge(result.engine)
            }
        }

        scopes.sort { $0.id < $1.id }
        sources.sort { $0.id < $1.id }

        reportProgress(
            .organizingResults,
            totalCount: physicalLedger.count,
            force: true
        )
        try resolvePhysicalLedger()
        applyDatabaseAttributionProjections()
        reportProgress(
            .organizingResults,
            completedCount: physicalLedger.count,
            totalCount: physicalLedger.count,
            force: true
        )
        return try makeSnapshot()
    }

    private mutating func scanProvider(
        _ provider: AgentStorageProvider,
        validationGate: AgentStorageValidationGate
    ) async throws {
        reportProgress(.discoveringSources, provider: provider, force: true)
        scopes = discoverScopes(for: provider)
        reportProgress(
            .discoveringSources,
            completedCount: scopes.count,
            totalCount: scopes.count,
            provider: provider,
            force: true
        )
        try Task.checkCancellation()

        let metadataScopes = scopes.filter {
            $0.kind == .codexHome || $0.kind == .claudeCode
        }
        reportProgress(
            .readingMetadata,
            totalCount: metadataScopes.count,
            provider: provider,
            force: true
        )
        for (index, scope) in metadataScopes.enumerated() {
            reportProgress(
                .readingMetadata,
                completedCount: index,
                totalCount: metadataScopes.count,
                provider: provider,
                force: true
            )
            switch scope.kind {
            case .codexHome:
                try loadCodexMetadata(
                    from: scope,
                    completedScopes: index,
                    totalScopes: metadataScopes.count
                )
            case .claudeCode, .claudeDesktopAgent:
                try loadClaudeMetadata(
                    from: scope,
                    completedScopes: index,
                    totalScopes: metadataScopes.count
                )
            case .codexDesktop, .claudeDesktop:
                break
            }
            reportProgress(
                .readingMetadata,
                completedCount: index + 1,
                totalCount: metadataScopes.count,
                provider: provider,
                force: true
            )
        }
        if provider == .claude {
            try loadClaudeDesktopSessionMappings()
        }

        let exclusions = exclusionsByScope()
        reportProgress(.measuringEntries, provider: provider, force: true)
        for scope in scopes {
            try Task.checkCancellation()
            scanPhysicalScope(scope, excluding: exclusions[scope.id] ?? [])
            reportProgress(
                .measuringEntries,
                completedCount: measuredEntryCount,
                provider: provider,
                activityCount: measuredEntryCount,
                processedBytes: measuredAllocatedBytes,
                force: true
            )
        }
        try Task.checkCancellation()
        if !physicalLedger.isEmpty {
            validationGate.runOnce()
        }
        reportProgress(
            .validatingEntries,
            totalCount: physicalLedger.count,
            provider: provider,
            force: true
        )
        try validatePhysicalEntries(provider: provider)

        if provider == .codex {
            reportProgress(
                .attributingDatabase,
                provider: provider,
                force: true
            )
            try await attributeCodexLogDatabases()
        }
        reportProgress(
            .organizingResults,
            completedCount: physicalLedger.count,
            totalCount: physicalLedger.count,
            provider: provider,
            force: true
        )
    }

    private mutating func merge(_ other: AgentStorageScanEngine) {
        scopes.append(contentsOf: other.scopes)
        sources.append(contentsOf: other.sources)
        families.merge(other.families) { current, _ in current }
        codexTargets.merge(other.codexTargets) { current, _ in current }
        codexRelationshipConflictIDs.merge(other.codexRelationshipConflictIDs) {
            $0.union($1)
        }
        claudeTargets.merge(other.claudeTargets) { current, _ in current }
        claudeSubagentTargets.merge(other.claudeSubagentTargets) { current, _ in current }
        claudeToolResultTargets.merge(other.claudeToolResultTargets) { current, _ in current }
        claudeDesktopPathTargets.merge(other.claudeDesktopPathTargets) { current, _ in current }

        for (identity, incoming) in other.physicalLedger {
            guard var existing = physicalLedger[identity] else {
                physicalLedger[identity] = incoming
                continue
            }
            existing.allocatedBytes = max(existing.allocatedBytes, incoming.allocatedBytes)
            existing.logicalBytes = max(existing.logicalBytes, incoming.logicalBytes)
            existing.updatedAt = max(existing.updatedAt, incoming.updatedAt)
            existing.claims.append(contentsOf: incoming.claims)
            existing.observations.append(contentsOf: incoming.observations)
            existing.isStable = existing.isStable && incoming.isStable
            existing.linkCount = max(existing.linkCount, incoming.linkCount)
            physicalLedger[identity] = existing
        }

        skippedEntryCount += other.skippedEntryCount
        unstableEntries.merge(other.unstableEntries)
        overflowed = overflowed || other.overflowed
        for (provider, count) in other.providerIssueCounts {
            providerIssueCounts[provider, default: 0] += count
        }
        for (provider, outcome) in other.providerMetadataOutcomes {
            var current = providerMetadataOutcomes[provider, default: ProviderMetadataOutcome()]
            current.merge(outcome)
            providerMetadataOutcomes[provider] = current
        }
        for (key, incoming) in other.diagnosticDrafts {
            if var current = diagnosticDrafts[key] {
                current.affectedEntityCount += incoming.affectedEntityCount
                current.affectedAllocatedBytes = mergeKnownBytes(
                    current.affectedAllocatedBytes,
                    incoming.affectedAllocatedBytes
                )
                current.absolutePaths.formUnion(incoming.absolutePaths)
                diagnosticDrafts[key] = current
            } else {
                diagnosticDrafts[key] = incoming
            }
        }
        databaseAttributions.append(contentsOf: other.databaseAttributions)
        pendingDatabaseProjections.append(contentsOf: other.pendingDatabaseProjections)
        measuredEntryCount = physicalLedger.count
        measuredAllocatedBytes = physicalLedger.values.reduce(0) {
            $0.addingClamped($1.allocatedBytes)
        }
    }

    private func reportProgress(
        _ phase: AgentStorageScanPhase,
        completedCount: Int = 0,
        totalCount: Int? = nil,
        provider: AgentStorageProvider? = nil,
        activityCount: Int? = nil,
        processedBytes: UInt64? = nil,
        databaseStage: AgentStorageDatabaseScanStage? = nil,
        databaseIndex: Int? = nil,
        databaseCount: Int? = nil,
        force: Bool = false
    ) {
        progressEmitter.emit(AgentStorageScanProgress(
            phase: phase,
            completedCount: completedCount,
            totalCount: totalCount,
            provider: provider,
            activityCount: activityCount,
            processedBytes: processedBytes,
            databaseStage: databaseStage,
            databaseIndex: databaseIndex,
            databaseCount: databaseCount
        ), force: force)
    }

    private mutating func discoverScopes(for requestedProvider: AgentStorageProvider) -> [ScanScope] {
        let home = configuration.homeDirectory.standardizedFileURL
        var candidates: [(URL, AgentStorageProvider, ScanScopeKind, String)] = [
            (home.appending(path: ".codex"), .codex, .codexHome, "Codex Home"),
            (home.appending(path: ".codex-cc"), .codex, .codexHome, "Codex Home"),
            (home.appending(path: ".claude"), .claude, .claudeCode, "Claude Code")
        ]

        if configuration.includesDesktopData {
            let applicationSupport = home.appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )
            candidates.append(contentsOf: [
                (applicationSupport.appending(path: "Codex"), .codex, .codexDesktop, "Codex Desktop"),
                (applicationSupport.appending(path: "com.openai.codex"), .codex, .codexDesktop, "Codex Desktop"),
                (applicationSupport.appending(path: "com.openai.chat"), .codex, .codexDesktop, "Codex Desktop"),
                (applicationSupport.appending(path: "Claude-3p"), .claude, .claudeDesktop, "Claude Desktop"),
                (applicationSupport.appending(path: "Claude"), .claude, .claudeDesktop, "Claude Desktop")
            ])

            if requestedProvider == .claude {
                for desktopRoot in [
                    applicationSupport.appending(path: "Claude-3p"),
                    applicationSupport.appending(path: "Claude")
                ] where fileManager.fileExists(atPath: desktopRoot.path) {
                    let nestedHomes = discoverNestedClaudeHomes(in: desktopRoot)
                    candidates.append(contentsOf: nestedHomes.map {
                        ($0, .claude, .claudeDesktopAgent, "Claude Desktop Agent")
                    })
                }
            }
        }

        for root in configuration.additionalRoots {
            let standardized = root.standardizedFileURL
            if fileManager.fileExists(atPath: standardized.appending(path: "state_5.sqlite").path)
                || fileManager.fileExists(atPath: standardized.appending(path: "sessions").path) {
                candidates.append((standardized, .codex, .codexHome, "Codex Home"))
            } else if fileManager.fileExists(atPath: standardized.appending(path: "projects").path) {
                candidates.append((standardized, .claude, .claudeCode, "Claude Code"))
            }
        }

        var seenPaths: Set<String> = []
        var result: [ScanScope] = []
        for (candidate, provider, kind, displayName) in candidates
        where provider == requestedProvider {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let resolved = canonicalURL(candidate)
            guard seenPaths.insert(resolved.path).inserted else { continue }
            let id = "\(provider.rawValue):\(resolved.path)"
            result.append(ScanScope(
                id: id,
                provider: provider,
                kind: kind,
                root: resolved,
                displayName: displayName
            ))
            sources.append(AgentStorageSource(
                id: id,
                provider: provider,
                displayName: displayName,
                path: resolved.path,
                isAvailable: true,
                isSessionSource: kind == .codexHome || kind == .claudeCode
                    || kind == .claudeDesktopAgent,
                kind: kind.publicKind
            ))
        }
        return result.sorted { $0.root.path < $1.root.path }
    }

    private mutating func discoverNestedClaudeHomes(in desktopRoot: URL) -> [URL] {
        let sessionsRoot = desktopRoot.appending(
            path: "local-agent-mode-sessions",
            directoryHint: .isDirectory
        )
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return [] }
        let enumerationErrors = ScanErrorCounter()
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                enumerationErrors.value += 1
                return true
            }
        ) else {
            recordSkipped(provider: .claude)
            return []
        }

        var result: [URL] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count.isMultiple(of: 128), Task.isCancelled { return result }
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                recordSkipped(provider: .claude)
                continue
            }
            let type = fileStat.st_mode & S_IFMT
            if type == S_IFLNK {
                enumerator.skipDescendants()
                continue
            }
            guard type == S_IFDIR, url.lastPathComponent == ".claude" else { continue }
            let projects = url.appending(path: "projects", directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: projects.path) { result.append(url) }
            enumerator.skipDescendants()
        }
        if enumerationErrors.value > 0 {
            recordSkipped(provider: .claude, count: enumerationErrors.value)
        }
        return result
    }

    private func exclusionsByScope() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for parent in scopes {
            let prefix = parent.root.path.hasSuffix("/") ? parent.root.path : parent.root.path + "/"
            let descendants = scopes
                .filter { $0.id != parent.id && $0.root.path.hasPrefix(prefix) }
                .map(\.root.path)
            if !descendants.isEmpty { result[parent.id] = Set(descendants) }
        }
        return result
    }

    private mutating func loadCodexMetadata(
        from scope: ScanScope,
        completedScopes: Int,
        totalScopes: Int
    ) throws {
        let databaseURL = scope.root.appending(path: "state_5.sqlite")
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            if fileManager.fileExists(atPath: scope.root.appending(path: "sessions").path) {
                recordMetadataOutcome(.unsupported, provider: .codex)
                recordDiagnostic(
                    provider: .codex,
                    sourceID: scope.id,
                    kind: .sourceUnsupportedFormat,
                    area: .dataSource,
                    impact: .chatDiscovery,
                    absolutePath: databaseURL.path
                )
            } else {
                recordMetadataOutcome(.empty, provider: .codex)
            }
            return
        }

        do {
            let metadataProgress = AgentStorageMetadataProgressReporter(
                emitter: progressEmitter,
                completedScopes: completedScopes,
                totalScopes: totalScopes,
                provider: .codex
            )
            let database = try ReadOnlyAgentSQLite(
                path: databaseURL.path,
                interruptRegistry: interruptRegistry
            )
            let snapshot = try database.codexSnapshot { count in
                metadataProgress.setActivityCount(count)
            }
            recordMetadataOutcome(.supported, provider: .codex)
            let records = snapshot.threads
            let edges = snapshot.edges
            if snapshot.issueCount > 0 {
                providerIssueCounts[.codex, default: 0] += snapshot.issueCount
                recordDiagnostic(
                    provider: .codex,
                    sourceID: scope.id,
                    kind: .databaseRecordUnverified,
                    area: .database,
                    impact: .chatDiscovery,
                    affectedEntityCount: snapshot.issueCount,
                    absolutePath: databaseURL.path,
                    entityKey: "thread-records"
                )
            }

            // Older rows can be missing repository metadata even when another thread from the
            // same checkout has it. Learn those exact-path identities before resolving projects.
            for record in records {
                projectResolver.register(
                    cwd: record.cwd,
                    gitOriginURL: record.gitOriginURL
                )
            }

            var recordsByID: [String: CodexThreadRecord] = [:]
            var invalidThreadIDs: Set<String> = []
            for record in records {
                guard recordsByID[record.id] == nil else {
                    invalidThreadIDs.insert(record.id)
                    continue
                }
                recordsByID[record.id] = record
            }

            var parentByChild: [String: String] = [:]
            for edge in edges {
                guard recordsByID[edge.child] != nil, recordsByID[edge.parent] != nil else {
                    invalidThreadIDs.insert(edge.child)
                    continue
                }
                if let existing = parentByChild[edge.child], existing != edge.parent {
                    invalidThreadIDs.insert(edge.child)
                } else {
                    parentByChild[edge.child] = edge.parent
                }
            }

            var rootByThread: [String: String] = [:]
            var depthByThread: [String: Int] = [:]
            for record in records {
                guard !invalidThreadIDs.contains(record.id) else { continue }
                var current = record.id
                var depth = 0
                var visited: Set<String> = []
                var isValid = true
                while let parent = parentByChild[current] {
                    guard visited.insert(current).inserted,
                          recordsByID[parent] != nil,
                          !invalidThreadIDs.contains(parent)
                    else {
                        isValid = false
                        break
                    }
                    current = parent
                    depth += 1
                }
                if depth == 0, record.isSubagent {
                    isValid = false
                }
                if isValid {
                    rootByThread[record.id] = current
                    depthByThread[record.id] = depth
                } else {
                    invalidThreadIDs.insert(record.id)
                }
            }
            let invalidDescendants = rootByThread.compactMap { threadID, rootID in
                invalidThreadIDs.contains(rootID) ? threadID : nil
            }
            for threadID in invalidDescendants {
                invalidThreadIDs.insert(threadID)
                rootByThread.removeValue(forKey: threadID)
                depthByThread.removeValue(forKey: threadID)
            }
            if !invalidThreadIDs.isEmpty {
                providerIssueCounts[.codex, default: 0] += invalidThreadIDs.count
                recordDiagnostic(
                    provider: .codex,
                    sourceID: scope.id,
                    kind: .relationshipConflict,
                    area: .subagent,
                    impact: .threadComposition,
                    affectedEntityCount: invalidThreadIDs.count,
                    absolutePath: databaseURL.path,
                    entityKey: "thread-relationships"
                )
            }
            codexRelationshipConflictIDs[scope.id] = invalidThreadIDs

            var targets: [String: ThreadTarget] = [:]
            for rootID in Set(rootByThread.values) {
                guard let root = recordsByID[rootID] else { continue }
                let familyID = stableFamilyID(provider: .codex, sourceID: scope.id, nativeID: rootID)
                let project = projectResolver.projectName(
                    cwd: root.cwd,
                    gitOriginURL: root.gitOriginURL
                )
                let titleContext = projectResolver.titleContext(
                    cwd: root.cwd,
                    project: project
                )
                let rootNode = MutableNode(
                    id: stableNodeID(familyID: familyID, nativeID: rootID),
                    nativeID: rootID,
                    parentNativeID: nil,
                    depth: 0,
                    title: codexDisplayTitle(root, isSubagent: false, project: titleContext) {
                        bytesRead in
                        metadataProgress.didRead(bytes: bytesRead)
                    },
                    updatedAt: root.updatedAt,
                    path: existingPath(root.rolloutPath)
                )
                families[familyID] = MutableFamily(
                    id: familyID,
                    provider: .codex,
                    sourceID: scope.id,
                    nativeThreadID: rootID,
                    title: rootNode.title,
                    project: project,
                    projectPath: root.cwd,
                    updatedAt: root.updatedAt,
                    isArchived: root.isArchived,
                    mainNodeID: rootNode.id,
                    path: rootNode.path,
                    nodes: [rootNode.id: rootNode]
                )
            }

            for record in records {
                guard let rootID = rootByThread[record.id] else { continue }
                let familyID = stableFamilyID(provider: .codex, sourceID: scope.id, nativeID: rootID)
                guard var family = families[familyID] else { continue }
                let nodeID = stableNodeID(familyID: familyID, nativeID: record.id)
                if record.id != rootID {
                    family.nodes[nodeID] = MutableNode(
                        id: nodeID,
                        nativeID: record.id,
                        parentNativeID: parentByChild[record.id],
                        depth: depthByThread[record.id] ?? 1,
                        title: codexDisplayTitle(
                            record,
                            isSubagent: true,
                            project: family.project
                        ) { bytesRead in
                            metadataProgress.didRead(bytes: bytesRead)
                        },
                        updatedAt: record.updatedAt,
                        path: existingPath(record.rolloutPath)
                    )
                    family.updatedAt = max(family.updatedAt, record.updatedAt)
                    families[familyID] = family
                }
                targets[record.id] = ThreadTarget(familyID: familyID, nodeID: nodeID)
            }
            codexTargets[scope.id] = targets
        } catch is CancellationError {
            throw CancellationError()
        } catch AgentSQLiteError.unsupportedSchema(_) {
            recordMetadataOutcome(.unsupported, provider: .codex)
            recordDiagnostic(
                provider: .codex,
                sourceID: scope.id,
                kind: .sourceUnsupportedFormat,
                area: .dataSource,
                impact: .chatDiscovery,
                absolutePath: databaseURL.path
            )
        } catch {
            recordMetadataOutcome(.unreadable, provider: .codex)
            recordDiagnostic(
                provider: .codex,
                sourceID: scope.id,
                kind: .sourceUnreadable,
                area: .dataSource,
                impact: .chatDiscovery,
                absolutePath: databaseURL.path
            )
        }
    }

    private mutating func loadClaudeMetadata(
        from scope: ScanScope,
        completedScopes: Int,
        totalScopes: Int
    ) throws {
        let projectsURL = scope.root.appending(path: "projects", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: projectsURL.path) else { return }
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            recordSkipped(provider: .claude)
            recordDiagnostic(
                provider: .claude,
                sourceID: scope.id,
                kind: .sourceUnreadable,
                area: .dataSource,
                impact: .chatDiscovery,
                absolutePath: projectsURL.path
            )
            return
        }

        struct MainRecord {
            let sessionID: String
            let file: URL
            let projectDirectory: URL
            let metadata: ClaudeSessionMetadata
        }
        var recordsBySession: [String: [MainRecord]] = [:]
        var sessionDirectories: [String: [URL]] = [:]
        var foundSessionCandidate = false
        var foundUnsupportedFormat = false
        var foundUnreadableData = false
        let metadataProgress = AgentStorageMetadataProgressReporter(
            emitter: progressEmitter,
            completedScopes: completedScopes,
            totalScopes: totalScopes,
            provider: .claude
        )

        for project in projects {
            try Task.checkCancellation()
            var projectStat = stat()
            guard lstat(project.path, &projectStat) == 0 else {
                recordSkipped(provider: .claude)
                continue
            }
            guard (projectStat.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsSubdirectoryDescendants]
                  ) else {
                recordSkipped(provider: .claude)
                continue
            }

            for file in files {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                   let sessionID = normalizedUUID(file.lastPathComponent) {
                    sessionDirectories[sessionID, default: []].append(file)
                    continue
                }
                guard file.pathExtension == "jsonl",
                      let sessionID = normalizedUUID(file.deletingPathExtension().lastPathComponent)
                else { continue }
                foundSessionCandidate = true
                let metadata: ClaudeSessionMetadata
                do {
                    metadata = try ClaudeMetadataReader.read(file) { bytesRead in
                        metadataProgress.didRead(bytes: bytesRead)
                    }
                    metadataProgress.didProcessItem()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    providerIssueCounts[.claude, default: 0] += 1
                    foundUnreadableData = true
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .mainTranscriptUnreadable,
                        area: .mainChat,
                        impact: .chatDiscovery,
                        absolutePath: file.path
                    )
                    continue
                }
                if metadata.validJSONObjectCount > 0,
                   metadata.supportedRecordCount == 0 {
                    foundUnsupportedFormat = true
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .sourceUnsupportedFormat,
                        area: .mainChat,
                        impact: .chatDiscovery,
                        absolutePath: file.path
                    )
                    continue
                }
                if metadata.validJSONObjectCount == 0,
                   metadata.malformedLineCount > 0 {
                    foundUnreadableData = true
                    providerIssueCounts[.claude, default: 0] += 1
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .mainTranscriptUnreadable,
                        area: .mainChat,
                        impact: .chatDiscovery,
                        affectedEntityCount: metadata.malformedLineCount,
                        absolutePath: file.path
                    )
                    continue
                }
                if metadata.malformedLineCount > 0 {
                    foundUnreadableData = true
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .malformedTranscriptRecords,
                        area: .mainChat,
                        impact: .chatMetadata,
                        affectedEntityCount: metadata.malformedLineCount,
                        absolutePath: file.path
                    )
                }
                guard metadata.sessionIDs == [sessionID] else {
                    providerIssueCounts[.claude, default: 0] += 1
                    foundUnreadableData = true
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .sessionIdentityMismatch,
                        area: .mainChat,
                        impact: .chatDiscovery,
                        absolutePath: file.path
                    )
                    continue
                }
                recordsBySession[sessionID, default: []].append(MainRecord(
                    sessionID: sessionID,
                    file: file,
                    projectDirectory: project,
                    metadata: metadata
                ))
            }
        }

        var targets: [String: String] = [:]
        var subagentTargets: [String: [String: String]] = [:]
        var toolResultTargets: [String: ClaimOwnership] = [:]
        for (sessionID, records) in recordsBySession {
            let preferred = records.max { $0.metadata.updatedAt < $1.metadata.updatedAt } ?? records[0]
            let familyID = stableFamilyID(provider: .claude, sourceID: scope.id, nativeID: sessionID)
            let rootNodeID = stableNodeID(familyID: familyID, nativeID: sessionID)
            let recordsByRecency = records.sorted {
                if $0.metadata.updatedAt != $1.metadata.updatedAt {
                    return $0.metadata.updatedAt > $1.metadata.updatedAt
                }
                return $0.file.path < $1.file.path
            }
            let cwd = preferred.metadata.cwd
            let fallbackProject = decodedClaudeProjectName(preferred.projectDirectory.lastPathComponent)
            let project = cwd.map {
                projectResolver.projectName(cwd: $0, gitOriginURL: nil)
            } ?? fallbackProject
            let titleCandidate = recordsByRecency.lazy.compactMap(\.metadata.customTitle).first
                ?? recordsByRecency.lazy.compactMap(\.metadata.aiTitle).first
                ?? recordsByRecency.lazy.compactMap(\.metadata.lastPrompt).first
                ?? recordsByRecency.lazy.compactMap(\.metadata.firstUserPrompt).first
            let title = normalizedTitleCandidate(titleCandidate, excluding: sessionID)
                ?? "\(project) · \(storageTitleDate(preferred.metadata.updatedAt))"
            let rootNode = MutableNode(
                id: rootNodeID,
                nativeID: sessionID,
                parentNativeID: nil,
                depth: 0,
                title: title,
                updatedAt: preferred.metadata.updatedAt,
                path: preferred.file.path
            )
            var family = MutableFamily(
                id: familyID,
                provider: .claude,
                sourceID: scope.id,
                nativeThreadID: sessionID,
                title: title,
                project: project,
                projectPath: cwd,
                updatedAt: preferred.metadata.updatedAt,
                isArchived: false,
                mainNodeID: rootNodeID,
                path: preferred.file.path,
                nodes: [rootNodeID: rootNode]
            )

            let allSessionDirectories = sessionDirectories[sessionID] ?? []
            var candidates: [String: ClaudeAgentCandidate] = [:]
            var toolFilesByName: [String: [URL]] = [:]

            for sessionDirectory in allSessionDirectories {
                try collectClaudeAgentCandidates(
                    below: sessionDirectory.appending(path: "subagents", directoryHint: .isDirectory),
                    into: &candidates
                )
                try collectClaudeToolResults(
                    below: sessionDirectory.appending(path: "tool-results", directoryHint: .isDirectory),
                    into: &toolFilesByName
                )
            }

            var knownAgents: [String: String] = [:]
            var validAgentTranscripts: [String: [URL]] = [:]
            var validAgentUpdatedAt: [String: Date] = [:]
            for (agentID, candidate) in candidates.sorted(by: { $0.key < $1.key }) {
                var validJSONLs: [URL] = []
                for file in candidate.jsonlFiles {
                    do {
                        let metadata = try ClaudeMetadataReader.read(file) { bytesRead in
                            metadataProgress.didRead(bytes: bytesRead)
                        }
                        metadataProgress.didProcessItem()
                        if metadata.sessionIDs == [sessionID], metadata.agentIDs == [agentID] {
                            validJSONLs.append(file)
                            validAgentUpdatedAt[agentID] = max(
                                validAgentUpdatedAt[agentID] ?? .distantPast,
                                metadata.updatedAt
                            )
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        continue
                    }
                }
                if !candidate.jsonlFiles.isEmpty, validJSONLs.isEmpty {
                    providerIssueCounts[.claude, default: 0] += 1
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .subagentTranscriptUnverified,
                        area: .subagent,
                        impact: .threadComposition,
                        affectedEntityCount: candidate.jsonlFiles.count,
                        absolutePath: candidate.jsonlFiles.first?.path,
                        entityKey: agentID
                    )
                    continue
                }
                if validJSONLs.isEmpty, candidate.metadataFiles.isEmpty { continue }

                let nodeID = stableNodeID(familyID: familyID, nativeID: agentID)
                let agentMetadata = candidate.metadataFiles.lazy
                    .compactMap { claudeAgentMetadata(from: $0, agentID: agentID) }
                    .first
                let representative = validJSONLs.first ?? candidate.metadataFiles[0]
                let updatedAt = validAgentUpdatedAt[agentID].flatMap {
                    $0 == .distantPast ? nil : $0
                } ?? fileModificationDate(representative) ?? preferred.metadata.updatedAt
                let title = normalizedTitleCandidate(agentMetadata?.title, excluding: agentID)
                    ?? "Subagent · \(storageTitleDate(updatedAt))"
                family.nodes[nodeID] = MutableNode(
                    id: nodeID,
                    nativeID: agentID,
                    parentNativeID: sessionID,
                    depth: max(1, agentMetadata?.spawnDepth ?? 1),
                    title: title,
                    updatedAt: updatedAt,
                    path: representative.path
                )
                knownAgents[agentID] = nodeID
                validAgentTranscripts[agentID] = validJSONLs
                if validJSONLs.isEmpty {
                    providerIssueCounts[.claude, default: 0] += 1
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .subagentMetadataOnly,
                        area: .subagent,
                        impact: .threadComposition,
                        affectedEntityCount: candidate.metadataFiles.count,
                        absolutePath: candidate.metadataFiles.first?.path,
                        entityKey: agentID
                    )
                }
            }

            var ownersByToolPath: [String: Set<String>] = [:]
            let uniqueToolFiles = toolFilesByName.filter { $0.value.count == 1 }
            for record in records {
                for path in ClaudeToolReferenceReader.references(
                    in: record.file,
                    candidates: uniqueToolFiles,
                    onRead: { bytesRead in
                        metadataProgress.didRead(bytes: bytesRead)
                    }
                ) {
                    ownersByToolPath[path, default: []].insert(rootNodeID)
                }
            }
            for (agentID, transcripts) in validAgentTranscripts {
                guard let nodeID = knownAgents[agentID] else { continue }
                for transcript in transcripts {
                    for path in ClaudeToolReferenceReader.references(
                        in: transcript,
                        candidates: uniqueToolFiles,
                        onRead: { bytesRead in
                            metadataProgress.didRead(bytes: bytesRead)
                        }
                    ) {
                        ownersByToolPath[path, default: []].insert(nodeID)
                    }
                }
            }
            for files in toolFilesByName.values {
                if files.count > 1 {
                    providerIssueCounts[.claude, default: 0] += 1
                    recordDiagnostic(
                        provider: .claude,
                        sourceID: scope.id,
                        kind: .ambiguousToolResult,
                        area: .toolResult,
                        impact: .threadComposition,
                        affectedEntityCount: files.count,
                        absolutePath: files.first?.path,
                        absolutePaths: files.map(\.path),
                        entityKey: files.first?.lastPathComponent
                    )
                }
                for file in files {
                    let path = file.standardizedFileURL.path
                    let owners = ownersByToolPath[path] ?? []
                    if owners.count == 1, let nodeID = owners.first {
                        toolResultTargets[path] = .node(familyID, nodeID)
                    } else {
                        toolResultTargets[path] = .familyOther(familyID)
                    }
                }
            }
            family.updatedAt = max(
                family.updatedAt,
                family.nodes.values.map(\.updatedAt).max() ?? family.updatedAt
            )
            families[familyID] = family
            targets[sessionID] = familyID
            subagentTargets[sessionID] = knownAgents
        }
        claudeTargets[scope.id] = targets
        claudeSubagentTargets[scope.id] = subagentTargets
        claudeToolResultTargets[scope.id] = toolResultTargets
        if !recordsBySession.isEmpty {
            recordMetadataOutcome(.supported, provider: .claude)
            if foundUnsupportedFormat {
                recordMetadataOutcome(.unsupported, provider: .claude)
            }
            if foundUnreadableData {
                recordMetadataOutcome(.unreadable, provider: .claude)
            }
        } else if foundUnsupportedFormat {
            recordMetadataOutcome(.unsupported, provider: .claude)
        } else if foundUnreadableData || foundSessionCandidate {
            recordMetadataOutcome(.unreadable, provider: .claude)
        } else {
            recordMetadataOutcome(.empty, provider: .claude)
        }
    }

    private mutating func loadClaudeDesktopSessionMappings() throws {
        var targetsByNativeID: [String: Set<ThreadTarget>] = [:]
        for targets in claudeTargets.values {
            for (nativeID, familyID) in targets {
                targetsByNativeID[nativeID, default: []].insert(ThreadTarget(
                    familyID: familyID,
                    nodeID: stableNodeID(familyID: familyID, nativeID: nativeID)
                ))
            }
        }

        for scope in scopes where scope.kind == .claudeDesktop {
            for relativeRoot in ["local-agent-mode-sessions", "claude-code-sessions"] {
                let root = scope.root.appending(path: relativeRoot, directoryHint: .isDirectory)
                guard fileManager.fileExists(atPath: root.path),
                      let enumerator = fileManager.enumerator(
                        at: root,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                      ) else { continue }
                var count = 0
                for case let url as URL in enumerator {
                    count += 1
                    if count.isMultiple(of: 64) { try Task.checkCancellation() }
                    guard url.pathExtension == "json",
                          url.lastPathComponent.hasPrefix("local_") else { continue }
                    var fileStat = stat()
                    guard lstat(url.path, &fileStat) == 0,
                          (fileStat.st_mode & S_IFMT) == S_IFREG,
                          fileStat.st_size <= 1_048_576,
                          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let nativeIDs = [object["cliSessionId"], object["sessionId"]]
                        .compactMap { $0 as? String }
                        .compactMap(normalizedUUID)
                    let matches = Set(nativeIDs.flatMap { targetsByNativeID[$0] ?? [] })
                    guard matches.count == 1, let target = matches.first else { continue }
                    claudeDesktopPathTargets[url.standardizedFileURL.path] = target
                    let sibling = url.deletingPathExtension()
                    var siblingStat = stat()
                    if lstat(sibling.path, &siblingStat) == 0,
                       (siblingStat.st_mode & S_IFMT) == S_IFDIR {
                        claudeDesktopPathTargets[sibling.standardizedFileURL.path] = target
                    }
                }
            }
        }
    }

    private func codexDisplayTitle(
        _ record: CodexThreadRecord,
        isSubagent: Bool,
        project: String,
        onRead: ((Int) -> Void)? = nil
    ) -> String {
        if let title = normalizedTitleCandidate(record.displayTitle, excluding: record.id) {
            return title
        }
        if let rollout = existingPath(record.rolloutPath),
           let title = CodexRolloutTitleReader.title(
               at: URL(fileURLWithPath: rollout),
               onRead: onRead
           ) {
            return title
        }
        let date = storageTitleDate(record.updatedAt)
        if isSubagent { return "Subagent · \(date)" }
        return "\(project) · \(date)"
    }

    private mutating func collectClaudeAgentCandidates(
        below root: URL,
        into candidates: inout [String: ClaudeAgentCandidate]
    ) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let enumerationErrors = ScanErrorCounter()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                enumerationErrors.value += 1
                return true
            }
        ) else {
            recordSkipped(provider: .claude)
            return
        }

        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count.isMultiple(of: 128) { try Task.checkCancellation() }
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                recordSkipped(provider: .claude)
                continue
            }
            let type = fileStat.st_mode & S_IFMT
            if type == S_IFLNK {
                enumerator.skipDescendants()
                continue
            }
            guard type == S_IFREG,
                  let agentID = claudeAgentID(from: url.lastPathComponent)
            else { continue }

            var candidate = candidates[agentID] ?? ClaudeAgentCandidate()
            if url.lastPathComponent.hasSuffix(".meta.json") {
                candidate.metadataFiles.append(url)
            } else {
                candidate.jsonlFiles.append(url)
            }
            candidates[agentID] = candidate
        }
        if enumerationErrors.value > 0 {
            recordSkipped(provider: .claude, count: enumerationErrors.value)
        }
    }

    private mutating func collectClaudeToolResults(
        below root: URL,
        into filesByName: inout [String: [URL]]
    ) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let enumerationErrors = ScanErrorCounter()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                enumerationErrors.value += 1
                return true
            }
        ) else {
            recordSkipped(provider: .claude)
            return
        }

        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count.isMultiple(of: 128) { try Task.checkCancellation() }
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                recordSkipped(provider: .claude)
                continue
            }
            let type = fileStat.st_mode & S_IFMT
            if type == S_IFLNK {
                enumerator.skipDescendants()
                continue
            }
            guard type == S_IFREG else { continue }
            filesByName[url.lastPathComponent, default: []].append(url)
        }
        if enumerationErrors.value > 0 {
            recordSkipped(provider: .claude, count: enumerationErrors.value)
        }
    }

    private mutating func scanPhysicalScope(_ scope: ScanScope, excluding exclusions: Set<String>) {
        var rootStat = stat()
        if lstat(scope.root.path, &rootStat) == 0 {
            recordPhysicalEntry(url: scope.root, stat: rootStat, scope: scope)
            measuredEntryCount += 1
        } else {
            recordSkipped(provider: scope.provider)
            return
        }

        let enumerationErrors = ScanErrorCounter()
        guard let enumerator = fileManager.enumerator(
            at: scope.root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                enumerationErrors.value += 1
                return true
            }
        ) else {
            recordSkipped(provider: scope.provider)
            return
        }

        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count.isMultiple(of: 128), Task.isCancelled { return }
            if exclusions.contains(url.standardizedFileURL.path) {
                enumerator.skipDescendants()
                continue
            }
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                recordSkipped(provider: scope.provider)
                continue
            }
            let fileType = fileStat.st_mode & S_IFMT
            if fileType == S_IFLNK {
                enumerator.skipDescendants()
            }
            recordPhysicalEntry(url: url, stat: fileStat, scope: scope)
            measuredEntryCount += 1
            if measuredEntryCount.isMultiple(of: 256) {
                reportProgress(
                    .measuringEntries,
                    completedCount: measuredEntryCount,
                    provider: scope.provider,
                    activityCount: measuredEntryCount,
                    processedBytes: measuredAllocatedBytes
                )
            }
        }
        if enumerationErrors.value > 0 {
            recordSkipped(provider: scope.provider, count: enumerationErrors.value)
        }
    }

    private mutating func recordPhysicalEntry(url: URL, stat fileStat: stat, scope: ScanScope) {
        let identity = FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino)
        )
        let blockCount = UInt64(max(0, fileStat.st_blocks))
        let allocatedResult = blockCount.multipliedReportingOverflow(by: 512)
        if allocatedResult.overflow { overflowed = true }
        let allocated = allocatedResult.overflow ? UInt64.max : allocatedResult.partialValue
        let logical = UInt64(max(0, fileStat.st_size))
        let updatedAt = Date(
            timeIntervalSince1970: TimeInterval(fileStat.st_mtimespec.tv_sec)
                + TimeInterval(fileStat.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let claim = classify(url: url, scope: scope)
        let observation = FileObservation(
            path: url.path,
            signature: FileStatSignature(fileStat),
            fileType: fileStat.st_mode & S_IFMT,
            provider: scope.provider
        )
        if var existing = physicalLedger[identity] {
            if existing.allocatedBytes != allocated || existing.logicalBytes != logical {
                let affectedProviders = Set(existing.observations.map(\.provider))
                    .union([scope.provider])
                for provider in affectedProviders {
                    unstableEntries.mark(
                        device: identity.device,
                        inode: identity.inode,
                        provider: provider
                    )
                }
                existing.allocatedBytes = max(existing.allocatedBytes, allocated)
                existing.logicalBytes = max(existing.logicalBytes, logical)
                existing.isStable = false
            }
            existing.updatedAt = max(existing.updatedAt, updatedAt)
            existing.claims.append(claim)
            existing.observations.append(observation)
            physicalLedger[identity] = existing
        } else {
            physicalLedger[identity] = PhysicalEntry(
                identity: identity,
                allocatedBytes: allocated,
                logicalBytes: logical,
                updatedAt: updatedAt,
                claims: [claim],
                observations: [observation],
                isStable: true,
                linkCount: UInt64(max(0, fileStat.st_nlink))
            )
            measuredAllocatedBytes = measuredAllocatedBytes.addingClamped(allocated)
        }
    }

    private mutating func validatePhysicalEntries(provider: AgentStorageProvider) throws {
        var count = 0
        for (identity, originalEntry) in physicalLedger {
            var entry = originalEntry
            count += 1
            if count.isMultiple(of: 128) {
                try Task.checkCancellation()
                reportProgress(
                    .validatingEntries,
                    completedCount: count,
                    totalCount: physicalLedger.count,
                    provider: provider
                )
            }
            var checkedObservations: Set<String> = []
            for observation in entry.observations {
                let observationKey = "\(observation.provider.rawValue)\0\(observation.path)"
                guard checkedObservations.insert(observationKey).inserted else { continue }
                var current = stat()
                let isStable = lstat(observation.path, &current) == 0
                    && (current.st_mode & S_IFMT) == observation.fileType
                    && FileIdentity(
                        device: UInt64(current.st_dev),
                        inode: UInt64(current.st_ino)
                    ) == identity
                    && FileStatSignature(current) == observation.signature
                guard isStable else {
                    entry.isStable = false
                    unstableEntries.mark(
                        device: identity.device,
                        inode: identity.inode,
                        provider: observation.provider
                    )
                    continue
                }
            }
            physicalLedger[identity] = entry
        }
        reportProgress(
            .validatingEntries,
            completedCount: physicalLedger.count,
            totalCount: physicalLedger.count,
            provider: provider,
            force: true
        )
    }

    private func classify(url: URL, scope: ScanScope) -> PhysicalClaim {
        let relative = relativePath(of: url, under: scope.root)
        let components = relative.split(separator: "/").map(String.init)
        switch scope.kind {
        case .codexHome:
            return classifyCodex(
                path: url.path,
                relativePath: relative,
                components: components,
                scope: scope
            )
        case .claudeCode, .claudeDesktopAgent:
            return classifyClaude(
                path: url.path,
                relativePath: relative,
                components: components,
                scope: scope
            )
        case .codexDesktop:
            return desktopClaim(
                path: url.path,
                relativePath: relative,
                components: components,
                scope: scope,
                isClaude: false
            )
        case .claudeDesktop:
            return desktopClaim(
                path: url.path,
                relativePath: relative,
                components: components,
                scope: scope,
                isClaude: true
            )
        }
    }

    private func classifyCodex(
        path: String,
        relativePath: String,
        components: [String],
        scope: ScanScope
    ) -> PhysicalClaim {
        let first = components.first ?? ""
        if first == "sessions" || first == "archived_sessions" {
            if let nativeID = extractUUID(from: components.last ?? "") {
                if let target = codexTargets[scope.id]?[nativeID] {
                    return claim(scope, path, .node(target.familyID, target.nodeID), .conversation)
                }
                if codexRelationshipConflictIDs[scope.id]?.contains(nativeID) == true {
                    return claim(scope, path, .unattributed(.relationshipConflict), .conversation)
                }
            }
            if relativePath.hasSuffix(".jsonl") {
                return claim(scope, path, .unattributed(.missingThreadMetadata), .conversation)
            }
            return claim(scope, path, .global(.directoryOverhead), .other)
        }
        if first == "shell_snapshots" {
            if let nativeID = extractUUID(from: components.last ?? ""),
               let target = codexTargets[scope.id]?[nativeID] {
                return claim(scope, path, .node(target.familyID, target.nodeID), .snapshot)
            }
            return claim(scope, path, .unattributed(.shellSnapshot), .snapshot)
        }
        if first == "visualizations" {
            if let nativeID = components.lazy.compactMap(extractUUID(from:)).first,
               let target = codexTargets[scope.id]?[nativeID] {
                return claim(scope, path, .node(target.familyID, target.nodeID), .snapshot)
            }
            return claim(scope, path, .unattributed(.unverifiedReference), .snapshot)
        }
        if first == "attachments" || first == "generated_images" {
            return claim(scope, path, .unattributed(.unverifiedReference), .attachment)
        }
        if first == "worktrees" {
            return claim(scope, path, .unattributed(.managedWorktree), .other)
        }
        if first == "browser" || first == "computer-use" || first == "node_repl" {
            return claim(scope, path, .global(first == "browser" ? .browser : .runtime), .other)
        }
        if ["plugins", "skills", "vendor_imports"].contains(first) {
            return claim(scope, path, .global(.tools), .other)
        }
        if ["cache", "tmp", ".tmp"].contains(first) {
            return claim(scope, path, .global(.cache), .other)
        }
        let name = components.last ?? ""
        if name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal")
            || name.hasSuffix(".sqlite-shm") {
            return claim(scope, path, .global(.sharedDatabase), .other)
        }
        if ["auth.json", "auth-image.json", "config.toml", "rules"].contains(first) {
            return claim(scope, path, .global(.configuration), .other)
        }
        return claim(scope, path, .global(.other), .other)
    }

    private func classifyClaude(
        path: String,
        relativePath: String,
        components: [String],
        scope: ScanScope
    ) -> PhysicalClaim {
        let first = components.first ?? ""
        if first == "projects", components.count >= 3 {
            let sessionID: String?
            if components.count == 3, relativePath.hasSuffix(".jsonl") {
                sessionID = normalizedUUID(String(components[2].dropLast(".jsonl".count)))
            } else {
                sessionID = normalizedUUID(components[2])
            }
            if let sessionID, let familyID = claudeTargets[scope.id]?[sessionID] {
                let rootNodeID = stableNodeID(familyID: familyID, nativeID: sessionID)
                if components.count == 3, relativePath.hasSuffix(".jsonl") {
                    return claim(scope, path, .node(familyID, rootNodeID), .conversation)
                }
                if components.count >= 4, components[3] == "subagents" {
                    if let agentID = claudeAgentID(from: components.last ?? ""),
                       let nodeID = claudeSubagentTargets[scope.id]?[sessionID]?[agentID] {
                        return claim(scope, path, .node(familyID, nodeID), .subagent)
                    }
                    return claim(scope, path, .familyOther(familyID), .subagent)
                }
                if components.count >= 4, components[3] == "tool-results" {
                    let ownership = claudeToolResultTargets[scope.id]?[urlPathKey(path)]
                        ?? .familyOther(familyID)
                    return claim(scope, path, ownership, .toolResult)
                }
                if components.count >= 4, components[3] == "workflows" {
                    return claim(scope, path, .familyOther(familyID), .workflow)
                }
                return claim(scope, path, .familyOther(familyID), .other)
            }
            if relativePath.hasSuffix(".jsonl") || components.count >= 3 {
                return claim(scope, path, .unattributed(.missingThreadMetadata), .conversation)
            }
        }

        if ["file-history", "tasks", "session-env"].contains(first), components.count >= 2 {
            guard let sessionID = normalizedUUID(components[1]) else {
                return claim(scope, path, .unattributed(.missingThreadMetadata), .other)
            }
            if let familyID = claudeTargets[scope.id]?[sessionID] {
                let rootNodeID = stableNodeID(familyID: familyID, nativeID: sessionID)
                let category: AgentStorageArtifactCategory = first == "file-history"
                    ? .fileHistory
                    : (first == "tasks" ? .task : .other)
                return claim(scope, path, .node(familyID, rootNodeID), category)
            }
            return claim(scope, path, .unattributed(.missingThreadMetadata), .other)
        }
        if first == "paste-cache" {
            return claim(scope, path, .unattributed(.pasteCache), .other)
        }
        if first == "shell-snapshots" {
            return claim(scope, path, .unattributed(.shellSnapshot), .snapshot)
        }
        if first == "plans" {
            return claim(scope, path, .unattributed(.unverifiedReference), .attachment)
        }
        if first == "projects" || first == "file-history" || first == "tasks"
            || first == "session-env" {
            return claim(scope, path, .global(.directoryOverhead), .other)
        }
        if first == "backups" || first == "telemetry" {
            return claim(scope, path, .global(first == "backups" ? .cache : .other), .other)
        }
        return claim(scope, path, .global(.configuration), .other)
    }

    private func desktopClaim(
        path: String,
        relativePath: String,
        components: [String],
        scope: ScanScope,
        isClaude: Bool
    ) -> PhysicalClaim {
        let first = components.first ?? ""
        if isClaude, let target = claudeDesktopTarget(for: path) {
            return claim(scope, path, .node(target.familyID, target.nodeID), .conversation)
        }
        if isClaude, ["vm_bundles", "claude-code", "claude-code-vm", "local-agent-mode-sessions"].contains(first) {
            return claim(scope, path, .global(.runtime), .other)
        }
        if ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad"].contains(first) {
            return claim(scope, path, .global(.cache), .other)
        }
        if ["Partitions", "Session Storage", "Local Storage", "IndexedDB", "WebStorage", "blob_storage"].contains(first) {
            return claim(scope, path, .global(.browser), .other)
        }
        if first == "claude-code-sessions" {
            return claim(scope, path, .global(.sharedAgentData), .other)
        }
        return claim(scope, path, .global(relativePath.isEmpty ? .directoryOverhead : .other), .other)
    }

    private func claudeDesktopTarget(for path: String) -> ThreadTarget? {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        while !candidate.isEmpty {
            if let target = claudeDesktopPathTargets[candidate] { return target }
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    private func claim(
        _ scope: ScanScope,
        _ path: String,
        _ ownership: ClaimOwnership,
        _ category: AgentStorageArtifactCategory
    ) -> PhysicalClaim {
        PhysicalClaim(
            provider: scope.provider,
            sourceID: scope.id,
            path: path,
            ownership: ownership,
            artifactCategory: category
        )
    }

    private mutating func resolvePhysicalLedger() throws {
        var count = 0
        for entry in physicalLedger.values {
            count += 1
            if count.isMultiple(of: 128) {
                try Task.checkCancellation()
                reportProgress(
                    .organizingResults,
                    completedCount: count,
                    totalCount: physicalLedger.count
                )
            }
            let providers = Set(entry.claims.map(\.provider))
            if providers.count > 1 {
                addGlobal(
                    provider: nil,
                    category: .crossAgentShared,
                    entry: entry,
                    path: entry.claims.map(\.path).sorted().first
                )
                continue
            }

            let claims = entry.claims.sorted { $0.sortKey < $1.sortKey }
            let familyIDs = Set(claims.compactMap(\.familyID))
            if familyIDs.count > 1 {
                addGlobal(
                    provider: providers.first,
                    category: .sharedAgentData,
                    entry: entry,
                    path: claims.first?.path
                )
                continue
            }
            if let familyID = familyIDs.first {
                let nodeIDs = Set(claims.compactMap(\.nodeID))
                let hasNonFamilyClaim = claims.contains { $0.familyID == nil }
                if nodeIDs.count == 1, !hasNonFamilyClaim,
                   claims.allSatisfy({
                       if case .node = $0.ownership { return true }
                       return false
                   }), let nodeID = nodeIDs.first {
                    addToFamily(
                        familyID: familyID,
                        nodeID: nodeID,
                        entry: entry,
                        category: claims[0].artifactCategory,
                        path: claims[0].path
                    )
                } else if !hasNonFamilyClaim {
                    addToFamilyOther(
                        familyID: familyID,
                        entry: entry,
                        category: claims[0].artifactCategory,
                        path: claims[0].path
                    )
                } else {
                    addGlobal(
                        provider: providers.first,
                        category: .sharedAgentData,
                        entry: entry,
                        path: claims.first?.path
                    )
                }
                continue
            }

            if let global = claims.compactMap(\.globalCategory).first {
                addGlobal(
                    provider: providers.first,
                    category: global,
                    entry: entry,
                    path: claims.first?.path
                )
            } else {
                let reason = claims.compactMap(\.unattributedReason).first ?? .unknown
                addUnattributed(
                    provider: providers.first ?? claims[0].provider,
                    reason: reason,
                    entry: entry,
                    path: claims.first?.path
                )
            }
        }
    }

    private mutating func attributeCodexLogDatabases() async throws {
        let bundles = codexLogDatabaseBundles()
        let progressCoordinator = CodexLogDatabaseProgressCoordinator(
            emitter: progressEmitter,
            databaseCount: bundles.count
        )
        var preparationFailures: [Int: CodexLogDatabaseReadFailure] = [:]
        var snapshotsByBundle: [Int: [CodexLogEstimateSnapshot]] = [:]
        var shards: [CodexLogScanShard] = []

        for (bundleOffset, bundle) in bundles.enumerated() {
            try Task.checkCancellation()
            reportProgress(
                .attributingDatabase,
                completedCount: progressCoordinator.totals.completedCount,
                provider: .codex,
                activityCount: progressCoordinator.totals.completedCount,
                processedBytes: progressCoordinator.totals.processedBytes,
                databaseStage: .preparing,
                databaseIndex: bundleOffset + 1,
                databaseCount: bundles.count,
                force: true
            )
            if bundle.capability == .ambiguous {
                preparationFailures[bundleOffset] = CodexLogDatabaseReadFailure(
                    status: .ambiguousOwnership,
                    diagnosticComponent: nil
                )
                progressCoordinator.markBundleCompleted(bundleOffset)
                continue
            }
            if bundle.capability == .sidecarsUnavailable {
                preparationFailures[bundleOffset] = CodexLogDatabaseReadFailure(
                    status: .unavailable,
                    diagnosticComponent: nil
                )
                progressCoordinator.markBundleCompleted(bundleOffset)
                continue
            }

            do {
                let database = try ReadOnlyAgentSQLite(
                    path: bundle.mainPath,
                    expectedIdentity: bundle.mainIdentity,
                    interruptRegistry: interruptRegistry
                )
                guard let bounds = try database.codexLogScanBounds() else {
                    snapshotsByBundle[bundleOffset] = [.empty]
                    progressCoordinator.markBundleCompleted(bundleOffset)
                    continue
                }
                shards.append(contentsOf: CodexLogScanShard.makeShards(
                    bundleIndex: bundleOffset,
                    bundleID: bundle.id,
                    path: bundle.mainPath,
                    expectedIdentity: bundle.mainIdentity,
                    bounds: bounds,
                    maximumShardCount: configuration.databaseReadConcurrency
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AgentSQLiteError {
                if case .interrupted = error, interruptRegistry.cancellationRequested() {
                    throw CancellationError()
                }
                preparationFailures[bundleOffset] = CodexLogDatabaseReadFailure(
                    status: error.attributionStatus,
                    diagnosticComponent: error.diagnosticComponent
                )
                progressCoordinator.markBundleCompleted(bundleOffset)
            } catch {
                preparationFailures[bundleOffset] = CodexLogDatabaseReadFailure(
                    status: error is DatabaseAttributionMathError ? .unreadable : .unavailable,
                    diagnosticComponent: error is DatabaseAttributionMathError
                        ? "attribution arithmetic" : nil
                )
                progressCoordinator.markBundleCompleted(bundleOffset)
            }
        }

        var shardFailures: [Int: CodexLogDatabaseReadFailure] = [:]
        var remainingShardCounts = Dictionary(grouping: shards, by: \.bundleIndex)
            .mapValues(\.count)
        let interruptRegistry = interruptRegistry
        let shardDidStart = configuration.databaseShardDidStart
        let maximumConcurrentReads = min(configuration.databaseReadConcurrency, shards.count)
        var shardIterator = shards.makeIterator()
        try await withThrowingTaskGroup(of: CodexLogShardReadOutcome.self) { group in
            func scheduleNextShard() {
                guard let shard = shardIterator.next() else { return }
                group.addTask {
                    try Self.readCodexLogShard(
                        shard,
                        interruptRegistry: interruptRegistry,
                        progressCoordinator: progressCoordinator,
                        shardDidStart: shardDidStart
                    )
                }
            }

            for _ in 0..<maximumConcurrentReads { scheduleNextShard() }
            while let outcome = try await group.next() {
                switch outcome.result {
                case .success(let snapshot):
                    snapshotsByBundle[outcome.bundleIndex, default: []].append(snapshot)
                case .failure(let failure):
                    if shardFailures[outcome.bundleIndex] == nil {
                        shardFailures[outcome.bundleIndex] = failure
                    }
                }
                if let remaining = remainingShardCounts[outcome.bundleIndex] {
                    let nextRemaining = remaining - 1
                    remainingShardCounts[outcome.bundleIndex] = nextRemaining
                    if nextRemaining == 0 {
                        progressCoordinator.markBundleCompleted(outcome.bundleIndex)
                    }
                }
                scheduleNextShard()
            }
        }

        for (bundleOffset, bundle) in bundles.enumerated() {
            if let failure = preparationFailures[bundleOffset] ?? shardFailures[bundleOffset] {
                databaseAttributions.append(bundle.summary(
                    status: failure.status,
                    diagnosticComponent: failure.diagnosticComponent
                ))
                continue
            }
            do {
                let raw = try Self.mergeCodexLogSnapshots(
                    snapshotsByBundle[bundleOffset] ?? [.empty]
                )
                let totals = progressCoordinator.totals
                reportProgress(
                    .attributingDatabase,
                    completedCount: totals.completedCount,
                    provider: .codex,
                    activityCount: totals.completedCount,
                    processedBytes: totals.processedBytes,
                    databaseStage: .mappingRecords,
                    databaseIndex: bundleOffset + 1,
                    databaseCount: bundles.count,
                    force: true
                )
                let projection = try projectDatabaseEstimates(raw, bundle: bundle)
                let summary = AgentStorageDatabaseAttributionSummary(
                    id: bundle.id,
                    provider: .codex,
                    sourceID: bundle.sourceID,
                    path: bundle.mainPath,
                    physicalBundleBytes: bundle.physicalAllocatedBytes,
                    attributedBytes: projection.attributedBytes,
                    residualBytes: bundle.physicalAllocatedBytes - projection.attributedBytes,
                    mappedEstimatedBytes: projection.mappedEstimatedBytes,
                    unmappedEstimatedBytes: projection.unmappedEstimatedBytes,
                    processedRowCount: raw.processedRowCount,
                    totalRowCount: raw.totalRowCount,
                    status: .completed
                )
                pendingDatabaseProjections.append(PendingDatabaseAttribution(
                    bundle: bundle,
                    projection: projection,
                    summary: summary
                ))
            } catch {
                databaseAttributions.append(bundle.summary(
                    status: .unreadable,
                    diagnosticComponent: "attribution arithmetic"
                ))
            }
        }

        let finalTotals = progressCoordinator.totals
        reportProgress(
            .attributingDatabase,
            completedCount: finalTotals.completedCount,
            totalCount: finalTotals.completedCount,
            provider: .codex,
            activityCount: finalTotals.completedCount,
            processedBytes: finalTotals.processedBytes,
            databaseStage: .mappingRecords,
            databaseIndex: bundles.isEmpty ? nil : bundles.count,
            databaseCount: bundles.isEmpty ? nil : bundles.count,
            force: true
        )
    }

    private static func readCodexLogShard(
        _ shard: CodexLogScanShard,
        interruptRegistry: AgentSQLiteInterruptRegistry,
        progressCoordinator: CodexLogDatabaseProgressCoordinator,
        shardDidStart: (@Sendable (String) -> Void)?
    ) throws -> CodexLogShardReadOutcome {
        try Task.checkCancellation()
        var processedHighWater = 0
        var estimatedBytesHighWater: UInt64 = 0
        do {
            let database = try ReadOnlyAgentSQLite(
                path: shard.path,
                expectedIdentity: shard.expectedIdentity,
                interruptRegistry: interruptRegistry
            )
            shardDidStart?(shard.id)
            try Task.checkCancellation()
            let snapshot = try database.codexLogEstimates(in: shard.range) {
                processed,
                estimatedBytes,
                force in
                processedHighWater = max(processedHighWater, processed)
                estimatedBytesHighWater = max(estimatedBytesHighWater, estimatedBytes)
                progressCoordinator.update(
                    shard: shard,
                    processedCount: processed,
                    processedBytes: estimatedBytes,
                    force: force
                )
            }
            return CodexLogShardReadOutcome(
                bundleIndex: shard.bundleIndex,
                result: .success(snapshot)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentSQLiteError {
            if case .interrupted = error,
               Task.isCancelled || interruptRegistry.cancellationRequested() {
                throw CancellationError()
            }
            progressCoordinator.update(
                shard: shard,
                processedCount: processedHighWater,
                processedBytes: estimatedBytesHighWater,
                force: true
            )
            return CodexLogShardReadOutcome(
                bundleIndex: shard.bundleIndex,
                result: .failure(CodexLogDatabaseReadFailure(
                    status: error.attributionStatus,
                    diagnosticComponent: error.diagnosticComponent
                ))
            )
        } catch {
            progressCoordinator.update(
                shard: shard,
                processedCount: processedHighWater,
                processedBytes: estimatedBytesHighWater,
                force: true
            )
            return CodexLogShardReadOutcome(
                bundleIndex: shard.bundleIndex,
                result: .failure(CodexLogDatabaseReadFailure(
                    status: error is DatabaseAttributionMathError ? .unreadable : .unavailable,
                    diagnosticComponent: error is DatabaseAttributionMathError
                        ? "attribution arithmetic" : nil
                ))
            )
        }
    }

    private static func mergeCodexLogSnapshots(
        _ snapshots: [CodexLogEstimateSnapshot]
    ) throws -> CodexLogEstimateSnapshot {
        var byThreadID: [String: UInt64] = [:]
        var threadlessEstimatedBytes: UInt64 = 0
        var estimatedBytes: UInt64 = 0
        var processedRowCount = 0
        for snapshot in snapshots {
            for (threadID, bytes) in snapshot.byThreadID {
                byThreadID[threadID] = try addingExact(byThreadID[threadID, default: 0], bytes)
            }
            threadlessEstimatedBytes = try addingExact(
                threadlessEstimatedBytes,
                snapshot.threadlessEstimatedBytes
            )
            estimatedBytes = try addingExact(estimatedBytes, snapshot.estimatedBytes)
            let (nextRowCount, overflow) = processedRowCount.addingReportingOverflow(
                snapshot.processedRowCount
            )
            guard !overflow else { throw DatabaseAttributionMathError.overflow }
            processedRowCount = nextRowCount
        }
        return CodexLogEstimateSnapshot(
            byThreadID: byThreadID,
            threadlessEstimatedBytes: threadlessEstimatedBytes,
            estimatedBytes: estimatedBytes,
            processedRowCount: processedRowCount,
            totalRowCount: processedRowCount
        )
    }

    private func codexLogDatabaseBundles() -> [CodexLogDatabaseBundle] {
        var candidatesByMain: [FileIdentity: [CodexLogDatabaseBundle]] = [:]
        for scope in scopes where scope.kind == .codexHome {
            let mainPath = scope.root.appending(path: "logs_2.sqlite").path
            let statePath = scope.root.appending(path: "state_5.sqlite").path
            guard let mainIdentity = identity(at: mainPath),
                  let stateIdentity = identity(at: statePath),
                  let mainEntry = physicalLedger[mainIdentity],
                  mainEntry.claims.contains(where: {
                      $0.provider == .codex && $0.sourceID == scope.id && $0.path == mainPath
                  }) else { continue }

            let walIdentity = identity(at: mainPath + "-wal")
            let sharedMemoryIdentity = identity(at: mainPath + "-shm")
            let sidecarIdentities = Set([walIdentity, sharedMemoryIdentity].compactMap { $0 })
            let memberIdentities = sidecarIdentities.union([mainIdentity])
            let membersAreExclusive = memberIdentities.allSatisfy { identity in
                guard let entry = physicalLedger[identity] else { return false }
                return Set(entry.claims.map(\.provider)) == [.codex]
                    && Set(entry.claims.map(\.sourceID)) == [scope.id]
                    && entry.claims.allSatisfy { $0.globalCategory == .sharedDatabase }
            }
            var didOverflow = false
            let physicalBytes = sumClamped(
                memberIdentities.compactMap { physicalLedger[$0]?.allocatedBytes },
                overflowed: &didOverflow
            )
            let capability: DatabaseBundleCapability
            if !membersAreExclusive || didOverflow {
                capability = .ambiguous
            } else if walIdentity == nil || sharedMemoryIdentity == nil {
                capability = .sidecarsUnavailable
            } else {
                capability = .supported
            }
            let bundle = CodexLogDatabaseBundle(
                id: "codex|\(scope.id)|logs_2",
                sourceID: scope.id,
                mainPath: mainPath,
                mainIdentity: mainIdentity,
                stateIdentity: stateIdentity,
                stateSignature: physicalLedger[stateIdentity]?.observations.first?.signature
                    ?? FileStatSignature.zero,
                sidecarIdentities: sidecarIdentities,
                memberIdentities: memberIdentities,
                physicalAllocatedBytes: physicalBytes,
                capability: capability
            )
            candidatesByMain[mainIdentity, default: []].append(bundle)
        }

        return candidatesByMain.values.flatMap { candidates -> [CodexLogDatabaseBundle] in
            guard let first = candidates.sorted(by: { $0.id < $1.id }).first else { return [] }
            let equivalent = candidates.allSatisfy {
                $0.stateIdentity == first.stateIdentity
                    && $0.stateSignature == first.stateSignature
                    && $0.sidecarIdentities == first.sidecarIdentities
                    && $0.memberIdentities == first.memberIdentities
                    && $0.capability == first.capability
            }
            if equivalent { return [first] }
            return candidates.map { $0.withCapability(.ambiguous) }
        }.sorted { $0.id < $1.id }
    }

    private func projectDatabaseEstimates(
        _ raw: CodexLogEstimateSnapshot,
        bundle: CodexLogDatabaseBundle
    ) throws -> DatabaseAttributionProjection {
        var rawByTarget: [ThreadTarget: UInt64] = [:]
        var mapped: UInt64 = 0
        var unmapped = raw.threadlessEstimatedBytes
        let targets = codexTargets[bundle.sourceID] ?? [:]
        let conflicts = codexRelationshipConflictIDs[bundle.sourceID] ?? []

        for (threadID, bytes) in raw.byThreadID {
            if let target = targets[threadID], !conflicts.contains(threadID) {
                rawByTarget[target] = try addingExact(rawByTarget[target, default: 0], bytes)
                mapped = try addingExact(mapped, bytes)
            } else {
                unmapped = try addingExact(unmapped, bytes)
            }
        }
        let total = try addingExact(mapped, unmapped)
        var byTarget: [ThreadTarget: UInt64] = [:]
        var attributed: UInt64 = 0
        for (target, bytes) in rawByTarget {
            let scaled = try scaledDatabaseBytes(
                logicalBytes: bytes,
                physicalBytes: bundle.physicalAllocatedBytes,
                totalEstimatedBytes: total
            )
            byTarget[target] = scaled
            attributed = try addingExact(attributed, scaled)
        }
        guard attributed <= bundle.physicalAllocatedBytes else { throw DatabaseAttributionMathError.overflow }
        return DatabaseAttributionProjection(
            byTarget: byTarget,
            attributedBytes: attributed,
            mappedEstimatedBytes: mapped,
            unmappedEstimatedBytes: unmapped
        )
    }

    private mutating func applyDatabaseAttributionProjections() {
        let key = "codex:global:\(AgentStorageGlobalCategory.sharedDatabase.rawValue)"
        for pending in pendingDatabaseProjections {
            do {
                guard databaseBundleIsExclusive(pending.bundle) else {
                    databaseAttributions.append(
                        pending.bundle.summary(status: .ambiguousOwnership)
                    )
                    continue
                }
                guard databaseContextIsStable(pending.bundle) else {
                    databaseAttributions.append(pending.bundle.summary(status: .unavailable))
                    continue
                }
                guard var aggregate = globalAggregates[key],
                      aggregate.allocatedBytes >= pending.summary.attributedBytes else {
                    throw DatabaseAttributionMathError.overflow
                }
                var candidateFamilies = families
                for (target, bytes) in pending.projection.byTarget {
                    guard var family = candidateFamilies[target.familyID],
                          var node = family.nodes[target.nodeID] else {
                        throw DatabaseAttributionMathError.missingTarget
                    }
                    node.databaseAttributedBytes = try addingExact(
                        node.databaseAttributedBytes,
                        bytes
                    )
                    family.nodes[target.nodeID] = node
                    candidateFamilies[target.familyID] = family
                }
                aggregate.databaseAttributedBytes = try addingExact(
                    aggregate.databaseAttributedBytes,
                    pending.summary.attributedBytes
                )
                aggregate.allocatedBytes -= pending.summary.attributedBytes
                families = candidateFamilies
                globalAggregates[key] = aggregate
                databaseAttributions.append(pending.summary)
            } catch {
                databaseAttributions.append(pending.bundle.summary(
                    status: .unreadable,
                    diagnosticComponent: "attribution arithmetic"
                ))
            }
        }
        pendingDatabaseProjections.removeAll(keepingCapacity: false)
    }

    private func databaseBundleIsExclusive(_ bundle: CodexLogDatabaseBundle) -> Bool {
        bundle.memberIdentities.allSatisfy { identity in
            guard let entry = physicalLedger[identity] else { return false }
            return Set(entry.claims.map(\.provider)) == [.codex]
                && Set(entry.claims.map(\.sourceID)) == [bundle.sourceID]
                && entry.claims.allSatisfy { $0.globalCategory == .sharedDatabase }
        }
    }

    private func databaseContextIsStable(_ bundle: CodexLogDatabaseBundle) -> Bool {
        let statePath = URL(fileURLWithPath: bundle.mainPath)
            .deletingLastPathComponent()
            .appending(path: "state_5.sqlite")
            .path
        var value = stat()
        guard lstat(statePath, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
            == bundle.stateIdentity
    }

    private func identity(at path: String) -> FileIdentity? {
        var value = stat()
        guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private mutating func addToFamily(
        familyID: String,
        nodeID: String,
        entry: PhysicalEntry,
        category: AgentStorageArtifactCategory,
        path: String
    ) {
        guard var family = families[familyID], var node = family.nodes[nodeID] else {
            let provider = entry.claims.first?.provider ?? .codex
            addUnattributed(
                provider: provider,
                reason: .missingThreadMetadata,
                entry: entry,
                path: path
            )
            return
        }
        node.allocatedBytes = node.allocatedBytes.addingClamped(entry.allocatedBytes)
        node.artifactCount += 1
        node.path = node.path ?? path
        if let artifact = cleanupArtifact(for: entry, path: path, category: category) {
            node.cleanupArtifacts.append(artifact)
        }
        family.nodes[nodeID] = node
        family.artifactCount += 1
        family.composition[category, default: 0] = family.composition[category, default: 0]
            .addingClamped(entry.allocatedBytes)
        families[familyID] = family
    }

    private mutating func addToFamilyOther(
        familyID: String,
        entry: PhysicalEntry,
        category: AgentStorageArtifactCategory,
        path: String
    ) {
        guard var family = families[familyID] else {
            let provider = entry.claims.first?.provider ?? .claude
            addUnattributed(
                provider: provider,
                reason: .missingThreadMetadata,
                entry: entry,
                path: path
            )
            return
        }
        family.familyOtherAllocatedBytes = family.familyOtherAllocatedBytes
            .addingClamped(entry.allocatedBytes)
        family.artifactCount += 1
        family.path = family.path ?? path
        if let artifact = cleanupArtifact(for: entry, path: path, category: category) {
            family.cleanupArtifacts.append(artifact)
        }
        family.composition[category, default: 0] = family.composition[category, default: 0]
            .addingClamped(entry.allocatedBytes)
        families[familyID] = family
    }

    private func cleanupArtifact(
        for entry: PhysicalEntry,
        path: String,
        category: AgentStorageArtifactCategory
    ) -> AgentStorageCleanupArtifact? {
        guard entry.isStable, entry.linkCount == 1,
              let observation = entry.observations.first(where: { $0.path == path }),
              observation.fileType == S_IFREG else { return nil }
        let signature = observation.signature
        return AgentStorageCleanupArtifact(
            path: path,
            allocatedBytes: entry.allocatedBytes,
            device: entry.identity.device,
            inode: entry.identity.inode,
            logicalBytes: signature.logicalBytes,
            blocks: signature.blocks,
            modifiedSeconds: signature.modifiedSeconds,
            modifiedNanoseconds: signature.modifiedNanoseconds,
            category: category
        )
    }

    private mutating func addGlobal(
        provider: AgentStorageProvider?,
        category: AgentStorageGlobalCategory,
        entry: PhysicalEntry,
        path: String?
    ) {
        let key = "\(provider?.rawValue ?? "shared"):global:\(category.rawValue)"
        var aggregate = globalAggregates[key] ?? MutableGlobalAggregate(
            id: key,
            provider: provider,
            category: category,
            path: path
        )
        aggregate.allocatedBytes = aggregate.allocatedBytes.addingClamped(entry.allocatedBytes)
        aggregate.logicalBytes = aggregate.logicalBytes.addingClamped(entry.logicalBytes)
        aggregate.artifactCount += 1
        aggregate.updatedAt = max(aggregate.updatedAt ?? entry.updatedAt, entry.updatedAt)
        globalAggregates[key] = aggregate
    }

    private mutating func addUnattributed(
        provider: AgentStorageProvider,
        reason: AgentStorageUnattributedReason,
        entry: PhysicalEntry,
        path: String?
    ) {
        let key = "\(provider.rawValue):unattributed:\(reason.rawValue)"
        var aggregate = unattributedAggregates[key] ?? MutableUnattributedAggregate(
            id: key,
            provider: provider,
            reason: reason,
            path: path
        )
        aggregate.allocatedBytes = aggregate.allocatedBytes.addingClamped(entry.allocatedBytes)
        aggregate.logicalBytes = aggregate.logicalBytes.addingClamped(entry.logicalBytes)
        aggregate.artifactCount += 1
        aggregate.updatedAt = max(aggregate.updatedAt ?? entry.updatedAt, entry.updatedAt)
        unattributedAggregates[key] = aggregate
    }

    private func makeSnapshot() throws -> AgentStorageSnapshot {
        let finalFamilies = try families.values.map { family in
            try Task.checkCancellation()
            let main = family.nodes[family.mainNodeID]
            let subagents = family.nodes.values
                .filter { $0.id != family.mainNodeID }
                .sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                    return $0.updatedAt > $1.updatedAt
                }
                .map(AgentStorageThreadNode.init)
            let nodeCleanupArtifacts = (main?.cleanupArtifacts ?? [])
                + subagents.flatMap(\.cleanupArtifacts)
            let cleanupArtifacts = uniqueCleanupArtifacts(
                nodeCleanupArtifacts + family.cleanupArtifacts
            )
            return AgentStorageThreadFamily(
                id: family.id,
                provider: family.provider,
                sourceID: family.sourceID,
                nativeThreadID: family.nativeThreadID,
                title: family.title,
                project: family.project,
                updatedAt: family.updatedAt,
                isArchived: family.isArchived,
                mainAllocatedBytes: main?.allocatedBytes ?? 0,
                subagentAllocatedBytes: subagents.reduce(0) {
                    $0.addingClamped($1.allocatedBytes)
                },
                familyOtherAllocatedBytes: family.familyOtherAllocatedBytes,
                mainDatabaseAttributedBytes: main?.databaseAttributedBytes ?? 0,
                subagentDatabaseAttributedBytes: subagents.reduce(0) {
                    $0.addingClamped($1.databaseAttributedBytes)
                },
                artifactCount: family.artifactCount,
                path: family.path,
                subagents: subagents,
                composition: family.composition,
                cleanupArtifacts: cleanupArtifacts,
                sourceKind: scopes.first(where: { $0.id == family.sourceID })?.kind.publicKind,
                sourcePath: scopes.first(where: { $0.id == family.sourceID })?.root.path,
                projectPath: family.projectPath
            )
        }.filter { $0.attributedBytes > 0 }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }

        let finalGlobals = try globalAggregates.values.map {
            try Task.checkCancellation()
            return AgentStorageGlobalItem($0)
        }.sorted {
            if $0.allocatedBytes == $1.allocatedBytes { return $0.id < $1.id }
            return $0.allocatedBytes > $1.allocatedBytes
        }
        let finalUnattributed = try unattributedAggregates.values
            .map {
                try Task.checkCancellation()
                return AgentStorageUnattributedItem($0)
            }
            .sorted {
                if $0.allocatedBytes == $1.allocatedBytes { return $0.id < $1.id }
                return $0.allocatedBytes > $1.allocatedBytes
            }
        var didOverflow = overflowed
        let measured = sumClamped(physicalLedger.values.map(\.allocatedBytes), overflowed: &didOverflow)
        let chatBytes = sumClamped(finalFamilies.map(\.attributedBytes), overflowed: &didOverflow)
        let globalBytes = sumClamped(finalGlobals.map(\.allocatedBytes), overflowed: &didOverflow)
        let unattributedBytes = sumClamped(finalUnattributed.map(\.allocatedBytes), overflowed: &didOverflow)
        let classified = sumClamped(
            [chatBytes, globalBytes, unattributedBytes],
            overflowed: &didOverflow
        )
        let reconciliationDelta = measured >= classified
            ? measured - classified
            : classified - measured
        let diagnostics = finalizedDiagnostics()
        let providerIssueCount = diagnostics.count
        let coverage = AgentStorageCoverage(
            measuredBytes: measured,
            classifiedBytes: classified,
            measuredEntryCount: physicalLedger.count,
            skippedEntryCount: skippedEntryCount,
            unstableEntryCount: unstableEntries.totalCount,
            overflowed: didOverflow,
            reconciliationDelta: reconciliationDelta,
            isComplete: skippedEntryCount == 0
                && unstableEntries.totalCount == 0
                && providerIssueCount == 0
                && !didOverflow
                && measured == classified
        )
        let familiesByProvider = Dictionary(grouping: finalFamilies, by: \.provider)
        let globalsByProvider = Dictionary(grouping: finalGlobals.compactMap { item in
            item.provider.map { ($0, item) }
        }, by: \.0)
        let unattributedByProvider = Dictionary(grouping: finalUnattributed, by: \.provider)
        let providerDatasets = AgentStorageProvider.allCases.map { provider in
            AgentStorageProviderDataset(
                provider: provider,
                families: familiesByProvider[provider] ?? [],
                globalItems: globalsByProvider[provider]?.map(\.1) ?? [],
                unattributedItems: unattributedByProvider[provider] ?? []
            )
        }
        let providerSummaries = providerDatasets.map { dataset in
            let provider = dataset.provider
            let metadataOutcome = providerMetadataOutcomes[provider, default: ProviderMetadataOutcome()]
            let providerFamilies = dataset.families
            let providerGlobals = dataset.globalItems
            let providerUnattributed = dataset.unattributedItems
            let chat = providerFamilies.reduce(UInt64(0)) {
                $0.addingClamped($1.attributedBytes)
            }
            let global = providerGlobals.reduce(UInt64(0)) {
                $0.addingClamped($1.allocatedBytes)
            }
            let unattributed = providerUnattributed.reduce(UInt64(0)) {
                $0.addingClamped($1.allocatedBytes)
            }
            let sourceCount = sources.filter { $0.provider == provider }.count
            let sessionSourceCount = sources.filter {
                $0.provider == provider && $0.isSessionSource
            }.count
            let providerDiagnostics = diagnostics.filter { $0.provider == provider }
            let issueCount = providerDiagnostics.count
            let databaseIssueCount = databaseAttributions.filter {
                $0.provider == provider && $0.status != .completed
            }.count
            let supportStatus: AgentStorageProviderSupportStatus
            if sourceCount == 0 {
                supportStatus = .notInstalled
            } else if metadataOutcome.supportedCount == 0, metadataOutcome.unsupportedCount > 0 {
                supportStatus = .unsupportedFormat
            } else if issueCount > 0 || databaseIssueCount > 0
                || unstableEntries.count(for: provider) > 0 {
                supportStatus = .partial
            } else if sessionSourceCount == 0 || metadataOutcome.emptyCount == sessionSourceCount {
                supportStatus = .noConversationSource
            } else {
                supportStatus = .supported
            }
            return AgentStorageProviderSummary(
                provider: provider,
                exclusiveBytes: chat.addingClamped(global).addingClamped(unattributed),
                chatBytes: chat,
                globalBytes: global,
                unattributedBytes: unattributed,
                mainThreadBytes: providerFamilies.reduce(UInt64(0)) {
                    $0.addingClamped($1.mainAllocatedBytes)
                        .addingClamped($1.mainDatabaseAttributedBytes)
                },
                subagentBytes: providerFamilies.reduce(UInt64(0)) {
                    $0.addingClamped($1.subagentAllocatedBytes)
                        .addingClamped($1.subagentDatabaseAttributedBytes)
                },
                familyOtherBytes: providerFamilies.reduce(UInt64(0)) {
                    $0.addingClamped($1.familyOtherAllocatedBytes)
                },
                databaseAttributedBytes: providerFamilies.reduce(UInt64(0)) {
                    $0.addingClamped($1.databaseAttributedBytes)
                },
                threadCount: providerFamilies.count,
                subagentCount: providerFamilies.reduce(0) { $0 + $1.subagentCount },
                sourceCount: sourceCount,
                issueCount: issueCount,
                unstableEntryCount: unstableEntries.count(for: provider),
                supportStatus: supportStatus,
                unsupportedSourceCount: metadataOutcome.unsupportedCount,
                unreadableSourceCount: metadataOutcome.unreadableCount,
                attributionStatus: attributionStatus(
                    supportStatus: supportStatus,
                    diagnostics: providerDiagnostics,
                    hasConversationSource: !providerFamilies.isEmpty
                        || metadataOutcome.supportedCount > 0
                ),
                diagnosticCounts: Dictionary(grouping: providerDiagnostics, by: \.kind)
                    .mapValues(\.count),
                knownAffectedBytes: uniqueKnownAffectedBytes(providerDiagnostics)
            )
        }

        return AgentStorageSnapshot(
            scannedAt: Date(),
            families: finalFamilies,
            globalItems: finalGlobals,
            unattributedItems: finalUnattributed,
            providers: providerSummaries,
            sources: sources,
            coverage: coverage,
            crossAgentSharedBytes: finalGlobals
                .filter { $0.category == .crossAgentShared }
                .reduce(0) { $0.addingClamped($1.allocatedBytes) },
            providerDatasets: providerDatasets,
            databaseAttributions: databaseAttributions.sorted { $0.id < $1.id },
            diagnostics: diagnostics
        )
    }

    private func attributionStatus(
        supportStatus: AgentStorageProviderSupportStatus,
        diagnostics: [AgentStorageDiagnostic],
        hasConversationSource: Bool
    ) -> AgentStorageAttributionStatus {
        switch supportStatus {
        case .notInstalled, .unsupportedFormat: return .unavailable
        case .noConversationSource: return .noConversationSource
        case .partial, .supported:
            if diagnostics.contains(where: { $0.impact != .physicalMeasurement }) {
                return .partial
            }
            return hasConversationSource ? .complete : .noConversationSource
        }
    }

    private func uniqueKnownAffectedBytes(
        _ diagnostics: [AgentStorageDiagnostic]
    ) -> UInt64 {
        var seen = Set<String>()
        return diagnostics.reduce(0) { total, diagnostic in
            guard let bytes = diagnostic.affectedAllocatedBytes else { return total }
            let key = diagnostic.relativePath.map {
                "\(diagnostic.sourceID)|\($0)"
            } ?? diagnostic.id
            guard seen.insert(key).inserted else { return total }
            return total.addingClamped(bytes)
        }
    }

    private func finalizedDiagnostics() -> [AgentStorageDiagnostic] {
        var values = diagnosticDrafts.map { key, draft in
            let source = sources.first { $0.id == key.sourceID }
            let measuredPathBytes: UInt64? = shouldKeepAffectedBytesUnknown(for: key.kind)
                ? nil
                : knownAllocatedBytes(for: draft.absolutePaths)
            let affectedBytes = draft.affectedAllocatedBytes ?? measuredPathBytes
            let displayPath = draft.absolutePaths.sorted().first
            let displayRelativePath = displayPath.flatMap { path in
                guard let source else { return URL(fileURLWithPath: path).lastPathComponent }
                return relativePath(
                    of: URL(fileURLWithPath: path),
                    under: URL(fileURLWithPath: source.path, isDirectory: true)
                )
            }
            return AgentStorageDiagnostic(
                id: key.stableID,
                provider: key.provider,
                sourceID: key.sourceID,
                sourceKind: source?.kind,
                kind: key.kind,
                area: draft.area,
                impact: draft.impact,
                affectedEntityCount: draft.affectedEntityCount,
                affectedAllocatedBytes: affectedBytes,
                relativePath: displayRelativePath
            )
        }

        for entry in physicalLedger.values where !entry.isStable {
            for observation in entry.observations {
                guard let claim = entry.claims.first(where: {
                    $0.provider == observation.provider && $0.path == observation.path
                }) else { continue }
                values.append(AgentStorageDiagnostic(
                    id: "\(observation.provider.rawValue)|\(claim.sourceID)|changed|\(observation.path)",
                    provider: observation.provider,
                    sourceID: claim.sourceID,
                    sourceKind: sources.first(where: { $0.id == claim.sourceID })?.kind,
                    kind: .changedDuringScan,
                    area: .fileSystem,
                    impact: .physicalMeasurement,
                    affectedAllocatedBytes: entry.allocatedBytes,
                    relativePath: relativePath(
                        of: URL(fileURLWithPath: observation.path),
                        under: URL(fileURLWithPath: sources.first(where: {
                            $0.id == claim.sourceID
                        })?.path ?? observation.path, isDirectory: true)
                    )
                ))
            }
        }

        for attribution in databaseAttributions where attribution.status != .completed {
            values.append(AgentStorageDiagnostic(
                id: "\(attribution.provider.rawValue)|\(attribution.sourceID)|database|\(attribution.id)",
                provider: attribution.provider,
                sourceID: attribution.sourceID,
                sourceKind: sources.first(where: { $0.id == attribution.sourceID })?.kind,
                kind: .databaseAttributionUnavailable,
                area: .database,
                impact: .databaseAttribution,
                affectedAllocatedBytes: attribution.physicalBundleBytes,
                relativePath: URL(fileURLWithPath: attribution.path).lastPathComponent
            ))
        }

        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }

    private func shouldKeepAffectedBytesUnknown(
        for kind: AgentStorageDiagnosticKind
    ) -> Bool {
        switch kind {
        case .malformedTranscriptRecords, .subagentMetadataOnly,
             .databaseRecordUnverified, .relationshipConflict:
            return true
        default:
            return false
        }
    }

    private func uniqueCleanupArtifacts(
        _ artifacts: [AgentStorageCleanupArtifact]
    ) -> [AgentStorageCleanupArtifact] {
        var identities = Set<FileIdentity>()
        return artifacts.filter { artifact in
            identities.insert(FileIdentity(
                device: artifact.device,
                inode: artifact.inode
            )).inserted
        }.sorted { $0.path < $1.path }
    }

    private mutating func recordSkipped(provider: AgentStorageProvider, count: Int = 1) {
        skippedEntryCount += count
        providerIssueCounts[provider, default: 0] += count
        recordDiagnostic(
            provider: provider,
            sourceID: scopes.first(where: { $0.provider == provider })?.id,
            kind: .filesystemEntrySkipped,
            area: .fileSystem,
            impact: .physicalMeasurement,
            affectedEntityCount: count,
            entityKey: "filesystem"
        )
    }

    private mutating func recordDiagnostic(
        provider: AgentStorageProvider,
        sourceID: String?,
        kind: AgentStorageDiagnosticKind,
        area: AgentStorageDiagnosticArea,
        impact: AgentStorageDiagnosticImpact,
        affectedEntityCount: Int = 1,
        affectedAllocatedBytes: UInt64? = nil,
        absolutePath: String? = nil,
        absolutePaths: [String] = [],
        entityKey: String? = nil
    ) {
        let resolvedSourceID = sourceID
            ?? scopes.first(where: { $0.provider == provider })?.id
            ?? "\(provider.rawValue):unknown"
        let key = AgentStorageDiagnosticKey(
            provider: provider,
            sourceID: resolvedSourceID,
            kind: kind,
            entityKey: entityKey ?? absolutePath ?? kind.rawValue
        )
        if var current = diagnosticDrafts[key] {
            current.affectedEntityCount += max(1, affectedEntityCount)
            current.affectedAllocatedBytes = mergeKnownBytes(
                current.affectedAllocatedBytes,
                affectedAllocatedBytes
            )
            current.absolutePaths.formUnion(absolutePaths)
            if let absolutePath { current.absolutePaths.insert(absolutePath) }
            diagnosticDrafts[key] = current
            return
        }
        diagnosticDrafts[key] = AgentStorageDiagnosticDraft(
            area: area,
            impact: impact,
            affectedEntityCount: max(1, affectedEntityCount),
            affectedAllocatedBytes: affectedAllocatedBytes,
            absolutePaths: Set(absolutePaths + [absolutePath].compactMap { $0 })
        )
    }

    private func knownAllocatedBytes(for paths: Set<String>) -> UInt64? {
        guard !paths.isEmpty else { return nil }
        var matchedPaths = Set<String>()
        var total: UInt64 = 0
        for entry in physicalLedger.values {
            let matches = Set(entry.observations.lazy.map(\.path)).intersection(paths)
            guard !matches.isEmpty else { continue }
            matchedPaths.formUnion(matches)
            total = total.addingClamped(entry.allocatedBytes)
        }
        return matchedPaths == paths ? total : nil
    }

    private mutating func recordMetadataOutcome(
        _ kind: ProviderMetadataOutcome.Kind,
        provider: AgentStorageProvider
    ) {
        var outcome = providerMetadataOutcomes[provider, default: ProviderMetadataOutcome()]
        outcome.record(kind)
        providerMetadataOutcomes[provider] = outcome
    }

    private func existingPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        return fileManager.fileExists(atPath: url.path) ? url.path : nil
    }
}

private enum ScanScopeKind: Sendable {
    case codexHome
    case codexDesktop
    case claudeCode
    case claudeDesktop
    case claudeDesktopAgent

    var publicKind: AgentStorageSourceKind {
        switch self {
        case .codexHome: .codexHome
        case .codexDesktop: .codexDesktop
        case .claudeCode: .claudeCode
        case .claudeDesktop: .claudeDesktop
        case .claudeDesktopAgent: .claudeDesktopAgent
        }
    }
}

private struct ProviderMetadataOutcome: Sendable {
    enum Kind: Sendable { case supported, unsupported, unreadable, empty }

    var supportedCount = 0
    var unsupportedCount = 0
    var unreadableCount = 0
    var emptyCount = 0

    mutating func record(_ kind: Kind) {
        switch kind {
        case .supported: supportedCount += 1
        case .unsupported: unsupportedCount += 1
        case .unreadable: unreadableCount += 1
        case .empty: emptyCount += 1
        }
    }

    mutating func merge(_ other: Self) {
        supportedCount += other.supportedCount
        unsupportedCount += other.unsupportedCount
        unreadableCount += other.unreadableCount
        emptyCount += other.emptyCount
    }
}

private struct AgentStorageDiagnosticKey: Hashable, Sendable {
    let provider: AgentStorageProvider
    let sourceID: String
    let kind: AgentStorageDiagnosticKind
    let entityKey: String

    var stableID: String {
        "\(provider.rawValue)|\(sourceID)|\(kind.rawValue)|\(entityKey)"
    }
}

private struct AgentStorageDiagnosticDraft: Sendable {
    let area: AgentStorageDiagnosticArea
    let impact: AgentStorageDiagnosticImpact
    var affectedEntityCount: Int
    var affectedAllocatedBytes: UInt64?
    var absolutePaths: Set<String>
}

private func mergeKnownBytes(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): lhs.addingClamped(rhs)
    case (.some(let value), .none), (.none, .some(let value)): value
    case (.none, .none): nil
    }
}

private struct ScanScope: Sendable {
    let id: String
    let provider: AgentStorageProvider
    let kind: ScanScopeKind
    let root: URL
    let displayName: String
}

private struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private enum DatabaseBundleCapability: Sendable, Equatable {
    case supported
    case sidecarsUnavailable
    case ambiguous
}

private struct CodexLogDatabaseBundle: Sendable {
    let id: String
    let sourceID: String
    let mainPath: String
    let mainIdentity: FileIdentity
    let stateIdentity: FileIdentity
    let stateSignature: FileStatSignature
    let sidecarIdentities: Set<FileIdentity>
    let memberIdentities: Set<FileIdentity>
    let physicalAllocatedBytes: UInt64
    let capability: DatabaseBundleCapability

    func withCapability(_ capability: DatabaseBundleCapability) -> Self {
        Self(
            id: id,
            sourceID: sourceID,
            mainPath: mainPath,
            mainIdentity: mainIdentity,
            stateIdentity: stateIdentity,
            stateSignature: stateSignature,
            sidecarIdentities: sidecarIdentities,
            memberIdentities: memberIdentities,
            physicalAllocatedBytes: physicalAllocatedBytes,
            capability: capability
        )
    }

    func summary(
        status: AgentStorageDatabaseAttributionStatus,
        diagnosticComponent: String? = nil
    ) -> AgentStorageDatabaseAttributionSummary {
        AgentStorageDatabaseAttributionSummary(
            id: id,
            provider: .codex,
            sourceID: sourceID,
            path: mainPath,
            physicalBundleBytes: physicalAllocatedBytes,
            attributedBytes: 0,
            residualBytes: physicalAllocatedBytes,
            mappedEstimatedBytes: 0,
            unmappedEstimatedBytes: 0,
            processedRowCount: 0,
            totalRowCount: 0,
            status: status,
            diagnosticComponent: diagnosticComponent
        )
    }
}

private struct CodexLogScanBounds: Sendable {
    let minimumID: Int64
    let maximumID: Int64
}

private struct CodexLogScanShard: Sendable {
    let id: String
    let bundleIndex: Int
    let path: String
    let expectedIdentity: FileIdentity
    let range: ClosedRange<Int64>

    static func makeShards(
        bundleIndex: Int,
        bundleID: String,
        path: String,
        expectedIdentity: FileIdentity,
        bounds: CodexLogScanBounds,
        maximumShardCount: Int
    ) -> [Self] {
        let fallback = [Self(
            id: "\(bundleID)|shard-1",
            bundleIndex: bundleIndex,
            path: path,
            expectedIdentity: expectedIdentity,
            range: bounds.minimumID...bounds.maximumID
        )]
        guard maximumShardCount > 1,
              bounds.minimumID >= 0,
              bounds.maximumID >= bounds.minimumID
        else { return fallback }
        let (distance, didOverflow) = bounds.maximumID.subtractingReportingOverflow(
            bounds.minimumID
        )
        guard !didOverflow else { return fallback }

        let span = UInt64(distance) + 1
        let minimumIDsPerShard: UInt64 = 4_096
        let usefulShardCount = Int(min(
            UInt64(maximumShardCount),
            ((span - 1) / minimumIDsPerShard) + 1
        ))
        guard usefulShardCount > 1 else { return fallback }

        let width = ((span - 1) / UInt64(usefulShardCount)) + 1
        return (0..<usefulShardCount).compactMap { shardIndex in
            let lowerOffset = UInt64(shardIndex) * width
            guard lowerOffset < span else { return nil }
            let upperOffset = min(span - 1, lowerOffset + width - 1)
            let lowerID = bounds.minimumID + Int64(lowerOffset)
            let upperID = bounds.minimumID + Int64(upperOffset)
            return Self(
                id: "\(bundleID)|shard-\(shardIndex + 1)",
                bundleIndex: bundleIndex,
                path: path,
                expectedIdentity: expectedIdentity,
                range: lowerID...upperID
            )
        }
    }
}

private struct CodexLogEstimateSnapshot: Sendable {
    let byThreadID: [String: UInt64]
    let threadlessEstimatedBytes: UInt64
    let estimatedBytes: UInt64
    let processedRowCount: Int
    let totalRowCount: Int

    static let empty = Self(
        byThreadID: [:],
        threadlessEstimatedBytes: 0,
        estimatedBytes: 0,
        processedRowCount: 0,
        totalRowCount: 0
    )
}

private struct CodexLogDatabaseReadFailure: Error, Sendable {
    let status: AgentStorageDatabaseAttributionStatus
    let diagnosticComponent: String?
}

private struct CodexLogShardReadOutcome: Sendable {
    let bundleIndex: Int
    let result: Result<CodexLogEstimateSnapshot, CodexLogDatabaseReadFailure>
}

private final class CodexLogDatabaseProgressCoordinator: @unchecked Sendable {
    struct Totals: Sendable {
        let completedCount: Int
        let processedBytes: UInt64
    }

    private struct ShardProgress {
        var completedCount = 0
        var processedBytes: UInt64 = 0
    }

    private let lock = NSLock()
    private let emitter: AgentStorageProgressEmitter
    private let databaseCount: Int
    private var progressByShard: [String: ShardProgress] = [:]
    private var completedBundles: Set<Int> = []

    init(emitter: AgentStorageProgressEmitter, databaseCount: Int) {
        self.emitter = emitter
        self.databaseCount = databaseCount
    }

    var totals: Totals {
        lock.lock()
        defer { lock.unlock() }
        return calculateTotals()
    }

    func update(
        shard: CodexLogScanShard,
        processedCount: Int,
        processedBytes: UInt64,
        force: Bool
    ) {
        lock.lock()
        var current = progressByShard[shard.id, default: ShardProgress()]
        current.completedCount = max(current.completedCount, processedCount)
        current.processedBytes = max(current.processedBytes, processedBytes)
        progressByShard[shard.id] = current
        let totals = calculateTotals()
        let databaseIndex = databaseCount == 0
            ? nil : min(databaseCount, completedBundles.count + 1)
        emitter.emit(AgentStorageScanProgress(
            phase: .attributingDatabase,
            completedCount: totals.completedCount,
            provider: .codex,
            activityCount: totals.completedCount,
            processedBytes: totals.processedBytes,
            databaseStage: .readingRecords,
            databaseIndex: databaseIndex,
            databaseCount: databaseCount
        ), force: force)
        lock.unlock()
    }

    func markBundleCompleted(_ bundleIndex: Int) {
        lock.lock()
        completedBundles.insert(bundleIndex)
        lock.unlock()
    }

    private func calculateTotals() -> Totals {
        let completedCount = progressByShard.values.reduce(0) { partialResult, progress in
            let (result, overflow) = partialResult.addingReportingOverflow(
                progress.completedCount
            )
            return overflow ? Int.max : result
        }
        return Totals(
            completedCount: completedCount,
            processedBytes: progressByShard.values.reduce(0) {
                $0.addingClamped($1.processedBytes)
            }
        )
    }
}

private struct DatabaseAttributionProjection: Sendable {
    let byTarget: [ThreadTarget: UInt64]
    let attributedBytes: UInt64
    let mappedEstimatedBytes: UInt64
    let unmappedEstimatedBytes: UInt64
}

private struct PendingDatabaseAttribution: Sendable {
    let bundle: CodexLogDatabaseBundle
    let projection: DatabaseAttributionProjection
    let summary: AgentStorageDatabaseAttributionSummary
}

private enum DatabaseAttributionMathError: Error {
    case overflow
    case missingTarget
}

private struct PhysicalEntry: Sendable {
    let identity: FileIdentity
    var allocatedBytes: UInt64
    var logicalBytes: UInt64
    var updatedAt: Date
    var claims: [PhysicalClaim]
    var observations: [FileObservation]
    var isStable: Bool
    var linkCount: UInt64
}

private struct FileObservation: Sendable {
    let path: String
    let signature: FileStatSignature
    let fileType: mode_t
    let provider: AgentStorageProvider
}

struct AgentStorageUnstableEntryTracker: Sendable {
    private struct Identity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private var all: Set<Identity> = []
    private var byProvider: [AgentStorageProvider: Set<Identity>] = [:]

    var totalCount: Int { all.count }

    mutating func mark(
        device: UInt64,
        inode: UInt64,
        provider: AgentStorageProvider
    ) {
        let identity = Identity(device: device, inode: inode)
        all.insert(identity)
        byProvider[provider, default: []].insert(identity)
    }

    func count(for provider: AgentStorageProvider) -> Int {
        byProvider[provider]?.count ?? 0
    }

    mutating func merge(_ other: Self) {
        all.formUnion(other.all)
        for (provider, identities) in other.byProvider {
            byProvider[provider, default: []].formUnion(identities)
        }
    }
}

private struct FileStatSignature: Equatable, Sendable {
    let logicalBytes: Int64
    let blocks: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    init(_ value: stat) {
        logicalBytes = Int64(value.st_size)
        blocks = Int64(value.st_blocks)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }

    static let zero = FileStatSignature(
        logicalBytes: 0,
        blocks: 0,
        modifiedSeconds: 0,
        modifiedNanoseconds: 0
    )

    private init(
        logicalBytes: Int64,
        blocks: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64
    ) {
        self.logicalBytes = logicalBytes
        self.blocks = blocks
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

private final class AgentSQLiteInterruptRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: Set<OpaquePointer> = []
    private var isCancelled = false

    func register(_ handle: OpaquePointer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        handles.insert(handle)
    }

    func unregister(_ handle: OpaquePointer) {
        lock.lock()
        handles.remove(handle)
        lock.unlock()
    }

    func cancelAndInterrupt() {
        lock.lock()
        isCancelled = true
        for handle in handles { sqlite3_interrupt(handle) }
        lock.unlock()
    }

    func cancellationRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

private let agentSQLiteProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    context in
    guard let context else { return 0 }
    let registry = Unmanaged<AgentSQLiteInterruptRegistry>.fromOpaque(context).takeUnretainedValue()
    return registry.cancellationRequested() ? 1 : 0
}

private enum ClaimOwnership: Hashable, Sendable {
    case node(String, String)
    case familyOther(String)
    case global(AgentStorageGlobalCategory)
    case unattributed(AgentStorageUnattributedReason)
}

private struct PhysicalClaim: Hashable, Sendable {
    let provider: AgentStorageProvider
    let sourceID: String
    let path: String
    let ownership: ClaimOwnership
    let artifactCategory: AgentStorageArtifactCategory

    var familyID: String? {
        switch ownership {
        case .node(let familyID, _), .familyOther(let familyID): familyID
        case .global, .unattributed: nil
        }
    }

    var nodeID: String? {
        if case .node(_, let nodeID) = ownership { return nodeID }
        return nil
    }

    var globalCategory: AgentStorageGlobalCategory? {
        if case .global(let category) = ownership { return category }
        return nil
    }

    var unattributedReason: AgentStorageUnattributedReason? {
        if case .unattributed(let reason) = ownership { return reason }
        return nil
    }

    var sortKey: String { "\(provider.rawValue)|\(sourceID)|\(path)|\(ownership)" }
}

private struct MutableNode: Sendable {
    let id: String
    let nativeID: String
    let parentNativeID: String?
    let depth: Int
    let title: String
    let updatedAt: Date
    var allocatedBytes: UInt64 = 0
    var databaseAttributedBytes: UInt64 = 0
    var artifactCount: Int = 0
    var path: String?
    var cleanupArtifacts: [AgentStorageCleanupArtifact] = []
}

private extension AgentStorageThreadNode {
    init(_ node: MutableNode) {
        self.init(
            id: node.id,
            nativeID: node.nativeID,
            parentID: node.parentNativeID,
            depth: node.depth,
            title: node.title,
            updatedAt: node.updatedAt,
            allocatedBytes: node.allocatedBytes,
            databaseAttributedBytes: node.databaseAttributedBytes,
            artifactCount: node.artifactCount,
            path: node.path,
            cleanupArtifacts: node.cleanupArtifacts
        )
    }
}

private struct MutableFamily: Sendable {
    let id: String
    let provider: AgentStorageProvider
    let sourceID: String
    let nativeThreadID: String
    let title: String
    let project: String
    let projectPath: String?
    var updatedAt: Date
    let isArchived: Bool
    let mainNodeID: String
    var path: String?
    var nodes: [String: MutableNode]
    var familyOtherAllocatedBytes: UInt64 = 0
    var artifactCount: Int = 0
    var composition: [AgentStorageArtifactCategory: UInt64] = [:]
    var cleanupArtifacts: [AgentStorageCleanupArtifact] = []
}

private struct MutableGlobalAggregate: Sendable {
    let id: String
    let provider: AgentStorageProvider?
    let category: AgentStorageGlobalCategory
    var allocatedBytes: UInt64 = 0
    var databaseAttributedBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var artifactCount: Int = 0
    let path: String?
    var updatedAt: Date?
}

private extension AgentStorageGlobalItem {
    init(_ aggregate: MutableGlobalAggregate) {
        self.init(
            id: aggregate.id,
            provider: aggregate.provider,
            category: aggregate.category,
            title: aggregate.category.rawValue,
            allocatedBytes: aggregate.allocatedBytes,
            physicalAllocatedBytes: aggregate.allocatedBytes.addingClamped(
                aggregate.databaseAttributedBytes
            ),
            databaseAttributedBytes: aggregate.databaseAttributedBytes,
            logicalBytes: aggregate.logicalBytes,
            artifactCount: aggregate.artifactCount,
            path: aggregate.path,
            updatedAt: aggregate.updatedAt
        )
    }
}

private struct MutableUnattributedAggregate: Sendable {
    let id: String
    let provider: AgentStorageProvider
    let reason: AgentStorageUnattributedReason
    var allocatedBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var artifactCount: Int = 0
    let path: String?
    var updatedAt: Date?
}

private extension AgentStorageUnattributedItem {
    init(_ aggregate: MutableUnattributedAggregate) {
        self.init(
            id: aggregate.id,
            provider: aggregate.provider,
            reason: aggregate.reason,
            title: aggregate.reason.rawValue,
            allocatedBytes: aggregate.allocatedBytes,
            logicalBytes: aggregate.logicalBytes,
            artifactCount: aggregate.artifactCount,
            path: aggregate.path,
            updatedAt: aggregate.updatedAt,
            evidence: aggregate.reason.rawValue
        )
    }
}

private struct ThreadTarget: Hashable, Sendable {
    let familyID: String
    let nodeID: String
}

private struct ClaudeAgentCandidate: Sendable {
    var jsonlFiles: [URL] = []
    var metadataFiles: [URL] = []
}

private final class ScanErrorCounter: @unchecked Sendable {
    var value = 0
}

private struct CodexThreadRecord: Sendable {
    let id: String
    let rolloutPath: String
    let updatedAt: Date
    let cwd: String
    let displayTitle: String?
    let isArchived: Bool
    let isSubagent: Bool
    let gitOriginURL: String?
}

private struct CodexEdge: Sendable {
    let parent: String
    let child: String
}

private struct CodexDatabaseSnapshot: Sendable {
    let threads: [CodexThreadRecord]
    let edges: [CodexEdge]
    let issueCount: Int
}

private final class ReadOnlyAgentSQLite {
    private var handle: OpaquePointer?
    private let interruptRegistry: AgentSQLiteInterruptRegistry

    init(
        path: String,
        expectedIdentity: FileIdentity? = nil,
        interruptRegistry: AgentSQLiteInterruptRegistry = AgentSQLiteInterruptRegistry()
    ) throws {
        self.interruptRegistry = interruptRegistry
        var fileStat = stat()
        guard lstat(path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw AgentSQLiteError.openFailed("\(path): not a regular file")
        }
        let observedIdentity = FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino)
        )
        guard expectedIdentity == nil || expectedIdentity == observedIdentity else {
            throw AgentSQLiteError.openFailed("\(path): file identity changed before opening")
        }
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(result)"
            if let pointer { sqlite3_close_v2(pointer) }
            throw AgentSQLiteError.openFailed("\(path): \(message)")
        }
        var openedPathStat = stat()
        let openedPathIsStable = lstat(path, &openedPathStat) == 0
            && (openedPathStat.st_mode & S_IFMT) == S_IFREG
            && FileIdentity(
                device: UInt64(openedPathStat.st_dev),
                inode: UInt64(openedPathStat.st_ino)
            ) == observedIdentity
        guard openedPathIsStable else {
            sqlite3_close_v2(pointer)
            throw AgentSQLiteError.openFailed("\(path): file identity changed while opening")
        }
        do {
            try interruptRegistry.register(pointer)
        } catch {
            sqlite3_close_v2(pointer)
            throw error
        }
        handle = pointer
        sqlite3_extended_result_codes(pointer, 1)
        sqlite3_progress_handler(
            pointer,
            2_000,
            agentSQLiteProgressCallback,
            Unmanaged.passUnretained(interruptRegistry).toOpaque()
        )
        guard sqlite3_exec(pointer, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            let error = sqliteError()
            sqlite3_progress_handler(pointer, 0, nil, nil)
            interruptRegistry.unregister(pointer)
            sqlite3_close_v2(pointer)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(pointer, 150)
    }

    deinit {
        if let handle {
            sqlite3_progress_handler(handle, 0, nil, nil)
            interruptRegistry.unregister(handle)
            sqlite3_close_v2(handle)
        }
    }

    func codexSnapshot(progress: (Int) -> Void = { _ in }) throws -> CodexDatabaseSnapshot {
        try execute("BEGIN DEFERRED TRANSACTION")
        var committed = false
        defer {
            if !committed { try? execute("ROLLBACK") }
        }
        let threadResult = try codexThreads(progress: progress)
        let edgeResult = try codexEdges { progress(threadResult.processedCount + $0) }
        try execute("COMMIT")
        committed = true
        return CodexDatabaseSnapshot(
            threads: threadResult.values,
            edges: edgeResult.values,
            issueCount: threadResult.issueCount + edgeResult.issueCount
        )
    }

    func codexLogScanBounds() throws -> CodexLogScanBounds? {
        try validateCodexLogDatabase()
        try execute("BEGIN DEFERRED TRANSACTION")
        var committed = false
        defer {
            if !committed { try? execute("ROLLBACK") }
        }
        let minimumID = try codexLogExtremeID("SELECT MIN(id) FROM logs")
        let maximumID = try codexLogExtremeID("SELECT MAX(id) FROM logs")
        try execute("COMMIT")
        committed = true
        guard let minimumID, let maximumID else {
            guard minimumID == nil, maximumID == nil else {
                throw AgentSQLiteError.unsupportedSchema("logs.id")
            }
            return nil
        }
        guard minimumID <= maximumID else {
            throw AgentSQLiteError.unsupportedSchema("logs.id")
        }
        return CodexLogScanBounds(minimumID: minimumID, maximumID: maximumID)
    }

    func codexLogEstimates(
        in range: ClosedRange<Int64>,
        progress: (Int, UInt64, Bool) -> Void
    ) throws -> CodexLogEstimateSnapshot {
        try validateCodexLogDatabase()

        try execute("BEGIN DEFERRED TRANSACTION")
        var committed = false
        defer {
            if !committed { try? execute("ROLLBACK") }
        }
        progress(0, 0, true)

        let estimates = try aggregateCodexLogs(
            in: range,
            progress: progress
        )
        try execute("COMMIT")
        committed = true
        return CodexLogEstimateSnapshot(
            byThreadID: estimates.byThreadID,
            threadlessEstimatedBytes: estimates.threadless,
            estimatedBytes: estimates.estimatedBytes,
            processedRowCount: estimates.processed,
            totalRowCount: estimates.processed
        )
    }

    private func validateCodexLogDatabase() throws {
        guard try journalMode().lowercased() == "wal" else {
            throw AgentSQLiteError.unsupportedJournalMode
        }
        let columns = try columnNames(table: "logs")
        guard Set(["id", "thread_id", "estimated_bytes"]).isSubset(of: columns) else {
            throw AgentSQLiteError.unsupportedSchema("logs")
        }
    }

    private func aggregateCodexLogs(
        in range: ClosedRange<Int64>,
        progress: (Int, UInt64, Bool) -> Void
    ) throws -> (
        byThreadID: [String: UInt64],
        threadless: UInt64,
        estimatedBytes: UInt64,
        processed: Int
    ) {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        var statement: OpaquePointer?
        let sql = """
        SELECT id, thread_id, estimated_bytes
        FROM logs
        WHERE id >= ? AND id <= ?
        ORDER BY id
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, range.lowerBound) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, range.upperBound) == SQLITE_OK
        else {
            throw sqliteError()
        }

        var byThreadID: [String: UInt64] = [:]
        var threadless: UInt64 = 0
        var accumulatedEstimatedBytes: UInt64 = 0
        var processed = 0
        var lastID = Int64.min
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteError(code: step) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER else {
                throw AgentSQLiteError.unsupportedSchema("logs.id/estimated_bytes")
            }
            let rowID = sqlite3_column_int64(statement, 0)
            let signedBytes = sqlite3_column_int64(statement, 2)
            guard rowID > lastID, signedBytes >= 0 else {
                throw AgentSQLiteError.unsupportedSchema("logs.id/estimated_bytes")
            }
            lastID = rowID
            let rawThreadID = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? "" : sqliteText(statement, 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let rowEstimatedBytes = UInt64(signedBytes)
            accumulatedEstimatedBytes = try addingExact(
                accumulatedEstimatedBytes,
                rowEstimatedBytes
            )
            if let threadID = normalizedUUID(rawThreadID) {
                byThreadID[threadID] = try addingExact(
                    byThreadID[threadID, default: 0],
                    rowEstimatedBytes
                )
            } else {
                threadless = try addingExact(threadless, rowEstimatedBytes)
            }
            processed += 1
            if processed.isMultiple(of: 256) {
                try Task.checkCancellation()
                progress(processed, accumulatedEstimatedBytes, processed == 256)
            }
        }
        progress(processed, accumulatedEstimatedBytes, true)
        return (byThreadID, threadless, accumulatedEstimatedBytes, processed)
    }

    private func codexLogExtremeID(_ sql: String) throws -> Int64? {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw sqliteError(code: step) }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw AgentSQLiteError.unsupportedSchema("logs.id")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func codexThreads(
        progress: (Int) -> Void
    ) throws -> (values: [CodexThreadRecord], issueCount: Int, processedCount: Int) {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        let columns = try columnNames(table: "threads")
        let requiredColumns: Set<String> = ["id", "rollout_path", "updated_at"]
        guard requiredColumns.isSubset(of: columns) else {
            throw AgentSQLiteError.unsupportedSchema("threads")
        }
        func expression(_ column: String, fallback: String = "''") -> String {
            columns.contains(column) ? "COALESCE(\(column), '')" : fallback
        }
        var titleTerms: [String] = []
        for column in ["agent_nickname", "name", "title", "first_user_message", "preview"]
            where columns.contains(column) {
            let bounded = "SUBSTR(\(column), 1, 2048)"
            titleTerms.append(
                "CASE WHEN LOWER(TRIM(\(bounded))) = LOWER(id) THEN NULL "
                    + "ELSE NULLIF(TRIM(\(bounded)), '') END"
            )
        }
        titleTerms.append("''")
        let titleExpression = "COALESCE(\(titleTerms.joined(separator: ", ")))"
        let sql = """
        SELECT id, rollout_path,
               \(columns.contains("updated_at_ms") ? "COALESCE(updated_at_ms / 1000.0, updated_at)" : "updated_at"),
               \(expression("cwd")), \(titleExpression),
               \(columns.contains("archived") ? "COALESCE(archived, 0)" : "0"),
               \(expression("source")), \(expression("agent_path")), \(expression("agent_role")),
               \(expression("git_origin_url"))
        FROM threads
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AgentSQLiteError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var records: [CodexThreadRecord] = []
        var issueCount = 0
        var rowCount = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw AgentSQLiteError.queryFailed }
            rowCount += 1
            if rowCount.isMultiple(of: 128) {
                try Task.checkCancellation()
                progress(rowCount)
            }
            guard let id = normalizedUUID(sqliteText(statement, 0)) else {
                issueCount += 1
                continue
            }
            let source = sqliteText(statement, 6)
            let agentPath = sqliteText(statement, 7)
            let agentRole = sqliteText(statement, 8)
            records.append(CodexThreadRecord(
                id: id,
                rolloutPath: sqliteText(statement, 1),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                cwd: sqliteText(statement, 3),
                displayTitle: normalizedTitleCandidate(sqliteText(statement, 4), excluding: id),
                isArchived: sqlite3_column_int(statement, 5) != 0,
                isSubagent: source.contains("\"subagent\"")
                    || !agentPath.isEmpty
                    || !agentRole.isEmpty,
                gitOriginURL: nonEmptyTrimmed(sqliteText(statement, 9))
            ))
        }
        progress(rowCount)
        return (records, issueCount, rowCount)
    }

    private func codexEdges(
        progress: (Int) -> Void
    ) throws -> (values: [CodexEdge], issueCount: Int) {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        let columns = try columnNames(table: "thread_spawn_edges")
        guard !columns.isEmpty else { return ([], 0) }
        guard Set(["parent_thread_id", "child_thread_id"]).isSubset(of: columns) else {
            throw AgentSQLiteError.unsupportedSchema("thread_spawn_edges")
        }
        let sql = "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AgentSQLiteError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var edges: [CodexEdge] = []
        var issueCount = 0
        var rowCount = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw AgentSQLiteError.queryFailed }
            rowCount += 1
            if rowCount.isMultiple(of: 128) {
                try Task.checkCancellation()
                progress(rowCount)
            }
            guard let parent = normalizedUUID(sqliteText(statement, 0)),
                  let child = normalizedUUID(sqliteText(statement, 1))
            else {
                issueCount += 1
                continue
            }
            edges.append(CodexEdge(
                parent: parent,
                child: child
            ))
        }
        progress(rowCount)
        return (edges, issueCount)
    }

    private func columnNames(table: String) throws -> Set<String> {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil)
                == SQLITE_OK,
              let statement else { throw AgentSQLiteError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var result: Set<String> = []
        var rowCount = 0
        while true {
            rowCount += 1
            if rowCount.isMultiple(of: 128) { try Task.checkCancellation() }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw AgentSQLiteError.queryFailed }
            let name = sqliteText(statement, 1)
            if !name.isEmpty { result.insert(name) }
        }
    }

    private func journalMode() throws -> String {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw sqliteError(code: step) }
        return sqliteText(statement, 0)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw sqliteError(code: step) }
        let value = sqlite3_column_int64(statement, 0)
        guard value >= 0, value <= Int64(Int.max) else { throw AgentSQLiteError.queryFailed }
        return Int(value)
    }

    private func execute(_ sql: String) throws {
        guard let handle else { throw AgentSQLiteError.queryFailed }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(code: result) }
    }

    private func sqliteError(code: Int32? = nil) -> AgentSQLiteError {
        guard let handle else { return .queryFailed }
        let result = code ?? sqlite3_extended_errcode(handle)
        let primary = result & 0xFF
        if primary == SQLITE_INTERRUPT { return .interrupted }
        if primary == SQLITE_BUSY || primary == SQLITE_LOCKED { return .temporarilyBusy }
        if primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB { return .unreadable }
        if primary == SQLITE_CANTOPEN || primary == SQLITE_IOERR || primary == SQLITE_PERM {
            return .unavailable
        }
        return .queryFailed
    }
}

private enum AgentSQLiteError: Error {
    case openFailed(String)
    case queryFailed
    case unsupportedSchema(String)
    case unsupportedJournalMode
    case temporarilyBusy
    case interrupted
    case unreadable
    case unavailable

    var attributionStatus: AgentStorageDatabaseAttributionStatus {
        switch self {
        case .unsupportedSchema: .unsupportedFormat
        case .unsupportedJournalMode: .unsupportedJournalMode
        case .temporarilyBusy: .temporarilyBusy
        case .unreadable: .unreadable
        case .openFailed, .unavailable: .unavailable
        case .interrupted, .queryFailed: .unavailable
        }
    }

    var diagnosticComponent: String? {
        if case .unsupportedSchema(let component) = self { return component }
        return nil
    }
}

private func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
}

private struct ClaudeSessionMetadata: Sendable {
    var customTitle: String?
    var aiTitle: String?
    var lastPrompt: String?
    var firstUserPrompt: String?
    var cwd: String?
    var updatedAt: Date = .distantPast
    var sessionIDs: Set<String> = []
    var agentIDs: Set<String> = []
    var validJSONObjectCount = 0
    var supportedRecordCount = 0
    var malformedLineCount = 0
}

private enum ClaudeMetadataReader {
    private static let chunkSize = 64 * 1_024
    private static let maximumLineSize = 512 * 1_024

    static func read(
        _ url: URL,
        onRead: ((Int) -> Void)? = nil
    ) throws -> ClaudeSessionMetadata {
        let handle = try openSafeRegularFile(url)
        defer { try? handle.close() }
        var metadata = ClaudeSessionMetadata()
        var buffer = Data()
        var droppingOversizedLine = false

        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            onRead?(chunk.count)
            if droppingOversizedLine {
                if let newline = chunk.firstIndex(of: 0x0A) {
                    droppingOversizedLine = false
                    buffer.append(chunk.suffix(from: chunk.index(after: newline)))
                }
            } else {
                buffer.append(chunk)
            }

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                update(&metadata, with: line)
                buffer.removeSubrange(...newline)
            }
            if buffer.count > maximumLineSize {
                buffer.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
        }
        if !droppingOversizedLine, !buffer.isEmpty { update(&metadata, with: buffer) }
        if metadata.updatedAt == .distantPast {
            metadata.updatedAt = fileModificationDate(url) ?? .distantPast
        }
        return metadata
    }

    private static func update(_ metadata: inout ClaudeSessionMetadata, with line: Data.SubSequence) {
        guard line.count <= maximumLineSize else {
            metadata.malformedLineCount += 1
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            if !line.trimmingASCIIWhitespaceAndNewlines().isEmpty {
                metadata.malformedLineCount += 1
            }
            return
        }
        metadata.validJSONObjectCount += 1
        if let rawSessionID = object["sessionId"] as? String,
           normalizedUUID(rawSessionID) != nil {
            metadata.supportedRecordCount += 1
        }
        if let customTitle = nonEmptyString(object["customTitle"]) {
            metadata.customTitle = customTitle
        }
        if metadata.aiTitle == nil,
           object["type"] as? String == "ai-title",
           let aiTitle = nonEmptyString(object["aiTitle"]) {
            metadata.aiTitle = aiTitle
        }
        if metadata.lastPrompt == nil,
           object["type"] as? String == "last-prompt",
           let lastPrompt = nonEmptyString(object["lastPrompt"]) {
            metadata.lastPrompt = lastPrompt
        }
        if metadata.firstUserPrompt == nil,
           object["type"] as? String == "user",
           object["isMeta"] as? Bool != true,
           object["isSidechain"] as? Bool != true,
           let message = object["message"] as? [String: Any],
           let prompt = firstTextContent(message["content"]),
           !prompt.hasPrefix("<task-notification>") {
            metadata.firstUserPrompt = prompt
        }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { metadata.cwd = cwd }
        if let rawSessionID = object["sessionId"] as? String,
           let sessionID = normalizedUUID(rawSessionID) {
            metadata.sessionIDs.insert(sessionID)
        }
        if let rawAgentID = object["agentId"] as? String, !rawAgentID.isEmpty {
            metadata.agentIDs.insert(rawAgentID.lowercased())
        }
        if let rawTimestamp = object["timestamp"] as? String,
           let timestamp = parseISO8601Date(rawTimestamp) {
            metadata.updatedAt = max(metadata.updatedAt, timestamp)
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstTextContent(_ value: Any?) -> String? {
        if let text = nonEmptyString(value) { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        for block in blocks {
            guard block["type"] as? String == "text" else { continue }
            if let text = nonEmptyString(block["text"]) ?? nonEmptyString(block["content"]) {
                return text
            }
        }
        return nil
    }
}

private extension Data.SubSequence {
    func trimmingASCIIWhitespaceAndNewlines() -> Data.SubSequence {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        guard let first = firstIndex(where: { !whitespace.contains($0) }),
              let last = lastIndex(where: { !whitespace.contains($0) })
        else { return self[endIndex..<endIndex] }
        return self[first...last]
    }
}

private enum ClaudeToolReferenceReader {
    private static let chunkSize = 64 * 1_024
    private static let maximumLineSize = 512 * 1_024

    static func references(
        in url: URL,
        candidates: [String: [URL]],
        onRead: ((Int) -> Void)? = nil
    ) -> Set<String> {
        guard !candidates.isEmpty, let handle = try? openSafeRegularFile(url) else { return [] }
        defer { try? handle.close() }

        var result: Set<String> = []
        var buffer = Data()
        var droppingOversizedLine = false
        while true {
            if Task.isCancelled { break }
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            onRead?(chunk.count)
            if droppingOversizedLine {
                if let newline = chunk.firstIndex(of: 0x0A) {
                    droppingOversizedLine = false
                    buffer.append(chunk.suffix(from: chunk.index(after: newline)))
                }
            } else {
                buffer.append(chunk)
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                collectReferences(from: buffer.prefix(upTo: newline), candidates: candidates, into: &result)
                buffer.removeSubrange(...newline)
            }
            if buffer.count > maximumLineSize {
                buffer.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
        }
        if !droppingOversizedLine, !buffer.isEmpty {
            collectReferences(from: buffer[...], candidates: candidates, into: &result)
        }
        return result
    }

    private static func collectReferences(
        from line: Data.SubSequence,
        candidates: [String: [URL]],
        into result: inout Set<String>
    ) {
        guard line.count <= maximumLineSize,
              let object = try? JSONSerialization.jsonObject(with: Data(line))
        else { return }
        var strings: [String] = []
        collectStrings(in: object, into: &strings)
        for value in strings {
            for (name, files) in candidates where files.count == 1 {
                guard containsExactReference(in: value, fileName: name) else { continue }
                result.insert(files[0].standardizedFileURL.path)
            }
        }
    }

    private static func containsExactReference(in value: String, fileName: String) -> Bool {
        let needle = "tool-results/\(fileName)"
        var searchRange = value.startIndex..<value.endIndex
        while let match = value.range(of: needle, range: searchRange) {
            if match.upperBound == value.endIndex
                || !isFileNameCharacter(value[match.upperBound]) {
                return true
            }
            searchRange = match.upperBound..<value.endIndex
        }
        return false
    }

    private static func isFileNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "."
            || character == "_" || character == "-"
    }

    private static func collectStrings(in value: Any, into result: inout [String]) {
        if let string = value as? String {
            result.append(string)
        } else if let array = value as? [Any] {
            for item in array { collectStrings(in: item, into: &result) }
        } else if let dictionary = value as? [String: Any] {
            for item in dictionary.values { collectStrings(in: item, into: &result) }
        }
    }
}

private enum CodexRolloutTitleReader {
    private static let maximumPrefixSize = 1 * 1_024 * 1_024
    private static let maximumLineSize = 512 * 1_024

    static func title(at url: URL, onRead: ((Int) -> Void)? = nil) -> String? {
        guard let handle = try? openSafeRegularFile(url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var bytesRead = 0
        var responseItemCandidate: String?
        while bytesRead < maximumPrefixSize {
            if Task.isCancelled { return nil }
            let remaining = maximumPrefixSize - bytesRead
            guard let chunk = try? handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            bytesRead += chunk.count
            onRead?(chunk.count)
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                if let candidate = candidate(from: line) {
                    if candidate.isExplicitUserEvent { return candidate.title }
                    responseItemCandidate = responseItemCandidate ?? candidate.title
                }
                buffer.removeSubrange(...newline)
            }
            if buffer.count > maximumLineSize { buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty, let candidate = candidate(from: buffer[...]) {
            if candidate.isExplicitUserEvent { return candidate.title }
            responseItemCandidate = responseItemCandidate ?? candidate.title
        }
        return responseItemCandidate
    }

    private struct Candidate {
        let title: String
        let isExplicitUserEvent: Bool
    }

    private static func candidate(from line: Data.SubSequence) -> Candidate? {
        guard line.count <= maximumLineSize,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        if object["type"] as? String == "event_msg",
           payload["type"] as? String == "user_message",
           let value = payload["message"] as? String,
           let title = normalizedTitleCandidate(value, excluding: nil),
           !isInjectedContext(title) {
            return Candidate(title: title, isExplicitUserEvent: true)
        }
        guard object["type"] as? String == "response_item",
              payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return nil }
        for item in content where item["type"] as? String == "input_text" {
            guard let value = item["text"] as? String,
                  let candidate = normalizedTitleCandidate(value, excluding: nil),
                  !isInjectedContext(candidate)
            else { continue }
            return Candidate(title: candidate, isExplicitUserEvent: false)
        }
        return nil
    }

    private static func isInjectedContext(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("# agents.md instructions")
            || lowercased.hasPrefix("<environment_context>")
            || lowercased.hasPrefix("<app-context>")
            || lowercased.hasPrefix("<permissions instructions>")
            || lowercased.hasPrefix("<instructions>")
    }
}

private func parseISO8601Date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private struct ClaudeAgentMetadata: Sendable {
    let title: String?
    let spawnDepth: Int?
}

private func claudeAgentMetadata(from metadataURL: URL, agentID: String) -> ClaudeAgentMetadata? {
    guard let data = readSmallSafeFile(metadataURL, maximumBytes: 64 * 1_024),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let description = object["description"] as? String
    let agentType = object["agentType"] as? String
    let title = [description, agentType].lazy
        .compactMap { normalizedTitleCandidate($0, excluding: agentID) }
        .first
    return ClaudeAgentMetadata(title: title, spawnDepth: object["spawnDepth"] as? Int)
}

private func stableFamilyID(
    provider: AgentStorageProvider,
    sourceID: String,
    nativeID: String
) -> String {
    "\(provider.rawValue)|\(sourceID)|\(nativeID)"
}

private func stableNodeID(familyID: String, nativeID: String) -> String {
    "\(familyID)|node|\(nativeID)"
}

private func relativePath(of url: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path != rootPath, path.hasPrefix(rootPath + "/") else { return "" }
    return String(path.dropFirst(rootPath.count + 1))
}

private func canonicalURL(_ url: URL) -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else {
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
    let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let bytes = buffer[..<terminator].map { UInt8(bitPattern: $0) }
    return URL(
        fileURLWithPath: String(decoding: bytes, as: UTF8.self),
        isDirectory: true
    )
}

private func normalizedUUID(_ value: String) -> String? {
    UUID(uuidString: value)?.uuidString.lowercased()
}

private func urlPathKey(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func extractUUID(from value: String) -> String? {
    let scalars = Array(value.utf8)
    guard scalars.count >= 36 else { return nil }
    for start in 0...(scalars.count - 36) {
        let candidate = String(decoding: scalars[start..<(start + 36)], as: UTF8.self)
        if let normalized = normalizedUUID(candidate) { return normalized }
    }
    return nil
}

private func claudeAgentID(from fileName: String) -> String? {
    guard fileName.hasPrefix("agent-") else { return nil }
    var value = String(fileName.dropFirst("agent-".count))
    if value.hasSuffix(".meta.json") { value.removeLast(".meta.json".count) }
    else if value.hasSuffix(".jsonl") { value.removeLast(".jsonl".count) }
    else { return nil }
    return value.isEmpty ? nil : value.lowercased()
}

private enum AgentFileReadError: Error {
    case unsafeFile
}

private func openSafeRegularFile(_ url: URL) throws -> FileHandle {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw AgentFileReadError.unsafeFile }
    var fileStat = stat()
    guard fstat(descriptor, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG else {
        Darwin.close(descriptor)
        throw AgentFileReadError.unsafeFile
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func readSmallSafeFile(_ url: URL, maximumBytes: Int64) -> Data? {
    guard let handle = try? openSafeRegularFile(url) else { return nil }
    defer { try? handle.close() }
    var fileStat = stat()
    guard fstat(handle.fileDescriptor, &fileStat) == 0,
          fileStat.st_size >= 0,
          fileStat.st_size <= maximumBytes
    else { return nil }
    return try? handle.readToEnd()
}

private func normalizedTitleCandidate(_ value: String?, excluding nativeID: String?) -> String? {
    guard let value else { return nil }
    let maximumLength = 160
    var result = ""
    var pendingSpace = false
    var wasTruncated = false
    let prefix = value.prefix(2_048)
    let wasPrefixLimited = prefix.endIndex != value.endIndex
    for character in prefix {
        if character.unicodeScalars.allSatisfy({
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) {
            if !result.isEmpty { pendingSpace = true }
            continue
        }
        if pendingSpace, result.count < maximumLength {
            result.append(" ")
            pendingSpace = false
        }
        guard result.count < maximumLength else {
            wasTruncated = true
            break
        }
        result.append(character)
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { return nil }
    if let nativeID, result.caseInsensitiveCompare(nativeID) == .orderedSame { return nil }
    if normalizedUUID(result) != nil { return nil }
    return wasTruncated || wasPrefixLimited ? result + "…" : result
}

private func storageTitleDate(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
    )
}

private func shortID(_ id: String) -> String {
    String(id.prefix(8))
}

private struct AgentStorageProjectResolver: Sendable {
    static let nonProjectDirectoryName = "Non-project directory"

    private var cachedNames: [String: String] = [:]
    private var learnedRepositoryNames: [String: String] = [:]

    mutating func register(cwd: String, gitOriginURL: String?) {
        guard let gitOriginURL = nonEmptyTrimmed(gitOriginURL ?? ""),
              let repositoryName = Self.repositoryName(from: gitOriginURL),
              let path = Self.normalizedPath(cwd)
        else { return }
        learnedRepositoryNames[path] = repositoryName
        cachedNames[path] = repositoryName
    }

    mutating func projectName(cwd: String, gitOriginURL: String?) -> String {
        if let gitOriginURL = nonEmptyTrimmed(gitOriginURL ?? ""),
           let repositoryName = Self.repositoryName(from: gitOriginURL) {
            if let path = Self.normalizedPath(cwd) {
                learnedRepositoryNames[path] = repositoryName
                cachedNames[path] = repositoryName
            }
            return repositoryName
        }

        guard let path = Self.normalizedPath(cwd) else {
            return Self.nonProjectDirectoryName
        }
        if let cached = cachedNames[path] { return cached }
        if let learned = learnedRepositoryNames[path] {
            cachedNames[path] = learned
            return learned
        }

        let root = Self.managedClaudeWorktreeRoot(from: path)
            ?? Self.rootGitProject(from: path)
        let resolved = root
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap(nonEmptyTrimmed)
            ?? Self.nonProjectDirectoryName
        cachedNames[path] = resolved
        return resolved
    }

    func titleContext(cwd: String, project: String) -> String {
        guard project == Self.nonProjectDirectoryName,
              let path = Self.normalizedPath(cwd),
              let leaf = nonEmptyTrimmed(URL(fileURLWithPath: path).lastPathComponent)
        else { return project }
        return leaf
    }

    private static func normalizedPath(_ cwd: String) -> String? {
        guard let cwd = nonEmptyTrimmed(cwd) else { return nil }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    private static func repositoryName(from originURL: String) -> String? {
        var value = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<separator])
        }
        while value.last == "/" { value.removeLast() }
        guard !value.isEmpty else { return nil }
        let separator = value.lastIndex(where: { $0 == "/" || $0 == ":" })
        var name = separator.map { String(value[value.index(after: $0)...]) } ?? value
        if name.lowercased().hasSuffix(".git") {
            name.removeLast(4)
        }
        return nonEmptyTrimmed(name)
    }

    private static func managedClaudeWorktreeRoot(from path: String) -> String? {
        let marker = "/.claude/worktrees/"
        guard let markerRange = path.range(of: marker) else { return nil }
        let root = String(path[..<markerRange.lowerBound])
        return nonEmptyTrimmed(root)
    }

    private static func rootGitProject(from path: String) -> String? {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            let dotGit = candidate.appending(path: ".git")
            var value = stat()
            if lstat(dotGit.path, &value) == 0 {
                switch value.st_mode & S_IFMT {
                case S_IFDIR:
                    return candidate.path
                case S_IFREG:
                    if let mainRoot = mainRepositoryRoot(
                        worktreeRoot: candidate,
                        dotGit: dotGit,
                        fileSize: value.st_size
                    ) {
                        return mainRoot
                    }
                    return candidate.path
                default:
                    return candidate.path
                }
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    private static func mainRepositoryRoot(
        worktreeRoot: URL,
        dotGit: URL,
        fileSize: off_t
    ) -> String? {
        guard fileSize >= 0, fileSize <= 65_536,
              let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              let pointer = contents
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", maxSplits: 1)
                .first,
              pointer.hasPrefix("gitdir:")
        else { return nil }
        let rawPath = pointer.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        let gitDirectory: URL
        if rawPath.hasPrefix("/") {
            gitDirectory = URL(fileURLWithPath: rawPath).standardizedFileURL
        } else {
            gitDirectory = worktreeRoot.appending(path: rawPath).standardizedFileURL
        }
        let worktreesDirectory = gitDirectory.deletingLastPathComponent()
        guard worktreesDirectory.lastPathComponent == "worktrees" else { return nil }
        return worktreesDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
}

private func nonEmptyTrimmed(_ value: String) -> String? {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}

private func decodedClaudeProjectName(_ encoded: String) -> String {
    let value = encoded.split(separator: "-").last.map(String.init) ?? encoded
    return value.isEmpty ? "Unknown project" : value
}

private func fileModificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
}

private func sumClamped(_ values: [UInt64], overflowed: inout Bool) -> UInt64 {
    var total: UInt64 = 0
    for value in values {
        let result = total.addingReportingOverflow(value)
        if result.overflow {
            overflowed = true
            return .max
        }
        total = result.partialValue
    }
    return total
}

private func addingExact(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw DatabaseAttributionMathError.overflow }
    return result.partialValue
}

private func scaledDatabaseBytes(
    logicalBytes: UInt64,
    physicalBytes: UInt64,
    totalEstimatedBytes: UInt64
) throws -> UInt64 {
    guard totalEstimatedBytes > 0 else { return 0 }
    guard totalEstimatedBytes > physicalBytes else { return logicalBytes }
    let product = logicalBytes.multipliedFullWidth(by: physicalBytes)
    return totalEstimatedBytes.dividingFullWidth(product).quotient
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

}
