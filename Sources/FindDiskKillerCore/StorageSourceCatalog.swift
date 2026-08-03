import Darwin
import Foundation

public enum StorageSourceCatalog {
    public static let descriptors: [StorageSourceDescriptor] = [
        .init(id: .chrome, title: "Chrome", family: .applications, symbol: "globe", cleanupCapability: .openOfficialManager),
        .init(id: .go, title: "Go", family: .developerTools, symbol: "shippingbox", cleanupCapability: .analysisOnly),
        .init(id: .npm, title: "npm", family: .developerTools, symbol: "shippingbox.fill", cleanupCapability: .analysisOnly),
        .init(id: .pnpm, title: "pnpm", family: .developerTools, symbol: "square.grid.3x3", cleanupCapability: .analysisOnly),
        .init(id: .bun, title: "Bun", family: .developerTools, symbol: "bolt", cleanupCapability: .analysisOnly),
        .init(id: .pip, title: "Python / pip", family: .developerTools, symbol: "chevron.left.forwardslash.chevron.right", cleanupCapability: .analysisOnly),
        .init(id: .xcode, title: "Xcode", family: .developerTools, symbol: "hammer", cleanupCapability: .analysisOnly),
        .init(id: .vscode, title: "VS Code", family: .developerTools, symbol: "chevron.left.forwardslash.chevron.right", cleanupCapability: .verifiedFiles),
        .init(id: .simulators, title: "Simulators", family: .developerTools, symbol: "iphone.gen3", cleanupCapability: .openOfficialManager),
        .init(id: .docker, title: "Docker Desktop", family: .containers, symbol: "shippingbox.and.arrow.backward", cleanupCapability: .analysisOnly),
        .init(id: .podman, title: "Podman", family: .containers, symbol: "cube.transparent", cleanupCapability: .analysisOnly),
        .init(id: .codex, title: "Codex", family: .aiTools, symbol: "terminal", cleanupCapability: .verifiedFiles),
        .init(id: .claude, title: "Claude", family: .aiTools, symbol: "sparkles", cleanupCapability: .verifiedFiles),
        .init(id: .openCode, title: "OpenCode", family: .aiTools, symbol: "curlybraces", cleanupCapability: .analysisOnly),
        .init(id: .workspace, title: "Git Workspaces", family: .workspaces, symbol: "folder.badge.gearshape", cleanupCapability: .analysisOnly)
    ]

    public static func descriptor(for id: StorageSourceID) -> StorageSourceDescriptor? {
        descriptors.first { $0.id == id }
    }

    public static func detect(
        configuration: StorageScanConfiguration,
        fileManager: FileManager = .default,
        progress: (@Sendable (StorageSourceCandidate) -> Void)? = nil
    ) -> [StorageSourceCandidate] {
        let home = configuration.homeDirectory.standardizedFileURL
        var definitions = rootDefinitions(
            home: home,
            workspaceRoots: configuration.workspaceRoots,
            repositories: [],
            fileManager: fileManager
        )
        let agentLocations = configuration.agentDataLocations ?? AgentDataLocationDiscovery(
            configuration: .init(
                homeDirectory: home,
                additionalRoots: configuration.agentAdditionalRoots,
                includesDesktopData: true,
                environment: configuration.environment
            ),
            fileManager: fileManager
        ).discover()
        for sourceID in [StorageSourceID.codex, .claude, .openCode] {
            definitions[sourceID] = []
        }
        for location in agentLocations {
            let sourceID: StorageSourceID
            switch location.provider {
            case .codex: sourceID = .codex
            case .claude: sourceID = .claude
            case .openCode: sourceID = .openCode
            }
            definitions[sourceID, default: []].append(StorageSourceRoot(
                id: location.id,
                sourceID: sourceID,
                displayName: location.displayName,
                path: location.resolvedPath,
                defaultCategory: location.kind == .rebuildableCache ? "Agent 缓存" : "Agent 数据",
                defaultRisk: location.kind == .rebuildableCache ? .rebuildableCache : .protectedUserData,
                isProtected: location.kind != .rebuildableCache
            ))
        }

        var candidates: [StorageSourceCandidate] = []
        for descriptor in descriptors where descriptor.id != .workspace {
            guard let candidate = candidate(
                descriptor: descriptor,
                definitions: definitions,
                fileManager: fileManager
            ) else { continue }
            candidates.append(candidate)
            progress?(candidate)
        }
        guard !Task.isCancelled else { return candidates }

        guard configuration.discoversCodeRepositories else {
            if let descriptor = descriptor(for: .workspace) {
                let workspace = StorageSourceCandidate(
                    descriptor: descriptor,
                    roots: [],
                    diagnostic: "Repository discovery is available in details"
                )
                candidates.append(workspace)
                progress?(workspace)
            }
            return candidates
        }

        let repositories = CodeRepositoryDiscovery(
            homeDirectory: home,
            searchRoots: configuration.repositorySearchRoots,
            includesPrivacyProtectedLocations: configuration.includesPrivacyProtectedRepositoryLocations,
            fileManager: fileManager
        ).discover()
        definitions[.workspace] = rootDefinitions(
            home: home,
            workspaceRoots: configuration.workspaceRoots,
            repositories: repositories,
            fileManager: fileManager
        )[.workspace]
        if let descriptor = descriptor(for: .workspace),
           let workspace = candidate(
               descriptor: descriptor,
               definitions: definitions,
               fileManager: fileManager
           ) {
            candidates.append(workspace)
            progress?(workspace)
        }
        return candidates
    }

