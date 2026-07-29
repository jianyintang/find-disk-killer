import AppKit
import Darwin
import FindDiskKillerCore
import Foundation
import SwiftUI

struct AgentStorageCleanupReview: Identifiable, Sendable {
    let id = UUID()
    let families: [AgentStorageThreadFamily]
    let artifacts: [AgentStorageCleanupArtifact]
    let totalBytes: UInt64
    let reclaimableBytes: UInt64
    let retainedBytes: UInt64

    init(families: [AgentStorageThreadFamily]) {
        self.families = families.sorted { $0.updatedAt > $1.updatedAt }
        var identities = Set<AgentStorageCleanupIdentity>()
        artifacts = families.flatMap(\.cleanupArtifacts).filter { artifact in
            identities.insert(AgentStorageCleanupIdentity(artifact)).inserted
        }.sorted { $0.path < $1.path }
        totalBytes = families.reduce(0) { $0.addingClamped($1.attributedBytes) }
        reclaimableBytes = artifacts.reduce(0) { $0.addingClamped($1.allocatedBytes) }
        retainedBytes = totalBytes >= reclaimableBytes ? totalBytes - reclaimableBytes : 0
    }
}

struct AgentStorageCleanupResult: Sendable {
    let movedFileCount: Int
    let movedBytes: UInt64
    let skippedFileCount: Int
    let errorDescription: String?
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
}

@MainActor
enum AgentStorageCleanupExecutor {
    static func moveToTrash(_ review: AgentStorageCleanupReview) async -> AgentStorageCleanupResult {
        let eligible = await Task.detached(priority: .userInitiated) {
            AgentStorageCleanupValidator.eligibleArtifacts(from: review.artifacts)
        }.value
        let skipped = review.artifacts.count - eligible.count
        guard !eligible.isEmpty else {
            return AgentStorageCleanupResult(
                movedFileCount: 0,
                movedBytes: 0,
                skippedFileCount: skipped,
                errorDescription: nil
            )
        }

        let byURL = Dictionary(uniqueKeysWithValues: eligible.map {
            (URL(fileURLWithPath: $0.path), $0)
        })
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(Array(byURL.keys)) { movedURLs, error in
                let movedArtifacts = movedURLs.keys.compactMap { byURL[$0] }
                continuation.resume(returning: AgentStorageCleanupResult(
                    movedFileCount: movedArtifacts.count,
                    movedBytes: movedArtifacts.reduce(0) { $0.addingClamped($1.allocatedBytes) },
                    skippedFileCount: skipped + eligible.count - movedArtifacts.count,
                    errorDescription: error?.localizedDescription
                ))
            }
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

struct AgentStorageCleanupReviewView: View {
    let review: AgentStorageCleanupReview
    let isCleaning: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    metrics
                    reclaimableBar
                    safetyNote
                    selectionSummary
                }
                .padding(24)
            }
            Divider()
            actions
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 520, idealHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("agent-storage-cleanup-review")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 40, height: 40)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("检查批量清理"))
                    .font(.title3.weight(.semibold))
                Text(L10n.format("%d 个聊天 · %d 个独占文件", review.families.count, review.artifacts.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            cleanupMetric(
                title: L10n.text("聊天总占用"),
                value: review.totalBytes,
                symbol: "bubble.left.and.bubble.right"
            )
            Divider().frame(height: 54)
            cleanupMetric(
                title: L10n.text("预计可释放"),
                value: review.reclaimableBytes,
                symbol: "arrow.down.to.line.compact",
                color: .green
            )
            Divider().frame(height: 54)
            cleanupMetric(
                title: L10n.text("保留不动"),
                value: review.retainedBytes,
                symbol: "lock.shield",
                color: .secondary
            )
        }
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }

    private func cleanupMetric(
        title: String,
        value: UInt64,
        symbol: String,
        color: Color = .accentColor
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(AgentStorageSizeFormatter.string(value))
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reclaimableBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.text("释放构成"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text("独占文件可清理 · 共享数据保留"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let total = max(1, Double(review.totalBytes))
                let reclaimableWidth = geometry.size.width
                    * CGFloat(Double(review.reclaimableBytes) / total)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.85))
                        .frame(width: max(review.reclaimableBytes == 0 ? 0 : 3, reclaimableWidth))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.22))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("执行前会再次核验"))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("只有扫描后未发生变化的独占普通文件会被移到废纸篓。共享数据库、Claude VM、缓存、硬链接与变化中的文件不会处理。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.22), lineWidth: 1)
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("所选聊天"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(review.families.prefix(6)) { family in
                HStack(spacing: 10) {
                    AgentStorageProviderIcon(provider: family.provider, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(family.title).lineLimit(1)
                        Text(family.project)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(AgentStorageSizeFormatter.string(family.reclaimableBytes))
                        .font(.callout.monospacedDigit())
                }
                .frame(height: 34)
            }
            if review.families.count > 6 {
                Text(L10n.format("另有 %d 个聊天", review.families.count - 6))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text(L10n.text("项目会移到废纸篓，可在清空废纸篓前恢复。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(L10n.text("取消"), action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isCleaning)
            Button(action: confirm) {
                if isCleaning {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在移到废纸篓"))
                    }
                } else {
                    Label(L10n.text("移到废纸篓"), systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isCleaning || review.artifacts.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.bar)
    }
}
