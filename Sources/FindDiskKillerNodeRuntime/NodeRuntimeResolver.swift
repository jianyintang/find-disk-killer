import Darwin
import Foundation

public struct NodeSemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(string: String, requiresVPrefix: Bool = false) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresVPrefix, !trimmed.hasPrefix("v") { return nil }
        let value = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var nodeOutput: String { "v\(major).\(minor).\(patch)" }
}

public enum NodeRuntimeSource: Equatable, Sendable {
    case environmentOverride
    case legacyBundled
    case downloaded
    case system
}

public struct ValidatedNodeRuntime: Equatable, Sendable {
    public let path: String
    public let version: NodeSemanticVersion
    public let source: NodeRuntimeSource

    public init(path: String, version: NodeSemanticVersion, source: NodeRuntimeSource) {
        self.path = path
        self.version = version
        self.source = source
    }
}

public enum NodeVersionProbeResult: Equatable, Sendable {
    case completed(status: Int32, stdout: String, stderr: String)
    case failedToLaunch(String)
    case timedOut
}

public enum NodeRuntimeValidationFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case notRegularFile
    case notExecutable
    case failedToLaunch(String)
    case timedOut
    case nonzeroExit(Int32, String)
    case invalidVersion(String)
    case unsupportedVersion(String, minimumMajor: Int)

    public var description: String {
        switch self {
        case .notRegularFile: "路径不是普通文件"
        case .notExecutable: "文件没有可执行权限"
        case .failedToLaunch(let reason): "无法启动（\(reason)）"
        case .timedOut: "执行 node --version 超时"
        case .nonzeroExit(let status, let detail):
            detail.isEmpty ? "node --version 退出码为 \(status)" : "node --version 退出码为 \(status)：\(detail)"
        case .invalidVersion(let output): "版本输出无效（\(output.isEmpty ? "无输出" : output)）"
        case .unsupportedVersion(let version, let minimumMajor):
            "Node.js \(version) 版本过低，需要 Node.js \(minimumMajor) 或更高版本"
        }
    }
}

public enum NodeRuntimeResolutionError: Error, Equatable, Sendable, LocalizedError {
    case invalidEnvironmentOverride(path: String, reason: NodeRuntimeValidationFailure)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironmentOverride(let path, let reason):
            "FDK_NODE_BINARY 指定的 Node.js 无法使用：\(path)（\(reason.description)）。请修正或移除该环境变量。"
        }
    }
}

public struct NodeRuntimeFileStatus: Sendable {
    public let isRegularFile: Bool
    public let isExecutable: Bool

    public init(isRegularFile: Bool, isExecutable: Bool) {
        self.isRegularFile = isRegularFile
        self.isExecutable = isExecutable
    }
}

public struct NodeRuntimeResolverDependencies: @unchecked Sendable {
    public var fileStatus: (String) -> NodeRuntimeFileStatus
    public var directoryNames: (URL) -> [String]
    public var probeVersion: (String, TimeInterval) -> NodeVersionProbeResult

    public init(
        fileStatus: @escaping (String) -> NodeRuntimeFileStatus,
        directoryNames: @escaping (URL) -> [String],
        probeVersion: @escaping (String, TimeInterval) -> NodeVersionProbeResult
    ) {
        self.fileStatus = fileStatus
        self.directoryNames = directoryNames
        self.probeVersion = probeVersion
    }

    public static let live = Self(
        fileStatus: { path in
            var info = stat()
            let isRegular = stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            return NodeRuntimeFileStatus(
                isRegularFile: isRegular,
                isExecutable: isRegular && access(path, X_OK) == 0
            )
        },
        directoryNames: { url in
            (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        },
        probeVersion: NodeRuntimeProcessProbe.run
    )
}

public struct NodeRuntimeResolutionContext: Sendable {
    public var environment: [String: String]
    public var bundledRuntimePath: String?
    public var downloadedRuntimePath: String
    public var homeDirectory: URL
    public var minimumMajor: Int
    public var timeout: TimeInterval

