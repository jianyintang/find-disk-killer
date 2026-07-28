import Darwin
import Foundation
import SQLite3

public enum AgentStorageScanPhase: Int, Sendable, Equatable, CaseIterable {
    case discoveringSources
    case readingMetadata
    case measuringEntries
    case validatingEntries
    case organizingResults
}

public struct AgentStorageScanProgress: Sendable, Equatable {
    public let phase: AgentStorageScanPhase
    public let completedCount: Int
    public let totalCount: Int?
    public let provider: AgentStorageProvider?

    public init(
        phase: AgentStorageScanPhase,
        completedCount: Int = 0,
        totalCount: Int? = nil,
        provider: AgentStorageProvider? = nil
    ) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.provider = provider
    }
}

public actor AgentStorageScanner {
    public struct Configuration: Sendable {
        public let homeDirectory: URL
        public let additionalRoots: [URL]
        public let includesDesktopData: Bool
        let beforePhysicalValidation: (@Sendable () -> Void)?

        public init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            additionalRoots: [URL] = [],
            includesDesktopData: Bool = true
        ) {
            self.homeDirectory = homeDirectory
            self.additionalRoots = additionalRoots
            self.includesDesktopData = includesDesktopData
            beforePhysicalValidation = nil
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
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func scan(
        progress: (@Sendable (AgentStorageScanProgress) -> Void)? = nil
    ) async throws -> AgentStorageSnapshot {
        let configuration = configuration
        let task = Task.detached(priority: .utility) {
            var engine = AgentStorageScanEngine(
                configuration: configuration,
                progressHandler: progress
            )
            return try engine.scan()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private struct AgentStorageScanEngine {
    private let configuration: AgentStorageScanner.Configuration
    private let progressHandler: (@Sendable (AgentStorageScanProgress) -> Void)?
    private let fileManager = FileManager.default
    private var scopes: [ScanScope] = []
    private var sources: [AgentStorageSource] = []
    private var families: [String: MutableFamily] = [:]
    private var codexTargets: [String: [String: ThreadTarget]] = [:]
    private var codexRelationshipConflictIDs: [String: Set<String>] = [:]
    private var claudeTargets: [String: [String: String]] = [:]
    private var claudeSubagentTargets: [String: [String: [String: String]]] = [:]
    private var claudeToolResultTargets: [String: [String: ClaimOwnership]] = [:]
    private var physicalLedger: [FileIdentity: PhysicalEntry] = [:]
    private var globalAggregates: [String: MutableGlobalAggregate] = [:]
    private var unattributedAggregates: [String: MutableUnattributedAggregate] = [:]
    private var skippedEntryCount = 0
    private var unstableEntries = AgentStorageUnstableEntryTracker()
    private var overflowed = false
    private var providerIssueCounts: [AgentStorageProvider: Int] = [:]
    private var providerMetadataOutcomes: [AgentStorageProvider: ProviderMetadataOutcome] = [:]
    private var measuredEntryCount = 0
    private let progressClock = ContinuousClock()
    private var lastProgressEmission: ContinuousClock.Instant?

    init(
        configuration: AgentStorageScanner.Configuration,
        progressHandler: (@Sendable (AgentStorageScanProgress) -> Void)?
    ) {
        self.configuration = configuration
        self.progressHandler = progressHandler
    }

    mutating func scan() throws -> AgentStorageSnapshot {
        reportProgress(.discoveringSources, force: true)
        scopes = discoverScopes()
        reportProgress(
            .discoveringSources,
            completedCount: scopes.count,
            totalCount: scopes.count,
            force: true
        )
        try Task.checkCancellation()

        let metadataScopes = scopes.filter {
            $0.kind == .codexHome || $0.kind == .claudeCode
        }
        reportProgress(.readingMetadata, totalCount: metadataScopes.count, force: true)
        for (index, scope) in metadataScopes.enumerated() {
            switch scope.kind {
            case .codexHome:
                try loadCodexMetadata(from: scope)
            case .claudeCode:
                try loadClaudeMetadata(from: scope)
            case .codexDesktop, .claudeDesktop:
                break
            }
            reportProgress(
                .readingMetadata,
                completedCount: index + 1,
                totalCount: metadataScopes.count,
                provider: scope.provider,
                force: true
            )
        }

        let exclusions = exclusionsByScope()
        reportProgress(.measuringEntries, totalCount: nil, force: true)
        for scope in scopes {
            try Task.checkCancellation()
            scanPhysicalScope(scope, excluding: exclusions[scope.id] ?? [])
            reportProgress(
                .measuringEntries,
                completedCount: measuredEntryCount,
                provider: scope.provider,
                force: true
            )
        }
        try Task.checkCancellation()
        configuration.beforePhysicalValidation?()
        reportProgress(
            .validatingEntries,
            totalCount: physicalLedger.count,
            force: true
        )
        try validatePhysicalEntries()

        reportProgress(
            .organizingResults,
            totalCount: physicalLedger.count,
            force: true
        )
        try resolvePhysicalLedger()
        reportProgress(
            .organizingResults,
            completedCount: physicalLedger.count,
            totalCount: physicalLedger.count,
            force: true
        )
        return try makeSnapshot()
    }

    private mutating func reportProgress(
        _ phase: AgentStorageScanPhase,
        completedCount: Int = 0,
        totalCount: Int? = nil,
        provider: AgentStorageProvider? = nil,
        force: Bool = false
    ) {
        let now = progressClock.now
        if !force, let lastProgressEmission,
           lastProgressEmission.duration(to: now) < .milliseconds(100) {
            return
        }
        lastProgressEmission = now
        progressHandler?(AgentStorageScanProgress(
            phase: phase,
            completedCount: completedCount,
            totalCount: totalCount,
            provider: provider
        ))
    }

    private mutating func discoverScopes() -> [ScanScope] {
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

            for desktopRoot in [
                applicationSupport.appending(path: "Claude-3p"),
                applicationSupport.appending(path: "Claude")
            ] where fileManager.fileExists(atPath: desktopRoot.path) {
                let nestedHomes = discoverNestedClaudeHomes(in: desktopRoot)
                candidates.append(contentsOf: nestedHomes.map {
                    ($0, .claude, .claudeCode, "Claude Desktop Agent")
                })
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
        for (candidate, provider, kind, displayName) in candidates {
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

    private mutating func loadCodexMetadata(from scope: ScanScope) throws {
        let databaseURL = scope.root.appending(path: "state_5.sqlite")
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            if fileManager.fileExists(atPath: scope.root.appending(path: "sessions").path) {
                recordMetadataOutcome(.unsupported, provider: .codex)
            } else {
                recordMetadataOutcome(.empty, provider: .codex)
            }
            return
        }

        do {
            let database = try ReadOnlyAgentSQLite(path: databaseURL.path)
            let snapshot = try database.codexSnapshot()
            recordMetadataOutcome(.supported, provider: .codex)
            let records = snapshot.threads
            let edges = snapshot.edges
            if snapshot.issueCount > 0 {
                providerIssueCounts[.codex, default: 0] += snapshot.issueCount
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
            }
            codexRelationshipConflictIDs[scope.id] = invalidThreadIDs

            var targets: [String: ThreadTarget] = [:]
            for rootID in Set(rootByThread.values) {
                guard let root = recordsByID[rootID] else { continue }
                let familyID = stableFamilyID(provider: .codex, sourceID: scope.id, nativeID: rootID)
                let rootNode = MutableNode(
                    id: stableNodeID(familyID: familyID, nativeID: rootID),
                    nativeID: rootID,
                    parentNativeID: nil,
                    depth: 0,
                    title: codexDisplayTitle(root, isSubagent: false),
                    updatedAt: root.updatedAt,
                    path: existingPath(root.rolloutPath)
                )
                families[familyID] = MutableFamily(
                    id: familyID,
                    provider: .codex,
                    sourceID: scope.id,
                    nativeThreadID: rootID,
                    title: rootNode.title,
                    project: projectName(from: root.cwd),
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
                        title: codexDisplayTitle(record, isSubagent: true),
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
        } catch {
            recordMetadataOutcome(.unreadable, provider: .codex)
        }
    }

    private mutating func loadClaudeMetadata(from scope: ScanScope) throws {
        let projectsURL = scope.root.appending(path: "projects", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: projectsURL.path) else { return }
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            recordSkipped(provider: .claude)
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
                    metadata = try ClaudeMetadataReader.read(file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    providerIssueCounts[.claude, default: 0] += 1
                    foundUnreadableData = true
                    continue
                }
                if metadata.validJSONObjectCount > 0,
                   metadata.supportedRecordCount == 0 {
                    foundUnsupportedFormat = true
                    continue
                }
                if metadata.malformedLineCount > 0 {
                    foundUnreadableData = true
                }
                guard metadata.sessionIDs == [sessionID] else {
                    providerIssueCounts[.claude, default: 0] += 1
                    foundUnreadableData = true
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
            let project = cwd.map(projectName(from:)) ?? fallbackProject
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
                        let metadata = try ClaudeMetadataReader.read(file)
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
                }
            }

            var ownersByToolPath: [String: Set<String>] = [:]
            let uniqueToolFiles = toolFilesByName.filter { $0.value.count == 1 }
            for record in records {
                for path in ClaudeToolReferenceReader.references(
                    in: record.file,
                    candidates: uniqueToolFiles
                ) {
                    ownersByToolPath[path, default: []].insert(rootNodeID)
                }
            }
            for (agentID, transcripts) in validAgentTranscripts {
                guard let nodeID = knownAgents[agentID] else { continue }
                for transcript in transcripts {
                    for path in ClaudeToolReferenceReader.references(
                        in: transcript,
                        candidates: uniqueToolFiles
                    ) {
                        ownersByToolPath[path, default: []].insert(nodeID)
                    }
                }
            }
            for files in toolFilesByName.values {
                if files.count > 1 {
                    providerIssueCounts[.claude, default: 0] += 1
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

    private func codexDisplayTitle(_ record: CodexThreadRecord, isSubagent: Bool) -> String {
        if let title = normalizedTitleCandidate(record.displayTitle, excluding: record.id) {
            return title
        }
        if let rollout = existingPath(record.rolloutPath),
           let title = CodexRolloutTitleReader.title(at: URL(fileURLWithPath: rollout)) {
            return title
        }
        let date = storageTitleDate(record.updatedAt)
        if isSubagent { return "Subagent · \(date)" }
        return "\(projectName(from: record.cwd)) · \(date)"
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
                    provider: scope.provider
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
            }
            existing.updatedAt = max(existing.updatedAt, updatedAt)
            existing.claims.append(claim)
            existing.observations.append(observation)
            physicalLedger[identity] = existing
        } else {
            physicalLedger[identity] = PhysicalEntry(
                allocatedBytes: allocated,
                logicalBytes: logical,
                updatedAt: updatedAt,
                claims: [claim],
                observations: [observation]
            )
        }
    }

    private mutating func validatePhysicalEntries() throws {
        var count = 0
        for (identity, entry) in physicalLedger {
            count += 1
            if count.isMultiple(of: 128) {
                try Task.checkCancellation()
                reportProgress(
                    .validatingEntries,
                    completedCount: count,
                    totalCount: physicalLedger.count
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
                    unstableEntries.mark(
                        device: identity.device,
                        inode: identity.inode,
                        provider: observation.provider
                    )
                    continue
                }
            }
        }
        reportProgress(
            .validatingEntries,
            completedCount: physicalLedger.count,
            totalCount: physicalLedger.count,
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
        case .claudeCode:
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
        family.composition[category, default: 0] = family.composition[category, default: 0]
            .addingClamped(entry.allocatedBytes)
        families[familyID] = family
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
                artifactCount: family.artifactCount,
                path: family.path,
                subagents: subagents,
                composition: family.composition
            )
        }.filter { $0.allocatedBytes > 0 }.sorted {
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
        let chatBytes = sumClamped(finalFamilies.map(\.allocatedBytes), overflowed: &didOverflow)
        let globalBytes = sumClamped(finalGlobals.map(\.allocatedBytes), overflowed: &didOverflow)
        let unattributedBytes = sumClamped(finalUnattributed.map(\.allocatedBytes), overflowed: &didOverflow)
        let classified = sumClamped(
            [chatBytes, globalBytes, unattributedBytes],
            overflowed: &didOverflow
        )
        let reconciliationDelta = measured >= classified
            ? measured - classified
            : classified - measured
        let metadataIssueCount = providerMetadataOutcomes.values.reduce(0) {
            $0 + $1.unsupportedCount + $1.unreadableCount
        }
        let providerIssueCount = providerIssueCounts.values.reduce(0, +) + metadataIssueCount
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
                $0.addingClamped($1.allocatedBytes)
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
            let issueCount = providerIssueCounts[provider, default: 0]
                + metadataOutcome.unsupportedCount
                + metadataOutcome.unreadableCount
            let supportStatus: AgentStorageProviderSupportStatus
            if metadataOutcome.supportedCount == 0, metadataOutcome.unsupportedCount > 0 {
                supportStatus = .unsupportedFormat
            } else if issueCount > 0 || unstableEntries.count(for: provider) > 0 {
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
                },
                subagentBytes: providerFamilies.reduce(UInt64(0)) {
                    $0.addingClamped($1.subagentAllocatedBytes)
                },
                familyOtherBytes: providerFamilies.reduce(UInt64(0)) {
                    $0.addingClamped($1.familyOtherAllocatedBytes)
                },
                threadCount: providerFamilies.count,
                subagentCount: providerFamilies.reduce(0) { $0 + $1.subagentCount },
                sourceCount: sourceCount,
                issueCount: issueCount,
                unstableEntryCount: unstableEntries.count(for: provider),
                supportStatus: supportStatus,
                unsupportedSourceCount: metadataOutcome.unsupportedCount,
                unreadableSourceCount: metadataOutcome.unreadableCount
            )
        }.filter { $0.sourceCount > 0 || $0.exclusiveBytes > 0 }

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
            providerDatasets: providerDatasets
        )
    }

    private mutating func recordSkipped(provider: AgentStorageProvider, count: Int = 1) {
        skippedEntryCount += count
        providerIssueCounts[provider, default: 0] += count
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

private struct PhysicalEntry: Sendable {
    var allocatedBytes: UInt64
    var logicalBytes: UInt64
    var updatedAt: Date
    var claims: [PhysicalClaim]
    var observations: [FileObservation]
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
    var artifactCount: Int = 0
    var path: String?
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
            artifactCount: node.artifactCount,
            path: node.path
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
    var updatedAt: Date
    let isArchived: Bool
    let mainNodeID: String
    var path: String?
    var nodes: [String: MutableNode]
    var familyOtherAllocatedBytes: UInt64 = 0
    var artifactCount: Int = 0
    var composition: [AgentStorageArtifactCategory: UInt64] = [:]
}

private struct MutableGlobalAggregate: Sendable {
    let id: String
    let provider: AgentStorageProvider?
    let category: AgentStorageGlobalCategory
    var allocatedBytes: UInt64 = 0
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

private struct ThreadTarget: Sendable {
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

    init(path: String) throws {
        var fileStat = stat()
        guard lstat(path, &fileStat) == 0, (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw AgentSQLiteError.openFailed("\(path): not a regular file")
        }
        let expectedIdentity = FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino)
        )
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
            ) == expectedIdentity
        guard openedPathIsStable else {
            sqlite3_close_v2(pointer)
            throw AgentSQLiteError.openFailed("\(path): file identity changed while opening")
        }
        handle = pointer
        sqlite3_extended_result_codes(pointer, 1)
        guard sqlite3_exec(pointer, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw AgentSQLiteError.queryFailed
        }
        sqlite3_busy_timeout(pointer, 150)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func codexSnapshot() throws -> CodexDatabaseSnapshot {
        try execute("BEGIN DEFERRED TRANSACTION")
        var committed = false
        defer {
            if !committed { try? execute("ROLLBACK") }
        }
        let threadResult = try codexThreads()
        let edgeResult = try codexEdges()
        try execute("COMMIT")
        committed = true
        return CodexDatabaseSnapshot(
            threads: threadResult.values,
            edges: edgeResult.values,
            issueCount: threadResult.issueCount + edgeResult.issueCount
        )
    }

    private func codexThreads() throws -> (values: [CodexThreadRecord], issueCount: Int) {
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
               \(expression("source")), \(expression("agent_path")), \(expression("agent_role"))
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
            rowCount += 1
            if rowCount.isMultiple(of: 128) { try Task.checkCancellation() }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw AgentSQLiteError.queryFailed }
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
                    || !agentRole.isEmpty
            ))
        }
        return (records, issueCount)
    }

    private func codexEdges() throws -> (values: [CodexEdge], issueCount: Int) {
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
            rowCount += 1
            if rowCount.isMultiple(of: 128) { try Task.checkCancellation() }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw AgentSQLiteError.queryFailed }
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

    private func execute(_ sql: String) throws {
        guard let handle,
              sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
        else { throw AgentSQLiteError.queryFailed }
    }
}

private enum AgentSQLiteError: Error {
    case openFailed(String)
    case queryFailed
    case unsupportedSchema(String)
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

    static func read(_ url: URL) throws -> ClaudeSessionMetadata {
        let handle = try openSafeRegularFile(url)
        defer { try? handle.close() }
        var metadata = ClaudeSessionMetadata()
        var buffer = Data()
        var droppingOversizedLine = false

        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
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

    static func references(in url: URL, candidates: [String: [URL]]) -> Set<String> {
        guard !candidates.isEmpty, let handle = try? openSafeRegularFile(url) else { return [] }
        defer { try? handle.close() }

        var result: Set<String> = []
        var buffer = Data()
        var droppingOversizedLine = false
        while true {
            if Task.isCancelled { break }
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
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

    static func title(at url: URL) -> String? {
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

private func projectName(from path: String) -> String {
    guard !path.isEmpty else { return "Unknown project" }
    return URL(fileURLWithPath: path).lastPathComponent
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

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

}
