import AppKit
import Darwin
import FindDiskKillerCore
import SwiftUI

struct StorageResourceTreeView: View {
    let projection: StorageResourceTreeIndex
    let categoryDescription: (String) -> String
    let onSelectionInteraction: () -> Void
    @Binding var selectedIDs: Set<String>
    @State private var expandedIDs: Set<String>
    @State private var visibleRows: [StorageResourceTreeRow]
    @State private var didCustomizeExpansion = false
    @State private var rowUpdateTask: Task<Void, Never>?

    init(
        projection: StorageResourceTreeIndex,
        categoryDescription: @escaping (String) -> String,
        selectedIDs: Binding<Set<String>>,
        onSelectionInteraction: @escaping () -> Void = {}
    ) {
        self.projection = projection
        self.categoryDescription = categoryDescription
        self.onSelectionInteraction = onSelectionInteraction
        _selectedIDs = selectedIDs
        _expandedIDs = State(initialValue: projection.defaultExpandedIDs)
        _visibleRows = State(initialValue: projection.defaultRows)
    }

    var body: some View {
        let selectionCounts = projection.selectionCounts(for: selectedIDs)
        VStack(spacing: 0) {
            ForEach(visibleRows) { row in
                if row.id != visibleRows.first?.id {
                    Divider().padding(.leading, CGFloat(row.depth) * 20 + 40)
                }
                resourceRow(row, selectedCount: selectionCounts[row.node.id] ?? 0)
            }
        }
        .onChange(of: projection.id) { _, _ in
            rowUpdateTask?.cancel()
            guard !didCustomizeExpansion else {
                visibleRows = projection.flatten(expandedIDs: expandedIDs)
                return
            }
            expandedIDs = projection.defaultExpandedIDs
            visibleRows = projection.defaultRows
        }
        .onDisappear { rowUpdateTask?.cancel() }
    }

