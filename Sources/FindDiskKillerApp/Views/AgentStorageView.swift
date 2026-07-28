import AppKit
import FindDiskKillerCore
import SwiftUI

enum AgentStorageScope: String, CaseIterable, Identifiable, Sendable {
    case chats = "聊天"
    case global = "全局"
    case unattributed = "未归属"

    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

enum AgentStorageArchiveFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case archived

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L10n.text("全部聊天")
        case .active: L10n.text("进行中")
        case .archived: L10n.text("已归档")
        }
    }
}

enum AgentStorageTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all
    case sevenDays
    case thirtyDays
    case ninetyDays

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L10n.text("全部时间")
        case .sevenDays: L10n.text("近 7 天")
        case .thirtyDays: L10n.text("近 30 天")
        case .ninetyDays: L10n.text("近 90 天")
        }
    }

    func dateInterval(relativeTo referenceDate: Date) -> Range<Date>? {
        let dayCount: Int
        switch self {
        case .all: return nil
        case .sevenDays: dayCount = 7
        case .thirtyDays: dayCount = 30
        case .ninetyDays: dayCount = 90
        }
        let calendar = Calendar.current
        let referenceDay = calendar.startOfDay(for: referenceDate)
        guard let start = calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: referenceDay
        ), let end = calendar.date(byAdding: .day, value: 1, to: referenceDay) else {
            return nil
        }
        return start..<end
    }
}

extension AgentStorageThreadFamily {
    func largestSubagents(limit: Int) -> [AgentStorageThreadNode] {
        guard limit > 0 else { return [] }
        return subagents.sorted { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes {
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }.prefix(limit).map { $0 }
    }
}

private struct AgentStorageProviderWorkspaceState {
    let scope: AgentStorageScope
    let archiveFilter: AgentStorageArchiveFilter
    let timeRange: AgentStorageTimeRange
    let selectedProject: String?
    let selectedGlobalCategory: AgentStorageGlobalCategory?
    let selectedUnattributedReason: AgentStorageUnattributedReason?
    let searchText: String
    let selection: String?
    let expandedFamilies: Set<String>
    let chatPageIndex: Int
    let chatSortOrder: [KeyPathComparator<AgentStorageChatRow>]
    let globalSortOrder: [KeyPathComparator<AgentStorageGlobalItem>]
    let unattributedSortOrder: [KeyPathComparator<AgentStorageUnattributedItem>]
}

private struct AgentStorageDetailSelection: Identifiable, Hashable {
    let id: String
}

private struct AgentStorageSummaryProjection {
    let chatBytes: UInt64
    let globalBytes: UInt64
    let unattributedBytes: UInt64
    let isComplete: Bool

    var totalBytes: UInt64 {
        let subtotal = chatBytes.addingReportingOverflow(globalBytes)
        guard !subtotal.overflow else { return .max }
        let total = subtotal.partialValue.addingReportingOverflow(unattributedBytes)
        return total.overflow ? .max : total.partialValue
    }
}

enum AgentStorageChatSortField: Sendable {
    case title
    case updatedAt
    case subagentCount
    case allocatedBytes
    case id
}

enum AgentStorageGlobalSortField: Sendable {
    case title
    case artifactCount
    case allocatedBytes
    case id
}

enum AgentStorageUnattributedSortField: Sendable {
    case title
    case artifactCount
    case allocatedBytes
    case id
}

struct AgentStorageChatSortRule: Sendable {
    let field: AgentStorageChatSortField
    let isReverse: Bool
}

struct AgentStorageGlobalSortRule: Sendable {
    let field: AgentStorageGlobalSortField
    let isReverse: Bool
}

struct AgentStorageUnattributedSortRule: Sendable {
    let field: AgentStorageUnattributedSortField
    let isReverse: Bool
}

struct AgentStorageProjectionRequest: Sendable {
    let scope: AgentStorageScope
    let dataset: AgentStorageProviderDataset
    let scannedAt: Date
    let archiveFilter: AgentStorageArchiveFilter
    let timeRange: AgentStorageTimeRange
    let selectedProject: String?
    let selectedGlobalCategory: AgentStorageGlobalCategory?
    let selectedUnattributedReason: AgentStorageUnattributedReason?
    let query: String
    let hidesPrivateDetails: Bool
    let expandedFamilies: Set<String>
    let chatPageIndex: Int
    let chatPageSize: Int
    let chatSortRules: [AgentStorageChatSortRule]
    let globalSortRules: [AgentStorageGlobalSortRule]
    let unattributedSortRules: [AgentStorageUnattributedSortRule]
}

enum AgentStorageProjectionContent: Sendable {
    case chats(
        rows: [AgentStorageChatRow],
        summary: AgentStorageChatRangeProjection,
        availableProjects: [String],
        pagination: AgentStorageChatPagination
    )
    case global([AgentStorageGlobalItem])
    case unattributed([AgentStorageUnattributedItem])
}

struct AgentStorageProjectionResult: Sendable {
    let content: AgentStorageProjectionContent
    let visibleIDs: Set<String>
}

struct AgentStorageChatPagination: Equatable, Sendable {
    static let pageSize = 50
    static let empty = AgentStorageChatPagination(pageIndex: 0, pageSize: pageSize, totalItems: 0)

    let pageIndex: Int
    let pageSize: Int
    let totalItems: Int

    var totalPages: Int {
        guard totalItems > 0 else { return 0 }
        return (totalItems + pageSize - 1) / pageSize
    }

    var hasPreviousPage: Bool { pageIndex > 0 }
    var hasNextPage: Bool { pageIndex + 1 < totalPages }
}

enum AgentStorageProjectionEngine {
    static func project(_ request: AgentStorageProjectionRequest) throws -> AgentStorageProjectionResult {
        try Task.checkCancellation()
        switch request.scope {
        case .chats:
            return try projectChats(request)
        case .global:
            return try projectGlobal(request)
        case .unattributed:
            return try projectUnattributed(request)
        }
    }

    private static func projectChats(
        _ request: AgentStorageProjectionRequest
    ) throws -> AgentStorageProjectionResult {
        let interval = request.timeRange.dateInterval(relativeTo: request.scannedAt)
        var timeFamilies: [AgentStorageThreadFamily] = []
        timeFamilies.reserveCapacity(request.dataset.families.count)
        for (index, family) in request.dataset.families.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            let isAfterCutoff = interval.map { family.updatedAt >= $0.lowerBound } ?? true
            let isBeforeUpperBound = interval.map { family.updatedAt < $0.upperBound } ?? true
            if isAfterCutoff, isBeforeUpperBound { timeFamilies.append(family) }
        }

        let availableProjects = Array(Set(timeFamilies.map(\.project))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        var matchingFamilies: [AgentStorageThreadFamily] = []
        matchingFamilies.reserveCapacity(timeFamilies.count)
        for (index, family) in timeFamilies.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard archiveMatches(family, filter: request.archiveFilter),
                  request.selectedProject == nil || family.project == request.selectedProject,
                  familyMatches(family, request: request) else { continue }
            matchingFamilies.append(family)
        }

        let summary = AgentStorageChatRangeProjection(families: matchingFamilies)
        matchingFamilies.sort { chatFamily($0, precedes: $1, request: request) }
        let pageSize = max(1, request.chatPageSize)
        let totalPages = matchingFamilies.isEmpty
            ? 0
            : (matchingFamilies.count + pageSize - 1) / pageSize
        let pageIndex = min(max(0, request.chatPageIndex), max(0, totalPages - 1))
        let pageStart = min(matchingFamilies.count, pageIndex * pageSize)
        let pageEnd = min(matchingFamilies.count, pageStart + pageSize)
        let pageFamilies = matchingFamilies[pageStart..<pageEnd]
        var rows: [AgentStorageChatRow] = []
        rows.reserveCapacity(pageFamilies.count + request.expandedFamilies.count * 4)
        for (index, family) in pageFamilies.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            let root = AgentStorageChatRow(
                family: family,
                hidesPrivateDetails: request.hidesPrivateDetails
            )
            rows.append(root)
            if request.expandedFamilies.contains(root.familyID) {
                rows.append(contentsOf: try projectedSubagents(family, request: request))
            } else if !request.query.isEmpty,
                      !familyTitleMatches(family, request: request) {
                rows.append(contentsOf: try projectedSubagents(family, request: request))
            }
        }

