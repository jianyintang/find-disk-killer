import AppKit
import Darwin
import FindDiskKillerCore
import Foundation
import SwiftUI

struct AgentStorageCleanupReview: Identifiable, Sendable {
    let id = UUID()
    let families: [AgentStorageThreadFamily]
    let totalBytes: UInt64
    let artifacts: [AgentStorageCleanupArtifact]
    let reclaimableBytes: UInt64
    let retainedBytes: UInt64

    init(families: [AgentStorageThreadFamily]) {
        self.families = families.sorted { $0.updatedAt > $1.updatedAt }
        totalBytes = families.reduce(0) { $0.addingClamped($1.attributedBytes) }
        var identities = Set<AgentStorageCleanupIdentity>()
        artifacts = families.flatMap(AgentStorageCleanupValidator.officialArtifacts).filter {
            identities.insert(AgentStorageCleanupIdentity($0)).inserted
        }
        reclaimableBytes = artifacts.reduce(0) { $0.addingClamped($1.allocatedBytes) }
        retainedBytes = totalBytes >= reclaimableBytes ? totalBytes - reclaimableBytes : 0
    }
}

enum AgentStorageCleanupAvailability: Equatable, Sendable {
    case checking
    case ready
    case active
    case changed
    case unsupported(String)
}

enum AgentStorageCleanupOutcome: Equatable, Sendable {
    case succeeded
    case skipped(String)
    case failed(String)
    case cancelled
}

struct AgentStorageCleanupTarget: Identifiable, Sendable {
    let family: AgentStorageThreadFamily
    let immediateArtifacts: [AgentStorageCleanupArtifact]
    var availability: AgentStorageCleanupAvailability
    var outcome: AgentStorageCleanupOutcome?

    var id: String { family.id }
    var immediateBytes: UInt64 {
        immediateArtifacts.reduce(0) { $0.addingClamped($1.allocatedBytes) }
    }
    var logicalBytes: UInt64 { family.databaseAttributedBytes }
    var retainedBytes: UInt64 {
        family.attributedBytes >= immediateBytes ? family.attributedBytes - immediateBytes : 0
    }
}

struct AgentStorageCleanupResult: Sendable {
    let targets: [AgentStorageCleanupTarget]
    let measuredReleasedBytes: UInt64

    var succeededCount: Int { targets.count(where: { $0.outcome == .succeeded }) }
    var changedStorage: Bool { succeededCount > 0 }
    var skippedCount: Int {
        targets.count { target in
            if case .skipped = target.outcome { return true }
            return target.outcome == .cancelled
        }
    }
    var failedCount: Int {
        targets.count { target in
            if case .failed = target.outcome { return true }
            return false
        }
    }
}

enum AgentStorageCleanupValidator {
    static func eligibleArtifacts(
        from artifacts: [AgentStorageCleanupArtifact]
    ) -> [AgentStorageCleanupArtifact] {
        artifacts.filter(isStillEligible)
    }