    public init(
        environment: [String: String],
        bundledRuntimePath: String?,
        downloadedRuntimePath: String,
        homeDirectory: URL,
        minimumMajor: Int,
        timeout: TimeInterval = 4
    ) {
        self.environment = environment
        self.bundledRuntimePath = bundledRuntimePath
        self.downloadedRuntimePath = downloadedRuntimePath
        self.homeDirectory = homeDirectory
        self.minimumMajor = minimumMajor
        self.timeout = timeout
    }
}

public enum NodeRuntimeResolver {
    public static func resolve(
        context: NodeRuntimeResolutionContext,
        dependencies: NodeRuntimeResolverDependencies = .live
    ) throws -> ValidatedNodeRuntime? {
        if let override = context.environment["FDK_NODE_BINARY"] {
            do {
                return try validate(
                    path: override,
                    source: .environmentOverride,
                    minimumMajor: context.minimumMajor,
                    timeout: context.timeout,
                    dependencies: dependencies
                )
            } catch let failure as NodeRuntimeValidationFailure {
                throw NodeRuntimeResolutionError.invalidEnvironmentOverride(path: override, reason: failure)
            }
        }

        var candidates: [(String, NodeRuntimeSource)] = []
        if let bundled = context.bundledRuntimePath { candidates.append((bundled, .legacyBundled)) }
        candidates.append((context.downloadedRuntimePath, .downloaded))
        candidates.append(contentsOf: systemCandidatePaths(
            environment: context.environment,
            homeDirectory: context.homeDirectory,
            directoryNames: dependencies.directoryNames
        ).map { ($0, .system) })

        var seen = Set<String>()
        for (path, source) in candidates where seen.insert(path).inserted {
            if let runtime = try? validate(
                path: path,
                source: source,
                minimumMajor: context.minimumMajor,
                timeout: context.timeout,
                dependencies: dependencies
            ) {
                return runtime
            }
        }
        return nil
    }

    public static func validate(
        path: String,
        source: NodeRuntimeSource,
        minimumMajor: Int,
        timeout: TimeInterval = 4,
        dependencies: NodeRuntimeResolverDependencies = .live
    ) throws -> ValidatedNodeRuntime {
        let status = dependencies.fileStatus(path)
        guard status.isRegularFile else { throw NodeRuntimeValidationFailure.notRegularFile }
        guard status.isExecutable else { throw NodeRuntimeValidationFailure.notExecutable }

        let output: String
        switch dependencies.probeVersion(path, timeout) {
        case .failedToLaunch(let reason): throw NodeRuntimeValidationFailure.failedToLaunch(reason)
        case .timedOut: throw NodeRuntimeValidationFailure.timedOut
        case .completed(let status, let stdout, let stderr):
            guard status == 0 else {
                throw NodeRuntimeValidationFailure.nonzeroExit(
                    status,
                    stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let version = NodeSemanticVersion(string: output, requiresVPrefix: true) else {
            throw NodeRuntimeValidationFailure.invalidVersion(output)
        }
        guard version.major >= minimumMajor else {
            throw NodeRuntimeValidationFailure.unsupportedVersion(output, minimumMajor: minimumMajor)
        }
        return ValidatedNodeRuntime(path: path, version: version, source: source)
    }

    public static func systemCandidatePaths(
        environment: [String: String],
        homeDirectory: URL,
        directoryNames: (URL) -> [String]
    ) -> [String] {
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).appending(path: "node").path }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/local/bin/node",
            homeDirectory.appending(path: ".volta/bin/node").path
        ])

        paths.append(contentsOf: versionedPaths(
            root: homeDirectory.appending(path: ".nvm/versions/node", directoryHint: .isDirectory),
            suffix: "bin/node",
            directoryNames: directoryNames
        ))
        for root in [
            homeDirectory.appending(path: ".local/share/fnm/node-versions", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".fnm/node-versions", directoryHint: .isDirectory)
        ] {
            paths.append(contentsOf: versionedPaths(
                root: root,
                suffix: "installation/bin/node",
                directoryNames: directoryNames
            ))
        }
        for root in [
            homeDirectory.appending(path: ".local/share/mise/installs/node", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".mise/installs/node", directoryHint: .isDirectory)
        ] {
            paths.append(contentsOf: versionedPaths(root: root, suffix: "bin/node", directoryNames: directoryNames))
        }
        paths.append(homeDirectory.appending(path: ".asdf/shims/node").path)
        paths.append(contentsOf: versionedPaths(
            root: homeDirectory.appending(path: ".asdf/installs/nodejs", directoryHint: .isDirectory),
            suffix: "bin/node",
            directoryNames: directoryNames
        ))
        paths.append(homeDirectory.appending(path: ".local/bin/node").path)

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func versionedPaths(
        root: URL,
        suffix: String,
        directoryNames: (URL) -> [String]
    ) -> [String] {
        directoryNames(root)
            .compactMap { name -> (String, NodeSemanticVersion)? in
                guard let version = NodeSemanticVersion(string: name) else { return nil }
                return (name, version)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0 < $1.0
            }
            .map { root.appending(path: $0.0).appending(path: suffix).path }
    }
}

public enum NodeRuntimeProcessProbe {
    public static func run(path: String, timeout: TimeInterval) -> NodeVersionProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            return .failedToLaunch(error.localizedDescription)
        }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            return .timedOut
        }
        return .completed(
            status: process.terminationStatus,
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