        var seenIDs = Set<String>()
        let uniqueRows = rows.filter { seenIDs.insert($0.id).inserted }
        return AgentStorageProjectionResult(
            content: .chats(
                rows: uniqueRows,
                summary: summary,
                availableProjects: availableProjects,
                pagination: AgentStorageChatPagination(
                    pageIndex: pageIndex,
                    pageSize: pageSize,
                    totalItems: matchingFamilies.count
                )
            ),
            visibleIDs: seenIDs
        )
    }

    private static func projectGlobal(
        _ request: AgentStorageProjectionRequest
    ) throws -> AgentStorageProjectionResult {
        var items: [AgentStorageGlobalItem] = []
        items.reserveCapacity(request.dataset.globalItems.count)
        for (index, item) in request.dataset.globalItems.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard request.selectedGlobalCategory == nil
                    || item.category == request.selectedGlobalCategory else { continue }
            guard request.query.isEmpty
                    || item.category.localizedTitle.localizedCaseInsensitiveContains(request.query)
                    || item.provider?.displayName.localizedCaseInsensitiveContains(request.query) == true
                    || (!request.hidesPrivateDetails
                        && item.path?.localizedCaseInsensitiveContains(request.query) == true)
            else { continue }
            items.append(item)
        }
        items.sort { globalItem($0, precedes: $1, rules: request.globalSortRules) }
        return AgentStorageProjectionResult(
            content: .global(items),
            visibleIDs: Set(items.map(\.id))
        )
    }

    private static func projectUnattributed(
        _ request: AgentStorageProjectionRequest
    ) throws -> AgentStorageProjectionResult {
        var items: [AgentStorageUnattributedItem] = []
        items.reserveCapacity(request.dataset.unattributedItems.count)
        for (index, item) in request.dataset.unattributedItems.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard request.selectedUnattributedReason == nil
                    || item.reason == request.selectedUnattributedReason else { continue }
            guard request.query.isEmpty
                    || item.reason.localizedTitle.localizedCaseInsensitiveContains(request.query)
                    || item.reason.localizedExplanation.localizedCaseInsensitiveContains(request.query)
                    || (!request.hidesPrivateDetails
                        && item.path?.localizedCaseInsensitiveContains(request.query) == true)
            else { continue }
            items.append(item)
        }
        items.sort { unattributedItem($0, precedes: $1, rules: request.unattributedSortRules) }
        return AgentStorageProjectionResult(
            content: .unattributed(items),
            visibleIDs: Set(items.map(\.id))
        )
    }

    private static func projectedSubagents(
        _ family: AgentStorageThreadFamily,
        request: AgentStorageProjectionRequest
    ) throws -> [AgentStorageChatRow] {
        try Task.checkCancellation()
        let nodesByParent = Dictionary(grouping: family.subagents) {
            $0.parentID ?? family.nativeThreadID
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: family.subagents.map { ($0.nativeID, $0) })
        let rowIDByNativeID = Dictionary(uniqueKeysWithValues: family.subagents.map {
            ($0.nativeID, $0.id)
        })
        let directlyMatching = Set(family.subagents.filter {
            request.query.isEmpty || nodeMatches($0, family: family, request: request)
        }.map(\.nativeID))
        var included = directlyMatching
        if !request.query.isEmpty {
            for nodeID in directlyMatching {
                try Task.checkCancellation()
                var current = nodesByID[nodeID]
                var visited = Set<String>()
                while let parent = current?.parentID,
                      parent != family.nativeThreadID,
                      visited.insert(parent).inserted {
                    included.insert(parent)
                    current = nodesByID[parent]
                }
            }
        }

        var result: [AgentStorageChatRow] = []
        var emittedNodeIDs = Set<String>()
        func appendChildren(of parentID: String) throws {
            try Task.checkCancellation()
            let children = (nodesByParent[parentID] ?? [])
                .filter { request.query.isEmpty || included.contains($0.nativeID) }
                .map { child in
                    AgentStorageChatRow(
                        node: child,
                        family: family,
                        parentRowID: child.parentID.flatMap { rowIDByNativeID[$0] } ?? family.id,
                        hidesPrivateDetails: request.hidesPrivateDetails
                    )
                }
                .sorted { chatRow($0, precedes: $1, rules: request.chatSortRules) }
            for child in children where emittedNodeIDs.insert(child.nativeID).inserted {
                result.append(child)
                try appendChildren(of: child.nativeID)
            }
        }
        try appendChildren(of: family.nativeThreadID)
        return result
    }

    private static func archiveMatches(
        _ family: AgentStorageThreadFamily,
        filter: AgentStorageArchiveFilter
    ) -> Bool {
        switch filter {
        case .all: true
        case .active: !family.isArchived
        case .archived: family.isArchived
        }
    }

    private static func familyMatches(
        _ family: AgentStorageThreadFamily,
        request: AgentStorageProjectionRequest
    ) -> Bool {
        request.query.isEmpty
            || familyTitleMatches(family, request: request)
            || family.subagents.contains { nodeMatches($0, family: family, request: request) }
    }

    private static func familyTitleMatches(
        _ family: AgentStorageThreadFamily,
        request: AgentStorageProjectionRequest
    ) -> Bool {
        if request.hidesPrivateDetails {
            return family.provider.displayName.localizedCaseInsensitiveContains(request.query)
                || family.nativeThreadID.localizedCaseInsensitiveContains(request.query)
        }
        return family.title.localizedCaseInsensitiveContains(request.query)
            || family.project.localizedCaseInsensitiveContains(request.query)
            || family.nativeThreadID.localizedCaseInsensitiveContains(request.query)
    }

    private static func nodeMatches(
        _ node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily,
        request: AgentStorageProjectionRequest
    ) -> Bool {
        if request.hidesPrivateDetails {
            return node.nativeID.localizedCaseInsensitiveContains(request.query)
        }
        return node.title.localizedCaseInsensitiveContains(request.query)
            || node.nativeID.localizedCaseInsensitiveContains(request.query)
            || family.title.localizedCaseInsensitiveContains(request.query)
    }

    private static func chatRow(
        _ lhs: AgentStorageChatRow,
        precedes rhs: AgentStorageChatRow,
        rules: [AgentStorageChatSortRule]
    ) -> Bool {
        for rule in rules {
            let comparison: Int
            switch rule.field {
            case .title: comparison = compare(lhs.title, rhs.title)
            case .updatedAt: comparison = compare(lhs.updatedAt, rhs.updatedAt)
            case .subagentCount: comparison = compare(lhs.subagentCount, rhs.subagentCount)
            case .allocatedBytes: comparison = compare(lhs.allocatedBytes, rhs.allocatedBytes)
            case .id: comparison = compare(lhs.id, rhs.id)
            }
            if comparison != 0 { return rule.isReverse ? comparison > 0 : comparison < 0 }
        }
        return lhs.id < rhs.id
    }

    private static func chatFamily(
        _ lhs: AgentStorageThreadFamily,
        precedes rhs: AgentStorageThreadFamily,
        request: AgentStorageProjectionRequest
    ) -> Bool {
        for rule in request.chatSortRules {
            let comparison: Int
            switch rule.field {
            case .title:
                comparison = compare(
                    visibleFamilyTitle(lhs, hidesPrivateDetails: request.hidesPrivateDetails),
                    visibleFamilyTitle(rhs, hidesPrivateDetails: request.hidesPrivateDetails)
                )
            case .updatedAt: comparison = compare(lhs.updatedAt, rhs.updatedAt)
            case .subagentCount: comparison = compare(lhs.subagentCount, rhs.subagentCount)
            case .allocatedBytes: comparison = compare(lhs.allocatedBytes, rhs.allocatedBytes)
            case .id: comparison = compare(lhs.id, rhs.id)
            }
            if comparison != 0 { return rule.isReverse ? comparison > 0 : comparison < 0 }
        }
        return lhs.id < rhs.id
    }

    private static func visibleFamilyTitle(
        _ family: AgentStorageThreadFamily,
        hidesPrivateDetails: Bool
    ) -> String {
        guard hidesPrivateDetails else { return family.title }
        return "\(family.provider.displayName) \(L10n.text("聊天")) · \(family.updatedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func globalItem(
        _ lhs: AgentStorageGlobalItem,
        precedes rhs: AgentStorageGlobalItem,
        rules: [AgentStorageGlobalSortRule]
    ) -> Bool {
        for rule in rules {
            let comparison: Int
            switch rule.field {
            case .title: comparison = compare(lhs.title, rhs.title)
            case .artifactCount: comparison = compare(lhs.artifactCount, rhs.artifactCount)
            case .allocatedBytes: comparison = compare(lhs.allocatedBytes, rhs.allocatedBytes)
            case .id: comparison = compare(lhs.id, rhs.id)
            }
            if comparison != 0 { return rule.isReverse ? comparison > 0 : comparison < 0 }
        }
        return lhs.id < rhs.id
    }

    private static func unattributedItem(
        _ lhs: AgentStorageUnattributedItem,
        precedes rhs: AgentStorageUnattributedItem,
        rules: [AgentStorageUnattributedSortRule]
    ) -> Bool {
        for rule in rules {
            let comparison: Int
            switch rule.field {
            case .title: comparison = compare(lhs.title, rhs.title)
            case .artifactCount: comparison = compare(lhs.artifactCount, rhs.artifactCount)
            case .allocatedBytes: comparison = compare(lhs.allocatedBytes, rhs.allocatedBytes)
            case .id: comparison = compare(lhs.id, rhs.id)
            }
            if comparison != 0 { return rule.isReverse ? comparison > 0 : comparison < 0 }
        }
        return lhs.id < rhs.id
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }
}