    static func isStillEligible(_ artifact: AgentStorageCleanupArtifact) -> Bool {
        var value = stat()
        guard lstat(artifact.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_nlink == 1,
              UInt64(value.st_dev) == artifact.device,
              UInt64(value.st_ino) == artifact.inode,
              Int64(value.st_size) == artifact.logicalBytes,
              Int64(value.st_blocks) == artifact.blocks,
              Int64(value.st_mtimespec.tv_sec) == artifact.modifiedSeconds,
              Int64(value.st_mtimespec.tv_nsec) == artifact.modifiedNanoseconds
        else { return false }
        return true
    }

    static func officialArtifacts(for family: AgentStorageThreadFamily) -> [AgentStorageCleanupArtifact] {
        if family.provider == .openCode { return [] }
        let artifacts: [AgentStorageCleanupArtifact]
        if family.provider == .claude {
            guard family.sourceKind == .claudeCode else { return [] }
            guard let mainPath = family.path else { return [] }
            let sessionDirectory = URL(fileURLWithPath: mainPath)
                .deletingLastPathComponent()
                .appending(path: family.nativeThreadID, directoryHint: .isDirectory)
                .standardizedFileURL.path
            artifacts = family.cleanupArtifacts.filter { artifact in
                let path = URL(fileURLWithPath: artifact.path).standardizedFileURL.path
                return path == URL(fileURLWithPath: mainPath).standardizedFileURL.path
                    || path.hasPrefix(sessionDirectory + "/")
            }
        } else {
            artifacts = family.cleanupArtifacts
        }
        var identities = Set<AgentStorageCleanupIdentity>()
        return artifacts.filter { identities.insert(AgentStorageCleanupIdentity($0)).inserted }
    }

    static func sourceIdentityIsValid(_ family: AgentStorageThreadFamily) -> Bool {
        guard !family.nativeThreadID.isEmpty,
              let sourcePath = family.sourcePath,
              sourcePath.hasPrefix("/"),
              let mainPath = family.path
        else { return false }
        let canonicalSource = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        let canonicalMain = URL(fileURLWithPath: mainPath).standardizedFileURL.path
        guard canonicalMain == canonicalSource || canonicalMain.hasPrefix(canonicalSource + "/") else {
            return false
        }
        let subagentIDs = Set(family.subagents.map(\.nativeID))
        guard subagentIDs.count == family.subagents.count,
              !subagentIDs.contains(family.nativeThreadID),
              family.subagents.allSatisfy({ node in
                  guard node.depth > 0,
                        let parentID = node.parentID,
                        parentID == family.nativeThreadID || subagentIDs.contains(parentID),
                        parentID != node.nativeID
                  else { return false }
                  guard let path = node.path else { return true }
                  let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
                  return canonicalPath.hasPrefix(canonicalSource + "/")
              })
        else { return false }
        if family.provider == .claude {
            return canonicalMain.contains(family.nativeThreadID)
                && family.projectPath?.hasPrefix("/") == true
        }
        if family.provider == .openCode {
            guard family.sourceKind == .openCode,
                  OpenCodeDataDirectory.environment(for: canonicalSource) != nil,
                  canonicalMain == URL(fileURLWithPath: canonicalSource)
                      .appending(path: "opencode.db")
                      .standardizedFileURL.path
            else { return false }
            var value = stat()
            return lstat(canonicalMain, &value) == 0
                && (value.st_mode & S_IFMT) == S_IFREG
        }
        return family.sourceKind == .codexHome
    }

    static func deletionScopeMatchesSnapshot(
        _ family: AgentStorageThreadFamily,
        artifacts: [AgentStorageCleanupArtifact]
    ) -> Bool {
        if family.provider == .openCode {
            guard family.sourceKind == .openCode,
                  let sourcePath = family.sourcePath,
                  let mainPath = family.path,
                  OpenCodeDataDirectory.environment(for: sourcePath) != nil
            else { return false }
            let expectedMain = URL(fileURLWithPath: sourcePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .appending(path: "opencode.db")
                .standardizedFileURL.path
            var value = stat()
            return URL(fileURLWithPath: mainPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == expectedMain
                && lstat(expectedMain, &value) == 0
                && (value.st_mode & S_IFMT) == S_IFREG
                && artifacts.isEmpty
        }
        guard family.provider == .claude else { return family.sourceKind == .codexHome }
        guard family.sourceKind == .claudeCode, let mainPath = family.path else { return false }
        let main = URL(fileURLWithPath: mainPath).standardizedFileURL
        let sessionDirectory = main.deletingLastPathComponent()
            .appending(path: family.nativeThreadID, directoryHint: .isDirectory)
        var currentPaths: Set<String> = []
        var mainStat = stat()
        guard lstat(main.path, &mainStat) == 0, (mainStat.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        currentPaths.insert(main.path)
        if FileManager.default.fileExists(atPath: sessionDirectory.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: sessionDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return false }
            for case let url as URL in enumerator {
                var value = stat()
                guard lstat(url.path, &value) == 0 else { return false }
                if (value.st_mode & S_IFMT) == S_IFREG { currentPaths.insert(url.standardizedFileURL.path) }
            }
        }
        return currentPaths == Set(artifacts.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
    }
}

protocol AgentStorageCleanupCapabilityProviding: Sendable {
    func availability(for family: AgentStorageThreadFamily) async -> AgentStorageCleanupAvailability
    func delete(_ family: AgentStorageThreadFamily) async -> AgentStorageCleanupOutcome
}

protocol AgentStorageCleanupActivityInspecting: Sendable {
    func isActive(
        family: AgentStorageThreadFamily,
        artifacts: [AgentStorageCleanupArtifact]
    ) async throws -> Bool
}

struct AgentStorageLsofActivityInspector: AgentStorageCleanupActivityInspecting {
    func isActive(
        family: AgentStorageThreadFamily,
        artifacts: [AgentStorageCleanupArtifact]
    ) async throws -> Bool {
        if family.provider == .openCode, let databasePath = family.path {
            return try await hasOpenHandle(for: [databasePath])
        }
        if try await hasOpenWriter(for: artifacts) { return true }
        guard family.sourceKind == .claudeCode, let projectPath = family.projectPath else {
            return false
        }
        return try await hasClaudeCodeProcess(in: projectPath)
    }

    func hasOpenWriter(for artifacts: [AgentStorageCleanupArtifact]) async throws -> Bool {
        guard !artifacts.isEmpty else { return false }
        return try await hasOpenWriter(for: artifacts.map(\.path))
    }

    private func hasOpenWriter(for paths: [String]) async throws -> Bool {
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-Fpa", "-w"] + paths
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                throw AgentStorageCleanupError.activityInspectionUnavailable
            }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .contains { $0 == "aw" || $0 == "au" }
        }.value
    }

    private func hasOpenHandle(for paths: [String]) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-Fpa", "-w"] + paths
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                throw AgentStorageCleanupError.activityInspectionUnavailable
            }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .contains { $0.first == "p" }
        }.value
    }

    private func hasClaudeCodeProcess(in projectPath: String) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let processList = Process()
            processList.executableURL = URL(fileURLWithPath: "/bin/ps")
            processList.arguments = ["-axo", "pid=,command="]
            let output = Pipe()
            processList.standardOutput = output
            processList.standardError = Pipe()
            try processList.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            processList.waitUntilExit()
            guard processList.terminationStatus == 0 else {
                throw AgentStorageCleanupError.activityInspectionUnavailable
            }

            let pids = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap(Self.claudeCodePID)
            guard !pids.isEmpty else { return false }

            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = [
                "-Fpn", "-w", "-a", "-d", "cwd", "-p",
                pids.map(String.init).joined(separator: ",")
            ]
            let cwdOutput = Pipe()
            lsof.standardOutput = cwdOutput
            lsof.standardError = Pipe()
            try lsof.run()
            let cwdData = cwdOutput.fileHandleForReading.readDataToEndOfFile()
            lsof.waitUntilExit()
            guard lsof.terminationStatus == 0 || lsof.terminationStatus == 1 else {
                throw AgentStorageCleanupError.activityInspectionUnavailable
            }
            let expected = URL(fileURLWithPath: projectPath)
                .resolvingSymlinksInPath().standardizedFileURL.path
            return String(decoding: cwdData, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.first == "n" }
                .map { String($0.dropFirst()) }
                .contains {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                        == expected
                }
        }.value
    }

    private static func claudeCodePID(_ line: Substring) -> Int32? {
        let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
        let command = fields[1].lowercased()
        guard !command.contains("/claude.app/contents/") else { return nil }
        let executable = command.split(whereSeparator: { $0.isWhitespace })
            .first.map(String.init) ?? ""
        let basename = URL(fileURLWithPath: executable).lastPathComponent
        guard basename == "claude"
                || command.contains("/bin/claude")
                || command.contains("@anthropic-ai/claude-code")
        else { return nil }
        return pid
    }
}

