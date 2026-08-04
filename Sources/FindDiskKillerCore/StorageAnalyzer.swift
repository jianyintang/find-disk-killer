import Darwin
import Foundation

public actor StorageAnalyzer {
    public typealias ProgressHandler = @Sendable (StorageScanProgress) -> Void
    typealias SourceStartHook = @Sendable (StorageSourceID) -> Void
    typealias RootStartHook = @Sendable (StorageSourceID, String) -> Void
    typealias VolumeProvider = @Sendable () -> [VolumeInfo]

    static let rootWorkerCountPerSource = 2

    private let configuration: StorageScanConfiguration
    private let fileManager: FileManager
    private let sourceStartHook: SourceStartHook?
    private let rootStartHook: RootStartHook?
    private let volumeProvider: VolumeProvider

    public init(
        configuration: StorageScanConfiguration = .init(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        sourceStartHook = nil
        rootStartHook = nil
        volumeProvider = Self.collectMountedVolumes
    }

    init(
        configuration: StorageScanConfiguration,
        fileManager: FileManager = .default,
        sourceStartHook: @escaping SourceStartHook,
        rootStartHook: RootStartHook? = nil,
        volumeProvider: @escaping VolumeProvider = StorageAnalyzer.collectMountedVolumes
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.sourceStartHook = sourceStartHook
        self.rootStartHook = rootStartHook
        self.volumeProvider = volumeProvider
    }

    public func detect(
        progress: (@Sendable (StorageSourceCandidate) -> Void)? = nil
    ) -> [StorageSourceCandidate] {
        StorageSourceCatalog.detect(
            configuration: configuration,
            fileManager: fileManager,
            progress: progress
        )
    }

    public func scan(progress: ProgressHandler? = nil) async throws -> StorageAnalysisSnapshot {
        progress?(StorageScanProgress(phase: .discovering))
        let candidates = detect().filter { !$0.roots.isEmpty }
        return try await scan(candidates: candidates, progress: progress)
    }

    public func scan(
        sourceID: StorageSourceID,
        progress: ProgressHandler? = nil
    ) async throws -> StorageAnalysisSnapshot {
        progress?(StorageScanProgress(phase: .discovering, sourceID: sourceID))
        let candidates = detect().filter { $0.id == sourceID }
        return try await scan(candidates: candidates, progress: progress)
    }

    private func scan(
        candidates: [StorageSourceCandidate],
        progress: ProgressHandler?
    ) async throws -> StorageAnalysisSnapshot {
        try Task.checkCancellation()
        let mountedVolumes = volumeProvider()
        let progressAccumulator = StorageScanProgressAccumulator(
            totalSourceCount: candidates.count,
            mountedVolumes: mountedVolumes,
            progress: progress
        )
        async let providerInventories = inspectProviderInventories(for: candidates)
        let outputs = try await scanCandidates(
            candidates,
            // Every discovered source should enter the scan immediately. The
            // cooperative runtime still controls execution, while avoiding a
            // small fixed queue that leaves large sources blocking the rest.
            maximumConcurrentSources: candidates.count,
            mountedVolumes: mountedVolumes,
            progress: progressAccumulator,
            sourceStartHook: sourceStartHook,
            rootStartHook: rootStartHook
        )
        let merged = merge(outputs: outputs, orderedBy: candidates)
        let inventories = await providerInventories

        try Task.checkCancellation()
        progress?(StorageScanProgress(
            phase: .reconciling,
            completedSourceCount: candidates.count,
            totalSourceCount: candidates.count,
            processedEntryCount: merged.processedEntryCount,
            processedBytes: merged.processedBytes,
            volumes: progressAccumulator.currentVolumes()
        ))
        let snapshot = reconcile(
            candidates: candidates,
            ledger: merged.ledger,
            skippedBySource: merged.skippedBySource,
            mountedVolumes: mountedVolumes,
            providerInventories: inventories
        )
        progress?(StorageScanProgress(
            phase: .finished,
            completedSourceCount: candidates.count,
            totalSourceCount: candidates.count,
            processedEntryCount: snapshot.measuredEntryCount,
            processedBytes: snapshot.totalAllocatedBytes,
            volumes: snapshot.volumes
        ))
        return snapshot
    }

    private func inspectProviderInventories(
        for candidates: [StorageSourceCandidate]
    ) async -> [StorageSourceID: DockerStorageInventory] {
        guard configuration.providerInventoryEnabled else { return [:] }
        async let dockerInventory: DockerStorageInventory? = candidates.contains(where: { $0.id == .docker })
            ? await DockerStorageInspector().inspect()
            : nil
        async let podmanInventory: DockerStorageInventory? = candidates.contains(where: { $0.id == .podman })
            ? await PodmanStorageInspector().inspect()
            : nil
        var result: [StorageSourceID: DockerStorageInventory] = [:]
        if let inventory = await dockerInventory { result[.docker] = inventory }
        if let inventory = await podmanInventory { result[.podman] = inventory }
        return result
    }

    private func scanCandidates(
        _ candidates: [StorageSourceCandidate],
        maximumConcurrentSources: Int,
        mountedVolumes: [VolumeInfo],
        progress: StorageScanProgressAccumulator,
        sourceStartHook: SourceStartHook?,
        rootStartHook: RootStartHook?
    ) async throws -> [StorageSourceScanOutput] {
        guard !candidates.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: StorageSourceScanOutput.self) { group in
            var iterator = candidates.makeIterator()
            let workerCount = min(maximumConcurrentSources, candidates.count)
            for _ in 0..<workerCount {
                if let candidate = iterator.next() {
                    group.addTask {
                        try await Self.scanCandidate(
                            candidate,
                            mountedVolumes: mountedVolumes,
                            progress: progress,
                            sourceStartHook: sourceStartHook,
                            rootStartHook: rootStartHook
                        )
                    }
                }
            }

            var outputs: [StorageSourceScanOutput] = []
            outputs.reserveCapacity(candidates.count)
            while let output = try await group.next() {
                outputs.append(output)
                if let candidate = iterator.next() {
                    group.addTask {
                        try await Self.scanCandidate(
                            candidate,
                            mountedVolumes: mountedVolumes,
                            progress: progress,
                            sourceStartHook: sourceStartHook,
                            rootStartHook: rootStartHook
                        )
                    }
                }
            }
            return outputs
        }
    }

    private nonisolated static func scanCandidate(
        _ candidate: StorageSourceCandidate,
        mountedVolumes: [VolumeInfo],
        progress: StorageScanProgressAccumulator,
        sourceStartHook: SourceStartHook?,
        rootStartHook: RootStartHook?
    ) async throws -> StorageSourceScanOutput {
        try Task.checkCancellation()
        sourceStartHook?(candidate.id)
        let roots = candidate.roots.sorted { lhs, rhs in
            let lhsDepth = lhs.path.split(separator: "/").count
            let rhsDepth = rhs.path.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            return lhs.path < rhs.path
        }
        progress.sourceStarted(candidate.id, totalWorkCount: roots.count)
        let rootOutputs = try await withThrowingTaskGroup(of: StorageRootScanOutput.self) { group in
            var iterator = Array(roots.enumerated()).makeIterator()
            let workerCount = min(rootWorkerCountPerSource, roots.count)
            for _ in 0..<workerCount {
                if let work = iterator.next() {
                    group.addTask {
                        try scanRoot(
                            candidate: candidate,
                            root: work.element,
                            rootOffset: work.offset,
                            totalRootCount: roots.count,
                            mountedVolumes: mountedVolumes,
                            progress: progress,
                            rootStartHook: rootStartHook
                        )
                    }
                }
            }

            var outputs: [StorageRootScanOutput] = []
            outputs.reserveCapacity(roots.count)
            while let output = try await group.next() {
                outputs.append(output)
                if let work = iterator.next() {
                    group.addTask {
                        try scanRoot(
                            candidate: candidate,
                            root: work.element,
                            rootOffset: work.offset,
                            totalRootCount: roots.count,
                            mountedVolumes: mountedVolumes,
                            progress: progress,
                            rootStartHook: rootStartHook
                        )
                    }
                }
            }
            return outputs
        }

        var ledger: [StoragePhysicalIdentity: StorageLedgerEntry] = [:]
        var processedEntries = 0
        var processedBytes: UInt64 = 0
        var processedBytesByVolume: [String: UInt64] = [:]
        var skippedRootCount = 0
        for output in rootOutputs.sorted(by: { $0.rootOffset < $1.rootOffset }) {
            processedEntries += output.processedEntryCount
            skippedRootCount += output.skippedRootCount
            for (identity, entry) in output.ledger {
                if var existing = ledger[identity] {
                    existing.claims.append(contentsOf: entry.claims)
                    ledger[identity] = existing
                } else {
                    ledger[identity] = entry
                    processedBytes = processedBytes.addingClamped(entry.allocatedBytes)
                    if let volumeID = output.volumeID {
                        processedBytesByVolume[volumeID, default: 0] =
                            processedBytesByVolume[volumeID, default: 0]
                                .addingClamped(entry.allocatedBytes)
                    }
                }
            }
        }
        progress.sourceFinished(
            candidate.id,
            processedEntryCount: processedEntries,
            processedBytes: processedBytes,
            sourceVolumeBytes: processedBytesByVolume
        )
        return StorageSourceScanOutput(
            sourceID: candidate.id,
            ledger: ledger,
            skippedRootCount: skippedRootCount,
            processedEntryCount: processedEntries,
            processedBytes: processedBytes
        )
    }

    private nonisolated static func scanRoot(
        candidate: StorageSourceCandidate,
        root: StorageSourceRoot,
        rootOffset: Int,
        totalRootCount: Int,
        mountedVolumes: [VolumeInfo],
        progress: StorageScanProgressAccumulator,
        rootStartHook: RootStartHook?
    ) throws -> StorageRootScanOutput {
        try Task.checkCancellation()
        rootStartHook?(candidate.id, root.id)
        var ledger: [StoragePhysicalIdentity: StorageLedgerEntry] = [:]
        var processedEntries = 0
        var processedBytes: UInt64 = 0
        var processedBytesByVolume: [String: UInt64] = [:]
        let resolvedRootPath = URL(fileURLWithPath: root.path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let volumeID = VolumePathResolver.bestMatch(
            for: resolvedRootPath,
            in: mountedVolumes
        )?.id
        progress.sourceProgress(
            candidate.id,
            workID: root.id,
            processedEntryCount: 0,
            processedBytes: 0,
            sourceVolumeBytes: [:],
            currentWork: root.displayName,
            currentWorkIndex: rootOffset + 1,
            totalWorkCount: totalRootCount
        )
        do {
            if candidate.id == .go || candidate.id == .workspace {
                try measureDirectoryAggregate(
                    root: root,
                    excludingNames: root.id.hasSuffix(".module-cache") ? ["cache"] : [],
                    into: &ledger,
                    processedEntries: &processedEntries,
                    processedBytes: &processedBytes,
                    processedBytesByVolume: &processedBytesByVolume,
                    mountedVolumes: mountedVolumes
                )
            } else {
                let excludedDescendantPaths = Set(candidate.roots.compactMap { other -> String? in
                    guard other.id != root.id,
                          other.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
                        return nil
                    }
                    return String(other.path.dropFirst(root.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                })
                try measure(
                    root: root,
                    fileManager: FileManager(),
                    excludedDescendantPaths: excludedDescendantPaths,
                    into: &ledger,
                    processedEntries: &processedEntries,
                    processedBytes: &processedBytes,
                    processedBytesByVolume: &processedBytesByVolume,
                    mountedVolumes: mountedVolumes,
                    progress: progress,
                    workID: root.id,
                    currentWork: root.displayName,
                    currentWorkIndex: rootOffset + 1,
                    totalWorkCount: totalRootCount
                )
            }
            progress.sourceProgress(
                candidate.id,
                workID: root.id,
                processedEntryCount: processedEntries,
                processedBytes: processedBytes,
                sourceVolumeBytes: processedBytesByVolume,
                currentWork: root.displayName,
                currentWorkIndex: rootOffset + 1,
                totalWorkCount: totalRootCount
            )
            return StorageRootScanOutput(
                rootOffset: rootOffset,
                volumeID: volumeID,
                ledger: ledger,
                skippedRootCount: 0,
                processedEntryCount: processedEntries
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return StorageRootScanOutput(
                rootOffset: rootOffset,
                volumeID: volumeID,
                ledger: ledger,
                skippedRootCount: 1,
                processedEntryCount: processedEntries
            )
        }
    }

    private nonisolated static func measureDirectoryAggregate(
        root: StorageSourceRoot,
        excludingNames: [String],
        into ledger: inout [StoragePhysicalIdentity: StorageLedgerEntry],
        processedEntries: inout Int,
        processedBytes: inout UInt64,
        processedBytesByVolume: inout [String: UInt64],
        mountedVolumes: [VolumeInfo]
    ) throws {
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var rootStat = stat()
        guard lstat(rootURL.path, &rootStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let allocatedBytes = try directoryAllocatedBytes(
            at: rootURL,
            excludingNames: excludingNames
        )
        let classification = StoragePathClassifier.classify(
            sourceID: root.sourceID,
            root: root,
            relativePath: ""
        )
        let identity = StoragePhysicalIdentity(
            device: UInt64(rootStat.st_dev),
            inode: UInt64(rootStat.st_ino)
        )
        let claim = StorageLedgerClaim(
            sourceID: root.sourceID,
            rootID: root.id,
            rootPath: rootURL.path,
            simulatorObjectIdentifier: nil,
            category: classification.category,
            risk: classification.risk,
            isProtected: classification.isProtected,
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(rootStat.st_mtimespec.tv_sec)
            )
        )
        ledger[identity] = StorageLedgerEntry(
            identity: identity,
            allocatedBytes: allocatedBytes,
            logicalBytes: allocatedBytes,
            claims: [claim]
        )
        processedEntries += 1
        processedBytes = processedBytes.addingClamped(allocatedBytes)
        if let volumeID = VolumePathResolver.bestMatch(
            for: rootURL.path,
            in: mountedVolumes
        )?.id {
            processedBytesByVolume[volumeID, default: 0] =
                processedBytesByVolume[volumeID, default: 0].addingClamped(allocatedBytes)
        }
    }

    private nonisolated static func directoryAllocatedBytes(
        at url: URL,
        excludingNames: [String]
    ) throws -> UInt64 {
        let targets: [URL]
        var rootDirectoryBytes: UInt64 = 0
        if excludingNames.isEmpty {
            targets = [url]
        } else {
            let excluded = Set(excludingNames)
            targets = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).filter { !excluded.contains($0.lastPathComponent) }
            var rootStat = stat()
            if lstat(url.path, &rootStat) == 0 {
                rootDirectoryBytes = UInt64(max(0, rootStat.st_blocks))
                    .multipliedClamped(by: 512)
            }
        }
        guard !targets.isEmpty else { return rootDirectoryBytes }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", "-P"] + targets.map(\.path)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let lines = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline),
              lines.count == targets.count else {
            throw POSIXError(.EIO)
        }
        return try lines.reduce(rootDirectoryBytes) { total, line in
            guard let firstField = line.split(whereSeparator: \.isWhitespace).first,
                  let blocks = UInt64(firstField) else {
                throw POSIXError(.EIO)
            }
            return total.addingClamped(blocks.multipliedClamped(by: 1_024))
        }
    }

    private nonisolated static func measure(
        root: StorageSourceRoot,
        fileManager: FileManager,
        excludedDescendantPaths: Set<String>,
        into ledger: inout [StoragePhysicalIdentity: StorageLedgerEntry],
        processedEntries: inout Int,
        processedBytes: inout UInt64,
        processedBytesByVolume: inout [String: UInt64],
        mountedVolumes: [VolumeInfo],
        progress: StorageScanProgressAccumulator,
        workID: String,
        currentWork: String,
        currentWorkIndex: Int,
        totalWorkCount: Int
    ) throws {
        // Resolve only the configured source root. Package managers and AI tools
        // commonly relocate their data to another volume through a root symlink.
        // Descendant symlinks remain ordinary measured entries and are not followed.
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let measuredVolumeID = VolumePathResolver.bestMatch(
            for: rootURL.path,
            in: mountedVolumes
        )?.id
        let rootKind = try measureEntry(
            at: rootURL,
            relativePath: "",
            root: root,
            measuredRootPath: rootURL.path,
            into: &ledger,
            processedEntries: &processedEntries,
            processedBytes: &processedBytes,
            processedBytesByVolume: &processedBytesByVolume,
            volumeID: measuredVolumeID
        )
        guard rootKind == .directory else { return }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return true
            }
        ) else {
            if let enumerationError { throw enumerationError }
            return
        }

        while let url = enumerator.nextObject() as? URL {
            if processedEntries.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let relativePath = relativePath(from: rootURL, to: url)
            if excludedDescendantPaths.contains(relativePath) {
                enumerator.skipDescendants()
                continue
            }
            let entryKind = try measureEntry(
                at: url,
                relativePath: relativePath,
                root: root,
                measuredRootPath: rootURL.path,
                into: &ledger,
                processedEntries: &processedEntries,
                processedBytes: &processedBytes,
                processedBytesByVolume: &processedBytesByVolume,
                volumeID: measuredVolumeID
            )
            if entryKind == .symbolicLink {
                enumerator.skipDescendants()
            }
            if processedEntries.isMultiple(of: 512) {
                progress.sourceProgress(
                    root.sourceID,
                    workID: workID,
                    processedEntryCount: processedEntries,
                    processedBytes: processedBytes,
                    sourceVolumeBytes: processedBytesByVolume,
                    currentWork: currentWork,
                    currentWorkIndex: currentWorkIndex,
                    totalWorkCount: totalWorkCount
                )
            }
        }
        if let enumerationError { throw enumerationError }
        progress.sourceProgress(
            root.sourceID,
            workID: workID,
            processedEntryCount: processedEntries,
            processedBytes: processedBytes,
            sourceVolumeBytes: processedBytesByVolume,
            currentWork: currentWork,
            currentWorkIndex: currentWorkIndex,
            totalWorkCount: totalWorkCount
        )
    }

    private nonisolated static func measureEntry(
        at url: URL,
        relativePath: String,
        root: StorageSourceRoot,
        measuredRootPath: String,
        into ledger: inout [StoragePhysicalIdentity: StorageLedgerEntry],
        processedEntries: inout Int,
        processedBytes: inout UInt64,
        processedBytesByVolume: inout [String: UInt64],
        volumeID: String?
    ) throws -> StorageMeasuredEntryKind {
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = before.st_mode & S_IFMT
        let measuredKind: StorageMeasuredEntryKind
        switch kind {
        case S_IFDIR: measuredKind = .directory
        case S_IFLNK: measuredKind = .symbolicLink
        default: measuredKind = .other
        }
        let allocated = UInt64(max(0, before.st_blocks)).multipliedClamped(by: 512)
        let logical = UInt64(max(0, before.st_size))
        let classification = StoragePathClassifier.classify(
            sourceID: root.sourceID,
            root: root,
            relativePath: relativePath
        )
        let identity = StoragePhysicalIdentity(
            device: UInt64(before.st_dev),
            inode: UInt64(before.st_ino)
        )
        let claim = StorageLedgerClaim(
            sourceID: root.sourceID,
            rootID: root.id,
            rootPath: measuredRootPath,
            simulatorObjectIdentifier: simulatorObjectIdentifier(
                sourceID: root.sourceID,
                rootID: root.id,
                relativePath: relativePath
            ),
            category: classification.category,
            risk: classification.risk,
            isProtected: classification.isProtected,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(before.st_mtimespec.tv_sec))
        )
        if var entry = ledger[identity] {
            entry.claims.append(claim)
            ledger[identity] = entry
        } else {
            ledger[identity] = StorageLedgerEntry(
                identity: identity,
                allocatedBytes: allocated,
                logicalBytes: logical,
                claims: [claim]
            )
            processedBytes = processedBytes.addingClamped(allocated)
            if let volumeID {
                processedBytesByVolume[volumeID, default: 0] =
                    processedBytesByVolume[volumeID, default: 0].addingClamped(allocated)
            }
        }
        processedEntries += 1
        return measuredKind
    }

    private nonisolated static func simulatorObjectIdentifier(
        sourceID: StorageSourceID,
        rootID: String,
        relativePath: String
    ) -> String? {
        guard sourceID == .simulators,
              rootID.hasSuffix(".devices") || rootID.contains("runtime") else {
            return nil
        }
        return relativePath.split(separator: "/").first.map(String.init)
    }

    private func reconcile(
        candidates: [StorageSourceCandidate],
        ledger: [StoragePhysicalIdentity: StorageLedgerEntry],
        skippedBySource: [StorageSourceID: Int],
        mountedVolumes: [VolumeInfo],
        providerInventories: [StorageSourceID: DockerStorageInventory]
    ) -> StorageAnalysisSnapshot {
        var aggregates: [StorageComponentKey: StorageComponentAccumulator] = [:]
        var simulatorObjects: [SimulatorObjectKey: StorageObjectAccumulator] = [:]
        var volumeUsage: [String: [StorageSourceID: UInt64]] = [:]
        var volumeIDByRootPath: [String: String] = [:]
        var rootPathsWithoutVolume = Set<String>()
        var conflictBytes: UInt64 = 0

        for entry in ledger.values {
            guard let claim = StorageClaimArbitrator.winner(for: entry.claims) else {
                conflictBytes = conflictBytes.addingClamped(entry.allocatedBytes)
                continue
            }
            let volumeID: String?
            if let cached = volumeIDByRootPath[claim.rootPath] {
                volumeID = cached
            } else if rootPathsWithoutVolume.contains(claim.rootPath) {
                volumeID = nil
            } else if let resolved = VolumePathResolver.bestMatch(
                for: claim.rootPath,
                in: mountedVolumes
            )?.id {
                volumeIDByRootPath[claim.rootPath] = resolved
                volumeID = resolved
            } else {
                rootPathsWithoutVolume.insert(claim.rootPath)
                volumeID = nil
            }
            if let volumeID {
                volumeUsage[volumeID, default: [:]][claim.sourceID, default: 0] =
                    volumeUsage[volumeID, default: [:]][claim.sourceID, default: 0]
                        .addingClamped(entry.allocatedBytes)
            }
            let key = StorageComponentKey(
                sourceID: claim.sourceID,
                rootID: claim.rootID,
                category: claim.category,
                risk: claim.risk,
                isProtected: claim.isProtected
            )
            var aggregate = aggregates[key] ?? StorageComponentAccumulator(
                rootDisplayName: candidates
                    .first(where: { $0.id == claim.sourceID })?
                    .roots.first(where: { $0.id == claim.rootID })?.displayName ?? claim.category
            )
            aggregate.allocatedBytes = aggregate.allocatedBytes.addingClamped(entry.allocatedBytes)
            aggregate.logicalBytes = aggregate.logicalBytes.addingClamped(entry.logicalBytes)
            aggregate.entryCount += 1
            if aggregate.newestModificationDate == nil
                || claim.modifiedAt > aggregate.newestModificationDate! {
                aggregate.newestModificationDate = claim.modifiedAt
            }
            aggregates[key] = aggregate

            if claim.sourceID == .simulators,
               claim.rootID.hasSuffix(".devices") || claim.rootID.contains("runtime"),
               let objectIdentifier = claim.simulatorObjectIdentifier {
                let objectKey = SimulatorObjectKey(
                    rootID: claim.rootID,
                    identifier: objectIdentifier
                )
                var object = simulatorObjects[objectKey] ?? StorageObjectAccumulator()
                object.allocatedBytes = object.allocatedBytes.addingClamped(entry.allocatedBytes)
                object.logicalBytes = object.logicalBytes.addingClamped(entry.logicalBytes)
                object.entryCount += 1
                object.risk = max(object.risk, claim.risk)
                object.isProtected = object.isProtected || claim.isProtected
                simulatorObjects[objectKey] = object
            }
        }

        let results = candidates.map { candidate in
            let componentPairs = aggregates
                .filter { $0.key.sourceID == candidate.id }
                .sorted { lhs, rhs in
                    if lhs.value.allocatedBytes != rhs.value.allocatedBytes {
                        return lhs.value.allocatedBytes > rhs.value.allocatedBytes
                    }
                    return lhs.key.category < rhs.key.category
                }
            let components = componentPairs.map { key, value in
                let root = candidate.roots.first { $0.id == key.rootID }
                return StorageComponent(
                    id: "\(key.sourceID.rawValue).\(key.rootID).\(key.category)",
                    title: key.category,
                    rootDisplayName: value.rootDisplayName,
                    rootID: key.rootID,
                    rootPath: root?.path,
                    allocatedBytes: value.allocatedBytes,
                    logicalBytes: value.logicalBytes,
                    entryCount: value.entryCount,
                    newestModificationDate: value.newestModificationDate,
                    risk: key.risk,
                    isProtected: key.isProtected
                )
            }
            let allocated = components.reduce(UInt64(0)) { $0.addingClamped($1.allocatedBytes) }
            let logical = components.reduce(UInt64(0)) { $0.addingClamped($1.logicalBytes) }
            let reclaimable = components
                .filter { !$0.isProtected && $0.risk == .rebuildableCache }
                .reduce(UInt64(0)) { $0.addingClamped($1.allocatedBytes) }
            let skipped = skippedBySource[candidate.id, default: 0]
            let inventory = providerInventories[candidate.id]
            let resourceTree = Self.completeResourceTree(
                sourceID: candidate.id,
                physicalNodes: Self.makeResourceTree(
                    candidate: candidate,
                    components: components,
                    simulatorObjects: simulatorObjects
                ),
                inventoryNodes: inventory?.nodes ?? []
            )
            return StorageSourceResult(
                descriptor: candidate.descriptor,
                availability: skipped == 0 ? candidate.availability : .permissionLimited,
                allocatedBytes: allocated,
                logicalBytes: logical,
                entryCount: components.reduce(0) { $0 + $1.entryCount },
                reclaimableCandidateBytes: reclaimable,
                components: components,
                resourceTree: resourceTree,
                inventoryDiagnostic: inventory?.diagnostic,
                skippedEntryCount: skipped,
                diagnostic: skipped == 0 ? candidate.diagnostic : "Some locations could not be read"
            )
        }
        let total = results.reduce(UInt64(0)) { $0.addingClamped($1.allocatedBytes) }
            .addingClamped(conflictBytes)
        let displayVolumes = Dictionary(
            grouping: mountedVolumes.filter { $0.totalCapacity > 0 },
            by: \.id
        )
        .values
        .compactMap { matches in
            matches.min { lhs, rhs in
                if lhs.mountPath == "/" { return true }
                if rhs.mountPath == "/" { return false }
                return lhs.mountPath.count < rhs.mountPath.count
            }
        }
        let volumes = displayVolumes
            .map { volume in
                StorageVolumeSnapshot(
                    id: volume.id,
                    name: volume.name,
                    mountPath: volume.mountPath,
                    totalCapacity: UInt64(max(0, volume.totalCapacity)),
                    availableCapacity: UInt64(max(0, volume.availableCapacity)),
                    sourceUsages: (volumeUsage[volume.id] ?? [:])
                        .map { StorageVolumeSourceUsage(sourceID: $0.key, allocatedBytes: $0.value) }
                        .sorted { lhs, rhs in
                            if lhs.allocatedBytes != rhs.allocatedBytes {
                                return lhs.allocatedBytes > rhs.allocatedBytes
                            }
                            return lhs.sourceID.rawValue < rhs.sourceID.rawValue
                        }
                )
            }
            .sorted { lhs, rhs in
                if lhs.mountPath == "/" { return true }
                if rhs.mountPath == "/" { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        return StorageAnalysisSnapshot(
            scannedAt: Date(),
            results: results,
            totalAllocatedBytes: total,
            conflictBytes: conflictBytes,
            measuredEntryCount: ledger.count,
            skippedEntryCount: skippedBySource.values.reduce(0, +),
            volumes: volumes
        )
    }

    private nonisolated static func completeResourceTree(
        sourceID: StorageSourceID,
        physicalNodes: [StorageResourceNode],
        inventoryNodes: [StorageResourceNode]
    ) -> [StorageResourceNode] {
        guard sourceID == .docker || sourceID == .podman else { return physicalNodes }
        let inventoryNodes = sourceID == .podman
            ? namespaceContainerInventory(inventoryNodes, sourceID: sourceID)
            : inventoryNodes
        let isPodman = sourceID == .podman
        let sourceTitle = isPodman ? "Podman" : "Docker"
        let physicalBytes = physicalNodes.reduce(UInt64.zero) {
            $0.addingClamped($1.allocatedBytes)
        }
        var nodes = [StorageResourceNode(
            id: "\(sourceID.rawValue).physical-storage",
            kind: .dockerStorage,
            title: sourceTitle,
            detail: isPodman
                ? "Podman machine、容器层与宿主机状态"
                : "Docker Desktop 虚拟磁盘、维护副本、日志与状态",
            titleLocalization: StorageLocalizedText(
                "%@ 宿主机物理存储",
                arguments: [sourceTitle]
            ),
            symbol: "internaldrive.fill",
            allocatedBytes: physicalBytes,
            logicalBytes: physicalNodes.reduce(UInt64.zero) {
                $0.addingClamped($1.logicalBytes)
            },
            entryCount: physicalNodes.reduce(0) { $0 + $1.entryCount },
            risk: .environmentOrRuntime,
            evidence: .fileSystemAllocated,
            isProtected: true,
            children: physicalNodes
        )]
        if !inventoryNodes.isEmpty {
            nodes.append(StorageResourceNode(
                id: "\(sourceID.rawValue).engine-objects",
                kind: .dockerStorage,
                title: sourceTitle,
                detail: "提供者报告的镜像、容器、Volume 与构建缓存；对象可能共享底层数据",
                titleLocalization: StorageLocalizedText(
                    "%@ Engine 资源",
                    arguments: [sourceTitle]
                ),
                symbol: "point.3.connected.trianglepath.dotted",
                allocatedBytes: 0,
                logicalBytes: 0,
                entryCount: inventoryNodes.reduce(0) { $0 + $1.entryCount },
                risk: .environmentOrRuntime,
                evidence: .providerReported,
                isProtected: true,
                children: inventoryNodes
            ))
        }
        return nodes
    }

    private nonisolated static func namespaceContainerInventory(
        _ nodes: [StorageResourceNode],
        sourceID: StorageSourceID
    ) -> [StorageResourceNode] {
        nodes.map { node in
            let target: StorageResourceCleanupTarget?
            switch node.cleanupTarget {
            case .dockerImage(let id) where sourceID == .podman:
                target = .podmanImage(id: id)
            case .dockerContainer(let id) where sourceID == .podman:
                target = .podmanContainer(id: id)
            case .dockerVolume(let name) where sourceID == .podman:
                target = .podmanVolume(name: name)
            default:
                target = node.cleanupTarget
            }
            return StorageResourceNode(
                id: sourceID == .podman ? node.id.replacingOccurrences(of: "docker.", with: "podman.") : node.id,
                kind: node.kind,
                title: node.title,
                detail: node.detail,
                titleLocalization: node.titleLocalization,
                detailLocalization: node.detailLocalization,
                symbol: node.symbol,
                allocatedBytes: node.allocatedBytes,
                logicalBytes: node.logicalBytes,
                entryCount: node.entryCount,
                risk: node.risk,
                evidence: node.evidence,
                isProtected: node.isProtected,
                cleanupTarget: target,
                children: namespaceContainerInventory(node.children, sourceID: sourceID)
            )
        }
    }

    private nonisolated static func makeResourceTree(
        candidate: StorageSourceCandidate,
        components: [StorageComponent],
        simulatorObjects: [SimulatorObjectKey: StorageObjectAccumulator]
    ) -> [StorageResourceNode] {
        if candidate.id == .simulators {
            return makeSimulatorResourceTree(
                candidate: candidate,
                components: components,
                objects: simulatorObjects
            )
        }
        let nodes = candidate.roots.compactMap {
            makeRootResourceNode(root: $0, components: components)
        }
        guard candidate.id == .workspace else { return nodes }
        return groupRepositoryNodes(nodes, roots: candidate.roots)
    }

    private nonisolated static func makeSimulatorResourceTree(
        candidate: StorageSourceCandidate,
        components: [StorageComponent],
        objects: [SimulatorObjectKey: StorageObjectAccumulator]
    ) -> [StorageResourceNode] {
        let rootsByID = Dictionary(uniqueKeysWithValues: candidate.roots.map { ($0.id, $0) })
        let deviceRootIDs = Set(candidate.roots.filter { $0.id.hasSuffix(".devices") }.map(\.id))
        let runtimeRootIDs = Set(candidate.roots.filter { $0.id.contains("runtime") }.map(\.id))

        let deviceNodes = objects.compactMap { key, value -> StorageResourceNode? in
            guard deviceRootIDs.contains(key.rootID),
                  let root = rootsByID[key.rootID],
                  let objectURL = simulatorObjectURL(root: root, identifier: key.identifier),
                  let metadata = SimulatorStorageMetadata.device(
                    at: objectURL,
                    identifier: key.identifier
                  ) else { return nil }
            return StorageResourceNode(
                id: "\(key.rootID).object.\(key.identifier)",
                kind: .location,
                title: metadata.title,
                detail: metadata.detail,
                symbol: "iphone.gen3",
                allocatedBytes: value.allocatedBytes,
                logicalBytes: value.logicalBytes,
                entryCount: value.entryCount,
                risk: value.risk,
                evidence: .fileSystemAllocated,
                isProtected: value.isProtected,
                cleanupTarget: .simulatorDevice(identifier: key.identifier)
            )
        }
        .sorted(by: resourceNodeSort)

        let runtimeNodes = objects.compactMap { key, value -> StorageResourceNode? in
            guard runtimeRootIDs.contains(key.rootID),
                  let root = rootsByID[key.rootID],
                  let objectURL = simulatorObjectURL(root: root, identifier: key.identifier),
                  let metadata = SimulatorStorageMetadata.runtime(
                    at: objectURL,
                    identifier: key.identifier
                  ) else { return nil }
            let cleanupTarget: StorageResourceCleanupTarget?
            if objectURL.pathExtension == "asset" {
                cleanupTarget = pathIdentity(objectURL.path).map {
                    .simulatorRuntimeAsset(path: objectURL.path, identity: $0)
                }
            } else {
                cleanupTarget = pathIdentity(objectURL.path).map {
                    .simulatorRuntime(
                        identifier: SimulatorStorageMetadata.runtimeIdentifier(
                            at: objectURL,
                            fallback: key.identifier
                        ),
                        path: objectURL.path,
                        identity: $0
                    )
                }
            }
            return StorageResourceNode(
                id: "\(key.rootID).object.\(key.identifier)",
                kind: .location,
                title: metadata.title,
                detail: simulatorRuntimeSourceDetail(rootID: key.rootID),
                symbol: "shippingbox.fill",
                allocatedBytes: value.allocatedBytes,
                logicalBytes: value.logicalBytes,
                entryCount: value.entryCount,
                risk: value.risk,
                evidence: .fileSystemAllocated,
                isProtected: value.isProtected,
                cleanupTarget: cleanupTarget
            )
        }
        .sorted(by: resourceNodeSort)

        var nodes: [StorageResourceNode] = []
        if let node = simulatorGroupNode(
            id: "simulators.devices",
            title: "模拟器设备",
            detail: "按具体设备名称与 Runtime 展示",
            symbol: "iphone.gen3",
            rootIDs: deviceRootIDs,
            components: components,
            children: deviceNodes
        ) {
            nodes.append(node)
        }
        if let node = simulatorGroupNode(
            id: "simulators.runtimes",
            title: "模拟器运行时",
            detail: "按已安装 Runtime 名称展示",
            symbol: "shippingbox.fill",
            rootIDs: runtimeRootIDs,
            components: components,
            children: runtimeNodes
        ) {
            nodes.append(node)
        }

        let aggregateRootIDs = deviceRootIDs.union(runtimeRootIDs)
        nodes.append(contentsOf: candidate.roots.compactMap { root in
            guard !aggregateRootIDs.contains(root.id) else { return nil }
            return makeRootResourceNode(root: root, components: components)
        })
        return nodes
    }

    private nonisolated static func simulatorObjectURL(
        root: StorageSourceRoot,
        identifier: String
    ) -> URL? {
        let url = URL(fileURLWithPath: root.path, isDirectory: true)
            .appending(path: identifier, directoryHint: .isDirectory)
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return url
    }

    private nonisolated static func simulatorGroupNode(
        id: String,
        title: String,
        detail: String,
        symbol: String,
        rootIDs: Set<String>,
        components: [StorageComponent],
        children: [StorageResourceNode]
    ) -> StorageResourceNode? {
        let matching = components.filter { component in
            component.rootID.map(rootIDs.contains) == true
        }
        guard !matching.isEmpty else { return nil }
        return StorageResourceNode(
            id: id,
            kind: .location,
            title: title,
            detail: detail,
            symbol: symbol,
            allocatedBytes: matching.reduce(UInt64.zero) { $0.addingClamped($1.allocatedBytes) },
            logicalBytes: matching.reduce(UInt64.zero) { $0.addingClamped($1.logicalBytes) },
            entryCount: matching.reduce(0) { $0 + $1.entryCount },
            risk: matching.map(\.risk).max() ?? .environmentOrRuntime,
            evidence: .fileSystemAllocated,
            isProtected: matching.contains(where: \.isProtected),
            children: children
        )
    }

    private nonisolated static func makeRootResourceNode(
        root: StorageSourceRoot,
        components: [StorageComponent]
    ) -> StorageResourceNode? {
        let rootComponents = components.filter { $0.rootID == root.id }
        guard !rootComponents.isEmpty else { return nil }
        let cleanupTarget = cleanupTarget(for: root, components: rootComponents)
        let children = rootComponents.map { component in
            StorageResourceNode(
                id: component.id,
                kind: .category,
                title: component.title,
                symbol: resourceSymbol(for: component.risk),
                allocatedBytes: component.allocatedBytes,
                logicalBytes: component.logicalBytes,
                entryCount: component.entryCount,
                risk: component.risk,
                evidence: component.evidence,
                isProtected: component.isProtected
            )
        }
        return StorageResourceNode(
            id: root.id,
            kind: resourceKind(for: root),
            title: root.displayName,
            detail: resourceDetail(for: root),
            symbol: resourceSymbol(for: root),
            allocatedBytes: rootComponents.reduce(UInt64.zero) {
                $0.addingClamped($1.allocatedBytes)
            },
            logicalBytes: rootComponents.reduce(UInt64.zero) {
                $0.addingClamped($1.logicalBytes)
            },
            entryCount: rootComponents.reduce(0) { $0 + $1.entryCount },
            risk: rootComponents.map(\.risk).max() ?? root.defaultRisk,
            evidence: .fileSystemAllocated,
            isProtected: rootComponents.contains(where: \.isProtected),
            cleanupTarget: cleanupTarget,
            children: children
        )
    }

    private nonisolated static func resourceNodeSort(
        _ lhs: StorageResourceNode,
        _ rhs: StorageResourceNode
    ) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes {
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private nonisolated static func simulatorRuntimeSourceDetail(rootID: String) -> String {
        if rootID.contains("downloaded-runtime") { return "系统下载资源" }
        if rootID.contains("legacy-system-runtime") { return "系统安装" }
        return "用户安装"
    }

    private nonisolated static func relativePath(from root: URL, to entry: URL) -> String {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if entry.path.hasPrefix(rootPrefix) {
            return String(entry.path.dropFirst(rootPrefix.count))
        }
        let rootComponents = root.pathComponents.filter { $0 != "/" }
        let entryComponents = entry.pathComponents.filter { $0 != "/" }
        if rootComponents.count <= entryComponents.count {
            for start in 0...(entryComponents.count - rootComponents.count) {
                let end = start + rootComponents.count
                if Array(entryComponents[start..<end]) == rootComponents {
                    return entryComponents.dropFirst(end).joined(separator: "/")
                }
            }
        }
        return entry.lastPathComponent
    }

    private nonisolated static func cleanupTarget(
        for root: StorageSourceRoot,
        components: [StorageComponent]
    ) -> StorageResourceCleanupTarget? {
        var linkValue = stat()
        guard lstat(root.path, &linkValue) == 0,
              (linkValue.st_mode & S_IFMT) != S_IFLNK else { return nil }
        guard let identity = pathIdentity(root.path) else { return nil }
        if let context = root.resourceContext {
            guard context.isCleanupAllowed else { return nil }
            switch context.kind {
            case .repository:
                return .trashRepository(path: root.path, identity: identity)
            case .worktree:
                guard let parentPath = context.parentPath else { return nil }
                return .removeGitWorktree(
                    path: root.path,
                    mainRepositoryPath: parentPath,
                    identity: identity
                )
            }
        }
        guard root.kind == .directory,
              components.allSatisfy({ !$0.isProtected && $0.risk == .rebuildableCache }) else {
            return nil
        }
        return .removePathContents(
            path: root.path,
            identity: identity,
            sourceID: root.sourceID,
            rootID: root.id
        )
    }

    private nonisolated static func pathIdentity(_ path: String) -> StoragePathIdentity? {
        let resolvedPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        var value = stat()
        guard stat(resolvedPath, &value) == 0 else { return nil }
        return StoragePathIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private nonisolated static func resourceKind(for root: StorageSourceRoot) -> StorageResourceKind {
        switch root.resourceContext?.kind {
        case .repository: .repository
        case .worktree: .worktree
        case nil: root.sourceID == .docker ? .dockerStorage : .location
        }
    }

    private nonisolated static func resourceDetail(for root: StorageSourceRoot) -> String {
        guard let context = root.resourceContext else { return root.path }
        let relationship = context.kind == .worktree ? "worktree" : "主仓库"
        if let branch = context.branch, !branch.isEmpty {
            return "\(relationship) · \(branch) · \(root.path)"
        }
        return "\(relationship) · \(root.path)"
    }

    private nonisolated static func resourceSymbol(for root: StorageSourceRoot) -> String {
        switch root.resourceContext?.kind {
        case .repository: return "folder.badge.gearshape"
        case .worktree: return "arrow.triangle.branch"
        case nil:
            if root.kind == .file { return "doc.zipper" }
            return "folder"
        }
    }

    private nonisolated static func resourceSymbol(for risk: StorageRiskLevel) -> String {
        switch risk {
        case .rebuildableCache: "arrow.triangle.2.circlepath"
        case .sharedOrExpensive: "shippingbox"
        case .environmentOrRuntime: "gearshape.2"
        case .protectedUserData: "lock.shield"
        }
    }

    private nonisolated static func groupRepositoryNodes(
        _ nodes: [StorageResourceNode],
        roots: [StorageSourceRoot]
    ) -> [StorageResourceNode] {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: nodes) { node in
            rootsByID[node.id]?.resourceContext?.groupID ?? node.id
        }
        let repositories = grouped.values.compactMap { group -> StorageResourceNode? in
            guard let main = group.first(where: { $0.kind == .repository }) else {
                return group.first
            }
            let worktrees = group
                .filter { $0.kind == .worktree }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            guard !worktrees.isEmpty else { return main }
            return StorageResourceNode(
                id: main.id,
                kind: main.kind,
                title: main.title,
                detail: main.detail,
                symbol: main.symbol,
                allocatedBytes: main.allocatedBytes.addingClamped(
                    worktrees.reduce(UInt64.zero) { $0.addingClamped($1.allocatedBytes) }
                ),
                logicalBytes: main.logicalBytes.addingClamped(
                    worktrees.reduce(UInt64.zero) { $0.addingClamped($1.logicalBytes) }
                ),
                entryCount: main.entryCount + worktrees.reduce(0) { $0 + $1.entryCount },
                risk: main.risk,
                evidence: .fileSystemAllocated,
                isProtected: main.isProtected,
                cleanupTarget: main.cleanupTarget,
                children: main.children + worktrees
            )
        }

        var parentGroups: [String: [StorageResourceNode]] = [:]
        var standalone: [StorageResourceNode] = []
        for node in repositories {
            guard node.kind == .repository,
                  let root = rootsByID[node.id],
                  root.resourceContext?.kind == .repository else {
                standalone.append(node)
                continue
            }
            let parentPath = URL(fileURLWithPath: root.path)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            parentGroups[parentPath, default: []].append(node)
        }

        var result = standalone
        for (parentPath, children) in parentGroups {
            guard children.count > 1 else {
                result.append(contentsOf: children)
                continue
            }
            let sortedChildren = children.sorted(by: resourceNodeSort)
            result.append(StorageResourceNode(
                id: "workspace.parent.\(stablePathHash(parentPath))",
                kind: .location,
                title: URL(fileURLWithPath: parentPath).lastPathComponent,
                detailLocalization: [StorageLocalizedText(
                    "上级目录 · %@",
                    arguments: [parentPath]
                )],
                symbol: "folder.fill",
                allocatedBytes: sortedChildren.reduce(UInt64.zero) {
                    $0.addingClamped($1.allocatedBytes)
                },
                logicalBytes: sortedChildren.reduce(UInt64.zero) {
                    $0.addingClamped($1.logicalBytes)
                },
                entryCount: sortedChildren.reduce(0) { $0 + $1.entryCount },
                risk: .environmentOrRuntime,
                evidence: .fileSystemAllocated,
                isProtected: false,
                children: sortedChildren
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private nonisolated static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    nonisolated private static func collectMountedVolumes() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey, .volumeIdentifierKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.volumeIsLocal == true, values?.volumeIsReadOnly == false else { return nil }
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            let identifier = values?.volumeUUIDString
                ?? values?.volumeIdentifier.map { String(describing: $0) }
                ?? "mount:\(url.standardizedFileURL.path)"
            let fallbackName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return VolumeInfo(
                id: identifier,
                name: values?.volumeName ?? fallbackName,
                mountPath: url.standardizedFileURL.path,
                totalCapacity: total,
                availableCapacity: Int64(values?.volumeAvailableCapacity ?? 0),
                isLocal: true,
                isWritable: true,
                hasStableIdentity: values?.volumeUUIDString != nil || values?.volumeIdentifier != nil,
                isRemovable: false,
                physicalDiskBSDNames: []
            )
        }
    }

    private func merge(
        outputs: [StorageSourceScanOutput],
        orderedBy candidates: [StorageSourceCandidate]
    ) -> StorageMergedScanOutput {
        let bySource = Dictionary(uniqueKeysWithValues: outputs.map { ($0.sourceID, $0) })
        var ledger: [StoragePhysicalIdentity: StorageLedgerEntry] = [:]
        var skippedBySource: [StorageSourceID: Int] = [:]
        var processedEntries = 0
        var processedBytes: UInt64 = 0

        for candidate in candidates {
            guard let output = bySource[candidate.id] else { continue }
            skippedBySource[candidate.id] = output.skippedRootCount
            processedEntries += output.processedEntryCount
            processedBytes = processedBytes.addingClamped(output.processedBytes)
            for (identity, entry) in output.ledger {
                if var existing = ledger[identity] {
                    existing.claims.append(contentsOf: entry.claims)
                    ledger[identity] = existing
                } else {
                    ledger[identity] = entry
                }
            }
        }
        return StorageMergedScanOutput(
            ledger: ledger,
            skippedBySource: skippedBySource,
            processedEntryCount: processedEntries,
            processedBytes: processedBytes
        )
    }
}

private struct StorageSourceScanOutput: Sendable {
    let sourceID: StorageSourceID
    let ledger: [StoragePhysicalIdentity: StorageLedgerEntry]
    let skippedRootCount: Int
    let processedEntryCount: Int
    let processedBytes: UInt64
}

private struct StorageRootScanOutput: Sendable {
    let rootOffset: Int
    let volumeID: String?
    let ledger: [StoragePhysicalIdentity: StorageLedgerEntry]
    let skippedRootCount: Int
    let processedEntryCount: Int
}

private struct StorageMergedScanOutput {
    let ledger: [StoragePhysicalIdentity: StorageLedgerEntry]
    let skippedBySource: [StorageSourceID: Int]
    let processedEntryCount: Int
    let processedBytes: UInt64
}

private final class StorageScanProgressAccumulator: @unchecked Sendable {
    private let minimumEmissionInterval: Duration = .seconds(1)
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let totalSourceCount: Int
    private let mountedVolumes: [VolumeInfo]
    private let progress: StorageAnalyzer.ProgressHandler?
    private struct WorkState {
        var entries: Int
        var bytes: UInt64
        var volumeBytes: [String: UInt64]
    }

    private struct SourceState {
        var entries: Int
        var bytes: UInt64
        var currentWork: String?
        var currentWorkIndex: Int?
        var totalWorkCount: Int?
        var completed: Bool
        var volumeBytes: [String: UInt64]
        var workStates: [String: WorkState]
    }

    private var latestBySource: [StorageSourceID: SourceState] = [:]
    private var completedSources = Set<StorageSourceID>()
    private var lastEmissionBySource: [StorageSourceID: ContinuousClock.Instant] = [:]

    init(
        totalSourceCount: Int,
        mountedVolumes: [VolumeInfo],
        progress: StorageAnalyzer.ProgressHandler?
    ) {
        self.totalSourceCount = totalSourceCount
        self.mountedVolumes = mountedVolumes
        self.progress = progress
    }

    func sourceStarted(_ sourceID: StorageSourceID, totalWorkCount: Int) {
        emit(
            sourceID: sourceID,
            workID: nil,
            entries: 0,
            bytes: 0,
            currentWork: nil,
            currentWorkIndex: nil,
            totalWorkCount: totalWorkCount,
            completed: false,
            volumeBytes: [:]
        )
    }

    func sourceProgress(
        _ sourceID: StorageSourceID,
        workID: String,
        processedEntryCount: Int,
        processedBytes: UInt64,
        sourceVolumeBytes: [String: UInt64],
        currentWork: String? = nil,
        currentWorkIndex: Int? = nil,
        totalWorkCount: Int? = nil
    ) {
        emit(
            sourceID: sourceID,
            workID: workID,
            entries: processedEntryCount,
            bytes: processedBytes,
            currentWork: currentWork,
            currentWorkIndex: currentWorkIndex,
            totalWorkCount: totalWorkCount,
            completed: false,
            volumeBytes: sourceVolumeBytes
        )
    }

    func sourceFinished(
        _ sourceID: StorageSourceID,
        processedEntryCount: Int,
        processedBytes: UInt64,
        sourceVolumeBytes: [String: UInt64]
    ) {
        emit(
            sourceID: sourceID,
            workID: nil,
            entries: processedEntryCount,
            bytes: processedBytes,
            currentWork: nil,
            currentWorkIndex: nil,
            totalWorkCount: nil,
            completed: true,
            volumeBytes: sourceVolumeBytes
        )
    }

    func currentVolumes() -> [StorageVolumeSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return makeVolumes()
    }

    private func emit(
        sourceID: StorageSourceID,
        workID: String?,
        entries: Int,
        bytes: UInt64,
        currentWork: String?,
        currentWorkIndex: Int?,
        totalWorkCount: Int?,
        completed: Bool,
        volumeBytes: [String: UInt64]
    ) {
        var update: StorageScanProgress?
        lock.lock()
        let previous = latestBySource[sourceID]
        if completed {
            latestBySource[sourceID] = SourceState(
                entries: entries,
                bytes: bytes,
                currentWork: previous?.currentWork,
                currentWorkIndex: previous?.currentWorkIndex,
                totalWorkCount: totalWorkCount ?? previous?.totalWorkCount,
                completed: true,
                volumeBytes: volumeBytes,
                workStates: previous?.workStates ?? [:]
            )
        } else if let workID {
            var workStates = previous?.workStates ?? [:]
            let previousWork = workStates[workID]
            let mergedWorkVolumes = volumeBytes.reduce(into: previousWork?.volumeBytes ?? [:]) {
                $0[$1.key] = max($0[$1.key, default: 0], $1.value)
            }
            workStates[workID] = WorkState(
                entries: max(previousWork?.entries ?? 0, entries),
                bytes: max(previousWork?.bytes ?? 0, bytes),
                volumeBytes: mergedWorkVolumes
            )
            let aggregate = workStates.values.reduce(
                into: (entries: 0, bytes: UInt64(0), volumes: [String: UInt64]())
            ) { result, work in
                result.entries += work.entries
                result.bytes = result.bytes.addingClamped(work.bytes)
                for (volumeID, volumeBytes) in work.volumeBytes {
                    result.volumes[volumeID, default: 0] =
                        result.volumes[volumeID, default: 0].addingClamped(volumeBytes)
                }
            }
            latestBySource[sourceID] = SourceState(
                entries: aggregate.entries,
                bytes: aggregate.bytes,
                currentWork: currentWork ?? previous?.currentWork,
                currentWorkIndex: currentWorkIndex ?? previous?.currentWorkIndex,
                totalWorkCount: totalWorkCount ?? previous?.totalWorkCount,
                completed: previous?.completed == true,
                volumeBytes: aggregate.volumes,
                workStates: workStates
            )
        } else {
            latestBySource[sourceID] = SourceState(
                entries: max(previous?.entries ?? 0, entries),
                bytes: max(previous?.bytes ?? 0, bytes),
                currentWork: currentWork ?? previous?.currentWork,
                currentWorkIndex: currentWorkIndex ?? previous?.currentWorkIndex,
                totalWorkCount: totalWorkCount ?? previous?.totalWorkCount,
                completed: previous?.completed == true,
                volumeBytes: volumeBytes,
                workStates: previous?.workStates ?? [:]
            )
        }
        if completed { completedSources.insert(sourceID) }
        let now = clock.now
        let intervalElapsed = lastEmissionBySource[sourceID].map {
            $0.duration(to: now) >= minimumEmissionInterval
        } ?? true
        if completed || intervalElapsed {
            lastEmissionBySource[sourceID] = now
            let totals = latestBySource.values.reduce(
                into: (entries: 0, bytes: UInt64(0))
            ) { result, value in
                result.entries += value.entries
                result.bytes = result.bytes.addingClamped(value.bytes)
            }
            update = StorageScanProgress(
                phase: .measuring,
                sourceID: sourceID,
                completedSourceCount: completedSources.count,
                totalSourceCount: totalSourceCount,
                processedEntryCount: totals.entries,
                processedBytes: totals.bytes,
                sourceProcessedEntryCount: latestBySource[sourceID]?.entries ?? entries,
                sourceProcessedBytes: latestBySource[sourceID]?.bytes ?? bytes,
                currentWork: latestBySource[sourceID]?.currentWork,
                currentWorkIndex: latestBySource[sourceID]?.currentWorkIndex,
                totalWorkCount: latestBySource[sourceID]?.totalWorkCount,
                sourceCompleted: latestBySource[sourceID]?.completed == true,
                volumes: makeVolumes()
            )
        }
        lock.unlock()
        if let update { progress?(update) }
    }

    private func makeVolumes() -> [StorageVolumeSnapshot] {
        let sourceUsagesByVolume = latestBySource.reduce(
            into: [String: [StorageVolumeSourceUsage]]()
        ) { result, source in
            for (volumeID, bytes) in source.value.volumeBytes where bytes > 0 {
                result[volumeID, default: []].append(StorageVolumeSourceUsage(
                    sourceID: source.key,
                    allocatedBytes: bytes
                ))
            }
        }
        return Dictionary(
            grouping: mountedVolumes.filter { $0.totalCapacity > 0 },
            by: \.id
        )
        .values
        .compactMap { matches in
            matches.min { lhs, rhs in
                if lhs.mountPath == "/" { return true }
                if rhs.mountPath == "/" { return false }
                return lhs.mountPath.count < rhs.mountPath.count
            }
        }
        .map { volume in
            StorageVolumeSnapshot(
                id: volume.id,
                name: volume.name,
                mountPath: volume.mountPath,
                totalCapacity: UInt64(max(0, volume.totalCapacity)),
                availableCapacity: UInt64(max(0, volume.availableCapacity)),
                sourceUsages: (sourceUsagesByVolume[volume.id] ?? []).sorted {
                    if $0.allocatedBytes != $1.allocatedBytes {
                        return $0.allocatedBytes > $1.allocatedBytes
                    }
                    return $0.sourceID.rawValue < $1.sourceID.rawValue
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private struct StoragePhysicalIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private enum StorageMeasuredEntryKind: Sendable {
    case directory
    case symbolicLink
    case other
}

private struct StorageLedgerClaim: Sendable {
    let sourceID: StorageSourceID
    let rootID: String
    let rootPath: String
    let simulatorObjectIdentifier: String?
    let category: String
    let risk: StorageRiskLevel
    let isProtected: Bool
    let modifiedAt: Date
}

private struct StorageLedgerEntry: Sendable {
    let identity: StoragePhysicalIdentity
    let allocatedBytes: UInt64
    let logicalBytes: UInt64
    var claims: [StorageLedgerClaim]
}

private enum StorageClaimArbitrator {
    static func winner(for claims: [StorageLedgerClaim]) -> StorageLedgerClaim? {
        let sourceIDs = Set(claims.map(\.sourceID))
        guard sourceIDs.count > 1 else { return claims.first }
        let nonWorkspace = claims.filter { $0.sourceID != .workspace }
        if Set(nonWorkspace.map(\.sourceID)).count == 1 { return nonWorkspace.first }
        let simulatorClaims = claims.filter { $0.sourceID == .simulators }
        if !simulatorClaims.isEmpty,
           claims.allSatisfy({ $0.sourceID == .simulators || $0.sourceID == .xcode }) {
            return simulatorClaims.first
        }
        let dockerVirtualDisk = claims.first { $0.sourceID == .docker && $0.rootID.hasSuffix(".raw") }
        if let dockerVirtualDisk { return dockerVirtualDisk }
        return nil
    }
}

private struct StorageComponentKey: Hashable {
    let sourceID: StorageSourceID
    let rootID: String
    let category: String
    let risk: StorageRiskLevel
    let isProtected: Bool
}

private struct StorageComponentAccumulator {
    let rootDisplayName: String
    var allocatedBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var entryCount = 0
    var newestModificationDate: Date?
}

private struct SimulatorObjectKey: Hashable {
    let rootID: String
    let identifier: String
}

private struct StorageObjectAccumulator {
    var allocatedBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var entryCount = 0
    var risk: StorageRiskLevel = .rebuildableCache
    var isProtected = false
}

private struct StoragePathClassification {
    let category: String
    let risk: StorageRiskLevel
    let isProtected: Bool
}

private enum StoragePathClassifier {
    static func classify(
        sourceID: StorageSourceID,
        root: StorageSourceRoot,
        relativePath: String
    ) -> StoragePathClassification {
        let lower = relativePath.lowercased()
        let components = lower.split(separator: "/").map(String.init)
        let first = components.first ?? ""
        switch sourceID {
        case .chrome:
            if components.contains("code cache") { return .init(category: "代码缓存", risk: .rebuildableCache, isProtected: false) }
            if components.contains(where: { $0.contains("gpu") || $0.contains("shader") }) {
                return .init(category: "GPU 与着色器缓存", risk: .rebuildableCache, isProtected: false)
            }
            if components.contains("service worker") || components.contains("indexeddb") {
                return .init(category: "站点离线数据", risk: .sharedOrExpensive, isProtected: true)
            }
            if components.contains(where: { $0.contains("crash") }) {
                return .init(category: "崩溃报告", risk: .rebuildableCache, isProtected: false)
            }
            if components.contains(where: { $0 == "extensions" || $0 == "extension state" || $0 == "extension rules" }) {
                return .init(category: "扩展", risk: .protectedUserData, isProtected: true)
            }
            if components.contains(where: {
                $0 == "history" || $0 == "cookies" || $0 == "login data"
                    || $0 == "local storage" || $0 == "sessions" || $0 == "bookmarks"
            }) {
                return .init(category: "受保护浏览器数据", risk: .protectedUserData, isProtected: true)
            }
            if components.contains("cache") || root.id.hasSuffix(".cache") {
                return .init(category: "浏览器缓存", risk: .rebuildableCache, isProtected: false)
            }
            if first == "default" || first.hasPrefix("profile " ) {
                return .init(category: "浏览器档案数据", risk: .protectedUserData, isProtected: true)
            }
        case .go:
            if root.id.hasSuffix(".build-cache") {
                return .init(category: "构建缓存", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.hasSuffix(".module-download-cache") {
                return .init(category: "模块下载缓存", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.hasSuffix(".installed-tools") {
                return .init(category: "已安装工具", risk: .environmentOrRuntime, isProtected: true)
            }
            if lower == "cache/download"
                || lower.hasPrefix("cache/download/")
                || lower.contains("/cache/download/") {
                return .init(category: "模块下载缓存", risk: .rebuildableCache, isProtected: false)
            }
            return .init(category: "已解压模块", risk: .sharedOrExpensive, isProtected: false)
        case .npm:
            if first == "_cacache" { return .init(category: "内容寻址缓存", risk: .rebuildableCache, isProtected: false) }
            if first == "_npx" { return .init(category: "npx 临时安装", risk: .rebuildableCache, isProtected: false) }
            if first == "_logs" { return .init(category: "调试日志", risk: .rebuildableCache, isProtected: false) }
        case .pnpm:
            if components.contains("files") { return .init(category: "共享包内容", risk: .sharedOrExpensive, isProtected: false) }
            if components.contains("index") { return .init(category: "包索引元数据", risk: .rebuildableCache, isProtected: false) }
        case .bun:
            if root.id.hasSuffix(".global") { return .init(category: "全局包", risk: .environmentOrRuntime, isProtected: true) }
            if components.contains(where: { $0.hasSuffix(".npm") }) { return .init(category: "缓存包", risk: .rebuildableCache, isProtected: false) }
        case .pip:
            if first == "http" || first == "http-v2" { return .init(category: "HTTP 下载缓存", risk: .rebuildableCache, isProtected: false) }
            if first == "wheels" { return .init(category: "已构建 Wheel 缓存", risk: .rebuildableCache, isProtected: false) }
            if first == "selfcheck" { return .init(category: "索引检查元数据", risk: .rebuildableCache, isProtected: false) }
        case .xcode:
            if lower.contains("sourcepackages") { return .init(category: "源码包检出", risk: .sharedOrExpensive, isProtected: false) }
            if lower.contains("index.noindex") { return .init(category: "构建索引", risk: .rebuildableCache, isProtected: false) }
            if lower.contains("build/intermediates.noindex") { return .init(category: "构建中间产物", risk: .rebuildableCache, isProtected: false) }
            if lower.contains("build/products") { return .init(category: "构建产品", risk: .sharedOrExpensive, isProtected: false) }
            if root.id.contains("archives") { return .init(category: "归档", risk: .protectedUserData, isProtected: true) }
        case .vscode:
            if root.id.hasSuffix(".cached-extension-vsixs") {
                return .init(category: "扩展安装包缓存", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.hasSuffix(".logs") {
                return .init(category: "编辑器日志", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.hasSuffix(".crash-reports") {
                return .init(category: "崩溃报告", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.hasSuffix(".update-cache") {
                return .init(category: "更新缓存", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.contains("cache") || root.id.contains("cached-") {
                let category = root.id.contains("gpu") || root.id.contains("dawn")
                    ? "图形缓存"
                    : "编辑器缓存"
                return .init(category: category, risk: .rebuildableCache, isProtected: false)
            }
            if root.id.hasSuffix(".extensions-and-cli") {
                if first == "extensions" {
                    return .init(category: "已安装扩展", risk: .environmentOrRuntime, isProtected: true)
                }
                return .init(category: "编辑器 CLI 与配置", risk: .protectedUserData, isProtected: true)
            }
            if components.contains("workspacestorage") {
                return .init(category: "工作区状态", risk: .protectedUserData, isProtected: true)
            }
            if first == "backups" || components.contains("history") {
                return .init(category: "本地历史与未保存备份", risk: .protectedUserData, isProtected: true)
            }
            if first == "user" {
                return .init(category: "用户设置与扩展状态", risk: .protectedUserData, isProtected: true)
            }
            if ["service worker", "webstorage", "local storage", "session storage", "blob_storage"]
                .contains(first) {
                return .init(category: "扩展与 Web 状态", risk: .protectedUserData, isProtected: true)
            }
            return .init(category: "编辑器状态数据", risk: .protectedUserData, isProtected: true)
        case .simulators:
            if root.id.contains("runtime") || lower.contains("profiles/runtimes") {
                return .init(category: "模拟器运行时", risk: .environmentOrRuntime, isProtected: true)
            }
            if (root.id.hasSuffix(".devices") || lower.contains("devices"))
                && lower.contains("data/containers") {
                return .init(category: "模拟器应用数据", risk: .protectedUserData, isProtected: true)
            }
            if root.id.hasSuffix(".devices") || lower.contains("devices") {
                return .init(category: "模拟器设备", risk: .environmentOrRuntime, isProtected: true)
            }
            if root.id.hasSuffix(".pending-deletion") {
                return .init(category: "模拟器待删除数据", risk: .rebuildableCache, isProtected: false)
            }
            if root.id.contains("cache") || lower.contains("caches") {
                return .init(
                    category: "模拟器缓存",
                    risk: .rebuildableCache,
                    isProtected: root.isProtected
                )
            }
        case .docker:
            let fileName = components.last ?? ""
            if root.kind == .file || fileName == "docker.raw" || fileName == "docker.qcow2" {
                return .init(category: "Docker 虚拟磁盘", risk: .environmentOrRuntime, isProtected: true)
            }
            if fileName.hasPrefix("docker.raw.") || fileName.hasPrefix("docker.qcow2.") {
                return .init(category: "Docker 磁盘维护副本", risk: .protectedUserData, isProtected: true)
            }
            if components.contains("log") || components.contains("logs") { return .init(category: "容器日志", risk: .sharedOrExpensive, isProtected: true) }
            return .init(category: "Docker Desktop 状态", risk: .environmentOrRuntime, isProtected: true)
        case .podman:
            if root.id.hasSuffix(".machines") { return .init(category: "Podman 虚拟机", risk: .environmentOrRuntime, isProtected: true) }
            if components.contains("overlay") { return .init(category: "镜像与容器层", risk: .environmentOrRuntime, isProtected: true) }
            if components.contains("volumes") { return .init(category: "命名卷", risk: .protectedUserData, isProtected: true) }
        case .workspace:
            if lower.contains("node_modules") { return .init(category: "依赖目录", risk: .environmentOrRuntime, isProtected: true) }
            if lower.contains(".venv") || lower.contains("venv") { return .init(category: "Python 环境", risk: .environmentOrRuntime, isProtected: true) }
            if lower.contains(".next/cache") || lower.contains(".turbo") || lower.contains(".vite") {
                return .init(category: "框架缓存", risk: .sharedOrExpensive, isProtected: true)
            }
        default:
            break
        }
        return StoragePathClassification(
            category: root.defaultCategory,
            risk: root.defaultRisk,
            isProtected: root.isProtected
        )
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    func multipliedClamped(by other: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: other)
        return result.overflow ? .max : result.partialValue
    }
}
