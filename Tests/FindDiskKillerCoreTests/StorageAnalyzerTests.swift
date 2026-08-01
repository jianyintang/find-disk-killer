import Foundation
import Testing
@testable import FindDiskKillerCore

@Suite(.serialized)
struct StorageAnalyzerTests {
    @Test func volumeSnapshotConservesUsedOtherAndAvailableCapacity() {
        let volume = StorageVolumeSnapshot(
            id: "disk",
            name: "Data",
            mountPath: "/",
            totalCapacity: 1_000,
            availableCapacity: 250,
            sourceUsages: [
                .init(sourceID: .chrome, allocatedBytes: 200),
                .init(sourceID: .go, allocatedBytes: 300)
            ]
        )

        #expect(volume.usedBytes == 750)
        #expect(volume.analyzedBytes == 500)
        #expect(volume.otherBytes == 250)
        #expect(volume.analyzedBytes + volume.otherBytes + volume.availableCapacity == volume.totalCapacity)
    }

    @Test func volumeSnapshotClampsOtherWhenAnalyzedExceedsReportedUsedSpace() {
        let volume = StorageVolumeSnapshot(
            id: "disk",
            name: "Data",
            mountPath: "/",
            totalCapacity: 1_000,
            availableCapacity: 800,
            sourceUsages: [.init(sourceID: .go, allocatedBytes: 300)]
        )

        #expect(volume.usedBytes == 200)
        #expect(volume.otherBytes == 0)
    }