enum AgentStorageCleanupError: LocalizedError {
    case activityInspectionUnavailable
    case helperUnavailable
    case invalidProtocol
    case providerHomeMismatch
    case timedOut

    var errorDescription: String? {
        switch self {
        case .activityInspectionUnavailable: "无法确认文件是否正在写入"
        case .helperUnavailable: "未找到兼容的官方清理入口"
        case .invalidProtocol: "官方清理协议不兼容"
        case .providerHomeMismatch: "官方服务的数据目录与扫描来源不一致"
        case .timedOut: "官方清理服务响应超时"
        }
    }
}

actor AgentStorageCleanupCoordinator {
    private let codex: any AgentStorageCleanupCapabilityProviding
    private let claude: any AgentStorageCleanupCapabilityProviding
    private let openCode: any AgentStorageCleanupCapabilityProviding
    private let activityInspector: any AgentStorageCleanupActivityInspecting
    private var capabilityCache: [String: AgentStorageCleanupAvailability] = [:]

    init(
        codex: any AgentStorageCleanupCapabilityProviding = CodexAppServerCleanupAdapter(),
        claude: any AgentStorageCleanupCapabilityProviding = ClaudeSDKCleanupAdapter(),
        openCode: any AgentStorageCleanupCapabilityProviding = OpenCodeCLIAdapter(),
        activityInspector: any AgentStorageCleanupActivityInspecting = AgentStorageLsofActivityInspector()
    ) {
        self.codex = codex
        self.claude = claude
        self.openCode = openCode
        self.activityInspector = activityInspector
    }

    func prepare(_ review: AgentStorageCleanupReview) async -> [AgentStorageCleanupTarget] {
        var targets: [AgentStorageCleanupTarget] = []
        for family in review.families {
            let artifacts = AgentStorageCleanupValidator.officialArtifacts(for: family)
            var target = AgentStorageCleanupTarget(
                family: family,
                immediateArtifacts: artifacts,
                availability: .checking,
                outcome: nil
            )
            guard AgentStorageCleanupValidator.sourceIdentityIsValid(family) else {
                target.availability = .changed
                targets.append(target)
                continue
            }
            guard artifacts.allSatisfy(AgentStorageCleanupValidator.isStillEligible) else {
                target.availability = .changed
                targets.append(target)
                continue
            }
            guard AgentStorageCleanupValidator.deletionScopeMatchesSnapshot(
                family,
                artifacts: artifacts
            ) else {
                target.availability = .changed
                targets.append(target)
                continue
            }
            do {
                if try await activityInspector.isActive(family: family, artifacts: artifacts) {
                    target.availability = .active
                } else {
                    let key = capabilityKey(for: family)
                    if let cached = capabilityCache[key] {
                        target.availability = cached
                    } else {
                        let availability = await adapter(for: family).availability(for: family)
                        capabilityCache[key] = availability
                        target.availability = availability
                    }
                }
            } catch {
                target.availability = .active
            }
            targets.append(target)
        }
        return targets
    }

    func execute(
        _ prepared: [AgentStorageCleanupTarget],
        shouldCancel: @Sendable () async -> Bool,
        didUpdate: @Sendable ([AgentStorageCleanupTarget]) async -> Void
    ) async -> AgentStorageCleanupResult {
        var targets = prepared
        let before = allocatedBytesStillPresent(in: targets)
        for index in targets.indices {
            if await shouldCancel() {
                for pending in targets.indices where targets[pending].outcome == nil {
                    targets[pending].outcome = .cancelled
                }
                await didUpdate(targets)
                break
            }
            guard targets[index].availability == .ready else {
                targets[index].outcome = .skipped(skipReason(targets[index].availability))
                await didUpdate(targets)
                continue
            }
            let artifacts = targets[index].immediateArtifacts
            guard AgentStorageCleanupValidator.sourceIdentityIsValid(targets[index].family),
                  artifacts.allSatisfy(AgentStorageCleanupValidator.isStillEligible),
                  AgentStorageCleanupValidator.deletionScopeMatchesSnapshot(
                    targets[index].family,
                    artifacts: artifacts
                  )
            else {
                targets[index].outcome = .skipped("文件身份已变化")
                await didUpdate(targets)
                continue
            }
            do {
                guard try await !activityInspector.isActive(
                    family: targets[index].family,
                    artifacts: artifacts
                ) else {
                    targets[index].outcome = .skipped("聊天仍在活动")
                    await didUpdate(targets)
                    continue
                }
            } catch {
                targets[index].outcome = .skipped("无法确认活动状态")
                await didUpdate(targets)
                continue
            }
            targets[index].outcome = await adapter(for: targets[index].family)
                .delete(targets[index].family)
            await didUpdate(targets)
        }
        let after = allocatedBytesStillPresent(in: targets)
        return AgentStorageCleanupResult(
            targets: targets,
            measuredReleasedBytes: before >= after ? before - after : 0
        )
    }

    private func adapter(for family: AgentStorageThreadFamily) -> any AgentStorageCleanupCapabilityProviding {
        switch family.provider {
        case .codex: codex
        case .claude: claude
        case .openCode: openCode
        }
    }

    private func capabilityKey(for family: AgentStorageThreadFamily) -> String {
        "\(family.provider.rawValue)|\(family.sourceKind?.rawValue ?? "unknown")|\(family.sourcePath ?? "")"
    }

    private func allocatedBytesStillPresent(in targets: [AgentStorageCleanupTarget]) -> UInt64 {
        targets.flatMap(\.immediateArtifacts).reduce(0) { total, artifact in
            guard AgentStorageCleanupValidator.isStillEligible(artifact) else { return total }
            return total.addingClamped(artifact.allocatedBytes)
        }
    }

    private func skipReason(_ availability: AgentStorageCleanupAvailability) -> String {
        switch availability {
        case .checking: "能力检查尚未完成"
        case .ready: ""
        case .active: "聊天仍在活动"
        case .changed: "文件身份已变化"
        case .unsupported(let reason): reason
        }
    }
}