struct AgentStorageView: View {
    let model: AgentStorageModel
    @AppStorage(AgentStoragePreferences.hidePrivateDetailsKey) private var hidesPrivateDetails = false
    @State private var selectedProvider: AgentStorageProvider?
    @State private var scope: AgentStorageScope = .chats
    @State private var archiveFilter: AgentStorageArchiveFilter = .all
    @State private var timeRange: AgentStorageTimeRange = .all
    @State private var selectedProject: String?
    @State private var selectedGlobalCategory: AgentStorageGlobalCategory?
    @State private var selectedUnattributedReason: AgentStorageUnattributedReason?
    @State private var searchText = ""
    @State private var selection: String?
    @State private var expandedFamilies: Set<String> = []
    @State private var visibleChatRows: [AgentStorageChatRow] = []
    @State private var visibleGlobalItems: [AgentStorageGlobalItem] = []
    @State private var visibleUnattributedItems: [AgentStorageUnattributedItem] = []
    @State private var visibleChatSummary = AgentStorageChatRangeProjection(families: [])
    @State private var chatSortOrder = [
        KeyPathComparator(\AgentStorageChatRow.updatedAt, order: .reverse),
        KeyPathComparator(\AgentStorageChatRow.id, order: .forward)
    ]
    @State private var globalSortOrder = [
        KeyPathComparator(\AgentStorageGlobalItem.allocatedBytes, order: .reverse)
    ]
    @State private var unattributedSortOrder = [
        KeyPathComparator(\AgentStorageUnattributedItem.allocatedBytes, order: .reverse)
    ]
    @State private var containerWidth: CGFloat = 0
    @State private var showsTransientDetail = false
    @State private var compactDetail: AgentStorageDetailSelection?
    @State private var familyIndex: [String: AgentStorageThreadFamily] = [:]
    @State private var detailIndex: [String: AgentStorageResolvedDetail] = [:]
    @State private var availableProjectsCache: [String] = []
    @State private var chatPageIndex = 0
    @State private var chatPagination = AgentStorageChatPagination.empty
    @State private var expandingFamilies: Set<String> = []
    @State private var providerOverviewItems: [AgentStorageProviderOverviewItem] = []
    @State private var workspaceStates: [AgentStorageProvider: AgentStorageProviderWorkspaceState] = [:]
    @State private var isRestoringWorkspace = false
    @State private var isProjecting = false
    @State private var projectionGeneration = 0
    @State private var projectionTask: Task<Void, Never>?
    @FocusState private var tableHasFocus: Bool
    @FocusState private var focusedProvider: AgentStorageProvider?
    @AccessibilityFocusState private var accessibilityFocusedProvider: AgentStorageProvider?
    @AccessibilityFocusState private var tableAccessibilityFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            Group {
                if selectedProvider == nil {
                    providerOverview
                } else {
                    mainContent(width: geometry.size.width)
                }
            }
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    containerWidth = width
                    if width >= 1_140 { showsTransientDetail = false }
                }
        }
        .navigationTitle(selectedProvider?.displayName ?? L10n.text("AI 空间"))
        .modifier(AgentStorageFocusedActions(
            refresh: { model.isScanning ? model.stop() : model.refresh() },
            back: exitAction
        ))
        .modifier(AgentStorageConditionalSearch(
            isEnabled: selectedProvider != nil,
            searchText: $searchText,
            prompt: searchPrompt
        ))
        .toolbar { featureToolbar }
        .sheet(item: $compactDetail) { detail in
            AgentStorageDetailView(
                detail: resolvedDetail(id: detail.id),
                hidesPrivateDetails: hidesPrivateDetails
            )
            .frame(minWidth: 520, minHeight: 520)
            .onDisappear { tableHasFocus = true }
        }
        .task { model.enterFeature() }
        .onChange(of: model.snapshotRevision, initial: true) { _, _ in
            rebuildSnapshotIndex(model.snapshot)
            scheduleProjection()
        }
        .onChange(of: archiveFilter) { _, _ in
            if !isRestoringWorkspace {
                resetChatPage()
                scheduleProjection()
            }
        }
        .onChange(of: timeRange) { _, _ in
            if !isRestoringWorkspace {
                clearSelectionAndDetails()
                resetChatPage()
                scheduleProjection()
            }
        }
        .onChange(of: selectedProject) { _, _ in
            if !isRestoringWorkspace {
                resetChatPage()
                scheduleProjection()
            }
        }
        .onChange(of: selectedGlobalCategory) { _, _ in
            if !isRestoringWorkspace { scheduleProjection() }
        }
        .onChange(of: selectedUnattributedReason) { _, _ in
            if !isRestoringWorkspace { scheduleProjection() }
        }
        .onChange(of: scope) { _, _ in
            if !isRestoringWorkspace { clearSelectionAndDetails() }
            if !isRestoringWorkspace { scheduleProjection() }
        }
        .onChange(of: searchText) { _, _ in
            if !isRestoringWorkspace {
                resetChatPage()
                scheduleProjection(debounce: .milliseconds(160))
            }
        }
        .onChange(of: hidesPrivateDetails) { _, isHidden in
            if isHidden { selectedProject = nil }
            scheduleProjection()
        }
        .onChange(of: chatSortOrder) { _, _ in
            resetChatPage()
            scheduleProjection()
        }
        .onChange(of: globalSortOrder) { _, _ in scheduleProjection() }
        .onChange(of: unattributedSortOrder) { _, _ in scheduleProjection() }
        .onDisappear { projectionTask?.cancel() }
        .onChange(of: selection) { _, newValue in
            guard let newValue, resolvedDetail(id: newValue) != nil else { return }
            presentDetail(id: newValue)
        }
    }

    @ToolbarContentBuilder
    private var featureToolbar: some ToolbarContent {
        if selectedProvider != nil {
            ToolbarItem(placement: .navigation) {
                Button(action: leaveProvider) {
                    Image(systemName: "chevron.left")
                }
                .help(L10n.text("AI 空间"))
                .accessibilityLabel(L10n.text("AI 空间"))
            }

        }

        ToolbarItemGroup(placement: .primaryAction) {
            if selectedProvider != nil {
                if scope == .chats {
                    Menu {
                        ForEach(AgentStorageTimeRange.allCases) { range in
                            Button {
                                timeRange = range
                            } label: {
                                if timeRange == range {
                                    Label(range.title, systemImage: "checkmark")
                                } else {
                                    Text(range.title)
                                }
                            }
                        }
                    } label: {
                        Label(timeRange.title, systemImage: "clock")
                    }
                    .help(L10n.text("按最近活动时间筛选聊天"))
                    .accessibilityIdentifier("agent-storage-time-range")
                }

                Menu {
                    scopeFilters
                    if hasActiveFilter {
                        Divider()
                        Button(L10n.text("清除筛选"), action: clearFilters)
                    }
                } label: {
                    Image(systemName: hasActiveFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .help(L10n.text("筛选 AI Agent"))
                .accessibilityLabel(L10n.text("筛选 AI Agent"))
                .accessibilityIdentifier("agent-storage-filter")

                Button {
                    showSelectedDetail()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .disabled(selection == nil)
                .help(L10n.text("显示详情"))
                .accessibilityLabel(L10n.text("显示详情"))
                .accessibilityIdentifier("agent-storage-detail")
            }

            Button {
                model.isScanning ? model.stop() : model.refresh()
            } label: {
                Image(systemName: model.isScanning ? "stop.fill" : "arrow.clockwise")
            }
            .help(L10n.text(model.isScanning ? "停止本次扫描" : "刷新 AI 空间"))
            .accessibilityLabel(L10n.text(model.isScanning ? "停止本次扫描" : "刷新 AI 空间"))
            .accessibilityIdentifier("agent-storage-refresh")
        }
    }

    private var hasActiveFilter: Bool {
        switch scope {
        case .chats: return timeRange != .all || archiveFilter != .all || selectedProject != nil
        case .global: return selectedGlobalCategory != nil
        case .unattributed: return selectedUnattributedReason != nil
        }
    }

    private func clearFilters() {
        timeRange = .all
        archiveFilter = .all
        selectedProject = nil
        selectedGlobalCategory = nil
        selectedUnattributedReason = nil
    }

    private var exitAction: (() -> Void)? {
        selectedProvider == nil ? nil : { dismissDetailOrLeaveProvider() }
    }

    @ViewBuilder
    private var scopeFilters: some View {
        switch scope {
        case .chats:
            Picker(L10n.text("聊天状态"), selection: $archiveFilter) {
                ForEach(AgentStorageArchiveFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            if !hidesPrivateDetails, !availableProjects.isEmpty {
                Menu(L10n.text("项目")) {
                    Button(L10n.text("全部项目")) { selectedProject = nil }
                    Divider()
                    ForEach(availableProjects, id: \.self) { project in
                        Button {
                            selectedProject = project
                        } label: {
                            if selectedProject == project {
                                Label(privateProjectName(project), systemImage: "checkmark")
                            } else {
                                Text(privateProjectName(project))
                            }
                        }
                    }
                }
            }
        case .global:
            Menu(L10n.text("类别")) {
                Button(L10n.text("全部类别")) { selectedGlobalCategory = nil }
                Divider()
                ForEach(AgentStorageGlobalCategory.allCases, id: \.self) { category in
                    Button(category.localizedTitle) { selectedGlobalCategory = category }
                }
            }
        case .unattributed:
            Menu(L10n.text("原因")) {
                Button(L10n.text("全部原因")) { selectedUnattributedReason = nil }
                Divider()
                ForEach(AgentStorageUnattributedReason.allCases, id: \.self) { reason in
                    Button(reason.localizedTitle) { selectedUnattributedReason = reason }
                }
            }
        }
    }

    @ViewBuilder
    private var providerOverview: some View {
        if let snapshot = model.snapshot, !snapshot.providers.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, height: 42)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.coverage.isComplete ? L10n.text("总占用") : L10n.text("已统计"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(AgentStorageSizeFormatter.string(snapshot.totalBytes))
                                .font(.system(size: 28, weight: .semibold))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 16)
                        if snapshot.crossAgentSharedBytes > 0 {
                            VStack(alignment: .trailing, spacing: 2) {
                                Label(L10n.text("跨 Agent 共享"), systemImage: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(AgentStorageSizeFormatter.string(snapshot.crossAgentSharedBytes))
                                    .font(.callout.monospacedDigit())
                            }
                        }
                        globalScanStatus(snapshot)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                    Divider()

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 370, maximum: 520), spacing: 16)],
                        alignment: .center,
                        spacing: 16
                    ) {
                        ForEach(providerOverviewItems) { item in
                            AgentStorageProviderOverviewRow(
                                item: item,
                                loadState: model.state,
                                coverage: snapshot.coverage,
                                open: { enterProvider(item.provider) }
                            )
                            .focused($focusedProvider, equals: item.provider)
                            .accessibilityFocused(
                                $accessibilityFocusedProvider,
                                equals: item.provider
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: 1_080)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else if model.snapshot != nil {
            ContentUnavailableView {
                Label(L10n.text("未检测到 Codex 或 Claude 数据"), systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text(L10n.text("分析 Codex 和 Claude 的聊天、子代理与全局运行时"))
            } actions: {
                Button(L10n.text("重新扫描")) { model.refresh() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            emptyOrLoadingContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func mainContent(width: CGFloat) -> some View {
        if width >= 1_140 {
            HSplitView {
                primaryContent
                    .frame(minWidth: 760)
                AgentStorageDetailView(
                    detail: selection.flatMap(resolvedDetail(id:)),
                    hidesPrivateDetails: hidesPrivateDetails
                )
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 400)
            }
        } else {
            primaryContent
                .overlay(alignment: .trailing) {
                    if showsTransientDetail, width >= 760 {
                        AgentStorageTransientDetail(
                            detail: selection.flatMap(resolvedDetail(id:)),
                            hidesPrivateDetails: hidesPrivateDetails,
                            close: closeTransientDetail
                        )
                        .frame(width: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
        }
    }

    private var primaryContent: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            providerStrip
            Divider()
            scopeContextBar
            contentTable
            if scope == .chats,
               model.snapshot != nil,
               selectedProviderSummary?.supportStatus != .unsupportedFormat,
               chatPagination.totalPages > 1 {
                Divider()
                chatPaginationBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var scopeContextBar: some View {
        switch scope {
        case .chats:
            VStack(alignment: .leading, spacing: 5) {
                if selectedProviderSummary?.supportStatus == .unsupportedFormat {
                    Label(
                        L10n.text("聊天索引版本待适配；全局和未归属数据仍可查看。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 10) {
                        Text(timeRange == .all
                            ? L10n.text("全部聊天")
                            : L10n.format("%@有活动", timeRange.title))
                            .font(.caption.weight(.semibold))
                        Text(L10n.format(
                            "当前占用 %@ · %d 个主聊天 · %d 个子代理",
                            AgentStorageSizeFormatter.string(visibleChatSummary.chatBytes),
                            visibleChatSummary.mainThreadCount,
                            visibleChatSummary.subagentCount
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help(L10n.text("按主聊天及其子代理的最近活动时间筛选。空间数字是这些聊天当前仍占用的容量，不代表这段时间新增的文件。"))
                            .accessibilityLabel(L10n.text("时间范围统计说明"))
                    }
                }
                if let summary = selectedProviderSummary, summary.supportStatus == .partial,
                   summary.unsupportedSourceCount > 0 {
                    Label(
                        L10n.format(
                            "部分聊天无法解析；已显示可识别的聊天，另有 %d 个数据位置的格式暂不支持。",
                            summary.unsupportedSourceCount
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if let summary = selectedProviderSummary,
                          summary.unreadableSourceCount > 0 {
                    Label(
                        L10n.text("部分聊天数据无法读取；已显示其余可识别的聊天。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
            Divider()
        case .global:
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(L10n.text("这些数据由多个聊天共享，或属于 Agent 的运行环境，因此不分摊到单个聊天，并且只计算一次。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 42)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
            Divider()
        case .unattributed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let snapshot = model.snapshot {
            let projection = summaryProjection(snapshot)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { summaryMetrics(projection: projection, compact: false) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    summaryMetrics(projection: projection, compact: true)
                }
            }
            .frame(minHeight: containerWidth < 760 ? 116 : 72)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        } else {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Storage").font(.caption)
                        Text("00.00 GiB").font(.title3.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                }
            }
            .frame(height: 72)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func summaryMetrics(
        projection: AgentStorageSummaryProjection,
        compact: Bool
    ) -> some View {
        AgentStorageSummaryMetric(
            title: projection.isComplete ? L10n.text("总占用") : L10n.text("已统计"),
            value: AgentStorageSizeFormatter.string(projection.totalBytes),
            symbol: "externaldrive.fill",
            isSelected: false,
            isLoading: false,
            action: nil
        )
        AgentStorageSummaryMetric(
            title: L10n.text("聊天"),
            value: selectedProviderSummary?.supportStatus == .unsupportedFormat
                ? L10n.text("待适配")
                : AgentStorageSizeFormatter.string(projection.chatBytes),
            symbol: "bubble.left.and.bubble.right.fill",
            isSelected: scope == .chats,
            isLoading: isProjecting && scope == .chats,
            action: { selectScope(.chats) }
        )
        AgentStorageSummaryMetric(
            title: L10n.text("全局"),
            value: AgentStorageSizeFormatter.string(projection.globalBytes),
            symbol: "shippingbox.fill",
            isSelected: scope == .global,
            isLoading: isProjecting && scope == .global,
            action: { selectScope(.global) }
        )
        AgentStorageSummaryMetric(
            title: L10n.text("未归属"),
            value: AgentStorageSizeFormatter.string(projection.unattributedBytes),
            symbol: "questionmark.folder.fill",
            isSelected: scope == .unattributed,
            isLoading: isProjecting && scope == .unattributed,
            action: { selectScope(.unattributed) }
        )
    }

    @ViewBuilder
    private var providerStrip: some View {
        if let snapshot = model.snapshot {
            HStack(spacing: 18) {
                ForEach(visibleProviderSummaries(snapshot)) { provider in
                    AgentStorageProviderLabel(summary: provider)
                }
                Spacer(minLength: 8)
                providerScanStatus(snapshot)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 40)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isScanning ? L10n.text("正在分析 AI Agent 空间") : L10n.text("尚未分析"))
                Spacer()
                if !model.isScanning {
                    Button(L10n.text("开始分析")) { model.refresh() }
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
    }

    private func providerScanStatus(_ snapshot: AgentStorageSnapshot) -> some View {
        Group {
            if model.isScanning {
                AgentStorageRefreshingProgressView(model: model)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: providerStatusSymbol)
                        .foregroundStyle(providerStatusColor)
                    Text(providerStatusText(snapshot))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func globalScanStatus(_ snapshot: AgentStorageSnapshot) -> some View {
        Group {
            if model.isScanning {
                AgentStorageRefreshingProgressView(model: model)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: globalStatusSymbol(snapshot))
                        .foregroundStyle(globalStatusColor(snapshot))
                    Text(globalStatusText(snapshot))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func globalStatusText(_ snapshot: AgentStorageSnapshot) -> String {
        if model.isScanning { return L10n.text("正在刷新，上次结果仍可查看") }
        switch model.state {
        case .failed:
            return L10n.text("刷新失败，显示上次结果")
        case .stale:
            return L10n.text("扫描已停止，显示上次结果")
        default:
            break
        }
        if !snapshot.coverage.isComplete {
            let metadataIssues = snapshot.providers.reduce(0) { $0 + $1.issueCount }
            if metadataIssues > 0,
               snapshot.coverage.skippedEntryCount == 0,
               snapshot.coverage.unstableEntryCount == 0 {
                return L10n.format("部分结果：%d 项元数据无法验证", metadataIssues)
            }
            return L10n.format(
                "部分结果：跳过 %d 项，变化 %d 项",
                snapshot.coverage.skippedEntryCount,
                snapshot.coverage.unstableEntryCount
            )
        }
        return L10n.format(
            "扫描于 %@",
            L10n.date(snapshot.scannedAt, date: .omitted, time: .shortened)
        )
    }

    private func globalStatusSymbol(_ snapshot: AgentStorageSnapshot) -> String {
        if case .failed = model.state { return "xmark.circle.fill" }
        if case .stale = model.state { return "pause.circle.fill" }
        return snapshot.coverage.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private func globalStatusColor(_ snapshot: AgentStorageSnapshot) -> Color {
        if case .failed = model.state { return .red }
        if case .stale = model.state { return .orange }
        return snapshot.coverage.isComplete ? .green : .orange
    }

    private func providerStatusText(_ snapshot: AgentStorageSnapshot) -> String {
        if model.isScanning { return L10n.text("正在刷新，上次结果仍可查看") }
        switch model.state {
        case .failed:
            return L10n.text("刷新失败，显示上次结果")
        case .stale:
            return L10n.text("扫描已停止，显示上次结果")
        default:
            break
        }
        guard let summary = selectedProviderSummary else {
            return L10n.format("扫描于 %@", L10n.date(snapshot.scannedAt, date: .omitted, time: .shortened))
        }
        if summary.supportStatus == .unsupportedFormat {
            return L10n.text("聊天索引版本待适配；全局和未归属数据仍可查看。")
        }
        if summary.supportStatus == .partial {
            if summary.issueCount > 0 {
                return L10n.format("部分结果：%d 项元数据无法验证", summary.issueCount)
            }
            return L10n.format(
                "部分结果：跳过 %d 项，变化 %d 项",
                0,
                summary.unstableEntryCount
            )
        }
        if summary.supportStatus == .noConversationSource {
            return L10n.text("未发现聊天")
        }
        return L10n.format(
            "扫描于 %@",
            L10n.date(snapshot.scannedAt, date: .omitted, time: .shortened)
        )
    }

    private var providerStatusSymbol: String {
        if case .failed = model.state { return "xmark.circle.fill" }
        if case .stale = model.state { return "pause.circle.fill" }
        guard let summary = selectedProviderSummary else { return "checkmark.circle.fill" }
        return summary.supportStatus == .supported ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var providerStatusColor: Color {
        if case .failed = model.state { return .red }
        if case .stale = model.state { return .orange }
        return selectedProviderSummary?.supportStatus == .supported ? .green : .orange
    }

    @ViewBuilder
    private var contentTable: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if model.snapshot == nil {
                    emptyOrLoadingContent
                } else {
                    switch scope {
                    case .chats:
                        if selectedProviderSummary?.supportStatus == .unsupportedFormat {
                            unsupportedChatContent
                        } else {
                            chatTable
                        }
                    case .global: globalTable
                    case .unattributed: unattributedTable
                    }
                }
            }

            if isProjecting, model.snapshot != nil {
                AgentStorageProjectionProgress(scope: scope)
                    .padding(.top, 8)
                    .padding(.trailing, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var unsupportedChatContent: some View {
        ContentUnavailableView {
            Label(L10n.text("暂不支持此版本的聊天数据"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(L10n.format(
                "已统计 %@ 的物理占用，但当前版本的聊天索引格式尚未适配。全局和未归属数据仍可查看。",
                selectedProvider?.displayName ?? "AI Agent"
            ))
        } actions: {
            Button(L10n.text("查看全局数据")) { selectScope(.global) }
        }
    }

    private var chatTable: some View {
        Table(visibleChatRows, selection: $selection, sortOrder: $chatSortOrder) {
            TableColumn(L10n.text("聊天"), value: \.title) { row in
                AgentStorageChatIdentityCell(
                    row: row,
                    isExpanded: expandedFamilies.contains(row.familyID),
                    isExpanding: expandingFamilies.contains(row.familyID),
                    toggleExpanded: { toggleExpanded(row.familyID) },
                    openDetail: { activateDetail(id: row.id) }
                )
            }
            .width(min: 270, ideal: 360)
            TableColumn(L10n.text("最近活动"), value: \.updatedAt) { row in
                Text(relativeDate(row.updatedAt))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(AgentStorageChatCellActivation {
                        activateDetail(id: row.id)
                    })
            }
            .width(min: 86, ideal: 104)
            TableColumn(L10n.text("子代理"), value: \.subagentCount) { row in
                Group {
                    if row.isFamily {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.subagentCount.formatted())
                            Text(AgentStorageSizeFormatter.string(row.subagentAllocatedBytes))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text("-").foregroundStyle(.tertiary)
                    }
                }
                .modifier(AgentStorageChatCellActivation {
                    activateDetail(id: row.id)
                })
            }
            .width(min: 76, ideal: 92)
            TableColumn(L10n.text("占用"), value: \.allocatedBytes) { row in
                Text(AgentStorageSizeFormatter.string(row.allocatedBytes))
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .modifier(AgentStorageChatCellActivation {
                        activateDetail(id: row.id)
                    })
            }
            .width(min: 92, ideal: 112)
        }
        .overlay { tableEmptyStateIfNeeded(itemsAreEmpty: visibleChatRows.isEmpty) }
        .focused($tableHasFocus)
        .accessibilityFocused($tableAccessibilityFocus)
        .accessibilityIdentifier("agent-storage-chat-table")
        .onKeyPress(.return) {
            showSelectedDetail()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let selection,
                  let row = visibleChatRows.first(where: { $0.id == selection }),
                  row.isFamily, row.subagentCount > 0 else { return .ignored }
            if !expandedFamilies.contains(row.familyID) { toggleExpanded(row.familyID) }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let selection,
                  let row = visibleChatRows.first(where: { $0.id == selection }) else { return .ignored }
            if row.isFamily {
                if expandedFamilies.contains(row.familyID) { toggleExpanded(row.familyID) }
            } else {
                self.selection = row.parentID ?? row.familyID
            }
            return .handled
        }
    }

    private var chatPaginationBar: some View {
        HStack(spacing: 10) {
            Text(L10n.format("共 %d 个主聊天", chatPagination.totalItems))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button {
                selectChatPage(chatPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(chatPageIndex <= 0)
            .help(L10n.text("上一页"))
            .accessibilityLabel(L10n.text("上一页"))

            Text(L10n.format(
                "第 %d / %d 页",
                min(chatPageIndex + 1, chatPagination.totalPages),
                chatPagination.totalPages
            ))
            .font(.caption.monospacedDigit().weight(.medium))
            .frame(minWidth: 72)

            Button {
                selectChatPage(chatPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(chatPageIndex + 1 >= chatPagination.totalPages)
            .help(L10n.text("下一页"))
            .accessibilityLabel(L10n.text("下一页"))
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .accessibilityElement(children: .contain)
    }

    private var globalTable: some View {
        Table(visibleGlobalItems, selection: $selection, sortOrder: $globalSortOrder) {
            TableColumn(L10n.text("类别"), value: \.title) { item in
                AgentStorageCategoryCell(
                    symbol: item.category.symbol,
                    title: item.category.localizedTitle,
                    subtitle: item.provider?.displayName ?? L10n.text("跨 Agent 共享")
                )
            }
            .width(min: 220, ideal: 320)
            TableColumn(L10n.text("文件"), value: \.artifactCount) { item in
                Text(item.artifactCount.formatted()).monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn(L10n.text("最近变化")) { item in
                Text(item.updatedAt.map(relativeDate) ?? "-")
                    .foregroundStyle(.secondary)
            }
            .width(min: 86, ideal: 104)
            TableColumn(L10n.text("占用"), value: \.allocatedBytes) { item in
                Text(AgentStorageSizeFormatter.string(item.allocatedBytes))
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 92, ideal: 112)
        }
        .overlay { tableEmptyStateIfNeeded(itemsAreEmpty: visibleGlobalItems.isEmpty) }
        .focused($tableHasFocus)
        .accessibilityFocused($tableAccessibilityFocus)
        .accessibilityIdentifier("agent-storage-global-table")
        .onKeyPress(.return) {
            showSelectedDetail()
            return .handled
        }
    }

    private var unattributedTable: some View {
        Table(visibleUnattributedItems, selection: $selection, sortOrder: $unattributedSortOrder) {
            TableColumn(L10n.text("名称"), value: \.title) { item in
                AgentStorageCategoryCell(
                    symbol: item.reason.symbol,
                    title: item.reason.localizedTitle,
                    subtitle: item.provider.displayName
                )
            }
            .width(min: 220, ideal: 320)
            TableColumn(L10n.text("原因")) { item in
                Text(item.reason.localizedExplanation)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 170, ideal: 240)
            TableColumn(L10n.text("文件"), value: \.artifactCount) { item in
                Text(item.artifactCount.formatted()).monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn(L10n.text("占用"), value: \.allocatedBytes) { item in
                Text(AgentStorageSizeFormatter.string(item.allocatedBytes))
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 92, ideal: 112)
        }
        .overlay { tableEmptyStateIfNeeded(itemsAreEmpty: visibleUnattributedItems.isEmpty) }
        .focused($tableHasFocus)
        .accessibilityFocused($tableAccessibilityFocus)
        .accessibilityIdentifier("agent-storage-unattributed-table")
        .onKeyPress(.return) {
            showSelectedDetail()
            return .handled
        }
    }

    @ViewBuilder
    private func tableEmptyStateIfNeeded(itemsAreEmpty: Bool) -> some View {
        if itemsAreEmpty {
            switch scope {
            case .chats:
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("没有匹配的聊天"), systemImage: "magnifyingglass")
                    } description: {
                        Text(L10n.format("没有与“%@”匹配的结果。", searchText))
                    } actions: {
                        Button(L10n.text("清空搜索")) { searchText = "" }
                    }
                } else if timeRange != .all, archiveFilter == .all, selectedProject == nil {
                    ContentUnavailableView {
                        Label(
                            L10n.format("%@没有活动的聊天", timeRange.title),
                            systemImage: "clock"
                        )
                    } description: {
                        Text(L10n.text("可以选择更长时间范围查看较早聊天。"))
                    } actions: {
                        Button(L10n.text("查看全部时间")) { timeRange = .all }
                    }
                } else if hasActiveFilter {
                    ContentUnavailableView {
                        Label(L10n.text("没有符合筛选条件的聊天"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("调整或清除筛选后再试。"))
                    } actions: {
                        Button(L10n.text("清除筛选"), action: clearFilters)
                    }
                } else {
                    ContentUnavailableView(
                        L10n.text("未发现聊天"),
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(L10n.text("此数据位置中没有可识别的主聊天。"))
                    )
                }
            case .global:
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("没有匹配的全局数据"), systemImage: "magnifyingglass")
                    } description: {
                        Text(L10n.format("没有与“%@”匹配的结果。", searchText))
                    } actions: {
                        Button(L10n.text("清空搜索")) { searchText = "" }
                    }
                } else if hasActiveFilter {
                    ContentUnavailableView {
                        Label(L10n.text("没有符合筛选条件的全局数据"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("调整或清除筛选后再试。"))
                    } actions: {
                        Button(L10n.text("清除筛选"), action: clearFilters)
                    }
                } else {
                    ContentUnavailableView(
                        L10n.text("没有全局数据"),
                        systemImage: "shippingbox",
                        description: Text(L10n.text("未发现可测量的共享数据或 Agent 运行环境文件。"))
                    )
                }
            case .unattributed:
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("没有匹配的未归属数据"), systemImage: "magnifyingglass")
                    } description: {
                        Text(L10n.format("没有与“%@”匹配的结果。", searchText))
                    } actions: {
                        Button(L10n.text("清空搜索")) { searchText = "" }
                    }
                } else if hasActiveFilter {
                    ContentUnavailableView {
                        Label(L10n.text("没有符合筛选条件的未归属数据"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("调整或清除筛选后再试。"))
                    } actions: {
                        Button(L10n.text("清除筛选"), action: clearFilters)
                    }
                } else {
                    ContentUnavailableView(
                        L10n.text("没有未归属数据"),
                        systemImage: "checkmark.circle",
                        description: Text(L10n.text("当前已测量内容均有明确分类。"))
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var emptyOrLoadingContent: some View {
        switch model.state {
        case .scanning:
            AgentStorageOverviewSkeleton(progress: model.progress)
        case .stopped:
            ContentUnavailableView {
                Label(L10n.text("扫描已停止"), systemImage: "pause.circle")
            } description: {
                Text(L10n.text("尚未生成可显示的结果"))
            } actions: {
                Button(L10n.text("重新扫描")) { model.refresh() }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.text("无法完成 AI 空间分析"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(L10n.text("重试")) { model.refresh() }
            }
        default:
            ContentUnavailableView {
                Label(L10n.text("尚未分析 AI Agent 空间"), systemImage: "sparkles")
            } description: {
                Text(L10n.text("分析 Codex 和 Claude 的聊天、子代理与全局运行时"))
            } actions: {
                Button(L10n.text("开始分析")) { model.refresh() }
            }
        }
    }

    private var searchPrompt: Text {
        switch scope {
        case .chats: Text(L10n.text("搜索聊天、项目或 ID"))
        case .global: Text(L10n.text("搜索全局类别"))
        case .unattributed: Text(L10n.text("搜索未归属内容"))
        }
    }

    private func scheduleProjection(debounce: Duration? = nil) {
        projectionTask?.cancel()
        projectionGeneration &+= 1
        let requestedGeneration = projectionGeneration

        guard let snapshot = model.snapshot,
              let provider = selectedProvider,
              let dataset = snapshot.dataset(for: provider) else {
            isProjecting = false
            visibleChatRows = []
            visibleGlobalItems = []
            visibleUnattributedItems = []
            visibleChatSummary = AgentStorageChatRangeProjection(families: [])
            availableProjectsCache = []
            chatPageIndex = 0
            chatPagination = .empty
            clearSelectionAndDetails()
            return
        }

        let request = AgentStorageProjectionRequest(
            scope: scope,
            dataset: dataset,
            scannedAt: snapshot.scannedAt,
            archiveFilter: archiveFilter,
            timeRange: timeRange,
            selectedProject: selectedProject,
            selectedGlobalCategory: selectedGlobalCategory,
            selectedUnattributedReason: selectedUnattributedReason,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            hidesPrivateDetails: hidesPrivateDetails,
            expandedFamilies: expandedFamilies,
            chatPageIndex: chatPageIndex,
            chatPageSize: AgentStorageChatPagination.pageSize,
            chatSortRules: chatSortRules,
            globalSortRules: globalSortRules,
            unattributedSortRules: unattributedSortRules
        )
        isProjecting = true

        projectionTask = Task { @MainActor in
            do {
                if let debounce { try await Task.sleep(for: debounce) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try AgentStorageProjectionEngine.project(request)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled,
                      projectionGeneration == requestedGeneration,
                      selectedProvider == provider,
                      scope == request.scope else { return }
                applyProjection(result)
                isProjecting = false
                expandingFamilies = []
                projectionTask = nil
            } catch is CancellationError {
                // A newer interaction owns the visible loading state.
            } catch {
                guard projectionGeneration == requestedGeneration else { return }
                isProjecting = false
                expandingFamilies = []
                projectionTask = nil
            }
        }
    }

    private func applyProjection(_ result: AgentStorageProjectionResult) {
        switch result.content {
        case .chats(let rows, let summary, let availableProjects, let pagination):
            visibleChatRows = rows
            visibleChatSummary = summary
            availableProjectsCache = availableProjects
            chatPageIndex = pagination.pageIndex
            chatPagination = pagination
        case .global(let items):
            visibleGlobalItems = items
        case .unattributed(let items):
            visibleUnattributedItems = items
        }
        guard let selection, !result.visibleIDs.contains(selection) else { return }
        clearSelectionAndDetails()
    }

    private var availableProjects: [String] { availableProjectsCache }

    private var chatSortRules: [AgentStorageChatSortRule] {
        chatSortOrder.compactMap { comparator in
            let field: AgentStorageChatSortField?
            switch comparator.keyPath {
            case \AgentStorageChatRow.title: field = .title
            case \AgentStorageChatRow.updatedAt: field = .updatedAt
            case \AgentStorageChatRow.subagentCount: field = .subagentCount
            case \AgentStorageChatRow.allocatedBytes: field = .allocatedBytes
            case \AgentStorageChatRow.id: field = .id
            default: field = nil
            }
            return field.map { AgentStorageChatSortRule(field: $0, isReverse: comparator.order == .reverse) }
        }
    }

    private var globalSortRules: [AgentStorageGlobalSortRule] {
        globalSortOrder.compactMap { comparator in
            let field: AgentStorageGlobalSortField?
            switch comparator.keyPath {
            case \AgentStorageGlobalItem.title: field = .title
            case \AgentStorageGlobalItem.artifactCount: field = .artifactCount
            case \AgentStorageGlobalItem.allocatedBytes: field = .allocatedBytes
            case \AgentStorageGlobalItem.id: field = .id
            default: field = nil
            }
            return field.map { AgentStorageGlobalSortRule(field: $0, isReverse: comparator.order == .reverse) }
        }
    }

    private var unattributedSortRules: [AgentStorageUnattributedSortRule] {
        unattributedSortOrder.compactMap { comparator in
            let field: AgentStorageUnattributedSortField?
            switch comparator.keyPath {
            case \AgentStorageUnattributedItem.title: field = .title
            case \AgentStorageUnattributedItem.artifactCount: field = .artifactCount
            case \AgentStorageUnattributedItem.allocatedBytes: field = .allocatedBytes
            case \AgentStorageUnattributedItem.id: field = .id
            default: field = nil
            }
            return field.map {
                AgentStorageUnattributedSortRule(field: $0, isReverse: comparator.order == .reverse)
            }
        }
    }

    private func selectScope(_ newScope: AgentStorageScope) {
        guard scope != newScope else { return }
        isProjecting = true
        scope = newScope
    }

    private func selectChatPage(_ pageIndex: Int) {
        let clampedPage = min(max(0, pageIndex), max(0, chatPagination.totalPages - 1))
        guard chatPageIndex != clampedPage else { return }
        chatPageIndex = clampedPage
        clearSelectionAndDetails()
        isProjecting = true
        scheduleProjection()
    }

    private func resetChatPage() {
        chatPageIndex = 0
    }

    private var selectedProviderSummary: AgentStorageProviderSummary? {
        guard let provider = selectedProvider else { return nil }
        return model.snapshot?.providers.first { $0.provider == provider }
    }

    private func privateProjectName(_ project: String) -> String {
        hidesPrivateDetails ? L10n.text("已隐藏项目") : project
    }

    private func visibleProviderSummaries(_ snapshot: AgentStorageSnapshot) -> [AgentStorageProviderSummary] {
        guard let selectedProvider else { return [] }
        return snapshot.providers.filter { $0.provider == selectedProvider }
    }

    private func summaryProjection(_ snapshot: AgentStorageSnapshot) -> AgentStorageSummaryProjection {
        guard let provider = selectedProvider,
              let summary = snapshot.providers.first(where: { $0.provider == provider })
        else {
            return AgentStorageSummaryProjection(
                chatBytes: 0,
                globalBytes: 0,
                unattributedBytes: 0,
                isComplete: false
            )
        }
        return AgentStorageSummaryProjection(
            chatBytes: summary.chatBytes,
            globalBytes: summary.globalBytes,
            unattributedBytes: summary.unattributedBytes,
            isComplete: summary.supportStatus == .supported
        )
    }

    private func toggleExpanded(_ familyID: String) {
        if expandedFamilies.contains(familyID) {
            expandedFamilies.remove(familyID)
            expandingFamilies.remove(familyID)
        } else {
            expandedFamilies.insert(familyID)
            expandingFamilies.insert(familyID)
        }
        scheduleProjection()
    }

    private func rebuildSnapshotIndex(_ snapshot: AgentStorageSnapshot?) {
        guard let snapshot else {
            providerOverviewItems = []
            familyIndex = [:]
            detailIndex = [:]
            availableProjectsCache = []
            chatPageIndex = 0
            chatPagination = .empty
            expandingFamilies = []
            return
        }
        let totalAgentBytes = snapshot.totalBytes
        providerOverviewItems = snapshot.providers.map {
            AgentStorageProviderOverviewItem(summary: $0, totalAgentBytes: totalAgentBytes)
        }
        guard let selectedProvider else {
            familyIndex = [:]
            detailIndex = [:]
            return
        }
        guard snapshot.providers.contains(where: { $0.provider == selectedProvider }),
              let dataset = snapshot.dataset(for: selectedProvider) else {
            leaveProvider()
            return
        }
        rebuildProviderIndexes(dataset)
        expandingFamilies.formIntersection(Set(familyIndex.keys))
        reconcileWorkspaceState(with: dataset)
    }

    private func rebuildProviderIndexes(_ dataset: AgentStorageProviderDataset) {
        familyIndex = Dictionary(uniqueKeysWithValues: dataset.families.map { ($0.id, $0) })
        var details: [String: AgentStorageResolvedDetail] = [:]
        details.reserveCapacity(
            dataset.families.count
                + dataset.families.reduce(0) { $0 + $1.subagents.count }
                + dataset.globalItems.count
                + dataset.unattributedItems.count
        )
        for family in dataset.families {
            details[family.id] = .family(family)
            for subagent in family.subagents {
                details[subagent.id] = .subagent(subagent, family)
            }
        }
        for item in dataset.globalItems { details[item.id] = .global(item) }
        for item in dataset.unattributedItems { details[item.id] = .unattributed(item) }
        detailIndex = details
    }

    private func enterProvider(_ provider: AgentStorageProvider) {
        isRestoringWorkspace = true
        if let saved = workspaceStates[provider] {
            scope = saved.scope
            archiveFilter = saved.archiveFilter
            timeRange = saved.timeRange
            selectedProject = saved.selectedProject
            selectedGlobalCategory = saved.selectedGlobalCategory
            selectedUnattributedReason = saved.selectedUnattributedReason
            searchText = saved.searchText
            selection = saved.selection
            expandedFamilies = saved.expandedFamilies
            chatPageIndex = saved.chatPageIndex
            chatSortOrder = saved.chatSortOrder
            globalSortOrder = saved.globalSortOrder
            unattributedSortOrder = saved.unattributedSortOrder
        } else {
            scope = .chats
            archiveFilter = .all
            timeRange = .all
            selectedProject = nil
            selectedGlobalCategory = nil
            selectedUnattributedReason = nil
            searchText = ""
            selection = nil
            expandedFamilies = []
            chatPageIndex = 0
            chatSortOrder = [
                KeyPathComparator(\AgentStorageChatRow.updatedAt, order: .reverse),
                KeyPathComparator(\AgentStorageChatRow.id, order: .forward)
            ]
            globalSortOrder = [KeyPathComparator(\AgentStorageGlobalItem.allocatedBytes, order: .reverse)]
            unattributedSortOrder = [
                KeyPathComparator(\AgentStorageUnattributedItem.allocatedBytes, order: .reverse)
            ]
        }
        showsTransientDetail = false
        compactDetail = nil
        focusedProvider = nil
        accessibilityFocusedProvider = nil
        selectedProvider = provider
        if let dataset = model.snapshot?.dataset(for: provider) {
            rebuildProviderIndexes(dataset)
            reconcileWorkspaceState(with: dataset)
        }
        scheduleProjection()
        Task { @MainActor in
            await Task.yield()
            isRestoringWorkspace = false
            tableHasFocus = true
            tableAccessibilityFocus = true
        }
    }

    private func leaveProvider() {
        projectionTask?.cancel()
        projectionGeneration &+= 1
        isProjecting = false
        let departingProvider = selectedProvider
        if let departingProvider {
            workspaceStates[departingProvider] = AgentStorageProviderWorkspaceState(
                scope: scope,
                archiveFilter: archiveFilter,
                timeRange: timeRange,
                selectedProject: selectedProject,
                selectedGlobalCategory: selectedGlobalCategory,
                selectedUnattributedReason: selectedUnattributedReason,
                searchText: searchText,
                selection: selection,
                expandedFamilies: expandedFamilies,
                chatPageIndex: chatPageIndex,
                chatSortOrder: chatSortOrder,
                globalSortOrder: globalSortOrder,
                unattributedSortOrder: unattributedSortOrder
            )
        }
        selectedProvider = nil
        selection = nil
        showsTransientDetail = false
        compactDetail = nil
        visibleChatRows = []
        visibleGlobalItems = []
        visibleUnattributedItems = []
        familyIndex = [:]
        detailIndex = [:]
        availableProjectsCache = []
        chatPageIndex = 0
        chatPagination = .empty
        expandingFamilies = []
        tableAccessibilityFocus = false
        Task { @MainActor in
            await Task.yield()
            focusedProvider = departingProvider
            accessibilityFocusedProvider = departingProvider
        }
    }

    private func reconcileWorkspaceState(with dataset: AgentStorageProviderDataset) {
        let validFamilies = Set(dataset.families.map(\.id))
        expandedFamilies.formIntersection(validFamilies)
        guard let selection else { return }
        guard detailIndex[selection] == nil else { return }
        self.selection = nil
        showsTransientDetail = false
        compactDetail = nil
    }

    private func reconcileSelectionWithVisibleRows() {
        guard let selection else { return }
        let visibleIDs: Set<String>
        switch scope {
        case .chats:
            visibleIDs = Set(visibleChatRows.map(\.id))
        case .global:
            visibleIDs = Set(visibleGlobalItems.map(\.id))
        case .unattributed:
            visibleIDs = Set(visibleUnattributedItems.map(\.id))
        }
        guard !visibleIDs.contains(selection) else { return }
        clearSelectionAndDetails()
    }

    private func clearSelectionAndDetails() {
        selection = nil
        showsTransientDetail = false
        compactDetail = nil
    }

    private func showSelectedDetail() {
        guard let selection else { return }
        presentDetail(id: selection)
    }

    private func activateDetail(id: String) {
        guard resolvedDetail(id: id) != nil else { return }
        selection = id
        presentDetail(id: id)
    }

    private func presentDetail(id: String) {
        if containerWidth < 760 {
            guard compactDetail?.id != id else { return }
            compactDetail = AgentStorageDetailSelection(id: id)
        } else if containerWidth < 1_140 {
            guard !showsTransientDetail else { return }
            withAnimation(.easeOut(duration: 0.16)) { showsTransientDetail = true }
        }
    }

    private func closeTransientDetail() {
        showsTransientDetail = false
        tableHasFocus = true
    }

    private func dismissDetailOrLeaveProvider() {
        if compactDetail != nil {
            compactDetail = nil
            tableHasFocus = true
        } else if showsTransientDetail {
            closeTransientDetail()
        } else {
            leaveProvider()
        }
    }

    private func resolvedDetail(id: String) -> AgentStorageResolvedDetail? {
        detailIndex[id]
    }

    private func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

private struct AgentStorageProviderOverviewItem: Identifiable {
    let summary: AgentStorageProviderSummary
    let totalAgentBytes: UInt64

    var id: AgentStorageProvider { summary.provider }
    var provider: AgentStorageProvider { summary.provider }
    var exclusiveBytes: UInt64 { summary.exclusiveBytes }
    var chatBytes: UInt64 { summary.chatBytes }
    var globalBytes: UInt64 { summary.globalBytes }
    var unattributedBytes: UInt64 { summary.unattributedBytes }
    var shareOfTotal: Double {
        guard totalAgentBytes > 0 else { return 0 }
        return Double(exclusiveBytes) / Double(totalAgentBytes)
    }
}

private struct AgentStorageProviderOverviewRow: View {
    let item: AgentStorageProviderOverviewItem
    let loadState: AgentStorageLoadState
    let coverage: AgentStorageCoverage
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 13) {
                    AgentStorageProviderIcon(provider: item.provider, size: 34)
                        .frame(width: 52, height: 52)
                        .background(brandColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.provider.displayName)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 5) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .help(statusHelp)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isHovering ? brandColor : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("独占占用"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(AgentStorageSizeFormatter.string(item.exclusiveBytes))
                            .font(.system(size: 30, weight: .semibold))
                            .monospacedDigit()
                        Text(item.shareOfTotal, format: .percent.precision(.fractionLength(1)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 10) {
                    AgentStorageCompositionBar(item: item, chatColor: brandColor)
                    metrics
                }

                Divider()
                HStack(spacing: 16) {
                    if item.summary.supportStatus == .unsupportedFormat {
                        Label(L10n.text("聊天索引待适配"), systemImage: "exclamationmark.triangle")
                    } else {
                        Label(
                            "\(item.summary.threadCount.formatted()) \(L10n.text("个主聊天"))",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        Label(
                            L10n.format("%d 个子代理", item.summary.subagentCount),
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 264, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(
                isHovering
                    ? Color(nsColor: .controlBackgroundColor).opacity(0.9)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.56),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isHovering ? brandColor.opacity(0.48) : Color(nsColor: .separatorColor).opacity(0.72),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0.035), radius: isHovering ? 10 : 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
    }

    private var brandColor: Color {
        item.provider == .codex ? Color(red: 0.08, green: 0.55, blue: 0.43) : Color(red: 0.82, green: 0.39, blue: 0.18)
    }

    private var statusText: String {
        switch loadState {
        case .scanning:
            return L10n.text("正在刷新，上次结果仍可查看")
        case .failed:
            return L10n.text("刷新失败，显示上次结果")
        case .stale:
            return L10n.text("扫描已停止，显示上次结果")
        default:
            break
        }
        switch item.summary.supportStatus {
        case .unsupportedFormat:
            return L10n.text("版本待适配")
        case .noConversationSource:
            return L10n.text("未发现聊天数据")
        case .partial where item.summary.unsupportedSourceCount > 0:
            return L10n.text("部分聊天无法解析")
        case .partial where item.summary.unreadableSourceCount > 0:
            return L10n.text("部分聊天数据无法读取")
        default:
            break
        }
        if item.summary.issueCount > 0 {
            return L10n.format("部分结果：%d 项元数据无法验证", item.summary.issueCount)
        }
        if item.summary.unstableEntryCount > 0 {
            return L10n.format(
                "部分结果：%d 项在扫描期间发生变化",
                item.summary.unstableEntryCount
            )
        }
        return hasProviderWideFailure ? L10n.text("部分结果") : L10n.text("已完成")
    }

    private var statusColor: Color {
        switch loadState {
        case .failed: return .red
        case .scanning: return .accentColor
        case .stale: return .orange
        default:
            return item.summary.supportStatus == .supported
                && item.summary.issueCount == 0
                && item.summary.unstableEntryCount == 0
                && !hasProviderWideFailure ? .green : .orange
        }
    }

    private var statusHelp: String {
        switch item.summary.supportStatus {
        case .unsupportedFormat:
            return L10n.text("已统计此 Agent 的物理占用，但无法解析当前版本的聊天索引。全局和未归属数据仍可查看。")
        case .partial where item.summary.unsupportedSourceCount > 0:
            return L10n.text("已显示可识别的聊天；部分数据位置的格式暂不支持。")
        case .partial where item.summary.unreadableSourceCount > 0:
            return L10n.text("已显示可识别的聊天；部分数据位置当前无法读取。")
        case .noConversationSource:
            return L10n.text("未发现可解析的聊天数据位置。")
        default:
            return statusText
        }
    }

    private var hasProviderWideFailure: Bool {
        coverage.overflowed || coverage.reconciliationDelta != 0
    }

    private var accessibilitySummary: String {
        [
            item.provider.displayName,
            statusText,
            "\(L10n.text("独占占用")) \(AgentStorageSizeFormatter.string(item.exclusiveBytes))",
            "\(L10n.text("聊天")) \(AgentStorageSizeFormatter.string(item.chatBytes))",
            "\(L10n.text("全局")) \(AgentStorageSizeFormatter.string(item.globalBytes))",
            "\(L10n.text("未归属")) \(AgentStorageSizeFormatter.string(item.unattributedBytes))",
            "\(item.summary.threadCount) \(L10n.text("个主聊天"))",
            L10n.format("%d 个子代理", item.summary.subagentCount)
        ].joined(separator: ", ")
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metric(
                L10n.text("聊天"),
                bytes: item.summary.supportStatus == .unsupportedFormat ? nil : item.chatBytes
            )
            metric(L10n.text("全局"), bytes: item.globalBytes)
            metric(L10n.text("未归属"), bytes: item.unattributedBytes)
        }
    }

    private func metric(_ title: String, bytes: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(bytes.map(AgentStorageSizeFormatter.string) ?? L10n.text("待适配"))
                .font(.callout.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentStorageCompositionBar: View {
    let item: AgentStorageProviderOverviewItem
    let chatColor: Color

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, Double(item.exclusiveBytes))
            HStack(spacing: 2) {
                segment(chatColor, bytes: item.chatBytes, total: total, width: geometry.size.width)
                segment(.secondary.opacity(0.55), bytes: item.globalBytes, total: total, width: geometry.size.width)
                segment(
                    Color(red: 0.76, green: 0.30, blue: 0.38).opacity(0.82),
                    bytes: item.unattributedBytes,
                    total: total,
                    width: geometry.size.width
                )
            }
        }
        .frame(height: 7)
        .clipShape(RoundedRectangle(cornerRadius: 3.5))
        .accessibilityHidden(true)
    }

    private func segment(_ color: Color, bytes: UInt64, total: Double, width: CGFloat) -> some View {
        color.frame(width: max(bytes == 0 ? 0 : 2, width * CGFloat(Double(bytes) / total)))
    }
}

private struct AgentStorageConditionalSearch: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String
    let prompt: Text

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $searchText, prompt: prompt)
        } else {
            content
        }
    }
}

private struct AgentStorageFocusedActions: ViewModifier {
    let refresh: () -> Void
    let back: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.agentStorageRefreshAction, refresh)
            .focusedSceneValue(\.agentStorageBackAction, back)
            .onExitCommand {
                back?()
            }
    }
}

struct AgentStorageChatRow: Identifiable, Hashable, Sendable {
    let id: String
    let nativeID: String
    let parentID: String?
    let familyID: String
    let provider: AgentStorageProvider
    let title: String
    let project: String
    let updatedAt: Date
    let subagentCount: Int
    let subagentAllocatedBytes: UInt64
    let allocatedBytes: UInt64
    let isFamily: Bool
    let depth: Int

    init(family: AgentStorageThreadFamily, hidesPrivateDetails: Bool) {
        id = family.id
        nativeID = family.nativeThreadID
        parentID = nil
        familyID = family.id
        provider = family.provider
        title = hidesPrivateDetails
            ? "\(family.provider.displayName) \(L10n.text("聊天")) · \(family.updatedAt.formatted(date: .abbreviated, time: .omitted))"
            : family.title
        project = hidesPrivateDetails ? L10n.text("已隐藏项目") : family.project
        updatedAt = family.updatedAt
        subagentCount = family.subagentCount
        subagentAllocatedBytes = family.subagentAllocatedBytes
        allocatedBytes = family.allocatedBytes
        isFamily = true
        depth = 0
    }

    init(
        node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily,
        parentRowID: String,
        hidesPrivateDetails: Bool
    ) {
        id = node.id
        nativeID = node.nativeID
        parentID = parentRowID
        familyID = family.id
        provider = family.provider
        title = hidesPrivateDetails ? L10n.text("子代理") : node.title
        project = hidesPrivateDetails ? L10n.text("已隐藏项目") : family.title
        updatedAt = node.updatedAt
        subagentCount = 0
        subagentAllocatedBytes = 0
        allocatedBytes = node.allocatedBytes
        isFamily = false
        depth = max(1, node.depth)
    }
}

private struct AgentStorageChatIdentityCell: View {
    let row: AgentStorageChatRow
    let isExpanded: Bool
    let isExpanding: Bool
    let toggleExpanded: () -> Void
    let openDetail: () -> Void

    @ViewBuilder
    var body: some View {
        if row.isFamily, row.subagentCount > 0 {
            cell.accessibilityAction(
                named: L10n.text(isExpanded ? "折叠子代理" : "展开子代理"),
                toggleExpanded
            )
        } else {
            cell
        }
    }

    private var cell: some View {
        HStack(spacing: 8) {
            if row.isFamily, row.subagentCount > 0 {
                Button(action: toggleExpanded) {
                    Group {
                        if isExpanding {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(isExpanded ? "折叠子代理" : "展开子代理"))
            } else {
                Color.clear.frame(width: 18, height: 24)
            }

            HStack(spacing: 8) {
                AgentStorageProviderIcon(provider: row.provider, size: row.isFamily ? 28 : 22)
                    .padding(.leading, CGFloat(max(0, row.depth - 1)) * 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(row.isFamily ? .callout.weight(.medium) : .callout)
                        .lineLimit(1)
                    Text(row.isFamily
                        ? "\(row.provider.displayName) · \(row.project)"
                        : "\(L10n.text("属于")) \(row.project)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(openDetail))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: L10n.text("显示详情"), openDetail)
    }

    private var accessibilityLabel: String {
        if row.isFamily {
            return "\(L10n.text("主聊天"))，\(row.title)，\(row.subagentCount) \(L10n.text("个子代理"))，\(AgentStorageSizeFormatter.string(row.allocatedBytes))"
        }
        return "\(L10n.text("子代理"))，\(row.title)，\(AgentStorageSizeFormatter.string(row.allocatedBytes))"
    }
}

private struct AgentStorageChatCellActivation: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
    }
}

private struct AgentStorageSummaryMetric: View {
    let title: String
    let value: String
    let symbol: String
    let isSelected: Bool
    let isLoading: Bool
    let action: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .onHover { isHovering = $0 }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(metricBackground)
        .overlay(alignment: .bottom) {
            if action != nil, isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) { Divider() }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(metricForeground)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Text(value)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var metricBackground: Color {
        guard action != nil else {
            return Color(nsColor: .underPageBackgroundColor).opacity(0.42)
        }
        if isSelected { return Color.accentColor.opacity(0.09) }
        if isHovering { return Color.accentColor.opacity(0.045) }
        return .clear
    }

    private var metricForeground: Color {
        guard action != nil else { return .secondary }
        return isSelected || isHovering ? .accentColor : .secondary
    }
}

private struct AgentStorageProjectionProgress: View {
    let scope: AgentStorageScope

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(L10n.format("正在准备%@…", scope.title))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("正在准备%@…", scope.title))
    }
}

private struct AgentStorageProviderLabel: View {
    let summary: AgentStorageProviderSummary

    var body: some View {
        HStack(spacing: 7) {
            AgentStorageProviderIcon(provider: summary.provider, size: 20)
            Text(summary.provider.displayName).fontWeight(.medium)
            Text(AgentStorageSizeFormatter.string(summary.exclusiveBytes))
                .monospacedDigit()
            Text("· \(summary.threadCount.formatted()) \(L10n.text("个主聊天"))")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct AgentStorageProviderIcon: View {
    let provider: AgentStorageProvider
    let size: CGFloat
    private static let codexImage = loadImage(named: "codex-openai")
    private static let claudeImage = loadImage(named: "claude-code")

    var body: some View {
        Group {
            if let image = providerImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(provider == .codex ? .original : .template)
                    .foregroundStyle(Color(red: 0.82, green: 0.39, blue: 0.18))
            } else {
                Image(systemName: provider == .codex ? "terminal" : "sparkles")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var providerImage: NSImage? {
        provider == .codex ? Self.codexImage : Self.claudeImage
    }

    private static func loadImage(named name: String) -> NSImage? {
        guard let url = AppResourceBundle.value.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private struct AgentStorageCategoryCell: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct AgentStorageOverviewSkeleton: View {
    let progress: AgentStorageScanProgress

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary)
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 7) {
                        skeletonLine(width: 62, height: 9)
                        skeletonLine(width: 154, height: 22)
                    }
                    Spacer(minLength: 24)
                    AgentStorageLiveProgressView(progress: progress)
                        .frame(maxWidth: 470)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        providerCard
                        providerCard
                    }
                    VStack(spacing: 16) {
                        providerCard
                        providerCard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: 1_080)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 7) {
                    skeletonLine(width: 92, height: 14)
                    skeletonLine(width: 168, height: 8)
                }
                Spacer()
                Circle()
                    .fill(.quaternary)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 8) {
                skeletonLine(width: 66, height: 8)
                skeletonLine(width: 172, height: 25)
            }

            VStack(alignment: .leading, spacing: 11) {
                skeletonLine(height: 8)
                HStack {
                    skeletonLine(width: 96, height: 22)
                    Spacer()
                    skeletonLine(width: 82, height: 22)
                    Spacer()
                    skeletonLine(width: 74, height: 22)
                }
            }

            Divider()
            HStack(spacing: 16) {
                skeletonLine(width: 112, height: 9)
                skeletonLine(width: 112, height: 9)
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: 520, minHeight: 264, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.56),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func skeletonLine(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(4, height / 2))
            .fill(.quaternary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

private struct AgentStorageLiveProgressView: View {
    let progress: AgentStorageScanProgress
    var compact = false

    @ViewBuilder
    var body: some View {
        if compact {
            HStack(spacing: 6) {
                Image(systemName: phaseSymbol)
                    .foregroundStyle(Color.accentColor)
                Text(phaseTitle)
                    .fontWeight(.semibold)
                Text("· \(progressDetail)")
                    .foregroundStyle(.secondary)
                if let total = progress.totalCount, total > 0 {
                    ProgressView(
                        value: Double(min(progress.completedCount, total)),
                        total: Double(total)
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                }
                Text("· \(L10n.text("上次结果仍可查看"))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        } else {
            fullContent
        }
    }

    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseTitle)
                        .font(.callout.weight(.semibold))
                    Text(progressDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let total = progress.totalCount, total > 0 {
                ProgressView(
                    value: Double(min(progress.completedCount, total)),
                    total: Double(total)
                )
                .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 4) {
                ForEach(AgentStorageScanPhase.allCases, id: \.rawValue) { phase in
                    Capsule()
                        .fill(phase.rawValue <= progress.phase.rawValue
                            ? Color.accentColor.opacity(phase == progress.phase ? 1 : 0.42)
                            : Color.secondary.opacity(0.16))
                        .frame(height: 3)
                }
            }

            Text(L10n.text("正在读取聊天、子代理与共享运行时；数据较多时可能需要一些时间。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var fraction: Double? {
        guard let total = progress.totalCount, total > 0 else { return nil }
        return min(1, Double(progress.completedCount) / Double(total))
    }

    private var phaseTitle: String {
        switch progress.phase {
        case .discoveringSources:
            L10n.text("正在查找 Agent 数据")
        case .readingMetadata:
            L10n.text("正在读取聊天关系")
        case .measuringEntries:
            if let provider = progress.provider {
                L10n.format("正在测量 %@ 数据", provider.displayName)
            } else {
                L10n.text("正在测量 Agent 数据")
            }
        case .validatingEntries:
            L10n.text("正在核对文件变化")
        case .organizingResults:
            L10n.text("正在整理空间归属")
        }
    }

    private var progressDetail: String {
        switch progress.phase {
        case .discoveringSources:
            L10n.format("已发现 %d 个数据位置", progress.completedCount)
        case .measuringEntries:
            L10n.format("已检查 %d 个文件与目录", progress.completedCount)
        case .readingMetadata, .validatingEntries, .organizingResults:
            if let total = progress.totalCount {
                L10n.format("已处理 %d / %d 项", min(progress.completedCount, total), total)
            } else {
                L10n.format("已处理 %d 项", progress.completedCount)
            }
        }
    }

    private var phaseSymbol: String {
        switch progress.phase {
        case .discoveringSources: "externaldrive.badge.magnifyingglass"
        case .readingMetadata: "point.3.connected.trianglepath.dotted"
        case .measuringEntries: "doc.text.magnifyingglass"
        case .validatingEntries: "checkmark.shield"
        case .organizingResults: "chart.bar.doc.horizontal"
        }
    }
}

private struct AgentStorageRefreshingProgressView: View {
    let model: AgentStorageModel

    var body: some View {
        AgentStorageLiveProgressView(progress: model.progress, compact: true)
    }
}

private enum AgentStorageResolvedDetail {
    case family(AgentStorageThreadFamily)
    case subagent(AgentStorageThreadNode, AgentStorageThreadFamily)
    case global(AgentStorageGlobalItem)
    case unattributed(AgentStorageUnattributedItem)
}

private struct AgentStorageTransientDetail: View {
    let detail: AgentStorageResolvedDetail?
    let hidesPrivateDetails: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("详情")).font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(L10n.text("关闭详情"))
                    .accessibilityLabel(L10n.text("关闭详情"))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()
            AgentStorageDetailView(detail: detail, hidesPrivateDetails: hidesPrivateDetails)
        }
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: .black.opacity(0.16), radius: 14, x: -4, y: 0)
        .onExitCommand(perform: close)
    }
}

private struct AgentStorageDetailView: View {
    let detail: AgentStorageResolvedDetail?
    let hidesPrivateDetails: Bool

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch detail {
                        case .family(let family): familyDetail(family)
                        case .subagent(let node, let family): subagentDetail(node, family: family)
                        case .global(let item): globalDetail(item)
                        case .unattributed(let item): unattributedDetail(item)
                        }
                    }
                    .padding(18)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("选择一项查看详情"),
                    systemImage: "sidebar.right"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    @ViewBuilder
    private func familyDetail(_ family: AgentStorageThreadFamily) -> some View {
        detailHeader(
            provider: family.provider,
            title: privateTitle(family.title, provider: family.provider, fallback: L10n.text("聊天")),
            subtitle: hidesPrivateDetails ? L10n.text("项目已隐藏") : family.project,
            path: hidesPrivateDetails ? nil : family.path
        )
        detailSection(L10n.text("占用摘要")) {
            detailValue(L10n.text("聊天占用"), family.allocatedBytes, emphasized: true)
            detailValue(L10n.text("主聊天自身"), family.mainAllocatedBytes)
            detailValue(
                L10n.format("%d 个子代理", family.subagentCount),
                family.subagentAllocatedBytes
            )
            if family.familyOtherAllocatedBytes > 0 {
                detailValue(L10n.text("聊天内共享与其他"), family.familyOtherAllocatedBytes)
            }
        }
        if !family.composition.isEmpty {
            detailSection(L10n.text("物理占用组成")) {
                ForEach(family.composition.sorted { $0.value > $1.value }, id: \.key) { item in
                    detailValue(item.key.localizedTitle, item.value)
                }
            }
        }
        if !family.subagents.isEmpty {
            detailSection(L10n.text("最大子代理")) {
                ForEach(family.largestSubagents(limit: 5)) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(privateTitle(node.title, provider: family.provider, fallback: L10n.text("子代理")))
                                .lineLimit(1)
                            Text(shortIdentifier(node.nativeID))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(AgentStorageSizeFormatter.string(node.allocatedBytes))
                            .monospacedDigit()
                    }
                }
            }
        }
        evidenceSection(
            id: family.nativeThreadID,
            path: hidesPrivateDetails ? nil : family.path,
            evidence: L10n.text("主聊天及全部递归子代理的独占文件")
        )
    }

    @ViewBuilder
    private func subagentDetail(
        _ node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily
    ) -> some View {
        detailHeader(
            provider: family.provider,
            title: privateTitle(node.title, provider: family.provider, fallback: L10n.text("子代理")),
            subtitle: hidesPrivateDetails
                ? L10n.text("主聊天 > 子代理")
                : "\(family.title) > \(node.title)",
            path: hidesPrivateDetails ? nil : node.path
        )
        detailSection(L10n.text("占用摘要")) {
            detailValue(L10n.text("子代理独占"), node.allocatedBytes, emphasized: true)
            LabeledContent(L10n.text("文件"), value: node.artifactCount.formatted())
            LabeledContent(L10n.text("层级"), value: node.depth.formatted())
        }
        evidenceSection(
            id: node.nativeID,
            path: hidesPrivateDetails ? nil : node.path,
            evidence: L10n.text("由主聊天关系或 session 目录直接归属")
        )
    }

    @ViewBuilder
    private func globalDetail(_ item: AgentStorageGlobalItem) -> some View {
        detailHeader(
            provider: item.provider,
            title: item.category.localizedTitle,
            subtitle: item.provider?.displayName ?? L10n.text("跨 Agent 共享"),
            path: hidesPrivateDetails ? nil : item.path
        )
        detailSection(L10n.text("占用摘要")) {
            detailValue(L10n.text("物理占用"), item.allocatedBytes, emphasized: true)
            detailValue(L10n.text("逻辑大小"), item.logicalBytes)
            LabeledContent(L10n.text("文件"), value: item.artifactCount.formatted())
        }
        evidenceSection(
            id: item.id,
            path: hidesPrivateDetails ? nil : item.path,
            evidence: globalEvidence(item.category)
        )
    }

    private func globalEvidence(_ category: AgentStorageGlobalCategory) -> String {
        switch category {
        case .sharedDatabase:
            return L10n.text("数据库是共享物理文件，无法将磁盘块可靠拆分到单个聊天；这里按整个文件只计算一次。")
        case .sharedAgentData:
            return L10n.text("同一文件由多个聊天引用，因此不分摊到某一个聊天，并且只计算一次。")
        case .crossAgentShared:
            return L10n.text("同一物理文件被多个 Agent 存储位置引用，只计算一次，不计入任一 Agent 的独占占用。")
        default:
            return L10n.text("属于 Agent 的全局运行时或共享数据，只计算一次。")
        }
    }

    @ViewBuilder
    private func unattributedDetail(_ item: AgentStorageUnattributedItem) -> some View {
        detailHeader(
            provider: item.provider,
            title: item.reason.localizedTitle,
            subtitle: item.reason.localizedExplanation,
            path: nil
        )
        detailSection(L10n.text("占用摘要")) {
            detailValue(L10n.text("物理占用"), item.allocatedBytes, emphasized: true)
            detailValue(L10n.text("逻辑大小"), item.logicalBytes)
            LabeledContent(L10n.text("文件"), value: item.artifactCount.formatted())
        }
        evidenceSection(
            id: item.id,
            path: nil,
            evidence: item.reason.localizedExplanation
        )
    }

    private func detailHeader(
        provider: AgentStorageProvider?,
        title: String,
        subtitle: String,
        path: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let provider { AgentStorageProviderIcon(provider: provider, size: 34) }
            else {
                Image(systemName: "link")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if let path {
                Button { reveal(path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain)
                    .help(L10n.text("在 Finder 中显示"))
                    .accessibilityLabel(L10n.text("在 Finder 中显示"))
            }
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Divider().offset(y: -8) }
    }

    private func detailValue(_ title: String, _ bytes: UInt64, emphasized: Bool = false) -> some View {
        LabeledContent {
            Text(AgentStorageSizeFormatter.string(bytes))
                .font(emphasized ? .body.weight(.semibold) : .body)
                .monospacedDigit()
        } label: {
            Text(title).font(emphasized ? .body.weight(.semibold) : .body)
        }
    }

    private func evidenceSection(id: String, path: String?, evidence: String) -> some View {
        detailSection(L10n.text("证据与诊断")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(evidence).font(.caption).foregroundStyle(.secondary)
                Text(shortIdentifier(id))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func privateTitle(
        _ title: String,
        provider: AgentStorageProvider,
        fallback: String
    ) -> String {
        hidesPrivateDetails ? "\(provider.displayName) \(fallback)" : title
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func shortIdentifier(_ value: String) -> String {
        value.count > 20 ? "\(value.prefix(10))…\(value.suffix(6))" : value
    }
}

private enum AgentStorageSizeFormatter {
    static func string(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes >= 1 << 30 { return String(format: "%.2f GiB", value / Double(1 << 30)) }
        if bytes >= 1 << 20 { return String(format: "%.1f MiB", value / Double(1 << 20)) }
        if bytes >= 1 << 10 { return String(format: "%.1f KiB", value / Double(1 << 10)) }
        return "\(bytes) B"
    }
}

private extension AgentStorageProvider {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

private extension AgentStorageGlobalCategory {
    var localizedTitle: String {
        switch self {
        case .sharedDatabase: L10n.text("共享日志与数据库")
        case .sharedAgentData: L10n.text("共享聊天数据")
        case .crossAgentShared: L10n.text("跨 Agent 共享")
        case .runtime: L10n.text("Agent 运行时")
        case .browser: L10n.text("浏览器与 Computer Use")
        case .tools: L10n.text("Plugins、Skills 与工具")
        case .cache: L10n.text("缓存与临时文件")
        case .configuration: L10n.text("配置与索引")
        case .directoryOverhead: L10n.text("目录开销")
        case .other: L10n.text("其他全局数据")
        }
    }

    var symbol: String {
        switch self {
        case .sharedDatabase: "cylinder.split.1x2"
        case .sharedAgentData, .crossAgentShared: "link"
        case .runtime: "cpu"
        case .browser: "globe"
        case .tools: "wrench.and.screwdriver"
        case .cache: "archivebox"
        case .configuration: "doc.badge.gearshape"
        case .directoryOverhead: "folder"
        case .other: "shippingbox"
        }
    }
}

private extension AgentStorageUnattributedReason {
    var localizedTitle: String {
        switch self {
        case .missingThreadMetadata: L10n.text("缺少聊天索引")
        case .relationshipConflict: L10n.text("关系异常子代理")
        case .unverifiedReference: L10n.text("尚未关联的附件")
        case .managedWorktree: L10n.text("受管工作树")
        case .pasteCache: L10n.text("粘贴缓存")
        case .shellSnapshot: L10n.text("未关联 Shell 快照")
        case .unknown: L10n.text("其他未归属数据")
        }
    }

    var localizedExplanation: String {
        switch self {
        case .missingThreadMetadata: L10n.text("文件存在，但状态库或主 session 中没有对应记录")
        case .relationshipConflict: L10n.text("父子关系缺失、冲突或形成循环")
        case .unverifiedReference: L10n.text("没有精确路径引用，不能可靠分配给某个聊天")
        case .managedWorktree: L10n.text("尚未发现稳定的 thread 所有权证据")
        case .pasteCache: L10n.text("缓存中没有稳定的 session ID")
        case .shellSnapshot: L10n.text("文件名或内容没有可验证的聊天标识")
        case .unknown: L10n.text("属于 Agent，但当前 schema 无法进一步识别")
        }
    }

    var symbol: String {
        switch self {
        case .managedWorktree: "arrow.triangle.branch"
        case .relationshipConflict: "point.3.connected.trianglepath.dotted"
        case .unverifiedReference: "paperclip"
        case .pasteCache: "doc.on.clipboard"
        case .shellSnapshot: "terminal"
        case .missingThreadMetadata, .unknown: "questionmark.folder"
        }
    }
}

private extension AgentStorageArtifactCategory {
    var localizedTitle: String {
        switch self {
        case .conversation: L10n.text("对话记录")
        case .toolResult: L10n.text("Tool 结果文件")
        case .subagent: L10n.text("子代理")
        case .fileHistory: L10n.text("文件历史")
        case .attachment: L10n.text("附件与图片")
        case .snapshot: L10n.text("快照与可视化")
        case .task: L10n.text("任务")
        case .workflow: L10n.text("工作流")
        case .other: L10n.text("其他")
        }
    }
}
