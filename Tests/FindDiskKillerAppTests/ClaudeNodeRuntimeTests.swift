import FindDiskKillerNodeRuntime
import Foundation
import Testing
@testable import FindDiskKillerApp

@Suite("Claude Node runtime resolution")
struct ClaudeNodeRuntimeTests {
    @Test func versionGateAcceptsSupportedStableMajorsOnly() {
        #expect(ClaudeNodeRuntime.isCompatibleVersion("v24.14.1\n"))
        #expect(ClaudeNodeRuntime.isCompatibleVersion("v20.0.0"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("v18.20.4"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("24.14.1"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("v24.14.1-rc.1"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("version unknown"))
    }

    @Test func downloadTargetsMatchPinnedOfficialBuilds() {
        #expect(ClaudeNodeRuntime.downloadURL(for: .arm64).absoluteString
            == "https://nodejs.org/dist/v24.14.1/node-v24.14.1-darwin-arm64.tar.gz")
        #expect(ClaudeNodeRuntime.downloadURL(for: .x64).absoluteString
            == "https://nodejs.org/dist/v24.14.1/node-v24.14.1-darwin-x64.tar.gz")
        for architecture in ClaudeNodeRuntime.Architecture.allCases {
            #expect(architecture.expectedSHA256.count == 64)
            #expect(architecture.expectedSHA256.allSatisfy { $0.isHexDigit })
        }
    }

    @Test func outdatedEnvironmentOverrideIsAnActionableError() {
        let path = "/configured/node"
        let dependencies = syntheticResolver(files: [path: .completed(status: 0, stdout: "v18.20.4", stderr: "")])
        do {
            _ = try NodeRuntimeResolver.resolve(
                context: context(environment: ["FDK_NODE_BINARY": path]),
                dependencies: dependencies
            )
            Issue.record("Expected an invalid override error")
        } catch let error as NodeRuntimeResolutionError {
            guard case .invalidEnvironmentOverride(let rejected, let reason) = error else {
                Issue.record("Unexpected resolution error")
                return
            }
            #expect(rejected == path)
            #expect(reason == .unsupportedVersion("v18.20.4", minimumMajor: 20))
            #expect(error.localizedDescription.contains("请修正或移除"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unlaunchableEnvironmentOverrideIsAnActionableError() {
        let path = "/configured/node"
        let dependencies = syntheticResolver(files: [path: .failedToLaunch("Exec format error")])
        do {
            _ = try NodeRuntimeResolver.resolve(
                context: context(environment: ["FDK_NODE_BINARY": path]),
                dependencies: dependencies
            )
            Issue.record("Expected an invalid override error")
        } catch let error as NodeRuntimeResolutionError {
            #expect(error.localizedDescription.contains("无法启动"))
            #expect(error.localizedDescription.contains("FDK_NODE_BINARY"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func timedOutOverrideIsRejected() {
        let path = "/configured/node"
        let dependencies = syntheticResolver(files: [path: .timedOut])
        #expect(throws: NodeRuntimeResolutionError.self) {
            try NodeRuntimeResolver.resolve(
                context: context(environment: ["FDK_NODE_BINARY": path]),
                dependencies: dependencies
            )
        }
    }

    @Test func corruptDownloadedRuntimeDoesNotBlockSystemNode() throws {
        let downloaded = "/support/downloaded/node"
        let system = "/path/bin/node"
        let dependencies = syntheticResolver(files: [
            downloaded: .completed(status: 126, stdout: "", stderr: "damaged"),
            system: .completed(status: 0, stdout: "v22.11.0", stderr: "")
        ])
        let resolved = try NodeRuntimeResolver.resolve(
            context: context(
                environment: ["PATH": "/path/bin"],
                downloadedRuntimePath: downloaded
            ),
            dependencies: dependencies
        )
        #expect(resolved?.path == system)
        #expect(resolved?.source == .system)
    }

    @Test func finderEnvironmentWithoutNVMInPathStillFindsNVMNode() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let root = home.appending(path: ".nvm/versions/node")
        let node = root.appending(path: "v24.14.1/bin/node").path
        let dependencies = syntheticResolver(
            files: [node: .completed(status: 0, stdout: "v24.14.1", stderr: "")],
            directories: [root.path: ["v18.20.4", "v24.14.1"]]
        )
        let resolved = try NodeRuntimeResolver.resolve(
            context: context(environment: ["PATH": "/usr/bin:/bin"], home: home),
            dependencies: dependencies
        )
        #expect(resolved?.path == node)
    }

    @Test func versionManagerPriorityIsStable() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let volta = home.appending(path: ".volta/bin/node").path
        let nvmRoot = home.appending(path: ".nvm/versions/node")
        let nvm = nvmRoot.appending(path: "v24.14.1/bin/node").path
        let fnmRoot = home.appending(path: ".local/share/fnm/node-versions")
        let fnm = fnmRoot.appending(path: "v25.1.0/installation/bin/node").path
        let dependencies = syntheticResolver(
            files: [
                volta: .completed(status: 0, stdout: "v20.12.2", stderr: ""),
                nvm: .completed(status: 0, stdout: "v24.14.1", stderr: ""),
                fnm: .completed(status: 0, stdout: "v25.1.0", stderr: "")
            ],
            directories: [nvmRoot.path: ["v24.14.1"], fnmRoot.path: ["v25.1.0"]]
        )
        let first = try NodeRuntimeResolver.resolve(
            context: context(environment: ["PATH": ""], home: home),
            dependencies: dependencies
        )
        let second = try NodeRuntimeResolver.resolve(
            context: context(environment: ["PATH": ""], home: home),
            dependencies: dependencies
        )
        #expect(first?.path == volta)
        #expect(second == first)
    }

    @Test func versionDirectoriesUseSemanticDescendingOrder() {
        let home = URL(fileURLWithPath: "/Users/example")
        let nvmRoot = home.appending(path: ".nvm/versions/node")
        let paths = NodeRuntimeResolver.systemCandidatePaths(
            environment: ["PATH": ""],
            homeDirectory: home,
            directoryNames: { url in
                url.path == nvmRoot.path
                    ? ["v9.10.0", "v24.2.0", "v20.11.1", "v24.14.1", "lts"]
                    : []
            }
        )
        let nvmPaths = paths.filter { $0.contains("/.nvm/") }
        #expect(nvmPaths.map { URL(fileURLWithPath: $0).pathComponents.dropLast(2).last! }
            == ["v24.14.1", "v24.2.0", "v20.11.1", "v9.10.0"])
    }

    @Test func downloadedBinaryLivesUnderApplicationSupport() {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support/FindDiskKiller")
        #expect(ClaudeNodeRuntime.downloadedBinaryURL(for: .arm64, applicationSupport: support).path
            == "/Users/example/Library/Application Support/FindDiskKiller/AgentCleanup/node-v24.14.1-arm64/node")
    }

    @Test func checksumMismatchNeverInstalls() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        var dependencies = fixture.dependencies()
        dependencies.checksum = { _ in String(repeating: "0", count: 64) }

        await expectRuntimeError(.checksumMismatch) {
            try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(fixture.stagingNames().isEmpty)
    }

    @Test func HTTPFailureNeverCreatesAnInstallation() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        var dependencies = fixture.dependencies()
        dependencies.download = { _ in ClaudeNodeRuntimeDownload(statusCode: 503, data: Data()) }

        await expectRuntimeError(.downloadFailed("HTTP 503")) {
            try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func archiveMissingNodeNeverInstalls() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        var dependencies = fixture.dependencies()
        dependencies.extract = { _, _, _ in }

        do {
            _ = try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
            Issue.record("Expected extraction failure")
        } catch let error as ClaudeNodeRuntimeError {
            guard case .extractionFailed = error else {
                Issue.record("Unexpected runtime error: \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func stagedRuntimeValidationFailurePreservesOldRuntime() async throws {
        let fixture = try InstallFixture(oldContents: "old")
        defer { fixture.destroy() }
        let dependencies = fixture.dependencies(probe: { path in
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
            return contents == "new"
                ? .completed(status: 0, stdout: "not-a-version", stderr: "")
                : .completed(status: 0, stdout: "v18.0.0", stderr: "")
        })

        do {
            _ = try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
            Issue.record("Expected staged validation failure")
        } catch let error as ClaudeNodeRuntimeError {
            guard case .validationFailed = error else {
                Issue.record("Unexpected runtime error: \(error)")
                return
            }
        }
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "old")
    }

    @Test func postInstallValidationFailureRollsBackOldRuntime() async throws {
        let fixture = try InstallFixture(oldContents: "old")
        defer { fixture.destroy() }
        let destinationProbeCount = LockedCounter()
        let dependencies = fixture.dependencies(probe: { path in
            if path == fixture.destination.path {
                let count = destinationProbeCount.increment()
                return count == 1
                    ? .completed(status: 0, stdout: "v18.0.0", stderr: "")
                    : .completed(status: 0, stdout: "broken", stderr: "")
            }
            return .completed(status: 0, stdout: "v24.14.1", stderr: "")
        })

        do {
            _ = try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
            Issue.record("Expected post-install validation failure")
        } catch let error as ClaudeNodeRuntimeError {
            guard case .validationFailed = error else {
                Issue.record("Unexpected runtime error: \(error)")
                return
            }
        }
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "old")
    }

    @Test func atomicReplacementFailurePreservesOldRuntime() async throws {
        let fixture = try InstallFixture(oldContents: "old")
        defer { fixture.destroy() }
        var dependencies = fixture.dependencies()
        dependencies.beginAtomicInstall = { _, _ in throw TestFailure.expected }

        do {
            _ = try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
            Issue.record("Expected installation failure")
        } catch let error as ClaudeNodeRuntimeError {
            guard case .installationFailed = error else {
                Issue.record("Unexpected runtime error: \(error)")
                return
            }
        }
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "old")
    }

    @Test func concurrentEnsureOnOneProvisionerDownloadsOnce() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        let counter = LockedCounter()
        var dependencies = fixture.dependencies()
        dependencies.download = { _ in
            counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return ClaudeNodeRuntimeDownload(statusCode: 200, data: Data("archive".utf8))
        }

        async let first = fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
        async let second = fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
        let values = try await [first, second]
        #expect(values[0].path == fixture.destination.path)
        #expect(values[1].path == fixture.destination.path)
        #expect(counter.value == 1)
    }

    @Test func independentProvisionersCompetingForFileLockInstallOnce() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        let counter = LockedCounter()
        var dependencies = fixture.dependencies()
        dependencies.download = { _ in
            counter.increment()
            try await Task.sleep(for: .milliseconds(60))
            return ClaudeNodeRuntimeDownload(statusCode: 200, data: Data("archive".utf8))
        }
        let otherProcess = ClaudeNodeRuntime.Provisioner()

        async let first = fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
        async let second = otherProcess.ensure(context: fixture.context, dependencies: dependencies)
        _ = try await [first, second]
        #expect(counter.value == 1)
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "new")
    }

    @Test func cancellingCallerLeavesNoPartialInstallation() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        var dependencies = fixture.dependencies()
        dependencies.download = { _ in
            try await Task.sleep(for: .milliseconds(60))
            return ClaudeNodeRuntimeDownload(statusCode: 200, data: Data("archive".utf8))
        }
        let caller = Task {
            try await fixture.provisioner.ensure(context: fixture.context, dependencies: dependencies)
        }
        try await Task.sleep(for: .milliseconds(10))
        caller.cancel()
        do {
            _ = try await caller.value
            Issue.record("Cancelled caller should observe cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(fixture.stagingNames().isEmpty)
        if FileManager.default.fileExists(atPath: fixture.destination.path) {
            #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "new")
        }
    }

    @Test func abandonedStagingIsCleanedOnNextInstall() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }
        let abandoned = fixture.cleanupRoot.appending(path: ".node-staging-interrupted")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: abandoned.appending(path: "node"))

        _ = try await fixture.provisioner.ensure(
            context: fixture.context,
            dependencies: fixture.dependencies()
        )
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(fixture.stagingNames().isEmpty)
    }

    @Test func helperAndAppUseTheSameOverrideValidation() throws {
        let path = "/configured/node"
        let dependencies = syntheticResolver(files: [
            path: .completed(status: 0, stdout: "v18.0.0", stderr: "")
        ])
        #expect(throws: NodeRuntimeResolutionError.self) {
            try NodeRuntimeResolver.resolve(
                context: context(environment: ["FDK_NODE_BINARY": path]),
                dependencies: dependencies
            )
        }
        #expect(throws: NodeRuntimeValidationFailure.self) {
            try NodeRuntimeResolver.validate(
                path: path,
                source: .environmentOverride,
                minimumMajor: 20,
                dependencies: dependencies
            )
        }
    }

    @Test @MainActor func statusModelDoesNotExposeUnvalidatedRuntimeAsAvailable() async throws {
        let model = ClaudeNodeRuntimeStatusModel(probeOperation: { nil })
        model.refresh()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.phase == .missing)
    }

    @Test func statusSourceClassificationCoversEveryOrigin() {
        let downloadRoot = "/Users/example/Library/Application Support/FindDiskKiller/AgentCleanup"
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: "/tmp/override-node",
            environmentOverride: "/tmp/override-node",
            bundledPath: nil,
            downloadRoot: downloadRoot
        ) == .environmentOverride)
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: downloadRoot + "/node-v24.14.1-arm64/node",
            environmentOverride: nil,
            bundledPath: nil,
            downloadRoot: downloadRoot
        ) == .downloaded)
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: downloadRoot + "Backup/node",
            environmentOverride: nil,
            bundledPath: nil,
            downloadRoot: downloadRoot
        ) == .system)
    }
}

