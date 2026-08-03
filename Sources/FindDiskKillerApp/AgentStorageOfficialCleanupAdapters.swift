import Foundation
import FindDiskKillerCore

struct UnsupportedAgentCleanupAdapter: AgentStorageCleanupCapabilityProviding {
    func availability(for family: AgentStorageThreadFamily) async -> AgentStorageCleanupAvailability {
        .unsupported("此来源暂不支持安全清理")
    }

    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome {
        .failed("此来源暂不支持安全清理")
    }
}

struct OpenCodeCLIAdapter: AgentStorageCleanupCapabilityProviding {
    private let executableOverride: String?

    init(executableOverride: String? = nil) {
        self.executableOverride = executableOverride
    }

    func availability(for family: AgentStorageThreadFamily) async -> AgentStorageCleanupAvailability {
        guard family.sourceKind == .openCode else {
            return .unsupported("此 OpenCode 来源不支持安全清理")
        }
        guard OpenCodeDataDirectory.environment(for: family.sourcePath) != nil else {
            return .unsupported("OpenCode 数据目录不是官方默认目录")
        }
        guard let executable = executableOverride ?? OpenCodeExecutableLocator.locate() else {
            return .unsupported("未找到 OpenCode 官方清理命令")
        }
        do {
            let result = try await AgentCleanupProcess.run(
                executable: executable,
                arguments: ["--pure", "session", "delete", "--help"],
                timeoutSeconds: 4
            )
            guard result.status == 0 else {
                return .unsupported("当前 OpenCode 不支持官方 session 删除")
            }
            return .ready
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }

    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome {
        guard family.sourceKind == .openCode,
              let environment = OpenCodeDataDirectory.environment(for: family.sourcePath),
              let executable = executableOverride ?? OpenCodeExecutableLocator.locate()
        else { return .failed("OpenCode 官方清理入口已不可用") }

        let sessionIDs = family.subagents.map(\.nativeID) + [family.nativeThreadID]
        var deletedIDs = Set<String>()
        do {
            for sessionID in sessionIDs where deletedIDs.insert(sessionID).inserted {
                let result = try await AgentCleanupProcess.run(
                    executable: executable,
                    arguments: ["--pure", "session", "delete", sessionID],
                    environment: environment,
                    timeoutSeconds: 20
                )
                guard result.status == 0 || Self.isAlreadyAbsent(result) else {
                    return .failed(Self.failureMessage(from: result))
                }
            }
            let remainingIDs = try await Self.remainingSessionIDs(
                executable: executable,
                environment: environment,
                sessionIDs: Array(deletedIDs)
            )
            guard remainingIDs.isEmpty else {
                return .failed("OpenCode 未确认 session 已删除")
            }
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func remainingSessionIDs(
        executable: String,
        environment: [String: String],
        sessionIDs: [String]
    ) async throws -> Set<String> {
        let quotedIDs = sessionIDs.map {
            "'\($0.replacingOccurrences(of: "'", with: "''"))'"
        }.joined(separator: ",")
        let query = "SELECT id FROM session WHERE id IN (\(quotedIDs))"
        let result = try await AgentCleanupProcess.run(
            executable: executable,
            arguments: ["--pure", "db", "--format", "json", query],
            environment: environment,
            timeoutSeconds: 8
        )
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw AgentStorageCleanupError.invalidProtocol
        }
        return Set(rows.compactMap { $0["id"] as? String })
    }

    private static func isAlreadyAbsent(_ result: AgentCleanupProcess.Result) -> Bool {
        let output = (result.stdout + "\n" + result.stderr).lowercased()
        return output.contains("session not found")
            || output.contains("session does not exist")
            || output.contains("not found")
    }

    private static func failureMessage(from result: AgentCleanupProcess.Result) -> String {
        let message = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return message ?? "OpenCode 未确认 session 已删除"
    }
}

enum OpenCodeExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["FDK_OPENCODE_CLI"], isExecutable(override) {
            return override
        }
        let fileManager = FileManager.default
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "opencode").path }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let fixedCandidates = [
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "\(home)/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode"
        ]
        return (pathCandidates + fixedCandidates).first(where: isExecutable)
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

enum OpenCodeDataDirectory {
    static func environment(for sourcePath: String?) -> [String: String]? {
        guard let sourcePath else { return nil }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL
        guard source.lastPathComponent == "opencode" else { return nil }
        let dataHome = source.deletingLastPathComponent()
        guard dataHome.lastPathComponent == "share",
              dataHome.deletingLastPathComponent().lastPathComponent == ".local"
        else { return nil }
        return ["XDG_DATA_HOME": dataHome.path]
    }
}

