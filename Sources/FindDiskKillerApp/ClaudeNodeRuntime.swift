import CryptoKit
import Foundation

enum ClaudeNodeRuntimeError: LocalizedError {
    case downloadFailed(String)
    case checksumMismatch
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason): L10n.format("Node.js 运行时下载失败：%@", reason)
        case .checksumMismatch: L10n.text("Node.js 运行时校验失败，已放弃安装")
        case .extractionFailed(let reason): L10n.format("Node.js 运行时解压失败：%@", reason)
        }
    }
}

/// Locates or provisions the Node.js runtime that executes the bundled
/// official Claude Agent SDK. The runtime is not shipped inside the app
/// bundle: a compatible local installation is reused when present, otherwise
/// the pinned official build for the current hardware architecture is
/// downloaded once from nodejs.org, verified against a hard-coded SHA-256,
/// and stored under Application Support.
enum ClaudeNodeRuntime {
    static let pinnedVersion = "24.14.1"
    static let minimumSupportedMajor = 20

    enum Architecture: String, CaseIterable {
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

    /// Parses `node --version` output such as `v24.14.1` and decides whether
    /// the runtime is recent enough for the bundled SDK.
    static func isCompatibleVersion(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("v"),
              let major = Int(trimmed.dropFirst().prefix(while: { $0.isNumber })),
              major > 0
        else { return false }
        return major >= minimumSupportedMajor
    }

    /// Candidate locations for an already usable runtime, in resolution
    /// order. The same order is mirrored by FindDiskKillerClaudeCleanupHelper
    /// so that direct helper invocations resolve identically.
    static func existingRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledRuntimePath: String? = bundledRuntimePath(),
        applicationSupport: URL = defaultApplicationSupportRoot(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        versionOutput: (String) -> String? = { measuredVersionOutput(of: $0) }
    ) -> String? {
        if let override = environment["FDK_NODE_BINARY"], isExecutable(override) {
            return override
        }
        if let bundled = bundledRuntimePath, isExecutable(bundled) {
            return bundled
        }
        let downloaded = downloadedBinaryURL(
            for: currentArchitecture(),
            applicationSupport: applicationSupport
        ).path
        if isExecutable(downloaded) {
            return downloaded
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let commonDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        for directory in pathDirectories + commonDirectories {
            let candidate = URL(fileURLWithPath: directory).appending(path: "node").path
            guard isExecutable(candidate) else { continue }
            guard let version = versionOutput(candidate), isCompatibleVersion(version) else { continue }
            return candidate
        }
        return nil
    }

    /// Returns a usable Node.js binary path, downloading the pinned official
    /// build when nothing suitable is installed. Concurrent callers share one
    /// provisioning task.
    static func ensureAvailable() async throws -> String {
        try await provisioner.ensure()
    }

    private static let provisioner = Provisioner()

    private actor Provisioner {
        private var inFlight: Task<String, Error>?

        func ensure() async throws -> String {
            if let existing = ClaudeNodeRuntime.existingRuntime() { return existing }
            if let inFlight { return try await inFlight.value }
            let task = Task { try await ClaudeNodeRuntime.downloadPinnedRuntime() }
            inFlight = task
            defer { inFlight = nil }
            return try await task.value
        }
    }

    static func bundledRuntimePath() -> String? {
        Bundle.main.resourceURL?.appending(path: "AgentCleanup/node").path
    }

    static func measuredVersionOutput(of binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func downloadPinnedRuntime() async throws -> String {
        let architecture = currentArchitecture()
        let destination = downloadedBinaryURL(for: architecture)
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: destination.path) { return destination.path }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let archiveURL: URL
        do {
            let (temporary, response) = try await session.download(from: downloadURL(for: architecture))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ClaudeNodeRuntimeError.downloadFailed("HTTP \(status)")
            }
            archiveURL = temporary
        } catch let error as ClaudeNodeRuntimeError {
            throw error
        } catch {
            throw ClaudeNodeRuntimeError.downloadFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: archiveURL) }

        guard try sha256Hex(of: archiveURL) == architecture.expectedSHA256 else {
            throw ClaudeNodeRuntimeError.checksumMismatch
        }

        let stage = fileManager.temporaryDirectory
            .appending(path: "fdk-node-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        try extractNodeBinary(
            archive: archiveURL,
            member: "\(archiveName(for: architecture))/bin/node",
            into: stage
        )
        let staged = stage.appending(path: "node")
        guard fileManager.isExecutableFile(atPath: staged.path) else {
            throw ClaudeNodeRuntimeError.extractionFailed(L10n.text("归档中缺少 node 可执行文件"))
        }

        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staged, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination.path
    }

    private static func extractNodeBinary(archive: URL, member: String, into stage: URL) throws {
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
            throw ClaudeNodeRuntimeError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeNodeRuntimeError.extractionFailed(detail.isEmpty ? L10n.text("tar 退出码非零") : detail)
        }
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
