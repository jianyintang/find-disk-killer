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
        .init(id: .gradle, title: "Gradle", family: .developerTools, symbol: "building.columns", cleanupCapability: .analysisOnly),
        .init(id: .androidSDK, title: "Android SDK", family: .developerTools, symbol: "apps.iphone", cleanupCapability: .analysisOnly),
        .init(id: .flutter, title: "Flutter / Dart", family: .developerTools, symbol: "square.stack.3d.up", cleanupCapability: .analysisOnly),
        .init(id: .cocoaPods, title: "CocoaPods", family: .developerTools, symbol: "shippingbox.circle", cleanupCapability: .analysisOnly),
        .init(id: .homebrew, title: "Homebrew", family: .developerTools, symbol: "mug", cleanupCapability: .officialTool),
        .init(id: .rust, title: "Rust / Cargo", family: .developerTools, symbol: "gearshape.2", cleanupCapability: .officialTool),
        .init(id: .toolCaches, title: "开发工具缓存", family: .developerTools, symbol: "externaldrive.badge.timemachine", cleanupCapability: .analysisOnly),
        .init(id: .xcode, title: "Xcode", family: .developerTools, symbol: "hammer", cleanupCapability: .analysisOnly),
        .init(id: .vscode, title: "VS Code", family: .developerTools, symbol: "chevron.left.forwardslash.chevron.right", cleanupCapability: .verifiedFiles),
        .init(id: .cursor, title: "Cursor", family: .developerTools, symbol: "cursorarrow.rays", cleanupCapability: .verifiedFiles),
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
            environment: configuration.environment,
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
            environment: configuration.environment,
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
        environment: [String: String],
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

        let cursorBundleIdentifier = applicationBundleIdentifier(
            at: "/Applications/Cursor.app",
            fallback: "com.todesktop.230313mzl4w4u92"
        )
        let cursorRoots: [StorageSourceRoot] = [
            root(
                .cursor,
                "application-support",
                "Cursor 用户与工作区数据",
                "Library/Application Support/Cursor",
                "编辑器用户与工作区数据",
                .protectedUserData,
                protected: true
            ),
            root(
                .cursor,
                "extensions-and-cli",
                "Cursor 扩展与 CLI",
                ".cursor",
                "已安装扩展与 CLI",
                .environmentOrRuntime,
                protected: true
            ),
            root(.cursor, "cached-data", "Cursor 编辑器缓存", "Library/Application Support/Cursor/CachedData", "编辑器缓存", .rebuildableCache),
            root(.cursor, "cached-extension-vsixs", "Cursor 扩展安装包缓存", "Library/Application Support/Cursor/CachedExtensionVSIXs", "扩展安装包缓存", .rebuildableCache),
            root(.cursor, "web-cache", "Cursor Web 缓存", "Library/Application Support/Cursor/Cache", "编辑器缓存", .rebuildableCache),
            root(.cursor, "code-cache", "Cursor 代码缓存", "Library/Application Support/Cursor/Code Cache", "编辑器缓存", .rebuildableCache),
            root(.cursor, "gpu-cache", "Cursor 图形缓存", "Library/Application Support/Cursor/GPUCache", "图形缓存", .rebuildableCache),
            root(.cursor, "dawn-cache", "Cursor Dawn 缓存", "Library/Application Support/Cursor/DawnCache", "图形缓存", .rebuildableCache),
            root(.cursor, "dawn-graphite-cache", "Cursor Graphite 缓存", "Library/Application Support/Cursor/DawnGraphiteCache", "图形缓存", .rebuildableCache),
            root(.cursor, "dawn-webgpu-cache", "Cursor WebGPU 缓存", "Library/Application Support/Cursor/DawnWebGPUCache", "图形缓存", .rebuildableCache),
            root(.cursor, "cached-profiles", "Cursor Profile 缓存", "Library/Application Support/Cursor/CachedProfilesData", "编辑器缓存", .rebuildableCache),
            root(.cursor, "cached-configurations", "Cursor 配置缓存", "Library/Application Support/Cursor/CachedConfigurations", "编辑器缓存", .rebuildableCache),
            root(.cursor, "logs", "Cursor 日志", "Library/Application Support/Cursor/logs", "编辑器日志", .rebuildableCache),
            root(.cursor, "crash-reports", "Cursor 崩溃报告", "Library/Application Support/Cursor/Crashpad", "崩溃报告", .rebuildableCache),
            root(.cursor, "system-cache", "Cursor 系统缓存", "Library/Caches/\(cursorBundleIdentifier)", "编辑器缓存", .rebuildableCache),
            root(.cursor, "update-cache", "Cursor 更新缓存", "Library/Caches/\(cursorBundleIdentifier).ShipIt", "更新缓存", .rebuildableCache)
        ]

        let gradleRoots = makeGradleRoots(
            home: home,
            environment: environment,
            fileManager: fileManager
        )
        let androidSDKRoots = makeAndroidSDKRoots(
            home: home,
            environment: environment,
            fileManager: fileManager
        )
        let flutterRoots = makeFlutterRoots(
            home: home,
            environment: environment,
            fileManager: fileManager
        )
        let cocoaPodsRoots = makeCocoaPodsRoots(
            home: home,
            fileManager: fileManager
        )
        let homebrewRoots = makeHomebrewRoots(
            home: home,
            environment: environment,
            fileManager: fileManager
        )
        let rustRoots = makeRustRoots(
            home: home,
            environment: environment,
            fileManager: fileManager
        )
        let toolCacheRoots = makeToolCacheRoots(
            home: home,
            environment: environment
        )

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
            .gradle: gradleRoots,
            .androidSDK: androidSDKRoots,
            .flutter: flutterRoots,
            .cocoaPods: cocoaPodsRoots,
            .homebrew: homebrewRoots,
            .rust: rustRoots,
            .toolCaches: toolCacheRoots,
            .xcode: [
                root(.xcode, "derived-data", "DerivedData", "Library/Developer/Xcode/DerivedData", "构建中间产物", .sharedOrExpensive),
                root(.xcode, "archives", "Archives", "Library/Developer/Xcode/Archives", "归档", .protectedUserData, protected: true),
                root(.xcode, "device-support", "Device Support", "Library/Developer/Xcode/iOS DeviceSupport", "真机支持文件", .sharedOrExpensive)
            ],
            .vscode: vscodeRoots,
            .cursor: cursorRoots,
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

    private static func makeGradleRoots(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let defaultHome = home.appending(path: ".gradle", directoryHint: .isDirectory)
        let homes = configuredDirectories(
            defaultURL: defaultHome,
            environmentKeys: ["GRADLE_USER_HOME"],
            environment: environment,
            home: home
        )
        return homes.flatMap { gradleHome in
            let suffix = gradleHome.standardizedFileURL.path == defaultHome.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(gradleHome.standardizedFileURL.path))"
            func gradleRoot(
                _ id: String,
                _ name: String,
                _ relativePath: String,
                _ category: String,
                _ risk: StorageRiskLevel
            ) -> StorageSourceRoot {
                StorageSourceRoot(
                    id: "gradle.\(id)\(suffix)",
                    sourceID: .gradle,
                    displayName: name,
                    path: gradleHome.appending(path: relativePath).standardizedFileURL.path,
                    defaultCategory: category,
                    defaultRisk: risk,
                    isProtected: true
                )
            }

            var roots = [
                gradleRoot("wrapper", "Gradle Wrapper distributions", "wrapper/dists", "Wrapper 发行版", .environmentOrRuntime),
                gradleRoot("jdks", "Gradle-managed JDKs", "jdks", "Gradle 管理的 JDK", .environmentOrRuntime),
                gradleRoot("daemon", "Gradle daemon state", "daemon", "Daemon 状态与日志", .sharedOrExpensive),
                gradleRoot("native", "Gradle native cache", "native", "本机组件缓存", .rebuildableCache)
            ]
            let caches = gradleHome.appending(path: "caches", directoryHint: .isDirectory)
            let children = (try? fileManager.contentsOfDirectory(
                at: caches,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }
                let name = child.lastPathComponent
                let lower = name.lowercased()
                let category: String
                let risk: StorageRiskLevel
                if lower.hasPrefix("build-cache-") {
                    category = "本机构建缓存"
                    risk = .rebuildableCache
                } else if lower.hasPrefix("transforms-") {
                    category = "Artifact 转换缓存"
                    risk = .rebuildableCache
                } else if lower.hasPrefix("modules-") {
                    category = "依赖下载与元数据"
                    risk = .sharedOrExpensive
                } else if lower.first?.isNumber == true {
                    category = "版本化构建状态"
                    risk = .sharedOrExpensive
                } else {
                    category = "Gradle 其它缓存"
                    risk = .rebuildableCache
                }
                roots.append(gradleRoot(
                    "cache.\(stablePathHash(name))",
                    name,
                    "caches/\(name)",
                    category,
                    risk
                ))
            }
            return roots
        }
    }

    private static func makeAndroidSDKRoots(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let defaultSDK = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let homes = configuredDirectories(
            defaultURL: defaultSDK,
            environmentKeys: ["ANDROID_SDK_ROOT", "ANDROID_HOME"],
            environment: environment,
            home: home
        )
        let versionedDefinitions: [(String, String, String, Int, String, StorageRiskLevel)] = [
            ("system-images", "Android System Image", "system-images", 3, "Android 系统镜像", .environmentOrRuntime),
            ("ndk", "Android NDK", "ndk", 1, "Android NDK", .environmentOrRuntime),
            ("platforms", "Android Platform", "platforms", 1, "Android 平台", .environmentOrRuntime),
            ("build-tools", "Android Build Tools", "build-tools", 1, "Android 构建工具", .environmentOrRuntime),
            ("sources", "Android Sources", "sources", 1, "Android SDK 源码", .sharedOrExpensive),
            ("cmdline-tools", "Android Command-line Tools", "cmdline-tools", 1, "Android 命令行工具", .environmentOrRuntime),
            ("cmake", "Android CMake", "cmake", 1, "Android CMake", .environmentOrRuntime)
        ]
        let aggregateDefinitions: [(String, String, String, String, StorageRiskLevel)] = [
            ("emulator", "Android Emulator", "emulator", "Android 模拟器", .environmentOrRuntime),
            ("platform-tools", "Android Platform Tools", "platform-tools", "Android 平台工具", .environmentOrRuntime),
            ("extras", "Android SDK Extras", "extras", "Android SDK 扩展", .environmentOrRuntime)
        ]
        return homes.flatMap { sdkHome in
            let suffix = sdkHome.standardizedFileURL.path == defaultSDK.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(sdkHome.standardizedFileURL.path))"
            var roots = aggregateDefinitions.map { id, name, relativePath, category, risk in
                StorageSourceRoot(
                    id: "androidSDK.\(id)\(suffix)",
                    sourceID: .androidSDK,
                    displayName: name,
                    path: sdkHome.appending(path: relativePath).standardizedFileURL.path,
                    defaultCategory: category,
                    defaultRisk: risk,
                    isProtected: true
                )
            }
            for definition in versionedDefinitions {
                let baseURL = sdkHome.appending(path: definition.2, directoryHint: .isDirectory)
                let packages = descendantDirectories(
                    at: baseURL,
                    depth: definition.3,
                    fileManager: fileManager
                )
                if packages.isEmpty {
                    roots.append(StorageSourceRoot(
                        id: "androidSDK.\(definition.0)\(suffix)",
                        sourceID: .androidSDK,
                        displayName: definition.1,
                        path: baseURL.standardizedFileURL.path,
                        defaultCategory: definition.4,
                        defaultRisk: definition.5,
                        isProtected: true
                    ))
                    continue
                }
                for package in packages {
                    let relative = package.path.replacingOccurrences(
                        of: baseURL.path + "/",
                        with: ""
                    )
                    roots.append(StorageSourceRoot(
                        id: "androidSDK.\(definition.0).\(stablePathHash(relative))\(suffix)",
                        sourceID: .androidSDK,
                        displayName: "\(definition.1) · \(relative.replacingOccurrences(of: "/", with: " · "))",
                        path: package.standardizedFileURL.path,
                        defaultCategory: definition.4,
                        defaultRisk: definition.5,
                        isProtected: true
                    ))
                }
            }
            return roots
        }
    }

    private static func makeFlutterRoots(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let defaultPubCache = home.appending(path: ".pub-cache", directoryHint: .isDirectory)
        let pubCaches = configuredDirectories(
            defaultURL: defaultPubCache,
            environmentKeys: ["PUB_CACHE"],
            environment: environment,
            home: home
        )
        let pubDefinitions: [(String, String, String, String, StorageRiskLevel)] = [
            ("hosted", "Pub Hosted packages", "hosted", "Pub Hosted 包", .sharedOrExpensive),
            ("git", "Pub Git packages", "git", "Pub Git 包", .sharedOrExpensive),
            ("bin", "Dart global commands", "bin", "Dart 全局命令", .environmentOrRuntime),
            ("hosted-hashes", "Pub hosted metadata", "hosted-hashes", "Pub 索引元数据", .rebuildableCache),
            ("temp", "Pub temporary downloads", "_temp", "Pub 临时下载", .rebuildableCache),
            ("logs", "Pub logs", "log", "Pub 日志", .rebuildableCache)
        ]
        var roots = pubCaches.flatMap { pubCache in
            let suffix = pubCache.standardizedFileURL.path == defaultPubCache.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(pubCache.standardizedFileURL.path))"
            return pubDefinitions.map { id, name, relativePath, category, risk in
                StorageSourceRoot(
                    id: "flutter.pub.\(id)\(suffix)",
                    sourceID: .flutter,
                    displayName: name,
                    path: pubCache.appending(path: relativePath).standardizedFileURL.path,
                    defaultCategory: category,
                    defaultRisk: risk,
                    isProtected: true
                )
            }
        }

        let defaultFVMHome = home.appending(path: "fvm", directoryHint: .isDirectory)
        var fvmHomes = configuredDirectories(
            defaultURL: defaultFVMHome,
            environmentKeys: ["FVM_HOME", "FVM_CACHE_PATH"],
            environment: environment,
            home: home
        )
        fvmHomes.append(home.appending(path: ".fvm", directoryHint: .isDirectory))
        fvmHomes.append(home.appending(path: "Library/Application Support/fvm", directoryHint: .isDirectory))
        var seenFVMPaths = Set<String>()
        fvmHomes = fvmHomes.filter {
            seenFVMPaths.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted
        }
        for fvmHome in fvmHomes {
            let suffix = fvmHome.standardizedFileURL.path == defaultFVMHome.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(fvmHome.standardizedFileURL.path))"
            let versionsURL = fvmHome.appending(path: "versions", directoryHint: .isDirectory)
            let versions = descendantDirectories(at: versionsURL, depth: 1, fileManager: fileManager)
            if versions.isEmpty {
                roots.append(StorageSourceRoot(
                    id: "flutter.fvm.versions\(suffix)",
                    sourceID: .flutter,
                    displayName: "FVM Flutter SDK versions",
                    path: versionsURL.standardizedFileURL.path,
                    defaultCategory: "Flutter SDK 版本",
                    defaultRisk: .environmentOrRuntime,
                    isProtected: true
                ))
            } else {
                for version in versions {
                    roots.append(StorageSourceRoot(
                        id: "flutter.fvm.version.\(stablePathHash(version.lastPathComponent))\(suffix)",
                        sourceID: .flutter,
                        displayName: "Flutter \(version.lastPathComponent)",
                        path: version.standardizedFileURL.path,
                        defaultCategory: "Flutter SDK 版本",
                        defaultRisk: .environmentOrRuntime,
                        isProtected: true
                    ))
                }
            }
            roots.append(StorageSourceRoot(
                id: "flutter.fvm.repository\(suffix)",
                sourceID: .flutter,
                displayName: "FVM Flutter repository",
                path: fvmHome.appending(path: "cache.git").standardizedFileURL.path,
                defaultCategory: "FVM Flutter 仓库",
                defaultRisk: .sharedOrExpensive,
                isProtected: true
            ))
        }
        return roots
    }

    private static func makeCocoaPodsRoots(
        home: URL,
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let repositoriesURL = home.appending(path: ".cocoapods/repos", directoryHint: .isDirectory)
        let repositories = descendantDirectories(
            at: repositoriesURL,
            depth: 1,
            fileManager: fileManager
        )
        var roots = repositories.map { repository in
            StorageSourceRoot(
                id: "cocoaPods.repository.\(stablePathHash(repository.lastPathComponent))",
                sourceID: .cocoaPods,
                displayName: repository.lastPathComponent,
                path: repository.standardizedFileURL.path,
                defaultCategory: "CocoaPods Specs 仓库",
                defaultRisk: .sharedOrExpensive,
                isProtected: true
            )
        }
        if repositories.isEmpty {
            roots.append(StorageSourceRoot(
                id: "cocoaPods.repositories",
                sourceID: .cocoaPods,
                displayName: "CocoaPods Specs repositories",
                path: repositoriesURL.standardizedFileURL.path,
                defaultCategory: "CocoaPods Specs 仓库",
                defaultRisk: .sharedOrExpensive,
                isProtected: true
            ))
        }
        roots.append(StorageSourceRoot(
            id: "cocoaPods.cache",
            sourceID: .cocoaPods,
            displayName: "CocoaPods cache",
            path: home.appending(path: "Library/Caches/CocoaPods", directoryHint: .isDirectory)
                .standardizedFileURL.path,
            defaultCategory: "CocoaPods 下载与构建缓存",
            defaultRisk: .rebuildableCache,
            isProtected: true
        ))
        return roots
    }

    private static func makeHomebrewRoots(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let currentHome = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        let scansCurrentHome = home.resolvingSymlinksInPath().standardizedFileURL.path == currentHome
        var cellarURLs: [URL] = []
        if let configuredCellar = absoluteDirectory(
            environment["HOMEBREW_CELLAR"],
            home: home
        ) {
            cellarURLs.append(configuredCellar)
        }
        if let configuredPrefix = absoluteDirectory(
            environment["HOMEBREW_PREFIX"],
            home: home
        ) {
            cellarURLs.append(configuredPrefix.appending(path: "Cellar", directoryHint: .isDirectory))
        }
        if scansCurrentHome {
            cellarURLs.append(URL(fileURLWithPath: "/opt/homebrew/Cellar", isDirectory: true))
            cellarURLs.append(URL(fileURLWithPath: "/usr/local/Cellar", isDirectory: true))
        }
        var seenCellars = Set<String>()
        cellarURLs = cellarURLs.filter {
            seenCellars.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted
        }

        var roots: [StorageSourceRoot] = []
        for cellar in cellarURLs {
            let prefix = cellar.deletingLastPathComponent()
            let formulae = descendantDirectories(at: cellar, depth: 1, fileManager: fileManager)
            for formula in formulae {
                let versions = descendantDirectories(at: formula, depth: 1, fileManager: fileManager)
                let optURL = prefix.appending(path: "opt/\(formula.lastPathComponent)")
                let linkedKeg = fileManager.fileExists(atPath: optURL.path)
                    ? optURL.resolvingSymlinksInPath().standardizedFileURL.path
                    : nil
                let currentKeg = linkedKeg ?? versions.max {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }?.resolvingSymlinksInPath().standardizedFileURL.path
                for version in versions {
                    let versionPath = version.resolvingSymlinksInPath().standardizedFileURL.path
                    let isOldVersion = versions.count > 1 && versionPath != currentKeg
                    let installedOnRequest = homebrewInstalledOnRequest(
                        at: version.appending(path: "INSTALL_RECEIPT.json"),
                        fileManager: fileManager
                    )
                    let category: String
                    if isOldVersion {
                        category = "Homebrew 旧版本 Formula"
                    } else if installedOnRequest == true {
                        category = "Homebrew 显式安装 Formula"
                    } else {
                        category = "Homebrew 依赖 Formula"
                    }
                    roots.append(StorageSourceRoot(
                        id: "homebrew.formula.\(stablePathHash(versionPath))",
                        sourceID: .homebrew,
                        displayName: "\(formula.lastPathComponent) · \(version.lastPathComponent)",
                        path: version.standardizedFileURL.path,
                        defaultCategory: category,
                        defaultRisk: .environmentOrRuntime,
                        isProtected: true
                    ))
                }
            }

            let caskroom = prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
            for cask in descendantDirectories(at: caskroom, depth: 1, fileManager: fileManager) {
                let versions = descendantDirectories(at: cask, depth: 1, fileManager: fileManager)
                if versions.isEmpty {
                    roots.append(StorageSourceRoot(
                        id: "homebrew.cask.\(stablePathHash(cask.path))",
                        sourceID: .homebrew,
                        displayName: cask.lastPathComponent,
                        path: cask.standardizedFileURL.path,
                        defaultCategory: "Homebrew Cask",
                        defaultRisk: .environmentOrRuntime,
                        isProtected: true
                    ))
                    continue
                }
                for version in versions {
                    roots.append(StorageSourceRoot(
                        id: "homebrew.cask.\(stablePathHash(version.path))",
                        sourceID: .homebrew,
                        displayName: "\(cask.lastPathComponent) · \(version.lastPathComponent)",
                        path: version.standardizedFileURL.path,
                        defaultCategory: "Homebrew Cask",
                        defaultRisk: .environmentOrRuntime,
                        isProtected: true
                    ))
                }
            }
        }

        let defaultCache = home.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory)
        for cache in configuredDirectories(
            defaultURL: defaultCache,
            environmentKeys: ["HOMEBREW_CACHE"],
            environment: environment,
            home: home
        ) {
            roots.append(StorageSourceRoot(
                id: "homebrew.cache.\(stablePathHash(cache.path))",
                sourceID: .homebrew,
                displayName: "Homebrew cache",
                path: cache.standardizedFileURL.path,
                defaultCategory: "Homebrew 下载与元数据缓存",
                defaultRisk: .rebuildableCache,
                isProtected: true
            ))
        }
        roots.append(StorageSourceRoot(
            id: "homebrew.logs",
            sourceID: .homebrew,
            displayName: "Homebrew logs",
            path: home.appending(path: "Library/Logs/Homebrew", directoryHint: .isDirectory)
                .standardizedFileURL.path,
            defaultCategory: "Homebrew 日志",
            defaultRisk: .rebuildableCache,
            isProtected: true
        ))
        return roots
    }

    private static func homebrewInstalledOnRequest(
        at receiptURL: URL,
        fileManager: FileManager
    ) -> Bool? {
        guard fileManager.fileExists(atPath: receiptURL.path),
              let data = try? Data(contentsOf: receiptURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let installedOnRequest = object["installed_on_request"] as? Bool {
            return installedOnRequest
        }
        return (object["installed_as_dependency"] as? Bool).map(!)
    }

    private static func makeRustRoots(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [StorageSourceRoot] {
        let defaultRustupHome = home.appending(path: ".rustup", directoryHint: .isDirectory)
        let rustupHomes = configuredDirectories(
            defaultURL: defaultRustupHome,
            environmentKeys: ["RUSTUP_HOME"],
            environment: environment,
            home: home
        )
        var roots: [StorageSourceRoot] = []
        for rustupHome in rustupHomes {
            let suffix = rustupHome.standardizedFileURL.path == defaultRustupHome.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(rustupHome.standardizedFileURL.path))"
            let toolchainsURL = rustupHome.appending(path: "toolchains", directoryHint: .isDirectory)
            let toolchains = descendantDirectories(
                at: toolchainsURL,
                depth: 1,
                fileManager: fileManager
            )
            if toolchains.isEmpty {
                roots.append(StorageSourceRoot(
                    id: "rust.rustup.toolchains\(suffix)",
                    sourceID: .rust,
                    displayName: "Rust toolchains",
                    path: toolchainsURL.standardizedFileURL.path,
                    defaultCategory: "Rust 工具链",
                    defaultRisk: .environmentOrRuntime,
                    isProtected: true
                ))
            } else {
                for toolchain in toolchains {
                    roots.append(StorageSourceRoot(
                        id: "rust.rustup.toolchain.\(stablePathHash(toolchain.lastPathComponent))\(suffix)",
                        sourceID: .rust,
                        displayName: toolchain.lastPathComponent,
                        path: toolchain.standardizedFileURL.path,
                        defaultCategory: "Rust 工具链",
                        defaultRisk: .environmentOrRuntime,
                        isProtected: true
                    ))
                }
            }
            roots.append(StorageSourceRoot(
                id: "rust.rustup.downloads\(suffix)",
                sourceID: .rust,
                displayName: "rustup downloads",
                path: rustupHome.appending(path: "downloads").standardizedFileURL.path,
                defaultCategory: "rustup 下载缓存",
                defaultRisk: .rebuildableCache,
                isProtected: true
            ))
            roots.append(StorageSourceRoot(
                id: "rust.rustup.temp\(suffix)",
                sourceID: .rust,
                displayName: "rustup temporary files",
                path: rustupHome.appending(path: "tmp").standardizedFileURL.path,
                defaultCategory: "rustup 临时文件",
                defaultRisk: .rebuildableCache,
                isProtected: true
            ))
        }

        let defaultCargoHome = home.appending(path: ".cargo", directoryHint: .isDirectory)
        let cargoHomes = configuredDirectories(
            defaultURL: defaultCargoHome,
            environmentKeys: ["CARGO_HOME"],
            environment: environment,
            home: home
        )
        let cargoDefinitions: [(String, String, String, String, StorageRiskLevel)] = [
            ("registry.archives", "Cargo crate archives", "registry/cache", "Cargo Crate 下载", .rebuildableCache),
            ("registry.sources", "Cargo registry sources", "registry/src", "Cargo Registry 源码", .sharedOrExpensive),
            ("registry.index", "Cargo registry index", "registry/index", "Cargo Registry 索引", .sharedOrExpensive),
            ("git.database", "Cargo Git databases", "git/db", "Cargo Git 仓库缓存", .sharedOrExpensive),
            ("git.checkouts", "Cargo Git checkouts", "git/checkouts", "Cargo Git 检出", .sharedOrExpensive),
            ("bin", "Cargo installed commands", "bin", "Cargo 已安装命令", .environmentOrRuntime)
        ]
        for cargoHome in cargoHomes {
            let suffix = cargoHome.standardizedFileURL.path == defaultCargoHome.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(cargoHome.standardizedFileURL.path))"
            roots.append(contentsOf: cargoDefinitions.map { id, name, relativePath, category, risk in
                StorageSourceRoot(
                    id: "rust.cargo.\(id)\(suffix)",
                    sourceID: .rust,
                    displayName: name,
                    path: cargoHome.appending(path: relativePath).standardizedFileURL.path,
                    defaultCategory: category,
                    defaultRisk: risk,
                    isProtected: true
                )
            })
        }
        return roots
    }

    private static func makeToolCacheRoots(
        home: URL,
        environment: [String: String]
    ) -> [StorageSourceRoot] {
        let defaultCacheHome = home.appending(path: ".cache", directoryHint: .isDirectory)
        let cacheHomes = configuredDirectories(
            defaultURL: defaultCacheHome,
            environmentKeys: ["XDG_CACHE_HOME"],
            environment: environment,
            home: home
        )
        let definitions: [(String, String, String, String, StorageRiskLevel)] = [
            ("uv", "uv package cache", "uv", "uv 包与环境缓存", .sharedOrExpensive),
            ("frida", "Frida runtime cache", "frida", "Frida 运行时缓存", .environmentOrRuntime),
            ("chrome-devtools-mcp", "Chrome DevTools MCP profiles", "chrome-devtools-mcp", "MCP 浏览器档案", .protectedUserData),
            ("codex-runtimes", "Codex tool runtimes", "codex-runtimes", "Codex 工具运行时", .environmentOrRuntime)
        ]
        var roots = cacheHomes.flatMap { cacheHome in
            let suffix = cacheHome.standardizedFileURL.path == defaultCacheHome.standardizedFileURL.path
                ? ""
                : ".\(stablePathHash(cacheHome.standardizedFileURL.path))"
            return definitions.map { id, name, relativePath, category, risk in
                StorageSourceRoot(
                    id: "toolCaches.\(id)\(suffix)",
                    sourceID: .toolCaches,
                    displayName: name,
                    path: cacheHome.appending(path: relativePath).standardizedFileURL.path,
                    defaultCategory: category,
                    defaultRisk: risk,
                    isProtected: true
                )
            }
        }
        if let uvCache = absoluteDirectory(environment["UV_CACHE_DIR"], home: home) {
            roots.append(StorageSourceRoot(
                id: "toolCaches.uv.\(stablePathHash(uvCache.path))",
                sourceID: .toolCaches,
                displayName: "uv package cache",
                path: uvCache.standardizedFileURL.path,
                defaultCategory: "uv 包与环境缓存",
                defaultRisk: .sharedOrExpensive,
                isProtected: true
            ))
        }
        return roots
    }

    private static func absoluteDirectory(_ value: String?, home: URL) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value == "~" { return home.standardizedFileURL }
        if value.hasPrefix("~/") {
            return home.appending(path: String(value.dropFirst(2))).standardizedFileURL
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private static func descendantDirectories(
        at root: URL,
        depth: Int,
        fileManager: FileManager
    ) -> [URL] {
        guard depth > 0 else { return [root] }
        var current = [root]
        for _ in 0..<depth {
            current = current.flatMap { parent in
                ((try? fileManager.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []).filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            }
            if current.isEmpty { break }
        }
        return current.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func configuredDirectories(
        defaultURL: URL,
        environmentKeys: [String],
        environment: [String: String],
        home: URL
    ) -> [URL] {
        var urls = [defaultURL.standardizedFileURL]
        for key in environmentKeys {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let url: URL
            if value == "~" {
                url = home
            } else if value.hasPrefix("~/") {
                url = home.appending(path: String(value.dropFirst(2)))
            } else if value.hasPrefix("/") {
                url = URL(fileURLWithPath: value, isDirectory: true)
            } else {
                continue
            }
            urls.append(url.standardizedFileURL)
        }
        var paths = Set<String>()
        return urls.filter { paths.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    private static func applicationBundleIdentifier(at path: String, fallback: String) -> String {
        guard let identifier = Bundle(path: path)?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return fallback
        }
        return identifier
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