private struct AgentStorageCleanupIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ artifact: AgentStorageCleanupArtifact) {
        device = artifact.device
        inode = artifact.inode
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}

@MainActor
final class AgentStorageCleanupSession: ObservableObject, Identifiable {
    enum Phase { case checking, ready, deleting, finished }

    let id = UUID()
    let review: AgentStorageCleanupReview
    @Published var phase: Phase = .checking
    @Published var targets: [AgentStorageCleanupTarget] = []
    @Published var result: AgentStorageCleanupResult?
    private let coordinator: AgentStorageCleanupCoordinator
    private var cancellationRequested = false

    init(
        review: AgentStorageCleanupReview,
        coordinator: AgentStorageCleanupCoordinator = AgentStorageCleanupCoordinator()
    ) {
        self.review = review
        self.coordinator = coordinator
    }

    var readyCount: Int { targets.count(where: { $0.availability == .ready }) }
    var immediateBytes: UInt64 {
        targets.filter { $0.availability == .ready }.reduce(0) {
            $0.addingClamped($1.immediateBytes)
        }
    }
    var logicalBytes: UInt64 {
        targets.filter { $0.availability == .ready }.reduce(0) {
            $0.addingClamped($1.logicalBytes)
        }
    }
    var retainedBytes: UInt64 {
        review.totalBytes >= immediateBytes ? review.totalBytes - immediateBytes : 0
    }

