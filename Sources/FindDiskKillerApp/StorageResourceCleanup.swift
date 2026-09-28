import Darwin
import FindDiskKillerCore
import Foundation

struct StorageCleanupRequest: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let displayBytes: UInt64
    let target: StorageResourceCleanupTarget

    var movesToTrash: Bool {
        switch target {
        case .removePathContents, .trashRepository, .simulatorRuntimeAsset: true
        default: false
        }
    }

    var actionDescription: String {
        switch target {
        case .removePathContents: L10n.text("可重建缓存 · 移入废纸篓后自动重建目录")
        case .dockerImage: L10n.text("Docker 镜像 · 通过 Docker 命令删除")
        case .podmanImage: L10n.text("Podman 镜像 · 通过 Podman 命令删除")
        default: L10n.text("通过官方工具清理")
        }
    }

    static func actionTitle(for requests: [Self]) -> String {
        requests.allSatisfy(\.movesToTrash) ? L10n.text("移到废纸篓") : L10n.text("清理所选项目")
    }
}

struct StorageCleanupOutcome: Identifiable, Sendable {
    let request: StorageCleanupRequest
    let errorDescription: String?
    var id: String { request.id }
    var succeeded: Bool { errorDescription == nil }
}

struct StorageCleanupSummary: Sendable {
    let outcomes: [StorageCleanupOutcome]
    var succeededCount: Int { outcomes.count(where: \.succeeded) }
    var failedCount: Int { outcomes.count - succeededCount }
}

struct StorageSafeCleanupGroup: Identifiable, Hashable, Sendable {
    let sourceID: StorageSourceID
    let title: String
    let family: StorageSourceFamily
    let symbol: String
    let requests: [StorageCleanupRequest]

