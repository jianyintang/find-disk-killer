import Foundation
import FindDiskKillerCore

struct CodexAppServerCleanupAdapter: AgentStorageCleanupCapabilityProviding {
    private let executableOverride: String?

    init(executableOverride: String? = nil) {
        self.executableOverride = executableOverride
    }

    func availability(for family: AgentStorageThreadFamily) async -> AgentStorageCleanupAvailability {
        guard family.sourceKind == .codexHome else {
            return .unsupported("此 Codex 来源不支持安全清理")
        }
        guard let executable = executableOverride ?? CodexExecutableLocator.locate() else {
            return .unsupported("未找到支持 thread/delete 的 Codex")
        }
        do {
            let version = try await AgentCleanupProcess.run(
                executable: executable,
                arguments: ["--version"],
                timeoutSeconds: 4
            )
            guard version.status == 0,
                  CodexExecutableLocator.supportsThreadDelete(version.stdout)
            else { return .unsupported("Codex 版本不支持安全清理") }
            try await CodexJSONRPCSession.probe(executable: executable, expectedHome: family.sourcePath)
            return .ready
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }

    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome {
        guard let executable = executableOverride ?? CodexExecutableLocator.locate() else {
            return .failed("官方 Codex 清理入口已不可用")
        }
        do {
            return try await CodexJSONRPCSession.delete(
                executable: executable,
                expectedHome: family.sourcePath,
                threadID: family.nativeThreadID
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["FDK_CODEX_APP_SERVER"], isExecutable(override) {
            return override
        }
        let fileManager = FileManager.default
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex").path }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let appCandidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex"
        ]
        return (pathCandidates + appCandidates).first(where: isExecutable)
    }

    static func supportsThreadDelete(_ output: String) -> Bool {
        guard let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return false
        }
        let suffix = output[match.upperBound...].lowercased()
        guard !suffix.hasPrefix("-alpha"),
              !suffix.hasPrefix("-beta"),
              !suffix.hasPrefix("-rc")
        else { return false }
        let parts = output[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return parts[0] > 0 || parts[1] > 146 || (parts[1] == 146 && parts[2] >= 0)
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

private enum CodexJSONRPCSession {
    static func probe(executable: String, expectedHome: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            let client = try CodexJSONRPCClient(executable: executable)
            defer { client.stop() }
            try client.initialize(expectedHome: expectedHome)
            let response = try client.request(
                id: 2,
                method: "thread/delete",
                params: ["threadId": "find-disk-killer-capability-probe"]
            )
            guard response.error?.isInvalidThreadID == true else {
                throw AgentStorageCleanupError.invalidProtocol
            }
        }.value
    }

    static func delete(
        executable: String,
        expectedHome: String?,
        threadID: String
    ) async throws -> AgentStorageCleanupOutcome {
        try await Task.detached(priority: .userInitiated) {
            let client = try CodexJSONRPCClient(executable: executable)
            defer { client.stop() }
            try client.initialize(expectedHome: expectedHome)

            let before = try client.request(
                id: 2,
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": false]
            )
            if let error = before.error {
                return error.isNotFound ? .succeeded : .failed(error.message)
            }
            guard let thread = before.result?.objectValue?["thread"]?.objectValue,
                  thread["id"]?.stringValue == threadID,
                  thread["parentThreadId"]?.stringValue == nil
            else {
                return .failed("Codex 返回了不匹配的 thread")
            }

            let deletion = try client.request(
                id: 3,
                method: "thread/delete",
                params: ["threadId": threadID]
            )
            if let error = deletion.error {
                return .failed(error.message)
            }
            let after = try client.request(
                id: 4,
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": false]
            )
            guard let error = after.error, error.isNotFound else {
                return .failed("Codex 未确认 thread 已删除")
            }
            return .succeeded
        }.value
    }
}

private final class CodexJSONRPCClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()

    init(executable: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
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
        else { throw AgentStorageCleanupError.invalidProtocol }
        if let expectedHome {
            let expected = URL(fileURLWithPath: expectedHome).resolvingSymlinksInPath().standardizedFileURL.path
            let actual = URL(fileURLWithPath: returnedHome).resolvingSymlinksInPath().standardizedFileURL.path
            guard expected == actual else { throw AgentStorageCleanupError.providerHomeMismatch }
        }
        try send(["method": "initialized"])
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> AgentCleanupRPCEnvelope {
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let line = try readLine(deadline: deadline)
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(AgentCleanupRPCEnvelope.self, from: data),
                  envelope.id == id else { continue }
            return envelope
        }
        throw AgentStorageCleanupError.timedOut
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
                throw AgentStorageCleanupError.timedOut
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw AgentStorageCleanupError.invalidProtocol }
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

    var isInvalidThreadID: Bool { message.lowercased().hasPrefix("invalid thread id:") }
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
        guard let helper = helperOverride ?? Self.bundledHelperPath() else {
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
              let helper = helperOverride ?? Self.bundledHelperPath(),
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

    private func runHelper(_ helper: String, request: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: request)
        let result = try await AgentCleanupProcess.run(
            executable: helper,
            arguments: [],
            stdin: input + Data([0x0A]),
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

    private static func bundledHelperPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["FDK_CLAUDE_CLEANUP_HELPER"],
           FileManager.default.isExecutableFile(atPath: override) { return override }
        guard let executable = Bundle.main.executableURL else { return nil }
        let path = executable.deletingLastPathComponent()
            .appending(path: "FindDiskKillerClaudeCleanupHelper").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
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
        timeoutSeconds: TimeInterval
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
