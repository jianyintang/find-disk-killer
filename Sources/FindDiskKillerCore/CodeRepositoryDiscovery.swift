import Darwin
import Foundation

public struct CodeRepositoryLocation: Hashable, Sendable {
    public let path: String
    public let displayName: String
    public let context: StorageResourceContext

    public init(path: String, displayName: String, context: StorageResourceContext) {
        self.path = path
        self.displayName = displayName
        self.context = context
    }
}

public struct CodeRepositoryDiscovery {
    private let homeDirectory: URL
    private let searchRoots: [URL]?
    private let mountedVolumeURLs: [URL]?
    private let fileManager: FileManager

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchRoots: [URL]? = nil,
        mountedVolumeURLs: [URL]? = nil,
        includesPrivacyProtectedLocations: Bool = false,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.searchRoots = searchRoots
        self.mountedVolumeURLs = mountedVolumeURLs
        // Authorization is deliberately a hint, not a discovery gate. TCC access can
        // change while the app is running and external volumes are often readable
        // without Full Disk Access, so every root is attempted directly.
        _ = includesPrivacyProtectedLocations
        self.fileManager = fileManager
    }

    public func discover() -> [CodeRepositoryLocation] {
        let roots = discoveryRoots()
        var repositories: [CodeRepositoryLocation] = []
        var seenPaths = Set<String>()
        for root in roots {
            guard !Task.isCancelled else { break }
            for repository in repositoriesUsingDirectoryTraversal(at: root) {
                if seenPaths.insert(repository.path).inserted {
                    repositories.append(repository)
                }
            }
        }
        return repositories.sorted { lhs, rhs in
            let groupOrder = lhs.context.groupID.localizedStandardCompare(rhs.context.groupID)
            if groupOrder != .orderedSame { return groupOrder == .orderedAscending }
            if lhs.context.kind != rhs.context.kind { return lhs.context.kind == .repository }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func discoveryRoots() -> [URL] {
        if let searchRoots {
            return deduplicatedDirectories(searchRoots)
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
        let mounted = mountedVolumeURLs ?? fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        let writableLocalRoots = mounted.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.volumeIsLocal == true && values.volumeIsReadOnly == false
        }
        let hasSystemRoot = writableLocalRoots.contains {
            $0.standardizedFileURL.path == "/"
        }
        return deduplicatedDirectories(
            (hasSystemRoot ? [] : [homeDirectory]) + writableLocalRoots
        )
    }

    private func deduplicatedDirectories(_ urls: [URL]) -> [URL] {
        var identities = Set<StoragePathIdentity>()
        return urls.compactMap { url in
            let standardized = url.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let identity = pathIdentity(standardized.path),
                  identities.insert(identity).inserted else { return nil }
            return standardized
        }
    }

    private func repository(at directory: URL) -> CodeRepositoryLocation? {
        let gitEntry = directory.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory),
              let identity = pathIdentity(directory.path) else { return nil }

        let kind: StorageResourceContext.Kind
        let commonDirectory: URL
        let parentPath: String?
        let branch: String?
        if isDirectory.boolValue {
            kind = .repository
            commonDirectory = gitEntry.resolvingSymlinksInPath().standardizedFileURL
            parentPath = nil
            branch = branchName(from: gitEntry.appending(path: "HEAD"))
        } else {
            guard let gitDirectory = parseGitDirectory(pointerFile: gitEntry) else { return nil }
            kind = .worktree
            commonDirectory = parseCommonDirectory(gitDirectory: gitDirectory)
            parentPath = repositoryPath(forCommonDirectory: commonDirectory)
            branch = branchName(from: gitDirectory.appending(path: "HEAD"))
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let cleanupAllowed = !containsPath(path, childPath: currentDirectory)
        return CodeRepositoryLocation(
            path: path,
            displayName: directory.lastPathComponent,
            context: StorageResourceContext(
                kind: kind,
                groupID: stablePathHash(commonDirectory.path),
                parentPath: parentPath,
                branch: branch,
                identity: identity,
                isCleanupAllowed: cleanupAllowed
            )
        )
    }

    private func parseGitDirectory(pointerFile: URL) -> URL? {
        guard let contents = try? String(contentsOf: pointerFile, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first,
              line.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return nil }
        let url = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : pointerFile.deletingLastPathComponent().appending(path: rawPath)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func parseCommonDirectory(gitDirectory: URL) -> URL {
        let file = gitDirectory.appending(path: "commondir")
        guard let raw = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return gitDirectory }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : gitDirectory.appending(path: raw)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func repositoryPath(forCommonDirectory commonDirectory: URL) -> String? {
        guard commonDirectory.lastPathComponent == ".git" else { return nil }
        return commonDirectory.deletingLastPathComponent().standardizedFileURL.path
    }

    private func branchName(from headFile: URL) -> String? {
        guard let contents = try? String(contentsOf: headFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !contents.isEmpty else { return nil }
        let prefix = "ref: refs/heads/"
        if contents.hasPrefix(prefix) { return String(contents.dropFirst(prefix.count)) }
        return String(contents.prefix(12))
    }

    private func shouldPrune(_ url: URL, root: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        if name == "mod", url.deletingLastPathComponent().lastPathComponent == "pkg" {
            return true
        }
        if Self.prunedNames.contains(name) { return true }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if parent == root.standardizedFileURL,
           Self.rootPrunedNames.contains(name) {
            return true
        }
        if parent == homeDirectory,
           Self.homePrunedNames.contains(name) {
            return true
        }
        if name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".xcarchive") {
            return true
        }
        return false
    }

    private func childDirectories(in directory: URL) -> [URL] {
        guard let stream = opendir(directory.path) else { return [] }
        defer { closedir(stream) }
        var directories: [URL] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            let child = directory.appending(path: name, directoryHint: .isDirectory)
            switch Int32(entry.pointee.d_type) {
            case DT_DIR:
                directories.append(child)
            case DT_UNKNOWN:
                var value = stat()
                if lstat(child.path, &value) == 0,
                   (value.st_mode & S_IFMT) == S_IFDIR {
                    directories.append(child)
                }
            default:
                continue
            }
        }
        return directories
    }

    private func repositoriesUsingDirectoryTraversal(
        at root: URL
    ) -> [CodeRepositoryLocation] {
        var accepted: [CodeRepositoryLocation] = []
        var pending = [root]
        while let directory = pending.popLast() {
            guard !Task.isCancelled else { break }
            if let repository = repository(at: directory) {
                accepted.append(repository)
                continue
            }
            if directory != root, shouldPrune(directory, root: root) { continue }
            let children = childDirectories(in: directory).sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedDescending
            }
            pending.append(contentsOf: children)
        }
        return accepted
    }

    private func pathIdentity(_ path: String) -> StoragePathIdentity? {
        var value = stat()
        guard stat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return StoragePathIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private func containsPath(_ parentPath: String, childPath: String) -> Bool {
        childPath == parentPath || childPath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }

    private func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static let prunedNames: Set<String> = [
        ".git", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".cache", ".npm", ".pnpm-store", ".bun", ".codex", ".codex-cc",
        ".claude",
        "node_modules", "Pods", "DerivedData", ".build", "build", "dist", "target", "vendor",
        "DockerDesktop"
    ]

    private static let rootPrunedNames: Set<String> = [
        "Applications", "Library", "System", "private", "usr", "bin", "sbin", "dev",
        "Volumes", "Network", "cores"
    ]

    private static let homePrunedNames: Set<String> = ["Applications", "Library"]
}