    private func resourceRow(
        _ row: StorageResourceTreeRow,
        selectedCount: Int
    ) -> some View {
        let requestIDs = projection.cleanupRequestIDsByNodeID[row.node.id] ?? []
        return HStack(alignment: .center, spacing: 10) {
            treeIndent(depth: row.depth)
            Button {
                toggleExpansion(row.node.id)
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
                requestIDs: requestIDs,
                selectedCount: selectedCount
            )
            Image(systemName: row.node.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(riskColor(row.node.risk))
                .frame(width: 24, height: 24)
                .background(riskColor(row.node.risk).opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(localizedTitle(for: row.node))
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
            toggleExpansion(row.node.id)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func selectionControl(
        node: StorageResourceNode,
        requestIDs: Set<String>,
        selectedCount: Int
    ) -> some View {
        if requestIDs.isEmpty {
            Image(systemName: node.isProtected ? "lock.fill" : "minus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .help(cleanupHelp(for: node))
        } else {
            Button {
                onSelectionInteraction()
                if selectedCount == requestIDs.count {
                    selectedIDs.subtract(requestIDs)
                } else {
                    selectedIDs.formUnion(requestIDs)
                }
            } label: {
                Image(systemName: selectionSymbol(
                    selectedCount: selectedCount,
                    totalCount: requestIDs.count
                ))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
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
        if let localization = node.detailLocalization {
            return localization.map(localizedText).joined(separator: " · ")
        }
        if let detail = node.detail, !detail.isEmpty {
            return localizedDetail(detail)
        }
        return categoryDescription(node.title)
    }

    private func localizedTitle(for node: StorageResourceNode) -> String {
        node.titleLocalization.map(localizedText) ?? L10n.text(node.title)
    }

    private func localizedText(_ text: StorageLocalizedText) -> String {
        text.arguments.isEmpty
            ? L10n.text(text.key)
            : L10n.format(text.key, arguments: text.arguments)
    }

    private func localizedDetail(_ detail: String) -> String {
        let parts = detail.components(separatedBy: " · ")
        return parts.map(L10n.text).joined(separator: " · ")
    }

    private func evidenceTitle(_ evidence: StorageMeasurementEvidence) -> String {
        switch evidence {
        case .fileSystemAllocated: L10n.text("物理分配")
        case .providerReported: L10n.text("提供者报告")
        case .logicalOnly: L10n.text("逻辑大小")
        }
    }

    private func cleanupHelp(for node: StorageResourceNode) -> String {
        guard let target = node.cleanupTarget else {
            return node.isProtected
                ? L10n.text("此资源受保护或必须通过官方工具管理")
                : L10n.text("此资源不提供直接清理")
        }
        switch target {
        case .trashRepository:
            return L10n.text("将整个主仓库移入废纸篓；不会删除同目录下的其它仓库")
        case .removeGitWorktree:
            return L10n.text("移除这个 Worktree，并保留主仓库")
        case .simulatorDevice:
            return L10n.text("通过 Xcode Simulator 删除此设备及其数据")
        case .simulatorRuntime:
            return L10n.text("通过 Xcode Simulator 删除此运行时")
        case .simulatorRuntimeAsset:
            return L10n.text("删除尚未安装的模拟器运行时下载包")
        case .podmanImage:
            return L10n.text("通过 Podman 删除此镜像；执行前会再次检查容器引用")
        case .podmanContainer:
            return L10n.text("通过 Podman 删除此已停止容器")
        case .podmanVolume:
            return L10n.text("通过 Podman 删除此未被容器引用的 Volume")
        default:
            return L10n.text("选择此资源进行清理")
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

    private func toggleExpansion(_ nodeID: String) {
        didCustomizeExpansion = true
        withAnimation(.snappy(duration: 0.2)) {
            if expandedIDs.contains(nodeID) {
                expandedIDs.remove(nodeID)
            } else {
                expandedIDs.insert(nodeID)
            }
        }
        let requestedExpansion = expandedIDs
        rowUpdateTask?.cancel()
        rowUpdateTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let rows = projection.flatten(expandedIDs: requestedExpansion)
            guard !Task.isCancelled, requestedExpansion == expandedIDs else { return }
            withAnimation(.snappy(duration: 0.2)) {
                visibleRows = rows
            }
        }
    }
}

struct StorageResourceTreeRow: Identifiable, Equatable, Sendable {
    let node: StorageResourceNode
    let depth: Int
    var id: String { node.id }
    var hasChildren: Bool { !node.children.isEmpty }
}

struct StorageResourceTreeIndex: Identifiable, Equatable, Sendable {
    let id: UUID
    let nodes: [StorageResourceNode]
    let cleanupRequestIDsByNodeID: [String: Set<String>]
    let requestAncestorNodeIDs: [String: [String]]
    let requestsByID: [String: StorageCleanupRequest]
    let requestOrder: [String]
    let safeRequestIDs: Set<String>
    let defaultExpandedIDs: Set<String>
    let defaultRows: [StorageResourceTreeRow]

    static let empty = StorageResourceTreeIndex(nodes: [])

    init(nodes rawNodes: [StorageResourceNode]) {
        id = UUID()
        nodes = StorageResourceTreeProjection.presentationNodes(rawNodes)

        var cleanupRequestIDsByNodeID: [String: Set<String>] = [:]
        var requestAncestorNodeIDs: [String: [String]] = [:]
        var requestsByID: [String: StorageCleanupRequest] = [:]
        var requestOrder: [String] = []

        @discardableResult
        func index(_ node: StorageResourceNode, ancestors: [String]) -> Set<String> {
            var requestIDs = Set<String>()
            if let target = node.cleanupTarget {
                let request = StorageCleanupRequest(
                    id: node.id,
                    title: node.title,
                    displayBytes: node.allocatedBytes,
                    target: target
                )
                if requestsByID.updateValue(request, forKey: request.id) == nil {
                    requestOrder.append(request.id)
                }
                requestIDs.insert(request.id)
                requestAncestorNodeIDs[request.id] = ancestors + [node.id]
            }
            for child in node.children {
                requestIDs.formUnion(index(child, ancestors: ancestors + [node.id]))
            }
            cleanupRequestIDsByNodeID[node.id] = requestIDs
            return requestIDs
        }

        for node in nodes { index(node, ancestors: []) }
        self.cleanupRequestIDsByNodeID = cleanupRequestIDsByNodeID
        self.requestAncestorNodeIDs = requestAncestorNodeIDs
        self.requestsByID = requestsByID
        self.requestOrder = requestOrder

        safeRequestIDs = Set(
            StorageSafeCleanupProjection.safeRequests(in: nodes).map(\.id)
        )
        defaultExpandedIDs = StorageResourceTreeProjection.expansionIDs(
            to: safeRequestIDs,
            in: nodes
        ).union(
            StorageResourceTreeProjection.workspaceParentIDs(in: nodes)
        ).union(
            StorageResourceTreeProjection.providerDetailIDs(in: nodes)
        )
        defaultRows = StorageResourceTreeProjection.flatten(
            nodes: nodes,
            expandedIDs: defaultExpandedIDs
        )
    }

    func flatten(expandedIDs: Set<String>) -> [StorageResourceTreeRow] {
        StorageResourceTreeProjection.flatten(nodes: nodes, expandedIDs: expandedIDs)
    }

    func selectionCounts(for selectedIDs: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for requestID in selectedIDs {
            guard let ancestors = requestAncestorNodeIDs[requestID] else { continue }
            for nodeID in ancestors { counts[nodeID, default: 0] += 1 }
        }
        return counts
    }

    func selectedRequests(for selectedIDs: Set<String>) -> [StorageCleanupRequest] {
        requestOrder.compactMap { requestID in
            guard selectedIDs.contains(requestID) else { return nil }
            return requestsByID[requestID]
        }
    }
}

enum StorageResourceTreeProjection {
    static func presentationNodes(_ nodes: [StorageResourceNode]) -> [StorageResourceNode] {
        repositoryParentGroups(nodes.map(presentationNode))
    }

    private static func presentationNode(_ rawNode: StorageResourceNode) -> StorageResourceNode {
        let node = migratedRepositoryNode(rawNode)
        let mappedChildren = node.children.map(presentationNode)
        let groupedChildren = node.id.hasPrefix("workspace.parent.")
            ? mappedChildren
            : repositoryParentGroups(mappedChildren)
        let presentedChildren: [StorageResourceNode]
        if groupedChildren.count == 1,
           let child = groupedChildren.first,
           child.children.isEmpty,
           child.cleanupTarget == nil,
           child.allocatedBytes == node.allocatedBytes,
           child.logicalBytes == node.logicalBytes,
           child.entryCount == node.entryCount {
            presentedChildren = []
        } else {
            presentedChildren = groupedChildren
        }
        return StorageResourceNode(
            id: node.id,
            kind: node.kind,
            title: node.title,
            detail: node.detail,
            titleLocalization: node.titleLocalization,
            detailLocalization: node.detailLocalization,
            symbol: node.symbol,
            allocatedBytes: node.allocatedBytes,
            logicalBytes: node.logicalBytes,
            entryCount: node.entryCount,
            risk: node.risk,
            evidence: node.evidence,
            isProtected: node.isProtected,
            cleanupTarget: node.cleanupTarget,
            children: presentedChildren
        )
    }

    static func workspaceParentIDs(in nodes: [StorageResourceNode]) -> Set<String> {
        var result = Set<String>()
        for node in nodes {
            if node.id.hasPrefix("workspace.parent."), !node.children.isEmpty {
                result.insert(node.id)
            }
            result.formUnion(workspaceParentIDs(in: node.children))
        }
        return result
    }

    static func providerDetailIDs(in nodes: [StorageResourceNode]) -> Set<String> {
        var result = Set<String>()
        for node in nodes {
            let isProviderGroup = node.id == "docker.engine-objects"
                || node.id.hasPrefix("docker.engine.")
                || node.id == "podman.engine-objects"
                || node.id.hasPrefix("podman.engine.")
            if isProviderGroup, !node.children.isEmpty {
                result.insert(node.id)
            }
            result.formUnion(providerDetailIDs(in: node.children))
        }
        return result
    }

    private static func repositoryParentGroups(
        _ nodes: [StorageResourceNode]
    ) -> [StorageResourceNode] {
        guard !nodes.contains(where: { $0.id.hasPrefix("workspace.parent.") }) else {
            return nodes
        }

        var grouped: [String: [StorageResourceNode]] = [:]
        var standalone: [StorageResourceNode] = []
        for node in nodes {
            guard node.kind == .repository,
                  let path = repositoryPath(from: node) else {
                standalone.append(node)
                continue
            }
            let parentPath = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            grouped[parentPath, default: []].append(node)
        }

        guard !grouped.isEmpty else {
            return nodes
        }

        var groupedNodes: [String: StorageResourceNode] = [:]
        for (parentPath, children) in grouped where children.count > 1 {
            let sortedChildren = children.sorted { lhs, rhs in
                if lhs.allocatedBytes != rhs.allocatedBytes {
                    return lhs.allocatedBytes > rhs.allocatedBytes
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            groupedNodes[parentPath] = StorageResourceNode(
                id: "workspace.parent.\(stablePathHash(parentPath))",
                kind: .location,
                title: URL(fileURLWithPath: parentPath).lastPathComponent,
                detail: L10n.format("上级目录 · %@", parentPath),
                symbol: "folder.fill",
                allocatedBytes: sortedChildren.reduce(UInt64.zero) {
                    let sum = $0.addingReportingOverflow($1.allocatedBytes)
                    return sum.overflow ? .max : sum.partialValue
                },
                logicalBytes: sortedChildren.reduce(UInt64.zero) {
                    let sum = $0.addingReportingOverflow($1.logicalBytes)
                    return sum.overflow ? .max : sum.partialValue
                },
                entryCount: sortedChildren.reduce(0) { $0 + $1.entryCount },
                risk: .environmentOrRuntime,
                evidence: .fileSystemAllocated,
                isProtected: false,
                children: sortedChildren
            )
        }

        var emittedParents = Set<String>()
        var result: [StorageResourceNode] = []
        for node in nodes {
            guard node.kind == .repository,
                  let path = repositoryPath(from: node) else {
                result.append(node)
                continue
            }
            let parentPath = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            if let parent = groupedNodes[parentPath] {
                if emittedParents.insert(parentPath).inserted {
                    result.append(parent)
                }
            } else {
                result.append(node)
            }
        }
        return result
    }

    private static func migratedRepositoryNode(
        _ node: StorageResourceNode
    ) -> StorageResourceNode {
        guard node.kind == .repository,
              node.cleanupTarget == nil,
              let path = repositoryPath(from: node),
              !containsCurrentDirectory(path),
              let identity = pathIdentity(path),
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appending(path: ".git").path)
        else { return node }
        return StorageResourceNode(
            id: node.id,
            kind: node.kind,
            title: node.title,
            detail: node.detail,
            titleLocalization: node.titleLocalization,
            detailLocalization: node.detailLocalization,
            symbol: node.symbol,
            allocatedBytes: node.allocatedBytes,
            logicalBytes: node.logicalBytes,
            entryCount: node.entryCount,
            risk: node.risk,
            evidence: node.evidence,
            isProtected: node.isProtected,
            cleanupTarget: .trashRepository(path: path, identity: identity),
            children: node.children
        )
    }

    private static func repositoryPath(from node: StorageResourceNode) -> String? {
        guard node.kind == .repository,
              let detail = node.detail,
              let path = detail.components(separatedBy: " · ").last,
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func pathIdentity(_ path: String) -> StoragePathIdentity? {
        let resolved = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var value = stat()
        guard stat(resolved.path, &value) == 0 else { return nil }
        return StoragePathIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    private static func containsCurrentDirectory(_ path: String) -> Bool {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return current == path || current.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    private static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func expansionIDs(
        to targetIDs: Set<String>,
        in nodes: [StorageResourceNode]
    ) -> Set<String> {
        var expandedIDs = Set<String>()

        @discardableResult
        func containsTarget(_ node: StorageResourceNode) -> Bool {
            let childContainsTarget = node.children.reduce(false) { containsTargetSoFar, child in
                containsTarget(child) || containsTargetSoFar
            }
            if childContainsTarget {
                expandedIDs.insert(node.id)
            }
            return targetIDs.contains(node.id) || childContainsTarget
        }

        for node in nodes { containsTarget(node) }
        return expandedIDs
    }

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
                Text(cleanupTargetDetail(request.target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    private func cleanupTargetDetail(_ target: StorageResourceCleanupTarget) -> String {
        switch target {
        case .trashRepository:
            return L10n.text("主仓库 · 整个目录移入废纸篓")
        case .removeGitWorktree:
            return L10n.text("Worktree · 保留主仓库")
        case .removePathContents:
            return L10n.text("可重建缓存 · 移入废纸篓后自动重建目录")
        case .simulatorDevice:
            return L10n.text("模拟器设备 · 通过 Xcode Simulator 删除")
        case .simulatorRuntime:
            return L10n.text("模拟器运行时 · 通过 Xcode Simulator 删除")
        case .simulatorRuntimeAsset:
            return L10n.text("未安装运行时下载包 · 移入废纸篓")
        case .dockerImage:
            return L10n.text("Docker 镜像 · 通过 Docker 命令删除")
        case .dockerContainer:
            return L10n.text("Docker 容器 · 通过 Docker 命令删除")
        case .dockerVolume:
            return L10n.text("Docker Volume · 通过 Docker 命令删除")
        case .podmanImage:
            return L10n.text("Podman 镜像 · 通过 Podman 命令删除")
        case .podmanContainer:
            return L10n.text("Podman 容器 · 通过 Podman 命令删除")
        case .podmanVolume:
            return L10n.text("Podman Volume · 通过 Podman 命令删除")
        }
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