    @Test func legacySnapshotWithoutVolumesDecodesWithEmptyVolumes() throws {
        let snapshot = StorageAnalysisSnapshot(
            id: UUID(),
            scannedAt: Date(timeIntervalSince1970: 100),
            results: [],
            totalAllocatedBytes: 0,
            conflictBytes: 0,
            measuredEntryCount: 0,
            skippedEntryCount: 0
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object.removeValue(forKey: "volumes")

        let decoded = try JSONDecoder().decode(
            StorageAnalysisSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.volumes.isEmpty)
    }

    @Test func catalogUsesStableSourceAndRootIdentifiers() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory(".npm")

        let configuration = StorageScanConfiguration(homeDirectory: fixture.home)
        let first = StorageSourceCatalog.detect(configuration: configuration)
        let second = StorageSourceCatalog.detect(configuration: configuration)

        #expect(first.map(\.id) == [.npm])
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.first?.roots.map(\.id) == second.first?.roots.map(\.id))
        #expect(first.first?.roots.first?.id == "npm.cache")
    }

    @Test func catalogPublishesEachRealCandidateAsItIsConfirmed() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory(".npm")
        try fixture.createDirectory("code/project/.git")
        let recorder = StorageCandidateRecorder()

        let candidates = StorageSourceCatalog.detect(
            configuration: .init(
                homeDirectory: fixture.home,
                repositorySearchRoots: [fixture.home]
            ),
            progress: recorder.append
        )

        #expect(candidates.map(\.id) == [.npm, .workspace])
        #expect(recorder.sourceIDs == candidates.map(\.id))
    }

    @Test func catalogDefersRepositoryDiscoveryButKeepsOneWorkspaceSource() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory(".npm")
        try fixture.createDirectory("code/project/.git")

        let candidates = StorageSourceCatalog.detect(configuration: .init(
            homeDirectory: fixture.home,
            repositorySearchRoots: [fixture.home],
            discoversCodeRepositories: false
        ))

        #expect(candidates.map(\.id) == [.npm, .workspace])
        let workspace = try #require(candidates.first { $0.id == .workspace })
        #expect(workspace.descriptor.title == "Git Workspaces")
        #expect(workspace.roots.isEmpty)
    }

    @Test func fullScanSkipsADeferredWorkspaceUntilItsDetailAnalysis() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory(".npm")
        try fixture.createDirectory("code/project/.git")

        let snapshot = try await StorageAnalyzer(configuration: .init(
            homeDirectory: fixture.home,
            repositorySearchRoots: [fixture.home],
            discoversCodeRepositories: false
        )).scan()

        #expect(snapshot.result(for: .npm) != nil)
        #expect(snapshot.result(for: .workspace) == nil)
    }

    @Test func catalogDetectsOpenCodeDataAsAFirstClassSource() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory(".local/share/opencode")

        let candidates = StorageSourceCatalog.detect(
            configuration: .init(homeDirectory: fixture.home)
        )
        let openCode = try #require(candidates.first { $0.id == .openCode })

        #expect(openCode.descriptor.family == .aiTools)
        #expect(openCode.descriptor.title == "OpenCode")
        #expect(openCode.roots.map(\.id) == ["openCode.data"])
        #expect(openCode.roots.first?.path.hasSuffix("/.local/share/opencode") == true)
    }

    @Test func catalogDetectsVSCodeAsADeveloperToolWithSeparatedStorageRoots() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory("Library/Application Support/Code/User")
        try fixture.createDirectory("Library/Application Support/Code/CachedData")
        try fixture.createDirectory("Library/Application Support/Code/CachedExtensionVSIXs")
        try fixture.createDirectory("Library/Application Support/Code/logs")
        try fixture.createDirectory("Library/Caches/com.microsoft.VSCode")
        try fixture.createDirectory(".vscode/extensions")

        let candidates = StorageSourceCatalog.detect(
            configuration: .init(homeDirectory: fixture.home)
        )
        let vscode = try #require(candidates.first { $0.id == .vscode })

        #expect(vscode.descriptor.title == "VS Code")
        #expect(vscode.descriptor.family == .developerTools)
        #expect(vscode.descriptor.cleanupCapability == .verifiedFiles)
        #expect(Set(vscode.roots.map(\.id)) == [
            "vscode.application-support",
            "vscode.extensions-and-cli",
            "vscode.cached-data",
            "vscode.cached-extension-vsixs",
            "vscode.logs",
            "vscode.system-cache"
        ])
    }

    @Test func vscodeScanProtectsUserDataAndOffersOnlyVerifiedCaches() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile("Library/Application Support/Code/User/settings.json")
        try fixture.writeFile(
            "Library/Application Support/Code/User/workspaceStorage/workspace/state.vscdb"
        )
        try fixture.writeFile("Library/Application Support/Code/Backups/session/backup.txt")
        try fixture.writeFile(
            "Library/Application Support/Code/CachedData/commit/workbench.js",
            byteCount: 8_192
        )
        try fixture.writeFile(
            "Library/Application Support/Code/CachedExtensionVSIXs/extension.vsix",
            byteCount: 12_288
        )
        try fixture.writeFile("Library/Application Support/Code/logs/session/window.log")
        try fixture.writeFile(".vscode/extensions/publisher.extension/extension.js")
        try fixture.writeFile("Library/Caches/com.microsoft.VSCode/cache.bin")

        let snapshot = try await StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home)
        ).scan()
        let vscode = try #require(snapshot.result(for: .vscode))

        #expect(vscode.descriptor.family == .developerTools)
        #expect(vscode.reclaimableCandidateBytes > 0)
        #expect(snapshot.conflictBytes == 0)
        #expect(vscode.components.contains {
            $0.rootID == "vscode.application-support"
                && $0.title == "用户设置与扩展状态"
                && $0.isProtected
        })
        #expect(vscode.components.contains {
            $0.rootID == "vscode.application-support"
                && $0.title == "工作区状态"
                && $0.isProtected
        })
        #expect(vscode.components.contains {
            $0.rootID == "vscode.application-support"
                && $0.title == "本地历史与未保存备份"
                && $0.isProtected
        })
        #expect(vscode.components.contains {
            $0.rootID == "vscode.extensions-and-cli"
                && $0.title == "已安装扩展"
                && $0.isProtected
        })
        #expect(vscode.components.contains {
            $0.rootID == "vscode.cached-extension-vsixs"
                && $0.title == "扩展安装包缓存"
                && !$0.isProtected
        })
        let safeRootIDs = Set(vscode.resourceTree.compactMap { node -> String? in
            guard node.cleanupTarget != nil else { return nil }
            return node.id
        })
        #expect(safeRootIDs == [
            "vscode.cached-data",
            "vscode.cached-extension-vsixs",
            "vscode.logs",
            "vscode.system-cache"
        ])
        #expect(vscode.resourceTree.first { $0.id == "vscode.application-support" }?
            .cleanupTarget == nil)
        #expect(vscode.resourceTree.first { $0.id == "vscode.extensions-and-cli" }?
            .cleanupTarget == nil)
    }

    @Test func catalogSeparatesSimulatorDevicesRuntimesCachesAndPendingDeletion() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory("Library/Developer/CoreSimulator/Devices")
        try fixture.createDirectory("Library/Developer/CoreSimulator/Caches")
        try fixture.createDirectory("Library/Developer/CoreSimulator/Temp/BackgroundDelete")
        try fixture.createDirectory(
            "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime"
        )

        let candidates = StorageSourceCatalog.detect(
            configuration: .init(homeDirectory: fixture.home)
        )
        let simulators = try #require(candidates.first { $0.id == .simulators })

        #expect(Set(simulators.roots.map(\.id)) == [
            "simulators.devices",
            "simulators.user-caches",
            "simulators.pending-deletion",
            "simulators.user-runtimes"
        ])
        #expect(simulators.roots.allSatisfy { !$0.path.contains("CoreSimulator/Volumes") })
    }

    @Test func catalogDiscoversDownloadedRuntimeBackingAssetsWithoutMountedVolumes() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let assets = try fixture.createDirectory("AssetsV2")
        let ios = try fixture.createDirectory(
            "AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"
        )
        let watchOS = try fixture.createDirectory(
            "AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime"
        )
        _ = try fixture.createDirectory("AssetsV2/com_apple_MobileAsset_Unrelated")

        let roots = StorageSourceCatalog.simulatorRuntimeAssetRoots(at: assets)

        #expect(Set(roots.map(\.path)) == Set([ios.path, watchOS.path]))
        #expect(roots.allSatisfy { $0.defaultCategory == "模拟器运行时" })
        #expect(roots.allSatisfy { $0.isProtected })
        #expect(roots.allSatisfy { !$0.path.contains("CoreSimulator/Volumes") })
    }

    @Test func simulatorScanKeepsDeviceDataRuntimeAndCachesInDistinctPhysicalGroups() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writePropertyList(
            "Library/Developer/CoreSimulator/Devices/DEVICE-ONE/device.plist",
            value: [
                "name": "iPhone 16 Pro",
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                "state": 3
            ]
        )
        try fixture.writeFile(
            "Library/Developer/CoreSimulator/Devices/DEVICE-ONE/data/Containers/Data/Application/app.db",
            byteCount: 12_288
        )
        try fixture.writePropertyList(
            "Library/Developer/CoreSimulator/Devices/DEVICE-TWO/device.plist",
            value: [
                "name": "iPad Pro 13-inch (M4)",
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                "state": 1
            ]
        )
        try fixture.writeFile(
            "Library/Developer/CoreSimulator/Devices/DEVICE-TWO/data/device-data.bin",
            byteCount: 4_096
        )
        try fixture.writePropertyList(
            "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.5.simruntime/Contents/Info.plist",
            value: [
                "CFBundleName": "iOS 18.5",
                "CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
            ]
        )
        try fixture.writeFile(
            "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.5.simruntime/Contents/Resources/runtime.dmg",
            byteCount: 16_384
        )
        try fixture.writeFile("Library/Developer/CoreSimulator/Caches/cache.bin")
        try fixture.writeFile(
            "Library/Developer/CoreSimulator/Temp/BackgroundDelete/stale-device.bin"
        )
        let fixtureDeviceMetadata = try #require(SimulatorStorageMetadata.device(
            at: fixture.home.appending(
                path: "Library/Developer/CoreSimulator/Devices/DEVICE-ONE",
                directoryHint: .isDirectory
            ),
            identifier: "DEVICE-ONE"
        ))
        #expect(fixtureDeviceMetadata.title == "iPhone 16 Pro")

        let snapshot = try await StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home)
        ).scan()
        let simulators = try #require(snapshot.result(for: .simulators))
        let categories = Set(simulators.components.map(\.title))

        #expect(categories.contains("模拟器设备"))
        #expect(categories.contains("模拟器应用数据"))
        #expect(categories.contains("模拟器运行时"))
        #expect(categories.contains("模拟器缓存"))
        #expect(categories.contains("模拟器待删除数据"))
        #expect(Set(simulators.resourceTree.map(\.id)) == [
            "simulators.devices",
            "simulators.runtimes",
            "simulators.user-caches",
            "simulators.pending-deletion"
        ])
        let devices = try #require(simulators.resourceTree.first { $0.id == "simulators.devices" })
        #expect(Set(devices.children.map(\.title)) == ["iPhone 16 Pro", "iPad Pro 13-inch (M4)"])
        let phone = try #require(devices.children.first { $0.title == "iPhone 16 Pro" })
        #expect(phone.detail == "iOS 18.5 · 已启动")
        #expect(phone.allocatedBytes > 0)
        guard case .simulatorDevice("DEVICE-ONE") = phone.cleanupTarget else {
            Issue.record("Expected simulator device deletion to use simctl")
            return
        }
        let runtimes = try #require(simulators.resourceTree.first { $0.id == "simulators.runtimes" })
        #expect(runtimes.children.map(\.title) == ["iOS 18.5"])
        #expect(runtimes.children.first?.detail == "用户安装")
        #expect(runtimes.children.first?.allocatedBytes ?? 0 > 0)
        guard case .simulatorRuntime(
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
            _,
            _
        ) = runtimes.children.first?.cleanupTarget else {
            Issue.record("Expected simulator runtime deletion to use simctl")
            return
        }
        #expect(simulators.resourceTree.first { $0.id == "simulators.user-caches" }?.children.count == 1)
        #expect(simulators.resourceTree.first { $0.id == "simulators.pending-deletion" }?.children.count == 1)
        #expect(simulators.components.allSatisfy {
            $0.rootPath?.contains("CoreSimulator/Volumes") != true
        })
    }

    @Test func downloadedSimulatorRuntimeUsesMobileAssetPlatformAndVersion() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let asset = try fixture.createDirectory(
            "AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/runtime.asset"
        )
        try fixture.writePropertyList(
            "AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/runtime.asset/Info.plist",
            value: [
                "CFBundleIdentifier": "com.apple.MobileAsset.iOSSimulatorRuntime",
                "MobileAssetProperties": [
                    "Build": "23E254a",
                    "SimulatorVersion": "26.4.1"
                ]
            ]
        )

        let metadata = try #require(
            SimulatorStorageMetadata.runtime(at: asset, identifier: "runtime.asset")
        )

        #expect(metadata.title == "iOS 26.4.1")
    }

    @Test func repositoryDiscoveryStopsAtTopLevelAndGroupsWorktrees() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let main = try fixture.createDirectory("code/main")
        let git = try fixture.createDirectory("code/main/.git")
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appending(path: "HEAD"))
        _ = try fixture.createDirectory("code/main/vendor/nested/.git")
        let worktreeGit = try fixture.createDirectory("code/main/.git/worktrees/feature")
        try Data("../..\n".utf8).write(to: worktreeGit.appending(path: "commondir"))
        try Data("ref: refs/heads/feature\n".utf8).write(to: worktreeGit.appending(path: "HEAD"))
        let worktree = try fixture.createDirectory("code/feature")
        try Data("gitdir: \(worktreeGit.path)\n".utf8)
            .write(to: worktree.appending(path: ".git"))

        let locations = CodeRepositoryDiscovery(
            homeDirectory: fixture.home,
            searchRoots: [fixture.home]
        ).discover()

        #expect(locations.count == 2)
        let mainLocation = try #require(locations.first { $0.path == main.path })
        let worktreeLocation = try #require(locations.first { $0.path == worktree.path })
        #expect(mainLocation.context.kind == .repository)
        #expect(mainLocation.context.branch == "main")
        #expect(worktreeLocation.context.kind == .worktree)
        #expect(worktreeLocation.context.branch == "feature")
        #expect(worktreeLocation.context.parentPath == main.path)
        #expect(worktreeLocation.context.groupID == mainLocation.context.groupID)
        #expect(locations.contains { $0.path.hasSuffix("/vendor/nested") } == false)
    }

    @Test func repositoryDiscoveryKeepsHiddenRepositoriesWithoutWalkingHiddenToolData() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let hiddenRepository = try fixture.createDirectory(".dotfiles")
        _ = try fixture.createDirectory(".dotfiles/.git")
        _ = try fixture.createDirectory(".tool-data/cache/dependency/.git")

        let locations = CodeRepositoryDiscovery(
            homeDirectory: fixture.home,
            searchRoots: [fixture.home]
        ).discover()

        #expect(locations.map(\.path) == [hiddenRepository.path])
    }

    @Test func repositoryDiscoveryIncludesAuthorizedPrivacyProtectedFolders() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let repository = try fixture.createDirectory("Downloads/project")
        _ = try fixture.createDirectory("Downloads/project/.git")

        let locations = CodeRepositoryDiscovery(
            homeDirectory: fixture.home,
            searchRoots: [fixture.home],
            includesPrivacyProtectedLocations: true
        ).discover()

        #expect(locations.map(\.path) == [repository.path])
    }

    @Test func workspaceScanMeasuresEachTopLevelRepositoryAsOneAggregate() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory("Downloads/code/project/.git")
        try fixture.writeFile("Downloads/code/project/Sources/App.swift", byteCount: 8_192)
        try fixture.writeFile("Downloads/code/project/node_modules/package/index.js", byteCount: 16_384)

        let snapshot = try await StorageAnalyzer(configuration: .init(
            homeDirectory: fixture.home,
            repositorySearchRoots: [fixture.home]
        )).scan(sourceID: .workspace)
        let workspace = try #require(snapshot.result(for: .workspace))

        #expect(workspace.entryCount == 1)
        #expect(workspace.resourceTree.count == 1)
        #expect(workspace.resourceTree.first?.entryCount == 1)
        #expect(workspace.resourceTree.first?.children.count == 1)
        #expect(workspace.resourceTree.first?.children.first?.entryCount == 1)
        #expect(workspace.allocatedBytes > 0)
    }

    @Test func workspaceScanGroupsRepositoriesByParentAndKeepsMainRepositoryCleanup() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.createDirectory("Downloads/code/alpha/.git")
        try fixture.createDirectory("Downloads/code/beta/.git")
        try fixture.writeFile("Downloads/code/alpha/Sources/App.swift", byteCount: 8_192)
        try fixture.writeFile("Downloads/code/beta/Sources/App.swift", byteCount: 4_096)

        let snapshot = try await StorageAnalyzer(configuration: .init(
            homeDirectory: fixture.home,
            repositorySearchRoots: [fixture.home]
        )).scan(sourceID: .workspace)
        let workspace = try #require(snapshot.result(for: .workspace))
        let parent = try #require(workspace.resourceTree.first)

        #expect(parent.title == "code")
        #expect(parent.detail?.contains("code") == true)
        #expect(parent.children.map(\.title) == ["alpha", "beta"])
        #expect(parent.children.allSatisfy { node in
            if case .trashRepository = node.cleanupTarget { return true }
            return false
        })
    }

    @Test func automaticRepositoryDiscoveryAttemptsReadableProtectedAndExternalLocationsWithoutAuthorization() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let ordinaryRepository = try fixture.createDirectory("code/ordinary")
        _ = try fixture.createDirectory("code/ordinary/.git")
        _ = try fixture.createDirectory("Downloads/private/.git")
        let external = FileManager.default.temporaryDirectory
            .appending(path: "FindDiskKiller-ExternalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: external.appending(path: "repository/.git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: external) }

        let locations = CodeRepositoryDiscovery(
            homeDirectory: fixture.home,
            mountedVolumeURLs: [external],
            includesPrivacyProtectedLocations: false
        ).discover()

        #expect(Set(locations.map(\.path)) == Set([
            ordinaryRepository.path,
            fixture.home.appending(path: "Downloads/private").path,
            external.appending(path: "repository").path
        ]))
    }

    @Test func automaticRepositoryDiscoveryIncludesProtectedAndExternalLocationsAfterAuthorization() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let protectedRepository = try fixture.createDirectory("Downloads/project")
        _ = try fixture.createDirectory("Downloads/project/.git")
        let external = FileManager.default.temporaryDirectory
            .appending(path: "FindDiskKiller-ExternalTests-\(UUID().uuidString)")
        let externalRepository = external.appending(path: "repository")
        try FileManager.default.createDirectory(
            at: externalRepository.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: external) }

        let locations = CodeRepositoryDiscovery(
            homeDirectory: fixture.home,
            mountedVolumeURLs: [external],
            includesPrivacyProtectedLocations: true
        ).discover()

        #expect(Set(locations.map(\.path)) == Set([
            protectedRepository.path,
            externalRepository.path
        ]))
    }

    @Test func dockerInventoryUsesUniqueImageBytesAndProtectsActiveObjects() throws {
        let data = Data(#"{"Images":[{"ID":"sha256:image","Repository":"example/app","Tag":"latest","Containers":"2","Size":"3GB","SharedSize":"1GB","UniqueSize":"2GB","VirtualSize":"3GB"}],"Containers":[{"ID":"running","Names":"web","Image":"example/app:latest","State":"running","Status":"Up 1 hour","Size":"12MB"},{"ID":"stopped","Names":"worker","Image":"example/app:latest","State":"exited","Status":"Exited","Size":"4MB"}],"Volumes":[{"Name":"data","Links":"0","Size":"512MB"}],"BuildCache":[{"ID":"cache","Description":"compile","Size":"64MB","InUse":"false","LastUsedSince":"1 day ago"}]}"#.utf8)

        let groups = try DockerStorageInspector.parse(
            data,
            imageReferencesByID: [
                "sha256:image": ["example/app:latest"]
            ]
        )
        let images = try #require(groups.first { $0.kind == .dockerImages })
        let image = try #require(images.children.first)
        let containers = try #require(groups.first { $0.kind == .dockerContainers })
        let running = try #require(containers.children.first { $0.id.hasSuffix("running") })
        let stopped = try #require(containers.children.first { $0.id.hasSuffix("stopped") })
        let volumes = try #require(groups.first { $0.kind == .dockerVolumes })

        #expect(image.allocatedBytes == 2_000_000_000)
        #expect(image.logicalBytes == 3_000_000_000)
        #expect(image.cleanupTarget == nil)
        #expect(running.cleanupTarget == nil)
        #expect(stopped.cleanupTarget == .dockerContainer(id: "stopped"))
        #expect(volumes.children.first?.cleanupTarget == .dockerVolume(name: "data"))
    }

    @Test func dockerInventoryAcceptsModernReportsAndDeduplicatesImageTags() throws {
        let data = Data(#"{"Images":[{"ID":"sha256:dangling","Repository":"<none>","Tag":"<none>","Containers":"0","Size":"3GB","SharedSize":"1GB","UniqueSize":"2GB"},{"ID":"sha256:tagged","Repository":"example/app","Tag":"latest","Containers":"0","Size":"900MB","SharedSize":"100MB","UniqueSize":"800MB"},{"ID":"sha256:tagged","Repository":"example/app","Tag":"stable","Containers":"0","Size":"900MB","SharedSize":"100MB","UniqueSize":"800MB"}],"Containers":[],"Volumes":[{"Name":"unused","Links":"0","Size":"512MB"},{"Name":"unknown","Links":"N/A","Size":"64MB"}],"BuildCache":[]}"#.utf8)

        let groups = try DockerStorageInspector.parse(
            data,
            imageReferencesByID: [
                "sha256:dangling": [],
                "sha256:tagged": ["example/app:latest", "example/app:stable"]
            ]
        )
        let images = try #require(groups.first { $0.kind == .dockerImages })
        let dangling = try #require(images.children.first { $0.id.hasSuffix("sha256:dangling") })
        let tagged = try #require(images.children.first { $0.id.hasSuffix("sha256:tagged") })
        let volumes = try #require(groups.first { $0.kind == .dockerVolumes })

        #expect(images.children.count == 2)
        #expect(images.allocatedBytes == 2_800_000_000)
        #expect(dangling.risk == .rebuildableCache)
        #expect(dangling.cleanupTarget == .dockerImage(id: "sha256:dangling"))
        #expect(tagged.allocatedBytes == 800_000_000)
        #expect(tagged.logicalBytes == 900_000_000)
        #expect(tagged.detail?.contains("2 个仓库引用") == true)
        #expect(volumes.children.first { $0.title == "unused" }?.cleanupTarget == .dockerVolume(name: "unused"))
        #expect(volumes.children.first { $0.title == "unknown" }?.cleanupTarget == nil)
    }

    @Test func dockerInventoryUsesInspectReferencesForDigestOnlyImages() throws {
        let data = Data(#"{"Images":[{"ID":"sha256:digest-only","Repository":"<none>","Tag":"<none>","Containers":"0","Size":"3GB","SharedSize":"1GB","UniqueSize":"2GB"}],"Containers":[],"Volumes":[],"BuildCache":[]}"#.utf8)

        let groups = try DockerStorageInspector.parse(
            data,
            imageReferencesByID: [
                "sha256:digest-only": [
                    "mirror.example/library/app@sha256:digest-only",
                    "registry.example/library/app@sha256:digest-only"
                ]
            ]
        )
        let images = try #require(groups.first { $0.kind == .dockerImages })
        let image = try #require(images.children.first)

        #expect(image.risk == .environmentOrRuntime)
        #expect(image.cleanupTarget == .dockerImage(id: "sha256:digest-only"))
        #expect(image.detail?.contains("2 个仓库引用") == true)
    }

    @Test func dockerInventoryDoesNotOfferRemovalWhenInspectReferencesAreUnavailable() throws {
        let data = Data(#"{"Images":[{"ID":"sha256:unknown","Repository":"<none>","Tag":"<none>","Containers":"0","Size":"3GB","SharedSize":"1GB","UniqueSize":"2GB"}],"Containers":[],"Volumes":[],"BuildCache":[]}"#.utf8)

        let groups = try DockerStorageInspector.parse(data)
        let images = try #require(groups.first { $0.kind == .dockerImages })
        let image = try #require(images.children.first)

        #expect(image.risk == .environmentOrRuntime)
        #expect(image.cleanupTarget == nil)
    }

    @Test func dockerInventoryFallbackKeepsObjectListsWhenCapacityReportFails() throws {
        let envelope = try DockerStorageInspector.makeFallbackEnvelope(
            images: Data(#"""
            {"ID":"sha256:dangling","Repository":"example/app","Tag":"latest","Size":"2GB","Containers":"0"}
            {"ID":"sha256:used","Repository":"example/used","Tag":"latest","Size":"3GB","Containers":"1"}
            """#.utf8),
            containers: Data(#"{"ID":"container-1","Names":"worker","Image":"example/used:latest","State":"exited","Status":"Exited","Size":"8MB"}"#.utf8),
            volumes: Data(#"{"Name":"cache","Links":"0"}"#.utf8)
        )

        let groups = try DockerStorageInspector.parseFallback(envelope)
        let images = try #require(groups.first { $0.kind == .dockerImages })
        let containers = try #require(groups.first { $0.kind == .dockerContainers })
        let volumes = try #require(groups.first { $0.kind == .dockerVolumes })

        #expect(images.children.count == 2)
        #expect(images.children.first { $0.title == "example/app:latest" }?.cleanupTarget == .dockerImage(id: "sha256:dangling"))
        #expect(containers.children.first?.cleanupTarget == .dockerContainer(id: "container-1"))
        #expect(volumes.children.first?.title == "cache")
    }

    @Test func podmanInventoryFallbackParsesImageContainerAndVolumeLists() async throws {
        let envelope = try DockerStorageInspector.makeFallbackEnvelope(
            images: Data(#"[{"Id":"podman-image","Names":["example/app:latest"],"Repository":"example/app","Tag":"latest","Size":"2GB","Containers":0}]"#.utf8),
            containers: Data(#"[{"Id":"podman-container","Names":["worker"],"Image":"example/app:latest","State":"exited","Status":"Exited","Size":"8MB"}]"#.utf8),
            volumes: Data(#"[{"Name":"cache"}]"#.utf8)
        )
        let inspector = PodmanStorageInspector(
            runner: { throw DockerStorageInspectorError.unavailable },
            fallbackRunner: { envelope }
        )

        let inventory = await inspector.inspect()
        let images = try #require(inventory.nodes.first { $0.kind == .dockerImages })
        let containers = try #require(inventory.nodes.first { $0.kind == .dockerContainers })
        let volumes = try #require(inventory.nodes.first { $0.kind == .dockerVolumes })

        #expect(images.children.first?.title == "example/app:latest")
        #expect(images.children.first?.cleanupTarget == .dockerImage(id: "podman-image"))
        #expect(containers.children.first?.cleanupTarget == .dockerContainer(id: "podman-container"))
        #expect(volumes.children.first?.title == "cache")
    }

    @Test func catalogReadsDockerDesktopConfiguredDataFolder() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let configuredData = try fixture.createDirectory("External/DockerDesktop")
        try fixture.writeFile("External/DockerDesktop/Docker.raw")
        let settings = try fixture.createDirectory("Library/Group Containers/group.com.docker")
            .appending(path: "settings-store.json")
        try JSONSerialization.data(withJSONObject: ["DataFolder": configuredData.path])
            .write(to: settings)

        let candidates = StorageSourceCatalog.detect(
            configuration: .init(homeDirectory: fixture.home)
        )
        let docker = try #require(candidates.first { $0.id == .docker })

        #expect(docker.roots.contains { $0.path == configuredData.path && $0.kind == .directory })
        #expect(docker.roots.contains {
            $0.path == configuredData.appending(path: "Docker.raw").path && $0.kind == .file
        })
    }

    @Test func catalogDeduplicatesDockerDataFolderAliasesByPhysicalIdentity() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let configuredData = try fixture.createDirectory("External/DockerDesktop")
        try fixture.writeFile("External/DockerDesktop/Docker.raw")
        let alias = fixture.home.appending(path: "DockerAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: configuredData)
        let settings = try fixture.createDirectory("Library/Group Containers/group.com.docker")
            .appending(path: "settings-store.json")
        try JSONSerialization.data(withJSONObject: ["DataFolder": alias.path]).write(to: settings)
        let legacySettings = settings.deletingLastPathComponent().appending(path: "settings.json")
        try JSONSerialization.data(withJSONObject: ["dataFolder": configuredData.path])
            .write(to: legacySettings)

        let candidates = StorageSourceCatalog.detect(
            configuration: .init(homeDirectory: fixture.home)
        )
        let docker = try #require(candidates.first { $0.id == .docker })

        #expect(docker.roots.filter { $0.kind == .directory }.count == 1)
        #expect(docker.roots.filter { $0.kind == .file }.count == 1)
    }

    @Test func scanAttributesConfiguredDockerDataFolderToItsVolume() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let externalMount = try fixture.createDirectory("External")
        let configuredData = try fixture.createDirectory("External/DockerDesktop")
        try fixture.writeFile("External/DockerDesktop/Docker.raw")
        let settings = try fixture.createDirectory("Library/Group Containers/group.com.docker")
            .appending(path: "settings-store.json")
        try JSONSerialization.data(withJSONObject: ["DataFolder": configuredData.path])
            .write(to: settings)
        let systemVolume = VolumeInfo(
            id: "system",
            name: "System",
            mountPath: fixture.home.path,
            totalCapacity: 10_000_000,
            availableCapacity: 8_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: false,
            physicalDiskBSDNames: []
        )
        let externalVolume = VolumeInfo(
            id: "external",
            name: "JianDisk",
            mountPath: externalMount.path,
            totalCapacity: 20_000_000,
            availableCapacity: 12_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: true,
            physicalDiskBSDNames: []
        )

        let snapshot = try await StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home),
            sourceStartHook: { _ in },
            volumeProvider: { [systemVolume, externalVolume] }
        ).scan()
        let docker = try #require(snapshot.result(for: .docker))
        let external = try #require(snapshot.volumes.first { $0.id == externalVolume.id })
        let system = try #require(snapshot.volumes.first { $0.id == systemVolume.id })

        #expect(docker.allocatedBytes > 0)
        #expect(external.sourceUsages.first { $0.sourceID == .docker }?.allocatedBytes == docker.allocatedBytes)
        #expect(system.sourceUsages.contains { $0.sourceID == .docker } == false)
    }

    @Test func scanDeduplicatesHardlinksAndConservesAllocatedBytes() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let cache = try fixture.createDirectory(".npm")
        let original = cache.appending(path: "package.tgz")
        try Data(repeating: 0xA5, count: 32 * 1_024).write(to: original)
        try FileManager.default.linkItem(
            at: original,
            to: cache.appending(path: "package-hardlink.tgz")
        )

        let snapshot = try await StorageAnalyzer(configuration: .init(homeDirectory: fixture.home)).scan()
        let npm = try #require(snapshot.result(for: .npm))

        #expect(npm.entryCount == 2)
        #expect(snapshot.measuredEntryCount == 2)
        let assigned = snapshot.results.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        #expect(assigned + snapshot.conflictBytes == snapshot.totalAllocatedBytes)
    }

    @Test func scanAssignsMeasuredSourcesToTheTouchedVolume() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile(".npm/cache.bin")
        let recorder = StorageProgressRecorder()
        let volume = VolumeInfo(
            id: "fixture-volume",
            name: "Fixture Disk",
            mountPath: fixture.home.path,
            totalCapacity: 10_000_000,
            availableCapacity: 8_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: false,
            physicalDiskBSDNames: []
        )
        let analyzer = StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home),
            sourceStartHook: { _ in },
            volumeProvider: { [volume] in [volume] }
        )

        let snapshot = try await analyzer.scan { update in
            recorder.append(update)
        }
        let npm = try #require(snapshot.result(for: .npm))
        let mappedVolume = try #require(snapshot.volumes.first)
        let liveVolumes = recorder.allValues()
            .filter { $0.phase == .measuring && $0.sourceID == .npm }
            .compactMap { $0.volumes.first { $0.id == volume.id } }

        #expect(mappedVolume.id == volume.id)
        #expect(mappedVolume.sourceUsages == [
            StorageVolumeSourceUsage(sourceID: .npm, allocatedBytes: npm.allocatedBytes)
        ])
        #expect(liveVolumes.first?.analyzedBytes == 0)
        #expect(liveVolumes.last?.analyzedBytes == npm.allocatedBytes)
        #expect((liveVolumes.last?.otherBytes ?? .max) < (liveVolumes.first?.otherBytes ?? 0))
    }

    @Test func scanKeepsMountedVolumesWithoutKnownSourceUsage() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile(".npm/cache.bin")
        let systemVolume = VolumeInfo(
            id: "system-volume",
            name: "System",
            mountPath: fixture.home.path,
            totalCapacity: 10_000_000,
            availableCapacity: 8_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: false,
            physicalDiskBSDNames: []
        )
        let externalVolume = VolumeInfo(
            id: "external-volume",
            name: "External",
            mountPath: fixture.home.appending(path: "External").path,
            totalCapacity: 20_000_000,
            availableCapacity: 12_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: true,
            physicalDiskBSDNames: []
        )
        let analyzer = StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home),
            sourceStartHook: { _ in },
            volumeProvider: { [systemVolume, externalVolume] in
                [systemVolume, externalVolume]
            }
        )

        let snapshot = try await analyzer.scan()
        let external = try #require(snapshot.volumes.first { $0.id == externalVolume.id })

        #expect(Set(snapshot.volumes.map(\.id)) == Set([systemVolume.id, externalVolume.id]))
        #expect(external.sourceUsages.isEmpty)
        #expect(external.otherBytes == 8_000_000)
        #expect(external.availableCapacity == 12_000_000)
    }

    @Test func scanProgressReportsEachSourcesCurrentRootAndIndependentCounters() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile(".npm/cache.bin")
        try fixture.writeFile(".bun/install/cache/package.bin")
        let recorder = StorageProgressRecorder()

        _ = try await StorageAnalyzer(configuration: .init(homeDirectory: fixture.home)).scan { update in
            recorder.append(update)
        }

        let npm = try #require(recorder.latest(for: .npm))
        let bun = try #require(recorder.latest(for: .bun))
        #expect(npm.sourceCompleted)
        #expect(bun.sourceCompleted)
        #expect(npm.sourceProcessedEntryCount > 0)
        #expect(bun.sourceProcessedEntryCount > 0)
        #expect(npm.currentWork == "npm cache")
        #expect(bun.currentWork == "Bun package cache")
        #expect(npm.currentWorkIndex == 1)
        #expect(npm.totalWorkCount == 1)
        #expect(bun.currentWorkIndex == 1)
        #expect(bun.totalWorkCount == 1)
    }

    @Test func scanStartsEveryDetectedSourceWithoutWaitingForAFixedWorkerQueue() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile(".npm/cache.bin")
        try fixture.writeFile("Library/Caches/pip/http-v2/response.bin")
        try fixture.writeFile(".bun/install/cache/package.bin")
        try fixture.writeFile("Library/pnpm/store/package.bin")
        try fixture.writeFile("Library/Caches/go-build/object.bin")
        try fixture.writeFile("Library/Developer/CoreSimulator/Devices/device.bin")
        let expectedSourceIDs: Set<StorageSourceID> = [
            .go, .npm, .pnpm, .bun, .pip, .simulators
        ]
        let barrier = StorageSourceStartBarrier(expectedCount: expectedSourceIDs.count)
        let analyzer = StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home),
            sourceStartHook: { sourceID in barrier.arrive(sourceID) }
        )

        let snapshot = try await analyzer.scan()

        #expect(barrier.didOpen)
        #expect(barrier.startedSourceIDs == expectedSourceIDs)
        #expect(Set(snapshot.results.map(\.id)) == expectedSourceIDs)
    }

    @Test func scanPublishesAnImmediateActiveStateForEverySourceWorker() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile(".npm/cache.bin")
        try fixture.writeFile("Library/Caches/pip/http-v2/response.bin")
        try fixture.writeFile(".bun/install/cache/package.bin")
        let recorder = StorageProgressRecorder()

        _ = try await StorageAnalyzer(configuration: .init(homeDirectory: fixture.home)).scan {
            recorder.append($0)
        }

        for sourceID in [StorageSourceID.npm, .pip, .bun] {
            let first = try #require(
                recorder.allValues().first {
                    $0.phase == .measuring && $0.sourceID == sourceID
                }
            )
            #expect(!first.sourceCompleted)
        }
    }

    @Test func scanUsesTwoRootWorkersInsideEachSource() async throws {
        #expect(StorageAnalyzer.rootWorkerCountPerSource == 2)

        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.writeFile("Library/Caches/go-build/object.bin")
        try fixture.writeFile("go/bin/tool")
        let barrier = StorageRootStartBarrier(expectedCount: 2)
        let analyzer = StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home),
            sourceStartHook: { _ in },
            rootStartHook: { sourceID, rootID in
                guard sourceID == .go else { return }
                barrier.arrive(rootID)
            }
        )

        let snapshot = try await analyzer.scan()

        #expect(barrier.didOpen)
        #expect(barrier.startedRootIDs.count == 2)
        #expect(snapshot.result(for: .go)?.entryCount == 2)
    }

    @Test func scanMeasuresASymlinkWithoutFollowingItsTarget() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let cache = try fixture.createDirectory(".npm")
        let privateDirectory = try fixture.createDirectory("private-content")
        try Data(repeating: 0x3C, count: 2 * 1_024 * 1_024)
            .write(to: privateDirectory.appending(path: "should-not-be-read.bin"))
        try FileManager.default.createSymbolicLink(
            at: cache.appending(path: "linked-cache"),
            withDestinationURL: privateDirectory
        )

        let snapshot = try await StorageAnalyzer(configuration: .init(homeDirectory: fixture.home)).scan()
        let npm = try #require(snapshot.result(for: .npm))

        #expect(npm.entryCount == 2)
        #expect(npm.logicalBytes < 2 * 1_024 * 1_024)
    }

    @Test func scanResolvesASymlinkedSourceRootAndAttributesItsTargetVolume() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let externalRoot = try fixture.createDirectory("External")
        let npmTarget = try fixture.createDirectory("External/npm")
        try fixture.writeFile("External/npm/cache.bin")
        let privateDirectory = try fixture.createDirectory("private-content")
        try Data(repeating: 0x9D, count: 2 * 1_024 * 1_024)
            .write(to: privateDirectory.appending(path: "should-not-be-read.bin"))
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appending(path: ".npm"),
            withDestinationURL: npmTarget
        )
        try FileManager.default.createSymbolicLink(
            at: npmTarget.appending(path: "nested-link"),
            withDestinationURL: privateDirectory
        )
        let systemVolume = VolumeInfo(
            id: "system",
            name: "System",
            mountPath: fixture.home.path,
            totalCapacity: 10_000_000,
            availableCapacity: 8_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: false,
            physicalDiskBSDNames: []
        )
        let externalVolume = VolumeInfo(
            id: "external",
            name: "External",
            mountPath: externalRoot.path,
            totalCapacity: 20_000_000,
            availableCapacity: 12_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: true,
            physicalDiskBSDNames: []
        )

        let snapshot = try await StorageAnalyzer(
            configuration: .init(homeDirectory: fixture.home),
            sourceStartHook: { _ in },
            volumeProvider: { [systemVolume, externalVolume] }
        ).scan()
        let npm = try #require(snapshot.result(for: .npm))
        let external = try #require(snapshot.volumes.first { $0.id == externalVolume.id })

        #expect(npm.entryCount == 3)
        #expect(npm.logicalBytes < 2 * 1_024 * 1_024)
        #expect(external.sourceUsages == [
            StorageVolumeSourceUsage(sourceID: .npm, allocatedBytes: npm.allocatedBytes)
        ])
    }

    @Test func chromeScanAggregatesBrowserSemanticsWithoutExposingPaths() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }

        try fixture.writeFile(
            "Library/Application Support/Google/Chrome/Default/Extensions/example/manifest.json"
        )
        try fixture.writeFile(
            "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/content.bin"
        )
        try fixture.writeFile(
            "Library/Application Support/Google/Chrome/Default/History"
        )
        try fixture.writeFile(
            "Library/Caches/Google/Chrome/Default/Cache/cache.bin"
        )

        let snapshot = try await StorageAnalyzer(configuration: .init(homeDirectory: fixture.home)).scan()
        let chrome = try #require(snapshot.result(for: .chrome))
        let titles = Set(chrome.components.map(\.title))

        #expect(titles.contains("浏览器缓存"))
        #expect(titles.contains("扩展"))
        #expect(titles.contains("站点离线数据"))
        #expect(titles.contains("受保护浏览器数据"))
        #expect(chrome.components.allSatisfy { !$0.id.contains(fixture.home.path) })
        #expect(chrome.components.allSatisfy { !$0.rootDisplayName.contains(fixture.home.path) })
    }

    @Test func goScanSeparatesCachesModulesAndToolsWithoutListingModules() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }

        try fixture.writeFile("Library/Caches/go-build/ab/build-cache")
        try fixture.writeFile("go/pkg/mod/cache/download/example.org/module/@v/v1.0.0.zip")
        try fixture.writeFile("go/pkg/mod/example.org/module@v1.0.0/source.go")
        try fixture.writeFile(
            "go/pkg/mod/example.org/module@v1.0.0/internal/cache/data.bin",
            byteCount: 1_048_576
        )
        try fixture.writeFile("go/bin/gopls")

        let snapshot = try await StorageAnalyzer(configuration: .init(homeDirectory: fixture.home)).scan()
        let go = try #require(snapshot.result(for: .go))
        let titles = Set(go.components.map(\.title))

        #expect(titles.contains("构建缓存"))
        #expect(titles.contains("模块下载缓存"))
        #expect(titles.contains("已解压模块"))
        #expect(titles.contains("已安装工具"))
        #expect(go.entryCount == 4)
        #expect(go.components.first { $0.title == "已解压模块" }?.allocatedBytes ?? 0 >= 1_048_576)
        #expect(go.components.allSatisfy { !$0.id.contains("example.org") })
        #expect(go.components.allSatisfy { !$0.rootDisplayName.contains("example.org") })
    }
}

private final class StorageProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StorageScanProgress] = []

    func append(_ value: StorageScanProgress) {
        lock.withLock { values.append(value) }
    }

    func latest(for sourceID: StorageSourceID) -> StorageScanProgress? {
        lock.withLock { values.last { $0.sourceID == sourceID } }
    }

    func allValues() -> [StorageScanProgress] {
        lock.withLock { values }
    }
}

private final class StorageCandidateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StorageSourceID] = []

    func append(_ candidate: StorageSourceCandidate) {
        lock.withLock { values.append(candidate.id) }
    }

    var sourceIDs: [StorageSourceID] {
        lock.withLock { values }
    }
}

private final class StorageSourceStartBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedCount: Int
    private var sourceIDs = Set<StorageSourceID>()
    private var opened = false
    private var timedOut = false

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func arrive(_ sourceID: StorageSourceID) {
        condition.lock()
        sourceIDs.insert(sourceID)
        if sourceIDs.count == expectedCount {
            opened = true
            condition.broadcast()
        } else {
            let deadline = Date().addingTimeInterval(2)
            while !opened {
                guard condition.wait(until: deadline) else {
                    timedOut = true
                    break
                }
            }
        }
        condition.unlock()
    }

    var didOpen: Bool {
        condition.withLock { opened && !timedOut }
    }

    var startedSourceIDs: Set<StorageSourceID> {
        condition.withLock { sourceIDs }
    }
}

private final class StorageRootStartBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedCount: Int
    private var rootIDs = Set<String>()
    private var opened = false
    private var timedOut = false

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func arrive(_ rootID: String) {
        condition.lock()
        rootIDs.insert(rootID)
        if rootIDs.count == expectedCount {
            opened = true
            condition.broadcast()
        } else {
            let deadline = Date().addingTimeInterval(2)
            while !opened {
                guard condition.wait(until: deadline) else {
                    timedOut = true
                    break
                }
            }
        }
        condition.unlock()
    }

    var didOpen: Bool {
        condition.withLock { opened && !timedOut }
    }

    var startedRootIDs: Set<String> {
        condition.withLock { rootIDs }
    }
}

private extension NSCondition {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private struct StorageFixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "FindDiskKiller-StorageAnalyzerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
    }

    @discardableResult
    func createDirectory(_ relativePath: String) throws -> URL {
        let url = home.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeFile(_ relativePath: String, byteCount: Int = 4_096) throws {
        let url = home.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: byteCount).write(to: url)
    }

    func writePropertyList(_ relativePath: String, value: Any) throws {
        let url = home.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}