    var id: StorageSourceID { sourceID }
    var totalBytes: UInt64 {
        requests.reduce(0) { partial, request in
            let sum = partial.addingReportingOverflow(request.displayBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}

struct StorageSafeCleanupIndex: Equatable, Sendable {
    let groups: [StorageSafeCleanupGroup]
    let groupsByFamily: [StorageSourceFamily: [StorageSafeCleanupGroup]]
    let requestIDsByGroup: [StorageSourceID: Set<String>]
    let requestIDsByFamily: [StorageSourceFamily: Set<String>]
    let allRequestIDs: Set<String>
    let requestsByID: [String: StorageCleanupRequest]
    let sourceIDByRequestID: [String: StorageSourceID]
    let requestOrder: [String]
    let totalBytes: UInt64

    static let empty = StorageSafeCleanupIndex(groups: [])

    init(groups: [StorageSafeCleanupGroup]) {
        self.groups = groups
        groupsByFamily = Dictionary(grouping: groups, by: \.family)

        var requestIDsByGroup: [StorageSourceID: Set<String>] = [:]
        var requestIDsByFamily: [StorageSourceFamily: Set<String>] = [:]
        var requestsByID: [String: StorageCleanupRequest] = [:]
        var sourceIDByRequestID: [String: StorageSourceID] = [:]
        var requestOrder: [String] = []

        for group in groups {
            let requestIDs = Set(group.requests.map(\.id))
            requestIDsByGroup[group.id] = requestIDs
            requestIDsByFamily[group.family, default: []].formUnion(requestIDs)
            for request in group.requests where requestsByID[request.id] == nil {
                requestsByID[request.id] = request
                sourceIDByRequestID[request.id] = group.id
                requestOrder.append(request.id)
            }
        }

        self.requestIDsByGroup = requestIDsByGroup
        self.requestIDsByFamily = requestIDsByFamily
        allRequestIDs = Set(requestsByID.keys)
        self.requestsByID = requestsByID
        self.sourceIDByRequestID = sourceIDByRequestID
        self.requestOrder = requestOrder
        totalBytes = StorageSafeCleanupProjection.totalBytes(in: groups)
    }

    init(snapshot: StorageAnalysisSnapshot?) {
        self.init(groups: StorageSafeCleanupProjection.groups(in: snapshot))
    }

    func groups(for family: StorageSourceFamily?) -> [StorageSafeCleanupGroup] {
        guard let family else { return groups }
        return groupsByFamily[family] ?? []
    }

    func requestIDs(for family: StorageSourceFamily?) -> Set<String> {
        guard let family else { return allRequestIDs }
        return requestIDsByFamily[family] ?? []
    }

    func selectedBytes(for selectedIDs: Set<String>) -> UInt64 {
        selectedIDs.reduce(0) { partial, requestID in
            guard let bytes = requestsByID[requestID]?.displayBytes else { return partial }
            let sum = partial.addingReportingOverflow(bytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    func selectedEntries(
        for selectedIDs: Set<String>
    ) -> [(StorageSourceID, StorageCleanupRequest)] {
        requestOrder.compactMap { requestID in
            guard selectedIDs.contains(requestID),
                  let sourceID = sourceIDByRequestID[requestID],
                  let request = requestsByID[requestID] else { return nil }
            return (sourceID, request)
        }
    }
}

enum StorageSafeCleanupProjection {
    static func groups(in snapshot: StorageAnalysisSnapshot?) -> [StorageSafeCleanupGroup] {
        guard let snapshot else { return [] }
        return snapshot.results.compactMap { result in
            let requests = safeRequests(in: result.resourceTree)
            guard !requests.isEmpty else { return nil }
            return StorageSafeCleanupGroup(
                sourceID: result.id,
                title: result.descriptor.title,
                family: result.descriptor.family,
                symbol: result.descriptor.symbol,
                requests: requests
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    static func safeRequests(in nodes: [StorageResourceNode]) -> [StorageCleanupRequest] {
        var requests: [StorageCleanupRequest] = []
        var seenIDs = Set<String>()

        func append(_ node: StorageResourceNode) {
            if let target = safeTarget(for: node),
               seenIDs.insert(node.id).inserted {
                requests.append(StorageCleanupRequest(
                    id: node.id,
                    title: node.title,
                    displayBytes: node.allocatedBytes,
                    target: target
                ))
                return
            }
            for child in node.children { append(child) }
        }

        for node in nodes { append(node) }
        return requests.sorted { lhs, rhs in
            if lhs.displayBytes != rhs.displayBytes { return lhs.displayBytes > rhs.displayBytes }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func safeTarget(
        for node: StorageResourceNode
    ) -> StorageResourceCleanupTarget? {
        guard node.risk == .rebuildableCache,
              !node.isProtected,
              let target = node.cleanupTarget else { return nil }
        switch target {
        case .removePathContents:
            return target
        case .dockerImage:
            return node.kind == .dockerImage ? target : nil
        case .podmanImage:
            return node.kind == .dockerImage ? target : nil
        case .trashRepository, .removeGitWorktree, .dockerContainer, .dockerVolume,
             .dockerBuildCachePrune, .goModuleCache, .podmanContainer, .podmanVolume:
            return nil
        case .simulatorDevice, .simulatorRuntime, .simulatorRuntimeAsset:
            return nil
        }
    }

    static func independentRequests(_ requests: [StorageCleanupRequest]) -> [StorageCleanupRequest] {
        func contentPath(_ target: StorageResourceCleanupTarget) -> String? {
            switch target {
            case .removePathContents(let path, _, _, _), .goModuleCache(let path, _): path
            default: nil
            }
        }
        return requests.filter { request in
            guard let path = contentPath(request.target) else { return true }
            return !requests.contains { other in
                guard other.id != request.id, let parent = contentPath(other.target) else { return false }
                return path != parent && VolumePathResolver.contains(path: path, in: parent)
            }
        }
    }

    static func totalBytes(in groups: [StorageSafeCleanupGroup]) -> UInt64 {
        groups.reduce(0) { partial, group in
            let sum = partial.addingReportingOverflow(group.totalBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}

actor StorageResourceCleanupExecutor {
    typealias DockerCommand = @Sendable ([String]) async throws -> String
    typealias PodmanCommand = @Sendable ([String]) async throws -> String
    typealias SimctlCommand = @Sendable ([String]) async throws -> String
    typealias GoCommand = @Sendable ([String]) async throws -> String

    private let fileManager: FileManager
    private let dockerCommand: DockerCommand?
    private let podmanCommand: PodmanCommand?
    private let simctlCommand: SimctlCommand?
    private let goCommand: GoCommand?

    init(
        fileManager: FileManager = .default,
        dockerCommand: DockerCommand? = nil,
        podmanCommand: PodmanCommand? = nil,
        simctlCommand: SimctlCommand? = nil,
        goCommand: GoCommand? = nil
    ) {
        self.fileManager = fileManager
        self.dockerCommand = dockerCommand
        self.podmanCommand = podmanCommand
        self.simctlCommand = simctlCommand
        self.goCommand = goCommand
    }

    func execute(_ requests: [StorageCleanupRequest]) async -> StorageCleanupSummary {
        // Linked worktrees must be removed before their main repositories can
        // be trashed, so a batch selection of both completes in one pass.
        // The main-repository guard refuses to trash while worktrees remain
        // registered. Ordering is otherwise stable.
        let ordered = requests.enumerated().sorted { lhs, rhs in
            let lhsPriority = Self.priority(of: lhs.element.target)
            let rhsPriority = Self.priority(of: rhs.element.target)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var outcomes: [StorageCleanupOutcome] = []
        outcomes.reserveCapacity(ordered.count)
        for request in ordered {
            do {
                try Task.checkCancellation()
                try await execute(request.target)
                outcomes.append(StorageCleanupOutcome(request: request, errorDescription: nil))
            } catch {
                outcomes.append(StorageCleanupOutcome(
                    request: request,
                    errorDescription: L10n.errorDescription(error)
                ))
            }
        }
        return StorageCleanupSummary(outcomes: outcomes)
    }

    private static func priority(of target: StorageResourceCleanupTarget) -> Int {
        switch target {
        case .removeGitWorktree: 0
        case .trashRepository: 1
        default: 2
        }
    }

    private func execute(_ target: StorageResourceCleanupTarget) async throws {
        switch target {
        case .removePathContents(let path, let identity, let sourceID, let rootID):
            guard try validateIdentityIfPresent(path: path, expected: identity) else { return }
            let candidates = StorageSourceCatalog.detect(configuration: .init(
                repositorySearchRoots: [],
                providerInventoryEnabled: false
            ))
            let isCurrentCatalogRoot = candidates.first(where: { $0.id == sourceID })?
                .roots.contains(where: { $0.id == rootID && samePhysicalPath($0.path, path) }) == true
            guard isCurrentCatalogRoot || isVerifiedCustomCodexCacheRoot(
                path: path,
                sourceID: sourceID,
                rootID: rootID
            ) else {
                throw StorageCleanupError.sourceChanged
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        case .trashRepository(let path, let identity):
            guard try validateIdentityIfPresent(path: path, expected: identity) else { return }
            guard fileManager.fileExists(atPath: URL(fileURLWithPath: path).appending(path: ".git").path),
                  !containsCurrentDirectory(path) else {
                throw StorageCleanupError.protectedRepository
            }
            let worktreeList = try await run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "worktree", "list", "--porcelain"]
            )
            let linkedWorktrees = worktreeList
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    let value = String(line)
                    guard value.hasPrefix("worktree ") else { return nil }
                    return String(value.dropFirst("worktree ".count))
                }
                .filter { !samePhysicalPath($0, path) }
            guard linkedWorktrees.isEmpty else {
                throw StorageCleanupError.repositoryHasWorktrees
            }
            var trashedURL: NSURL?
            try fileManager.trashItem(
                at: URL(fileURLWithPath: path, isDirectory: true),
                resultingItemURL: &trashedURL
            )
        case .removeGitWorktree(let path, let mainRepositoryPath, let identity):
            guard try validateIdentityIfPresent(path: path, expected: identity) else { return }
            guard !containsCurrentDirectory(path) else {
                throw StorageCleanupError.protectedRepository
            }
            // Confirm the path is still a worktree registered by the recorded
            // main repository before touching anything. If the main repository
            // is gone or moved, the registration metadata cannot be cleaned
            // through git and the directory must not be deleted on our own.
            let worktreeList: String
            do {
                worktreeList = try await run(
                    executable: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["-C", mainRepositoryPath, "worktree", "list", "--porcelain"]
                )
            } catch {
                throw StorageCleanupError.mainRepositoryUnavailable
            }
            let registeredWorktrees = worktreeList
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    let value = String(line)
                    guard value.hasPrefix("worktree ") else { return nil }
                    return String(value.dropFirst("worktree ".count))
                }
            guard registeredWorktrees.contains(where: { samePhysicalPath($0, path) }) else {
                throw StorageCleanupError.worktreeNotRegistered
            }
            // Never force-remove: refuse when the worktree contains
            // uncommitted changes or untracked files. Those files belong to
            // the user and a worktree shares no working data with the main
            // checkout, so there is nothing safe to preserve them with.
            let status = try await run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "status", "--porcelain", "--untracked-files=normal"]
            )
            let changedEntries = status
                .split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !changedEntries.isEmpty {
                throw StorageCleanupError.worktreeHasChanges(changedEntries.count)
            }
            do {
                try await run(
                    executable: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["-C", mainRepositoryPath, "worktree", "remove", path]
                )
            } catch {
                let message = String(describing: error).lowercased()
                if message.contains("locked") {
                    throw StorageCleanupError.worktreeLocked
                }
                throw error
            }
        case .simulatorDevice(let identifier):
            do {
                try await runSimctl(arguments: ["delete", identifier])
            } catch {
                guard simulatorResourceIsAbsent(error) else { throw error }
            }
        case .simulatorRuntime(let identifier, let path, let identity):
            guard try validateIdentityIfPresent(path: path, expected: identity) else { return }
            do {
                try await runSimctl(arguments: ["runtime", "delete", identifier])
            } catch {
                guard simulatorResourceIsAbsent(error) else { throw error }
            }
        case .simulatorRuntimeAsset(let path, let identity):
            guard try validateIdentityIfPresent(path: path, expected: identity) else { return }
            var trashedURL: NSURL?
            try fileManager.trashItem(
                at: URL(fileURLWithPath: path, isDirectory: true),
                resultingItemURL: &trashedURL
            )
        case .dockerImage(let id):
            let referenceOutput: String
            do {
                referenceOutput = try await runDocker(arguments: [
                    "image", "inspect", id, "--format", "{{json .RepoTags}}"
                ])
            } catch {
                if dockerResourceIsAbsent(error) { return }
                throw error
            }
            let references = try await runDocker(arguments: [
                "container", "ls", "--all", "--quiet", "--filter", "ancestor=\(id)"
            ])
            guard references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StorageCleanupError.sourceChanged
            }
            let repositoryReferences = try parseDockerImageReferences(referenceOutput)
            if repositoryReferences.isEmpty {
                try await removeDockerImageReference(id)
            } else {
                for reference in repositoryReferences {
                    try await removeDockerImageReference(reference)
                }
            }
        case .dockerContainer(let id):
            do {
                try await runDocker(arguments: ["container", "rm", id])
            } catch {
                guard dockerResourceIsAbsent(error) else { throw error }
            }
        case .dockerVolume(let name):
            do {
                _ = try await runDocker(arguments: ["volume", "inspect", name])
            } catch {
                if dockerResourceIsAbsent(error) { return }
                throw error
            }
            let references = try await runDocker(arguments: [
                "container", "ls", "--all", "--quiet", "--filter", "volume=\(name)"
            ])
            guard references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StorageCleanupError.sourceChanged
            }
            try await runDocker(arguments: ["volume", "rm", name])
        case .dockerBuildCachePrune:
            // Official group-level operation: `docker builder prune` removes
            // only unused build cache entries. The CLI cannot address single
            // cache records, so this is deliberately a whole-group cleanup
            // that leaves in-use entries untouched (no --all).
            _ = try await runDocker(arguments: ["builder", "prune", "--force"])
        case .goModuleCache(let path, let identity):
            // `go clean -modcache` clears the whole module cache, so re-verify
            // the recorded path against the live `go env GOMODCACHE` before
            // running it. A mismatch means the cache moved or GOMODCACHE was
            // customized since analysis; refuse instead of deleting something
            // unexpected.
            guard try validateIdentityIfPresent(path: path, expected: identity) else { return }
            let reported = try await runGo(arguments: ["env", "GOMODCACHE"])
            let moduleCache = reported.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !moduleCache.isEmpty, samePhysicalPath(moduleCache, path) else {
                throw StorageCleanupError.sourceChanged
            }
            _ = try await runGo(arguments: ["clean", "-modcache"])
        case .podmanImage(let id):
            let referenceOutput: String
            do {
                referenceOutput = try await runPodman(arguments: [
                    "image", "inspect", id, "--format", "{{json .RepoTags}}"
                ])
            } catch {
                if podmanResourceIsAbsent(error) { return }
                throw error
            }
            let references = try await runPodman(arguments: [
                "container", "ls", "--all", "--quiet", "--filter", "ancestor=\(id)"
            ])
            guard references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StorageCleanupError.sourceChanged
            }
            let repositoryReferences = try parseDockerImageReferences(referenceOutput)
            if repositoryReferences.isEmpty {
                try await runPodman(arguments: ["image", "rm", id])
            } else {
                for reference in repositoryReferences {
                    try await runPodman(arguments: ["image", "rm", reference])
                }
            }
        case .podmanContainer(let id):
            do {
                try await runPodman(arguments: ["container", "rm", id])
            } catch {
                guard podmanResourceIsAbsent(error) else { throw error }
            }
        case .podmanVolume(let name):
            do {
                _ = try await runPodman(arguments: ["volume", "inspect", name])
            } catch {
                if podmanResourceIsAbsent(error) { return }
                throw error
            }
            let references = try await runPodman(arguments: [
                "container", "ls", "--all", "--quiet", "--filter", "volume=\(name)"
            ])
            guard references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StorageCleanupError.sourceChanged
            }
            try await runPodman(arguments: ["volume", "rm", name])
        }
    }

    private func isVerifiedCustomCodexCacheRoot(
        path: String,
        sourceID: StorageSourceID,
        rootID: String
    ) -> Bool {
        guard sourceID == .codex,
              rootID.hasPrefix("codex."),
              rootID.contains(".cache.") else { return false }
        let cacheURL = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard ["cache", "tmp", ".tmp"].contains(cacheURL.lastPathComponent) else {
            return false
        }
        return AgentDataLocationDiscovery.recognizedProvider(
            at: cacheURL.deletingLastPathComponent()
        ) == .codex
    }

    @discardableResult
    private func runDocker(arguments: [String]) async throws -> String {
        if let dockerCommand { return try await dockerCommand(arguments) }
        guard let executable = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ].first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw StorageCleanupError.toolUnavailable("Docker")
        }
        return try await run(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }

    @discardableResult
    private func runPodman(arguments: [String]) async throws -> String {
        if let podmanCommand { return try await podmanCommand(arguments) }
        guard let executable = [
            "/opt/homebrew/bin/podman",
            "/usr/local/bin/podman",
            "/Applications/Podman Desktop.app/Contents/Resources/bin/podman"
        ].first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw StorageCleanupError.toolUnavailable("Podman")
        }
        return try await run(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }

    @discardableResult
    private func runSimctl(arguments: [String]) async throws -> String {
        if let simctlCommand { return try await simctlCommand(arguments) }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw StorageCleanupError.toolUnavailable("Xcode Simulator")
        }
        return try await run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl"] + arguments
        )
    }

    @discardableResult
    private func runGo(arguments: [String]) async throws -> String {
        if let goCommand { return try await goCommand(arguments) }
        guard let executable = locateGoExecutable() else {
            throw StorageCleanupError.toolUnavailable("Go")
        }
        return try await run(executable: executable, arguments: arguments)
    }

    private func locateGoExecutable() -> URL? {
        let candidates = [
            "/usr/local/go/bin/go",
            "/opt/homebrew/bin/go",
            "/usr/local/bin/go",
            "/usr/bin/go"
        ]
        if let candidate = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: candidate)
        }
        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnvironment.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appending(path: "go")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func simulatorResourceIsAbsent(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("does not exist")
            || message.contains("not found")
            || message.contains("unknown device")
            || message.contains("unknown runtime")
    }

    @discardableResult
    private func run(executable: URL, arguments: [String]) async throws -> String {
        let status = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data.prefix(1_048_576), as: UTF8.self))
        }.value
        guard status.0 == 0 else {
            throw StorageCleanupError.commandFailed(
                status.1.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return status.1
    }

    private func validateIdentityIfPresent(
        path: String,
        expected: StoragePathIdentity
    ) throws -> Bool {
        var linkValue = stat()
        guard lstat(path, &linkValue) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw StorageCleanupError.sourceChanged
        }
        guard (linkValue.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageCleanupError.sourceChanged
        }
        var value = stat()
        guard stat(path, &value) == 0,
              UInt64(value.st_dev) == expected.device,
              UInt64(value.st_ino) == expected.inode else {
            throw StorageCleanupError.sourceChanged
        }
        return true
    }

