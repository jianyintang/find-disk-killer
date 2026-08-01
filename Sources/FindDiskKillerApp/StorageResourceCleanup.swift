import Darwin
import FindDiskKillerCore
import Foundation

struct StorageCleanupRequest: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let displayBytes: UInt64
    let target: StorageResourceCleanupTarget
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

actor StorageResourceCleanupExecutor {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func execute(_ requests: [StorageCleanupRequest]) async -> StorageCleanupSummary {
        var outcomes: [StorageCleanupOutcome] = []
        outcomes.reserveCapacity(requests.count)
        for request in requests {
            do {
                try Task.checkCancellation()
                try await execute(request.target)
                outcomes.append(StorageCleanupOutcome(request: request, errorDescription: nil))
            } catch {
                outcomes.append(StorageCleanupOutcome(
                    request: request,
                    errorDescription: error.localizedDescription
                ))
            }
        }
        return StorageCleanupSummary(outcomes: outcomes)
    }

    private func execute(_ target: StorageResourceCleanupTarget) async throws {
        switch target {
        case .removePathContents(let path, let identity, let sourceID, let rootID):
            try validateIdentity(path: path, expected: identity)
            let candidates = StorageSourceCatalog.detect(configuration: .init(
                repositorySearchRoots: [],
                providerInventoryEnabled: false
            ))
            guard candidates.first(where: { $0.id == sourceID })?
                .roots.contains(where: { $0.id == rootID && samePhysicalPath($0.path, path) }) == true else {
                throw StorageCleanupError.sourceChanged
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        case .trashRepository(let path, let identity):
            try validateIdentity(path: path, expected: identity)
            guard fileManager.fileExists(atPath: URL(fileURLWithPath: path).appending(path: ".git").path),
                  !containsCurrentDirectory(path) else {
                throw StorageCleanupError.protectedRepository
            }
            var trashedURL: NSURL?
            try fileManager.trashItem(
                at: URL(fileURLWithPath: path, isDirectory: true),
                resultingItemURL: &trashedURL
            )
        case .removeGitWorktree(let path, let mainRepositoryPath, let identity):
            try validateIdentity(path: path, expected: identity)
            guard !containsCurrentDirectory(path) else {
                throw StorageCleanupError.protectedRepository
            }
            try await run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", mainRepositoryPath, "worktree", "remove", path]
            )
        case .dockerImage(let id):
            try await runDocker(arguments: ["image", "rm", id])
        case .dockerContainer(let id):
            try await runDocker(arguments: ["container", "rm", id])
        case .dockerVolume(let name):
            try await runDocker(arguments: ["volume", "rm", name])
        }
    }

    private func runDocker(arguments: [String]) async throws {
        guard let executable = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ].first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw StorageCleanupError.toolUnavailable("Docker")
        }
        try await run(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }

    private func run(executable: URL, arguments: [String]) async throws {
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
    }

    private func validateIdentity(path: String, expected: StoragePathIdentity) throws {
        var linkValue = stat()
        guard lstat(path, &linkValue) == 0,
              (linkValue.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageCleanupError.sourceChanged
        }
        var value = stat()
        guard stat(path, &value) == 0,
              UInt64(value.st_dev) == expected.device,
              UInt64(value.st_ino) == expected.inode else {
            throw StorageCleanupError.sourceChanged
        }
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
    case toolUnavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            L10n.text("资源自分析后已发生变化，请重新分析后再试。")
        case .protectedRepository:
            L10n.text("当前正在使用的代码仓库不能清理。")
        case .toolUnavailable(let tool):
            L10n.format("未找到 %@ 官方命令行工具。", tool)
        case .commandFailed(let detail):
            detail.isEmpty ? L10n.text("官方清理命令执行失败。") : detail
        }
    }
}
