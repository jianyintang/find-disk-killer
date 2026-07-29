import FindDiskKillerCore
import SwiftUI

struct AgentStorageBatchCleanupContext: Identifiable, Sendable {
    let id = UUID()
    let provider: AgentStorageProvider
    let families: [AgentStorageThreadFamily]
    let scannedAt: Date
    let hidesPrivateDetails: Bool
}

struct AgentStorageBatchCleanupProjection: Equatable, Sendable {
    let families: [AgentStorageThreadFamily]
    let projects: [String]
}

enum AgentStorageBatchCleanupEngine {
    static let defaultTimeRange = AgentStorageTimeRange.thirtyDays

    static func project(
        families: [AgentStorageThreadFamily],
        timeRange: AgentStorageTimeRange,
        selectedProject: String?,
        query: String,
        relativeTo referenceDate: Date,
        hidesPrivateDetails: Bool
    ) -> AgentStorageBatchCleanupProjection {
        let oldFamilies = families.filter {
            timeRange != .all && timeRange.includes(updatedAt: $0.updatedAt, relativeTo: referenceDate)
        }
        let projects = Array(Set(oldFamilies.map(\.project))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = oldFamilies.filter { family in
            guard selectedProject == nil || family.project == selectedProject else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            if hidesPrivateDetails {
                return family.provider.displayName.localizedCaseInsensitiveContains(normalizedQuery)
                    || family.nativeThreadID.localizedCaseInsensitiveContains(normalizedQuery)
                    || family.subagents.contains {
                        $0.nativeID.localizedCaseInsensitiveContains(normalizedQuery)
                    }
            }
            return family.title.localizedCaseInsensitiveContains(normalizedQuery)
                || family.project.localizedCaseInsensitiveContains(normalizedQuery)
                || family.nativeThreadID.localizedCaseInsensitiveContains(normalizedQuery)
                || family.subagents.contains {
                    $0.title.localizedCaseInsensitiveContains(normalizedQuery)
                        || $0.nativeID.localizedCaseInsensitiveContains(normalizedQuery)
                }
        }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        return AgentStorageBatchCleanupProjection(families: matching, projects: projects)
    }
}

struct AgentStorageBatchCleanupSheet: View {
    private static let pageSize = 50

    let context: AgentStorageBatchCleanupContext
    let close: () -> Void
    let didFinish: (AgentStorageCleanupResult) -> Void

    @State private var timeRange = AgentStorageBatchCleanupEngine.defaultTimeRange
    @State private var selectedProject: String?
    @State private var query = ""
    @State private var projection: AgentStorageBatchCleanupProjection
    @State private var selectedIDs: Set<String> = []
    @State private var pageIndex = 0
    @State private var projectionGeneration = 0
    @State private var projectionTask: Task<Void, Never>?
    @State private var isUpdating = false
    @State private var reviewGeneration = 0
    @State private var reviewTask: Task<Void, Never>?
    @State private var isReviewUpdating = false
    @State private var selectedReview: AgentStorageCleanupReview?
    @State private var cleanupSession: AgentStorageCleanupSession?

    init(
        context: AgentStorageBatchCleanupContext,
        close: @escaping () -> Void,
        didFinish: @escaping (AgentStorageCleanupResult) -> Void
    ) {
        self.context = context
        self.close = close
        self.didFinish = didFinish
        _projection = State(initialValue: AgentStorageBatchCleanupEngine.project(
            families: context.families,
            timeRange: AgentStorageBatchCleanupEngine.defaultTimeRange,
            selectedProject: nil,
            query: "",
            relativeTo: context.scannedAt,
            hidesPrivateDetails: context.hidesPrivateDetails
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rangeControls
            Divider()
            cleanupToolbar
            Divider()
            threadList
            Divider()
            footer
        }
        .frame(minWidth: 840, idealWidth: 980, minHeight: 680, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: timeRange) { _, _ in scheduleProjection() }
        .onChange(of: selectedProject) { _, _ in scheduleProjection() }
        .onChange(of: query) { _, _ in scheduleProjection(debounce: .milliseconds(140)) }
        .onChange(of: selectedIDs) { _, _ in scheduleReview() }
        .onDisappear {
            projectionTask?.cancel()
            reviewTask?.cancel()
        }
        .sheet(item: $cleanupSession) { session in
            AgentStorageCleanupReviewView(
                session: session,
                close: { cleanupSession = nil },
                didFinish: didFinish
            )
            .interactiveDismissDisabled(session.phase == .deleting)
        }
        .accessibilityIdentifier("agent-storage-batch-cleanup-sheet")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("批量清理聊天"))
                    .font(.title3.weight(.semibold))
                Text(L10n.text("确定清理范围，再选择要交给官方接口永久删除的聊天。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Label(context.provider.displayName, systemImage: providerSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("关闭"))
            .accessibilityLabel(L10n.text("关闭批量清理"))
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
        .background(.bar)
    }

    private var rangeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                rangeSummary
                    .frame(width: 250, alignment: .leading)
                agePresetGroup
                    .frame(width: 278)
                compactAgeSlider
                    .frame(minWidth: 190)
                updateIndicator
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    rangeSummary
                    Spacer(minLength: 8)
                    updateIndicator
                }
                HStack(spacing: 12) {
                    agePresetGroup
                    compactAgeSlider
                        .frame(minWidth: 180)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
    }

    private var rangeSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("清理范围"))
                    .font(.callout.weight(.semibold))
                Text(protectionSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }

