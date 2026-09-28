import AppKit
import FindDiskKillerCore
import SwiftUI

/// Dedicated detail view for container engine sources (Docker and Podman).
///
/// Instead of a generic multi-level tree, engine objects are split into four
/// flat sections (images, containers, volumes, build cache). A summary strip
/// shows the total count and footprint of each section and switches to it on
/// click; a search field, sort control and status filter narrow down large
/// collections, and host-side virtual disk storage is folded into a readonly
/// section at the bottom.
///
/// Interaction notes:
/// - Section cards and filter chips avoid `.help()` tooltips: on macOS a
///   visible tooltip swallows the following click, which made switching feel
///   unresponsive.
/// - Rows are pre-rendered into `EngineRowModel` values whenever the section,
///   query, sort or filter changes, so row views never localize or format
///   strings while scrolling or hovering.
struct ContainerEngineDetailView: View {
    enum Section: String, CaseIterable, Identifiable {
        case images
        case containers
        case volumes
        case cache

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .images: "镜像"
            case .containers: "容器"
            case .volumes: "Volumes"
            case .cache: "构建缓存"
            }
        }

        var symbol: String {
            switch self {
            case .images: "shippingbox.fill"
            case .containers: "cube.fill"
            case .volumes: "externaldrive.fill"
            case .cache: "hammer.fill"
            }
        }

        func groupID(prefix: String) -> String {
            switch self {
            case .images: "\(prefix).engine.images"
            case .containers: "\(prefix).engine.containers"
            case .volumes: "\(prefix).engine.volumes"
            case .cache: "\(prefix).engine.build-cache"
            }
        }
    }

    enum SortOption: Equatable {
        case bySize
        case byName
    }

    enum FilterOption: Equatable {
        case all
        case dangling
        case running
        case stopped
        case unreferenced
        case inUse
    }

    /// Fully resolved presentation model for one engine object row.
    struct EngineRowModel: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let size: String
        let symbol: String
        let iconColor: Color
        let chipTitle: String?
        let chipColor: Color
        let isSelectable: Bool
        let isPending: Bool
    }

    let engineTitle: String
    let engineIDPrefix: String
    let nodes: [StorageResourceNode]
    let projection: StorageResourceTreeIndex
    let pendingSynchronizationIDs: Set<String>
    let onSelectionInteraction: () -> Void
    @Binding var selectedIDs: Set<String>

    @State private var section = Section.images
    @State private var query = ""
    @State private var sortOption = SortOption.bySize
    @State private var filterOption = FilterOption.all
    @State private var presentedRows: [EngineRowModel] = []
    @State private var isPhysicalStorageExpanded = false
    @State private var rowUpdateTask: Task<Void, Never>?

    init(
        engineTitle: String,
        engineIDPrefix: String,
        nodes: [StorageResourceNode],
        projection: StorageResourceTreeIndex,
        pendingSynchronizationIDs: Set<String>,
        selectedIDs: Binding<Set<String>>,
        onSelectionInteraction: @escaping () -> Void
    ) {
        self.engineTitle = engineTitle
        self.engineIDPrefix = engineIDPrefix
        self.nodes = nodes
        self.projection = projection
        self.pendingSynchronizationIDs = pendingSynchronizationIDs
        self.onSelectionInteraction = onSelectionInteraction
        _selectedIDs = selectedIDs
        _presentedRows = State(initialValue: Self.makeRows(
            nodes: nodes,
            projection: projection,
            section: .images,
            query: "",
            sortOption: .bySize,
            filterOption: .all,
            prefix: engineIDPrefix,
            pendingIDs: pendingSynchronizationIDs
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionSummaryStrip
            toolRow
            engineSectionList
            physicalStorageSection
        }
        .onChange(of: query) { _, _ in rebuildRows() }
        .onChange(of: sortOption) { _, _ in rebuildRows() }
        .onChange(of: filterOption) { _, _ in rebuildRows() }
        .onChange(of: projection.id) { _, _ in rebuildRows() }
        .onChange(of: pendingSynchronizationIDs) { _, _ in rebuildRows() }
        .onDisappear { rowUpdateTask?.cancel() }
    }

    // MARK: - Section model

    private var engineObjectsID: String { "\(engineIDPrefix).engine-objects" }

    private var engineGroups: [Section: StorageResourceNode] {
        guard let objects = nodes.first(where: { $0.id == engineObjectsID }) else {
            return [:]
        }
        var result: [Section: StorageResourceNode] = [:]
        for child in objects.children {
            for candidate in Section.allCases where child.id == candidate.groupID(prefix: engineIDPrefix) {
                result[candidate] = child
            }
        }
        return result
    }

    private var physicalStorageNode: StorageResourceNode? {
        nodes.first { $0.id == "\(engineIDPrefix).physical-storage" }
    }

    private var engineIsUnavailable: Bool {
        engineGroups.isEmpty
    }

    private func groupFor(_ candidate: Section) -> StorageResourceNode? {
        engineGroups[candidate]
    }

    private var filterOptions: [FilterOption] {
        switch section {
        case .images: [.all, .dangling]
        case .containers: [.all, .running, .stopped]
        case .volumes: [.all, .unreferenced]
        case .cache: [.all, .inUse]
        }
    }

    // MARK: - Row model building

    private func rebuildRows() {
        rowUpdateTask?.cancel()
        rowUpdateTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            presentedRows = Self.makeRows(
                nodes: nodes,
                projection: projection,
                section: section,
                query: query,
                sortOption: sortOption,
                filterOption: filterOption,
                prefix: engineIDPrefix,
                pendingIDs: pendingSynchronizationIDs
            )
        }
    }

    private static func makeRows(
        nodes: [StorageResourceNode],
        projection: StorageResourceTreeIndex,
        section: Section,
        query: String,
        sortOption: SortOption,
        filterOption: FilterOption,
        prefix: String,
        pendingIDs: Set<String>
    ) -> [EngineRowModel] {
        let objects = nodes.first { $0.id == "\(prefix).engine-objects" }
        let group = objects?.children.first { $0.id == section.groupID(prefix: prefix) }
        guard let group else { return [] }

        var rows = group.children
        switch filterOption {
        case .all:
            break
        case .dangling:
            rows = rows.filter { $0.kind == .dockerImage && $0.risk == .rebuildableCache }
        case .running:
            rows = rows.filter { $0.isProtected }
        case .stopped:
            rows = rows.filter { !$0.isProtected }
        case .unreferenced:
            rows = rows.filter { $0.cleanupTarget != nil }
        case .inUse:
            rows = rows.filter { $0.isProtected }
        }
        if !query.isEmpty {
            let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            rows = rows.filter { row in
                let title = row.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if title.contains(needle) { return true }
                let detail = detailText(row).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return detail.contains(needle)
            }
        }
        switch sortOption {
        case .bySize:
            rows.sort { lhs, rhs in
                if lhs.allocatedBytes != rhs.allocatedBytes {
                    return lhs.allocatedBytes > rhs.allocatedBytes
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .byName:
            rows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        var models = rows.map { node in
            let requestIDs = projection.cleanupRequestIDsByNodeID[node.id] ?? []
            let isPending = !requestIDs.isEmpty && requestIDs.subtracting(pendingIDs).isEmpty
            let chip = statusChip(for: node)
            return EngineRowModel(
                id: node.id,
                title: node.title,
                detail: isPending ? L10n.text("已清理，等待同步确认") : detailText(node),
                size: AgentStorageSizeFormatter.string(node.allocatedBytes),
                symbol: node.symbol,
                iconColor: iconColor(for: node),
                chipTitle: chip?.title,
                chipColor: chip?.color ?? .clear,
                isSelectable: projection.requestsByID[node.id] != nil && !isPending,
                isPending: isPending
            )
        }
        if section == .cache, filterOption != .inUse,
           projection.requestsByID[group.id] != nil {
            // The Docker CLI cannot remove individual build cache records,
            // so the section offers one group-level operation that prunes
            // unused cache. It stays pinned to the top of the list.
            let unused = group.children.filter { !$0.isProtected }
            let unusedBytes = unused.reduce(UInt64.zero) { partial, node in
                let sum = partial.addingReportingOverflow(node.allocatedBytes)
                return sum.overflow ? .max : sum.partialValue
            }
            let requestIDs = projection.cleanupRequestIDsByNodeID[group.id] ?? []
            let isPending = !requestIDs.isEmpty && requestIDs.subtracting(pendingIDs).isEmpty
            models.insert(EngineRowModel(
                id: group.id,
                title: L10n.text("清理未使用的构建缓存"),
                detail: L10n.text("执行时仅清理未使用缓存"),
                size: AgentStorageSizeFormatter.string(unusedBytes),
                symbol: "hammer.fill",
                iconColor: .green,
                chipTitle: L10n.text("未使用"),
                chipColor: .green,
                isSelectable: !isPending,
                isPending: isPending
            ), at: 0)
        }
        return models
    }

    private static func detailText(_ node: StorageResourceNode) -> String {
        if let localization = node.detailLocalization, !localization.isEmpty {
            return localization.map(localizedText).joined(separator: " · ")
        }
        if let detail = node.detail, !detail.isEmpty {
            return detail.components(separatedBy: " · ").map(L10n.text).joined(separator: " · ")
        }
        return ""
    }

    private static func localizedText(_ text: StorageLocalizedText) -> String {
        text.arguments.isEmpty
            ? L10n.text(text.key)
            : L10n.format(text.key, arguments: text.arguments)
    }

    private static func statusChip(for node: StorageResourceNode) -> (title: String, color: Color)? {
        switch node.kind {
        case .dockerImage where node.risk == .rebuildableCache:
            (L10n.text("悬空"), .green)
        case .dockerContainer where node.symbol == "play.circle.fill":
            (L10n.text("运行中"), .green)
        case .dockerContainer:
            (L10n.text("已停止"), .secondary)
        default:
            nil
        }
    }

    private static func iconColor(for node: StorageResourceNode) -> Color {
        switch node.kind {
        case .dockerContainer where node.symbol == "play.circle.fill":
            .green
        default:
            riskColor(node.risk)
        }
    }

    private static func riskColor(_ risk: StorageRiskLevel) -> Color {
        switch risk {
        case .rebuildableCache: .green
        case .sharedOrExpensive: .orange
        case .environmentOrRuntime: .secondary
        case .protectedUserData: .red
        }
    }

    // MARK: - Summary strip

    private var sectionSummaryStrip: some View {
        HStack(spacing: 8) {
            ForEach(Section.allCases) { candidate in
                EngineSectionCard(
                    section: candidate,
                    isSelected: section == candidate,
                    countText: L10n.format("%d 个", groupFor(candidate)?.entryCount ?? 0),
                    sizeText: AgentStorageSizeFormatter.string(groupFor(candidate)?.allocatedBytes ?? 0)
                ) {
                    selectSection(candidate)
                }
            }
        }
    }

    private func selectSection(_ newSection: Section) {
        guard newSection != section else { return }
        withAnimation(.snappy(duration: 0.18)) {
            section = newSection
        }
        filterOption = .all
        rebuildRows()
    }

    // MARK: - Tool row

    private var toolRow: some View {
        HStack(spacing: 8) {
            searchField
            Spacer(minLength: 8)
            sortMenu
            filterChips
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.text("搜索镜像、容器、Volume 或构建缓存"), text: $query)
                .textFieldStyle(.plain)
                .font(.caption)
                .accessibilityLabel(L10n.text("搜索镜像、容器、Volume 或构建缓存"))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
    }

    private var sortMenu: some View {
        Menu {
            Button {
                sortOption = .bySize
            } label: {
                Label(L10n.text("按大小"), systemImage: sortOption == .bySize ? "checkmark" : "")
            }
            Button {
                sortOption = .byName
            } label: {
                Label(L10n.text("按名称"), systemImage: sortOption == .byName ? "checkmark" : "")
            }
        } label: {
            Label(
                L10n.text(sortOption == .bySize ? "按大小" : "按名称"),
                systemImage: "arrow.up.arrow.down"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text(sortOption == .bySize ? "按大小" : "按名称"))
    }

    private var filterChips: some View {
        HStack(spacing: 5) {
            ForEach(filterOptions, id: \.self) { option in
                Button {
                    filterOption = option
                } label: {
                    Text(chipTitle(option))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            filterOption == option
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    filterOption == option
                                        ? Color.accentColor.opacity(0.55)
                                        : Color(nsColor: .separatorColor).opacity(0.7),
                                    lineWidth: 0.5
                                )
                        }
                        .foregroundStyle(filterOption == option ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chipTitle(option))
            }
        }
    }

    private func chipTitle(_ option: FilterOption) -> String {
        switch option {
        case .all: L10n.text("全部")
        case .dangling: L10n.text("悬空镜像")
        case .running: L10n.text("运行中")
        case .stopped: L10n.text("已停止")
        case .unreferenced: L10n.text("未被引用")
        case .inUse: L10n.text("使用中")
        }
    }

    // MARK: - Section list

    @ViewBuilder
    private var engineSectionList: some View {
        if engineIsUnavailable {
            ContentUnavailableView {
                Label(
                    L10n.format("%@ Engine 资源不可用", engineTitle),
                    systemImage: "externaldrive.badge.questionmark"
                )
            } description: {
                Text(L10n.text("当前分析未能连接 Engine，仅显示宿主机物理存储。"))
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if presentedRows.isEmpty {
            if let group = groupFor(section), group.children.isEmpty {
                ContentUnavailableView {
                    Label(
                        L10n.format("当前没有%@", L10n.text(section.titleKey)),
                        systemImage: section.symbol
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ContentUnavailableView {
                    Label(
                        L10n.format("没有匹配的%@", L10n.text(section.titleKey)),
                        systemImage: "magnifyingglass"
                    )
                } description: {
                    Text(L10n.text("尝试其他关键词或清除搜索。"))
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        } else {
            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(presentedRows) { model in
                        EngineRow(
                            model: model,
                            isSelected: selectedIDs.contains(model.id),
                            pendingIDs: pendingSynchronizationIDs,
                            toggleSelection: {
                                onSelectionInteraction()
                                if selectedIDs.contains(model.id) {
                                    selectedIDs.remove(model.id)
                                } else {
                                    selectedIDs.insert(model.id)
                                }
                            }
                        )
                        if model.id != presentedRows.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: - Physical storage

    private var physicalStorageSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isPhysicalStorageExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    Text(L10n.format("%@ 宿主机物理存储", engineTitle))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let physical = physicalStorageNode {
                        Text(AgentStorageSizeFormatter.string(physical.allocatedBytes))
                            .font(.caption.monospaced().weight(.semibold))
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isPhysicalStorageExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("%@ 宿主机物理存储", engineTitle))

            if isPhysicalStorageExpanded, let physical = physicalStorageNode {
                Divider().padding(.leading, 40)
                ForEach(physical.children) { node in
                    physicalRow(node)
                    if node.id != physical.children.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func physicalRow(_ node: StorageResourceNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Image(systemName: node.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(Self.detailText(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(AgentStorageSizeFormatter.string(node.allocatedBytes))
                .font(.caption.monospaced().weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Section card

private struct EngineSectionCard: View {
    let section: ContainerEngineDetailView.Section
    let isSelected: Bool
    let countText: String
    let sizeText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        (isSelected ? Color.accentColor : Color.secondary).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.text(section.titleKey))
                            .font(.caption.weight(.semibold))
                        Text(countText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(sizeText)
                        .font(.caption.monospaced().weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : (isHovered ? Color.primary.opacity(0.045) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.55)
                            : (isHovered
                                ? Color.accentColor.opacity(0.35)
                                : Color(nsColor: .separatorColor).opacity(0.7)),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityLabel(L10n.format("查看%@", L10n.text(section.titleKey)))
    }
}

// MARK: - Engine object row

private struct EngineRow: View {
    let model: ContainerEngineDetailView.EngineRowModel
    let isSelected: Bool
    let pendingIDs: Set<String>
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            selectionControl
            Image(systemName: model.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.iconColor)
                .frame(width: 20, height: 20)
                .background(model.iconColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(model.isPending ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let chipTitle = model.chipTitle {
                Text(chipTitle)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(model.chipColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(model.chipColor)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(model.size)
                .font(.caption.monospaced().weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var selectionControl: some View {
        if model.isPending {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.green)
                .frame(width: 18, height: 18)
                .accessibilityLabel(L10n.text("已清理，等待同步确认"))
        } else if model.isSelectable {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isSelected
                    ? L10n.text("取消选择此资源")
                    : L10n.text("选择此资源进行清理")
            )
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .accessibilityLabel(L10n.text("此资源受保护或必须通过官方工具管理"))
        }
    }
}