struct CodexAppServerCleanupAdapter: AgentStorageCleanupCapabilityProviding {
    private let resolver: CodexCleanupRuntimeResolver

    init(executableOverride: String? = nil, requestTimeout: TimeInterval = 12) {
        if let executableOverride {
            resolver = CodexCleanupRuntimeResolver(
                candidateProvider: { CodexExecutableLocator.candidates(for: [executableOverride], origin: .override) },
                requestTimeout: requestTimeout
            )
        } else {
            resolver = CodexCleanupRuntimeResolver(requestTimeout: requestTimeout)
        }
    }

    init(candidatePaths: [String], requestTimeout: TimeInterval = 12) {
        resolver = CodexCleanupRuntimeResolver(
            candidateProvider: { CodexExecutableLocator.candidates(for: candidatePaths, origin: .override) },
            requestTimeout: requestTimeout
        )
    }

    func availability(for family: AgentStorageThreadFamily) async -> AgentStorageCleanupAvailability {
        guard family.sourceKind == .codexHome else {
            return .unsupported("此 Codex 来源不支持安全清理")
        }
        return await resolver.hasAvailableRuntime
            ? .ready
            : .unsupported("未找到 Codex 官方执行器")
    }

    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome {
        await resolver.delete(family)
    }

    func resetDetection() async {
        await resolver.resetDetection()
    }
}

struct CodexRuntimeCandidate: Hashable, Sendable {
    enum Origin: Int, Sendable {
        case override
        case path
        case homebrew
        case npm
        case nvm
        case fnm
        case volta
        case bun
        case application
    }

    let executablePath: String
    let canonicalPath: String
    let origin: Origin
    let device: UInt64
    let inode: UInt64
}

enum CodexExecutableLocator {
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        includeSystemLocations: Bool = true
    ) -> [CodexRuntimeCandidate] {
        let home = homeDirectory.standardizedFileURL
        var discovered: [(String, CodexRuntimeCandidate.Origin)] = []
        if let override = environment["FDK_CODEX_APP_SERVER"] {
            discovered.append((override, .override))
        }
        discovered += (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { (URL(fileURLWithPath: String($0)).appending(path: "codex").path, .path) }

        if includeSystemLocations {
            discovered += [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ].map { ($0, .homebrew) }
        }
        discovered += [
            home.appending(path: ".npm-global/bin/codex").path,
            home.appending(path: ".npm/bin/codex").path,
            home.appending(path: ".local/bin/codex").path,
            home.appending(path: "bin/codex").path
        ].map { ($0, .npm) }
        discovered += versionedCandidates(
            below: home.appending(path: ".nvm/versions/node"),
            suffix: "bin/codex"
        ).map { ($0, .nvm) }
        discovered += [
            home.appending(path: ".local/share/fnm/node-versions"),
            home.appending(path: ".fnm/node-versions")
        ].flatMap { versionedCandidates(below: $0, suffix: "installation/bin/codex") }
            .map { ($0, .fnm) }
        discovered.append((home.appending(path: ".volta/bin/codex").path, .volta))
        discovered.append((home.appending(path: ".bun/bin/codex").path, .bun))

        let appRoots = applicationDirectories ?? [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory)
        ]
        for root in appRoots {
            for appName in ["ChatGPT.app", "Codex.app"] {
                discovered.append((
                    root.appending(path: appName).appending(path: "Contents/Resources/codex").path,
                    .application
                ))
            }
        }

        return deduplicated(discovered)
    }

    static func candidates(
        for paths: [String],
        origin: CodexRuntimeCandidate.Origin
    ) -> [CodexRuntimeCandidate] {
        deduplicated(paths.map { ($0, origin) })
    }

    private static func versionedCandidates(below root: URL, suffix: String) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.map { $0.appending(path: suffix).path }
    }

    private static func deduplicated(
        _ paths: [(String, CodexRuntimeCandidate.Origin)]
    ) -> [CodexRuntimeCandidate] {
        let sorted = paths.sorted { lhs, rhs in
            lhs.1.rawValue == rhs.1.rawValue
                ? URL(fileURLWithPath: lhs.0).standardizedFileURL.path
                    < URL(fileURLWithPath: rhs.0).standardizedFileURL.path
                : lhs.1.rawValue < rhs.1.rawValue
        }
        var canonicalPaths = Set<String>()
        var fileIdentities = Set<CodexExecutableIdentity>()
        return sorted.compactMap { path, origin in
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let canonical = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath().standardizedFileURL.path
            var value = stat()
            guard stat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else { return nil }
            let identity = CodexExecutableIdentity(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino)
            )
            guard canonicalPaths.insert(canonical).inserted,
                  fileIdentities.insert(identity).inserted else { return nil }
            return CodexRuntimeCandidate(
                executablePath: standardized,
                canonicalPath: canonical,
                origin: origin,
                device: identity.device,
                inode: identity.inode
            )
        }
    }
}

