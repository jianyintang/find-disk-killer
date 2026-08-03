import CryptoKit
import Darwin
import FindDiskKillerNodeRuntime
import Foundation

enum ClaudeNodeRuntimeError: LocalizedError, Equatable {
    case downloadFailed(String)
    case checksumMismatch
    case extractionFailed(String)
    case validationFailed(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason): L10n.format("Node.js 运行时下载失败：%@", reason)
        case .checksumMismatch: L10n.text("Node.js 运行时校验失败，已放弃安装")
        case .extractionFailed(let reason): L10n.format("Node.js 运行时解压失败：%@", reason)
        case .validationFailed(let reason): L10n.format("Node.js 运行时验证失败：%@", reason)
        case .installationFailed(let reason): L10n.format("Node.js 运行时安装失败：%@", reason)
        }
    }
}

enum ClaudeNodeRuntimeProvisioningPhase: Equatable, Sendable {
    case downloading
    case verifying
    case installing
}

struct ClaudeNodeRuntimeDownload: Sendable {
    let statusCode: Int
    let data: Data
}

protocol ClaudeNodeRuntimeInstallLock: Sendable {
    func unlock()
}

protocol ClaudeNodeRuntimeInstallTransaction: Sendable {
    func commit() throws
    func rollback() throws
}

struct ClaudeNodeRuntimeDependencies: @unchecked Sendable {
    var resolver: NodeRuntimeResolverDependencies
    var download: @Sendable (URL) async throws -> ClaudeNodeRuntimeDownload
    var checksum: @Sendable (URL) throws -> String
    var extract: @Sendable (URL, String, URL) throws -> Void
    var acquireLock: @Sendable (URL) throws -> any ClaudeNodeRuntimeInstallLock
    var beginAtomicInstall: @Sendable (URL, URL) throws -> any ClaudeNodeRuntimeInstallTransaction

    static let live = Self(
        resolver: .live,
        download: { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: url)
            return ClaudeNodeRuntimeDownload(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                data: data
            )
        },
        checksum: ClaudeNodeRuntime.sha256Hex,
        extract: ClaudeNodeRuntime.extractNodeBinary,
        acquireLock: { try ClaudeNodeRuntimeFileLock(url: $0) },
        beginAtomicInstall: { try ClaudeNodeRuntimeAtomicInstall(source: $0, destination: $1) }
    )
}

/// Locates or provisions the Node.js runtime that executes the bundled
/// official Claude Agent SDK.
enum ClaudeNodeRuntime {
    static let pinnedVersion = "24.14.1"
    static let minimumSupportedMajor = 20

    enum Architecture: String, CaseIterable, Sendable {
        case arm64
        case x64

        var expectedSHA256: String {
            switch self {
            case .arm64: "25495ff85bd89e2d8a24d88566d7e2f827c6b0d3d872b2cebf75371f93fcb1fe"
            case .x64: "2526230ad7d922be82d4fdb1e7ee1e84303e133e3b4b0ec4c2897ab31de0253d"
            }
        }
    }

    static func currentArchitecture() -> Architecture {
        #if arch(arm64)
        return .arm64
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0,
           translated == 1 {
            return .arm64
        }
        return .x64
        #endif
    }

    static func archiveName(for architecture: Architecture) -> String {
        "node-v\(pinnedVersion)-darwin-\(architecture.rawValue)"
    }

    static func downloadURL(for architecture: Architecture) -> URL {
        URL(string: "https://nodejs.org/dist/v\(pinnedVersion)/\(archiveName(for: architecture)).tar.gz")!
    }

    static func downloadedBinaryURL(
        for architecture: Architecture,
        applicationSupport: URL = defaultApplicationSupportRoot()
    ) -> URL {
        applicationSupport
            .appending(path: "AgentCleanup/node-v\(pinnedVersion)-\(architecture.rawValue)/node")
    }