    func prepare() async {
        guard phase == .checking else { return }
        targets = await coordinator.prepare(review)
        phase = .ready
    }

    func execute() async {
        guard phase == .ready, readyCount > 0 else { return }
        cancellationRequested = false
        phase = .deleting
        result = await coordinator.execute(
            targets,
            shouldCancel: { [weak self] in await MainActor.run { self?.cancellationRequested ?? true } },
            didUpdate: { [weak self] updated in await MainActor.run { self?.targets = updated } }
        )
        if let result { targets = result.targets }
        phase = .finished
    }

    func cancelRemaining() { cancellationRequested = true }
}

struct AgentStorageCleanupReviewView: View {
    @ObservedObject var session: AgentStorageCleanupSession
    let close: () -> Void
    let didFinish: (AgentStorageCleanupResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metrics
                    safetyNote
                    groupedTargets
                }
                .padding(24)
            }
            actions
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 560, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await session.prepare() }
        .accessibilityIdentifier("agent-storage-cleanup-review")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: session.phase == .finished ? "checkmark.shield.fill" : "trash.slash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(session.phase == .finished ? Color.green : Color.red)
                .frame(width: 42, height: 42)
                .background((session.phase == .finished ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.phase == .finished ? L10n.text("清理结果") : L10n.text("复核永久删除"))
                    .font(.title3.weight(.semibold))
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.phase != .deleting {
                Button(action: dismissReview) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(L10n.text("关闭"))
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
        .background(.bar)
    }

    private var headerSubtitle: String {
        switch session.phase {
        case .checking: L10n.text("正在核验官方能力与聊天活动状态")
        case .ready: L10n.format("%d 个聊天可安全提交给官方清理", session.readyCount)
        case .deleting: L10n.text("正在串行提交；可取消尚未开始的聊天")
        case .finished: L10n.format("成功 %d · 跳过 %d · 失败 %d", session.result?.succeededCount ?? 0, session.result?.skippedCount ?? 0, session.result?.failedCount ?? 0)
        }
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric("预计立即释放", metricValue(session.immediateBytes), "internaldrive")
            Divider().frame(height: 48)
            metric("逻辑清理", metricValue(session.logicalBytes), "cylinder.split.1x2")
            Divider().frame(height: 48)
            metric("保留数据", metricValue(session.retainedBytes), "lock.shield")
        }
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)) }
    }

    private func metricValue(_ bytes: UInt64) -> UInt64? {
        session.phase == .checking ? nil : bytes
    }

    private func metric(_ title: String, _ bytes: UInt64?, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.text(title), systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(bytes.map(AgentStorageSizeFormatter.string) ?? "—")
                .font(.system(size: 21, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("由官方接口永久删除")).font(.callout.weight(.semibold))
                Text(L10n.text("操作不可撤销。活动聊天、身份变化或协议不兼容会立即跳过；不会改写数据库，也不会降级为手工删除文件。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var groupedTargets: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(AgentStorageProvider.allCases) { provider in
                let providerTargets = session.targets.filter { $0.family.provider == provider }
                if !providerTargets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            provider == .codex ? "Codex" : provider == .claude ? "Claude" : "OpenCode",
                            systemImage: provider == .codex
                                ? "terminal"
                                : provider == .claude ? "bubble.left.and.text.bubble.right" : "curlybraces"
                        )
                            .font(.headline)
                        ForEach(providerTargets) { target in targetRow(target) }
                    }
                }
            }
            if session.phase == .checking {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L10n.text("正在逐项核验…")).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private func targetRow(_ target: AgentStorageCleanupTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol(target)).foregroundStyle(statusColor(target)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.family.title).lineLimit(1)
                Text(target.family.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if target.family.sourceKind == .claudeDesktop
                || target.family.sourceKind == .claudeDesktopAgent {
                Button {
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.anthropic.claudefordesktop"
                    ) { NSWorkspace.shared.open(url) }
                } label: {
                    Label(L10n.text("打开 Claude"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText(target)).font(.caption.weight(.medium)).foregroundStyle(statusColor(target))
                if target.immediateBytes > 0 {
                    Text(AgentStorageSizeFormatter.string(target.immediateBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).frame(height: 52)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
    }

    private func statusText(_ target: AgentStorageCleanupTarget) -> String {
        if let outcome = target.outcome {
            switch outcome {
            case .succeeded: return L10n.text("已删除")
            case .cancelled: return L10n.text("已取消")
            case .skipped(let reason): return reason
            case .failed(let reason): return reason
            }
        }
        switch target.availability {
        case .checking: return L10n.text("核验中")
        case .ready: return L10n.text("可安全删除")
        case .active: return L10n.text("活动中，跳过")
        case .changed: return L10n.text("数据已变化，跳过")
        case .unsupported(let reason): return reason
        }
    }

    private func statusSymbol(_ target: AgentStorageCleanupTarget) -> String {
        if let outcome = target.outcome {
            switch outcome {
            case .succeeded: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            case .skipped, .cancelled: return "minus.circle.fill"
            }
        }
        switch target.availability {
        case .checking: return "clock"
        case .ready: return "checkmark.circle.fill"
        case .active: return "waveform.circle.fill"
        case .changed, .unsupported: return "minus.circle.fill"
        }
    }

    private func statusColor(_ target: AgentStorageCleanupTarget) -> Color {
        if let outcome = target.outcome {
            switch outcome {
            case .succeeded: return .green
            case .failed: return .red
            case .skipped, .cancelled: return .secondary
            }
        }
        switch target.availability {
        case .ready: return .green
        case .active: return .orange
        case .checking, .changed, .unsupported: return .secondary
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if session.phase == .finished, let result = session.result {
                Text(L10n.format("实际复核释放 %@", AgentStorageSizeFormatter.string(result.measuredReleasedBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("数据库逻辑删除不会计入立即释放；不会执行 VACUUM 或 checkpoint。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if session.phase == .deleting {
                Button(L10n.text("取消剩余任务")) { session.cancelRemaining() }
            } else if session.phase == .finished {
                Button(L10n.text("完成"), action: dismissReview).keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.text("取消"), action: close).keyboardShortcut(.cancelAction)
                Button {
                    Task { await session.execute() }
                } label: {
                    Label(L10n.text("永久删除"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(session.phase != .ready || session.readyCount == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).frame(height: 66).background(.bar)
    }

    private func dismissReview() {
        if session.phase == .finished, let result = session.result {
            didFinish(result)
        } else {
            close()
        }
    }
}