    private func parseDockerImageReferences(_ output: String) throws -> [String] {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "null" else { return [] }
        guard let data = value.data(using: .utf8),
              let references = try? JSONDecoder().decode([String].self, from: data) else {
            throw StorageCleanupError.sourceChanged
        }
        return Set(references)
            .filter { !$0.isEmpty && $0 != "<none>:<none>" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func removeDockerImageReference(_ reference: String) async throws {
        do {
            try await runDocker(arguments: ["image", "rm", reference])
        } catch {
            guard dockerResourceIsAbsent(error) else { throw error }
        }
    }

    private func dockerResourceIsAbsent(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("no such image")
            || message.contains("no such volume")
            || message.contains("no such container")
            || message.contains("no such object")
            || message.contains("not found")
    }

    private func podmanResourceIsAbsent(_ error: Error) -> Bool {
        dockerResourceIsAbsent(error)
    }

    private func samePhysicalPath(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
        return left == right
    }

    private func containsCurrentDirectory(_ path: String) -> Bool {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return current == root || current.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

private enum StorageCleanupError: LocalizedError {
    case sourceChanged
    case protectedRepository
    case repositoryHasWorktrees
    case mainRepositoryUnavailable
    case worktreeNotRegistered
    case worktreeHasChanges(Int)
    case worktreeLocked
    case toolUnavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            L10n.text("资源自分析后已发生变化，请重新分析后再试。")
        case .protectedRepository:
            L10n.text("当前正在使用的代码仓库不能清理。")
        case .repositoryHasWorktrees:
            L10n.text("主仓库仍有关联的 Worktree，请先移除这些 Worktree 后再删除主仓库。")
        case .mainRepositoryUnavailable:
            L10n.text("主仓库已不可用或已移动，未执行任何删除。请重新分析后再试。")
        case .worktreeNotRegistered:
            L10n.text("此路径已不是该主仓库注册的 Worktree，未执行任何删除。请重新分析后再试。")
        case .worktreeHasChanges(let count):
            L10n.format("该 Worktree 含 %d 处未提交更改或未跟踪文件，已拒绝移除。请先在对应分支提交或丢弃这些更改。", count)        case .worktreeLocked:
            L10n.text("该 Worktree 已被 git 锁定，已拒绝移除。请先在主仓库中执行 git worktree unlock。")
        case .toolUnavailable(let tool):
            L10n.format("未找到 %@ 官方命令行工具。", tool)
        case .commandFailed(let detail):
            detail.isEmpty ? L10n.text("官方清理命令执行失败。") : detail
        }
    }
}