private func context(
    environment: [String: String] = ["PATH": ""],
    downloadedRuntimePath: String = "/downloaded/node",
    home: URL = URL(fileURLWithPath: "/Users/example")
) -> NodeRuntimeResolutionContext {
    NodeRuntimeResolutionContext(
        environment: environment,
        bundledRuntimePath: nil,
        downloadedRuntimePath: downloadedRuntimePath,
        homeDirectory: home,
        minimumMajor: 20
    )
}

private func syntheticResolver(
    files: [String: NodeVersionProbeResult],
    directories: [String: [String]] = [:]
) -> NodeRuntimeResolverDependencies {
    NodeRuntimeResolverDependencies(
        fileStatus: { path in
            NodeRuntimeFileStatus(
                isRegularFile: files[path] != nil,
                isExecutable: files[path] != nil
            )
        },
        directoryNames: { directories[$0.path] ?? [] },
        probeVersion: { path, _ in files[path] ?? .failedToLaunch("missing") }
    )
}

private final class InstallFixture: @unchecked Sendable {
    let root: URL
    let cleanupRoot: URL
    let destination: URL
    let context: NodeRuntimeResolutionContext
    let provisioner = ClaudeNodeRuntime.Provisioner()

    init(oldContents: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "fdk-node-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cleanupRoot = root.appending(path: "AgentCleanup", directoryHint: .isDirectory)
        destination = ClaudeNodeRuntime.downloadedBinaryURL(
            for: ClaudeNodeRuntime.currentArchitecture(),
            applicationSupport: root
        )
        context = ClaudeNodeRuntime.resolutionContext(
            environment: ["PATH": ""],
            bundledRuntimePath: nil,
            applicationSupport: root,
            homeDirectory: root
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let oldContents {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(oldContents.utf8).write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    func dependencies(
        probe: @escaping @Sendable (String) -> NodeVersionProbeResult = { path in
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .failedToLaunch("missing")
            }
            return contents == "new"
                ? .completed(status: 0, stdout: "v24.14.1", stderr: "")
                : .completed(status: 0, stdout: "v18.0.0", stderr: "")
        }
    ) -> ClaudeNodeRuntimeDependencies {
        let liveResolver = NodeRuntimeResolverDependencies.live
        var dependencies = ClaudeNodeRuntimeDependencies.live
        dependencies.resolver = NodeRuntimeResolverDependencies(
            fileStatus: { [root] path in
                guard path.hasPrefix(root.path + "/") else {
                    return NodeRuntimeFileStatus(isRegularFile: false, isExecutable: false)
                }
                return liveResolver.fileStatus(path)
            },
            directoryNames: { _ in [] },
            probeVersion: { path, _ in probe(path) }
        )
        dependencies.download = { _ in
            ClaudeNodeRuntimeDownload(statusCode: 200, data: Data("archive".utf8))
        }
        dependencies.checksum = { _ in
            ClaudeNodeRuntime.currentArchitecture().expectedSHA256
        }
        dependencies.extract = { _, _, directory in
            try Data("new".utf8).write(to: directory.appending(path: "node"))
        }
        return dependencies
    }

    func stagingNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cleanupRoot.path)) ?? [])
            .filter { $0.hasPrefix(".node-staging-") }
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        count += 1
        let result = count
        lock.unlock()
        return result
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private enum TestFailure: Error { case expected }

private func expectRuntimeError(
    _ expected: ClaudeNodeRuntimeError,
    operation: () async throws -> ValidatedNodeRuntime
) async {
    do {
        _ = try await operation()
        Issue.record("Expected runtime error")
    } catch let error as ClaudeNodeRuntimeError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