    static func defaultApplicationSupportRoot() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support"))
            .appending(path: "FindDiskKiller", directoryHint: .isDirectory)
    }

    static func isCompatibleVersion(_ output: String) -> Bool {
        guard let version = NodeSemanticVersion(string: output, requiresVPrefix: true) else { return false }
        return version.major >= minimumSupportedMajor
    }

    static func resolutionContext(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledRuntimePath: String? = bundledRuntimePath(),
        applicationSupport: URL = defaultApplicationSupportRoot(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        architecture: Architecture = currentArchitecture()
    ) -> NodeRuntimeResolutionContext {
        NodeRuntimeResolutionContext(
            environment: environment,
            bundledRuntimePath: bundledRuntimePath,
            downloadedRuntimePath: downloadedBinaryURL(
                for: architecture,
                applicationSupport: applicationSupport
            ).path,
            homeDirectory: homeDirectory,
            minimumMajor: minimumSupportedMajor
        )
    }

    static func resolvedExistingRuntime(
        context: NodeRuntimeResolutionContext? = nil,
        dependencies: NodeRuntimeResolverDependencies = .live
    ) throws -> ValidatedNodeRuntime? {
        try NodeRuntimeResolver.resolve(
            context: context ?? resolutionContext(),
            dependencies: dependencies
        )
    }

    static func existingRuntime(
        context: NodeRuntimeResolutionContext? = nil,
        dependencies: NodeRuntimeResolverDependencies = .live
    ) -> String? {
        try? resolvedExistingRuntime(context: context, dependencies: dependencies)?.path
    }

    static func ensureAvailable(
        onPhase: @escaping @Sendable (ClaudeNodeRuntimeProvisioningPhase) -> Void = { _ in }
    ) async throws -> String {
        try await ensureResolved(onPhase: onPhase).path
    }

    static func ensureResolved(
        onPhase: @escaping @Sendable (ClaudeNodeRuntimeProvisioningPhase) -> Void = { _ in }
    ) async throws -> ValidatedNodeRuntime {
        try await provisioner.ensure(
            context: resolutionContext(),
            dependencies: .live,
            onPhase: onPhase
        )
    }

    private static let provisioner = Provisioner()

    actor Provisioner {
        private var inFlight: Task<ValidatedNodeRuntime, Error>?

        func ensure(
            context: NodeRuntimeResolutionContext,
            dependencies: ClaudeNodeRuntimeDependencies,
            onPhase: @escaping @Sendable (ClaudeNodeRuntimeProvisioningPhase) -> Void = { _ in }
        ) async throws -> ValidatedNodeRuntime {
            try Task.checkCancellation()
            if let inFlight {
                let runtime = try await inFlight.value
                try Task.checkCancellation()
                return runtime
            }
            if let existing = try NodeRuntimeResolver.resolve(
                context: context,
                dependencies: dependencies.resolver
            ) {
                return existing
            }

            let task = Task.detached {
                try await ClaudeNodeRuntime.downloadPinnedRuntime(
                    context: context,
                    dependencies: dependencies,
                    onPhase: onPhase
                )
            }
            inFlight = task
            defer { inFlight = nil }
            let runtime = try await task.value
            try Task.checkCancellation()
            return runtime
        }
    }

    static func bundledRuntimePath() -> String? {
        Bundle.main.resourceURL?.appending(path: "AgentCleanup/node").path
    }

    static func measuredVersionOutput(of binary: String) -> String? {
        guard case .completed(let status, let stdout, _) = NodeRuntimeProcessProbe.run(path: binary, timeout: 4),
              status == 0
        else { return nil }
        return stdout
    }

    static func downloadPinnedRuntime(
        context: NodeRuntimeResolutionContext,
        dependencies: ClaudeNodeRuntimeDependencies,
        onPhase: @escaping @Sendable (ClaudeNodeRuntimeProvisioningPhase) -> Void
    ) async throws -> ValidatedNodeRuntime {
        let destination = URL(fileURLWithPath: context.downloadedRuntimePath)
        let cleanupRoot = destination.deletingLastPathComponent().deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)

        let lock: any ClaudeNodeRuntimeInstallLock
        do {
            lock = try await Task.detached {
                try dependencies.acquireLock(cleanupRoot.appending(path: ".node-install.lock"))
            }.value
        } catch {
            throw ClaudeNodeRuntimeError.installationFailed(L10n.errorDescription(error))
        }
        defer { lock.unlock() }

        cleanupAbandonedStaging(in: cleanupRoot, fileManager: fileManager)
        if let installed = try? NodeRuntimeResolver.validate(
            path: destination.path,
            source: .downloaded,
            minimumMajor: context.minimumMajor,
            timeout: context.timeout,
            dependencies: dependencies.resolver
        ) {
            return installed
        }

        let stage = cleanupRoot.appending(
            path: ".node-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }

        try Task.checkCancellation()
        onPhase(.downloading)
        let architecture = currentArchitecture()
        let payload: ClaudeNodeRuntimeDownload
        do {
            payload = try await dependencies.download(downloadURL(for: architecture))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeNodeRuntimeError.downloadFailed(L10n.errorDescription(error))
        }
        guard payload.statusCode == 200 else {
            throw ClaudeNodeRuntimeError.downloadFailed("HTTP \(payload.statusCode)")
        }
        try Task.checkCancellation()
        let archive = stage.appending(path: "runtime.tar.gz")
        try payload.data.write(to: archive, options: .atomic)

        onPhase(.verifying)
        guard try dependencies.checksum(archive) == architecture.expectedSHA256 else {
            throw ClaudeNodeRuntimeError.checksumMismatch
        }
        try Task.checkCancellation()

        let extracted = stage.appending(path: "extracted", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
        do {
            try dependencies.extract(
                archive,
                "\(archiveName(for: architecture))/bin/node",
                extracted
            )
        } catch let error as ClaudeNodeRuntimeError {
            throw error
        } catch {
            throw ClaudeNodeRuntimeError.extractionFailed(L10n.errorDescription(error))
        }
        let staged = extracted.appending(path: "node")
        guard fileManager.fileExists(atPath: staged.path) else {
            throw ClaudeNodeRuntimeError.extractionFailed(L10n.text("归档中缺少 node 可执行文件"))
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        do {
            _ = try NodeRuntimeResolver.validate(
                path: staged.path,
                source: .downloaded,
                minimumMajor: context.minimumMajor,
                timeout: context.timeout,
                dependencies: dependencies.resolver
            )
        } catch {
            throw ClaudeNodeRuntimeError.validationFailed(String(describing: error))
        }
        try Task.checkCancellation()

        onPhase(.installing)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transaction: any ClaudeNodeRuntimeInstallTransaction
        do {
            transaction = try dependencies.beginAtomicInstall(staged, destination)
        } catch {
            throw ClaudeNodeRuntimeError.installationFailed(L10n.errorDescription(error))
        }
        do {
            let installed = try NodeRuntimeResolver.validate(
                path: destination.path,
                source: .downloaded,
                minimumMajor: context.minimumMajor,
                timeout: context.timeout,
                dependencies: dependencies.resolver
            )
            try transaction.commit()
            return installed
        } catch {
            try? transaction.rollback()
            if let failure = error as? NodeRuntimeValidationFailure {
                throw ClaudeNodeRuntimeError.validationFailed(failure.description)
            }
            throw ClaudeNodeRuntimeError.installationFailed(L10n.errorDescription(error))
        }
    }

    static func cleanupAbandonedStaging(in root: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".node-staging-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    static func extractNodeBinary(archive: URL, member: String, into stage: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-xzf", archive.path,
            "-C", stage.path,
            "--strip-components", "2",
            member
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw ClaudeNodeRuntimeError.extractionFailed(L10n.errorDescription(error))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeNodeRuntimeError.extractionFailed(
                detail.isEmpty ? L10n.text("tar 退出码非零") : detail
            )
        }
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ClaudeNodeRuntimeFileLock: ClaudeNodeRuntimeInstallLock, @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var isLocked = true

    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
    }

    func unlock() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isLocked else { return }
        isLocked = false
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { unlock() }
}

private final class ClaudeNodeRuntimeAtomicInstall: ClaudeNodeRuntimeInstallTransaction, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let replacedExisting: Bool
    private let stateLock = NSLock()
    private var isActive = true

    init(source: URL, destination: URL) throws {
        self.source = source
        self.destination = destination
        var info = stat()
        replacedExisting = lstat(destination.path, &info) == 0
        let result = replacedExisting
            ? renamex_np(source.path, destination.path, UInt32(RENAME_SWAP))
            : rename(source.path, destination.path)
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func commit() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive else { return }
        if replacedExisting { try FileManager.default.removeItem(at: source) }
        isActive = false
    }

    func rollback() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive else { return }
        let result = replacedExisting
            ? renamex_np(source.path, destination.path, UInt32(RENAME_SWAP))
            : rename(destination.path, source.path)
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        isActive = false
    }

    deinit { try? rollback() }
}
