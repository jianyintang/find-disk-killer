import AppKit
import FindDiskKillerCore
import SwiftUI

struct StorageResourceTreeView: View {
    let nodes: [StorageResourceNode]
    let categoryDescription: (String) -> String
    @Binding var selectedIDs: Set<String>
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.node.id) { index, row in
                if index > 0 { Divider().padding(.leading, CGFloat(row.depth) * 20 + 40) }
                resourceRow(row)
            }
        }
        .onAppear {
            if expandedIDs.isEmpty {
                expandedIDs = Set(defaultExpandedIDs(in: nodes))
            }
        }
    }

    private var rows: [StorageResourceTreeRow] {
        StorageResourceTreeProjection.flatten(nodes: nodes, expandedIDs: expandedIDs)
    }

    private func resourceRow(_ row: StorageResourceTreeRow) -> some View {
        let targets = StorageResourceTreeProjection.cleanupRequests(in: row.node)
        let selectedTargetIDs = Set(targets.map(\.id)).intersection(selectedIDs)
        return HStack(alignment: .center, spacing: 10) {
            treeIndent(depth: row.depth)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expandedIDs.contains(row.node.id) {
                        expandedIDs.remove(row.node.id)
                    } else {
                        expandedIDs.insert(row.node.id)
                    }
                }
            } label: {
                Image(systemName: row.hasChildren ? "chevron.right" : "circle.fill")
                    .font(.system(size: row.hasChildren ? 11 : 4, weight: .semibold))
                    .rotationEffect(.degrees(expandedIDs.contains(row.node.id) && row.hasChildren ? 90 : 0))
                    .foregroundStyle(row.hasChildren ? Color.secondary : Color.secondary.opacity(0.45))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.hasChildren)
            selectionControl(
                node: row.node,
                targets: targets,
                selectedTargetIDs: selectedTargetIDs
            )
            Image(systemName: row.node.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(riskColor(row.node.risk))
                .frame(width: 24, height: 24)
                .background(riskColor(row.node.risk).opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(row.node.title))
                    .font(.callout.weight(row.depth == 0 ? .semibold : .medium))
                    .lineLimit(1)
                Text(detail(for: row.node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if row.node.allocatedBytes > 0 {
                    Text(AgentStorageSizeFormatter.string(row.node.allocatedBytes))
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                        .monospacedDigit()
                } else {
                    Text(L10n.format("%d 项", row.node.entryCount))
                        .font(.callout.weight(.medium))
                }
                Text(evidenceTitle(row.node.evidence))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 104, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .background(row.depth == 0 ? Color.primary.opacity(0.025) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.hasChildren else { return }
            withAnimation(.snappy(duration: 0.2)) {
                if expandedIDs.contains(row.node.id) {
                    expandedIDs.remove(row.node.id)
                } else {
                    expandedIDs.insert(row.node.id)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func selectionControl(
        node: StorageResourceNode,
        targets: [StorageCleanupRequest],
        selectedTargetIDs: Set<String>
    ) -> some View {
        if targets.isEmpty {
            Image(systemName: node.isProtected ? "lock.fill" : "minus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .help(node.isProtected ? L10n.text("此资源受保护或必须通过官方工具管理") : L10n.text("此资源不提供直接清理"))
        } else {
            Button {
                let ids = Set(targets.map(\.id))
                if selectedTargetIDs.count == ids.count {
                    selectedIDs.subtract(ids)
                } else {
                    selectedIDs.formUnion(ids)
                }
            } label: {
                Image(systemName: selectionSymbol(
                    selectedCount: selectedTargetIDs.count,
                    totalCount: targets.count
                ))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selectedTargetIDs.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(L10n.text("选择此分支中的可清理资源"))
            .accessibilityLabel(L10n.text("选择此分支中的可清理资源"))
        }
    }

    private func treeIndent(depth: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.42))
                    .frame(width: 1, height: 56)
                    .frame(width: 20)
            }
        }
        .frame(width: CGFloat(depth) * 20)
    }

    private func detail(for node: StorageResourceNode) -> String {
        if let detail = node.detail, !detail.isEmpty {
            return localizedDetail(detail)
        }
        return categoryDescription(node.title)
    }

    private func localizedDetail(_ detail: String) -> String {
        let parts = detail.components(separatedBy: " · ")
        guard let prefix = parts.first,
              prefix == "主仓库" || prefix == "worktree" else {
            return L10n.text(detail)
        }
        let localizedPrefix = prefix == "主仓库"
            ? L10n.text("主仓库")
            : L10n.text("worktree")
        return ([localizedPrefix] + parts.dropFirst()).joined(separator: " · ")
    }

    private func evidenceTitle(_ evidence: StorageMeasurementEvidence) -> String {
        switch evidence {
        case .fileSystemAllocated: L10n.text("物理分配")
        case .providerReported: L10n.text("提供者报告")
        case .logicalOnly: L10n.text("逻辑大小")
        }
    }

    private func selectionSymbol(selectedCount: Int, totalCount: Int) -> String {
        if selectedCount == 0 { return "square" }
        if selectedCount == totalCount { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func riskColor(_ risk: StorageRiskLevel) -> Color {
        switch risk {
        case .rebuildableCache: .green
        case .sharedOrExpensive: .orange
        case .environmentOrRuntime: .secondary
        case .protectedUserData: .red
        }
    }

    private func defaultExpandedIDs(in nodes: [StorageResourceNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            guard !node.children.isEmpty else { return [] }
            if node.kind == .dockerBuildCache { return [] }
            let childGroups = node.children
                .filter { !$0.children.isEmpty && $0.kind != .dockerBuildCache }
                .map(\.id)
            return [node.id] + childGroups
        }
    }
}

struct StorageResourceTreeRow: Identifiable {
    let node: StorageResourceNode
    let depth: Int
    var id: String { node.id }
    var hasChildren: Bool { !node.children.isEmpty }
}

enum StorageResourceTreeProjection {
    static func flatten(
        nodes: [StorageResourceNode],
        expandedIDs: Set<String>
    ) -> [StorageResourceTreeRow] {
        var result: [StorageResourceTreeRow] = []
        func append(_ nodes: [StorageResourceNode], depth: Int) {
            for node in nodes {
                result.append(StorageResourceTreeRow(node: node, depth: depth))
                if expandedIDs.contains(node.id) {
                    append(node.children, depth: depth + 1)
                }
            }
        }
        append(nodes, depth: 0)
        return result
    }

    static func cleanupRequests(in node: StorageResourceNode) -> [StorageCleanupRequest] {
        var requests: [StorageCleanupRequest] = []
        if let target = node.cleanupTarget {
            requests.append(StorageCleanupRequest(
                id: node.id,
                title: node.title,
                displayBytes: node.allocatedBytes,
                target: target
            ))
        }
        for child in node.children {
            requests.append(contentsOf: cleanupRequests(in: child))
        }
        return requests
    }

    static func selectedRequests(
        nodes: [StorageResourceNode],
        selectedIDs: Set<String>
    ) -> [StorageCleanupRequest] {
        nodes.flatMap(cleanupRequests).filter { selectedIDs.contains($0.id) }
    }
}

struct StorageCleanupReviewContext: Identifiable {
    let id = UUID()
    let sourceTitle: String
    let sourceID: StorageSourceID
    let requests: [StorageCleanupRequest]
}

struct StorageCleanupReviewSheet: View {
    let context: StorageCleanupReviewContext
    let close: () -> Void
    let didFinish: (StorageCleanupSummary) -> Void
    @State private var isExecuting = false
    @State private var summary: StorageCleanupSummary?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: summary == nil ? "checklist.checked" : "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(summary?.failedCount == 0 ? Color.accentColor : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary == nil ? L10n.text("确认批量清理") : L10n.text("批量清理结果"))
                        .font(.headline)
                    Text(context.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(AppIconButtonStyle(size: 30, isFramed: false))
                    .disabled(isExecuting)
                    .accessibilityLabel(L10n.text("关闭"))
            }
            .padding(18)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(context.requests) { request in
                        cleanupRow(request)
                        if request.id != context.requests.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(minHeight: 180, maxHeight: 380)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if summary == nil {
                    Label(
                        L10n.text("将使用官方工具处理 Docker 与 worktree；文件缓存和代码仓库会移入废纸篓。执行前会再次核对资源身份。"),
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if let summary {
                    Label(
                        L10n.format("成功 %d 项，失败 %d 项", summary.succeededCount, summary.failedCount),
                        systemImage: summary.failedCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(summary.failedCount == 0 ? Color.green : Color.orange)
                }
                HStack {
                    Text(L10n.format("共 %@", AgentStorageSizeFormatter.string(totalBytes)))
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                    Spacer()
                    Button(summary == nil ? L10n.text("取消") : L10n.text("关闭"), action: close)
                        .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .large))
                        .disabled(isExecuting)
                    if summary == nil {
                        Button(role: .destructive) {
                            execute()
                        } label: {
                            if isExecuting {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("正在清理"))
                                }
                            } else {
                                Text(L10n.format("清理 %d 项", context.requests.count))
                            }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .destructive, size: .large))
                        .disabled(isExecuting)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 620)
        .frame(minHeight: 430)
    }

    private func cleanupRow(_ request: StorageCleanupRequest) -> some View {
        let outcome = summary?.outcomes.first { $0.id == request.id }
        return HStack(spacing: 10) {
            Image(systemName: outcome.map { $0.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill" } ?? "square.dashed")
                .foregroundStyle(outcome.map { $0.succeeded ? Color.green : Color.red } ?? Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(request.title)).font(.callout.weight(.medium)).lineLimit(1)
                if let error = outcome?.errorDescription {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Text(AgentStorageSizeFormatter.string(request.displayBytes))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private var totalBytes: UInt64 {
        context.requests.reduce(UInt64.zero) {
            let sum = $0.addingReportingOverflow($1.displayBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    private func execute() {
        isExecuting = true
        let requests = context.requests
        Task {
            let result = await StorageResourceCleanupExecutor().execute(requests)
            await MainActor.run {
                summary = result
                isExecuting = false
                didFinish(result)
            }
        }
    }
}