private struct CodexExecutableIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

actor CodexCleanupRuntimeResolver {
    typealias CandidateProvider = @Sendable () -> [CodexRuntimeCandidate]

    private let candidateProvider: CandidateProvider
    private let requestTimeout: TimeInterval
    private var resolvedCandidates: [CodexRuntimeCandidate]?
    private var preferredIdentity: CodexExecutableIdentity?
    private var failedIdentities = Set<CodexExecutableIdentity>()
    private var failuresByIdentity: [CodexExecutableIdentity: CodexCleanupAttemptError] = [:]

    init(
        candidateProvider: @escaping CandidateProvider = { CodexExecutableLocator.locate() },
        requestTimeout: TimeInterval = 12
    ) {
        self.candidateProvider = candidateProvider
        self.requestTimeout = requestTimeout
    }

    var hasAvailableRuntime: Bool { !candidates().isEmpty }

    func resetDetection() {
        resolvedCandidates = nil
        preferredIdentity = nil
        failedIdentities.removeAll()
        failuresByIdentity.removeAll()
    }

    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome {
        guard family.sourceKind == .codexHome else {
            return .failed("此 Codex 来源不支持安全清理")
        }
        let available = candidates()
        guard !available.isEmpty else { return .failed("未找到 Codex 官方执行器") }
        var ordered = available
        if let preferredIdentity,
           let preferredIndex = ordered.firstIndex(where: { identity(of: $0) == preferredIdentity }) {
            let preferred = ordered.remove(at: preferredIndex)
            ordered.insert(preferred, at: 0)
        }
        let usable = ordered.filter { !failedIdentities.contains(identity(of: $0)) }
        guard !usable.isEmpty else {
            return .failed(CodexCleanupAttemptError.summary(Array(failuresByIdentity.values)))
        }

        var attemptFailures: [CodexCleanupAttemptError] = []
        for candidate in usable {
            let identity = identity(of: candidate)
            guard candidateIsUnchanged(candidate) else {
                let failure = CodexCleanupAttemptError.startup
                failedIdentities.insert(identity)
                failuresByIdentity[identity] = failure
                attemptFailures.append(failure)
                continue
            }
            do {
                try await CodexJSONRPCSession.delete(
                    executable: candidate.executablePath,
                    expectedHome: family.sourcePath,
                    threadID: family.nativeThreadID,
                    requestTimeout: requestTimeout
                )
                preferredIdentity = identity
                return .succeeded
            } catch let error as CodexCleanupAttemptError {
                if error.isSafetyRefusal { return .failed(error.localizedDescription) }
                failedIdentities.insert(identity)
                failuresByIdentity[identity] = error
                attemptFailures.append(error)
            } catch {
                let failure = CodexCleanupAttemptError.invalidResponse
                failedIdentities.insert(identity)
                failuresByIdentity[identity] = failure
                attemptFailures.append(failure)
            }
        }
        return .failed(CodexCleanupAttemptError.summary(attemptFailures))
    }

    private func candidates() -> [CodexRuntimeCandidate] {
        if let resolvedCandidates { return resolvedCandidates }
        let candidates = candidateProvider()
        resolvedCandidates = candidates
        return candidates
    }

    private func identity(of candidate: CodexRuntimeCandidate) -> CodexExecutableIdentity {
        CodexExecutableIdentity(device: candidate.device, inode: candidate.inode)
    }

    private func candidateIsUnchanged(_ candidate: CodexRuntimeCandidate) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: candidate.executablePath) else { return false }
        var value = stat()
        return stat(candidate.executablePath, &value) == 0
            && (value.st_mode & S_IFMT) == S_IFREG
            && UInt64(value.st_dev) == candidate.device
            && UInt64(value.st_ino) == candidate.inode
    }
}

private enum CodexCleanupAttemptError: LocalizedError, Sendable {
    case startup
    case homeMismatch
    case timedOut
    case invalidResponse
    case officialDeleteFailed
    case threadIdentityChanged