    private static func candidate(
        descriptor: StorageSourceDescriptor,
        definitions: [StorageSourceID: [StorageSourceRoot]],
        fileManager: FileManager
    ) -> StorageSourceCandidate? {
        let existingRoots = (definitions[descriptor.id] ?? []).filter { root in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                return false
            }
            if root.kind == .file {
                return !isDirectory.boolValue
            }
            return isDirectory.boolValue
        }
        let roots = deduplicatedRoots(existingRoots)
        guard !roots.isEmpty else { return nil }
        return StorageSourceCandidate(descriptor: descriptor, roots: roots)
    }

    private static func rootDefinitions(
        home: URL,
        workspaceRoots: [URL],
        repositories: [CodeRepositoryLocation],
        fileManager: FileManager
    ) -> [StorageSourceID: [StorageSourceRoot]] {
        func root(
            _ source: StorageSourceID,
            _ id: String,
            _ name: String,
            _ relativePath: String,
            _ category: String,
            _ risk: StorageRiskLevel,
            protected: Bool = false,
            kind: StorageSourceRoot.Kind = .directory
        ) -> StorageSourceRoot {
            StorageSourceRoot(
                id: "\(source.rawValue).\(id)",
                sourceID: source,
                displayName: name,
                path: home.appending(path: relativePath).standardizedFileURL.path,
                defaultCategory: category,
                defaultRisk: risk,
                isProtected: protected,
                kind: kind
            )
        }
        func absoluteRoot(
            _ source: StorageSourceID,
            _ id: String,
            _ name: String,
            _ path: String,
            _ category: String,
            _ risk: StorageRiskLevel,
            protected: Bool = false,
            kind: StorageSourceRoot.Kind = .directory
        ) -> StorageSourceRoot {
            StorageSourceRoot(
                id: "\(source.rawValue).\(id)",
                sourceID: source,
                displayName: name,
                path: URL(fileURLWithPath: path, isDirectory: kind == .directory)
                    .standardizedFileURL.path,
                defaultCategory: category,
                defaultRisk: risk,
                isProtected: protected,
                kind: kind
            )
        }

        let chromeChannels = [
            ("stable", "Chrome", "Google/Chrome"),
            ("beta", "Chrome Beta", "Google/Chrome Beta"),
            ("dev", "Chrome Dev", "Google/Chrome Dev"),
            ("canary", "Chrome Canary", "Google/Chrome Canary")
        ]
        let chromeRoots = chromeChannels.flatMap { channel, name, suffix in
            [
                root(.chrome, "\(channel).support", name, "Library/Application Support/\(suffix)", "浏览器档案数据", .protectedUserData, protected: true),
                root(.chrome, "\(channel).cache", "\(name) caches", "Library/Caches/\(suffix)", "浏览器缓存", .rebuildableCache)
            ]
        }

        let repositoryRoots = repositories.map { repository in
            StorageSourceRoot(
                id: "workspace.repository.\(stablePathHash(repository.path))",
                sourceID: .workspace,
                displayName: repository.displayName,
                path: repository.path,
                defaultCategory: repository.context.kind == .worktree ? "Worktree 内容" : "代码仓库内容",
                defaultRisk: .protectedUserData,
                isProtected: true,
                resourceContext: repository.context
            )
        }
        let configuredWorkspaces = workspaceRoots.enumerated().map { index, url in
            StorageSourceRoot(
                id: "workspace.\(index).\(stablePathHash(url.standardizedFileURL.path))",
                sourceID: .workspace,
                displayName: url.lastPathComponent,
                path: url.standardizedFileURL.path,
                defaultCategory: "项目文件",
                defaultRisk: .protectedUserData,
                isProtected: true
            )
        }
        let workspaces = repositoryRoots + configuredWorkspaces

        var simulatorRoots: [StorageSourceRoot] = [
            root(
                .simulators,
                "devices",
                "Simulator devices",
                "Library/Developer/CoreSimulator/Devices",
                "模拟器设备",
                .environmentOrRuntime,
                protected: true
            ),
            root(
                .simulators,
                "user-caches",
                "Simulator user caches",
                "Library/Developer/CoreSimulator/Caches",
                "模拟器缓存",
                .rebuildableCache
            ),
            root(
                .simulators,
                "pending-deletion",
                "Simulator pending deletion",
                "Library/Developer/CoreSimulator/Temp/BackgroundDelete",
                "模拟器待删除数据",
                .rebuildableCache
            ),
            root(
                .simulators,
                "user-runtimes",
                "User-installed Simulator runtimes",
                "Library/Developer/CoreSimulator/Profiles/Runtimes",
                "模拟器运行时",
                .environmentOrRuntime,
                protected: true
            )
        ]
        let currentHome = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        if home.path == currentHome {
            simulatorRoots.append(contentsOf: [
                absoluteRoot(
                    .simulators,
                    "legacy-system-runtimes",
                    "Legacy Simulator runtimes",
                    "/Library/Developer/CoreSimulator/Profiles/Runtimes",
                    "模拟器运行时",
                    .environmentOrRuntime,
                    protected: true
                ),
                absoluteRoot(
                    .simulators,
                    "system-caches",
                    "Simulator shared caches",
                    "/Library/Developer/CoreSimulator/Caches",
                    "模拟器缓存",
                    .rebuildableCache,
                    protected: true
                )
            ])
            simulatorRoots.append(contentsOf: simulatorRuntimeAssetRoots(
                at: URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true),
                fileManager: fileManager
            ))
        }

        let vscodeRoots: [StorageSourceRoot] = [
            root(
                .vscode,
                "application-support",
                "VS Code 用户与工作区数据",
                "Library/Application Support/Code",
                "编辑器用户与工作区数据",
                .protectedUserData,
                protected: true
            ),
            root(
                .vscode,
                "extensions-and-cli",
                "VS Code 扩展与 CLI",
                ".vscode",
                "已安装扩展与 CLI",
                .environmentOrRuntime,
                protected: true
            ),
            root(.vscode, "cached-data", "VS Code 编辑器缓存", "Library/Application Support/Code/CachedData", "编辑器缓存", .rebuildableCache),
            root(.vscode, "cached-extension-vsixs", "VS Code 扩展安装包缓存", "Library/Application Support/Code/CachedExtensionVSIXs", "扩展安装包缓存", .rebuildableCache),
            root(.vscode, "web-cache", "VS Code Web 缓存", "Library/Application Support/Code/Cache", "编辑器缓存", .rebuildableCache),
            root(.vscode, "code-cache", "VS Code 代码缓存", "Library/Application Support/Code/Code Cache", "编辑器缓存", .rebuildableCache),
            root(.vscode, "gpu-cache", "VS Code 图形缓存", "Library/Application Support/Code/GPUCache", "图形缓存", .rebuildableCache),
            root(.vscode, "dawn-cache", "VS Code Dawn 缓存", "Library/Application Support/Code/DawnCache", "图形缓存", .rebuildableCache),
            root(.vscode, "dawn-graphite-cache", "VS Code Graphite 缓存", "Library/Application Support/Code/DawnGraphiteCache", "图形缓存", .rebuildableCache),
            root(.vscode, "dawn-webgpu-cache", "VS Code WebGPU 缓存", "Library/Application Support/Code/DawnWebGPUCache", "图形缓存", .rebuildableCache),
            root(.vscode, "cached-profiles", "VS Code Profile 缓存", "Library/Application Support/Code/CachedProfilesData", "编辑器缓存", .rebuildableCache),
            root(.vscode, "cached-configurations", "VS Code 配置缓存", "Library/Application Support/Code/CachedConfigurations", "编辑器缓存", .rebuildableCache),
            root(.vscode, "logs", "VS Code 日志", "Library/Application Support/Code/logs", "编辑器日志", .rebuildableCache),
            root(.vscode, "crash-reports", "VS Code 崩溃报告", "Library/Application Support/Code/Crashpad", "崩溃报告", .rebuildableCache),
            root(.vscode, "system-cache", "VS Code 系统缓存", "Library/Caches/com.microsoft.VSCode", "编辑器缓存", .rebuildableCache),
            root(.vscode, "update-cache", "VS Code 更新缓存", "Library/Caches/com.microsoft.VSCode.ShipIt", "更新缓存", .rebuildableCache)
        ]

        return [
            .chrome: chromeRoots,
            .go: [
                root(.go, "build-cache", "Build cache", "Library/Caches/go-build", "构建缓存", .rebuildableCache),
                root(
                    .go,
                    "module-download-cache",
                    "Module download cache",
                    "go/pkg/mod/cache/download",
                    "模块下载缓存",
                    .rebuildableCache
                ),
                root(.go, "module-cache", "Module cache", "go/pkg/mod", "已解压模块", .sharedOrExpensive),
                root(.go, "installed-tools", "Installed Go tools", "go/bin", "已安装工具", .environmentOrRuntime)
            ],
            .npm: [root(.npm, "cache", "npm cache", ".npm", "包缓存", .rebuildableCache)],
            .pnpm: [
                root(.pnpm, "store", "pnpm store", "Library/pnpm/store", "共享包内容", .sharedOrExpensive),
                root(.pnpm, "local-store", "pnpm store", ".local/share/pnpm/store", "共享包内容", .sharedOrExpensive)
            ],
            .bun: [
                root(.bun, "cache", "Bun package cache", ".bun/install/cache", "包缓存", .rebuildableCache),
                root(.bun, "global", "Bun global packages", ".bun/install/global", "全局包", .environmentOrRuntime)
            ],
            .pip: [root(.pip, "cache", "pip cache", "Library/Caches/pip", "包缓存", .rebuildableCache)],
            .xcode: [
                root(.xcode, "derived-data", "DerivedData", "Library/Developer/Xcode/DerivedData", "构建中间产物", .sharedOrExpensive),
                root(.xcode, "archives", "Archives", "Library/Developer/Xcode/Archives", "归档", .protectedUserData, protected: true),
                root(.xcode, "device-support", "Device Support", "Library/Developer/Xcode/iOS DeviceSupport", "真机支持文件", .sharedOrExpensive)
            ],
            .vscode: vscodeRoots,
            .simulators: simulatorRoots,
            .docker: [
                root(.docker, "raw", "Docker virtual disk", "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker 虚拟磁盘", .environmentOrRuntime, protected: true, kind: .file),
                root(.docker, "desktop-data", "Docker Desktop data", "Library/Containers/com.docker.docker/Data", "Docker Desktop 状态", .environmentOrRuntime, protected: true)
            ] + dockerConfiguredRoots(home: home, fileManager: fileManager),
            .podman: [
                root(.podman, "containers", "Rootless container storage", ".local/share/containers", "镜像与容器层", .environmentOrRuntime, protected: true),
                root(.podman, "machines", "Podman machines", ".local/share/containers/podman/machine", "Podman 虚拟机", .environmentOrRuntime, protected: true)
            ],
            .workspace: workspaces
        ]
    }

    private static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func simulatorRuntimeAssetRoots(
        at assetsDirectory: URL,
        fileManager: FileManager = .default
    ) -> [StorageSourceRoot] {
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
            .skipsSubdirectoryDescendants
        ]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: keys,
            options: options
        ) else { return [] }

        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.localizedCaseInsensitiveContains("SimulatorRuntime"),
                  (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true else {
                return nil
            }
            let path = url.standardizedFileURL.path
            return StorageSourceRoot(
                id: "simulators.downloaded-runtime.\(stablePathHash(path))",
                sourceID: .simulators,
                displayName: "Downloaded Simulator runtimes",
                path: path,
                defaultCategory: "模拟器运行时",
                defaultRisk: .environmentOrRuntime,
                isProtected: true
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func dockerConfiguredRoots(
        home: URL,
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let settingsDirectory = home.appending(path: "Library/Group Containers/group.com.docker")
        let settingsURLs = ["settings-store.json", "settings.json"].map {
            settingsDirectory.appending(path: $0)
        }
        var configuredURLs: [URL] = []

        for settingsURL in settingsURLs {
            guard let data = try? Data(contentsOf: settingsURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let configuredPath = dictionary.first(where: {
                      $0.key.caseInsensitiveCompare("DataFolder") == .orderedSame
                  })?.value as? String,
                  !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            configuredURLs.append(expandDockerPath(configuredPath, home: home))
        }

        return configuredURLs.flatMap { configuredURL -> [StorageSourceRoot] in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: configuredURL.path, isDirectory: &isDirectory) else {
                return []
            }
            let pathHash = stablePathHash(configuredURL.standardizedFileURL.path)
            if !isDirectory.boolValue {
                return [dockerDiskRoot(
                    id: "docker.configured.\(pathHash).raw",
                    path: configuredURL.path
                )]
            }

            var roots = [StorageSourceRoot(
                id: "docker.configured.\(pathHash).data",
                sourceID: .docker,
                displayName: "Configured Docker data",
                path: configuredURL.standardizedFileURL.path,
                defaultCategory: "Docker Desktop 状态",
                defaultRisk: .environmentOrRuntime,
                isProtected: true
            )]
            for diskName in ["Docker.raw", "Docker.qcow2"] {
                let diskURL = configuredURL.appending(path: diskName)
                var diskIsDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: diskURL.path, isDirectory: &diskIsDirectory),
                   !diskIsDirectory.boolValue {
                    roots.append(dockerDiskRoot(
                        id: "docker.configured.\(pathHash).raw",
                        path: diskURL.path
                    ))
                    break
                }
            }
            return roots
        }
    }

    private static func dockerDiskRoot(id: String, path: String) -> StorageSourceRoot {
        StorageSourceRoot(
            id: id,
            sourceID: .docker,
            displayName: "Docker virtual disk",
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            defaultCategory: "Docker 虚拟磁盘",
            defaultRisk: .environmentOrRuntime,
            isProtected: true,
            kind: .file
        )
    }

    private static func expandDockerPath(_ path: String, home: URL) -> URL {
        if path == "~" {
            return home.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2))).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func deduplicatedRoots(_ roots: [StorageSourceRoot]) -> [StorageSourceRoot] {
        struct PhysicalIdentity: Hashable {
            let device: UInt64
            let inode: UInt64
        }

        var identities = Set<PhysicalIdentity>()
        return roots.filter { root in
            let resolvedPath = URL(fileURLWithPath: root.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            var value = stat()
            guard stat(resolvedPath, &value) == 0 else { return true }
            return identities.insert(PhysicalIdentity(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino)
            )).inserted
        }
    }
}