    private var updateIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isUpdating ? 1 : 0)
            .accessibilityHidden(!isUpdating)
            .accessibilityLabel(L10n.text("正在更新列表"))
    }

    private var agePresetGroup: some View {
        HStack(spacing: 6) {
            ForEach([1, 7, 30, 90], id: \.self) { days in
                agePresetButton(days)
            }
        }
    }

    private var compactAgeSlider: some View {
        HStack(spacing: 9) {
            Slider(value: logarithmicSliderValue, in: 0...1)
                .tint(Color.accentColor)
                .frame(minWidth: 96)
                .accessibilityLabel(L10n.text("未活动时间门槛"))
                .accessibilityValue(timeRange.inactiveTitle ?? "")
            TextField("", value: inactiveDays, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 38, height: 24)
                .padding(.horizontal, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.28)) }
                .accessibilityLabel(L10n.text("未活动时间门槛"))
            Text(L10n.text("天"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func agePresetButton(_ days: Int) -> some View {
        let isSelected = timeRange.inactiveDays == days
        return Button {
            timeRange = .olderThan(days: days)
        } label: {
            Text(L10n.format("%d 天", days))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.11)
                : Color(nsColor: .controlBackgroundColor).opacity(0.48),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.5)
                        : Color(nsColor: .separatorColor).opacity(0.42)
                )
        }
        .accessibilityLabel(L10n.format("超过 %d 天未活动", days))
        .accessibilityValue(isSelected ? L10n.text("已选择") : L10n.text("未选择"))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.accentColor)
            TextField(L10n.text("在可清理聊天中搜索"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("清空搜索"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65))
        }
        .accessibilityElement(children: .contain)
    }

    private var projectMenu: some View {
        Menu {
            Button(L10n.text("所有项目")) { selectedProject = nil }
            Divider()
            ForEach(projection.projects, id: \.self) { project in
                Button(localizedAgentStorageProjectName(project)) {
                    selectedProject = project
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(selectedProject.map(localizedAgentStorageProjectName) ?? L10n.text("所有项目"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5))
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 190)
        .accessibilityLabel(L10n.text("按项目缩小范围"))
    }

    private var cleanupToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                    .frame(minWidth: 240, maxWidth: .infinity)
                projectMenu
                resultCount
                selectionMenu
            }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    searchField
                    projectMenu
                }
                HStack(spacing: 10) {
                    resultCount
                    Spacer(minLength: 8)
                    selectionMenu
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var resultCount: some View {
        Text(L10n.format("%d 个聊天可选择", projection.families.count))
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                toggleCurrentPage()
            } label: {
                Label(
                    currentPageIsSelected ? L10n.text("取消选择本页") : L10n.text("选择本页"),
                    systemImage: currentPageSelectionSymbol
                )
            }
            .disabled(currentPageFamilies.isEmpty)

            Button {
                toggleAllMatching()
            } label: {
                Label(
                    allMatchingAreSelected
                        ? L10n.text("取消选择全部结果")
                        : L10n.format("选择全部 %d 个结果", projection.families.count),
                    systemImage: allMatchingAreSelected ? "checkmark.square.fill" : "square.stack.3d.up"
                )
            }
            .disabled(projection.families.isEmpty)

            Divider()

            Button {
                selectedIDs = []
            } label: {
                Label(L10n.text("清除选择"), systemImage: "xmark")
            }
            .disabled(selectedIDs.isEmpty)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selectedIDs.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                Text(L10n.text("批量选择"))
                Text(selectedIDs.count.formatted())
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Color.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(
                        selectedIDs.isEmpty
                            ? Color(nsColor: .separatorColor).opacity(0.28)
                            : Color.accentColor,
                        in: Circle()
                    )
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selectedIDs.isEmpty ? Color.primary : Color.accentColor)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                selectedIDs.isEmpty
                    ? Color(nsColor: .controlBackgroundColor).opacity(0.72)
                    : Color.accentColor.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        selectedIDs.isEmpty
                            ? Color(nsColor: .separatorColor).opacity(0.5)
                            : Color.accentColor.opacity(0.4)
                    )
            }
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(L10n.text("批量选择"))
        .accessibilityValue(L10n.format("已选择 %d 个聊天", selectedIDs.count))
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("聊天"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("最近活动"))
                    .frame(width: 104, alignment: .leading)
                Text(L10n.text("独占文件"))
                    .frame(width: 92, alignment: .trailing)
                Text(L10n.text("预计立即释放"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 150, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .frame(height: 38)

            Divider()

            if projection.families.isEmpty, !isUpdating {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.teal)
                        .frame(width: 64, height: 64)
                        .background(Color.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    Text(L10n.text("没有符合范围的聊天"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.text("调整未活动时间、项目或搜索条件。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(currentPageFamilies) { family in
                            threadRow(family)
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }

            if totalPages > 1 {
                Divider()
                pagination
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threadRow(_ family: AgentStorageThreadFamily) -> some View {
        let row = AgentStorageChatRow(family: family, hidesPrivateDetails: context.hidesPrivateDetails)
        let artifacts = AgentStorageCleanupValidator.officialArtifacts(for: family)
        let immediateBytes = artifacts.reduce(UInt64.zero) {
            let sum = $0.addingReportingOverflow($1.allocatedBytes)
            return sum.overflow ? .max : sum.partialValue
        }
        let isSelected = selectedIDs.contains(family.id)
        return Button {
            toggleSelection(family.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(row.project)
                        if family.subagentCount > 0 {
                            Text("·")
                            Text(L10n.format("%d 个子代理", family.subagentCount))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(family.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .leading)
                Text(artifacts.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
                Text(AgentStorageSizeFormatter.string(immediateBytes))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(immediateBytes > 0 ? Color.primary : Color.secondary)
                    .frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .accessibilityValue(isSelected ? L10n.text("已选择") : L10n.text("未选择"))
        .accessibilityHint(L10n.text("切换此聊天的清理选择"))
    }

    private var pagination: some View {
        HStack(spacing: 10) {
            Text(L10n.format("共 %d 个符合范围的聊天", projection.families.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { pageIndex -= 1 } label: {
                Image(systemName: "chevron.left").frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(pageIndex == 0)
            .help(L10n.text("上一页"))
            Text(L10n.format("第 %d / %d 页", pageIndex + 1, totalPages))
                .font(.caption.weight(.medium).monospacedDigit())
                .frame(minWidth: 72)
            Button { pageIndex += 1 } label: {
                Image(systemName: "chevron.right").frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(pageIndex + 1 >= totalPages)
            .help(L10n.text("下一页"))
        }
        .padding(.horizontal, 22)
        .frame(height: 42)
        .background(.bar)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                footerMetrics
                Spacer(minLength: 16)
                footerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                footerMetrics
                HStack {
                    Spacer(minLength: 0)
                    footerActions
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.green.opacity(0.5)).frame(height: 1)
        }
    }

    private var footerMetrics: some View {
        HStack(spacing: 22) {
            footerMetric(
                L10n.text("已选聊天"),
                selectedFamilies.count.formatted(),
                symbol: "checkmark.circle.fill",
                color: .blue
            )
            footerMetric(
                L10n.text("独占文件"),
                isReviewUpdating ? "—" : (selectedReview?.artifacts.count ?? 0).formatted(),
                symbol: "doc.fill",
                color: .teal
            )
            footerMetric(
                L10n.text("预计立即释放"),
                isReviewUpdating
                    ? "—"
                    : AgentStorageSizeFormatter.string(selectedReview?.reclaimableBytes ?? 0),
                symbol: "arrow.down.to.line.compact",
                color: .green,
                valueColor: (selectedReview?.reclaimableBytes ?? 0) > 0 ? .green : .secondary
            )
            if isReviewUpdating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("正在计算预计释放空间"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button(L10n.text("取消"), action: close)
                .keyboardShortcut(.cancelAction)
            Button {
                guard let selectedReview else { return }
                cleanupSession = AgentStorageCleanupSession(review: selectedReview)
            } label: {
                Label(L10n.text("检查并清理"), systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedFamilies.isEmpty || isReviewUpdating || selectedReview == nil)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("agent-storage-review-cleanup")
        }
        .controlSize(.large)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func footerMetric(
        _ title: String,
        _ value: String,
        symbol: String,
        color: Color,
        valueColor: Color = .primary
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(height: 24, alignment: .bottomLeading)
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(valueColor)
            }
        }
        .frame(width: 140, alignment: .leading)
    }

    private var providerSymbol: String {
        context.provider == .codex ? "terminal" : "bubble.left.and.text.bubble.right"
    }

    private var protectionSummary: String {
        L10n.format("最近 %d 天的聊天受到保护，不会出现在可选列表中。", timeRange.inactiveDays ?? 30)
    }

    private var inactiveDays: Binding<Int> {
        Binding(
            get: { timeRange.inactiveDays ?? 30 },
            set: { timeRange = .olderThan(days: $0) }
        )
    }

    private var logarithmicSliderValue: Binding<Double> {
        Binding(
            get: {
                let days = Double(timeRange.inactiveDays ?? 30)
                return log(days) / log(Double(AgentStorageTimeRange.maximumInactiveDays))
            },
            set: { value in
                let days = Int(round(pow(
                    Double(AgentStorageTimeRange.maximumInactiveDays),
                    min(1, max(0, value))
                )))
                timeRange = .olderThan(days: days)
            }
        )
    }

    private var selectedFamilies: [AgentStorageThreadFamily] {
        projection.families.filter { selectedIDs.contains($0.id) }
    }

    private var totalPages: Int {
        max(1, (projection.families.count + Self.pageSize - 1) / Self.pageSize)
    }

    private var currentPageFamilies: ArraySlice<AgentStorageThreadFamily> {
        let start = min(projection.families.count, pageIndex * Self.pageSize)
        let end = min(projection.families.count, start + Self.pageSize)
        return projection.families[start..<end]
    }

    private var currentPageIDs: Set<String> {
        Set(currentPageFamilies.map(\.id))
    }

    private var currentPageIsSelected: Bool {
        !currentPageIDs.isEmpty && currentPageIDs.isSubset(of: selectedIDs)
    }

    private var currentPageSelectionSymbol: String {
        let count = currentPageIDs.intersection(selectedIDs).count
        if currentPageIsSelected { return "checkmark.square.fill" }
        return count > 0 ? "minus.square.fill" : "square"
    }

    private var allMatchingAreSelected: Bool {
        let matchingIDs = Set(projection.families.map(\.id))
        return !matchingIDs.isEmpty && matchingIDs.isSubset(of: selectedIDs)
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleCurrentPage() {
        selectedIDs = AgentStorageBatchSelectionEngine.togglingCurrentPage(
            selectedIDs: selectedIDs,
            pageFamilyIDs: currentPageIDs
        )
    }

    private func toggleAllMatching() {
        let matchingIDs = Set(projection.families.map(\.id))
        selectedIDs = allMatchingAreSelected ? [] : matchingIDs
    }

    private func scheduleProjection(debounce: Duration? = nil) {
        projectionTask?.cancel()
        projectionGeneration &+= 1
        let requestedGeneration = projectionGeneration
        let families = context.families
        let range = timeRange
        let project = selectedProject
        let currentQuery = query
        let referenceDate = context.scannedAt
        let hidesPrivateDetails = context.hidesPrivateDetails
        isUpdating = true

        projectionTask = Task { @MainActor in
            do {
                await Task.yield()
                if let debounce { try await Task.sleep(for: debounce) }
                let worker = Task.detached(priority: .userInitiated) {
                    AgentStorageBatchCleanupEngine.project(
                        families: families,
                        timeRange: range,
                        selectedProject: project,
                        query: currentQuery,
                        relativeTo: referenceDate,
                        hidesPrivateDetails: hidesPrivateDetails
                    )
                }
                let result = await worker.value
                try Task.checkCancellation()
                guard projectionGeneration == requestedGeneration else { return }
                projection = result
                selectedIDs.formIntersection(Set(result.families.map(\.id)))
                pageIndex = 0
                isUpdating = false
                projectionTask = nil
            } catch is CancellationError {
                // The next projection owns the visible updating state.
            } catch {
                guard projectionGeneration == requestedGeneration else { return }
                isUpdating = false
                projectionTask = nil
            }
        }
    }

    private func scheduleReview() {
        reviewTask?.cancel()
        reviewGeneration &+= 1
        let requestedGeneration = reviewGeneration
        let families = selectedFamilies
        guard !families.isEmpty else {
            selectedReview = nil
            isReviewUpdating = false
            return
        }
        isReviewUpdating = true
        reviewTask = Task { @MainActor in
            await Task.yield()
            let worker = Task.detached(priority: .userInitiated) {
                AgentStorageCleanupReview(families: families)
            }
            let review = await worker.value
            guard !Task.isCancelled, reviewGeneration == requestedGeneration else { return }
            selectedReview = review
            isReviewUpdating = false
            reviewTask = nil
        }
    }
}