    var isSafetyRefusal: Bool {
        if case .threadIdentityChanged = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .startup: L10n.text("Codex 官方执行器启动失败")
        case .homeMismatch: L10n.text("Codex 官方服务的数据目录与扫描来源不一致")
        case .timedOut: L10n.text("Codex 官方清理服务响应超时")
        case .invalidResponse: L10n.text("Codex 官方服务返回了无效响应")
        case .officialDeleteFailed: L10n.text("Codex 官方删除调用失败")
        case .threadIdentityChanged: L10n.text("Codex 聊天身份或父子关系已变化")
        }
    }

    static func summary(_ failures: [Self]) -> String {
        let messages = failures.compactMap(\.errorDescription)
        let unique = messages.reduce(into: [String]()) { result, message in
            if !result.contains(message) { result.append(message) }
        }
        guard unique.count > 1 else {
            return unique.first ?? L10n.text("Codex 官方删除调用失败")
        }
        return L10n.format(
            "所有 Codex 官方执行器均失败：%@",
            unique.joined(separator: " · ")
        )
    }
}

private enum CodexJSONRPCSession {
    static func delete(
        executable: String,
        expectedHome: String?,
        threadID: String,
        requestTimeout: TimeInterval
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let client: CodexJSONRPCClient
            do {
                client = try CodexJSONRPCClient(
                    executable: executable,
                    codexHome: expectedHome,
                    requestTimeout: requestTimeout
                )
            } catch {
                throw CodexCleanupAttemptError.startup
            }
            defer { client.stop() }
            try client.initialize(expectedHome: expectedHome)

            let before = try client.request(
                id: 2,
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": false]
            )
            if let error = before.error {
                if error.isNotFound { return }
                throw CodexCleanupAttemptError.officialDeleteFailed
            }
            guard let thread = before.result?.objectValue?["thread"]?.objectValue else {
                throw CodexCleanupAttemptError.invalidResponse
            }
            guard thread["id"]?.stringValue == threadID,
                  thread["parentThreadId"]?.stringValue == nil else {
                throw CodexCleanupAttemptError.threadIdentityChanged
            }

            let deletion = try client.request(
                id: 3,
                method: "thread/delete",
                params: ["threadId": threadID]
            )
            if deletion.error != nil { throw CodexCleanupAttemptError.officialDeleteFailed }
            let after = try client.request(
                id: 4,
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": false]
            )
            guard let error = after.error, error.isNotFound else {
                throw CodexCleanupAttemptError.officialDeleteFailed
            }
        }.value
    }
}

private final class CodexJSONRPCClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let requestTimeout: TimeInterval
    private var pending = Data()

    init(executable: String, codexHome: String?, requestTimeout: TimeInterval) throws {
        self.requestTimeout = requestTimeout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        if let codexHome {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHome
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func initialize(expectedHome: String?) throws {
        let response = try request(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "find-disk-killer",
                    "title": "FindDiskKiller",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
                ],
                "capabilities": ["experimentalApi": false]
            ]
        )
        guard response.error == nil, let result = response.result?.objectValue,
              result["userAgent"]?.stringValue?.lowercased().contains("codex") == true,
              let returnedHome = result["codexHome"]?.stringValue
        else { throw CodexCleanupAttemptError.invalidResponse }
        if let expectedHome {
            let expected = URL(fileURLWithPath: expectedHome).resolvingSymlinksInPath().standardizedFileURL.path
            let actual = URL(fileURLWithPath: returnedHome).resolvingSymlinksInPath().standardizedFileURL.path
            guard expected == actual else { throw CodexCleanupAttemptError.homeMismatch }
        }
        try send(["method": "initialized"])
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> AgentCleanupRPCEnvelope {
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            let line = try readLine(deadline: deadline)
            guard let data = line.data(using: .utf8) else { continue }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (object?["id"] as? Int) == id else { continue }
            guard let envelope = try? JSONDecoder().decode(AgentCleanupRPCEnvelope.self, from: data) else {
                throw CodexCleanupAttemptError.invalidResponse
            }
            return envelope
        }
        throw CodexCleanupAttemptError.timedOut
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine(deadline: Date) throws -> String {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            var descriptor = pollfd(
                fd: output.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            guard poll(&descriptor, 1, remaining) > 0 else {
                throw CodexCleanupAttemptError.timedOut
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw CodexCleanupAttemptError.invalidResponse }
            pending.append(chunk)
        }
    }
}

private struct AgentCleanupRPCEnvelope: Decodable {
    let id: Int?
    let result: AgentCleanupJSONValue?
    let error: AgentCleanupRPCError?
}

private struct AgentCleanupRPCError: Decodable {
    let code: Int
    let message: String

    var isNotFound: Bool {
        let normalized = message.lowercased()
        return normalized == "thread not found"
            || normalized.hasPrefix("thread not found:")
            || normalized.hasPrefix("thread not loaded:")
    }

}

private indirect enum AgentCleanupJSONValue: Decodable {
    case string(String), number(Double), object([String: Self]), array([Self]), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try container.decode([Self].self)) }
    }

    var objectValue: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
}

struct ClaudeSDKCleanupAdapter: AgentStorageCleanupCapabilityProviding {
    private let helperOverride: String?

    init(helperOverride: String? = nil) {
        self.helperOverride = helperOverride
    }

    func availability(for family: AgentStorageThreadFamily) async -> AgentStorageCleanupAvailability {
        switch family.sourceKind {
        case .claudeDesktop, .claudeDesktopAgent:
            return .unsupported("请在 Claude Desktop 中删除")
        case .claudeCode:
            break
        default:
            return .unsupported("此 Claude 来源不支持安全清理")
        }
        guard let helper = Self.resolvedHelper(override: helperOverride) else {
            return .unsupported("官方 Claude SDK 清理组件不可用")
        }
        do {
            let response = try await runHelper(helper, request: ["operation": "probe"])
            guard response["sdkVersion"] as? String == "0.3.220" else {
                return .unsupported("Claude SDK 版本不兼容")
            }
            return .ready
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }

    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome {
        guard family.sourceKind == .claudeCode,
              let helper = Self.resolvedHelper(override: helperOverride),
              let projectPath = family.projectPath,
              let sourcePath = family.sourcePath
        else { return .failed("官方 Claude SDK 清理组件不可用") }
        do {
            let response = try await runHelper(helper, request: [
                "operation": "delete",
                "sessionId": family.nativeThreadID,
                "dir": projectPath,
                "claudeHome": sourcePath
            ])
            if response["deleted"] as? Bool == true || response["alreadyAbsent"] as? Bool == true {
                return .succeeded
            }
            return .failed(response["error"] as? String ?? "Claude SDK 未确认 session 已删除")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func runHelper(_ helper: Helper, request: [String: Any]) async throws -> [String: Any] {
        // The bundled helper no longer ships a Node.js runtime; resolve (and
        // download once, if nothing usable is installed) before invoking it.
        // Override helpers used by tests manage their own runtime.
        var environment: [String: String] = [:]
        if helper.isBundled {
            environment["FDK_NODE_BINARY"] = try await ClaudeNodeRuntime.ensureAvailable()
        }
        let input = try JSONSerialization.data(withJSONObject: request)
        let result = try await AgentCleanupProcess.run(
            executable: helper.path,
            arguments: [],
            stdin: input + Data([0x0A]),
            environment: environment.isEmpty ? nil : environment,
            timeoutSeconds: 20
        )
        guard let data = result.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if !result.stderr.isEmpty {
                throw AgentCleanupProviderError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw AgentStorageCleanupError.invalidProtocol
        }
        return object
    }

    private struct Helper {
        let path: String
        let isBundled: Bool
    }

    private static func resolvedHelper(override helperOverride: String?) -> Helper? {
        if let helperOverride { return Helper(path: helperOverride, isBundled: false) }
        if let override = ProcessInfo.processInfo.environment["FDK_CLAUDE_CLEANUP_HELPER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return Helper(path: override, isBundled: false)
        }
        guard let executable = Bundle.main.executableURL else { return nil }
        let path = executable.deletingLastPathComponent()
            .appending(path: "FindDiskKillerClaudeCleanupHelper").path
        return FileManager.default.isExecutableFile(atPath: path) ? Helper(path: path, isBundled: true) : nil
    }
}

private enum AgentCleanupProviderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

private enum AgentCleanupProcess {
    struct Result: Sendable { let status: Int32; let stdout: String; let stderr: String }

    static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, override in override }
            }
            let output = Pipe()
            let errors = Pipe()
            let input = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = input
            try process.run()
            if let stdin { try input.fileHandleForWriting.write(contentsOf: stdin) }
            try? input.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning {
                process.terminate()
                throw AgentStorageCleanupError.timedOut
            }
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }.value
    }
}
